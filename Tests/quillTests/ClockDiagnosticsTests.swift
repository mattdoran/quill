import Foundation
import Testing
@testable import quill

@Suite struct ClockDiagnosticsTests {
    @Test func samplesClockAnchorsAndSummarizesRelativeDrift() throws {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(session)
        defer { try? FileManager.default.removeItem(at: session) }

        let log = SessionLog(dir: session)
        let diagnostics = ClockDiagnostics(
            url: SessionFiles.clockObservations(session),
            log: log,
            interval: 60,
            hostFrequency: 1_000
        )
        observe(
            diagnostics,
            track: .microphone,
            hostTime: 1_000,
            sampleTime: 0,
            normalizedFrame: 0
        )
        observe(
            diagnostics,
            track: .microphone,
            hostTime: 31_000,
            sampleTime: 1_440_144,
            normalizedFrame: 1_440_144
        )
        observe(
            diagnostics,
            track: .microphone,
            hostTime: 61_000,
            sampleTime: 2_880_288,
            normalizedFrame: 2_880_288
        )
        observe(
            diagnostics,
            track: .system,
            hostTime: 1_000,
            sampleTime: 0,
            normalizedFrame: 0
        )
        observe(
            diagnostics,
            track: .system,
            hostTime: 61_000,
            sampleTime: 2_880_000,
            normalizedFrame: 2_880_000
        )
        diagnostics.finish()
        log.close()

        let data = try String(
            contentsOf: SessionFiles.clockObservations(session),
            encoding: .utf8
        )
        let lines = data.split(separator: "\n")
        #expect(lines.count == 4)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observations = try lines.map {
            try decoder.decode(ClockDiagnostics.Observation.self, from: Data($0.utf8))
        }
        #expect(observations.filter { $0.track == .microphone }.count == 2)
        #expect(observations.allSatisfy { $0.schemaVersion == 1 })

        let sessionLog = try String(
            contentsOf: SessionFiles.sessionLog(session),
            encoding: .utf8
        )
        #expect(sessionLog.contains("clock mic epoch 0: 60s, 2 anchors"))
        #expect(sessionLog.contains("normalized 48004.800Hz (+100.0 ppm)"))
        #expect(sessionLog.contains("clock relative: mic-system +100.0 ppm, +0.006s"))
    }

    @Test func recordsTheFirstAnchorOfEveryRouteEpoch() throws {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(session)
        defer { try? FileManager.default.removeItem(at: session) }

        let log = SessionLog(dir: session)
        let diagnostics = ClockDiagnostics(
            url: SessionFiles.clockObservations(session),
            log: log,
            interval: 60,
            hostFrequency: 1_000
        )
        observe(
            diagnostics,
            track: .microphone,
            epoch: 0,
            hostTime: 1_000,
            sampleTime: 0,
            normalizedFrame: 0
        )
        observe(
            diagnostics,
            track: .microphone,
            epoch: 1,
            hostTime: 2_000,
            sampleTime: 0,
            normalizedFrame: 48_000
        )
        diagnostics.finish()
        log.close()

        let data = try String(
            contentsOf: SessionFiles.clockObservations(session),
            encoding: .utf8
        )
        #expect(data.split(separator: "\n").count == 2)
    }

    @Test func finishRetainsTheLastAnchorBeforeTheSamplingInterval() throws {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(session)
        defer { try? FileManager.default.removeItem(at: session) }

        let log = SessionLog(dir: session)
        let diagnostics = ClockDiagnostics(
            url: SessionFiles.clockObservations(session),
            log: log,
            interval: 60,
            hostFrequency: 1_000
        )
        observe(
            diagnostics,
            track: .microphone,
            hostTime: 1_000,
            sampleTime: 0,
            normalizedFrame: 0
        )
        observe(
            diagnostics,
            track: .microphone,
            hostTime: 11_000,
            sampleTime: 480_000,
            normalizedFrame: 480_000
        )
        diagnostics.finish()
        log.close()

        let data = try String(
            contentsOf: SessionFiles.clockObservations(session),
            encoding: .utf8
        )
        #expect(data.split(separator: "\n").count == 2)
        let sessionLog = try String(
            contentsOf: SessionFiles.sessionLog(session),
            encoding: .utf8
        )
        #expect(sessionLog.contains("clock mic epoch 0: 10s, 2 anchors"))
    }

    private func observe(
        _ diagnostics: ClockDiagnostics,
        track: SourceTrack,
        epoch: Int = 0,
        hostTime: UInt64,
        sampleTime: Double,
        normalizedFrame: Int64
    ) {
        diagnostics.observe(
            track: track,
            stamp: CaptureClockStamp(
                hostTime: hostTime,
                sampleTime: sampleTime,
                sampleRate: 48_000,
                routeEpoch: epoch,
                observedAt: Date(timeIntervalSince1970: Double(hostTime) / 1_000)
            ),
            normalizedStartFrame: normalizedFrame,
            normalizedFrameCount: 4_800
        )
    }
}
