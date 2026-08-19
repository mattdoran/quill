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

    @Test func pointerInteractionHoldsExpandedControls() async throws {
        _ = NSApplication.shared
        let controller = MeetingCompanionController(
            initialCollapseDelay: 0.05,
            reopenedCollapseDelay: 0.05
        )
        defer { controller.dismiss() }

        controller.handle(.recordingStarted(application))
        controller.beginInteraction()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!controller.presentationIsCollapsed)

        controller.endInteraction()
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

    @Test func processingPanelHandsOffAfterDeadline() async throws {
        _ = NSApplication.shared
        let controller = MeetingCompanionController(processingTimeout: 0.05)
        defer { controller.dismiss() }

        controller.handle(.recordingStarted(application))
        controller.handle(.stopRequested)
        controller.handle(.finalizationFinished)
        #expect(controller.isVisible)

        try await Task.sleep(for: .milliseconds(80))
        #expect(!controller.isVisible)
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
