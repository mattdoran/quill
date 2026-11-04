import AVFoundation
import Foundation
import Testing
@testable import quill

@Suite struct CaptureResumeTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func journal(resumesAgo: [TimeInterval] = []) -> CaptureJournal {
        var journal = CaptureJournal(
            started: "2026-11-04T00:00:00Z",
            files: SessionAudioFiles(),
            startOffsets: SessionTrackOffsets()
        )
        journal.resumedSegments = resumesAgo.map {
            CaptureSegment(
                files: SessionAudioFiles(),
                startOffsets: SessionTrackOffsets(),
                startedAtMilliseconds: Int64((now.timeIntervalSince1970 - $0) * 1000)
            )
        }
        return journal
    }

    @Test func aRecentDeathResumes() {
        #expect(CaptureResume.decision(
            journal: journal(), lastAudio: now.addingTimeInterval(-299), now: now
        ) == .resume)
    }

    @Test func anOldDeathOnlyFinalizes() {
        #expect(CaptureResume.decision(
            journal: journal(), lastAudio: now.addingTimeInterval(-301), now: now
        ) == .finalize)
    }

    @Test func repeatedResumesStop() {
        #expect(CaptureResume.decision(
            journal: journal(resumesAgo: [60, 120, 180]),
            lastAudio: now.addingTimeInterval(-1),
            now: now
        ) == .stopResuming)
    }

    @Test func resumesOutsideTheWindowDoNotCount() {
        #expect(CaptureResume.decision(
            journal: journal(resumesAgo: [60, 120, 3_600]),
            lastAudio: now.addingTimeInterval(-1),
            now: now
        ) == .resume)
    }

    @Test func aStoppedJournalIsNotInterrupted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stopped = root.appendingPathComponent("2026.11.04-1000")
        let died = root.appendingPathComponent("2026.11.04-1100")
        for session in [stopped, died] { _ = try SessionFiles.prepare(session) }
        var journal = journal()
        try SessionMetadataStore.writeJournal(journal, to: died)
        journal.ended = "2026-11-04T01:00:00Z"
        try SessionMetadataStore.writeJournal(journal, to: stopped)

        #expect(CaptureResume.interrupted(in: root).map(\.session.lastPathComponent)
            == ["2026.11.04-1100"])
    }

    @Test func budgetStopsAtTheLimitAndRecovers() {
        var budget = RelaunchBudget(relaunches: [])
        var allowed = 0
        for _ in 0..<RelaunchBudget.limit + 1 where budget.spend(now: now) { allowed += 1 }
        #expect(allowed == RelaunchBudget.limit)
        let afterWindow = budget.spend(now: now.addingTimeInterval(RelaunchBudget.window + 1))
        #expect(afterWindow)
    }

    @Test func journalWithoutSegmentsStillDecodes() throws {
        let data = Data(#"{"started":"2026-11-04T00:00:00Z","files":{}}"#.utf8)
        let journal = try JSONDecoder().decode(CaptureJournal.self, from: data)
        #expect(journal.resumedSegments.isEmpty)
        #expect(journal.ended == nil)
        #expect(journal.timelineOrigin != nil)
    }

    @Test func offsetsStayOnTheOriginalTimeline() {
        let origin = Date(timeIntervalSinceReferenceDate: 1_000)
        let offsets = SessionTimeline.resumedOffsets(
            origin: origin,
            microphoneStartedAt: origin.addingTimeInterval(120.25),
            systemStartedAt: origin.addingTimeInterval(120.5)
        )
        #expect(offsets.microphone == 120_250)
        #expect(offsets.system == 120_500)
    }

    @Test func planFillsTheGapFromTheTimeline() throws {
        let url = URL(fileURLWithPath: "/unused")
        let plan = try #require(CaptureStitcher.plan(
            [
                .init(url: url, frames: 48_000, offsetMilliseconds: 500),
                .init(url: url, frames: 48_000, offsetMilliseconds: 3_500),
            ],
            sampleRate: 48_000
        ))
        #expect(plan.startOffsetMilliseconds == 500)
        #expect(plan.pieces == [
            .init(silenceBefore: 0, source: 0),
            .init(silenceBefore: 96_000, source: 1),
        ])
    }

    @Test func planClampsAnOverlapToNoSilence() throws {
        let url = URL(fileURLWithPath: "/unused")
        let plan = try #require(CaptureStitcher.plan(
            [
                .init(url: url, frames: 96_000, offsetMilliseconds: 0),
                .init(url: url, frames: 48_000, offsetMilliseconds: 1_000),
            ],
            sampleRate: 48_000
        ))
        #expect(plan.pieces[1].silenceBefore == 0)
    }

    @Test func spokenDurationsFollowTheCopyRules() {
        #expect(CaptureResume.spoken(8) == "8 seconds")
        #expect(CaptureResume.spoken(180) == "3 minutes")
        #expect(CaptureResume.spoken(4_320) == "1 hour 12 minutes")
    }

    @Test func aGapSplitsTheTurnAndAppearsInTheMarkdown() {
        let row = { (start: Int, text: String) in
            TranscriptDocument.Segment(
                speaker: "Me", voice_id: "mic:1", start_ms: start, end_ms: start + 500, text: text
            )
        }
        let document = TranscriptDocument(
            schema_version: TranscriptDocument.currentSchemaVersion,
            engine: "e",
            model: "m",
            diarizer: nil,
            created_at: "2026-11-04T00:00:00Z",
            voices: [:],
            segments: [row(0, "Before the gap."), row(70_000, "After the gap.")],
            interruptions: [SessionInterruption(
                startMilliseconds: 1_000,
                endMilliseconds: 69_000,
                startedAt: "2026-11-04T00:01:00Z",
                endedAt: "2026-11-04T00:02:08Z"
            )]
        )
        #expect(document.turns.count == 2)
        let lines = document.renderedTurns(longForm: false)
        let marker = lines.firstIndex { $0.hasPrefix("*Recording gap, ") }
        #expect(marker == 2)
        #expect(lines[0].contains("Before the gap."))
        #expect(lines[4].contains("After the gap."))
    }
}
