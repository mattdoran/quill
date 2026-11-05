import AppKit
import Testing
@testable import quill

@MainActor
@Suite(.serialized) struct WelcomeWindowTests {
    @Test func saysWhereQuillLivesAndFitsItsContent() throws {
        AppKitTestHost.start()
        let controller = WelcomeWindowController()
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()

        let text = labels(in: content).map(\.stringValue).joined(separator: " ")
        #expect(text.contains("Quill is running"))
        #expect(text.contains("menu bar"))

        let ok = try #require(buttons(in: content).first { $0.title == "OK" })
        #expect(ok.keyEquivalent == "\r")
        for control in labels(in: content) + [ok] {
            #expect(content.bounds.contains(control.convert(control.bounds, to: content)))
            #expect(control.frame.height >= control.intrinsicContentSize.height)
        }
    }

    @Test func hiddenIconAdviceUsesTheOverflowButtonWhereItExists() {
        let withButton = WelcomeWindowController.hiddenIconAdvice(hasOverflowButton: true)
        let withoutButton = WelcomeWindowController.hiddenIconAdvice(hasOverflowButton: false)

        #expect(withButton.contains("double arrow"))
        #expect(!withButton.contains("Quitting"))
        #expect(withoutButton.contains("Quitting"))
        #expect(!withoutButton.contains("double arrow"))
    }

    @Test func okReturnsQuillToTheMenuBar() throws {
        AppKitTestHost.start()
        var policies: [NSApplication.ActivationPolicy] = []
        let presence = ApplicationPresenceController(
            setActivationPolicy: { policies.append($0) },
            activateApplication: {}
        )
        let controller = WelcomeWindowController(presence: presence)
        let window = try #require(controller.window)
        let content = try #require(window.contentView)

        controller.show()
        #expect(presence.state.hasUserInterface)
        #expect(policies.last == .regular)

        try #require(buttons(in: content).first { $0.title == "OK" }).performClick(nil)
        #expect(!presence.state.hasUserInterface)
        #expect(policies.last == .accessory)
    }

    @Test func reopenIsHandledByQuillNotAppKit() {
        AppKitTestHost.start()
        var reopens = 0
        let delegate = ApplicationReopenDelegate { reopens += 1 }

        let handledByAppKit = delegate.applicationShouldHandleReopen(
            NSApplication.shared, hasVisibleWindows: true
        )

        #expect(reopens == 1)
        #expect(!handledByAppKit)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap(buttons)
    }

    private func labels(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap(labels)
    }
}
