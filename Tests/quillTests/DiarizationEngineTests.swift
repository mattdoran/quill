import Testing
@testable import quill

@Suite struct DiarizationEngineTests {
    @Test func anEstimateAsksForOneMoreVoice() {
        #expect(SpeakerCountSelection.estimate(2).clusterCount == 3)
        #expect(SpeakerCountSelection.automatic.clusterCount == nil)
        #expect(SpeakerCountSelection.estimate(2).description == "about 2")
    }

    @Test func voicesMatchingAnotherFoldIntoTheVoiceWithMoreSpeech() {
        let analysis = DiarizationEngine.Analysis(
            spans: [
                .init(speaker: 0, start: 0, end: 10),
                .init(speaker: 1, start: 10, end: 12),
                .init(speaker: 2, start: 12, end: 40),
            ],
            timings: nil,
            speakerEmbeddings: [
                0: [1, 0, 0],
                1: [0, 1, 0],
                2: [0.97, 0.1, 0.05],
            ]
        )

        let merged = DiarizationEngine.mergingSameVoices(analysis)

        #expect(merged.spans.map(\.speaker) == [1, 0, 1])
        #expect(merged.speakerEmbeddings.count == 2)
        #expect(merged.mergedVoiceSimilarities.count == 1)
        #expect(merged.mergedVoiceSimilarities[0] > 0.99)
    }

    @Test func distinctVoicesAreLeftAlone() {
        let analysis = DiarizationEngine.Analysis(
            spans: [
                .init(speaker: 0, start: 0, end: 10),
                .init(speaker: 1, start: 10, end: 20),
            ],
            timings: nil,
            speakerEmbeddings: [0: [1, 0.4, 0], 1: [0.4, 1, 0]]
        )

        let merged = DiarizationEngine.mergingSameVoices(analysis)

        #expect(merged.spans.map(\.speaker) == [0, 1])
        #expect(merged.mergedVoiceSimilarities.isEmpty)
    }

    @Test func aVoiceSplitThreeWaysBecomesOne() {
        let analysis = DiarizationEngine.Analysis(
            spans: [
                .init(speaker: 0, start: 0, end: 5),
                .init(speaker: 1, start: 5, end: 10),
                .init(speaker: 2, start: 10, end: 15),
                .init(speaker: 3, start: 15, end: 20),
            ],
            timings: nil,
            speakerEmbeddings: [
                0: [1, 0.1, 0],
                1: [0, 0, 1],
                2: [1, 0, 0.1],
                3: [1, 0.05, 0.05],
            ]
        )

        let merged = DiarizationEngine.mergingSameVoices(analysis)

        #expect(merged.spans.map(\.speaker) == [0, 1, 0, 0])
        #expect(merged.mergedVoiceSimilarities.count == 2)
    }

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
