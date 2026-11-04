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

    private nonisolated(unsafe) static weak var active: SessionLog?
    private static let activeLock = NSLock()

    init(dir: URL) {
        let url = SessionFiles.sessionLog(dir)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        Self.activeLock.lock()
        Self.active = self
        Self.activeLock.unlock()
    }

    func log(_ message: String) { append(message, mirrorToStderr: false) }

    func warn(_ message: String) { append("WARN \(message)", mirrorToStderr: true) }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
    }

    private nonisolated(unsafe) static var previousExceptionHandler:
        (@convention(c) (NSException) -> Void)?

    /// The system log redacts an exception's reason, so this is the only place
    /// it survives. Writes bypass `lock`: an exception raised while it is held
    /// would otherwise deadlock instead of crashing.
    ///
    /// Call once the application is running. AppKit replaces any handler set
    /// before that, silently.
    static func installUncaughtExceptionHandler() {
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            let lines = [
                "FATAL uncaught \(exception.name.rawValue): \(exception.reason ?? "no reason")",
            ] + exception.callStackSymbols
            let text = lines.joined(separator: "\n") + "\n"
            FileHandle.standardError.write(Data(text.utf8))
            if SessionLog.activeLock.try() {
                let log = SessionLog.active
                SessionLog.activeLock.unlock()
                let time = SessionLog.stamp.string(from: Date())
                try? log?.handle?.write(contentsOf: Data("\(time) \(text)".utf8))
            }
            SessionLog.previousExceptionHandler?(exception)
        }
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
