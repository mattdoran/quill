import Foundation
import Testing
@testable import quill

@Suite struct MeetingCompanionStateTests {
    private let zoom = CallApplication(id: "zoom", name: "Zoom")

    @Test func dismissedDetectionSuppressesOnlyTheCurrentEpisode() {
        var state = MeetingCompanionState()
        state.handle(.callDetected(zoom, token: UUID()))
        state.handle(.dismissed)
        state.handle(.callDetected(zoom, token: UUID()))
        #expect(state.phase == .hidden)

        state.handle(.callEnded(zoom))
        state.handle(.callDetected(zoom, token: UUID()))
        guard case .detected(let application, _) = state.phase else {
            Issue.record("the next call episode was still suppressed")
            return
        }
        #expect(application == zoom)
    }

    @Test func recoveredInputReturnsPossibleEndToRecording() {
        var state = MeetingCompanionState()
        state.handle(.recordingStarted(zoom))
        state.handle(.elapsed("12:34"))
        state.handle(.callEnded(zoom))
        state.handle(.callRecovered(zoom))
        #expect(
            state.phase == .recording(application: zoom, elapsed: "12:34")
        )
    }

    @Test func keepingRecordingAcknowledgesPossibleEnd() {
        var state = MeetingCompanionState()
        state.handle(.recordingStarted(zoom))
        state.handle(.elapsed("12:34"))
        state.handle(.callEnded(zoom))
        state.handle(.keepRecording)

        #expect(
            state.phase == .recording(application: zoom, elapsed: "12:34")
        )
    }

    @Test func dismissedRecordingDoesNotResurrectAtCompletion() {
        var state = MeetingCompanionState()
        state.handle(.recordingStarted(zoom))
        state.handle(.dismissed)
        state.handle(.transcriptReady(URL(fileURLWithPath: "/tmp/transcript.md")))
        #expect(state.phase == .hidden)
    }

    @Test func dismissedRecordingCanBeRecoveredFromTheMenu() {
        var state = MeetingCompanionState()
        state.handle(.recordingStarted(zoom))
        state.handle(.elapsed("3:21"))
        state.handle(.dismissed)
        state.handle(.elapsed("3:22"))
        state.handle(.showControls)
        #expect(
            state.phase == .recording(application: zoom, elapsed: "3:22")
        )
    }

    @Test func menuStopDoesNotResurrectADismissedCompanion() {
        var state = MeetingCompanionState()
        state.handle(.recordingStarted(zoom))
        state.handle(.dismissed)
        state.handle(.stopRequested)
        state.handle(.finalizationFinished)
        state.handle(.transcriptReady(URL(fileURLWithPath: "/tmp/transcript.md")))
        #expect(state.phase == .hidden)
    }

    @Test func detectorFlapCannotCoverDismissedRecordingControls() {
        var state = MeetingCompanionState()
        state.handle(.recordingStarted(zoom))
        state.handle(.dismissed)
        state.handle(.callDetected(
            CallApplication(id: "teams", name: "Microsoft Teams"),
            token: UUID()
        ))
        #expect(state.phase == .hidden)
    }

    @Test func failureDoesNotResurrectDismissedSession() {
        var state = MeetingCompanionState()
        state.handle(.recordingStarted(zoom))
        state.handle(.dismissed)
        state.handle(.failed("Transcription failed"))
        #expect(state.phase == .hidden)
    }

    @Test func stopHasAnExplicitFinalizationBoundary() {
        var state = MeetingCompanionState()
        state.handle(.recordingStarted(nil))
        state.handle(.stopRequested)
        #expect(state.phase == .finalizing)
        state.handle(.finalizationFinished)
        #expect(state.phase == .processing)
    }
}
