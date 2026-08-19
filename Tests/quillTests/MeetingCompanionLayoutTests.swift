import AppKit
import Foundation
import Testing
@testable import quill

@MainActor
@Suite struct MeetingCompanionLayoutTests {
    @Test func everyVisibleControlFitsAtTheSupportedPanelSize() {
        _ = NSApplication.shared
        let application = CallApplication(
            id: "teams",
            name: "Microsoft Teams (Work or School) for Contoso Engineering"
        )
        let states: [MeetingCompanionState.Phase] = [
            .detected(application: application, token: UUID()),
            .starting(application: application),
            .recording(
                application: application,
                elapsed: "12:34:56",
                profile: .neither,
                voiceControlVisible: false
            ),
            .recording(
                application: application,
                elapsed: "12:34:56",
                profile: .onTheCall,
                voiceControlVisible: true
            ),
            .possibleEnd(
                application: application,
                elapsed: "12:34:56",
                profile: .both,
                voiceControlVisible: true
            ),
            .finalizing,
            .processing,
            .ready(transcript: URL(fileURLWithPath: "/tmp/2026.08.19-1432/transcript.md")),
        ]

        for state in states {
            let view = MeetingCompanionView(
                frame: NSRect(x: 0, y: 0, width: 468, height: 108)
            )
            view.render(state)
            view.layoutSubtreeIfNeeded()
            #expect(view.visibleControlsFitBounds(), "controls escaped in \(state)")
        }
    }
}
