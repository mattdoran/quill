import AppKit
import Foundation
import UserNotifications

/// Post a user-facing notification. Clicking it opens `opens`.
func notifyUser(title: String, body: String, opens: URL? = nil) {
    Task { @MainActor in Notifier.shared.post(title: title, body: body, opens: opens) }
}

/// Notifications go through UserNotifications when running from quill.app, and
/// through osascript otherwise.
///
/// `UNUserNotificationCenter.current()` traps for a bare Mach-O, which is what
/// `swift run` produces, so the bundle check guards every call into it rather
/// than only the first.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private nonisolated static let openKey = "opens"

    private let bundled = Bundle.main.bundleURL.pathExtension == "app"

    /// Ask once, at launch: a request raised alongside the first notification
    /// would swallow that notification while the prompt is up.
    func start() {
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                FileHandle.standardError.write(Data(
                    "warning: notifications unavailable (\(error))\n".utf8
                ))
            }
        }
    }

    func post(title: String, body: String, opens: URL?) {
        guard bundled else {
            postViaOSAScript(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let opens { content.userInfo = [Self.openKey: opens.path] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo[Self.openKey] as? String {
            Task { @MainActor in
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        completionHandler()
    }

    /// Without this the system suppresses banners raised by the frontmost app,
    /// and an accessory app counts as frontmost often enough to lose them.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func postViaOSAScript(title: String, body: String) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = [
            "-e", "display notification \(quoted(body)) with title \(quoted(title))",
        ]
        try? task.run()
    }
}
