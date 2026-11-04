import Foundation

/// Gathers what the system kept about a process death into the session it
/// interrupted, before macOS rotates it away.
enum CrashEvidence {
    struct Summary: Equatable {
        let capturedAt: Date
        let version: String
        let exception: String
        let frames: [String]
    }

    static let systemLogName = "crash-system.log"
    private static let maxFrames = 30
    private static let secondsBeforeCrash: TimeInterval = 60
    private static let secondsAfterCrash: TimeInterval = 5

    private static var defaultReports: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Never throws: evidence must not stand between a session and its recovery.
    static func record(
        session: URL,
        startedAt: Date,
        reports: URL? = nil,
        fetchSystemLog: (Date, Date) -> Data? = systemLog,
        log: (String) -> Void
    ) {
        let systemLogURL = SessionFiles.internalFile(systemLogName, in: session)
        // A failed recovery retries every launch and must not repeat this.
        guard !FileManager.default.fileExists(atPath: systemLogURL.path) else { return }

        let summary = firstCrash(after: startedAt, in: reports ?? defaultReports)
        if let summary {
            log("crash report: quill \(summary.version), \(summary.exception)")
            summary.frames.forEach { log("  \($0)") }
        } else {
            log("no crash report found: the process was killed, or the Mac lost power")
        }

        let sessionLog = SessionFiles.sessionLog(session)
        let lastWrite = (try? sessionLog.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        guard let end = summary?.capturedAt ?? lastWrite else { return }
        let contents = fetchSystemLog(
            end.addingTimeInterval(-secondsBeforeCrash),
            end.addingTimeInterval(secondsAfterCrash)
        ) ?? Data()
        try? contents.write(to: systemLogURL)
    }

    /// The first after the session started: a later one is a different failure.
    private static func firstCrash(after started: Date, in directory: URL) -> Summary? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("quill") && $0.hasSuffix(".ips") }
            .compactMap { name in
                (try? Data(contentsOf: directory.appendingPathComponent(name)))
                    .flatMap(summarize)
            }
            .filter { $0.capturedAt >= started }
            .min { $0.capturedAt < $1.capturedAt }
    }

    /// An `.ips` is a JSON header line followed by a JSON body.
    static func summarize(_ report: Data) -> Summary? {
        guard
            let newline = report.firstIndex(of: 0x0a),
            let header = try? JSONSerialization.jsonObject(
                with: report[..<newline]
            ) as? [String: Any],
            let body = try? JSONSerialization.jsonObject(
                with: report[report.index(after: newline)...]
            ) as? [String: Any],
            let captured = (body["captureTime"] as? String).flatMap(reportDate)
        else { return nil }

        let exception = body["exception"] as? [String: Any]
        let termination = body["termination"] as? [String: Any]
        let description = [
            exception?["type"] as? String,
            exception?["signal"] as? String,
            termination?["indicator"] as? String,
        ].compactMap { $0 }.joined(separator: ", ")

        return Summary(
            capturedAt: captured,
            version: header["app_version"] as? String ?? "unknown",
            exception: description.isEmpty ? "unknown failure" : description,
            frames: faultingFrames(in: body)
        )
    }

    private static func faultingFrames(in body: [String: Any]) -> [String] {
        guard
            let threads = body["threads"] as? [[String: Any]],
            let index = body["faultingThread"] as? Int,
            threads.indices.contains(index),
            let frames = threads[index]["frames"] as? [[String: Any]]
        else { return [] }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        return frames.prefix(maxFrames).map { frame in
            let image = (frame["imageIndex"] as? Int)
                .flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil }
                ?? "?"
            let symbol = frame["symbol"] as? String ?? "?"
            guard let file = frame["sourceFile"] as? String else { return "\(image) \(symbol)" }
            let line = (frame["sourceLine"] as? Int).map { ":\($0)" } ?? ""
            return "\(image) \(symbol) \(file)\(line)"
        }
    }

    private static func reportDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        return formatter.date(from: text)
    }

    static func systemLog(from start: Date, to end: Date) -> Data? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-system-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        guard
            FileManager.default.createFile(atPath: output.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: output)
        else { return nil }
        defer { try? handle.close() }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = [
            "show",
            "--start", formatter.string(from: start),
            "--end", formatter.string(from: end),
            "--style", "compact",
            "--predicate", "process == \"quill\"",
        ]
        task.standardOutput = handle
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [task] in
            if task.isRunning { task.terminate() }
        }
        task.waitUntilExit()
        return try? Data(contentsOf: output)
    }
}
