import AVFoundation
import Foundation
import WebRTCAudio

/// Cancels speaker playback out of the microphone track while the meeting is
/// still running, so stopping costs nothing.
///
/// AEC3 is a streaming block algorithm carrying its own state, so this is its
/// native mode; `EchoCancellation` running the same filter over finished files
/// is the unusual one. That offline pass stays as the fallback: this publishes
/// `mic-cleaned.caf` only on a clean finish, and `EchoCancellation.clean()`
/// returns early when it finds one, so an abandoned live pass simply means the
/// old post-stop path runs.
///
/// `SetAudioBufferDelay(0)` in the bridge means the filter is told near and far
/// are already sample-aligned, so alignment is this type's problem. Both tracks
/// are wall-clock timelines: `TrackWriter` pads gaps with silence, so track
/// frame `n` is always `firstBufferAt + n/rate`. Near frame `i` therefore needs
/// far track frame `i + farOffset`, which is the same relation the offline pass
/// derives from the journal's `start_offset_ms`.
final class LiveEchoCanceller: TrackMonitor, @unchecked Sendable {
    /// Near audio held while far has not caught up. Beyond this the far track
    /// is treated as silent for the gap rather than stalling the pass: no
    /// cancellation over that stretch beats no transcript.
    private static let maxFarWait: TimeInterval = 5

    /// Unprocessed near audio beyond this means the pump is not keeping up at
    /// all, which live AEC has no way to recover from. Abandon and leave it to
    /// the offline pass.
    private static let maxBufferedSeconds: TimeInterval = 30

    /// Both tracks are pinned to this. A mismatch means someone changed a
    /// recorder's file format without revisiting the alignment maths.
    private let rate: Double
    private let frameSize: Int
    private let nearName: String
    private let farName: String
    private let session: URL
    private let log: SessionLog

    private let work = DispatchQueue(
        label: "com.mattdoran.quill.live-aec", qos: .utility
    )
    private let lock = NSLock()

    private var canceller: QuillEchoCanceller?
    private var file: AVAudioFile?
    private let partial: URL
    private let published: URL

    /// Near frame `i` reads far track frame `i + farOffset`. Unknown until both
    /// tracks have delivered a buffer, which is when the pump may start.
    private var farOffset: Int64?

    private var near: [Float] = []
    private var nearBase: Int64 = 0
    private var far: [Float] = []
    private var farBase: Int64 = 0
    private var nextFrame: Int64 = 0

    private var pumpScheduled = false
    private var abandoned = false
    private var blockedSince: Date?

    init?(session: URL, rate: Double, nearName: String, farName: String, log: SessionLog) {
        guard [16_000.0, 32_000.0, 48_000.0].contains(rate) else {
            log.warn("live aec: unsupported rate \(rate)")
            return nil
        }
        self.session = session
        self.rate = rate
        self.frameSize = Int(rate) / 100
        self.nearName = nearName
        self.farName = farName
        self.log = log
        self.published = session.appendingPathComponent(EchoCancellation.outputName)
        self.partial = session.appendingPathComponent(
            "\(EchoCancellation.outputName).live"
        )
        try? FileManager.default.removeItem(at: partial)

        guard let canceller = quill_aec_create(Int32(rate)) else {
            log.warn("live aec: AEC3 initialization failed")
            return nil
        }
        self.canceller = canceller

        do {
            file = try AVAudioFile(
                forWriting: partial,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 1,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            quill_aec_destroy(canceller)
            self.canceller = nil
            log.warn("live aec: couldn't open \(partial.lastPathComponent): \(error)")
            return nil
        }
    }

    deinit {
        if let canceller { quill_aec_destroy(canceller) }
    }

    /// Called once both tracks have a first buffer, which fixes their offset.
    func begin(nearStart: Date, farStart: Date) {
        lock.lock()
        guard !abandoned, farOffset == nil else { lock.unlock(); return }
        let offset = Int64((nearStart.timeIntervalSince(farStart) * rate).rounded())
        farOffset = offset
        lock.unlock()
        log.log(String(
            format: "live aec: aligned, far leads near by %.3fs", Double(offset) / rate
        ))
        schedulePump()
    }

    /// Drain what is buffered and publish. Returns whether the cleaned track is
    /// now on disk under its final name.
    func finish() -> Bool {
        work.sync {
            lock.lock()
            let alreadyAbandoned = abandoned
            lock.unlock()
            guard !alreadyAbandoned else { return }
            // No more far audio is coming, so anything still waiting on it is
            // processed against silence rather than held.
            pump(draining: true)
            publish()
        }
        lock.lock()
        defer { lock.unlock() }
        return !abandoned
    }

    func abandon(_ reason: String) {
        lock.lock()
        guard !abandoned else { lock.unlock(); return }
        abandoned = true
        file = nil
        near = []
        far = []
        lock.unlock()
        log.warn("live aec: \(reason) — leaving the cleaned track to the offline pass")
        try? FileManager.default.removeItem(at: partial)
    }

    // MARK: - TrackMonitor

    /// Runs on the writer's queue while it holds its lock, so this copies and
    /// returns. Nothing here may call back into the writer.
    func trackDidWrite(
        _ buffer: AVAudioPCMBuffer, at frame: AVAudioFramePosition, from name: String
    ) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        lock.lock()
        guard !abandoned else { lock.unlock(); return }
        guard buffer.format.sampleRate == rate, buffer.format.channelCount == 1 else {
            lock.unlock()
            abandon("\(name) is \(buffer.format.short), expected 1ch \(Int(rate))Hz")
            return
        }

        let isNear = name == nearName
        var contiguous = true
        if isNear {
            if near.isEmpty && nextFrame == 0 && nearBase == 0 && frame >= 0 {
                nearBase = frame
                nextFrame = frame
            }
            contiguous = frame == nearBase + Int64(near.count)
            if contiguous { near.append(contentsOf: UnsafeBufferPointer(start: samples, count: count)) }
        } else {
            if far.isEmpty && farBase == 0 && frame >= 0 { farBase = frame }
            contiguous = frame == farBase + Int64(far.count)
            if contiguous { far.append(contentsOf: UnsafeBufferPointer(start: samples, count: count)) }
        }
        let buffered = Double(near.count) / rate
        lock.unlock()

        guard contiguous else {
            abandon("\(name) frames arrived out of order")
            return
        }
        guard buffered < Self.maxBufferedSeconds else {
            abandon("\(String(format: "%.0f", buffered))s of near audio unprocessed")
            return
        }
        schedulePump()
    }

    // MARK: -

    private func schedulePump() {
        lock.lock()
        guard !abandoned, !pumpScheduled, farOffset != nil else { lock.unlock(); return }
        pumpScheduled = true
        lock.unlock()
        work.async { [self] in
            lock.lock()
            pumpScheduled = false
            lock.unlock()
            pump(draining: false)
        }
    }

    /// One 10ms frame at a time, in batches, so the AAC encode and the file
    /// write happen once per second of audio rather than per frame.
    private func pump(draining: Bool) {
        let batchFrames = 100
        while true {
            var output = [Float]()
            var stalled = false
            lock.lock()
            guard !abandoned, let canceller, let farOffset else { lock.unlock(); return }

            var produced = 0
            var scratchNear = [Float](repeating: 0, count: frameSize)
            var scratchFar = [Float](repeating: 0, count: frameSize)
            var scratchOut = [Float](repeating: 0, count: frameSize)

            while produced < batchFrames {
                let start = nextFrame
                let nearOffset = Int(start - nearBase)
                guard nearOffset >= 0, near.count - nearOffset >= frameSize else {
                    stalled = true
                    break
                }

                // Far track frames covering this near frame. Missing far is
                // silence: either the system tap started later, or it has not
                // caught up and we have waited long enough to stop caring.
                let farStart = start + farOffset
                let farOffsetInBuffer = Int(farStart - farBase)
                let farAvailable = farOffsetInBuffer >= 0
                    && far.count - farOffsetInBuffer >= frameSize
                let farStartsLater = farStart < farBase
                if !farAvailable && !farStartsLater && !draining {
                    if let since = blockedSince {
                        if Date().timeIntervalSince(since) < Self.maxFarWait {
                            stalled = true
                            break
                        }
                    } else {
                        blockedSince = Date()
                        stalled = true
                        break
                    }
                }
                blockedSince = nil

                near.withUnsafeBufferPointer { source in
                    scratchNear.withUnsafeMutableBufferPointer { destination in
                        destination.baseAddress?.update(
                            from: source.baseAddress! + nearOffset, count: frameSize
                        )
                    }
                }
                if farAvailable {
                    far.withUnsafeBufferPointer { source in
                        scratchFar.withUnsafeMutableBufferPointer { destination in
                            destination.baseAddress?.update(
                                from: source.baseAddress! + farOffsetInBuffer, count: frameSize
                            )
                        }
                    }
                } else {
                    for i in 0..<frameSize { scratchFar[i] = 0 }
                }

                let ok = scratchNear.withUnsafeBufferPointer { nearPointer in
                    scratchFar.withUnsafeBufferPointer { farPointer in
                        scratchOut.withUnsafeMutableBufferPointer { outPointer in
                            quill_aec_process(
                                canceller,
                                nearPointer.baseAddress,
                                farPointer.baseAddress,
                                outPointer.baseAddress,
                                Int32(frameSize)
                            )
                        }
                    }
                }
                guard ok == 1 else {
                    lock.unlock()
                    abandon("AEC3 processing failed")
                    return
                }
                output.append(contentsOf: scratchOut)
                nextFrame += Int64(frameSize)
                produced += 1
            }

            compactLocked()
            lock.unlock()

            if !output.isEmpty { write(output) }
            if stalled || output.isEmpty { return }
        }
    }

    /// Drop consumed samples once there is a second of them, so the arrays stay
    /// bounded without paying a shift per frame.
    private func compactLocked() {
        let nearConsumed = Int(nextFrame - nearBase)
        if nearConsumed > Int(rate) {
            near.removeFirst(nearConsumed)
            nearBase += Int64(nearConsumed)
        }
        guard let farOffset else { return }
        let farConsumed = Int(nextFrame + farOffset - farBase)
        if farConsumed > Int(rate) {
            let drop = min(farConsumed, far.count)
            far.removeFirst(drop)
            farBase += Int64(drop)
        }
    }

    private func write(_ samples: [Float]) {
        lock.lock()
        guard !abandoned, let file else { lock.unlock(); return }
        lock.unlock()

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let destination = buffer.floatChannelData?[0]
        else {
            abandon("couldn't allocate an output buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: samples.count)
        }
        do {
            try file.write(from: buffer)
        } catch {
            abandon("write failed: \(error)")
        }
    }

    private func publish() {
        lock.lock()
        guard !abandoned else { lock.unlock(); return }
        // Releasing the AVAudioFile is what finalizes it.
        file = nil
        let seconds = Double(nextFrame) / rate
        lock.unlock()

        do {
            if FileManager.default.fileExists(atPath: published.path) {
                try FileManager.default.removeItem(at: published)
            }
            try FileManager.default.moveItem(at: partial, to: published)
            log.log(String(format: "live aec: cleaned %.1fs during the meeting", seconds))
        } catch {
            abandon("couldn't publish the cleaned track: \(error)")
        }
    }
}
