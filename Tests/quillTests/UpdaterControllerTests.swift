import Testing
@testable import quill

@Suite @MainActor struct UpdaterControllerTests {
    @Test func relaunchWaitsForRecordingToFinish() {
        let gate = UpdateRelaunchGate()
        var installs = 0

        #expect(gate.postpone({ installs += 1 }, while: true))
        gate.resume(while: true)
        #expect(installs == 0)

        gate.resume(while: false)
        #expect(installs == 1)
        gate.resume(while: false)
        #expect(installs == 1)
    }

    @Test func idleAppDoesNotPostponeRelaunch() {
        let gate = UpdateRelaunchGate()

        #expect(!gate.postpone({}, while: false))
    }
}
