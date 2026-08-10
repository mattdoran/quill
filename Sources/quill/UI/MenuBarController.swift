import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let micSpeakersItem: NSMenuItem
    private let systemSpeakersItem: NSMenuItem
    private var pulseDim = false

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        // The tracks are independent: a remote call wants the far side split,
        // an in-person meeting wants the room. Titles name the situation, since
        // "mic" and "system" don't describe the choice being made. Both sit at
        // the top level — a setting worth changing per meeting shouldn't cost a
        // hover and a second click to reach or to read.
        micSpeakersItem = NSMenuItem(
            title: "Detect speakers in the room",
            action: #selector(micSpeakersClicked),
            keyEquivalent: ""
        )
        menu.addItem(micSpeakersItem)

        systemSpeakersItem = NSMenuItem(
            title: "Detect speakers on the call",
            action: #selector(systemSpeakersClicked),
            keyEquivalent: ""
        )
        menu.addItem(systemSpeakersItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [
            toggleItem, openFolder, quit, micSpeakersItem, systemSpeakersItem,
        ] {
            item.target = self
        }

        statusItem.menu = menu
        refreshSpeakerDetectionState()

        if let button = statusItem.button {
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
            // Monospaced digits: proportional ones reflow width every tick,
            // making the icon jiggle as the counter updates.
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular
            )
        }
    }

    /// Reflect recording state in the icon, the counter next to it, and menu
    /// item titles. The counter runs in the status bar itself (not just the
    /// menu's state label) because a static red tint reads as decoration, not
    /// an alarm — a number that visibly counts up is what actually catches
    /// the eye on a glance. The tint pulses on the same call as the counter
    /// (not a separate timer) so the two move in lockstep instead of
    /// drifting in and out of phase. Call once a second while recording.
    ///
    /// `trouble` tints yellow: still recording, no longer assumed complete.
    func update(recording: Bool, elapsed: String?, trouble: String? = nil) {
        stateLabel.title = recording
            ? "● recording · \(elapsed ?? "0:00")\(trouble.map { " · \($0)" } ?? "")"
            : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        statusItem.button?.title = recording ? " \(elapsed ?? "0:00")" : ""
        if recording {
            pulseDim.toggle()
            let tint: NSColor = trouble == nil ? .systemRed : .systemYellow
            statusItem.button?.contentTintColor =
                tint.withAlphaComponent(pulseDim ? 0.35 : 1.0)
        } else {
            statusItem.button?.contentTintColor = nil
            pulseDim = false
        }
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
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
        return image
    }

    /// Reads the checkmarks back from the config file, so the menu agrees with
    /// a hand-edited config and not with whatever was last clicked.
    private func refreshSpeakerDetectionState() {
        micSpeakersItem.state =
            Config.speakerDetection(track: "mic").enabled ? .on : .off
        systemSpeakersItem.state =
            Config.speakerDetection(track: "system").enabled ? .on : .off
    }

    /// Persists, then re-reads: a failed write leaves the checkmark where it
    /// was instead of showing a setting that isn't on disk.
    private func setSpeakerDetection(track: String, from item: NSMenuItem) {
        State.setSpeakerDetection(track: track, enabled: item.state != .on)
        refreshSpeakerDetectionState()
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func micSpeakersClicked() {
        setSpeakerDetection(track: "mic", from: micSpeakersItem)
    }

    @objc private func systemSpeakersClicked() {
        setSpeakerDetection(track: "system", from: systemSpeakersItem)
    }
}
