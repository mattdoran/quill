import AppKit
import Testing
@testable import quill

@MainActor
@Suite(.serialized) struct SettingsWindowTests {
    @Test func controlsExposeTheirPurposeAndKeyboardOrder() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController()
        controller.refresh()
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let buttons = buttons(in: content)
        let change = try #require(buttons.first { $0.title == "Change…" })
        let model = try #require(buttons.first { $0.title == "Download" || $0.title == "Remove…" })
        let retention = try #require(popups(in: content).first)

        #expect(change.accessibilityLabel() == "Change recordings folder")
        #expect(retention.accessibilityLabel() == "Source audio retention")
        #expect(model.accessibilityLabel()?.contains("transcription models") == true)
        #expect(change.nextKeyView === retention)
        #expect(retention.nextKeyView === model)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap(buttons)
    }

    private func popups(in view: NSView) -> [NSPopUpButton] {
        let own = (view as? NSPopUpButton).map { [$0] } ?? []
        return own + view.subviews.flatMap(popups)
    }
}
