import AppKit

struct MeetingCompanionPlacement: Equatable, Sendable {
    let rightEdge: Double
    let centerY: Double
}

@MainActor
final class MeetingCompanionController: NSObject, NSWindowDelegate {
    static let expandedSize = NSSize(width: 380, height: 72)
    static let collapsedSize = NSSize(width: 40, height: 58)

    private let panel: MeetingCompanionPanel
    private let content = MeetingCompanionView()
    private(set) var state = MeetingCompanionState()
    private var display: NSScreen?
    private var hasPositioned = false
    private var isCollapsed = false
    private var collapseTask: DispatchWorkItem?
    private var detectionTimeoutTask: DispatchWorkItem?
    private var collapseGeneration = 0
    private var detectionTimeoutGeneration = 0
    private var interactionDepth = 0
    private let initialCollapseDelay: TimeInterval
    private let reopenedCollapseDelay: TimeInterval
    private let detectionTimeout: TimeInterval
    private let loadPlacement: () -> MeetingCompanionPlacement?
    private let savePlacement: (MeetingCompanionPlacement) -> Void

    var onRecord: ((UUID) -> Void)?
    var onStop: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onReadyDismissed: (() -> Void)?
    var onReviewTranscript: ((URL) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    init(
        initialCollapseDelay: TimeInterval = 3,
        reopenedCollapseDelay: TimeInterval = 8,
        detectionTimeout: TimeInterval = 12,
        loadPlacement: @escaping () -> MeetingCompanionPlacement? = { nil },
        savePlacement: @escaping (MeetingCompanionPlacement) -> Void = { _ in }
    ) {
        self.initialCollapseDelay = initialCollapseDelay
        self.reopenedCollapseDelay = reopenedCollapseDelay
        self.detectionTimeout = detectionTimeout
        self.loadPlacement = loadPlacement
        self.savePlacement = savePlacement
        panel = MeetingCompanionPanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = true
        panel.setAccessibilityLabel("Quill meeting controls")
        panel.onCancel = { [weak self] in self?.closeCompanion() }
        panel.delegate = self

        content.onAction = { [weak self] in self?.performPrimaryAction() }
        content.onDismiss = { [weak self] in self?.closeCompanion() }
        content.onExpand = { [weak self] in
            guard let self else { return }
            expandRecordingControls(after: reopenedCollapseDelay)
        }
        content.onInteractionBegan = { [weak self] in self?.beginInteraction() }
        content.onInteractionEnded = { [weak self] in self?.endInteraction() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    var isVisible: Bool { panel.isVisible }
    var presentationIsCollapsed: Bool { isCollapsed }
    var presentationFrame: NSRect { panel.frame }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func handle(_ event: MeetingCompanionState.Event) {
        let wasVisible = panel.isVisible
        state.handle(event)
        updatePresentation(for: event)
        render()
        if panel.isVisible != wasVisible {
            onVisibilityChanged?(panel.isVisible)
        }
    }

    func showRecordingControls() {
        handle(.showControls)
    }

    func dismiss() {
        let dismissedPhase = state.phase
        cancelCollapse()
        cancelDetectionTimeout()
        state.handle(.dismissed)
        panel.orderOut(nil)
        if case .ready = dismissedPhase {
            onReadyDismissed?()
        } else {
            onDismiss?()
        }
        onVisibilityChanged?(false)
    }

    func closeCompanion() {
        switch state.phase {
        case .recording:
            collapseRecordingControls()
        case .possibleEnd:
            state.handle(.keepRecording)
            collapseRecordingControls()
        default:
            dismiss()
        }
    }

    private func render(forceVisible: Bool = false) {
        guard case .hidden = state.phase else {
            if isCollapsed, case .recording(_, let elapsed) = state.phase {
                content.renderCollapsed(elapsed: elapsed)
                applyPanelSize()
            } else {
                applyPanelSize()
                content.render(state.phase)
            }
            positionIfNeeded()
            refreshShadow()
            panel.orderFrontRegardless()
            return
        }
        if forceVisible {
            content.render(state.phase)
            positionIfNeeded()
            refreshShadow()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func refreshShadow() {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
    }

    private func updatePresentation(for event: MeetingCompanionState.Event) {
        if case .callDetected = event {
            scheduleDetectionTimeout()
        } else {
            cancelDetectionTimeout()
        }
        switch event {
        case .recordingStarted:
            expandRecordingControls(after: initialCollapseDelay)
        case .showControls, .callRecovered:
            expandRecordingControls(after: reopenedCollapseDelay)
        case .keepRecording:
            break
        case .elapsed:
            break
        case .callDetected, .callEnded, .startRequested, .stopRequested,
             .finalizationFinished, .transcriptReady, .failed:
            expandRecordingControls()
        case .dismissed, .reset:
            cancelCollapse()
            isCollapsed = false
        }
    }

    private func expandRecordingControls(after delay: TimeInterval? = nil) {
        cancelCollapse()
        let wasCollapsed = isCollapsed
        isCollapsed = false
        if let delay {
            let pointerIsOverControls = interactionDepth > 0
            scheduleCollapse(
                after: pointerIsOverControls ? reopenedCollapseDelay : delay,
                evenDuringInteraction: pointerIsOverControls
            )
        }
        if panel.isVisible { render() }
        if wasCollapsed { onVisibilityChanged?(true) }
    }

    private func scheduleCollapse(
        after delay: TimeInterval,
        evenDuringInteraction: Bool = false
    ) {
        cancelCollapse()
        guard case .recording = state.phase else { return }
        let generation = collapseGeneration
        let task = DispatchWorkItem { [weak self] in
            guard
                let self,
                collapseGeneration == generation,
                case .recording = state.phase,
                evenDuringInteraction || interactionDepth == 0
            else { return }
            collapseTask = nil
            collapseRecordingControls()
        }
        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func cancelCollapse() {
        collapseGeneration += 1
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func collapseRecordingControls() {
        cancelCollapse()
        guard case .recording = state.phase else { return }
        isCollapsed = true
        render()
        onVisibilityChanged?(false)
    }

    func beginInteraction() {
        interactionDepth += 1
        if case .recording = state.phase {
            scheduleCollapse(after: reopenedCollapseDelay, evenDuringInteraction: true)
        } else {
            cancelCollapse()
        }
    }

    func endInteraction() {
        interactionDepth = max(0, interactionDepth - 1)
        if interactionDepth == 0 { scheduleCollapse(after: reopenedCollapseDelay) }
    }

    private func scheduleDetectionTimeout() {
        cancelDetectionTimeout()
        guard case .detected = state.phase else { return }
        let generation = detectionTimeoutGeneration
        let task = DispatchWorkItem { [weak self] in
            guard
                let self,
                detectionTimeoutGeneration == generation,
                case .detected = state.phase
            else { return }
            detectionTimeoutTask = nil
            dismiss()
        }
        detectionTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + detectionTimeout, execute: task)
    }

    private func cancelDetectionTimeout() {
        detectionTimeoutGeneration += 1
        detectionTimeoutTask?.cancel()
        detectionTimeoutTask = nil
    }

    private func applyPanelSize() {
        let size = isCollapsed ? Self.collapsedSize : Self.expandedSize
        guard panel.frame.size != size else { return }
        let old = panel.frame
        var frame = NSRect(
            x: old.maxX - size.width,
            y: old.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
            frame.origin.x = min(
                max(frame.minX, screen.visibleFrame.minX),
                screen.visibleFrame.maxX - frame.width
            )
            frame.origin.y = min(
                max(frame.minY, screen.visibleFrame.minY),
                screen.visibleFrame.maxY - frame.height
            )
        }
        panel.setFrame(frame, display: true)
    }

    private func positionIfNeeded() {
        if hasPositioned,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            return
        }
        if !hasPositioned, let placement = loadPlacement() {
            var frame = panel.frame
            frame.origin = NSPoint(
                x: placement.rightEdge - frame.width,
                y: placement.centerY - frame.height / 2
            )
            if let screen = NSScreen.screens.first(where: {
                $0.visibleFrame.intersects(frame)
            }) {
                display = screen
                panel.setFrame(frame, display: true)
                clampPanel(to: screen)
                hasPositioned = true
                return
            }
        }
        let retainedDisplay = display.flatMap { candidate in
            NSScreen.screens.contains(where: { $0 === candidate }) ? candidate : nil
        }
        let screen = retainedDisplay ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        if display == nil {
            display = screen
        }
        let visible = screen.visibleFrame
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - frame.width - 20,
            y: visible.maxY - frame.height - 48
        ))
        hasPositioned = true
    }

    private func performPrimaryAction() {
        switch state.phase {
        case .detected(_, let token):
            onRecord?(token)
        case .recording, .possibleEnd:
            onStop?()
        case .ready(let session):
            onReviewTranscript?(session)
        case .hidden, .starting, .finalizing, .processing, .failed:
            break
        }
    }

    func windowWillMove(_ notification: Notification) {
        cancelCollapse()
    }

    func windowDidMove(_ notification: Notification) {
        display = panel.screen ?? screenContainingPanelCenter()
        savePlacement(MeetingCompanionPlacement(
            rightEdge: panel.frame.maxX,
            centerY: panel.frame.midY
        ))
        scheduleCollapse(after: reopenedCollapseDelay)
    }

    private func screenContainingPanelCenter() -> NSScreen? {
        let centre = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(centre) })
    }

    @objc private func screenParametersChanged() {
        if let screen = screenContainingPanelCenter() {
            display = screen
            clampPanel(to: screen)
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        display = screen
        clampPanel(to: screen)
    }

    private func clampPanel(to screen: NSScreen) {
        var frame = panel.frame
        frame.origin.x = min(
            max(frame.minX, screen.visibleFrame.minX),
            screen.visibleFrame.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.minY, screen.visibleFrame.minY),
            screen.visibleFrame.maxY - frame.height
        )
        panel.setFrame(frame, display: true)
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
    private let actionButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let collapsedSymbol = NSImageView()
    private let expandButton = NSButton()
    private let timeoutBar = NSView()
    private var expandedConstraints: [NSLayoutConstraint] = []
    private var collapsedConstraints: [NSLayoutConstraint] = []
    private var isCollapsedPresentation = false
    private var dragStartLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var draggedCollapsedPill = false
    private var reduceMotion = false
    private var materialMaskSize = NSSize.zero
    private var materialMaskRadius: CGFloat = 0

    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onExpand: (() -> Void)?
    var onInteractionBegan: (() -> Void)?
    var onInteractionEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        refreshMaterialMask(radius: 18)

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

        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        symbol.contentTintColor = .labelColor

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.font = .systemFont(ofSize: 13, weight: .semibold)
        actionButton.target = self
        actionButton.action = #selector(actionClicked)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        collapsedSymbol.image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: nil
        )
        collapsedSymbol.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        collapsedSymbol.contentTintColor = .systemRed
        collapsedSymbol.setAccessibilityElement(false)
        collapsedSymbol.isHidden = true

        expandButton.bezelStyle = .inline
        expandButton.isBordered = false
        expandButton.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: nil
        )
        expandButton.imagePosition = .imageOnly
        expandButton.contentTintColor = .secondaryLabelColor
        expandButton.target = self
        expandButton.action = #selector(expandClicked)
        expandButton.toolTip = "Show recording controls"
        expandButton.isHidden = true

        timeoutBar.wantsLayer = true
        timeoutBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        timeoutBar.isHidden = true

        let titleStack = NSStackView(views: [titleLabel, elapsedLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .firstBaseline
        titleStack.spacing = 7
        let secondaryStack = NSStackView(views: [detailLabel])
        secondaryStack.orientation = .horizontal
        secondaryStack.alignment = .firstBaseline
        secondaryStack.spacing = 5
        let textStack = NSStackView(views: [titleStack, secondaryStack])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [closeButton, symbol, textStack, spinner, actionButton,
                     collapsedSymbol, expandButton, timeoutBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        expandedConstraints = [
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 24),
            symbol.heightAnchor.constraint(equalToConstant: 24),

            textStack.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -12),

            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -12),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 72),
            actionButton.heightAnchor.constraint(equalToConstant: 32),
        ]
        collapsedConstraints = [
            collapsedSymbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            collapsedSymbol.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            collapsedSymbol.widthAnchor.constraint(equalToConstant: 20),
            collapsedSymbol.heightAnchor.constraint(equalToConstant: 20),
            expandButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            expandButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            expandButton.widthAnchor.constraint(equalToConstant: 24),
            expandButton.heightAnchor.constraint(equalToConstant: 18),
        ]
        NSLayoutConstraint.activate(expandedConstraints)
        NSLayoutConstraint.activate([
            timeoutBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            timeoutBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            timeoutBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            timeoutBar.heightAnchor.constraint(equalToConstant: 2),
        ])

        applyAccessibilityOptions(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        isCollapsedPresentation = false
        toolTip = nil
        resetCursorRects()
        NSLayoutConstraint.deactivate(collapsedConstraints)
        NSLayoutConstraint.activate(expandedConstraints)
        layer?.cornerRadius = 18
        refreshMaterialMask(radius: 18)
        timeoutBar.layer?.removeAllAnimations()
        timeoutBar.isHidden = true
        collapsedSymbol.isHidden = true
        expandButton.isHidden = true
        closeButton.isHidden = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Dismiss meeting controls"
        )
        symbol.isHidden = false
        titleLabel.isHidden = false
        elapsedLabel.isHidden = true
        spinner.stopAnimation(nil)
        actionButton.isHidden = false
        actionButton.isEnabled = true
        detailLabel.isHidden = false
        symbol.contentTintColor = .labelColor
        closeButton.toolTip = "Dismiss"
        closeButton.setAccessibilityLabel("Dismiss meeting controls")

        switch phase {
        case .hidden:
            break
        case .detected(let application, _):
            setSymbol("video.badge.waveform", description: "Meeting detected")
            titleLabel.stringValue = "Meeting detected"
            detailLabel.stringValue = application.name
            actionButton.title = "Record"
            actionButton.keyEquivalent = "\r"
            showDetectionCountdown()
            setAccessibility(
                title: "Meeting detected",
                detail: "\(application.name). This prompt closes in 12 seconds"
            )
        case .starting(let application):
            setSymbol("record.circle", description: "Starting recording")
            titleLabel.stringValue = "Starting recording"
            detailLabel.stringValue = application?.name ?? ""
            detailLabel.isHidden = application == nil
            actionButton.isHidden = true
            closeButton.isHidden = true
            spinner.startAnimation(nil)
            setAccessibility(title: "Starting recording", detail: application?.name)
        case .recording(let application, let elapsed):
            setSymbol("circle.fill", description: "Recording")
            symbol.contentTintColor = .systemRed
            titleLabel.stringValue = "Recording"
            elapsedLabel.stringValue = elapsed
            elapsedLabel.isHidden = false
            detailLabel.stringValue = application?.name ?? ""
            detailLabel.isHidden = application == nil
            actionButton.title = "Stop"
            actionButton.keyEquivalent = ""
            closeButton.toolTip = "Collapse"
            closeButton.image = NSImage(
                systemSymbolName: "chevron.right",
                accessibilityDescription: "Collapse recording controls"
            )
            closeButton.setAccessibilityLabel("Collapse recording controls")
            setAccessibility(title: "Recording, \(elapsed)", detail: application?.name)
        case .possibleEnd(let application, let elapsed):
            setSymbol("questionmark.circle", description: "Meeting may have ended")
            titleLabel.stringValue = "Meeting ended?"
            elapsedLabel.stringValue = elapsed
            elapsedLabel.isHidden = false
            detailLabel.stringValue = application.name
            actionButton.title = "Stop"
            actionButton.keyEquivalent = ""
            closeButton.toolTip = "Keep recording"
            closeButton.image = NSImage(
                systemSymbolName: "chevron.right",
                accessibilityDescription: "Keep recording and collapse controls"
            )
            closeButton.setAccessibilityLabel("Keep recording and collapse controls")
            setAccessibility(
                title: "Meeting ended? Still recording, \(elapsed)",
                detail: application.name
            )
        case .finalizing:
            setSymbol("waveform.badge.checkmark", description: "Saving recording")
            titleLabel.stringValue = "Saving recording…"
            detailLabel.isHidden = true
            actionButton.isHidden = true
            closeButton.isHidden = true
            spinner.startAnimation(nil)
            setAccessibility(title: "Saving recording", detail: nil)
        case .processing:
            setSymbol("text.page", description: "Creating transcript")
            titleLabel.stringValue = "Creating transcript…"
            detailLabel.isHidden = true
            actionButton.isHidden = true
            spinner.startAnimation(nil)
            setAccessibility(title: "Creating transcript", detail: nil)
        case .ready(let session):
            setSymbol("checkmark.circle.fill", description: "Transcript ready")
            symbol.contentTintColor = .systemGreen
            titleLabel.stringValue = "Transcript ready"
            detailLabel.stringValue = SessionName.spoken(session)
            actionButton.title = "Review"
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

    func renderCollapsed(elapsed: String) {
        isCollapsedPresentation = true
        NSLayoutConstraint.deactivate(expandedConstraints)
        NSLayoutConstraint.activate(collapsedConstraints)
        layer?.cornerRadius = 16
        refreshMaterialMask(radius: 16)
        closeButton.isHidden = true
        symbol.isHidden = true
        titleLabel.isHidden = true
        elapsedLabel.isHidden = true
        detailLabel.isHidden = true
        actionButton.isHidden = true
        spinner.stopAnimation(nil)
        collapsedSymbol.isHidden = false
        expandButton.isHidden = false
        expandButton.setAccessibilityLabel(
            "Quill recording, \(elapsed). Show recording controls"
        )
        setAccessibilityLabel("Quill recording, \(elapsed)")
        toolTip = "Click for recording controls. Drag to move."
        resetCursorRects()
    }

    private func showDetectionCountdown() {
        timeoutBar.isHidden = false
        layoutSubtreeIfNeeded()
        guard let layer = timeoutBar.layer else { return }
        layer.removeAllAnimations()
        guard !reduceMotion else { return }
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer.position = CGPoint(x: frame.minX, y: frame.midY)
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 12
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "meeting-timeout")
    }

    func applyAccessibilityOptions(
        reduceTransparency: Bool,
        increaseContrast: Bool,
        reduceMotion: Bool
    ) {
        self.reduceMotion = reduceMotion
        if reduceMotion { timeoutBar.layer?.removeAllAnimations() }
        layer?.backgroundColor = reduceTransparency
            ? NSColor.windowBackgroundColor.cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = increaseContrast ? 1 : 0
        layer?.borderColor = increaseContrast ? NSColor.separatorColor.cgColor : nil
    }

    func visibleControlsFitBounds() -> Bool {
        [closeButton, symbol, titleLabel, elapsedLabel, detailLabel,
         actionButton, collapsedSymbol, expandButton]
            .filter { !$0.isHidden }
            .allSatisfy { bounds.contains($0.convert($0.bounds, to: self)) }
    }

    func detectionCountdownIsAnimating() -> Bool {
        timeoutBar.layer?.animation(forKey: "meeting-timeout") != nil
    }

    override func layout() {
        super.layout()
        refreshMaterialMask(radius: isCollapsedPresentation ? 16 : 18)
    }

    private func refreshMaterialMask(radius: CGFloat) {
        guard bounds.size != materialMaskSize || radius != materialMaskRadius else { return }
        materialMaskSize = bounds.size
        materialMaskRadius = radius
        maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isCollapsedPresentation, bounds.contains(point) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isCollapsedPresentation {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isCollapsedPresentation, let window else {
            super.mouseDown(with: event)
            return
        }
        dragStartLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window.frame.origin
        draggedCollapsedPill = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            isCollapsedPresentation,
            let window,
            let startLocation = dragStartLocation,
            let startOrigin = dragStartWindowOrigin
        else {
            super.mouseDragged(with: event)
            return
        }
        let current = NSEvent.mouseLocation
        let dx = current.x - startLocation.x
        let dy = current.y - startLocation.y
        if !draggedCollapsedPill, hypot(dx, dy) >= 3 {
            draggedCollapsedPill = true
        }
        guard draggedCollapsedPill else { return }
        window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard isCollapsedPresentation else {
            super.mouseUp(with: event)
            return
        }
        let shouldExpand = !draggedCollapsedPill
        dragStartLocation = nil
        dragStartWindowOrigin = nil
        draggedCollapsedPill = false
        if shouldExpand { onExpand?() }
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isCollapsedPresentation else { return }
        onInteractionBegan?()
    }

    override func mouseExited(with event: NSEvent) {
        guard !isCollapsedPresentation else { return }
        onInteractionEnded?()
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        applyAccessibilityOptions(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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

    @objc private func expandClicked() { onExpand?() }
}
