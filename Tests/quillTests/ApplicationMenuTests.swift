import AppKit
import Testing
@testable import quill

@MainActor
@Suite(.serialized) struct ApplicationMenuTests {
    @Test func definesStandardEditCommandsAndUsesTheSafeQuitHandler() throws {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        defer { app.mainMenu = previousMenu }
        let controller = ApplicationMenuController()
        var quitRequested = false
        controller.onQuit = { quitRequested = true }
        controller.install()

        let edit = try #require(app.mainMenu?.item(withTitle: "Edit")?.submenu)
        let copy = try #require(edit.item(withTitle: "Copy"))
        #expect(copy.action == #selector(NSText.copy(_:)))
        #expect(copy.keyEquivalent == "c")
        #expect(copy.target == nil)

        let application = try #require(app.mainMenu?.item(withTitle: "Quill")?.submenu)
        let quit = try #require(application.item(withTitle: "Quit Quill"))
        #expect(app.sendAction(quit.action!, to: quit.target, from: quit))
        #expect(quitRequested)
    }
}
