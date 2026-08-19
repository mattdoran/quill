import AVFoundation
import Foundation

/// Per-recording capture log kept with the session's internal state.
///
/// Warnings mirror to stderr; routine detail does not, or a long meeting's
/// device chatter buries the few lines the daemon log is useful for.
final class SessionLog: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(dir: URL) {
        let url = SessionFiles.sessionLog(dir)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func log(_ message: String) { append(message, mirrorToStderr: false) }

    func warn(_ message: String) { append("WARN \(message)", mirrorToStderr: true) }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
    }

    private func append(_ message: String, mirrorToStderr: Bool) {
        lock.lock()
        let line = "\(Self.stamp.string(from: Date())) \(message)\n"
        try? handle?.write(contentsOf: Data(line.utf8))
        lock.unlock()
        if mirrorToStderr {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
    }
}

extension AVAudioFormat {
    /// Loggable form. The inherited `description` embeds a pointer address that
    /// changes every restart, so two logs of the same route don't compare.
    var short: String { "\(channelCount)ch \(Int(sampleRate))Hz" }
}
