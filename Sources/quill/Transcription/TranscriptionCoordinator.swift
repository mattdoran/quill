import Foundation

struct SpeakerSeparationProgress: Sendable {
    let source: SourceTrack?
    let completedSources: Int
    let totalSources: Int

    var percentage: Int {
        guard totalSources > 0 else { return 0 }
        return completedSources * 100 / totalSources
    }
}

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// Microphone and system-audio segments are shifted by
/// its start offset, merged by timestamp, and written as an internal canonical
/// document plus the user-facing transcript.md. The filesystem is the queue.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        /// Loading models, which on first run means downloading ~600 MB. A
        /// separate state because calling this "transcribing" is a lie the
        /// user sits in front of for minutes.
        case preparing
        case transcribing(session: String, queued: Int)
        case separatingSpeakers(session: String, queued: Int)
        /// Carries the directory so the menu can open its log and re-enqueue it.
        case failed(session: String, dir: URL)
    }

    private enum Job {
        case transcript(URL)
        case separateSpeakers(
            URL,
            Set<SourceTrack>,
            @Sendable (SpeakerSeparationProgress) -> Void,
            CheckedContinuation<Void, any Error>
        )

        var session: URL {
            switch self {
            case .transcript(let session), .separateSpeakers(let session, _, _, _): session
            }
        }
    }

    private var queue: [Job] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var diarizer: DiarizationEngine?
    private var lastFailure: (name: String, dir: URL)?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var completionHandler: (@Sendable (URL) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    func setCompletionHandler(_ handler: @escaping @Sendable (URL) -> Void) {
        completionHandler = handler
    }

    func enqueue(_ sessionDir: URL) {
        queue.append(.transcript(sessionDir))
        drainIfIdle()
    }

    func separateSpeakers(
        in sessionDir: URL,
        tracks: Set<SourceTrack> = Set(SourceTrack.allCases),
        progress: @escaping @Sendable (SpeakerSeparationProgress) -> Void = { _ in }
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.append(.separateSpeakers(sessionDir, tracks, progress, continuation))
            drainIfIdle()
        }
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                SessionFiles.hasProcessableAudio($0)
                    && !fm.fileExists(atPath: SessionFiles.transcriptJSON($0).path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(where: { $0.session == dir }) {
            queue.append(.transcript(dir))
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            let dir = job.session
            let session = SessionName.spoken(dir)
            switch job {
            case .transcript:
                do {
                    try await transcribe(dir, session: session)
                    if let completionHandler {
                        completionHandler(dir)
                    } else {
                        notifyUser(
                            title: "Transcript ready",
                            body: SessionName.spoken(dir),
                            opens: SessionFiles.transcriptMarkdown(dir)
                        )
                    }
                    runHook(for: dir, then: { AudioRetention.clean(session: dir) })
                } catch {
                    log(dir, "transcription failed: \(error)")
                    lastFailure = (SessionName.spoken(dir), dir)
                    notifyUser(
                        title: "Transcription failed",
                        body: SessionName.spoken(dir),
                        opens: SessionFiles.transcriptionLog(dir)
                    )
                }
            case .separateSpeakers(_, let tracks, let progress, let continuation):
                do {
                    publish(.separatingSpeakers(session: session, queued: queue.count))
                    try await applySpeakerSeparation(
                        to: dir,
                        tracks: tracks,
                        progress: progress
                    )
                    continuation.resume()
                } catch {
                    log(dir, "speaker separation failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
        await engine?.release()
        engine = nil
        await diarizer?.release()
        diarizer = nil
        publish(lastFailure.map { .failed(session: $0.name, dir: $0.dir) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL, session: String) async throws {
        let transcriptionStarted = Date()
        let meta = try SessionMetadataStore.readManifest(dir)
        // Model loading happens before any audio is read, and on first run
        // that is a 600 MB download.
        if engine == nil { publish(.preparing) }
        let engine = try await preparedEngine()
        publish(.transcribing(session: session, queued: queue.count))

        let prepared = try AudioPreparation.prepare(
            session: dir,
            manifest: meta,
            log: { log(dir, $0) }
        )

        var merged: [TranscriptDocument.Segment] = []
        var voices: [String: TranscriptDocument.Voice] = [:]
        for track in meta.sourceAudio {
            guard let audio = prepared.transcriptionSource(for: track.track) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(audio.lastPathComponent) (\(engine.name))")
            let trackStarted = Date()
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            log(dir, String(
                format: "transcribed %@ in %.1fs",
                audio.lastPathComponent,
                Date().timeIntervalSince(trackStarted)
            ))
            let speaker = track.track == .microphone ? "Me" : "Them"
            let speakers = segments.map { _ in speaker }
            let offset = TimeInterval(track.offsetMilliseconds) / 1000
            let voiceIDs = [speaker: "\(track.track.rawValue):1"]
            let audioFile = audio.path.replacingOccurrences(of: dir.path + "/", with: "")
            for (speaker, id) in voiceIDs {
                var candidates: [(sample: TranscriptDocument.Voice.Sample, score: Int)] = []
                for index in segments.indices where speakers[index] == speaker {
                    let sample = TranscriptDocument.Voice.Sample(
                        start_ms: Int(segments[index].start * 1000),
                        end_ms: Int(segments[index].end * 1000)
                    )
                    candidates.append((
                        sample,
                        Self.sampleScore(sample, text: segments[index].text)
                    ))
                }
                candidates.sort { $0.score > $1.score }
                voices[id] = TranscriptDocument.Voice(
                    source: track.track.rawValue,
                    audio_file: audioFile,
                    machine_label: speaker,
                    name: nil,
                    samples: candidates.prefix(3).map(\.sample)
                )
            }
            merged += zip(segments, speakers).map { segment, speaker in
                TranscriptDocument.Segment(
                    speaker: speaker,
                    voice_id: voiceIDs[speaker],
                    start_ms: Int((segment.start + offset) * 1000),
                    end_ms: Int((segment.end + offset) * 1000),
                    text: segment.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = TranscriptDocument(
            schema_version: TranscriptDocument.currentSchemaVersion,
            engine: engine.name,
            model: engine.model,
            diarizer: nil,
            created_at: ISO8601DateFormatter().string(from: Date()),
            voices: voices,
            segments: merged
        )
        try TranscriptStore(session: dir).write(transcript)
        log(dir, String(
            format: "done — %d segments in %.1fs",
            merged.count,
            Date().timeIntervalSince(transcriptionStarted)
        ))
    }

    private func applySpeakerSeparation(
        to dir: URL,
        tracks selectedTracks: Set<SourceTrack>,
        progress: @Sendable (SpeakerSeparationProgress) -> Void
    ) async throws {
        let separationStarted = Date()
        let store = TranscriptStore(session: dir)
        let current = try store.read()
        guard current.canEditVoices else {
            throw TranscriptStore.StoreError.unsupportedSchema
        }
        guard current.diarizer == nil else {
            throw SpeakerSeparationError.alreadySeparated
        }
        let meta = try SessionMetadataStore.readManifest(dir)
        let prepared = try AudioPreparation.prepare(
            session: dir,
            manifest: meta,
            log: { log(dir, $0) }
        )
        let tracks = meta.sourceAudio.filter { selectedTracks.contains($0.track) }
        guard !tracks.isEmpty else { throw SpeakerSeparationError.sourceAudioUnavailable }
        progress(.init(source: nil, completedSources: 0, totalSources: tracks.count))
        let engine = try await preparedDiarizer()
        var voices = current.voices.filter { _, voice in
            guard let source = SourceTrack(rawValue: voice.source) else { return true }
            return !selectedTracks.contains(source)
        }
        var segments = current.segments
        var processedTrack = false
        var voiceLabels = VoiceLabelSequence()

        for (trackIndex, track) in tracks.enumerated() {
            guard let audio = prepared.transcriptionSource(for: track.track) else {
                throw SpeakerSeparationError.sourceAudioUnavailable
            }
            let indices = segments.indices.filter { index in
                guard
                    let voiceID = segments[index].voice_id,
                    let voice = current.voices[voiceID]
                else { return false }
                return voice.source == track.track.rawValue
            }
            guard !indices.isEmpty else { continue }
            processedTrack = true
            progress(.init(
                source: track.track,
                completedSources: trackIndex,
                totalSources: tracks.count
            ))

            let offset = TimeInterval(track.offsetMilliseconds) / 1000
            let timed = indices.map { index in
                TranscriptSegment(
                    start: max(0, TimeInterval(segments[index].start_ms) / 1000 - offset),
                    end: max(0, TimeInterval(segments[index].end_ms) / 1000 - offset),
                    text: segments[index].text
                )
            }
            let started = Date()
            log(dir, "separating speakers in \(audio.lastPathComponent)")
            let spans = try await engine.spans(for: audio)
            let assignments = DiarizationEngine.assignments(for: timed, spans: spans)
            var ordinals: [Int: Int] = [:]
            for assignment in assignments {
                guard let assignment, ordinals[assignment] == nil else { continue }
                ordinals[assignment] = ordinals.count + 1
            }
            let audioFile = audio.path.replacingOccurrences(of: dir.path + "/", with: "")

            if ordinals.isEmpty {
                let id = "\(track.track.rawValue):1"
                let label = voiceLabels.next()
                var voice = makeVoice(
                    source: track.track.rawValue, audioFile: audioFile,
                    label: label, indices: Array(timed.indices), segments: timed
                )
                voice.name = current.nameToCarry(
                    source: track.track.rawValue, separatedVoiceCount: 1
                )
                voices[id] = voice
                for index in indices {
                    segments[index].speaker = voice.displayName
                    segments[index].voice_id = id
                }
                continue
            }

            for (speaker, ordinal) in ordinals.sorted(by: { $0.value < $1.value }) {
                let id = "\(track.track.rawValue):\(ordinal)"
                let label = voiceLabels.next()
                let positions = assignments.indices.filter { assignments[$0] == speaker }
                var voice = makeVoice(
                    source: track.track.rawValue, audioFile: audioFile,
                    label: label, indices: positions, segments: timed
                )
                voice.name = current.nameToCarry(
                    source: track.track.rawValue, separatedVoiceCount: ordinals.count
                )
                voices[id] = voice
            }
            for (position, index) in indices.enumerated() {
                guard
                    let speaker = assignments[position],
                    let ordinal = ordinals[speaker]
                else {
                    segments[index].speaker = "Unassigned"
                    segments[index].voice_id = nil
                    continue
                }
                let id = "\(track.track.rawValue):\(ordinal)"
                segments[index].speaker = voices[id]?.displayName ?? "Voice \(ordinal)"
                segments[index].voice_id = id
            }
            log(dir, String(
                format: "found %d speaker(s) in %@ (%.1fs)",
                ordinals.count,
                audio.lastPathComponent,
                Date().timeIntervalSince(started)
            ))
        }

        guard processedTrack else { throw SpeakerSeparationError.incompatibleTranscript }
        let enriched = TranscriptDocument(
            schema_version: current.schema_version,
            engine: current.engine,
            model: current.model,
            diarizer: engine.model,
            created_at: current.created_at,
            voices: voices,
            segments: segments
        )
        try store.preserveBeforeSpeakerSeparation(current)
        try store.write(enriched)
        log(dir, String(
            format: "speaker separation complete in %.1fs",
            Date().timeIntervalSince(separationStarted)
        ))
    }

    private func makeVoice(
        source: String,
        audioFile: String,
        label: String,
        indices: [Int],
        segments: [TranscriptSegment]
    ) -> TranscriptDocument.Voice {
        var candidates = indices.map { index in
            let sample = TranscriptDocument.Voice.Sample(
                start_ms: Int(segments[index].start * 1000),
                end_ms: Int(segments[index].end * 1000)
            )
            return (sample, Self.sampleScore(sample, text: segments[index].text))
        }
        candidates.sort { $0.1 > $1.1 }
        return TranscriptDocument.Voice(
            source: source,
            audio_file: audioFile,
            machine_label: label,
            name: nil,
            samples: candidates.prefix(3).map(\.0)
        )
    }

    private enum SpeakerSeparationError: LocalizedError {
        case alreadySeparated
        case sourceAudioUnavailable
        case incompatibleTranscript

        var errorDescription: String? {
            switch self {
            case .alreadySeparated:
                "Undo the current voice separation before running it again."
            case .sourceAudioUnavailable:
                "Source audio is no longer available, so this transcript cannot be reprocessed."
            case .incompatibleTranscript:
                "This transcript does not contain the timing information needed for speaker separation."
            }
        }
    }

    private static func sampleScore(
        _ sample: TranscriptDocument.Voice.Sample, text: String
    ) -> Int {
        let duration = sample.end_ms - sample.start_ms
        let durationScore = duration <= 8_000 ? min(duration, 8_000) : max(0, 16_000 - duration)
        return durationScore + min(text.count, 120) * 20
    }

    private func preparedDiarizer() async throws -> DiarizationEngine {
        if let diarizer { return diarizer }
        let diarizer = DiarizationEngine()
        try await diarizer.prepare()
        self.diarizer = diarizer
        return diarizer
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL, then completion: (@Sendable () -> Void)? = nil) {
        guard let cmd = Config.onStop() else {
            completion?()
            return
        }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        task.terminationHandler = { _ in completion?() }
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
            completion?()
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = SessionFiles.transcriptionLog(dir)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}
