import Foundation

enum SessionFiles {
    static let internalDirectoryName = ".quill"

    static func internalDirectory(_ session: URL) -> URL {
        session.appendingPathComponent(internalDirectoryName, isDirectory: true)
    }

    static func prepare(_ session: URL) throws -> URL {
        let directory = internalDirectory(session)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func internalFile(_ name: String, in session: URL) -> URL {
        internalDirectory(session).appendingPathComponent(name)
    }

    static func internalPath(_ name: String) -> String {
        "\(internalDirectoryName)/\(name)"
    }

    static func metadata(_ session: URL) -> URL { internalFile("meta.json", in: session) }
    static func captureJournal(_ session: URL) -> URL {
        internalFile("capture.json", in: session)
    }
    static func sessionLog(_ session: URL) -> URL {
        internalFile("session.log", in: session)
    }
    static func transcriptionLog(_ session: URL) -> URL {
        internalFile("transcribe.log", in: session)
    }
    static func transcriptJSON(_ session: URL) -> URL {
        internalFile("transcript.json", in: session)
    }
    static func transcriptMarkdown(_ session: URL) -> URL {
        session.appendingPathComponent("transcript.md")
    }
}
