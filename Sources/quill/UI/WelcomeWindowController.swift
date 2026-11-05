import AppKit

@MainActor
final class WelcomeWindowController: NSWindowController {
    private let presence: ApplicationPresenceController
    private static let textWidth: CGFloat = 380

    init(presence: ApplicationPresenceController = ApplicationPresenceController()) {
        self.presence = presence
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 428, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        if let window {
            presence.present(window)
        }
    }

    private func buildContent() {
        guard let window, let content = window.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let title = NSTextField(labelWithString: "Quill is running")
        title.font = .boldSystemFont(ofSize: 15)
        stack.addArrangedSubview(title)

        let feather = NSImageView()
        feather.image = MenuBarController.featherImage()
        feather.setAccessibilityLabel("Feather icon")
        let location = paragraph(
            "It lives in the menu bar at the top of your screen, not in the Dock. "
                + "Look for this feather.",
            width: Self.textWidth - 26
        )
        let locationRow = NSStackView(views: [feather, location])
        locationRow.orientation = .horizontal
        locationRow.alignment = .top
        locationRow.spacing = 8
        stack.addArrangedSubview(locationRow)

        stack.addArrangedSubview(paragraph(
            "When a call starts, Quill offers to record it. "
                + "You can also start a recording from the feather's menu.",
            width: Self.textWidth
        ))
        stack.addArrangedSubview(paragraph(
            Self.hiddenIconAdvice(
                hasOverflowButton: ProcessInfo.processInfo.isOperatingSystemAtLeast(
                    OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
                )
            ),
            width: Self.textWidth
        ))

        let done = NSButton(title: "OK", target: self, action: #selector(doneClicked))
        done.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [NSView(), done])
        buttonRow.orientation = .horizontal
        stack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true

        content.layoutSubtreeIfNeeded()
        window.setContentSize(stack.fittingSize)
    }

    static func hiddenIconAdvice(hasOverflowButton: Bool) -> String {
        if hasOverflowButton {
            return "If you can't see the feather, your menu bar may be too full to show it. "
                + "Click the double arrow beside your menu bar icons to see the rest."
        }
        return "If you can't see the feather, your menu bar may be too full to show it. "
            + "Quitting another app with an icon up there makes room."
    }

    private func paragraph(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    @objc private func doneClicked() {
        close()
    }
}

/// AppKit reports opening an already-running app only through its delegate.
/// `NSApplication.delegate` is weak, so the owner must keep this alive.
@MainActor
final class ApplicationReopenDelegate: NSObject, NSApplicationDelegate {
    private let onReopen: () -> Void

    init(onReopen: @escaping () -> Void) {
        self.onReopen = onReopen
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        onReopen()
        return false
    }
}
