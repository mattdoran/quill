import ArgumentParser
import Foundation

/// A real recording with no menu to drive, so crash recovery can be checked
/// from a script. Open it through LaunchServices, or macOS attributes the
/// microphone to the terminal, then kill the process; the watcher reopens the
/// normal app, which resumes the capture.
struct CheckCrashResume: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-crash-resume",
        abstract: "Record until killed, to check recovery from a crash."
    )

    func run() throws {
        try MainActor.assumeIsolated {
            AppWatcher.start(forwarding: [])
            let session = try RecordingSession(root: Config.resolveRoot(cliOverride: nil))
            try session.start()
            FileHandle.standardError.write(Data("recording → \(session.dir.path)\n".utf8))
            withExtendedLifetime(session) { RunLoop.main.run() }
        }
    }
}
