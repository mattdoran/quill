import AppKit
import Testing
@testable import quill

@Suite @MainActor struct ApplicationPresenceControllerTests {
    @Test func keepsRegularPresenceUntilEveryOwnerEnds() {
        var policies: [NSApplication.ActivationPolicy] = []
        var activations = 0
        let presence = ApplicationPresenceController(
            setActivationPolicy: { policies.append($0) },
            activateApplication: { activations += 1 }
        )
        let settings = NSObject()
        let review = NSObject()

        presence.begin(settings)
        presence.begin(review, blocking: true)
        presence.end(settings)

        #expect(presence.state == .init(hasUserInterface: true, isBlocking: true))
        #expect(policies.last == .regular)

        presence.end(review)

        #expect(presence.state == .init(hasUserInterface: false, isBlocking: false))
        #expect(policies.last == .accessory)
        #expect(activations == 2)
    }

    @Test func aboutPanelKeepsQuillForegroundUntilItCloses() throws {
        AppKitTestHost.start()
        var policies: [NSApplication.ActivationPolicy] = []
        let presence = ApplicationPresenceController(
            setActivationPolicy: { policies.append($0) },
            activateApplication: {}
        )
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        presence.showAbout(options: [.applicationVersion: "test"])
        presence.showAbout(options: [.applicationVersion: "test"])
        let panel = try #require(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) })

        #expect(presence.state.hasUserInterface)
        #expect(policies.last == .regular)
        panel.close()
        #expect(!presence.state.hasUserInterface)
        #expect(policies.last == .accessory)
    }

    @Test func presentingTheSameOwnerAgainDoesNotStackPresence() {
        var policies: [NSApplication.ActivationPolicy] = []
        let presence = ApplicationPresenceController(
            setActivationPolicy: { policies.append($0) },
            activateApplication: {}
        )
        let panel = NSObject()

        presence.begin(panel, blocking: true)
        presence.begin(panel, blocking: true)
        presence.end(panel)

        #expect(presence.state == .init(hasUserInterface: false, isBlocking: false))
        #expect(policies.last == .accessory)
    }

}
