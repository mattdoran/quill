import Testing
@testable import quill

@Suite struct DiarizationEngineTests {
    @Test func attributesTimedSegmentsAndLeavesUnmatchedSpeechUnassigned() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "one"),
            TranscriptSegment(start: 2, end: 3, text: "two"),
            TranscriptSegment(start: 4, end: 5, text: "three"),
        ]
        let spans = [
            DiarizationEngine.Span(speaker: 7, start: 0, end: 1),
            DiarizationEngine.Span(speaker: 3, start: 2, end: 3),
        ]

        let assignments = DiarizationEngine.assignments(for: segments, spans: spans)

        #expect(assignments[0] == 7)
        #expect(assignments[1] == 3)
        #expect(assignments[2] == nil)
    }

    @Test func oneDetectedPersonKeepsTheCoarseLabel() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "one"),
            TranscriptSegment(start: 2, end: 3, text: "two"),
        ]
        let spans = [
            DiarizationEngine.Span(speaker: 4, start: 0, end: 3),
        ]

        #expect(DiarizationEngine.labels(
            for: segments,
            spans: spans,
            solo: "Remote",
            shared: "Speaker"
        ) == ["Remote", "Remote"])
    }

    @Test func separatedVoicesAreNumberedGlobally() {
        var labels = VoiceLabelSequence()
        #expect([
            labels.next(), labels.next(), labels.next(), labels.next(),
        ] == ["Voice 1", "Voice 2", "Voice 3", "Voice 4"])
    }
}
