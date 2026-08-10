// AVAudioConverter's input block is typed @Sendable but called synchronously,
// so handing it the buffer we were just given is safe.
@preconcurrency import AVFoundation
import Foundation

/// Owns one track's output file, outliving the capture graphs that feed it.
///
/// Buffers are resampled and downmixed to the file's fixed format. A gap in
/// capture is padded with silence: without it every word after the gap sits
/// earlier than it was spoken, and the two tracks stop describing one timeline.
///
/// Thread-safe — capture graphs write from their own render threads.
final class TrackWriter: @unchecked Sendable {
    enum WriterError: Error, CustomStringConvertible {
        case unsupportedFormat(AVAudioFormat)

        var description: String {
            switch self {
            case .unsupportedFormat(let f): return "track format must be deinterleaved float32, got \(f)"
            }
        }
    }

    struct Gap {
        /// Seconds from the start of the track, not wall clock.
        let at: TimeInterval
        let seconds: TimeInterval
    }

    /// A capture gap shorter than this is jitter, not an interruption: a 4096
    /// frame buffer at 48 kHz is 85 ms, and Bluetooth routes are lumpier still.
    private static let gapThreshold: TimeInterval = 0.5

    /// Long enough that a quiet stretch of a meeting is not an alarm.
    private static let silenceThreshold: TimeInterval = 60

    /// Only meaningful where the device has a noise floor. A live mic delivers
    /// non-zero samples even in a silent room, so exact zeroes mean a dead
    /// route; a system tap delivers exact zeroes whenever nothing is playing.
    private let watchSilence: Bool

    /// Raised once when the track has been digitally silent long enough that
    /// the route is probably dead but still delivering.
    var onProlongedSilence: (@Sendable () -> Void)?

    private let format: AVAudioFormat
    private let name: String
    private let log: SessionLog
    private let lock = NSLock()

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var frames: AVAudioFramePosition = 0

    private var _firstBufferAt: Date?
    private var _lastBufferAt: Date?
    private var _gaps: [Gap] = []
    private var silentSince: Date?
    private var silenceReported = false

    init(
        url: URL, format: AVAudioFormat, name: String, log: SessionLog, watchSilence: Bool
    ) throws {
        self.format = format
        self.name = name
        self.log = log
        self.watchSilence = watchSilence
        // Silence padding writes through `floatChannelData`, which is nil for
        // any other layout — the zeroes would come out as uninitialised heap.
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw WriterError.unsupportedFormat(format)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        log.log("\(name): writing \(url.lastPathComponent) as \(format.short) AAC")
    }

    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    var firstBufferAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _firstBufferAt
    }

    var lastBufferAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastBufferAt
    }

    /// Seconds of audio actually on disk, silence padding included.
    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(frames) / format.sampleRate
    }

    var gaps: [Gap] {
        lock.lock()
        defer { lock.unlock() }
        return _gaps
    }

    /// Gaps since the last buffer are padded here, so callers never sequence
    /// padding against a live tap.
    func write(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard file != nil else { return }

        guard let converted = convertLocked(buffer) else { return }
        if _firstBufferAt == nil {
            _firstBufferAt = now
            log.log("\(name): first buffer at \(buffer.format.short)")
        } else {
            padToWallClockLocked(now: now, arriving: converted.frameLength)
        }
        _lastBufferAt = now
        trackSilenceLocked(converted, at: now)
        writeLocked(converted)
    }

    /// Padding to `date` keeps a track that died early the same length as one
    /// that didn't.
    func close(paddingTo date: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard file != nil else { return }
        padToWallClockLocked(now: date, arriving: 0, reason: "track ended early")
        log.log(String(
            format: "%@: closed — %.1fs written, %d gap(s)",
            name, Double(frames) / format.sampleRate, _gaps.count
        ))
        // Releasing the AVAudioFile is what finalizes it; there is no explicit
        // close.
        file = nil
    }

    // MARK: -

    private func writeLocked(_ buffer: AVAudioPCMBuffer) {
        guard let file else { return }
        do {
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            log.warn("\(name): write failed: \(error)")
        }
    }

    /// The converter carries resampler filter state, so it is kept until the
    /// input format changes — which is exactly when a device swaps.
    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }

        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterInput = buffer.format
            log.log("\(name): converting \(buffer.format.short) → \(format.short)")
        }
        guard let converter else {
            log.warn("\(name): can't convert \(buffer.format.short) → \(format.short)")
            return nil
        }

        // Rate conversion rules out the one-shot `convert(to:from:)`, which
        // requires matching rates; the pull form covers both cases.
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        // Escaping block, so the one-shot flag needs a reference type.
        let supplied = OneShot()
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied.fired {
                status.pointee = .noDataNow
                return nil
            }
            supplied.fired = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            log.warn("\(name): conversion failed: \(error)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    /// The deficit is measured against the track's start, never the previous
    /// buffer: each buffer re-measures the whole track, so an over-long pad is
    /// absorbed by the next one rather than displacing every later word.
    private func padToWallClockLocked(
        now: Date, arriving: AVAudioFrameCount, reason: String = "capture gap"
    ) {
        guard let first = _firstBufferAt else { return }
        let expected = AVAudioFramePosition(
            now.timeIntervalSince(first) * format.sampleRate
        )
        let deficit = expected - frames - AVAudioFramePosition(arriving)
        guard deficit > AVAudioFramePosition(Self.gapThreshold * format.sampleRate) else {
            return
        }
        padLocked(frames: AVAudioFrameCount(deficit), reason: reason)
    }

    private func padLocked(frames padding: AVAudioFrameCount, reason: String) {
        let at = Double(frames) / format.sampleRate
        let seconds = Double(padding) / format.sampleRate
        var remaining = padding
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            return
        }
        // Zeroed through the buffer list so interleaved layouts, where there is
        // one buffer rather than one per channel, are covered. `frameLength` is
        // set to capacity first so the whole allocation is cleared, then shrunk
        // per chunk below.
        silence.frameLength = chunk
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        while remaining > 0 {
            silence.frameLength = min(chunk, remaining)
            writeLocked(silence)
            remaining -= silence.frameLength
        }
        _gaps.append(Gap(at: at, seconds: seconds))
        log.warn(String(
            format: "%@: %.1fs gap at %.1fs padded with silence (%@)", name, seconds, at, reason
        ))
    }

    /// A route can be rebuilt successfully and still deliver nothing but
    /// zeroes. No error is raised for that, so peak is watched instead.
    private func trackSilenceLocked(_ buffer: AVAudioPCMBuffer, at now: Date) {
        guard watchSilence else { return }
        var peak: Float = 0
        for raw in UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        ) {
            guard let data = raw.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(raw.mDataByteSize) / MemoryLayout<Float>.size {
                peak = max(peak, abs(samples[i]))
            }
        }
        guard peak == 0 else {
            if silenceReported {
                log.log("\(name): audio returned")
            }
            silentSince = nil
            silenceReported = false
            return
        }
        guard let since = silentSince else {
            silentSince = now
            return
        }
        if !silenceReported, now.timeIntervalSince(since) > Self.silenceThreshold {
            silenceReported = true
            log.warn(String(
                format: "%@: digital silence for %.0fs — capture is running but empty",
                name, now.timeIntervalSince(since)
            ))
            onProlongedSilence?()
        }
    }
}

private final class OneShot: @unchecked Sendable {
    var fired = false
}
