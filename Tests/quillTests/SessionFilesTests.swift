import Foundation
import Testing
@testable import quill

@Suite struct SessionFilesTests {
    @Test func emptyAudioStateIsNotProcessableAfterRelaunch() throws {
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-session-files-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: session,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: session) }
        _ = try SessionFiles.prepare(session)

        try writeMetadata(
            ["audio_state": "empty", "files": [:] as [String: String]],
            session: session
        )
        #expect(!SessionFiles.hasProcessableAudio(session))

        try writeMetadata(
            ["files": ["mic": SessionFiles.internalPath("mic.caf")]],
            session: session
        )
        #expect(SessionFiles.hasProcessableAudio(session))
    }

    private func writeMetadata(_ json: [String: Any], session: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: SessionFiles.metadata(session), options: .atomic)
    }
}
