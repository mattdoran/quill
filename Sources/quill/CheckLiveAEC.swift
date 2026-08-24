import AVFoundation
import ArgumentParser
import Foundation

/// Exercises `LiveEchoCanceller` through the real `TrackWriter` monitor path.
///
/// Two modes. `--session` replays a finished recording, which is the only way
/// to see real echo, real device skew and real double talk; it scores the live
/// pass against `Local Cleaned.m4a`, the offline output that shipped for that
/// meeting. Synthetic mode exists for `--misalign-ms`, the control: a
/// deliberately wrong offset has to wreck the result, or the numbers are
/// measuring nothing.
struct CheckLiveAEC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-live-aec", shouldDisplay: false
    )

    @Option(name: .long, help: "A finished session directory to replay.")
    var session: String?

    @Option(name: .long) var out: String

    @Option(name: .long, help: "Synthetic mode: ms the system track starts after the mic.")
    var skewMs: Int = 0

    @Option(name: .long, help: "Corrupt the alignment by this much, as a control.")
    var misalignMs: Int = 0

    /// Faster than real time, but not so fast that the writers hit their drop
    /// cap: a replay that drops buffers is measuring the drop, not the filter.
    @Option(name: .long) var speed: Double = 40

    @Flag(name: .customLong("finalize"), help: "Publish the replay as a finished session.")
    var finalizeOutput = false

    static let rate: Double = 48000
    static let frame = 4800

    func run() throws {
        if let session {
            try replay(URL(fileURLWithPath: session, isDirectory: true))
        } else {
            try synthetic()
        }
    }

    // MARK: - Real recordings

    private func replay(_ recording: URL) throws {
        let sourceDir = recording.appendingPathComponent("Source Audio", isDirectory: true)
        let nearURL = sourceDir.appendingPathComponent("Local.m4a")
        let farURL = sourceDir.appendingPathComponent("Remote.m4a")
        let referenceURL = sourceDir.appendingPathComponent("Local Cleaned.m4a")
        for url in [nearURL, farURL, referenceURL] where !FileManager.default.fileExists(
            atPath: url.path
        ) {
            throw ValidationError("missing \(url.lastPathComponent)")
        }

        var meta = try SessionMetadataStore.readManifest(recording)
        let nearOffset = meta.startOffsets.microphone
        let farOffset = meta.startOffsets.system

        let nearFile = try AVAudioFile(forReading: nearURL)
        let farFile = try AVAudioFile(forReading: farURL)
        print("""
        \(recording.lastPathComponent)
          near \(String(format: "%.1f", Double(nearFile.length) / nearFile.processingFormat.sampleRate))s, \
        far \(String(format: "%.1f", Double(farFile.length) / farFile.processingFormat.sampleRate))s, \
        skew \(nearOffset - farOffset)ms
        """)

        let live = try runLive(
            near: nearURL, far: farURL,
            nearOffsetMs: nearOffset, farOffsetMs: farOffset + misalignMs,
            into: URL(fileURLWithPath: out, isDirectory: true)
        )
        let scores = try score(
            near: nearURL, far: farURL, live: live.cleaned, reference: referenceURL
        )

        print(String(
            format: "  far-loud windows: %d   far-quiet windows: %d",
            scores.echoWindows, scores.quietWindows
        ))
        print(String(
            format: "  echo reduction   live %+5.1f dB   offline %+5.1f dB",
            scores.liveERLE, scores.referenceERLE
        ))
        print(String(
            format: "  near-end kept    live %+5.1f dB   offline %+5.1f dB",
            scores.liveQuiet, scores.referenceQuiet
        ))

        let cleanedFile = try AVAudioFile(forReading: live.cleaned)
        let lengthDifference = abs(cleanedFile.length - nearFile.length)
        let lengthOK = lengthDifference <= AVAudioFramePosition(Self.rate / 10)
        let meetingFile = try AVAudioFile(forReading: live.meeting)
        let expectedMeetingFrames = max(
            AVAudioFramePosition(Double(nearOffset) / 1000 * Self.rate) + nearFile.length,
            AVAudioFramePosition(Double(farOffset + misalignMs) / 1000 * Self.rate)
                + farFile.length
        )
        let meetingOK = meetingFile.processingFormat.channelCount == 1
            && abs(meetingFile.length - expectedMeetingFrames)
                <= AVAudioFramePosition(Self.rate / 10)
        // Within 3 dB of the pass it replaces, on real audio, in both
        // directions: worse cancellation is a regression and so is a quieter
        // near end, which is what ASR reads.
        let cancels = scores.liveERLE > scores.referenceERLE - 3
        let keeps = scores.liveQuiet > scores.referenceQuiet - 3
        print("  echo reduction vs offline: \(cancels ? "PASS" : "FAIL")")
        print("  near end vs offline:       \(keeps ? "PASS" : "FAIL")")
        print("  length matches near track: \(lengthOK ? "PASS" : "FAIL")"
              + " (\(cleanedFile.length) vs \(nearFile.length))")
        print("  mono meeting mix complete: \(meetingOK ? "PASS" : "FAIL")"
              + " (\(meetingFile.length) vs \(expectedMeetingFrames))")
        if !(cancels && keeps && lengthOK && meetingOK) { throw ExitCode(1) }

        if finalizeOutput {
            let replay = URL(fileURLWithPath: out, isDirectory: true)
            meta.files = SessionAudioFiles(
                microphone: SessionFiles.internalPath("mic.caf"),
                system: SessionFiles.internalPath("system.caf")
            )
            meta.audioState = nil
            if var microphone = meta.tracks.microphone {
                microphone.file = SessionFiles.internalPath("mic.caf")
                meta.tracks.microphone = microphone
            }
            if var system = meta.tracks.system {
                system.file = SessionFiles.internalPath("system.caf")
                meta.tracks.system = system
            }
            try SessionMetadataStore.writeManifest(meta, to: replay)

            let started = Date()
            try finalize(replay)
            let elapsed = Date().timeIntervalSince(started)
            let published = replay.appendingPathComponent(AudioFinalizer.meetingAudioPath)
            let publishedFile = try AVAudioFile(forReading: published)
            print(String(
                format: "  finalization: %.2fs, %dch, %.1fs",
                elapsed,
                publishedFile.processingFormat.channelCount,
                Double(publishedFile.length) / publishedFile.processingFormat.sampleRate
            ))
        }
    }

    private final class FinalizationResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?

        func store(_ result: Result<Void, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func get() -> Result<Void, Error> {
            lock.lock()
            defer { lock.unlock() }
            return result!
        }
    }

    private func finalize(_ session: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let result = FinalizationResult()
        Task.detached {
            do {
                try await AudioFinalizer.shared.finalize(session: session)
                result.store(.success(()))
            } catch {
                result.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        try result.get().get()
    }

    // MARK: - Synthetic control

    private func synthetic() throws {
        let seconds = 8.0
        let total = Int(seconds * Self.rate)
        let skewFrames = Int(Double(skewMs) / 1000 * Self.rate)
        var near = [Float](repeating: 0, count: total)
        var far = [Float](repeating: 0, count: total)
        for n in 0..<total {
            near[n] = noise(n + skewFrames, 0.4) + tone(n, 1000, 0.15)
            far[n] = noise(n, 0.8)
        }

        let live = try runLive(
            near: near, far: far,
            nearOffsetMs: skewMs, farOffsetMs: misalignMs,
            into: URL(fileURLWithPath: out, isDirectory: true)
        )
        let cleaned = try decode(live.cleaned)

        let from = max(0, cleaned.count - Int(4 * Self.rate))
        var num = 0.0, den = 0.0
        for i in from..<cleaned.count {
            let v = Double(tone(i, 1000, 0.15))
            num += Double(cleaned[i]) * v
            den += v * v
        }
        let gain = den > 0 ? num / den : 0
        var residual = 0.0
        for i in from..<cleaned.count {
            let r = Double(cleaned[i]) - gain * Double(tone(i, 1000, 0.15))
            residual += r * r
        }
        let rms = (residual / Double(max(1, cleaned.count - from))).squareRoot()
        let erle = 20 * log10((0.4 / 3.0.squareRoot()) / max(rms, 1e-12))
        let meetingFile = try AVAudioFile(forReading: live.meeting)
        let meeting = try decode(live.meeting)
        let earliestOffset = min(skewMs, misalignMs)
        let expectedMeetingFrames = max(
            AVAudioFramePosition(Double(skewMs - earliestOffset) / 1000 * Self.rate)
                + AVAudioFramePosition(near.count),
            AVAudioFramePosition(Double(misalignMs - earliestOffset) / 1000 * Self.rate)
                + AVAudioFramePosition(far.count)
        )
        let meetingOK = meetingFile.processingFormat.channelCount == 1
            && abs(meetingFile.length - expectedMeetingFrames)
                <= AVAudioFramePosition(Self.rate / 100)
        let farAudible = signalRMS(meeting) > signalRMS(cleaned) * 2
        print(String(
            format: "synthetic skew=%dms misalign=%dms  ERLE=%+.1f dB  voice=%+.1f dB",
            skewMs, misalignMs, erle, 20 * log10(max(abs(gain), 1e-9))
        ))
        let ok = erle > 12
        print("cancels echo: \(ok ? "PASS" : "FAIL")")
        print("mono meeting mix complete: \(meetingOK ? "PASS" : "FAIL")"
              + " (\(meetingFile.length) vs \(expectedMeetingFrames))")
        print("far end present in meeting: \(farAudible ? "PASS" : "FAIL")")
        if !(ok && meetingOK && farAudible) { throw ExitCode(1) }
    }

    // MARK: -

    /// Feeds both signals through real `TrackWriter`s so the monitor path under
    /// test is the one that runs during a meeting.
    private struct LiveOutputs {
        let cleaned: URL
        let meeting: URL
    }

    private func runLive(
        near: [Float], far: [Float], nearOffsetMs: Int, farOffsetMs: Int, into directory: URL
    ) throws -> LiveOutputs {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.rate,
            channels: 1, interleaved: false
        )!
        return try runLive(
            nearOffsetMs: nearOffsetMs,
            farOffsetMs: farOffsetMs,
            into: directory
        ) { nearWriter, farWriter in
            var offset = 0
            while offset < max(near.count, far.count) {
                if offset < near.count { nearWriter.write(buffer(near, offset, format)) }
                if offset < far.count { farWriter.write(buffer(far, offset, format)) }
                offset += Self.frame
            }
        }
    }

    private func runLive(
        near: URL, far: URL, nearOffsetMs: Int, farOffsetMs: Int, into directory: URL
    ) throws -> LiveOutputs {
        let nearFile = try AVAudioFile(forReading: near)
        let farFile = try AVAudioFile(forReading: far)
        guard nearFile.processingFormat.sampleRate == Self.rate,
              farFile.processingFormat.sampleRate == Self.rate else {
            throw ValidationError("replay expects 48 kHz source tracks")
        }
        return try runLive(
            nearOffsetMs: nearOffsetMs,
            farOffsetMs: farOffsetMs,
            into: directory
        ) { nearWriter, farWriter in
            while nearFile.framePosition < nearFile.length
                || farFile.framePosition < farFile.length
            {
                if let buffer = try read(nearFile) { nearWriter.write(buffer) }
                if let buffer = try read(farFile) { farWriter.write(buffer) }
                Thread.sleep(forTimeInterval: (Double(Self.frame) / Self.rate) / speed)
            }
        }
    }

    private func runLive(
        nearOffsetMs: Int,
        farOffsetMs: Int,
        into directory: URL,
        feed: (TrackWriter, TrackWriter) throws -> Void
    ) throws -> LiveOutputs {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let internalDir = try SessionFiles.prepare(directory)
        let log = SessionLog(dir: directory)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.rate,
            channels: 1, interleaved: false
        )!

        guard let canceller = LiveEchoCanceller(
            session: internalDir, rate: Self.rate, log: log
        ) else { throw ValidationError("couldn't create the canceller") }

        let nearWriter = try TrackWriter(
            url: SessionFiles.internalFile("mic.caf", in: directory),
            format: outputFormat, track: .microphone, log: log, watchSilence: false
        )
        let farWriter = try TrackWriter(
            url: SessionFiles.internalFile("system.caf", in: directory),
            format: outputFormat, track: .system, log: log, watchSilence: false
        )
        let mailbox = AcceptedFrameMailbox(
            maxQueuedFrames: Int(Self.rate * 30),
            consume: { canceller.consume($0) },
            onOverflow: { canceller.abandon("accepted-frame mailbox overflow") }
        )
        let fanout = AcceptedFrameFanout([mailbox])
        nearWriter.sendAcceptedFrames(to: fanout)
        farWriter.sendAcceptedFrames(to: fanout)

        // Before feeding, as the session does about a second in: the pump
        // cannot run without the offset, and audio piles up until it does.
        canceller.begin(startOffsets: SessionTrackOffsets(
            microphone: nearOffsetMs,
            system: farOffsetMs
        ))

        try feed(nearWriter, farWriter)
        let ended = Date()
        nearWriter.close(paddingTo: ended)
        farWriter.close(paddingTo: ended)
        mailbox.finish()

        guard canceller.finish() else { throw ValidationError("live pass abandoned") }
        return LiveOutputs(
            cleaned: internalDir.appendingPathComponent(EchoCancellation.outputName),
            meeting: internalDir.appendingPathComponent(LiveEchoCanceller.meetingOutputName)
        )
    }

    private func read(_ file: AVAudioFile) throws -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length else { return nil }
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Self.frame)
        )!
        try file.read(into: buffer, frameCount: AVAudioFrameCount(Self.frame))
        return buffer.frameLength > 0 ? buffer : nil
    }

    private func buffer(
        _ samples: [Float], _ offset: Int, _ format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let count = min(Self.frame, samples.count - offset)
        let out = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(count)
        )!
        out.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { source in
            out.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
        }
        return out
    }

    private func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buffer)
        let channels = Int(format.channelCount)
        let count = Int(buffer.frameLength)
        guard channels > 1 else {
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count))
        }
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channels {
            let data = buffer.floatChannelData![channel]
            for i in 0..<count { mono[i] += data[i] / Float(channels) }
        }
        return mono
    }

    private struct Scores {
        var liveERLE: Double
        var referenceERLE: Double
        var liveQuiet: Double
        var referenceQuiet: Double
        var echoWindows: Int
        var quietWindows: Int
    }

    private func score(near: URL, far: URL, live: URL, reference: URL) throws -> Scores {
        var farLevels: [Double] = []
        let farFile = try AVAudioFile(forReading: far)
        while let buffer = try read(farFile) {
            farLevels.append(rms(buffer))
        }
        guard !farLevels.isEmpty else { throw ValidationError("recording too short") }
        let sorted = farLevels.sorted()
        let loud = sorted[Int(Double(sorted.count) * 0.8)]
        let quiet = sorted[Int(Double(sorted.count) * 0.2)]

        let files = try [near, far, live, reference].map { try AVAudioFile(forReading: $0) }
        var liveEcho = (input: 0.0, output: 0.0, windows: 0)
        var referenceEcho = (input: 0.0, output: 0.0, windows: 0)
        var liveQuiet = (input: 0.0, output: 0.0, windows: 0)
        var referenceQuiet = (input: 0.0, output: 0.0, windows: 0)
        var index = 0
        while true {
            let buffers = try files.map { try read($0) }
            guard buffers.allSatisfy({ $0 != nil }) else { break }
            let nearEnergy = energy(buffers[0]!)
            let level = index < farLevels.count ? farLevels[index] : 0
            if level >= loud, level > 1e-4 {
                liveEcho.input += nearEnergy
                liveEcho.output += energy(buffers[2]!)
                liveEcho.windows += 1
                referenceEcho.input += nearEnergy
                referenceEcho.output += energy(buffers[3]!)
                referenceEcho.windows += 1
            }
            if level <= quiet {
                liveQuiet.input += nearEnergy
                liveQuiet.output += energy(buffers[2]!)
                liveQuiet.windows += 1
                referenceQuiet.input += nearEnergy
                referenceQuiet.output += energy(buffers[3]!)
                referenceQuiet.windows += 1
            }
            index += 1
        }

        func reduction(_ value: (input: Double, output: Double, windows: Int)) -> Double {
            guard value.input > 0 else { return 0 }
            return 10 * log10(value.input / max(value.output, 1e-18))
        }
        return Scores(
            liveERLE: reduction(liveEcho),
            referenceERLE: reduction(referenceEcho),
            liveQuiet: -reduction(liveQuiet),
            referenceQuiet: -reduction(referenceQuiet),
            echoWindows: liveEcho.windows,
            quietWindows: liveQuiet.windows
        )
    }

    private func energy(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        var sum = 0.0
        for frame in 0..<Int(buffer.frameLength) {
            var mono = 0.0
            for channel in 0..<channelCount { mono += Double(channels[channel][frame]) }
            mono /= Double(channelCount)
            sum += mono * mono
        }
        return sum
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        let count = max(1, Int(buffer.frameLength))
        return (energy(buffer) / Double(count)).squareRoot()
    }

    private func signalRMS(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var energy = 0.0
        for sample in samples { energy += Double(sample) * Double(sample) }
        return (energy / Double(samples.count)).squareRoot()
    }

    private func tone(_ i: Int, _ hz: Double, _ amp: Double) -> Float {
        Float(amp * sin(2 * Double.pi * hz * Double(i) / Self.rate))
    }

    private func noise(_ i: Int, _ amp: Double) -> Float {
        var x = UInt64(bitPattern: Int64(i &+ 1)) &* 6_364_136_223_846_793_005
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        return Float(amp * (Double(x % 20001) / 10000.0 - 1.0))
    }
}
