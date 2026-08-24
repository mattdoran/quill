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
            .recording(application: application, elapsed: "12:34:56"),
            .possibleEnd(application: application, elapsed: "12:34:56"),
            .finalizing,
            .processing,
            .ready(session: URL(fileURLWithPath: "/tmp/2026.08.19-1432")),
        ]

        for state in states {
            let view = MeetingCompanionView(
                frame: NSRect(origin: .zero, size: MeetingCompanionController.expandedSize)
            )
            view.render(state)
            view.layoutSubtreeIfNeeded()
            #expect(view.visibleControlsFitBounds(), "controls escaped in \(state)")
        }

        let collapsed = MeetingCompanionView(
            frame: NSRect(origin: .zero, size: MeetingCompanionController.collapsedSize)
        )
        collapsed.renderCollapsed(elapsed: "12:34:56")
        collapsed.layoutSubtreeIfNeeded()
        #expect(collapsed.visibleControlsFitBounds())
        #expect(collapsed.hitTest(NSPoint(x: 4, y: 4)) === collapsed)
    }
}
