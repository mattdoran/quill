import Foundation
import Testing
@testable import quill

@Suite struct TranscriptDocumentTests {
    @Test func voiceNamesUpdateEveryMatchingSegmentAndMarkdown() throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        var transcript = fixture()

        try transcript.applyVoiceNames(["system:1": "Alice", "system:2": "Alice"])
        try TranscriptStore(session: session).write(transcript)

        let saved = try TranscriptStore(session: session).read()
        #expect(saved.segments.map(\.speaker) == ["Alice", "Alice", "Matt"])
        let json = try String(
            contentsOf: TranscriptStore(session: session).jsonURL,
            encoding: .utf8
        )
        #expect(!json.contains("\\/"))
        let markdown = try String(
            contentsOf: TranscriptStore(session: session).markdownURL,
            encoding: .utf8
        )
        #expect(markdown.components(separatedBy: "Alice").count == 3)
    }

    @Test func blankNameRestoresTheMachineLabel() throws {
        var transcript = fixture(name: "Alice")
        try transcript.applyVoiceNames(["system:1": "  "])
        #expect(transcript.voices["system:1"]?.name == nil)
        #expect(transcript.segments[0].speaker == "them 1")
    }

    @Test func newerSchemaCannotBeOverwritten() throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        var transcript = fixture()
        transcript = TranscriptDocument(
            schema_version: 2, engine: transcript.engine, model: transcript.model,
            diarizer: transcript.diarizer, created_at: transcript.created_at,
            voices: transcript.voices, segments: transcript.segments
        )
        #expect(throws: TranscriptStore.StoreError.self) {
            try TranscriptStore(session: session).write(transcript)
        }
    }

    @Test func failedInitialMarkdownPublishDoesNotMarkTranscriptComplete() throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let markdownDirectory = session.appendingPathComponent("transcript.md")
        try FileManager.default.createDirectory(
            at: markdownDirectory, withIntermediateDirectories: false
        )

        #expect(throws: (any Error).self) {
            try TranscriptStore(session: session).write(fixture())
        }
        #expect(!FileManager.default.fileExists(
            atPath: SessionFiles.transcriptJSON(session).path
        ))
    }

    private func fixture(name: String? = nil) -> TranscriptDocument {
        let sample = TranscriptDocument.Voice.Sample(start_ms: 1_000, end_ms: 6_000)
        return TranscriptDocument(
            schema_version: 1,
            engine: "parakeet",
            model: "test",
            diarizer: "test",
            created_at: "2026-08-19T00:00:00Z",
            voices: [
                "system:1": .init(
                    source: "system", audio_file: "Source Audio/Call.m4a",
                    machine_label: "them 1", name: name, samples: [sample]
                ),
                "system:2": .init(
                    source: "system", audio_file: "Source Audio/Call.m4a",
                    machine_label: "them 2", name: nil, samples: [sample]
                ),
                "mic:1": .init(
                    source: "mic", audio_file: "Source Audio/Microphone.m4a",
                    machine_label: "me", name: "Matt", samples: [sample]
                ),
            ],
            segments: [
                .init(speaker: name ?? "them 1", voice_id: "system:1", start_ms: 0, end_ms: 1_000, text: "Hi"),
                .init(speaker: "them 2", voice_id: "system:2", start_ms: 1_000, end_ms: 2_000, text: "Hello"),
                .init(speaker: "me", voice_id: "mic:1", start_ms: 2_000, end_ms: 3_000, text: "Welcome"),
            ]
        )
    }

    private func temporarySession() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-transcript-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
