import Foundation
import Testing
@testable import quill

/// Stands in for the graph that raised when AirPods were pulled mid-attach.
@MainActor
private final class FlakyCapture: Capture {
    let name = "mic"
    var lastBufferAt: Date?
    var onInvalidated: ((String) -> Void)?
    var failuresLeft: Int
    var attaches = 0

    init(failuresLeft: Int) { self.failuresLeft = failuresLeft }

    func attach() throws {
        attaches += 1
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw NSError(domain: "com.apple.coreaudio.avfaudio", code: 0)
        }
    }

    func detach() {}
    func close(at date: Date) {}
}

@MainActor
@Suite struct CaptureSupervisorRecoveryTests {
    @Test func aFailedRebuildIsRetriedAndLoggedInsteadOfEndingCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-supervisor-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(directory)
        let log = SessionLog(dir: directory)
        let capture = FlakyCapture(failuresLeft: 0)
        let supervisor = CaptureSupervisor(
            capture: capture, log: log, startedAt: Date()
        ) { _ in }
        try supervisor.start()

        capture.failuresLeft = 1
        capture.onInvalidated?("route changed")
        #expect(capture.attaches == 2)
        #expect(!supervisor.isHealthy)

        let text = try String(contentsOf: SessionFiles.sessionLog(directory), encoding: .utf8)
        #expect(text.contains("mic: rebuild attempt 1 starting"))
        #expect(text.contains("rebuild attempt 1 failed"))
    }
}
