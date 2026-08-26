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
            case .unsupportedFormat(let f): return "track format must be float32, got \(f)"
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

    /// RMS below this counts as nobody being there. Not zero: a live
    /// microphone in a silent room still has a noise floor, so zero would only
    /// ever mean a dead route. -50 dBFS.
    private static let audibleFloor: Double = 0.00316

    /// Only meaningful where the device has a noise floor. A live mic delivers
    /// non-zero samples even in a silent room, so exact zeroes mean a dead
    /// route; a system tap delivers exact zeroes whenever nothing is playing.
    private let watchSilence: Bool

    /// Raised once when the track has been digitally silent long enough that
    /// the route is probably dead but still delivering.
    var onProlongedSilence: (@Sendable () -> Void)?

    /// Raised once when the source archive can no longer accept audio. The
    /// writer becomes terminal and leaves existing bytes for recovery.
    var onWriteFailure: (@Sendable (String) -> Void)?

    /// Raised after wall-clock repair inserts silence between capture buffers.
    /// The callback must return immediately; it runs on the archive queue.
    var onCaptureGap: (@Sendable (Gap) -> Void)?

    /// Beyond this many buffers queued, the disk is losing badly enough that
    /// holding more would only grow unbounded. Roughly 20 seconds of audio.
    private static let maxPending = 256

    private let format: AVAudioFormat
    private let track: SourceTrack
    private var name: String { track.rawValue }
    private let log: SessionLog
    private let clockDiagnostics: ClockDiagnostics?
    private let lock = NSLock()
    private let work = DispatchQueue(label: "com.mattdoran.quill.track-writer", qos: .utility)
    private let pendingLock = NSLock()
    private var pending = 0
    private var droppedReported = false
    private var accepting = true

    private var acceptedFrames: (any AcceptedFrameSink)?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var frames: AVAudioFramePosition = 0

    private var _firstBufferAt: Date?
    private var _lastBufferAt: Date?
    private var _gaps: [Gap] = []
    private var silentSince: Date?
    private var silenceReported = false
    private var _lastAudibleAt: Date?
    private var _hasEverBeenAudible = false
    private var _writeFailure: String?
    private var failureCallbackSent = false
    private let fileWrite: (AVAudioFile, AVAudioPCMBuffer) throws -> Void

    init(
        url: URL,
        format: AVAudioFormat,
        track: SourceTrack,
        log: SessionLog,
        watchSilence: Bool,
        clockDiagnostics: ClockDiagnostics? = nil,
        fileWrite: ((AVAudioFile, AVAudioPCMBuffer) throws -> Void)? = nil
    ) throws {
        self.format = format
        self.track = track
        self.log = log
        self.watchSilence = watchSilence
        self.clockDiagnostics = clockDiagnostics
        self.fileWrite = fileWrite ?? { file, buffer in try file.write(from: buffer) }
        // Silence and peak both walk raw sample memory as Float. The system tap
        // hands back interleaved stereo, so layout is not assumed, but the
        // sample type is.
        guard format.commonFormat == .pcmFormatFloat32 else {
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

    /// When this track last carried something audible, and whether it ever
    /// has. An in-person meeting never plays anything, so a system track that
    /// has never been audible is not evidence that a meeting ended.
    var lastAudibleAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastAudibleAt
    }

    var hasEverBeenAudible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _hasEverBeenAudible
    }

    var writeFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return _writeFailure
    }

    /// Called on a capture thread, which must not block: this copies the
    /// buffer, stamps its arrival and hands it off. Resampling, AAC encode and
    /// the disk write all happen on `work`, where a slow disk costs latency
    /// rather than dropped buffers.
    func write(_ buffer: AVAudioPCMBuffer, clock: CaptureClockStamp? = nil) {
        let now = clock?.observedAt ?? Date()
        pendingLock.lock()
        guard accepting else {
            pendingLock.unlock()
            return
        }
        guard pending < Self.maxPending else {
            let firstDrop = !droppedReported
            droppedReported = true
            pendingLock.unlock()
            if firstDrop {
                log.warn("\(name): writer fell behind — dropped audio becomes a padded gap")
            }
            return
        }
        pending += 1
        pendingLock.unlock()

        guard let copy = Self.copy(buffer) else {
            pendingLock.lock()
            pending -= 1
            pendingLock.unlock()
            return
        }

        work.async { [self] in
            consume(copy, at: now, clock: clock)
            pendingLock.lock()
            pending -= 1
            pendingLock.unlock()
        }
    }

    /// Set before capture starts; every successfully archived frame is offered.
    func sendAcceptedFrames(to sink: any AcceptedFrameSink) {
        lock.lock()
        defer { lock.unlock() }
        acceptedFrames = sink
    }

    /// Padding to `date` keeps a track that died early the same length as one
    /// that didn't.
    func close(paddingTo date: Date) {
        // Drains everything already queued before closing, since `work` is
        // serial.
        work.sync { self.closeDraining(paddingTo: date) }
        reportCloseFailure()
    }

    /// Suspends the caller while the archive queue drains.
    func closeAsync(paddingTo date: Date) async {
        await withCheckedContinuation { continuation in
            work.async { [self] in
                closeDraining(paddingTo: date)
                reportCloseFailure()
                continuation.resume()
            }
        }
    }

    private func reportCloseFailure() {
        lock.lock()
        let failure = takeUnreportedFailureLocked()
        lock.unlock()
        if let failure { onWriteFailure?(failure) }
    }

    // MARK: -

    private func consume(
        _ buffer: AVAudioPCMBuffer,
        at now: Date,
        clock: CaptureClockStamp?
    ) {
        lock.lock()
        guard file != nil else { lock.unlock(); return }

        guard let converted = convertLocked(buffer) else { lock.unlock(); return }
        if _firstBufferAt == nil {
            _firstBufferAt = now
            log.log("\(name): first buffer at \(buffer.format.short)")
        } else {
            padToWallClockLocked(now: now, arriving: converted.frameLength)
        }
        _lastBufferAt = now
        trackSilenceLocked(converted, at: now)
        let startFrame = frames
        let captureSegment = _gaps.count
        let written = writeLocked(converted, origin: .captured)
        let failure = takeUnreportedFailureLocked()
        lock.unlock()
        if written, let clock {
            clockDiagnostics?.observe(
                track: track,
                stamp: clock,
                normalizedStartFrame: startFrame,
                normalizedFrameCount: converted.frameLength,
                captureSegment: captureSegment
            )
        }
        if let failure { onWriteFailure?(failure) }
    }

    /// Layout-agnostic copy: the tap's buffer is only valid for the duration of
    /// its callback.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(
            pcmFormat: buffer.format, frameCapacity: buffer.frameLength
        ) else { return nil }
        out.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let from = src[i].mData, let to = dst[i].mData else { continue }
            memcpy(to, from, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
        }
        return out
    }

    private func closeDraining(paddingTo date: Date) {
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

    @discardableResult
    private func writeLocked(
        _ buffer: AVAudioPCMBuffer,
        origin: AcceptedFrame.Origin
    ) -> Bool {
        guard let file else { return false }
        do {
            try fileWrite(file, buffer)
            let startFrame = frames
            frames += AVAudioFramePosition(buffer.frameLength)
            if
                let acceptedFrames,
                acceptedFrames.isAccepting,
                let frame = AcceptedFrame(
                    copying: buffer,
                    track: track,
                    startFrame: startFrame,
                    origin: origin
                )
            {
                acceptedFrames.offer(frame)
            }
            return true
        } catch {
            log.warn("\(name): write failed: \(error)")
            if _writeFailure == nil { _writeFailure = "\(error)" }
            self.file = nil
            pendingLock.lock()
            accepting = false
            pendingLock.unlock()
            return false
        }
    }

    private func takeUnreportedFailureLocked() -> String? {
        guard let failure = _writeFailure, !failureCallbackSent else { return nil }
        failureCallbackSent = true
        return failure
    }

    /// AVAudioConverter does not mix channels down: asked for 2ch to 1ch it
    /// returns the left channel and discards the right, so a participant panned
    /// right would vanish. Averaging has to happen here, before it runs.
    private func downmixLocked(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sourceChannels = Int(buffer.format.channelCount)
        guard format.channelCount == 1, sourceChannels > 1 else { return buffer }

        guard
            let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
            let destination = out.floatChannelData?[0]
        else {
            log.warn("\(name): couldn't allocate downmix buffer")
            return nil
        }
        out.frameLength = buffer.frameLength

        let frames = Int(buffer.frameLength)
        let scale = 1 / Float(sourceChannels)
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        for frame in 0..<frames { destination[frame] = 0 }
        if list.count == 1, let data = list[0].mData {
            // Interleaved: one buffer carrying every channel.
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<sourceChannels {
                    sum += samples[frame * sourceChannels + channel]
                }
                destination[frame] = sum * scale
            }
        } else {
            for raw in list {
                guard let data = raw.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames { destination[frame] += samples[frame] * scale }
            }
        }
        return out
    }

    /// The converter carries resampler filter state, so it is kept until the
    /// input format changes — which is exactly when a device swaps.
    private func convertLocked(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let buffer = downmixLocked(input) else { return nil }
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
            guard writeLocked(silence, origin: .insertedSilence) else { return }
            remaining -= silence.frameLength
        }
        let gap = Gap(at: at, seconds: seconds)
        _gaps.append(gap)
        log.warn(String(
            format: "%@: %.1fs gap at %.1fs padded with silence (%@)", name, seconds, at, reason
        ))
        if reason == "capture gap" { onCaptureGap?(gap) }
    }

    /// Two different questions get asked of the same buffer, and conflating
    /// them is a trap:
    ///
    ///  - Is this route dead? Exact zeroes on a mic mean the graph is
    ///    delivering nothing and needs rebuilding. Only asked where a noise
    ///    floor is expected, so never of the system tap, where exact zeroes
    ///    just mean nothing is playing.
    ///  - Is anyone there? Answered against a level floor rather than zero,
    ///    for both tracks, and only ever reported. Wiring this one to a
    ///    rebuild would tear the system tap down every time playback pauses.
    private func trackSilenceLocked(_ buffer: AVAudioPCMBuffer, at now: Date) {
        var peak: Float = 0
        var sumOfSquares: Double = 0
        var count = 0
        for raw in UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        ) {
            guard let data = raw.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(raw.mDataByteSize) / MemoryLayout<Float>.size {
                let sample = samples[i]
                peak = max(peak, abs(sample))
                sumOfSquares += Double(sample) * Double(sample)
                count += 1
            }
        }

        if count > 0 {
            let rms = (sumOfSquares / Double(count)).squareRoot()
            if rms > Self.audibleFloor {
                _lastAudibleAt = now
                _hasEverBeenAudible = true
            }
        }

        guard watchSilence else { return }
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
