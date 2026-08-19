import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// Microphone and system-audio segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        /// Loading models, which on first run means downloading ~600 MB. A
        /// separate state because calling this "transcribing" is a lie the
        /// user sits in front of for minutes.
        case preparing
        case transcribing(session: String, queued: Int)
        /// Carries the directory so the menu can open its log and re-enqueue it.
        case failed(session: String, dir: URL)
    }

    private var queue: [URL] = []
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

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
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
            let dir = queue.removeFirst()
            let session = SessionName.spoken(dir)
            do {
                try await transcribe(dir, session: session)
                if let completionHandler {
                    completionHandler(dir)
                } else {
                    notifyUser(
                        title: "Transcript ready",
                        body: SessionName.spoken(dir),
                        opens: dir.appendingPathComponent("transcript.md")
                    )
                }
                runHook(for: dir, then: { AudioRetention.clean(session: dir) })
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = (SessionName.spoken(dir), dir)
                notifyUser(
                    // Clicking opens the log, so saying "see transcribe.log"
                    // only spends a line telling the user to do what the
                    // notification already does.
                    title: "Transcription failed",
                    body: SessionName.spoken(dir),
                    opens: dir.appendingPathComponent("transcribe.log")
                )
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
        let meta = try SessionMeta.read(from: dir)
        // Model loading happens before any audio is read, and on first run
        // that is a 600 MB download.
        if engine == nil { publish(.preparing) }
        let engine = try await preparedEngine()
        publish(.transcribing(session: session, queued: queue.count))

        var cleanedMic = meta.cleanedMicrophoneFile.map {
            dir.appendingPathComponent($0)
        }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if
            let mic = meta.tracks.first(where: { $0.kind == "mic" }),
            let system = meta.tracks.first(where: { $0.kind == "system" })
        {
            let micAudio = dir.appendingPathComponent(mic.file)
            let systemAudio = dir.appendingPathComponent(system.file)
            if
                FileManager.default.fileExists(atPath: micAudio.path),
                FileManager.default.fileExists(atPath: systemAudio.path)
            {
                do {
                    log(dir, "cleaning speaker playback from \(mic.file) (AEC3)")
                    cleanedMic = try EchoCancellation.clean(
                        mic: micAudio,
                        micOffsetMs: mic.offsetMs,
                        system: systemAudio,
                        systemOffsetMs: system.offsetMs,
                        in: dir
                    )
                    log(dir, "cleaned microphone written to \(EchoCancellation.outputName)")
                } catch {
                    log(dir, "echo cancellation failed, using \(mic.file): \(error)")
                }
            }
        }

        var merged: [TranscriptDocument.Segment] = []
        var voices: [String: TranscriptDocument.Voice] = [:]
        var diarizedModel: String?
        for track in meta.tracks {
            let source = dir.appendingPathComponent(track.file)
            let audio = track.kind == "mic" ? cleanedMic ?? source : source
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(audio.lastPathComponent) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let (speakers, split, sharedLabel) = await labels(
                for: segments, track: track, profile: meta.meetingProfile,
                audio: audio, dir: dir
            )
            if split {
                diarizedModel = diarizer?.model
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            let voiceIDs = TranscriptDocument.voiceIDs(
                labels: speakers,
                source: track.kind,
                split: split,
                sharedLabel: sharedLabel
            )
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
                    source: track.kind,
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
            diarizer: diarizedModel,
            created_at: ISO8601DateFormatter().string(from: Date()),
            voices: voices,
            segments: merged
        )
        try TranscriptStore(session: dir).write(transcript)
        log(dir, "done — \(merged.count) segments")
    }

    private static func sampleScore(
        _ sample: TranscriptDocument.Voice.Sample, text: String
    ) -> Int {
        let duration = sample.end_ms - sample.start_ms
        let durationScore = duration <= 8_000 ? min(duration, 8_000) : max(0, 16_000 - duration)
        return durationScore + min(text.count, 120) * 20
    }

    /// Per-segment speaker labels for one track, diarized when that track's
    /// config asks for it.
    ///
    /// A diarization failure degrades to the flat track label instead of
    /// propagating — coarse attribution beats losing the transcript — and the
    /// reason lands in transcribe.log.
    ///
    /// - Returns: one label per segment, and whether diarization actually split
    ///   the track. False when it was off, failed, or found a single speaker,
    ///   which is what decides whether the transcript records a diarizer.
    private func labels(
        for segments: [TranscriptSegment],
        track: SessionMeta.Track,
        profile: MeetingProfile?,
        audio: URL,
        dir: URL
    ) async -> (labels: [String], split: Bool, sharedLabel: String) {
        let settings: VoiceSettings
        if let profile {
            settings = profile.voiceSettings(for: track.kind)
        } else {
            let legacy = Config.speakerDetection(track: track.kind)
            settings = VoiceSettings(
                separatesVoices: legacy.enabled,
                soloLabel: legacy.soloLabel,
                sharedLabel: legacy.sharedLabel
            )
        }
        guard settings.separatesVoices, !segments.isEmpty else {
            return (segments.map { _ in settings.soloLabel }, false, settings.sharedLabel)
        }
        do {
            log(dir, "diarizing \(track.file)")
            let engine = try await preparedDiarizer()
            let spans = try await engine.spans(for: audio)
            let labels = DiarizationEngine.labels(
                for: segments,
                spans: spans,
                solo: settings.soloLabel,
                shared: settings.sharedLabel
            )
            let distinct = Set(labels).count
            log(dir, "diarized \(track.file) — \(distinct) speaker(s)")
            return (labels, distinct > 1, settings.sharedLabel)
        } catch {
            log(dir, "diarization failed for \(track.file), using \(settings.soloLabel): \(error)")
            return (segments.map { _ in settings.soloLabel }, false, settings.sharedLabel)
        }
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
        let url = dir.appendingPathComponent("transcribe.log")
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

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let offsetMs: Int
        /// Config key for this track's diarization settings and its label
        /// defaults: "mic" or "system".
        let kind: String
    }

    let tracks: [Track]
    let meetingProfile: MeetingProfile?
    let cleanedMicrophoneFile: String?

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, offsetMs: offsets["mic"] ?? 0, kind: "mic"))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, offsetMs: offsets["system"] ?? 0, kind: "system"))
        }
        let meetingProfile = (json["meeting_profile"] as? String)
            .flatMap(MeetingProfile.init(rawValue:))
        return SessionMeta(
            tracks: tracks,
            meetingProfile: meetingProfile,
            cleanedMicrophoneFile: files["mic_cleaned"]
        )
    }
}
