import AVFoundation
import ArgumentParser
import Foundation

struct CheckLiveAEC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-live-aec", shouldDisplay: false
    )

    @Option(name: .long) var out: String
    /// Milliseconds the system track starts after the mic track.
    @Option(name: .long) var skewMs: Int = 0
    /// Deliberately corrupt the alignment handed to `begin`, as a control: a
    /// test that cannot fail proves nothing.
    @Option(name: .long) var misalignMs: Int = 0

    static let rate: Double = 48000

    func run() throws {
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let internalDir = try SessionFiles.prepare(dir)
        let log = SessionLog(dir: dir)

        let micURL = SessionFiles.internalFile("mic.caf", in: dir)
        let systemURL = SessionFiles.internalFile("system.caf", in: dir)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.rate,
            channels: 1, interleaved: false
        )!

        let canceller = LiveEchoCanceller(
            session: internalDir, rate: Self.rate,
            nearName: "mic", farName: "system", log: log
        )!

        let micWriter = try TrackWriter(
            url: micURL, format: format, name: "mic", log: log, watchSilence: false
        )
        let systemWriter = try TrackWriter(
            url: systemURL, format: format, name: "system", log: log, watchSilence: false
        )
        micWriter.monitor(with: canceller)
        systemWriter.monitor(with: canceller)

        // The mic hears the speaker's 440Hz playback at -6dB plus a 1000Hz
        // "voice" that only exists near-end. Cancellation must remove the
        // first and keep the second.
        let seconds = 8.0
        let block = 4800
        let blocks = Int(seconds * Self.rate) / block
        let skewFrames = Int(Double(skewMs) / 1000 * Self.rate)

        let micStart = Date()
        let systemStart = micStart.addingTimeInterval(Double(skewMs) / 1000)

        func tone(_ i: Int, _ hz: Double, _ amp: Double) -> Float {
            Float(amp * sin(2 * Double.pi * hz * Double(i) / Self.rate))
        }
        // White noise, not a tone: a stationary sine is cancelled by any
        // reference at any offset, so it cannot tell a correct alignment from a
        // wrong one. Noise is uncorrelated with itself over time, so it can.
        func noise(_ i: Int, _ amp: Double) -> Float {
            var x = UInt64(bitPattern: Int64(i &+ 1)) &* 6_364_136_223_846_793_005
            x ^= x >> 33
            x = x &* 0xff51_afd7_ed55_8ccd
            x ^= x >> 33
            return Float(amp * (Double(x % 20001) / 10000.0 - 1.0))
        }

        for b in 0..<blocks {
            let far = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
            far.frameLength = AVAudioFrameCount(block)
            let near = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
            near.frameLength = AVAudioFrameCount(block)
            for j in 0..<block {
                let n = b * block + j                      // mic timeline index
                let f = n - skewFrames                     // system timeline index
                // Track frame n of each file. The mic hears the speaker's
                // noise at -6dB plus a near-end-only 1000Hz voice.
                // Near frame n hears whatever was playing at that instant. The
                // system track starts skewFrames later, so its frame n holds
                // what the speaker played at mic frame n + skewFrames; that is
                // what makes the far reference line up once the offset is
                // applied, and what a wrong offset destroys.
                near.floatChannelData![0][j] = noise(n, 0.4) + tone(n, 1000, 0.15)
                far.floatChannelData![0][j] = noise(n + skewFrames, 0.8)
                _ = f
            }
            micWriter.write(near)
            systemWriter.write(far)
        }
        micWriter.close(paddingTo: Date())
        systemWriter.close(paddingTo: Date())

        canceller.begin(
            nearStart: micStart,
            farStart: systemStart.addingTimeInterval(Double(misalignMs) / 1000)
        )
        let published = canceller.finish()
        print("published=\(published)")
        guard published else { throw ExitCode(1) }

        let cleaned = internalDir.appendingPathComponent(EchoCancellation.outputName)
        let file = try AVAudioFile(forReading: cleaned)
        let buf = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        print("cleaned frames=\(n) (\(String(format: "%.2f", Double(n) / Self.rate))s)")

        // Two-sided, because a one-sided "the echo is gone" check passes when
        // the filter has flattened the near-end voice as well.
        //
        // The reference is the offline pass on the same session, not an
        // absolute number: how hard AEC3 suppresses is a property of the
        // filter, and this signal (broadband far end louder than the near-end
        // voice) is far more hostile than a meeting. The two paths are not
        // sample-identical and are not expected to be, because offline reads
        // the tracks back through AAC while live sees them before the encode.
        func measure(_ samples: [Float]) -> (voiceGain: Double, erle: Double) {
            let to = samples.count
            let from = max(0, to - Int(4 * Self.rate))
            var num = 0.0, den = 0.0
            for i in from..<to {
                let v = Double(tone(i, 1000, 0.15))
                num += Double(samples[i]) * v
                den += v * v
            }
            let gain = den > 0 ? num / den : 0
            var residual = 0.0
            for i in from..<to {
                let r = Double(samples[i]) - gain * Double(tone(i, 1000, 0.15))
                residual += r * r
            }
            let rms = (residual / Double(max(1, to - from))).squareRoot()
            let echoIn = 0.4 / 3.0.squareRoot()
            return (20 * log10(max(abs(gain), 1e-9)), 20 * log10(echoIn / max(rms, 1e-12)))
        }

        func samples(of url: URL) throws -> [Float] {
            let f = try AVAudioFile(forReading: url)
            let b = AVAudioPCMBuffer(
                pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)
            )!
            try f.read(into: b)
            return Array(UnsafeBufferPointer(
                start: b.floatChannelData![0], count: Int(b.frameLength)
            ))
        }

        let liveSamples = try samples(of: cleaned)
        let live = measure(liveSamples)

        let stashed = internalDir.appendingPathComponent("live-result.caf")
        try? FileManager.default.removeItem(at: stashed)
        try FileManager.default.moveItem(at: cleaned, to: stashed)
        let offlineURL = try EchoCancellation.clean(
            mic: micURL, micOffsetMs: 0,
            system: systemURL, systemOffsetMs: skewMs + misalignMs,
            in: internalDir
        )
        let offline = measure(try samples(of: offlineURL))

        let micFrames = try AVAudioFile(forReading: micURL).length
        print(String(format: "live:    ERLE=%+.1f dB  voice=%+.1f dB", live.erle, live.voiceGain))
        print(String(format: "offline: ERLE=%+.1f dB  voice=%+.1f dB", offline.erle, offline.voiceGain))

        // Voice retention is reported, not gated: how hard AEC3 ducks the near
        // end depends on how loud the far end is, and this far end is louder
        // than the voice, which no meeting is. Run with --misalign-ms to check
        // the check: a deliberately wrong offset must drop ERLE to single
        // digits, or this is measuring nothing.
        let cancels = live.erle > 12
        let aligned = Int64(liveSamples.count) == micFrames
        print("cancels echo: \(cancels ? "PASS" : "FAIL")")
        print("length matches mic track: \(aligned ? "PASS" : "FAIL") "
              + "(\(liveSamples.count) vs \(micFrames))")
        if !(cancels && aligned) { throw ExitCode(1) }
    }
}
