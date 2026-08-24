import Foundation
import Testing
@testable import quill

@Suite struct SessionManifestTests {
    @Test func legacyManifestDefaultsMissingOptionalState() throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        try Data(#"{"files":{"mic":".quill/mic.caf"}}"#.utf8).write(
            to: SessionFiles.metadata(session)
        )

        let manifest = try SessionMetadataStore.readManifest(session)

        #expect(manifest.started == "")
        #expect(manifest.audioState == nil)
        #expect(manifest.startOffsets.microphone == 0)
        #expect(manifest.startOffsets.system == 0)
        #expect(manifest.sourceAudio.count == 1)
        #expect(manifest.sourceAudio.first?.track == .microphone)
    }

    @Test func sharedSchemaRoundTripsPersistedFieldNames() throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let manifest = SessionManifest(
            started: "2026-08-24T00:00:00Z",
            ended: "2026-08-24T00:00:02Z",
            durationSeconds: 2,
            files: SessionAudioFiles(
                microphone: SessionFiles.internalPath("mic.caf"),
                cleanedMicrophone: AudioFinalizer.cleanedLocalPath
            ),
            startOffsets: SessionTrackOffsets(microphone: 12, system: 0),
            tracks: SessionTracks(
                microphone: SessionTrackMetadata(
                    file: SessionFiles.internalPath("mic.caf"),
                    durationSeconds: 2,
                    capturedSeconds: 1,
                    gaps: [SessionGap(at: 1, seconds: 1)]
                )
            ),
            recoveredAfterInterruption: true,
            audioState: .finalized
        )

        try SessionMetadataStore.writeManifest(manifest, to: session)
        let text = try String(
            contentsOf: SessionFiles.metadata(session),
            encoding: .utf8
        )
        let decoded = try SessionMetadataStore.readManifest(session)

        #expect(text.contains(#""audio_state" : "finalized""#))
        #expect(text.contains(#""mic_cleaned""#))
        #expect(text.contains(#""start_offset_ms""#))
        #expect(decoded.files.cleanedMicrophone == AudioFinalizer.cleanedLocalPath)
        #expect(decoded.tracks.microphone?.capturedSeconds == 1)
        #expect(decoded.tracks.microphone?.gaps.first?.at == 1)
    }

    @Test func unknownAudioStateIsNotRewrittenByOlderCode() throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        try Data(
            #"{"started":"2026-08-24T00:00:00Z","files":{},"audio_state":"processing"}"#.utf8
        ).write(to: SessionFiles.metadata(session))

        #expect(throws: (any Error).self) {
            try SessionMetadataStore.readManifest(session)
        }
    }

    private func temporarySession() throws -> URL {
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-manifest-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(session)
        return session
    }
}
