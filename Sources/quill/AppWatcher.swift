import ArgumentParser
import Foundation

/// Reopens Quill when it dies. launchd's `KeepAlive` only covers instances
/// launchd started, which would leave anything opened by Sparkle or Finder
/// unprotected until the next login.
enum AppWatcher {
    private static let cleanExit: UInt8 = 0x71
    private nonisolated(unsafe) static var writeEnd: Int32 = -1
    private nonisolated(unsafe) static var process: Process?
    private nonisolated(unsafe) static var pipe: Pipe?

    /// `swift run` has no bundle to reopen.
    static func start(forwarding arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        guard
            Bundle.main.bundleURL.pathExtension == "app",
            let executable = Bundle.main.executableURL
        else { return }
        let pipe = Pipe()
        let task = Process()
        task.executableURL = executable
        task.arguments = ["watch-app", "--bundle", Bundle.main.bundleURL.path, "--"] + arguments
        task.standardInput = pipe.fileHandleForReading
        do {
            try task.run()
        } catch {
            FileHandle.standardError.write(Data("warning: no crash watcher: \(error)\n".utf8))
            return
        }
        try? pipe.fileHandleForReading.close()
        writeEnd = pipe.fileHandleForWriting.fileDescriptor
        // An inherited write end would hold the pipe open past our death.
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        self.pipe = pipe
        process = task
        atexit { AppWatcher.markCleanExit() }
    }

    /// Runs from `atexit`, which a crash or a signal never reaches.
    private static func markCleanExit() {
        guard writeEnd >= 0 else { return }
        var byte = cleanExit
        _ = write(writeEnd, &byte, 1)
    }

    static func diedUncleanly(readingFrom descriptor: Int32 = STDIN_FILENO) -> Bool {
        var byte: UInt8 = 0
        while true {
            let count = read(descriptor, &byte, 1)
            if count == 1 { return byte != cleanExit }
            if count == 0 { return true }
            if errno != EINTR { return true }
        }
    }
}

/// How often a dying app may be reopened before the watcher stops trying.
/// Persisted because each relaunch gets a new watcher.
struct RelaunchBudget {
    static let limit = 5
    static let window: TimeInterval = 10 * 60

    var relaunches: [Date]

    mutating func spend(now: Date) -> Bool {
        relaunches = relaunches.filter { now.timeIntervalSince($0) < Self.window }
        guard relaunches.count < Self.limit else { return false }
        relaunches.append(now)
        return true
    }

    static var file: URL { Config.home.appendingPathComponent("relaunches.json") }

    static func load() -> RelaunchBudget {
        let stamps = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([Double].self, from: $0) } ?? []
        return RelaunchBudget(relaunches: stamps.map(Date.init(timeIntervalSince1970:)))
    }

    func save() {
        let stamps = relaunches.map(\.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(stamps) else { return }
        try? FileManager.default.createDirectory(
            at: Config.home,
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.file, options: .atomic)
    }
}

struct WatchApp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch-app",
        abstract: "Reopen Quill if it dies.",
        shouldDisplay: false
    )

    @Option(name: .long)
    var bundle: String

    @Argument(parsing: .captureForPassthrough)
    var arguments: [String] = []

    /// Long enough for `pkill -x quill` to reach this process too, so an install
    /// is not fought by a relaunch of the bundle it is replacing.
    private static let settle: UInt32 = 1

    func run() throws {
        // ^C in a terminal reaches the whole group, and the app stops cleanly.
        signal(SIGINT, SIG_IGN)
        guard AppWatcher.diedUncleanly() else { return }
        sleep(Self.settle)

        var budget = RelaunchBudget.load()
        guard budget.spend(now: Date()) else {
            note("giving up after \(RelaunchBudget.limit) relaunches")
            alert()
            return
        }
        budget.save()
        note("relaunching \(bundle)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var openArguments = [String]()
        if let home = ProcessInfo.processInfo.environment["QUILL_HOME"], !home.isEmpty {
            openArguments += ["--env", "QUILL_HOME=\(home)"]
        }
        openArguments.append(bundle)
        let forwarded = arguments.filter { $0 != "--" }
        if !forwarded.isEmpty { openArguments += ["--args"] + forwarded }
        task.arguments = openArguments
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            note("open exited \(task.terminationStatus)")
            alert()
        }
    }

    private func note(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = Config.home.appendingPathComponent("watcher.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// The app is not there to ask, and the bare helper has no notification
    /// identity of its own.
    private func alert() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e",
            #"display notification "Open it again from Applications." with title "Quill can't restart""#,
        ]
        try? task.run()
        task.waitUntilExit()
    }
}
