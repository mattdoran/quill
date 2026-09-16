import Foundation
import Testing
@testable import quill

@Suite struct VoiceProfileStoreTests {
    @Test func rememberPersistsProfileAndSuggestionDoesNotNameTranscript() throws {
        let store = VoiceProfileStore(url: try temporaryURL())
        let remembered = try store.remember(
            document: transcript(
                voice: voice(name: " Alice ", embedding: [3, 4])
            ),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )

        let profile = try #require(remembered["mic:1"])
        #expect(profile.name == "Alice")
        #expect(profile.embedding_model == "offline-vbx-community-1")
        #expect(abs(profile.embedding[0] - 0.6) < 0.001)
        #expect(abs(profile.embedding[1] - 0.8) < 0.001)
        #expect(profile.contribution_count == 1)

        let future = transcript(
            voice: voice(name: nil, embedding: [0.61, 0.79])
        )
        let suggestions = try store.suggestions(for: future)
        #expect(suggestions["mic:1"]?.profileID == profile.id)
        #expect(suggestions["mic:1"]?.name == "Alice")
        #expect(future.voices["mic:1"]?.name == nil)
    }

    @Test func repeatedSaveOfSameMeetingVoiceReplacesContributionWhenNameAndEmbeddingMatch() throws {
        let store = VoiceProfileStore(url: try temporaryURL())
        _ = try store.remember(
            document: transcript(voice: voice(name: "Alice", embedding: [1, 0])),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )
        _ = try store.remember(
            document: transcript(voice: voice(name: "Alice", embedding: [0.98, 0.2])),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )

        let profile = try #require(try store.load().first)
        #expect(profile.contribution_count == 1)
        #expect(profile.contributions.count == 1)
        #expect(profile.embedding[0] > 0.97)
        #expect(profile.embedding[1] > 0.19)
    }

    @Test func recycledVoiceIDWithDifferentEmbeddingCreatesNewProfile() throws {
        let store = VoiceProfileStore(url: try temporaryURL())
        _ = try store.remember(
            document: transcript(voice: voice(name: "Alice", embedding: [1, 0])),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )
        _ = try store.remember(
            document: transcript(voice: voice(name: "Alice", embedding: [0, 1])),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )

        #expect(try store.load().count == 2)
    }

    @Test func acceptedProfileAveragesIntoThatProfileOnly() throws {
        let store = VoiceProfileStore(url: try temporaryURL())
        let remembered = try store.remember(
            document: transcript(voice: voice(name: "Alice", embedding: [1, 0])),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )
        let profileID = try #require(remembered["mic:1"]?.id)
        var accepted = voice(name: "Alice", embedding: [0, 1])
        accepted.remembered_profile_id = profileID

        _ = try store.remember(
            document: transcript(voice: accepted),
            sessionID: "meeting-2",
            voiceIDs: ["mic:1"]
        )

        let profile = try #require(try store.load().first)
        #expect(profile.id == profileID)
        #expect(profile.contribution_count == 2)
        #expect(abs(profile.embedding[0] - 0.707) < 0.001)
        #expect(abs(profile.embedding[1] - 0.707) < 0.001)
    }

    @Test func sameNameWithoutAcceptedProfileCreatesSeparateProfiles() throws {
        let store = VoiceProfileStore(url: try temporaryURL())
        _ = try store.remember(
            document: transcript(voice: voice(name: "Alex", embedding: [1, 0])),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )
        _ = try store.remember(
            document: transcript(voice: voice(name: "Alex", embedding: [0, 1])),
            sessionID: "meeting-2",
            voiceIDs: ["mic:1"]
        )

        let profiles = try store.load()
        #expect(profiles.count == 2)
        #expect(Set(profiles.map(\.name)) == ["Alex"])
    }

    @Test func suggestionsRequireCompatibleModelDimensionAndClearWinner() throws {
        let url = try temporaryURL()
        let store = VoiceProfileStore(
            url: url,
            matching: .init(threshold: 0.8, margin: 0.1)
        )
        _ = try store.remember(
            document: transcript(voice: voice(name: "Alice", embedding: [1, 0])),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )
        _ = try store.remember(
            document: transcript(voice: voice(name: "Bob", embedding: [0.99, 0.01])),
            sessionID: "meeting-2",
            voiceIDs: ["mic:1"]
        )

        #expect(try store.suggestions(for: transcript(
            voice: voice(name: nil, embedding: [1, 0])
        )).isEmpty)
        #expect(try store.suggestions(for: transcript(
            voice: voice(name: nil, model: "other-model", embedding: [1, 0])
        )).isEmpty)
        #expect(try store.suggestions(for: transcript(
            voice: voice(name: nil, embedding: [1, 0, 0])
        )).isEmpty)
    }

    @Test func invalidAndIncompatibleRememberingIsRejected() throws {
        let store = VoiceProfileStore(url: try temporaryURL())
        #expect(throws: VoiceProfileStore.StoreError.invalidEmbedding) {
            try store.remember(
                document: transcript(voice: voice(name: "Alice", embedding: [0, 0])),
                sessionID: "meeting-1",
                voiceIDs: ["mic:1"]
            )
        }
        #expect(throws: VoiceProfileStore.StoreError.invalidEmbedding) {
            try store.remember(
                document: transcript(voice: voice(name: "Alice", embedding: [Float.nan, 1])),
                sessionID: "meeting-1",
                voiceIDs: ["mic:1"]
            )
        }
        let remembered = try store.remember(
            document: transcript(voice: voice(name: "Alice", embedding: [1, 0])),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )
        var incompatible = voice(name: "Alice", model: "other-model", embedding: [1, 0])
        incompatible.remembered_profile_id = try #require(remembered["mic:1"]?.id)
        #expect(throws: VoiceProfileStore.StoreError.incompatibleProfile) {
            try store.remember(
                document: transcript(voice: incompatible),
                sessionID: "meeting-2",
                voiceIDs: ["mic:1"]
            )
        }
    }

    @Test func forgottenRememberedProfileIDCreatesANewProfile() throws {
        let store = VoiceProfileStore(url: try temporaryURL())
        var accepted = voice(name: "Alice", embedding: [1, 0])
        accepted.remembered_profile_id = "forgotten-profile"

        let remembered = try store.remember(
            document: transcript(voice: accepted),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )

        #expect(try store.load().count == 1)
        #expect(remembered["mic:1"]?.id != "forgotten-profile")
    }

    @Test func futureSchemaIsNotOverwritten() throws {
        let url = try temporaryURL()
        let data = Data("""
        {
          "schema_version": 2,
          "profiles": []
        }
        """.utf8)
        try data.write(to: url, options: .atomic)
        let store = VoiceProfileStore(url: url)

        #expect(throws: VoiceProfileStore.StoreError.unsupportedSchema(2)) {
            try store.remember(
                document: transcript(voice: voice(name: "Alice", embedding: [1, 0])),
                sessionID: "meeting-1",
                voiceIDs: ["mic:1"]
            )
        }
    }

    @Test func forgetRemovesProfiles() throws {
        let store = VoiceProfileStore(url: try temporaryURL())
        let remembered = try store.remember(
            document: transcript(voice: voice(name: "Alice", embedding: [1, 0])),
            sessionID: "meeting-1",
            voiceIDs: ["mic:1"]
        )
        try store.forget(profileID: try #require(remembered["mic:1"]?.id))
        #expect(try store.load().isEmpty)

        _ = try store.remember(
            document: transcript(voice: voice(name: "Alice", embedding: [1, 0])),
            sessionID: "meeting-2",
            voiceIDs: ["mic:1"]
        )
        try store.forgetAll()
        #expect(try store.load().isEmpty)
    }

    private func transcript(voice: TranscriptDocument.Voice) -> TranscriptDocument {
        TranscriptDocument(
            schema_version: TranscriptDocument.currentSchemaVersion,
            engine: "parakeet",
            model: "test",
            diarizer: "offline-vbx-community-1",
            created_at: "2026-09-16T00:00:00Z",
            voices: ["mic:1": voice],
            segments: [
                .init(
                    speaker: voice.displayName,
                    voice_id: "mic:1",
                    start_ms: 0,
                    end_ms: 1_000,
                    text: "Hello"
                ),
            ]
        )
    }

    private func voice(
        name: String?,
        model: String = "offline-vbx-community-1",
        embedding: [Float]
    ) -> TranscriptDocument.Voice {
        TranscriptDocument.Voice(
            source: "mic",
            audio_file: "Source Audio/Local.m4a",
            machine_label: "Voice 1",
            name: name,
            samples: [.init(start_ms: 0, end_ms: 1_000)],
            embedding_model: model,
            embedding: embedding
        )
    }

    private func temporaryURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-voice-profile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voice-profiles.json")
    }
}
