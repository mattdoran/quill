import AppKit
import Foundation
import UserNotifications

/// Post a user-facing notification. Clicking it opens `opens`.
func notifyUser(title: String, body: String, opens: URL? = nil, stopButton: Bool = false) {
    Task { @MainActor in
        Notifier.shared.post(title: title, body: body, opens: opens, stopButton: stopButton)
    }
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
    private nonisolated static let stopAction = "STOP_RECORDING"
    private nonisolated static let stopCategory = "RECORDING"

    /// Invoked when the user takes the Stop Recording action on a
    /// notification. Set by whoever owns the session.
    var onStopRequested: (() -> Void)?

    private let bundled = Bundle.main.bundleURL.pathExtension == "app"
    private var hasAsked = false

    /// Wire up delivery. Authorization is asked for separately, since a prompt
    /// at login arrives before the user has done anything to explain it.
    func start() {
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // A notification asking whether the meeting is over needs a way to act
        // on the answer; without the button it is only nagging.
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.stopCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.stopAction,
                        title: "Stop Recording",
                        options: []
                    )
                ],
                intentIdentifiers: []
            )
        ])
    }

    /// Asked the first time the user starts a recording: they have just acted,
    /// so the prompt has a reason, and every notification quill sends comes
    /// after this point.
    func requestAuthorizationOnce() {
        guard bundled, !hasAsked else { return }
        hasAsked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, error in
            if let error {
                FileHandle.standardError.write(Data(
                    "warning: notifications unavailable (\(error))\n".utf8
                ))
            }
        }
    }

    func post(title: String, body: String, opens: URL?, stopButton: Bool = false) {
        guard bundled else {
            postViaOSAScript(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if stopButton { content.categoryIdentifier = Self.stopCategory }
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
        let action = response.actionIdentifier
        let path = response.notification.request.content.userInfo[Self.openKey] as? String
        Task { @MainActor in
            if action == Self.stopAction {
                Notifier.shared.onStopRequested?()
            } else if let path {
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
