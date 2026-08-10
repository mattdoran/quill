import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
///
/// Wording and structure follow docs/ux.md: commands in title case, status
/// lines in sentence case, and every setting explained by a tooltip rather
/// than by a settings window.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let troubleLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let lastTranscriptItem: NSMenuItem
    private let retryItem: NSMenuItem
    private let micVoicesItem: NSMenuItem
    private let systemVoicesItem: NSMenuItem
    private let echoItem: NSMenuItem
    private let transcribeItem: NSMenuItem
    private let openFolderItem: NSMenuItem
    private let loginItem: NSMenuItem
    private let quitItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onChangeFolder: (() -> Void)?
    var onOpenLastTranscript: (() -> Void)?
    var onOpenFailureLog: (() -> Void)?
    var onRetryTranscription: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Whether a transcript exists to open, re-asked each time the menu opens
    /// rather than tracked, since transcription finishes on its own schedule.
    var hasTranscript: (() -> Bool)?

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

        lastTranscriptItem = NSMenuItem(
            title: "Open Last Transcript",
            action: #selector(openLastTranscriptClicked),
            keyEquivalent: ""
        )
        menu.addItem(lastTranscriptItem)

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

        openFolderItem = NSMenuItem(
            title: "Open Recordings Folder",
            action: #selector(openFolderClicked),
            keyEquivalent: ""
        )
        menu.addItem(openFolderItem)

        // Visible rather than hidden behind an option-click: choosing a folder
        // through the open panel is also what grants access to a protected
        // location, so it is the fix for a permission problem, not a
        // preference for power users.
        let changeFolder = NSMenuItem(
            title: "Change Recordings Folder…",
            action: #selector(changeFolderClicked),
            keyEquivalent: ""
        )
        changeFolder.toolTip = """
            Pick where recordings are saved. Choosing a folder here is also how \
            macOS grants access to protected places like Documents.
            """
        menu.addItem(changeFolder)

        menu.addItem(.separator())

        // The tracks are independent: a remote call wants the far side split,
        // an in-person meeting wants the room. Titles name the situation, since
        // "microphone" and "system audio" don't describe the choice being made.
        // Both sit at the top level — a setting worth changing per meeting
        // shouldn't cost a hover and a second click to reach or to read.
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

        menu.addItem(.separator())

        loginItem = NSMenuItem(
            title: "Open at Login",
            action: #selector(loginItemClicked),
            keyEquivalent: ""
        )
        loginItem.toolTip = """
            Quill starts hidden in the menu bar when you log in. macOS also \
            lists it under System Settings → General → Login Items.
            """
        menu.addItem(loginItem)

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
            toggleItem, openFolderItem, changeFolder, quitItem, micVoicesItem, systemVoicesItem,
            echoItem, transcribeItem, lastTranscriptItem, about, retryItem, loginItem,
            transcriptionLabel,
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
        let clock = elapsed ?? "0:00"
        stateLabel.attributedTitle = Self.status(
            recording ? "Recording — \(clock)" : "Quill is idle"
        )
        toggleItem.title = recording ? "Stop Recording" : "Start Recording"
        // Naming the consequence beats a confirmation sheet from an app with
        // no window to put one in front of.
        quitItem.title = recording ? "Stop Recording and Quit" : "Quit Quill"
        // Echo cancellation is applied when the mic graph is built, so a
        // mid-recording change would silently not take effect.
        echoItem.isEnabled = !recording
        statusItem.button?.title = recording ? " \(clock)" : ""

        troubleLabel.attributedTitle = Self.status(trouble ?? "", color: .systemOrange)
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

    /// Show transcription progress/failure as a status line in the menu; nil
    /// hides it. Independent of recording state — a new recording can run
    /// while the last one transcribes.
    /// A failure is a dead end unless you can act on it, so that line becomes
    /// clickable and grows a Retry beneath it. Everything else is status.
    func updateTranscription(_ text: String?, failed: Bool = false) {
        transcriptionLabel.attributedTitle = Self.status(
            text ?? "", color: failed ? .systemOrange : .labelColor
        )
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

    /// Disabled items render grey, which would leave the line the user opened
    /// the menu to read as the dimmest text in it.
    private static func status(
        _ text: String, color: NSColor = .labelColor
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.menuFont(ofSize: 0),
        ])
    }

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
    /// stored rather than with whatever was last clicked. State wins over
    /// config wherever it has an opinion.
    private func refreshSettings() {
        micVoicesItem.state = Config.speakerDetection(track: "mic").enabled ? .on : .off
        systemVoicesItem.state = Config.speakerDetection(track: "system").enabled ? .on : .off
        echoItem.state = Config.micVoiceProcessing() ? .on : .off
        transcribeItem.state = Config.transcriptionEnabled() ? .on : .off
        // Asked of the system rather than remembered, so revoking it in
        // System Settings is reflected here.
        loginItem.state = LoginItem.isEnabled ? .on : .off
        loginItem.isEnabled = LoginItem.isAvailable
    }

    /// Persists, then re-reads: a failed write leaves the checkmark where it
    /// was instead of showing a setting that isn't on disk.
    @objc private func micVoicesClicked() {
        State.setSpeakerDetection(track: "mic", enabled: micVoicesItem.state != .on)
        refreshSettings()
    }

    @objc private func systemVoicesClicked() {
        State.setSpeakerDetection(track: "system", enabled: systemVoicesItem.state != .on)
        refreshSettings()
    }

    @objc private func echoClicked() {
        State.setMicVoiceProcessing(echoItem.state != .on)
        refreshSettings()
    }

    @objc private func transcribeClicked() {
        State.setTranscriptionEnabled(transcribeItem.state != .on)
        refreshSettings()
    }

    @objc private func loginItemClicked() {
        LoginItem.setEnabled(loginItem.state != .on)
        refreshSettings()
    }

    @objc private func aboutClicked() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func failureLogClicked() { onOpenFailureLog?() }
    @objc private func retryClicked() { onRetryTranscription?() }
    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func changeFolderClicked() { onChangeFolder?() }
    @objc private func openLastTranscriptClicked() { onOpenLastTranscript?() }
    @objc private func quitClicked() { onQuit?() }
}
