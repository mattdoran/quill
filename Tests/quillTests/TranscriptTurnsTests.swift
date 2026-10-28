import Foundation
import Testing
@testable import quill

@Suite struct TranscriptTurnsTests {
    @Test func consecutiveRowsBySpeakerFormOneTurn() {
        let turns = turns([
            row("Alex", 0, 1_000, "First point."),
            row("Alex", 1_100, 2_000, "Second point."),
            row("Sam", 2_100, 4_000, "I see it differently."),
        ])
        #expect(turns.map(\.speaker) == ["Alex", "Sam"])
        #expect(turns[0].paragraphs == [[.speech("First point."), .speech("Second point.")]])
        #expect(turns[1].startMilliseconds == 2_100)
    }

    @Test func shortRepliesShowInlineAndMergeByPerson() {
        let turns = turns([
            row("Alex", 0, 1_000, "First point."),
            row("Sam", 1_050, 1_300, "Yeah."),
            row("Sam", 1_350, 1_600, "Right!"),
            row("Alex", 1_700, 3_000, "Second point."),
        ])
        #expect(turns.count == 1)
        #expect(turns[0].paragraphs == [[
            .speech("First point."), .replies(speaker: "Sam", text: "Yeah, Right"),
            .speech("Second point."),
        ]])
    }

    @Test func replyMidSentenceWaitsForTheSentenceToEnd() {
        let turns = turns([
            row("Alex", 0, 1_000, "So the thing is"),
            row("Sam", 1_000, 1_300, "Mm-hmm."),
            row("Alex", 1_300, 2_000, "it works."),
        ])
        #expect(turns[0].paragraphs == [[
            .speech("So the thing is"), .speech("it works."),
            .replies(speaker: "Sam", text: "Mm-hmm"),
        ]])
    }

    @Test func answerToAQuestionStaysItsOwnTurn() {
        let turns = turns([
            row("Alex", 0, 1_000, "Is that right?"),
            row("Sam", 1_100, 1_400, "Yeah."),
            row("Alex", 1_500, 2_000, "Good."),
        ])
        #expect(turns.map(\.speaker) == ["Alex", "Sam", "Alex"])
    }

    @Test func onlyAWholeRowOnTheListIsAReply() {
        let turns = turns([
            row("Alex", 0, 1_000, "First point."),
            row("Sam", 1_100, 2_000, "Yeah, that's fine."),
            row("Alex", 2_100, 3_000, "Second point."),
        ])
        #expect(turns.map(\.speaker) == ["Alex", "Sam", "Alex"])
    }

    @Test func fillersAreHiddenButNumbersAreSpeech() {
        let turns = turns([
            row("Alex", 0, 1_000, "Hello there."),
            row("Sam", 1_100, 1_300, "Um."),
            row("Alex", 1_400, 2_000, "More."),
            row("Sam", 2_100, 2_500, "2006."),
        ])
        #expect(turns.map(\.speaker) == ["Alex", "Sam"])
        #expect(turns[0].paragraphs == [[.speech("Hello there."), .speech("More.")]])
        #expect(turns[1].paragraphs == [[.speech("2006.")]])
    }

    @Test func shortUnassignedBitsJoinTheSpeakerAsAGuess() {
        let turns = turns([
            row("Alex", 0, 1_000, "And this new"),
            row(nil, 1_000, 1_600, "database software"),
            row("Alex", 1_600, 2_500, "is great."),
            row(nil, 2_600, 6_000, "This one is long enough to be its own turn."),
        ])
        #expect(turns.map(\.speaker) == ["Alex", "Unassigned"])
        #expect(turns[0].paragraphs == [[
            .speech("And this new"), .guess("database software"), .speech("is great."),
        ]])
    }

    @Test func consecutiveUnassignedRowsFormOneTurn() {
        let turns = turns([
            row("Alex", 0, 3_000, "This is my point."),
            row(nil, 3_100, 5_000, "And this is something else entirely."),
            row(nil, 5_100, 5_600, "with you."),
            row(nil, 7_500, 8_000, "You."),
        ])
        #expect(turns.map(\.speaker) == ["Alex", "Unassigned"])
        #expect(turns[1].paragraphs == [
            [.speech("And this is something else entirely."), .speech("with you.")],
            [.speech("You.")],
        ])
    }

    @Test func aPauseStartsAParagraphOnlyWhenNobodySpeaks() {
        let quiet = turns([
            row("Alex", 0, 2_000, "First point."),
            row("Alex", 3_600, 5_000, "Second point."),
        ])
        #expect(quiet[0].paragraphs.count == 2)

        let interrupted = turns([
            row("Alex", 0, 2_000, "First point."),
            row("Sam", 2_300, 3_400, "Yeah."),
            row("Alex", 3_700, 5_000, "Second point."),
        ])
        #expect(interrupted[0].paragraphs.count == 1)
    }

    @Test func aParagraphNeverBreaksBeforeALowercaseRow() {
        let turns = turns([
            row("Alex", 0, 2_000, "First point."),
            row("Alex", 5_000, 6_000, "and then more."),
        ])
        #expect(turns[0].paragraphs.count == 1)
    }

    @Test func longParagraphsSplitWithoutLeavingAStub() {
        let ten = "One two three four five six seven eight nine ten."
        let long = turns((0..<20).map { row("Alex", $0 * 1_000, $0 * 1_000 + 1_000, ten) })
        #expect(long[0].paragraphs.map(\.count) == [12, 8])

        let short = turns((0..<13).map { row("Alex", $0 * 1_000, $0 * 1_000 + 1_000, ten) })
        #expect(short[0].paragraphs.count == 1)
    }

    @Test func markdownHasATitleHeaderLineAndOneTimePerTurn() {
        let document = document([
            row("Alex", 0, 2_000, "Hello there."),
            row("Sam", 2_100, 2_500, "Yeah."),
            row("Alex", 2_600, 4_000, "Next point."),
            row("Alex", 6_000, 7_000, "After a pause."),
            row("Sam", 7_100, 12_000, "My own view is longer."),
            row(nil, 12_500, 20_000, "Nobody in particular said this long thing."),
        ])
        #expect(document.rendered(title: "Title", durationMilliseconds: 600_000) == """
        # Title

        10 min · Sam, Alex

        **Alex** (0:00): Hello there. [Sam: Yeah] Next point.

        After a pause.

        **Sam** (0:07): My own view is longer.

        **Unassigned** (0:12): Nobody in particular said this long thing.

        """)
        #expect(document.rendered(title: "Title", durationMilliseconds: 3_600_000)
            .contains("**Alex** (0:00:00):"))
    }

    @Test func uneditedLegacyMarkdownIsRewrittenAndEditedMarkdownIsKept() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-turns-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let untouched = root.appendingPathComponent("2026.10.26-1400")
        let edited = root.appendingPathComponent("2026.10.27-0900")
        let transcript = document([row("Alex", 0, 1_000, "Hello.")])
        for session in [untouched, edited] {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let store = TranscriptStore(session: session)
            try store.write(transcript)
            try Data(transcript.legacyMarkdown(title: session.lastPathComponent).utf8)
                .write(to: store.markdownURL)
        }
        let note = transcript.legacyMarkdown(title: edited.lastPathComponent) + "My note.\n"
        try Data(note.utf8).write(to: TranscriptStore(session: edited).markdownURL)

        TranscriptStore.upgradeUneditedMarkdown(in: root)

        let store = TranscriptStore(session: untouched)
        #expect(try String(contentsOf: store.markdownURL, encoding: .utf8)
            == store.markdown(for: transcript))
        #expect(try String(contentsOf: TranscriptStore(session: edited).markdownURL, encoding: .utf8)
            == note)
    }

    private func row(_ speaker: String?, _ start: Int, _ end: Int, _ text: String)
        -> TranscriptDocument.Segment
    {
        .init(
            speaker: speaker ?? TranscriptDocument.Segment.unassigned,
            voice_id: speaker.map { "system:\($0)" },
            start_ms: start, end_ms: end, text: text
        )
    }

    private func turns(_ segments: [TranscriptDocument.Segment]) -> [TranscriptTurn] {
        document(segments).turns
    }

    private func document(_ segments: [TranscriptDocument.Segment]) -> TranscriptDocument {
        TranscriptDocument(
            schema_version: 1, engine: "parakeet", model: "test", diarizer: "test",
            created_at: "2026-10-28T00:00:00Z", voices: [:], segments: segments
        )
    }
}
