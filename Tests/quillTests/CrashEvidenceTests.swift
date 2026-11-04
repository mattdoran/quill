import Foundation
import Testing
@testable import quill

@Suite struct CrashEvidenceTests {
    private func report(captured: String) throws -> Data {
        let header = try JSONSerialization.data(withJSONObject: ["app_version": "0.9.0"])
        let body = try JSONSerialization.data(withJSONObject: [
            "captureTime": captured,
            "exception": ["type": "EXC_CRASH", "signal": "SIGABRT"],
            "termination": ["indicator": "Abort trap: 6"],
            "faultingThread": 0,
            "usedImages": [["name": "AVFAudio"], ["name": "quill"]],
            "threads": [[
                "frames": [
                    ["imageIndex": 0, "symbol": "InstallTapOnNode"],
                    [
                        "imageIndex": 1,
                        "symbol": "MicRecorder.attach()",
                        "sourceFile": "MicRecorder.swift",
                        "sourceLine": 105,
                    ],
                ],
            ]],
        ])
        return header + Data("\n".utf8) + body
    }

    private func workspace() throws -> (root: URL, session: URL, reports: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-evidence-\(UUID().uuidString)", isDirectory: true
        )
        let session = root.appendingPathComponent("session", isDirectory: true)
        let reports = root.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(session)
        try Data().write(to: SessionFiles.sessionLog(session))
        return (root, session, reports)
    }

    @Test func summarizesTheFaultingThread() throws {
        let summary = try #require(
            CrashEvidence.summarize(try report(captured: "2026-11-04 14:42:41.4017 +1100"))
        )
        #expect(summary.version == "0.9.0")
        #expect(summary.exception == "EXC_CRASH, SIGABRT, Abort trap: 6")
        #expect(summary.frames == [
            "AVFAudio InstallTapOnNode",
            "quill MicRecorder.attach() MicRecorder.swift:105",
        ])
    }

    @Test func recordsTheFirstCrashAfterTheSessionStartedOnlyOnce() throws {
        let (root, session, reports) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try report(captured: "2026-11-01 09:00:00.0000 +1100")
            .write(to: reports.appendingPathComponent("quill-before.ips"))
        try report(captured: "2026-11-04 14:42:41.0000 +1100")
            .write(to: reports.appendingPathComponent("quill-first.ips"))
        try report(captured: "2026-11-04 16:00:00.0000 +1100")
            .write(to: reports.appendingPathComponent("quill-later.ips"))
        let started = try #require(
            ISO8601DateFormatter().date(from: "2026-11-03T23:31:37Z")
        )

        var lines: [String] = []
        var windows: [(Date, Date)] = []
        for _ in 0..<2 {
            CrashEvidence.record(
                session: session,
                startedAt: started,
                reports: reports,
                fetchSystemLog: { windows.append(($0, $1)); return Data("bluetooth".utf8) },
                log: { lines.append($0) }
            )
        }

        #expect(lines.first == "crash report: quill 0.9.0, EXC_CRASH, SIGABRT, Abort trap: 6")
        #expect(lines.count == 3)
        #expect(windows.count == 1)
        let crash = try #require(ISO8601DateFormatter().date(from: "2026-11-04T03:42:41Z"))
        #expect(windows[0].0 == crash.addingTimeInterval(-60))
        let saved = SessionFiles.internalFile(CrashEvidence.systemLogName, in: session)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "bluetooth")
    }

    @Test func saysSoWhenThereIsNoCrashReport() throws {
        let (root, session, reports) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        var lines: [String] = []
        CrashEvidence.record(
            session: session,
            startedAt: Date(timeIntervalSince1970: 0),
            reports: reports,
            fetchSystemLog: { _, _ in nil },
            log: { lines.append($0) }
        )
        #expect(lines == ["no crash report found: the process was killed, or the Mac lost power"])
    }
}

@Suite struct MainThreadStallTests {
    @Test func reportsAStallOnceAndItsLengthWhenItEnds() {
        var stall = MainThreadStall(now: 100)
        let early = stall.check(now: 101.9)
        let unreported = stall.beat(now: 101.9)
        let belowThreshold = stall.check(now: 103.5)
        let crossed = stall.check(now: 104.1)
        let repeated = stall.check(now: 106)
        let length = stall.beat(now: 108.4)
        let afterRecovery = stall.check(now: 109)

        #expect(!early)
        #expect(unreported == nil)
        #expect(!belowThreshold)
        #expect(crossed)
        #expect(!repeated)
        #expect(length == 108.4 - 101.9)
        #expect(!afterRecovery)
    }
}
