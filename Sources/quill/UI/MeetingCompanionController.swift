import AppKit

@MainActor
final class MeetingCompanionController: NSObject {
    private let panel: MeetingCompanionPanel
    private let content = MeetingCompanionView()
    private(set) var state = MeetingCompanionState()
    private var display: NSScreen?

    var onRecord: ((UUID) -> Void)?
    var onStop: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onOpenTranscript: ((URL) -> Void)?
    var onProfileChanged: ((MeetingProfile) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    override init() {
        panel = MeetingCompanionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 468, height: 108),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = true
        panel.setAccessibilityLabel("Quill meeting controls")
        panel.onCancel = { [weak self] in self?.dismiss() }

        content.onAction = { [weak self] in self?.performPrimaryAction() }
        content.onDismiss = { [weak self] in self?.dismiss() }
        content.onProfileChanged = { [weak self] profile in
            self?.handle(.profileChanged(profile))
            self?.onProfileChanged?(profile)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func handle(_ event: MeetingCompanionState.Event) {
        let wasVisible = panel.isVisible
        state.handle(event)
        render()
        if panel.isVisible != wasVisible {
            onVisibilityChanged?(panel.isVisible)
        }
    }

    func showRecordingControls() {
        handle(.showControls)
    }

    func dismiss() {
        state.handle(.dismissed)
        panel.orderOut(nil)
        onDismiss?()
        onVisibilityChanged?(false)
    }

    private func render(forceVisible: Bool = false) {
        guard case .hidden = state.phase else {
            content.render(state.phase)
            positionIfNeeded()
            panel.orderFrontRegardless()
            return
        }
        if forceVisible {
            content.render(state.phase)
            positionIfNeeded()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func positionIfNeeded() {
        let screen = display ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        if display == nil {
            display = screen
        }
        let visible = screen.visibleFrame
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - 22
        ))
    }

    private func performPrimaryAction() {
        switch state.phase {
        case .detected(_, let token):
            onRecord?(token)
        case .recording, .possibleEnd:
            onStop?()
        case .ready(let transcript):
            onOpenTranscript?(transcript)
        case .hidden, .starting, .finalizing, .processing, .failed:
            break
        }
    }
}

@MainActor
private final class MeetingCompanionPanel: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class MeetingCompanionView: NSVisualEffectView {
    private let closeButton = NSButton()
    private let symbol = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let profileButton = NSButton()
    private let profileMenu = NSMenu()
    private let actionButton = NSButton()
    private let spinner = NSProgressIndicator()

    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onProfileChanged: ((MeetingProfile) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Dismiss meeting controls"
        )
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismissClicked)
        closeButton.toolTip = "Dismiss"

        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        symbol.contentTintColor = .labelColor

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        for profile in MeetingProfile.allCases {
            let item = NSMenuItem(
                title: profile.title,
                action: #selector(profileMenuItemClicked(_:)),
                keyEquivalent: ""
            )
            item.representedObject = profile.rawValue
            item.target = self
            profileMenu.addItem(item)
        }
        profileButton.bezelStyle = .inline
        profileButton.controlSize = .small
        profileButton.font = .systemFont(ofSize: 12, weight: .medium)
        profileButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: nil
        )
        profileButton.imagePosition = .imageTrailing
        profileButton.target = self
        profileButton.action = #selector(profileClicked)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.font = .systemFont(ofSize: 14, weight: .semibold)
        actionButton.target = self
        actionButton.action = #selector(actionClicked)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let titleStack = NSStackView(views: [titleLabel, elapsedLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .firstBaseline
        titleStack.spacing = 7
        let textStack = NSStackView(views: [titleStack, detailLabel, profileButton])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [closeButton, symbol, textStack, spinner, actionButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 34),
            symbol.heightAnchor.constraint(equalToConstant: 34),

            textStack.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -12),

            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -12),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 88),
            actionButton.heightAnchor.constraint(equalToConstant: 38),
        ])

        applyAccessibilityOptions(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func render(_ phase: MeetingCompanionState.Phase) {
        profileButton.isHidden = true
        elapsedLabel.isHidden = true
        spinner.stopAnimation(nil)
        actionButton.isHidden = false
        actionButton.isEnabled = true
        detailLabel.isHidden = false
        symbol.contentTintColor = .labelColor

        switch phase {
        case .hidden:
            break
        case .detected(let application, _):
            setSymbol("video.badge.waveform", description: "Meeting detected")
            titleLabel.stringValue = "Meeting detected"
            detailLabel.stringValue = application.name
            actionButton.title = "Record"
            actionButton.keyEquivalent = "\r"
            setAccessibility(title: "Meeting detected", detail: application.name)
        case .starting(let application):
            setSymbol("record.circle", description: "Starting recording")
            titleLabel.stringValue = "Starting recording"
            detailLabel.stringValue = application?.name ?? ""
            detailLabel.isHidden = application == nil
            actionButton.isHidden = true
            spinner.startAnimation(nil)
            setAccessibility(title: "Starting recording", detail: application?.name)
        case .recording(let application, let elapsed, let profile, let visible):
            setSymbol("record.circle.fill", description: "Recording")
            symbol.contentTintColor = .systemRed
            titleLabel.stringValue = "Recording"
            elapsedLabel.stringValue = elapsed
            elapsedLabel.isHidden = false
            detailLabel.stringValue = application?.name ?? "Microphone and computer audio"
            actionButton.title = "Stop"
            actionButton.keyEquivalent = ""
            configureProfile(profile, visible: visible)
            setAccessibility(title: "Recording, \(elapsed)", detail: application?.name)
        case .possibleEnd(let application, let elapsed, let profile, let visible):
            setSymbol("questionmark.circle", description: "Meeting may have ended")
            titleLabel.stringValue = "Meeting ended?"
            detailLabel.stringValue = "Recording \(elapsed) · \(application.name)"
            actionButton.title = "Stop"
            actionButton.keyEquivalent = ""
            configureProfile(profile, visible: visible)
            setAccessibility(
                title: "Meeting ended? Still recording, \(elapsed)",
                detail: application.name
            )
        case .finalizing:
            setSymbol("waveform.badge.checkmark", description: "Saving recording")
            titleLabel.stringValue = "Saving recording…"
            detailLabel.isHidden = true
            actionButton.isHidden = true
            spinner.startAnimation(nil)
            setAccessibility(title: "Saving recording", detail: nil)
        case .processing:
            setSymbol("text.page", description: "Creating transcript")
            titleLabel.stringValue = "Creating transcript…"
            detailLabel.isHidden = true
            actionButton.isHidden = true
            spinner.startAnimation(nil)
            setAccessibility(title: "Creating transcript", detail: nil)
        case .ready(let transcript):
            setSymbol("checkmark.circle.fill", description: "Transcript ready")
            symbol.contentTintColor = .systemGreen
            titleLabel.stringValue = "Transcript ready"
            detailLabel.stringValue = SessionName.spoken(transcript.deletingLastPathComponent())
            actionButton.title = "Open"
            actionButton.keyEquivalent = "\r"
            setAccessibility(title: "Transcript ready", detail: detailLabel.stringValue)
        case .failed(let message):
            setSymbol("exclamationmark.triangle.fill", description: "Quill needs attention")
            symbol.contentTintColor = .systemOrange
            titleLabel.stringValue = "Quill needs attention"
            detailLabel.stringValue = message
            actionButton.isHidden = true
            setAccessibility(title: "Quill needs attention", detail: message)
        }
    }

    private func configureProfile(_ profile: MeetingProfile, visible: Bool) {
        profileButton.isHidden = !visible
        profileButton.title = "Voices: \(profile.title)"
        profileButton.setAccessibilityLabel("Separate voices")
        profileButton.setAccessibilityValue(profile.title)
        for item in profileMenu.items {
            item.state = item.representedObject as? String == profile.rawValue ? .on : .off
        }
    }

    func applyAccessibilityOptions(reduceTransparency: Bool, increaseContrast: Bool) {
        layer?.backgroundColor = reduceTransparency
            ? NSColor.windowBackgroundColor.cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = increaseContrast ? 1 : 0
        layer?.borderColor = increaseContrast ? NSColor.separatorColor.cgColor : nil
    }

    func visibleControlsFitBounds() -> Bool {
        [closeButton, symbol, titleLabel, elapsedLabel, detailLabel, profileButton, actionButton]
            .filter { !$0.isHidden }
            .allSatisfy { bounds.contains($0.convert($0.bounds, to: self)) }
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        applyAccessibilityOptions(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }

    private func setSymbol(_ name: String, description: String) {
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    private func setAccessibility(title: String, detail: String?) {
        setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
    }

    @objc private func actionClicked() { onAction?() }
    @objc private func dismissClicked() { onDismiss?() }

    @objc private func profileClicked() {
        let selected = profileMenu.items.first(where: { $0.state == .on })
        let point = NSPoint(x: profileButton.bounds.minX, y: profileButton.bounds.minY - 4)
        profileMenu.popUp(positioning: selected, at: point, in: profileButton)
    }

    @objc private func profileMenuItemClicked(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let profile = MeetingProfile(rawValue: raw)
        else { return }
        onProfileChanged?(profile)
    }
}
