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
