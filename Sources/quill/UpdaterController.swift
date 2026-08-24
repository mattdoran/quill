import Foundation
import Sparkle

@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private let relaunchGate = UpdateRelaunchGate()
    var shouldPostponeRelaunch: () -> Bool = { false }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        if Bundle.main.object(forInfoDictionaryKey: "QuillUpdateChannel") as? String == "beta" {
            return ["beta"]
        }
        return []
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        relaunchGate.postpone(installHandler, while: shouldPostponeRelaunch())
    }

    func resumePostponedRelaunchIfPossible() {
        relaunchGate.resume(while: shouldPostponeRelaunch())
    }
}

@MainActor
final class UpdateRelaunchGate {
    private var postponedInstall: (() -> Void)?

    func postpone(_ installHandler: @escaping () -> Void, while blocked: Bool) -> Bool {
        guard blocked else { return false }
        postponedInstall = installHandler
        return true
    }

    func resume(while blocked: Bool) {
        guard !blocked, let postponedInstall else { return }
        self.postponedInstall = nil
        postponedInstall()
    }
}
