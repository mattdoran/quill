import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [
            Run.self, Doctor.self, Install.self, Diarize.self, WatchCalls.self,
            PreviewCompanion.self, PreviewVoices.self, CheckLiveAEC.self,
        ],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Notifier.shared.start()
        LoginItem.migrateFromLaunchAgent { message in
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
        LoginItem.enableByDefaultOnFirstRun()
        let controller = AppController(root: root)
        Notifier.shared.onStopRequested = { [weak controller] in
            controller?.stopFromNotification()
        }
        Notifier.shared.onCallRecordingRequested = { [weak controller] promptToken in
            controller?.startDetectedCall(promptToken: promptToken)
        }
        Notifier.shared.onCallStopRequested = { [weak controller] recordingToken in
            controller?.stopDetectedCall(recordingToken: recordingToken)
        }
        Notifier.shared.onReviewTranscript = { [weak controller] path in
            controller?.reviewTranscript(at: URL(fileURLWithPath: path))
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private var root: URL
    private let menuBar = MenuBarController()
    private let applicationMenu = ApplicationMenuController()
    private let updater = UpdaterController()
    private let companion = MeetingCompanionController()
    private let transcription = TranscriptionCoordinator()
    private let models = ModelDownload()
    private var settings: SettingsWindowController?
    private var voiceReview: VoiceReviewWindowController?
    private var session: RecordingSession?
    private var stoppingTask: Task<Void, Never>?
    private var isStarting = false
    private var callObserver: CallObservationController?
    private var promptedCallApplication: CallApplication?
    private var promptedCallToken: UUID?
    private var startingCallApplication: CallApplication?
    private var startingCallToken: UUID?
    private var recordingCallApplication: CallApplication?
    private var recordingCallToken: UUID?
    private var ticker: Timer?
    private var retentionTimer: Timer?
    private var processingSession: URL?
    private var pendingReadySession: URL?

    /// The session whose transcription failed, so its log can be opened and
    /// the job re-queued without quitting the app.
    private var failedSession: URL?

    init(root: URL) {
        self.root = root
        applicationMenu.onQuit = { [weak self] in self?.shutdown() }
        applicationMenu.install()
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onShowRecordingControls = { [weak self] in
            self?.companion.showRecordingControls()
        }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onOpenLastTranscript = { [weak self] in self?.openLastTranscript() }
        menuBar.onIdentifyVoices = { [weak self] in
            guard let session = self?.voiceReviewSession() else { return }
            self?.reviewTranscript(at: session)
        }
        menuBar.onReviewRecording = { [weak self] in self?.chooseRecordingToReview() }
        menuBar.hasVoiceReview = { [weak self] in self?.voiceReviewSession() != nil }
        menuBar.hasTranscript = { [weak self] in
            guard let self else { return false }
            // Checked here rather than on a timer: the menu opening is the
            // only moment it matters.
            let reachable = canReachRoot()
            menuBar.showFolderProblem(!reachable)
            // Refresh immediately because opening the menu can change the
            // folder warning between timer ticks.
            refreshMenuStatus()
            return reachable && lastTranscript() != nil
        }
        menuBar.recordingsPath = { [weak self] in self?.root.path ?? "" }
        menuBar.onChangeFolder = { [weak self] in self?.changeFolder() }
        menuBar.onOpenFailureLog = { [weak self] in
            guard let dir = self?.failedSession else { return }
            NSWorkspace.shared.open(SessionFiles.transcriptionLog(dir))
        }
        menuBar.onRetryTranscription = { [weak self] in
            guard let self, let dir = failedSession else { return }
            failedSession = nil
            menuBar.updateTranscription(nil)
            Task { [transcription] in await transcription.enqueue(dir) }
        }
        menuBar.update(recording: false, elapsed: nil)

        AudioRetention.clean(root: root)
        let retentionTimer = Timer(timeInterval: 24 * 60 * 60, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                AudioRetention.clean(root: self.root)
            }
        }
        scheduleInteractiveTimer(retentionTimer)
        self.retentionTimer = retentionTimer

        menuBar.onDownloadModels = { [weak self] in
            guard let self else { return }
            menuBar.showModelDownloadOffer(false)
            Task { [models] in await models.fetchIfNeeded(force: true) }
        }
        menuBar.onSettings = { [weak self] in self?.showSettings() }
        menuBar.onCheckForUpdates = { [weak self] in self?.updater.checkForUpdates() }
        updater.shouldPostponeRelaunch = { [weak self] in
            guard let self else { return false }
            return isStarting || session != nil || stoppingTask != nil
        }
        companion.onRecord = { [weak self] token in
            self?.startDetectedCall(promptToken: token.uuidString)
        }
        companion.onReadyDismissed = { [weak self] in
            self?.pendingReadySession = nil
        }
        companion.onStop = { [weak self] in self?.requestStopSession() }
        companion.onDismiss = { [weak self] in self?.companionDismissed() }
        companion.onReviewTranscript = { [weak self] session in
            self?.pendingReadySession = nil
            self?.companion.handle(.reset)
            self?.reviewTranscript(at: session)
        }
        companion.onVisibilityChanged = { [weak self] visible in
            self?.menuBar.updateCompanionVisible(visible)
        }

        Task { [models] in
            await models.setStatusHandler { status in
                Task { @MainActor [weak self] in self?.showModelDownload(status) }
            }
            await models.fetchIfNeeded()
        }

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.setCompletionHandler { dir in
                Task { @MainActor [weak self] in self?.transcriptFinished(dir) }
            }
            await AudioFinalizer.shared.recoverPending(in: root)
            await transcription.resumePending(root: root)
        }

        let callObserver = CallObservationController(
            includeUnknown: true,
            printSnapshots: false,
            log: try? CallDetectionLog(path: CallDetectionLog.defaultPath),
            onStarted: { [weak self] application in self?.callStarted(application) },
            onEnded: { [weak self] application in self?.callEnded(application) }
        )
        callObserver.start()
        self.callObserver = callObserver
    }

    /// Stop from the Stop Recording button on a notification.
    func stopFromNotification() { requestStopSession() }

    func startDetectedCall(promptToken: String) {
        guard
            let application = promptedCallApplication,
            promptedCallToken?.uuidString == promptToken,
            callObserver?.activeApplications.contains(application) == true,
            session == nil,
            !isStarting
        else { return }
        promptedCallApplication = nil
        promptedCallToken = nil
        companion.handle(.startRequested(application))
        startSession(boundTo: application, token: UUID())
    }

    func stopDetectedCall(recordingToken: String) {
        guard
            self.recordingCallToken?.uuidString == recordingToken,
            let application = recordingCallApplication,
            callObserver?.activeApplications.contains(application) == false
        else { return }
        requestStopSession()
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        callObserver?.stop()
        retentionTimer?.invalidate()
        let stoppingTask = beginStoppingSession()
        Task {
            await stoppingTask?.value
            NSApp.terminate(nil)
        }
    }

    private func toggle() {
        guard !isStarting else { return }
        if session == nil {
            promptedCallApplication = nil
            promptedCallToken = nil
            companion.handle(.startRequested(nil))
            startSession(boundTo: nil, token: nil)
        } else {
            requestStopSession()
        }
    }

    private func startSession(boundTo application: CallApplication?, token: UUID?) {
        startingCallApplication = application
        startingCallToken = token
        isStarting = true
        menuBar.updateStarting()
        // Let the NSMenu action return and AppKit paint the acknowledgement
        // before audio-device attachment occupies the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.attachSession()
        }
    }

    private func attachSession() {
        guard isStarting else { return }
        Notifier.shared.requestAuthorizationOnce()
        guard canReachRoot() else {
            isStarting = false
            startingCallApplication = nil
            startingCallToken = nil
            refreshMenuStatus()
            notifyUser(
                title: "Can't reach the recordings folder",
                body: "macOS is blocking access to \(root.path). Use Change "
                    + "Recordings Folder… in the menu to grant it."
            )
            companion.handle(.reset)
            updater.resumePostponedRelaunchIfPossible()
            return
        }
        do {
            let newSession = try RecordingSession(root: root)
            // No buttons: at thirty seconds the useful response is physical,
            // and "stop recording" is wrong advice while the other track is
            // still good.
            newSession.onTrackDead = { title, body in
                notifyUser(title: title, body: body)
            }
            newSession.onEveryoneGone = {
                notifyUser(
                    title: "Still recording",
                    body: "No one has spoken for 10 minutes. Is the meeting over?",
                    stopButton: true
                )
            }
            newSession.onAllArchivesFailed = { [weak self] in
                self?.requestStopSession()
            }
            try newSession.start()
            session = newSession
            recordingCallApplication = startingCallApplication
            recordingCallToken = startingCallToken
            companion.handle(.recordingStarted(recordingCallApplication))
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            isStarting = false
            startingCallApplication = nil
            startingCallToken = nil
            refreshMenuStatus()
            // The raw error goes to stderr and the log. What reaches someone
            // about to start a meeting is the thing they can act on.
            notifyUser(
                title: "Recording failed",
                body: """
                    Quill couldn't start recording. Check Microphone and \
                    Screen & System Audio Recording permissions.
                    """
            )
            companion.handle(.reset)
            updater.resumePostponedRelaunchIfPossible()
            return
        }

        isStarting = false
        startingCallApplication = nil
        startingCallToken = nil
        updater.resumePostponedRelaunchIfPossible()
        refreshMenuStatus()
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        scheduleInteractiveTimer(ticker)
        self.ticker = ticker
    }

    private func stopSession() async {
        guard let session else { return }
        let dir = session.dir
        processingSession = dir
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)
        menuBar.updateTranscription("Finishing audio…")

        var hasRecordedAudio = true
        do {
            hasRecordedAudio = try await session.stop()
        } catch {
            FileHandle.standardError.write(Data(
                "recording metadata publication failed: \(error)\n".utf8
            ))
            notifyUser(
                title: "Recording needs recovery",
                body: "The audio is safe. Quill will recover it before processing."
            )
        }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        recordingCallApplication = nil
        recordingCallToken = nil

        guard hasRecordedAudio else {
            processingSession = nil
            companion.handle(.reset)
            return
        }

        Task { [weak self, transcription] in
            do {
                try await AudioFinalizer.shared.finalize(session: dir)
            } catch {
                FileHandle.standardError.write(Data(
                    "audio finalization failed for \(dir.path): \(error)\n".utf8
                ))
                notifyUser(
                    title: "Couldn't finish meeting audio",
                    body: "The source recording is safe. Quill will try again later."
                )
            }
            self?.companion.handle(.finalizationFinished)
            await transcription.enqueue(dir)
        }
    }

    private func requestStopSession() {
        _ = beginStoppingSession()
    }

    private func beginStoppingSession() -> Task<Void, Never>? {
        if let stoppingTask { return stoppingTask }
        guard session != nil else { return nil }
        companion.handle(.stopRequested)
        let task = Task { [weak self] in
            guard let self else { return }
            await stopSession()
            stoppingTask = nil
            updater.resumePostponedRelaunchIfPossible()
        }
        stoppingTask = task
        return task
    }

    private func callStarted(_ application: CallApplication) {
        if recordingCallApplication == application, let recordingCallToken {
            Notifier.shared.removeCallEnded(recordingToken: recordingCallToken)
            companion.handle(.callRecovered(application))
        }
        guard session == nil, !isStarting, promptedCallApplication == nil else { return }
        let promptToken = UUID()
        promptedCallApplication = application
        promptedCallToken = promptToken
        Notifier.shared.requestAuthorizationOnce()
        companion.handle(.callDetected(application, token: promptToken))
    }

    private func callEnded(_ application: CallApplication) {
        if promptedCallApplication == application {
            promptedCallApplication = nil
            promptedCallToken = nil
            companion.handle(.callEnded(application))
        }
        guard
            session != nil,
            recordingCallApplication == application,
            recordingCallToken != nil
        else { return }
        companion.handle(.callEnded(application))
    }

    private func showModelDownload(_ status: ModelDownload.Status) {
        settings?.updateModelDownload(status)
        switch status {
        case .idle:
            menuBar.showModelDownloadOffer(false)
            menuBar.updateTranscription(nil)
        case .downloading(let fraction):
            menuBar.showModelDownloadOffer(false)
            menuBar.updateTranscription(
                "Downloading transcription models — \(Int(fraction * 100))%"
            )
        case .waitingForNetwork:
            menuBar.showModelDownloadOffer(true)
            menuBar.updateTranscription("Transcription models not downloaded")
        case .failed:
            menuBar.showModelDownloadOffer(true)
            menuBar.updateTranscription("Model download failed", failed: false)
        }
    }

    private func showSettings() {
        if settings == nil {
            let settings = SettingsWindowController()
            settings.recordingsPath = { [weak self] in self?.root.path ?? "" }
            settings.onChangeRecordingsFolder = { [weak self] in self?.changeFolder() }
            settings.onRetentionChanged = { [weak self] in
                guard let self else { return }
                AudioRetention.clean(root: self.root)
            }
            settings.onDownloadModels = { [weak self] in
                guard let self else { return }
                Task { [models] in await models.fetchIfNeeded(force: true) }
            }
            settings.onRemoveModels = { [weak self] in
                guard let self else { return }
                Task { [models] in await models.removeCached() }
            }
            self.settings = settings
        }
        settings?.show()
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            failedSession = nil
            menuBar.updateTranscription(nil)
        case .preparing:
            failedSession = nil
            menuBar.updateTranscription("Preparing transcription model…")
        case .transcribing(let name, let queued):
            failedSession = nil
            menuBar.updateTranscription(
                queued > 0 ? "Transcribing \(name) — \(queued) queued" : "Transcribing \(name)"
            )
        case .separatingSpeakers(let name, let queued):
            failedSession = nil
            menuBar.updateTranscription(
                queued > 0
                    ? "Separating speakers in \(name) — \(queued) queued"
                    : "Separating speakers in \(name)"
            )
        case .failed(let name, let dir):
            failedSession = dir
            menuBar.updateTranscription("Transcription failed — \(name)", failed: true)
            if processingSession == dir {
                processingSession = nil
                companion.handle(.reset)
            }
        }
    }

    private func tick() {
        refreshMenuStatus()
    }

    private func refreshMenuStatus() {
        if isStarting {
            menuBar.updateStarting()
            return
        }
        guard let session else {
            menuBar.update(recording: false, elapsed: nil)
            return
        }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt)),
            trouble: session.trouble,
            degraded: session.isDegraded
        )
        companion.handle(.elapsed(Self.format(Date().timeIntervalSince(session.startedAt))))
    }

    private func transcriptFinished(_ dir: URL) {
        guard processingSession == dir, session == nil else {
            if processingSession == dir {
                processingSession = nil
            }
            notifyTranscriptReady(dir)
            return
        }
        processingSession = nil
        guard companion.isVisible else {
            companion.handle(.reset)
            notifyTranscriptReady(dir)
            return
        }
        pendingReadySession = dir
        companion.handle(.transcriptReady(dir))
    }

    private func companionDismissed() {
        pendingReadySession = nil
    }

    private func notifyTranscriptReady(_ session: URL) {
        Notifier.shared.postTranscriptReady(session: session)
    }

    /// Newest session holding a transcript. Re-derived from disk rather than
    /// remembered, so it survives a restart and reflects a transcript that
    /// finished while the menu was closed.
    private func lastTranscript() -> URL? {
        let sessions = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        return sessions
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .lazy
            .map { $0.appendingPathComponent("transcript.md") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func openLastTranscript() {
        guard let transcript = lastTranscript() else { return }
        let session = transcript.deletingLastPathComponent()
        Task {
            try? await AudioFinalizer.shared.finalize(session: session)
        }
        NSWorkspace.shared.open(transcript)
    }

    private func voiceReviewSession() -> URL? {
        guard let transcript = lastTranscript() else { return nil }
        let session = transcript.deletingLastPathComponent()
        return TranscriptStore(session: session).isReviewable ? session : nil
    }

    private func chooseRecordingToReview() {
        guard session == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Review"
        panel.message = "Choose a recording to review its transcript."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        guard TranscriptStore(session: chosen).isReviewable else {
            let alert = NSAlert()
            alert.messageText = "This recording can’t be reviewed"
            alert.informativeText = "Choose a Quill recording folder that contains a compatible completed transcript."
            alert.runModal()
            return
        }
        reviewTranscript(at: chosen)
    }

    func reviewTranscript(at session: URL) {
        if voiceReview?.sessionURL == session {
            voiceReview?.show()
            return
        }
        do {
            let controller = try VoiceReviewWindowController(
                session: session,
                isRecording: { [weak self] in self?.session != nil },
                separateSpeakers: { [transcription] tracks, speakerCount, progress in
                    try await transcription.separateSpeakers(
                        in: session,
                        tracks: tracks,
                        speakerCount: speakerCount,
                        progress: progress
                    )
                }
            )
            voiceReview = controller
            controller.show()
        } catch {
            notifyUser(title: "Voice review unavailable", body: error.localizedDescription)
        }
    }

    /// The open panel is not only a convenience: a folder chosen through it is
    /// granted by macOS, which is the only way a menu-bar app can reach a
    /// protected location. There is no window to hang a permission prompt on,
    /// so an unreachable folder otherwise fails silently forever.
    private func changeFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Use Folder"
        panel.message = "Where should Quill save recordings and transcripts?"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        Config.setRecordingsDir(chosen)
        root = chosen
        AudioRetention.clean(root: chosen)
        Task { [transcription] in await transcription.resumePending(root: chosen) }
    }

    /// A TCC-blocked folder stays writable while listing it returns nothing,
    /// so this is the operation that actually tells you whether the app can
    /// see its own recordings.
    private func canReachRoot() -> Bool {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) != nil
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
