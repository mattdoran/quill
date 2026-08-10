import Foundation

@main
struct RetentionHarness {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let recent = try session(named: "recent", under: root, transcriptAge: 0)
        let old = try session(named: "old", under: root, transcriptAge: 31 * 24 * 60 * 60)
        let incomplete = try session(named: "incomplete", under: root, transcriptAge: nil)

        AudioRetention.clean(root: root)
        try requireAudio(in: [recent, old, incomplete])

        Config.setAudioRetention(.thirtyDays)
        AudioRetention.clean(root: root)
        try requireAudio(in: [recent, incomplete])
        try requireNoAudio(in: [old])

        Config.setAudioRetention(.afterTranscription)
        AudioRetention.clean(root: root)
        try requireNoAudio(in: [recent, old])
        try requireAudio(in: [incomplete])

        print("audio retention: ok")
    }

    private static func session(
        named name: String,
        under root: URL,
        transcriptAge: TimeInterval?
    ) throws -> URL {
        let session = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        for track in ["mic.caf", "system.caf"] {
            try Data(track.utf8).write(to: session.appendingPathComponent(track))
        }
        if let transcriptAge {
            let transcript = session.appendingPathComponent("transcript.json")
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "created_at": ISO8601DateFormatter().string(
                        from: Date().addingTimeInterval(-transcriptAge)
                    )
                ]
            )
            try data.write(to: transcript)
        }
        return session
    }

    private static func requireAudio(in sessions: [URL]) throws {
        for session in sessions {
            for track in ["mic.caf", "system.caf"] where
                !FileManager.default.fileExists(
                    atPath: session.appendingPathComponent(track).path
                ) {
                throw Failure("expected \(session.lastPathComponent)/\(track) to exist")
            }
        }
    }

    private static func requireNoAudio(in sessions: [URL]) throws {
        for session in sessions {
            for track in ["mic.caf", "system.caf"] where
                FileManager.default.fileExists(
                    atPath: session.appendingPathComponent(track).path
                ) {
                throw Failure("expected \(session.lastPathComponent)/\(track) to be deleted")
            }
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
