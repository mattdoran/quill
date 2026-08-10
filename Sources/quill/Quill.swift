import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self, Diarize.self],
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
    private let transcription = TranscriptionCoordinator()
    private let models = ModelDownload()
    private var settings: SettingsWindowController?
    private var session: RecordingSession?
    private var ticker: Timer?
    private var retentionTimer: Timer?

    /// The session whose transcription failed, so its log can be opened and
    /// the job re-queued without quitting the app.
    private var failedSession: URL?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onOpenLastTranscript = { [weak self] in self?.openLastTranscript() }
        menuBar.hasTranscript = { [weak self] in
            guard let self else { return false }
            // Checked here rather than on a timer: the menu opening is the
            // only moment it matters.
            let reachable = canReachRoot()
            menuBar.showFolderProblem(!reachable)
            // Refresh the state line, which is only otherwise redrawn on a tick.
            menuBar.update(recording: session != nil, elapsed: nil)
            return reachable && lastTranscript() != nil
        }
        menuBar.recordingsPath = { [weak self] in self?.root.path ?? "" }
        menuBar.onChangeFolder = { [weak self] in self?.changeFolder() }
        menuBar.onOpenFailureLog = { [weak self] in
            guard let dir = self?.failedSession else { return }
            NSWorkspace.shared.open(dir.appendingPathComponent("transcribe.log"))
        }
        menuBar.onRetryTranscription = { [weak self] in
            guard let self, let dir = failedSession else { return }
            failedSession = nil
            menuBar.updateTranscription(nil)
            Task { [transcription] in await transcription.enqueue(dir) }
        }
        menuBar.update(recording: false, elapsed: nil)

        AudioRetention.clean(root: root)
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                AudioRetention.clean(root: self.root)
            }
        }

        menuBar.onDownloadModels = { [weak self] in
            guard let self else { return }
            menuBar.showModelDownloadOffer(false)
            Task { [models] in await models.fetchIfNeeded(force: true) }
        }
        menuBar.onSettings = { [weak self] in self?.showSettings() }

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
            await transcription.resumePending(root: root)
        }
    }

    /// Stop from the Stop Recording button on a notification.
    func stopFromNotification() { stopSession() }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        retentionTimer?.invalidate()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        Notifier.shared.requestAuthorizationOnce()
        guard canReachRoot() else {
            notifyUser(
                title: "Can't reach the recordings folder",
                body: "macOS is blocking access to \(root.path). Use Change "
                    + "Recordings Folder… in the menu to grant it."
            )
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
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            // The raw error goes to stderr and the log. What reaches someone
            // about to start a meeting is the thing they can act on.
            notifyUser(
                title: "Recording failed",
                body: """
                    Quill couldn't start recording. Check Microphone and \
                    Screen & System Audio Recording permissions.
                    """
            )
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
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
        case .failed(let name, let dir):
            failedSession = dir
            menuBar.updateTranscription("Transcription failed — \(name)", failed: true)
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt)),
            trouble: session.trouble,
            degraded: session.isDegraded
        )
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
        NSWorkspace.shared.open(transcript)
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
