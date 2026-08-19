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
    private nonisolated static let callPromptKey = "callPrompt"
    private nonisolated static let callRecordingKey = "callRecording"
    private nonisolated static let startCallAction = "START_CALL_RECORDING"
    private nonisolated static let callCategory = "CALL_DETECTED"
    private nonisolated static let stopCallAction = "STOP_CALL_RECORDING"
    private nonisolated static let callEndedCategory = "CALL_ENDED"
    private nonisolated static let stopAction = "STOP_RECORDING"
    private nonisolated static let stopCategory = "RECORDING"

    /// Invoked when the user takes the Stop Recording action on a
    /// notification. Set by whoever owns the session.
    var onStopRequested: (() -> Void)?
    var onCallRecordingRequested: ((String) -> Void)?
    var onCallStopRequested: ((String) -> Void)?

    private let bundled = Bundle.main.bundleURL.pathExtension == "app"
    private var hasAsked = false

    /// Wire up delivery. Authorization is asked for separately, since a prompt
    /// at login arrives before the user has done anything to explain it.
    func start() {
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Call lifecycle prompts must expose the recording action directly;
        // opening an accessory app has no useful destination.
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.callCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.startCallAction,
                        title: "Record",
                        options: []
                    )
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.callEndedCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.stopCallAction,
                        title: "Stop",
                        options: []
                    )
                ],
                intentIdentifiers: []
            ),
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

    /// Asked when a manual recording first needs notifications. Call detection
    /// handles its own first-use request before delivering the start action.
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

    func postCallDetected(_ application: CallApplication, promptToken: UUID) {
        guard bundled else {
            postViaOSAScript(
                title: "Possible call in \(application.name)",
                body: "Open Quill to start recording."
            )
            return
        }
        guard hasAsked else {
            hasAsked = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                granted, error in
                if let error {
                    FileHandle.standardError.write(Data(
                        "warning: notifications unavailable (\(error))\n".utf8
                    ))
                }
                guard granted else { return }
                Task { @MainActor in
                    Notifier.shared.deliverCallDetected(application, promptToken: promptToken)
                }
            }
            return
        }
        deliverCallDetected(application, promptToken: promptToken)
    }

    private func deliverCallDetected(_ application: CallApplication, promptToken: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = application.name
        content.categoryIdentifier = Self.callCategory
        content.userInfo = [Self.callPromptKey: promptToken.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
        )
    }

    func postCallEnded(_ application: CallApplication, recordingToken: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting ended?"
        content.body = application.name
        content.categoryIdentifier = Self.callEndedCategory
        content.userInfo = [Self.callRecordingKey: recordingToken.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.callEndIdentifier(recordingToken),
                content: content,
                trigger: nil
            )
        )
    }

    func removeCallEnded(recordingToken: UUID) {
        let identifier = Self.callEndIdentifier(recordingToken)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private nonisolated static func callEndIdentifier(_ recordingToken: UUID) -> String {
        "call-ended-\(recordingToken.uuidString)"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let path = response.notification.request.content.userInfo[Self.openKey] as? String
        let callPrompt = response.notification.request.content.userInfo[
            Self.callPromptKey
        ] as? String
        let callRecording = response.notification.request.content.userInfo[
            Self.callRecordingKey
        ] as? String
        Task { @MainActor in
            if action == Self.stopCallAction, let callRecording {
                Notifier.shared.onCallStopRequested?(callRecording)
            } else if action == Self.stopAction {
                Notifier.shared.onStopRequested?()
            } else if action == Self.startCallAction, let callPrompt {
                Notifier.shared.onCallRecordingRequested?(callPrompt)
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
        completionHandler([.banner, .list, .sound])
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
