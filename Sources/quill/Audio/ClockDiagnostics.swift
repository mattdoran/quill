import AVFoundation
import CoreAudio
import Foundation

struct CaptureClockStamp: Sendable {
    let hostTime: UInt64?
    let sampleTime: Double?
    let sampleRate: Double
    let routeEpoch: Int
    let observedAt: Date

    init(
        hostTime: UInt64?,
        sampleTime: Double?,
        sampleRate: Double,
        routeEpoch: Int,
        observedAt: Date = Date()
    ) {
        self.hostTime = hostTime
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
        self.routeEpoch = routeEpoch
        self.observedAt = observedAt
    }

    init(time: AVAudioTime, routeEpoch: Int, observedAt: Date = Date()) {
        self.init(
            hostTime: time.isHostTimeValid ? time.hostTime : AudioGetCurrentHostTime(),
            sampleTime: time.isSampleTimeValid ? Double(time.sampleTime) : nil,
            sampleRate: time.sampleRate,
            routeEpoch: routeEpoch,
            observedAt: observedAt
        )
    }

    init(
        time: AudioTimeStamp,
        sampleRate: Double,
        routeEpoch: Int,
        fallbackHostTime: UInt64? = nil,
        observedAt: Date = Date()
    ) {
        self.init(
            hostTime: time.mFlags.contains(.hostTimeValid) ? time.mHostTime : fallbackHostTime,
            sampleTime: time.mFlags.contains(.sampleTimeValid) ? time.mSampleTime : nil,
            sampleRate: sampleRate,
            routeEpoch: routeEpoch,
            observedAt: observedAt
        )
    }
}

/// Sparse callback-clock observations for diagnosing long-session alignment.
/// Recording continues if this disposable diagnostic file cannot be written.
final class ClockDiagnostics: @unchecked Sendable {
    struct Observation: Codable, Sendable {
        let schemaVersion: Int
        let track: SourceTrack
        let routeEpoch: Int
        let observedAt: Date
        let hostTime: UInt64?
        let deviceSampleTime: Double?
        let deviceSampleRate: Double
        let normalizedStartFrame: Int64
        let normalizedFrameCount: Int

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case track
            case routeEpoch = "route_epoch"
            case observedAt = "observed_at"
            case hostTime = "host_time"
            case deviceSampleTime = "device_sample_time"
            case deviceSampleRate = "device_sample_rate"
            case normalizedStartFrame = "normalized_start_frame"
            case normalizedFrameCount = "normalized_frame_count"
        }
    }

    private struct Key: Hashable {
        let track: SourceTrack
        let epoch: Int
    }

    private struct Fit {
        let key: Key
        let firstHostTime: UInt64
        let lastHostTime: UInt64
        let seconds: Double
        let anchors: Int
        let deviceRate: Double?
        let devicePPM: Double?
        let normalizedRate: Double
        let normalizedPPM: Double
        let maximumResidualMilliseconds: Double
    }

    private let log: SessionLog
    private let interval: TimeInterval
    private let hostFrequency: Double
    private let lock = NSLock()
    private var handle: FileHandle?
    private var observations: [Observation] = []
    private var lastByKey: [Key: Observation] = [:]
    private var latestByKey: [Key: Observation] = [:]
    private var finished = false

    init(
        url: URL,
        log: SessionLog,
        interval: TimeInterval = 60,
        hostFrequency: Double = AudioGetHostClockFrequency()
    ) {
        self.log = log
        self.interval = interval
        self.hostFrequency = hostFrequency
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            log.warn("clock diagnostics unavailable: \(error)")
        }
    }

    func observe(
        track: SourceTrack,
        stamp: CaptureClockStamp,
        normalizedStartFrame: AVAudioFramePosition,
        normalizedFrameCount: AVAudioFrameCount
    ) {
        let observation = Observation(
            schemaVersion: 1,
            track: track,
            routeEpoch: stamp.routeEpoch,
            observedAt: stamp.observedAt,
            hostTime: stamp.hostTime,
            deviceSampleTime: stamp.sampleTime,
            deviceSampleRate: stamp.sampleRate,
            normalizedStartFrame: normalizedStartFrame,
            normalizedFrameCount: Int(normalizedFrameCount)
        )
        let key = Key(track: track, epoch: stamp.routeEpoch)

        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        latestByKey[key] = observation
        if let previous = lastByKey[key], !shouldRecord(observation, after: previous) {
            return
        }
        observations.append(observation)
        lastByKey[key] = observation
        append(observation)
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        for (key, observation) in latestByKey where !sameAnchor(observation, lastByKey[key]) {
            observations.append(observation)
            lastByKey[key] = observation
            append(observation)
        }
        let captured = observations
        try? handle?.close()
        handle = nil
        lock.unlock()

        let fits = Dictionary(grouping: captured) {
            Key(track: $0.track, epoch: $0.routeEpoch)
        }.values.compactMap(fit)
        for fit in fits.sorted(by: fitOrder) {
            var device = "device timestamp unavailable"
            if let rate = fit.deviceRate, let ppm = fit.devicePPM {
                device = String(format: "device %.3fHz (%+.1f ppm)", rate, ppm)
            }
            log.log(String(
                format: "clock %@ epoch %d: %.0fs, %d anchors, %@, "
                    + "normalized %.3fHz (%+.1f ppm), max residual %.2fms",
                fit.key.track.rawValue,
                fit.key.epoch,
                fit.seconds,
                fit.anchors,
                device,
                fit.normalizedRate,
                fit.normalizedPPM,
                fit.maximumResidualMilliseconds
            ))
        }
        logRelativeDrift(fits)
    }

    private func shouldRecord(_ current: Observation, after previous: Observation) -> Bool {
        if
            let currentHost = current.hostTime,
            let previousHost = previous.hostTime,
            currentHost >= previousHost,
            hostFrequency > 0
        {
            return Double(currentHost - previousHost) / hostFrequency >= interval
        }
        return current.observedAt.timeIntervalSince(previous.observedAt) >= interval
    }

    private func sameAnchor(_ observation: Observation, _ previous: Observation?) -> Bool {
        observation.hostTime == previous?.hostTime
            && observation.normalizedStartFrame == previous?.normalizedStartFrame
    }

    private func append(_ observation: Observation) {
        guard let handle else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(observation)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            try? handle.close()
            self.handle = nil
            log.warn("clock diagnostics stopped: \(error)")
        }
    }

    private func fit(_ points: [Observation]) -> Fit? {
        let sorted = points.sorted { ($0.hostTime ?? 0) < ($1.hostTime ?? 0) }
        guard
            hostFrequency > 0,
            sorted.count >= 2,
            let firstHost = sorted.first?.hostTime,
            let lastHost = sorted.last?.hostTime,
            lastHost > firstHost
        else { return nil }

        let seconds = sorted.compactMap { point -> Double? in
            guard let host = point.hostTime, host >= firstHost else { return nil }
            return Double(host - firstHost) / hostFrequency
        }
        guard seconds.count == sorted.count else { return nil }
        let normalized = sorted.map { Double($0.normalizedStartFrame) }
        guard let normalizedLine = regression(x: seconds, y: normalized) else { return nil }

        let devicePoints = zip(seconds, sorted).compactMap { second, point -> (Double, Double)? in
            guard let sample = point.deviceSampleTime else { return nil }
            return (second, sample)
        }
        let deviceLine = regression(
            x: devicePoints.map(\.0),
            y: devicePoints.map(\.1)
        )
        let declaredRate = sorted.first?.deviceSampleRate ?? 0
        let deviceRate = deviceLine?.slope
        let devicePPM = deviceRate.flatMap {
            declaredRate > 0 ? ($0 / declaredRate - 1) * 1_000_000 : nil
        }
        let residual = zip(seconds, normalized).map { second, frame in
            abs(frame - (normalizedLine.intercept + normalizedLine.slope * second))
        }.max() ?? 0

        return Fit(
            key: Key(track: sorted[0].track, epoch: sorted[0].routeEpoch),
            firstHostTime: firstHost,
            lastHostTime: lastHost,
            seconds: seconds.last ?? 0,
            anchors: sorted.count,
            deviceRate: deviceRate,
            devicePPM: devicePPM,
            normalizedRate: normalizedLine.slope,
            normalizedPPM: (normalizedLine.slope / 48_000 - 1) * 1_000_000,
            maximumResidualMilliseconds: residual / 48_000 * 1000
        )
    }

    private func regression(x: [Double], y: [Double]) -> (slope: Double, intercept: Double)? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let meanX = x.reduce(0, +) / Double(x.count)
        let meanY = y.reduce(0, +) / Double(y.count)
        let covariance = zip(x, y).reduce(0.0) {
            $0 + ($1.0 - meanX) * ($1.1 - meanY)
        }
        let variance = x.reduce(0.0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard variance > 0 else { return nil }
        let slope = covariance / variance
        return (slope, meanY - slope * meanX)
    }

    private func fitOrder(_ lhs: Fit, _ rhs: Fit) -> Bool {
        if lhs.key.track.rawValue != rhs.key.track.rawValue {
            return lhs.key.track.rawValue < rhs.key.track.rawValue
        }
        return lhs.key.epoch < rhs.key.epoch
    }

    private func logRelativeDrift(_ fits: [Fit]) {
        let pairs = fits.filter { $0.key.track == .microphone }.flatMap { microphone in
            fits.filter { $0.key.track == .system }.compactMap { system -> (Fit, Fit, UInt64)? in
                let start = max(microphone.firstHostTime, system.firstHostTime)
                let end = min(microphone.lastHostTime, system.lastHostTime)
                return end > start ? (microphone, system, end - start) : nil
            }
        }
        guard
            let pair = pairs.max(by: { $0.2 < $1.2 }),
            hostFrequency > 0
        else { return }
        let microphone = pair.0
        let system = pair.1
        let relativePPM = microphone.normalizedPPM - system.normalizedPPM
        let observedSeconds = Double(pair.2) / hostFrequency
        let accumulated = relativePPM * observedSeconds / 1_000_000
        log.log(String(
            format: "clock relative: mic-system %+.1f ppm, %+.3fs over %.0fs comparable observation",
            relativePPM,
            accumulated,
            observedSeconds
        ))
    }
}
