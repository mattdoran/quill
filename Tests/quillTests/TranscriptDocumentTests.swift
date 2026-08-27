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
        #expect(!markdown.contains("engine:"))
        #expect(!markdown.contains("diarizer:"))
        #expect(markdown.hasPrefix("# "))
    }

    @Test func blankNameRestoresTheMachineLabel() throws {
        var transcript = fixture(name: "Alice")
        try transcript.applyVoiceNames(["system:1": "  "])
        #expect(transcript.voices["system:1"]?.name == nil)
        #expect(transcript.segments[0].speaker == "them 1")
    }

    @Test func separatedSourceContextDoesNotEnterMarkdown() {
        let voice = TranscriptDocument.Voice(
            source: "mic",
            audio_file: "Source Audio/Local.m4a",
            machine_label: "Voice 1",
            name: nil,
            samples: []
        )
        let transcript = TranscriptDocument(
            schema_version: 1,
            engine: "parakeet",
            model: "test",
            diarizer: "test",
            created_at: "2026-08-20T00:00:00Z",
            voices: ["mic:1": voice],
            segments: [
                .init(
                    speaker: "Voice 1", voice_id: "mic:1",
                    start_ms: 0, end_ms: 1_000, text: "Hello"
                ),
            ]
        )

        let markdown = transcript.rendered(title: "Test")
        #expect(markdown.contains("**[0:00] Voice 1:** Hello"))
        #expect(!markdown.localizedCaseInsensitiveContains("in room"))
        #expect(!markdown.localizedCaseInsensitiveContains("remote"))
    }

    @Test func groupNameCarriesOnlyToOneSeparatedVoice() {
        var transcript = fixture()
        transcript.voices.removeValue(forKey: "system:2")
        transcript.voices["system:1"]?.name = "Alice"

        #expect(transcript.nameToCarry(
            source: "system", separatedVoiceCount: 1
        ) == "Alice")
        #expect(transcript.nameToCarry(
            source: "system", separatedVoiceCount: 2
        ) == nil)
        #expect(transcript.nameToCarry(
            source: "mic", separatedVoiceCount: 1
        ) == "Matt")
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

    @Test func speakerSeparationSnapshotIsPreservedOnceAndRestoredAtomically() throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let store = TranscriptStore(session: session)
        let base = fixture()
        let original = TranscriptDocument(
            schema_version: base.schema_version,
            engine: base.engine,
            model: base.model,
            diarizer: nil,
            created_at: base.created_at,
            voices: base.voices,
            segments: base.segments
        )
        try store.write(original)
        #expect(store.isReviewable)
        try store.preserveBeforeSpeakerSeparation(original)

        var separated = original
        separated = TranscriptDocument(
            schema_version: separated.schema_version,
            engine: separated.engine,
            model: separated.model,
            diarizer: "sortformer-offline-v2.1",
            created_at: separated.created_at,
            voices: separated.voices,
            segments: separated.segments
        )
        try store.write(separated)
        try store.preserveBeforeSpeakerSeparation(separated)

        #expect(store.canRestoreBeforeSpeakerSeparation)
        #expect(try store.readBeforeSpeakerSeparation().diarizer == nil)
        #expect(try store.read().diarizer == "sortformer-offline-v2.1")
        try store.restoreBeforeSpeakerSeparation()
        #expect(try store.read().diarizer == original.diarizer)
        #expect(!store.canRestoreBeforeSpeakerSeparation)
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
                    source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "them 1", name: name, samples: [sample]
                ),
                "system:2": .init(
                    source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "them 2", name: nil, samples: [sample]
                ),
                "mic:1": .init(
                    source: "mic", audio_file: "Source Audio/Local.m4a",
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
