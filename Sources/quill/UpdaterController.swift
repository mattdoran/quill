import Foundation
import Sparkle

@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate
{
    private var controller: SPUStandardUpdaterController!
    private let relaunchGate = UpdateRelaunchGate()
    private let presence: ApplicationPresenceController
    var shouldPostponeRelaunch: () -> Bool = { false }

    init(presence: ApplicationPresenceController) {
        self.presence = presence
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        presence.begin(self, blocking: true)
        controller.checkForUpdates(nil)
    }

    func standardUserDriverWillShowModalAlert() {
        presence.begin(self, blocking: true)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            presence.begin(self, blocking: true)
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        presence.end(self)
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
