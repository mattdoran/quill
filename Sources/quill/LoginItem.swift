import Foundation
import ServiceManagement

/// Launch at login, via the app bundle rather than a hand-written LaunchAgent.
///
/// `SMAppService` registers the bundle where it currently sits, so moving
/// Quill.app afterwards breaks startup until it is re-enabled. In exchange the
/// user gets a real Quill entry in System Settings → Login Items, which they
/// can revoke without knowing what launchctl is, and `status` can be read back
/// so a menu checkbox reflects the system's opinion rather than our own.
enum LoginItem {
    /// Only meaningful from the bundle; `swift run` produces a bare binary
    /// that `SMAppService` cannot register.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let verb = enabled ? "enable" : "disable"
            FileHandle.standardError.write(Data(
                "warning: couldn't \(verb) launch at login: \(error)\n".utf8
            ))
        }
    }

    /// Retire a LaunchAgent left by an older install.
    ///
    /// The plist file is deleted but the job is deliberately not booted out:
    /// this process is running under it, and unloading it would kill the app
    /// mid-migration. launchd re-reads the directory at the next login, by
    /// which point the file is gone and the registration below has taken over.
    static func migrateFromLaunchAgent(log: (String) -> Void) {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.mattdoran.quill.plist")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.removeItem(at: legacy)
        log("migrated launch-at-login from a LaunchAgent to a login item")
        setEnabled(true)
    }
}
