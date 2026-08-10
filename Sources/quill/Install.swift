import ArgumentParser
import Foundation

/// Turn launch-at-login on or off. The menu does the same thing; this exists
/// so a fresh install can be set up without opening the app.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Register or remove Quill as a login item."
    )

    @Flag(name: .long, help: "Start Quill at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Stop starting Quill at login.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        guard LoginItem.isAvailable else {
            // A bare binary has no bundle for SMAppService to register.
            let hint = "run this from Quill.app, not from the bare binary:\n"
                + "  /Applications/Quill.app/Contents/MacOS/quill install --launch-at-login\n"
            FileHandle.standardError.write(Data(hint.utf8))
            throw ExitCode(1)
        }

        LoginItem.migrateFromLaunchAgent { message in
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
        LoginItem.setEnabled(launchAtLogin)
        Config.setLoginItemInitialized()

        let state = LoginItem.isEnabled ? "on" : "off"
        let report = "launch at login: \(state)\n"
            + "manage it any time in System Settings → General → Login Items\n"
        FileHandle.standardError.write(Data(report.utf8))
    }
}
