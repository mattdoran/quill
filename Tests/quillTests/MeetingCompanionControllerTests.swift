import AppKit
import Foundation
import Testing
@testable import quill

@MainActor
@Suite(.serialized) struct MeetingCompanionControllerTests {
    private let application = CallApplication(id: "zoom", name: "Zoom")

    @Test func reopenedDeadlineSupersedesInitialCollapse() async throws {
        _ = NSApplication.shared
        let controller = MeetingCompanionController(
            initialCollapseDelay: 0.05,
            reopenedCollapseDelay: 0.2
        )
        defer { controller.dismiss() }

        controller.handle(.recordingStarted(application))
        try await Task.sleep(for: .milliseconds(20))
        controller.showRecordingControls()
        try await Task.sleep(for: .milliseconds(60))

        #expect(!controller.presentationIsCollapsed)
        try await Task.sleep(for: .milliseconds(170))
        #expect(controller.presentationIsCollapsed)
    }

    @Test func pointerInteractionExtendsButDoesNotPreventCollapse() async throws {
        _ = NSApplication.shared
        let controller = MeetingCompanionController(
            initialCollapseDelay: 0.05,
            reopenedCollapseDelay: 0.2
        )
        defer { controller.dismiss() }

        controller.handle(.recordingStarted(application))
        controller.beginInteraction()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!controller.presentationIsCollapsed)

        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.presentationIsCollapsed)
    }

    @Test func manualRecordingCollapsesWithoutPointerInteraction() async throws {
        _ = NSApplication.shared
        let controller = MeetingCompanionController(initialCollapseDelay: 0.05)
        defer { controller.dismiss() }

        controller.handle(.startRequested(nil))
        controller.handle(.recordingStarted(nil))
        try await Task.sleep(for: .milliseconds(80))

        #expect(controller.presentationIsCollapsed)
    }

    @Test func possibleEndCannotBeCollapsedByOldDeadline() async throws {
        _ = NSApplication.shared
        let controller = MeetingCompanionController(initialCollapseDelay: 0.05)
        defer { controller.dismiss() }

        controller.handle(.recordingStarted(application))
        controller.handle(.callEnded(application))
        try await Task.sleep(for: .milliseconds(80))

        #expect(!controller.presentationIsCollapsed)
        guard case .possibleEnd = controller.state.phase else {
            Issue.record("Expected possible-end controls")
            return
        }
    }

    @Test func processingPanelRemainsUntilDismissed() async throws {
        _ = NSApplication.shared
        let controller = MeetingCompanionController()
        defer { controller.dismiss() }

        controller.handle(.recordingStarted(application))
        controller.handle(.stopRequested)
        controller.handle(.finalizationFinished)
        #expect(controller.isVisible)

        try await Task.sleep(for: .milliseconds(80))
        #expect(controller.isVisible)
        #expect(controller.state.phase == .processing)
    }

    @Test func closeDuringRecordingCollapsesWithoutDismissingSession() {
        _ = NSApplication.shared
        let controller = MeetingCompanionController()
        defer { controller.dismiss() }

        controller.handle(.recordingStarted(application))
        controller.closeCompanion()

        #expect(controller.presentationIsCollapsed)
        #expect(controller.isVisible)
        guard case .recording = controller.state.phase else {
            Issue.record("Close dismissed the recording companion")
            return
        }
    }

    @Test func collapseAndExpansionPreserveTheRightEdge() {
        _ = NSApplication.shared
        let controller = MeetingCompanionController()
        defer { controller.dismiss() }

        controller.handle(.recordingStarted(application))
        let expandedRightEdge = controller.presentationFrame.maxX
        controller.closeCompanion()
        #expect(abs(controller.presentationFrame.maxX - expandedRightEdge) < 0.5)

        controller.showRecordingControls()
        #expect(abs(controller.presentationFrame.maxX - expandedRightEdge) < 0.5)
    }

    @Test func draggedPositionLastsOnlyForTheCurrentSession() throws {
        _ = NSApplication.shared
        let controller = MeetingCompanionController()
        defer { controller.dismiss() }

        controller.handle(.callDetected(application, token: UUID()))
        let defaultOrigin = controller.presentationFrame.origin
        let panel = try #require(NSApp.windows.first {
            $0.isVisible
                && $0.accessibilityLabel() == "Quill meeting controls"
                && $0.frame.origin == defaultOrigin
        })
        let draggedOrigin = NSPoint(x: defaultOrigin.x - 120, y: defaultOrigin.y - 80)
        panel.setFrameOrigin(draggedOrigin)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))

        controller.handle(.startRequested(application))
        controller.handle(.recordingStarted(application))
        #expect(controller.presentationFrame.origin == draggedOrigin)

        controller.handle(.reset)
        controller.handle(.callDetected(application, token: UUID()))
        #expect(controller.presentationFrame.origin == defaultOrigin)
    }

    @Test func closeAtPossibleEndMeansKeepRecordingAndCollapse() {
        _ = NSApplication.shared
        let controller = MeetingCompanionController()
        defer { controller.dismiss() }

        controller.handle(.recordingStarted(application))
        controller.handle(.callEnded(application))
        controller.closeCompanion()

        #expect(controller.presentationIsCollapsed)
        #expect(controller.isVisible)
        guard case .recording = controller.state.phase else {
            Issue.record("Close did not acknowledge possible end")
            return
        }
    }
}
