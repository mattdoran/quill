import Foundation
import Testing
@testable import quill

@Suite struct SessionTimelineTests {
    @Test func startOffsetsRoundToTheNearestMillisecond() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(SessionTimeline.startOffsets(
            microphoneStartedAt: base.addingTimeInterval(0.2616),
            systemStartedAt: base
        ).microphone == 262)
        #expect(SessionTimeline.startOffsets(
            microphoneStartedAt: base,
            systemStartedAt: base.addingTimeInterval(0.2496)
        ).system == 250)
    }

    @Test func frameOffsetsUseThePersistedMillisecondClock() {
        let offsets = SessionTrackOffsets(microphone: 262, system: 0)

        #expect(SessionTimeline.frameOffset(
            of: .microphone,
            relativeTo: .system,
            startOffsets: offsets,
            sampleRate: 48_000
        ) == 12_576)
        #expect(SessionTimeline.frameOffset(
            of: .system,
            relativeTo: .microphone,
            startOffsets: offsets,
            sampleRate: 48_000
        ) == -12_576)
    }
}
