import Foundation
import Testing
@testable import quill

@Suite struct CallAppMonitorTests {
    @Test func continuityPhoneHelperNormalizesToFaceTime() {
        #expect(
            CallApplicationRegistry.application(for: "com.apple.avconferenced")
                == CallApplication(id: "facetime", name: "FaceTime")
        )
    }

    @Test func knownBrowserHelperNormalizesToBrowser() {
        #expect(
            CallApplicationRegistry.application(for: "com.google.Chrome.helper.GPU")
                == CallApplication(id: "chrome", name: "Chrome")
        )
    }

    @Test func webKitGPUHelperNormalizesToSafari() {
        #expect(
            CallApplicationRegistry.application(for: "com.apple.WebKit.GPU")
                == CallApplication(id: "safari", name: "Safari")
        )
    }

    @Test func unknownMicrophoneApplicationIsNotClassifiedAsCall() {
        #expect(CallApplicationRegistry.application(for: "com.apple.VoiceMemos") == nil)
    }

    @Test func zenBrowserIsRecognized() {
        #expect(
            CallApplicationRegistry.application(for: "app.zen-browser.zen")
                == CallApplication(id: "zen", name: "Zen Browser")
        )
    }

    @Test func snapshotDetectorReportsChangedSnapshotsOnly() {
        let faceTime = ActiveInputProcess(
            pid: 42,
            bundleID: "com.apple.avconferenced",
            deviceUIDs: ["BuiltInMicrophoneDevice"],
            callApplication: CallApplication(id: "facetime", name: "FaceTime")
        )
        var detector = InputSnapshotChangeDetector()

        let initial = detector.observe([])
        let unchangedEmpty = detector.observe([])
        let becameActive = detector.observe([faceTime])
        let unchangedActive = detector.observe([faceTime])
        let becameEmpty = detector.observe([])

        #expect(initial)
        #expect(!unchangedEmpty)
        #expect(becameActive)
        #expect(!unchangedActive)
        #expect(becameEmpty)
    }

    @Test func initialActiveLifecycleDoesNotClaimTheCallJustStarted() {
        let application = CallApplication(id: "facetime", name: "FaceTime")
        var lifecycle = CallLifecycleReducer(stabilityInterval: 2)
        let origin = Date(timeIntervalSinceReferenceDate: 500)

        let initial = lifecycle.observe([application], at: origin)

        #expect(initial.started == [])
        #expect(initial.ended == [])
        #expect(lifecycle.active == [application])
    }

    @Test func lifecycleRequiresTwoStableSecondsToStartAndEnd() {
        let zen = CallApplication(id: "zen", name: "Zen Browser")
        let origin = Date(timeIntervalSinceReferenceDate: 1_000)
        var lifecycle = CallLifecycleReducer(stabilityInterval: 2)

        #expect(lifecycle.observe([], at: origin).started == [])
        #expect(lifecycle.observe([zen], at: origin.addingTimeInterval(1)).started == [])
        #expect(lifecycle.observe([zen], at: origin.addingTimeInterval(2.9)).started == [])
        #expect(lifecycle.observe([zen], at: origin.addingTimeInterval(3)).started == [zen])

        #expect(lifecycle.observe([], at: origin.addingTimeInterval(4)).ended == [])
        #expect(lifecycle.observe([], at: origin.addingTimeInterval(6)).ended == [zen])
    }

    @Test func lifecycleCancelsTransientStartAndEnd() {
        let zen = CallApplication(id: "zen", name: "Zen Browser")
        let origin = Date(timeIntervalSinceReferenceDate: 2_000)
        var lifecycle = CallLifecycleReducer(stabilityInterval: 2)

        _ = lifecycle.observe([], at: origin)
        _ = lifecycle.observe([zen], at: origin.addingTimeInterval(1))
        #expect(lifecycle.observe([], at: origin.addingTimeInterval(2)).started == [])
        #expect(lifecycle.active == [])

        _ = lifecycle.observe([zen], at: origin.addingTimeInterval(3))
        _ = lifecycle.observe([zen], at: origin.addingTimeInterval(5))
        _ = lifecycle.observe([], at: origin.addingTimeInterval(6))
        #expect(lifecycle.observe([zen], at: origin.addingTimeInterval(7)).ended == [])
        #expect(lifecycle.active == [zen])
    }

    @Test func lifecycleTreatsApplicationsIndependently() {
        let zen = CallApplication(id: "zen", name: "Zen Browser")
        let zoom = CallApplication(id: "zoom", name: "Zoom")
        let origin = Date(timeIntervalSinceReferenceDate: 3_000)
        var lifecycle = CallLifecycleReducer(stabilityInterval: 2)

        _ = lifecycle.observe([zen], at: origin)
        _ = lifecycle.observe([zen, zoom], at: origin.addingTimeInterval(1))
        #expect(
            lifecycle.observe([zen, zoom], at: origin.addingTimeInterval(3)).started == [zoom]
        )
        _ = lifecycle.observe([zoom], at: origin.addingTimeInterval(4))
        #expect(lifecycle.observe([zoom], at: origin.addingTimeInterval(6)).ended == [zen])
        #expect(lifecycle.active == [zoom])
    }
}
