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
    var isDegraded: Bool { supervisors.contains { !$0.isHealthy } }

    /// Raised once when a track has been down long enough that it is not
    /// coming back on its own. Carries a title and body, since what to say
    /// depends on which tracks are gone.
    var onTrackDead: ((String, String) -> Void)?

    /// Raised once when every track that has ever carried audio has been quiet
    /// long enough that the meeting is probably over and nobody stopped the
    /// recording.
    var onEveryoneGone: (() -> Void)?

    /// A legitimately quiet stretch runs a minute or three. Nobody speaking
    /// and nothing playing for this long is not a meeting in progress.
    private static let quietBeforeNudge: TimeInterval = 600

    private var reported: Set<String> = []
    private var nudged = false

    private let log: SessionLog
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var supervisors: [CaptureSupervisor] = []
    private var deviceWatcher: AudioDevices.Watcher?
    private var ticker: Timer?
    private var journalHasOffsets = false

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
                self.reportDeadTracks()
                self.reportEveryoneGone()
            }
        }
        scheduleInteractiveTimer(ticker)
        self.ticker = ticker
    }

    /// Stop both tracks and write meta.json.
    func stop() throws {
        ticker?.invalidate()
        ticker = nil
        deviceWatcher = nil

        let ended = Date()
        supervisors.forEach { $0.stop(at: ended) }
        supervisors = []

        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        let meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": [
                "mic": SessionFiles.internalPath("mic.caf"),
                "system": SessionFiles.internalPath("system.caf"),
            ],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
            // `captured_seconds` excludes silence padded over gaps, so a track
            // that runs full length but recorded three minutes says so.
            "tracks": [
                "mic": trackMeta(
                    file: SessionFiles.internalPath("mic.caf"),
                    duration: mic.duration,
                    gaps: mic.gaps
                ),
                "system": trackMeta(
                    file: SessionFiles.internalPath("system.caf"),
                    duration: system.duration,
                    gaps: system.gaps
                ),
            ],
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: meta,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(
                to: SessionFiles.metadata(dir),
                options: .atomic
            )
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
    }

    // MARK: -

    private func supervise(_ capture: Capture) -> CaptureSupervisor {
        CaptureSupervisor(capture: capture, log: log, startedAt: startedAt) {
            [weak self] message in
            self?.report(message)
        }
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
        let earliest = min(mic.firstBufferAt ?? startedAt, system.firstBufferAt ?? startedAt)
        let journal: [String: Any] = [
            "started": ISO8601DateFormatter().string(from: startedAt),
            "files": [
                "mic": SessionFiles.internalPath("mic.caf"),
                "system": SessionFiles.internalPath("system.caf"),
            ],
            "start_offset_ms": [
                "mic": Int((mic.firstBufferAt ?? earliest).timeIntervalSince(earliest) * 1000),
                "system": Int(
                    (system.firstBufferAt ?? earliest).timeIntervalSince(earliest) * 1000
                ),
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: journal,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(
            to: SessionFiles.captureJournal(dir),
            options: .atomic
        )
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

    private func trackMeta(
        file: String, duration: TimeInterval, gaps: [TrackWriter.Gap]
    ) -> [String: Any] {
        let padded = gaps.reduce(0) { $0 + $1.seconds }
        return [
            "file": file,
            "duration_seconds": Int(duration.rounded()),
            "captured_seconds": Int((duration - padded).rounded()),
            "gaps": gaps.map { ["at": Int($0.at.rounded()), "seconds": Int($0.seconds.rounded())] },
        ]
    }
}
