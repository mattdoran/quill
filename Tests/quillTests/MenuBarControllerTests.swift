import AppKit
import Testing
@testable import quill

@MainActor
@Suite(.serialized) struct MenuBarControllerTests {
    @Test func statusItemTitleStaysConstantAcrossStates() throws {
        let controller = MenuBarController()
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let button = try #require(controller.statusItem.button)

        controller.update(recording: false, elapsed: nil)
        #expect(button.accessibilityTitle() == "Quill")
        #expect(button.accessibilityValue() as? String == "idle")

        controller.updateStarting()
        #expect(button.accessibilityTitle() == "Quill")

        controller.update(recording: true, elapsed: "1:05")
        #expect(button.accessibilityTitle() == "Quill")
        #expect((button.accessibilityValue() as? String)?.hasPrefix("recording, ") == true)

        controller.update(recording: true, elapsed: "1:06", degraded: true)
        #expect(button.accessibilityTitle() == "Quill")
        #expect((button.accessibilityValue() as? String)?.hasPrefix("capture problem, ") == true)
    }
}
