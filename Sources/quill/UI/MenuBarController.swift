import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory`, with no dock icon).
///
/// Wording and structure follow docs/ux.md: commands in title case, status
/// lines in sentence case.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let troubleLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let lastTranscriptItem: NSMenuItem
    private let retryItem: NSMenuItem
    private let downloadModelsItem: NSMenuItem
    private let micVoicesItem: NSMenuItem
    private let systemVoicesItem: NSMenuItem
    private let echoItem: NSMenuItem
    private let transcribeItem: NSMenuItem
    private let openFolderItem: NSMenuItem
    private let changeFolderItem: NSMenuItem
    private let quitItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onChangeFolder: (() -> Void)?
    var onOpenLastTranscript: (() -> Void)?
    var onOpenFailureLog: (() -> Void)?
    var onRetryTranscription: (() -> Void)?
    var onDownloadModels: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Whether a transcript exists to open, re-asked each time the menu opens
    /// rather than tracked, since transcription finishes on its own schedule.
    var hasTranscript: (() -> Bool)?

    /// Reported in the state line rather than as its own row: it is a
    /// condition, not a command, and Change Recordings Folder… below is the
    /// action that fixes it.
    private var folderUnreadable = false

    /// Where recordings land. Shown as a tooltip rather than a setting: it is
    /// worth knowing and rarely worth changing.
    var recordingsPath: (() -> String)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "Quill is idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        troubleLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        troubleLabel.isEnabled = false
        troubleLabel.isHidden = true
        menu.addItem(troubleLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        retryItem = NSMenuItem(
            title: "Retry Transcription",
            action: #selector(retryClicked),
            keyEquivalent: ""
        )
        retryItem.isHidden = true
        menu.addItem(retryItem)

        // Absent unless quill cannot get the models on its own: a metered
        // connection it will not spend, or a download that failed.
        downloadModelsItem = NSMenuItem(
            title: "Download Transcription Models",
            action: #selector(downloadModelsClicked),
            keyEquivalent: ""
        )
        downloadModelsItem.toolTip = """
            About 600 MB, once. Quill normally fetches these on its own, but \
            not over a metered connection.
            """
        downloadModelsItem.isHidden = true
        menu.addItem(downloadModelsItem)

        menu.addItem(.separator())

        // No key equivalents except Quit: a menu shortcut only fires while the
        // menu is open, so advertising one promises a hotkey that cannot work
        // from inside the meeting being recorded.
        toggleItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(toggleClicked),
            keyEquivalent: ""
        )
        menu.addItem(toggleItem)

        lastTranscriptItem = NSMenuItem(
            title: "Open Last Transcript",
            action: #selector(openLastTranscriptClicked),
            keyEquivalent: ""
        )
        menu.addItem(lastTranscriptItem)

        openFolderItem = NSMenuItem(
            title: "Open Recordings Folder",
            action: #selector(openFolderClicked),
            keyEquivalent: ""
        )
        menu.addItem(openFolderItem)

        // Choosing a folder through the open panel is also what grants access
        // to a protected location, so this appears beside the visible folder
        // failure rather than occupying the operational menu permanently.
        changeFolderItem = NSMenuItem(
            title: "Change Recordings Folder…",
            action: #selector(changeFolderClicked),
            keyEquivalent: ""
        )
        changeFolderItem.toolTip = """
            Pick where recordings are saved. Choosing a folder here is also how \
            macOS grants access to protected places like Documents.
            """
        changeFolderItem.isHidden = true
        menu.addItem(changeFolderItem)

        menu.addItem(.separator())

        echoItem = NSMenuItem(
            title: "Cancel Echo from Speakers",
            action: #selector(echoClicked),
            keyEquivalent: ""
        )
        echoItem.toolTip = """
            Stops meeting audio bleeding into your microphone when you are not \
            wearing headphones. Costs about 8 dB on the system audio track, \
            which is usually the worse trade. Applies to the next recording.
            """
        menu.addItem(echoItem)

        // Ordered by the pipeline: what gets captured, then whether it is
        // transcribed, then how the transcript is labelled. Transcription is
        // the master switch for the two below it, so it cannot sit under them.
        transcribeItem = NSMenuItem(
            title: "Transcribe After Recording",
            action: #selector(transcribeClicked),
            keyEquivalent: ""
        )
        transcribeItem.toolTip = """
            Off means quill records only. Turning it back on transcribes the \
            backlog the next time Quill starts.
            """
        menu.addItem(transcribeItem)

        // The tracks are independent: a remote call wants the far side split,
        // an in-person meeting wants the room. Titles name the situation, since
        // "microphone" and "system audio" don't describe the choice being made.
        // The shared prefix is deliberate: they are a matched pair, and being
        // adjacent is what tells them apart.
        micVoicesItem = NSMenuItem(
            title: "Separate Voices in the Room",
            action: #selector(micVoicesClicked),
            keyEquivalent: ""
        )
        micVoicesItem.toolTip = """
            Labels each person on your microphone track separately, for \
            in-person meetings. Downloads a second on-device model the first \
            time.
            """
        menu.addItem(micVoicesItem)

        systemVoicesItem = NSMenuItem(
            title: "Separate Voices on the Call",
            action: #selector(systemVoicesClicked),
            keyEquivalent: ""
        )
        systemVoicesItem.toolTip = """
            Labels each person on the call separately, for group calls. \
            Downloads a second on-device model the first time.
            """
        menu.addItem(systemVoicesItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(settingsClicked),
            keyEquivalent: ""
        )
        menu.addItem(settings)

        let about = NSMenuItem(
            title: "About Quill",
            action: #selector(aboutClicked),
            keyEquivalent: ""
        )
        menu.addItem(about)

        quitItem = NSMenuItem(
            title: "Quit Quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        super.init()

        for item in [
            toggleItem, openFolderItem, changeFolderItem, quitItem, micVoicesItem,
            systemVoicesItem,
            echoItem, transcribeItem, lastTranscriptItem, about, retryItem,
            downloadModelsItem,
            transcriptionLabel,
            settings,
        ] {
            item.target = self
        }

        menu.delegate = self
        statusItem.menu = menu
        // Keeps the item where the user dragged it, across launches.
        statusItem.autosaveName = "com.mattdoran.quill.status"
        refreshSettings()

        if let button = statusItem.button {
            button.image = Self.featherImage()
            button.imagePosition = .imageLeft
            // Monospaced digits: proportional ones reflow width every tick,
            // making the icon jiggle as the counter updates.
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular
            )
        }
    }

    /// Reflect recording state in the icon, the counter next to it, and menu
    /// item titles. The counter runs in the status bar itself, not just the
    /// menu's state label, so the state is readable without opening anything.
    /// Call once a second while recording.
    ///
    /// `trouble` is the session's record of what went wrong and stays in the
    /// menu; `degraded` is whether a track is down right now and drives the
    /// icon, so it stops warning about a fault already recovered from.
    ///
    /// The three states differ in shape, not just tint: nothing in the macOS
    /// menu bar animates, and colour alone is one state to a colourblind user
    /// in the strip of screen with the least contrast to work with.
    func update(
        recording: Bool, elapsed: String?, trouble: String? = nil, degraded: Bool = false
    ) {
        precondition(!recording || elapsed != nil)
        toggleItem.isEnabled = true
        let clock = elapsed ?? "0:00"
        stateLabel.title =
            recording
            ? "Recording — \(clock)"
            : (folderUnreadable ? "Can't read the recordings folder" : "Quill is idle")
        toggleItem.title = recording ? "Stop Recording" : "Start Recording"
        // Naming the consequence beats a confirmation sheet from an app with
        // no window to put one in front of.
        quitItem.title = recording ? "Stop Recording and Quit" : "Quit Quill"
        statusItem.button?.title = recording ? " \(clock)" : ""

        troubleLabel.title = trouble ?? ""
        troubleLabel.isHidden = trouble == nil

        guard let button = statusItem.button else { return }
        switch (recording, degraded) {
        case (false, _):
            button.image = Self.featherImage()
            button.contentTintColor = nil
            button.setAccessibilityTitle("Quill, idle")
        case (true, false):
            button.image = Self.symbol("record.circle.fill", "recording")
            button.contentTintColor = .systemRed
            button.setAccessibilityTitle("Quill, recording, \(Self.spoken(clock))")
        case (true, true):
            button.image = Self.symbol("exclamationmark.triangle.fill", "capture problem")
            button.contentTintColor = .systemOrange
            button.setAccessibilityTitle("Quill, capture problem, \(Self.spoken(clock))")
        }
    }

    func updateStarting() {
        stateLabel.title = "Starting recording…"
        toggleItem.title = "Starting Recording…"
        toggleItem.isEnabled = false
        quitItem.title = "Quit Quill"
        statusItem.button?.title = ""
        troubleLabel.title = ""
        troubleLabel.isHidden = true

        guard let button = statusItem.button else { return }
        button.image = Self.symbol("record.circle", "starting recording")
        button.contentTintColor = nil
        button.setAccessibilityTitle("Quill, starting recording")
    }

    /// Show transcription progress/failure as a status line in the menu; nil
    /// hides it. Independent of recording state — a new recording can run
    /// while the last one transcribes.
    /// A failure is a dead end unless you can act on it, so that line becomes
    /// clickable and grows a Retry beneath it. Everything else is status.
    /// macOS denies a login item access to Documents, Desktop and Downloads
    /// without ever prompting, and the folder stays writable while listing it
    /// returns nothing. Saying so in the menu is the only place the user will
    /// see it.
    func showFolderProblem(_ hasProblem: Bool) {
        folderUnreadable = hasProblem
        changeFolderItem.isHidden = !hasProblem
    }

    /// Shown only when quill needs the user to decide, which is why it is a
    /// hidden item rather than a permanent command.
    func showModelDownloadOffer(_ show: Bool) {
        downloadModelsItem.isHidden = !show
    }

    func updateTranscription(_ text: String?, failed: Bool = false) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
        transcriptionLabel.isEnabled = failed
        transcriptionLabel.action = failed ? #selector(failureLogClicked) : nil
        retryItem.isHidden = !failed
    }

    /// Settings can change on disk while the menu is closed, so they are read
    /// back on open rather than only after a click.
    func menuWillOpen(_ menu: NSMenu) {
        refreshSettings()
        lastTranscriptItem.isEnabled = hasTranscript?() ?? false
        openFolderItem.toolTip = recordingsPath?()
    }

    // MARK: -

    /// VoiceOver reads "12:03" as a time of day; spell it out instead.
    private static func spoken(_ clock: String) -> String {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return clock }
        let minutes = parts[parts.count - 2]
        let seconds = parts[parts.count - 1]
        let hours = parts.count > 2 ? parts[0] : 0
        var said: [String] = []
        if hours > 0 { said.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { said.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        said.append("\(seconds) second\(seconds == 1 ? "" : "s")")
        return said.joined(separator: " ")
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        // Template, so the glyph follows the menu bar's appearance.
        image.isTemplate = true
        return image
    }

    /// Reads the checkmarks back from disk, so the menu agrees with what is
    /// stored rather than with whatever was last clicked.
    private func refreshSettings() {
        micVoicesItem.state = Config.speakerDetection(track: "mic").enabled ? .on : .off
        systemVoicesItem.state = Config.speakerDetection(track: "system").enabled ? .on : .off
        echoItem.state = Config.micVoiceProcessing() ? .on : .off
        let transcribing = Config.transcriptionEnabled()
        transcribeItem.state = transcribing ? .on : .off
        // Both only affect a transcript, so with transcription off they are
        // settings for something that will not run. The unchecked master
        // directly above them is the visible reason.
        micVoicesItem.isEnabled = transcribing
        systemVoicesItem.isEnabled = transcribing
    }

    /// Persists, then re-reads: a failed write leaves the checkmark where it
    /// was instead of showing a setting that isn't on disk.
    @objc private func micVoicesClicked() {
        Config.setSpeakerDetection(track: "mic", enabled: micVoicesItem.state != .on)
        refreshSettings()
    }

    @objc private func systemVoicesClicked() {
        Config.setSpeakerDetection(track: "system", enabled: systemVoicesItem.state != .on)
        refreshSettings()
    }

    @objc private func echoClicked() {
        Config.setMicVoiceProcessing(echoItem.state != .on)
        refreshSettings()
    }

    @objc private func transcribeClicked() {
        Config.setTranscriptionEnabled(transcribeItem.state != .on)
        refreshSettings()
    }

    @objc private func settingsClicked() { onSettings?() }

    @objc private func aboutClicked() {
        NSApp.activate(ignoringOtherApps: true)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let commit = info["QuillBuildCommit"] as? String
        let date = info["QuillBuildDate"] as? String
        let identity = [commit, date].compactMap { $0 }.joined(separator: ", ")
        let display = identity.isEmpty ? version : "\(version) (\(identity))"
        NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: display])
    }

    @objc private func failureLogClicked() { onOpenFailureLog?() }
    @objc private func retryClicked() { onRetryTranscription?() }
    @objc private func downloadModelsClicked() { onDownloadModels?() }
    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func changeFolderClicked() { onChangeFolder?() }
    @objc private func openLastTranscriptClicked() { onOpenLastTranscript?() }
    @objc private func quitClicked() { onQuit?() }
}
