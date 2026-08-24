import Foundation

/// One meeting recording with independent microphone and computer-audio tracks.
@MainActor
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    /// Set the first time a track is interrupted and never cleared: the
    /// recording can no longer be assumed complete, even though capture came
    /// back.
    private(set) var trouble: String?

    /// Whether a track is down *now*, as opposed to `trouble`, which records
    /// what went wrong at any point. The icon follows this so it stops warning
    /// about a fault the session has already recovered from.
    var isDegraded: Bool {
        !failedArchives.isEmpty || supervisors.contains { !$0.isHealthy }
    }

    /// Raised once when a track has been down long enough that it is not
    /// coming back on its own. Carries a title and body, since what to say
    /// depends on which tracks are gone.
    var onTrackDead: ((String, String) -> Void)?

    /// Raised once when every track that has ever carried audio has been quiet
    /// long enough that the meeting is probably over and nobody stopped the
    /// recording.
    var onEveryoneGone: (() -> Void)?

    /// Raised when neither source archive can accept more audio. The app owns
    /// the stop action so this type does not call back into its own writers.
    var onAllArchivesFailed: (() -> Void)?

    /// A legitimately quiet stretch runs a minute or three. Nobody speaking
    /// and nothing playing for this long is not a meeting in progress.
    private static let quietBeforeNudge: TimeInterval = 600

    private var reported: Set<String> = []
    private var nudged = false
    private var failedArchives: Set<String> = []
    private var isStopping = false

    private let log: SessionLog
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var supervisors: [CaptureSupervisor] = []
    private var deviceWatcher: AudioDevices.Watcher?
    private var ticker: Timer?
    private var journalHasOffsets = false
    private var liveAEC: LiveEchoCanceller?
    private var liveFrames: AcceptedFrameMailbox?
    private var liveAECBegun = false

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(candidate)
        dir = candidate
        log = SessionLog(dir: candidate)
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        log.log("session started — \(dir.lastPathComponent)")
        log.log(
            "devices — input=\(AudioDevices.defaultInputName()) "
                + "output=\(AudioDevices.defaultOutputName())"
        )
        deviceWatcher = AudioDevices.Watcher(log: log)

        system.prepare(writingTo: SessionFiles.internalFile("system.caf", in: dir), log: log)
        try mic.prepare(writingTo: SessionFiles.internalFile("mic.caf", in: dir), log: log)
        mic.onArchiveFailed = { [weak self] detail in
            self?.archiveFailed(name: "mic", detail: detail)
        }
        system.onArchiveFailed = { [weak self] detail in
            self?.archiveFailed(name: "system", detail: detail)
        }

        if let canceller = LiveEchoCanceller(
            session: SessionFiles.internalDirectory(dir),
            rate: MicRecorder.trackSampleRate,
            log: log
        ) {
            let mailbox = AcceptedFrameMailbox(
                maxQueuedFrames: Int(MicRecorder.trackSampleRate * 30),
                consume: { canceller.consume($0) },
                onOverflow: { canceller.abandon("accepted-frame mailbox overflow") }
            )
            let fanout = AcceptedFrameFanout([mailbox])
            mic.sendAcceptedFrames(to: fanout)
            system.sendAcceptedFrames(to: fanout)
            liveAEC = canceller
            liveFrames = mailbox
        }

        let systemSupervisor = supervise(system)
        let micSupervisor = supervise(mic)
        do {
            try publishCaptureJournal()
            try systemSupervisor.start()
            try micSupervisor.start()
        } catch {
            // Nothing was captured, so the folder is noise rather than a record
            // of anything. Leaving it behind means a failed start accumulates
            // an empty dated directory every time.
            let ended = Date()
            [systemSupervisor, micSupervisor].forEach { $0.stop(at: ended) }
            log.warn("session aborted: \(error)")
            log.close()
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        supervisors = [micSupervisor, systemSupervisor]

        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // assumeIsolated traps if this ever fires off-main; the main run
            // loop is the only thing making it safe.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.supervisors.forEach { $0.tick() }
                self.publishJournalOffsetsIfReady()
                self.alignLiveEchoCancellerIfReady()
                self.reportDeadTracks()
                self.reportEveryoneGone()
            }
        }
        scheduleInteractiveTimer(ticker)
        self.ticker = ticker
    }

    /// Stop both tracks and write meta.json.
    @discardableResult
    func stop() async throws -> Bool {
        isStopping = true
        ticker?.invalidate()
        ticker = nil
        deviceWatcher = nil

        let ended = Date()
        supervisors.forEach { $0.detachForStop() }
        supervisors = []
        async let microphoneClosed: Void = mic.closeAsync(at: ended)
        async let systemClosed: Void = system.closeAsync(at: ended)
        _ = await (microphoneClosed, systemClosed)
        captureArchiveFailures()

        // After the writers close, so every accepted frame is already queued.
        if let liveFrames {
            await Task.detached { liveFrames.finish() }.value
        }
        liveFrames = nil
        if let liveAEC {
            let started = Date()
            let published = await Task.detached { liveAEC.finish() }.value
            self.liveAEC = nil
            if published {
                log.log(String(
                    format: "live aec: drained in %.1fs", Date().timeIntervalSince(started)
                ))
            }
        }

        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let startOffsets = SessionTimeline.startOffsets(
            microphoneStartedAt: micStart,
            systemStartedAt: systemStart
        )

        var files = SessionAudioFiles()
        var tracks = SessionTracks()
        if mic.duration > 0 {
            files.microphone = SessionFiles.internalPath("mic.caf")
            tracks.microphone = trackMeta(
                file: SessionFiles.internalPath("mic.caf"),
                duration: mic.duration,
                gaps: mic.gaps
            )
        }
        if system.duration > 0 {
            files.system = SessionFiles.internalPath("system.caf")
            tracks.system = trackMeta(
                file: SessionFiles.internalPath("system.caf"),
                duration: system.duration,
                gaps: system.gaps
            )
        }
        if mic.duration == 0 {
            try? FileManager.default.removeItem(
                at: SessionFiles.internalFile("mic.caf", in: dir)
            )
        }
        if system.duration == 0 {
            try? FileManager.default.removeItem(
                at: SessionFiles.internalFile("system.caf", in: dir)
            )
        }

        let meta = SessionManifest(
            started: iso.string(from: startedAt),
            ended: iso.string(from: ended),
            durationSeconds: Int(ended.timeIntervalSince(startedAt)),
            files: files,
            startOffsets: startOffsets,
            tracks: tracks,
            audioState: files.hasSourceAudio ? nil : .empty
        )
        do {
            let sessionDir = dir
            try await Task.detached {
                try SessionMetadataStore.writeManifest(meta, to: sessionDir)
            }.value
            try? FileManager.default.removeItem(at: SessionFiles.captureJournal(dir))
        } catch {
            log.warn("couldn't publish meta.json: \(error)")
            log.close()
            throw error
        }

        log.log(String(
            format: "session stopped — %.0fs wall, mic %.0fs (%d gap(s)), system %.0fs (%d gap(s))",
            ended.timeIntervalSince(startedAt),
            mic.duration, mic.gaps.count, system.duration, system.gaps.count
        ))
        log.close()
        return files.hasSourceAudio
    }

    // MARK: -

    private func supervise(_ capture: Capture) -> CaptureSupervisor {
        CaptureSupervisor(capture: capture, log: log, startedAt: startedAt) {
            [weak self] message in
            self?.report(message)
        }
    }

    /// The two tracks' offset is only known once both have delivered a buffer.
    /// A system tap that never delivers leaves nothing to cancel against, and
    /// the offline pass needs both tracks too, so give up rather than hold
    /// audio for a meeting that is already running.
    private func alignLiveEchoCancellerIfReady() {
        guard let liveAEC, !liveAECBegun else { return }
        guard let micStart = mic.firstBufferAt, let systemStart = system.firstBufferAt else {
            // Comfortably inside LiveEchoCanceller's buffered-audio cap, so a
            // one-sided start is reported as that rather than as the pump
            // falling behind.
            if Date().timeIntervalSince(startedAt) > 15 {
                liveAECBegun = true
                liveFrames?.abandon()
                liveFrames = nil
                liveAEC.abandon("only one track started within 15s")
                self.liveAEC = nil
            }
            return
        }
        liveAECBegun = true
        liveAEC.begin(startOffsets: SessionTimeline.startOffsets(
            microphoneStartedAt: micStart,
            systemStartedAt: systemStart
        ))
    }

    private func publishJournalOffsetsIfReady() {
        guard !journalHasOffsets, mic.firstBufferAt != nil, system.firstBufferAt != nil else {
            return
        }
        do {
            try publishCaptureJournal()
            journalHasOffsets = true
        } catch {
            log.warn("couldn't update capture journal offsets: \(error)")
        }
    }

    private func publishCaptureJournal() throws {
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let journal = CaptureJournal(
            started: ISO8601DateFormatter().string(from: startedAt),
            files: SessionAudioFiles(
                microphone: SessionFiles.internalPath("mic.caf"),
                system: SessionFiles.internalPath("system.caf")
            ),
            startOffsets: SessionTimeline.startOffsets(
                microphoneStartedAt: micStart,
                systemStartedAt: systemStart
            )
        )
        try SessionMetadataStore.writeJournal(journal, to: dir)
    }

    /// A track that has been down past the threshold is announced once. Both
    /// tracks down is one message rather than two, because the two arrive
    /// together and say the same thing.
    private func reportDeadTracks() {
        let dead = supervisors.filter {
            ($0.outage ?? 0) > CaptureSupervisor.deadThreshold && !$0.hasReportedDead
        }
        guard !dead.isEmpty else { return }
        dead.forEach { $0.hasReportedDead = true }

        let names = Set(dead.map(\.name))
        let seconds = Int(CaptureSupervisor.deadThreshold)
        if names.count > 1 {
            onTrackDead?(
                "Recording is empty",
                "Neither track has captured anything for \(seconds) seconds. "
                    + "Quill is still running."
            )
        } else if names.contains("mic") {
            onTrackDead?(
                "Microphone stopped",
                "Still recording the call, but nothing from your mic for "
                    + "\(seconds) seconds. Reconnect your input device."
            )
        } else {
            onTrackDead?(
                "System audio stopped",
                "Still recording your mic, but nothing from the call for "
                    + "\(seconds) seconds. Check the meeting app is still playing."
            )
        }
    }

    /// Nobody has spoken and nothing has played for long enough that the
    /// meeting has almost certainly ended.
    ///
    /// Only tracks that have ever been audible count. An in-person meeting
    /// plays nothing, so counting the system track would fire this ten minutes
    /// into a real meeting. If neither track has ever been audible, capture is
    /// broken rather than finished, which is `reportDeadTracks`' business.
    private func reportEveryoneGone() {
        guard !nudged, !isDegraded else { return }
        let heard = [mic.lastAudibleAt, system.lastAudibleAt].compactMap { $0 }
        guard mic.hasEverBeenAudible || system.hasEverBeenAudible, let latest = heard.max()
        else { return }
        guard Date().timeIntervalSince(latest) > Self.quietBeforeNudge else { return }
        nudged = true
        log.log("session: quiet for \(Int(Self.quietBeforeNudge / 60)) minutes — asking")
        onEveryoneGone?()
    }

    /// Accumulates, since both tracks broken must not read as one.
    private func report(_ message: String) {
        reported.insert(message)
        trouble = reported.sorted().joined(separator: " · ")
    }

    private func archiveFailed(name: String, detail: String) {
        guard !isStopping else { return }
        recordArchiveFailure(name: name, detail: detail, notify: true)
    }

    private func captureArchiveFailures() {
        if let detail = mic.archiveFailure {
            recordArchiveFailure(name: "mic", detail: detail, notify: false)
        }
        if let detail = system.archiveFailure {
            recordArchiveFailure(name: "system", detail: detail, notify: false)
        }
    }

    private func recordArchiveFailure(name: String, detail: String, notify: Bool) {
        guard failedArchives.insert(name).inserted else { return }
        log.warn("\(name): source archive failed permanently: \(detail)")
        report("\(name) source archive failed")
        liveFrames?.abandon()
        liveFrames = nil
        liveAEC?.abandon("\(name) source archive failed")
        liveAEC = nil
        liveAECBegun = true

        guard notify else { return }
        if failedArchives.count == 2 {
            onTrackDead?(
                "Recording stopped",
                "Quill couldn't save any more audio. Quill will try to recover audio already written."
            )
            onAllArchivesFailed?()
        } else if name == "mic" {
            onTrackDead?(
                "Microphone recording stopped",
                "Quill couldn't save more microphone audio. The call is still being recorded."
            )
        } else {
            onTrackDead?(
                "System audio recording stopped",
                "Quill couldn't save more call audio. Your microphone is still being recorded."
            )
        }
    }

    private func trackMeta(
        file: String, duration: TimeInterval, gaps: [TrackWriter.Gap]
    ) -> SessionTrackMetadata {
        let padded = gaps.reduce(0) { $0 + $1.seconds }
        return SessionTrackMetadata(
            file: file,
            durationSeconds: Int(duration.rounded()),
            capturedSeconds: Int((duration - padded).rounded()),
            // `capturedSeconds` excludes silence padded over gaps, so a track
            // that runs full length but recorded three minutes says so.
            gaps: gaps.map {
                SessionGap(at: Int($0.at.rounded()), seconds: Int($0.seconds.rounded()))
            }
        )
    }
}
