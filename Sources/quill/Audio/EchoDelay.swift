import Accelerate
import AVFoundation
import Foundation

/// How far the microphone trails the call, from the two tracks' loudness. A
/// call heard through the speakers reaches the microphone after an acoustic
/// delay, so the microphone's loudness tracks the call's at that lag.
enum EchoDelay {
    struct Estimate: Sendable {
        let milliseconds: Int
        let correlation: Double

        /// Without echo, turn-taking leaves every lag uncorrelated or negative,
        /// and the best of them lands on an edge of the search.
        var foundEcho: Bool {
            correlation >= EchoDelay.minimumCorrelation
                && milliseconds > lags.lowerBound * frameMilliseconds
                && milliseconds < lags.upperBound * frameMilliseconds
        }

        var description: String {
            foundEcho
                ? String(format: "trails the call by %d ms (correlation %.2f)", milliseconds, correlation)
                : String(format: "no echo found (best correlation %.2f)", correlation)
        }
    }

    static let frameMilliseconds = 10
    static let lags = -50...200
    static let minimumCorrelation = 0.2

    /// Offsets place each file on the session timeline. Negative lags are
    /// searched too: a microphone that leads the call means a misaligned
    /// timeline, not an acoustic path.
    static func estimate(
        microphone: URL, microphoneOffsetMilliseconds: Int,
        call: URL, callOffsetMilliseconds: Int
    ) throws -> Estimate? {
        let mic = standardized(try loudness(microphone))
        let reference = standardized(try loudness(call))
        let base = (callOffsetMilliseconds - microphoneOffsetMilliseconds) / frameMilliseconds
        var best: Estimate?
        for lag in lags {
            guard let value = correlation(reference, mic, shift: base + lag) else { continue }
            if value > best?.correlation ?? -.infinity {
                best = Estimate(milliseconds: lag * frameMilliseconds, correlation: value)
            }
        }
        return best
    }

    /// Correlation of `a[k]` with `b[k + shift]` over the frames both cover.
    static func correlation(_ a: [Float], _ b: [Float], shift: Int) -> Double? {
        let start = max(0, -shift)
        let end = min(a.count, b.count - shift)
        let count = end - start
        guard count > 100 else { return nil }
        var sum: Float = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                vDSP_dotpr(a.baseAddress! + start, 1, b.baseAddress! + start + shift, 1, &sum, vDSP_Length(count))
            }
        }
        return Double(sum) / Double(count)
    }

    /// Mean-square loudness in decibels per 10 ms frame, mixed to mono. Decibels
    /// rather than power, so quiet echo under loud local speech still counts.
    static func loudness(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let hop = AVAudioFrameCount(format.sampleRate * Double(frameMilliseconds) / 1000)
        guard hop > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: hop * 500),
              let channels = buffer.floatChannelData
        else { return [] }
        var frames: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: hop * 500)
            let read = Int(buffer.frameLength)
            guard read > 0 else { break }
            for frame in stride(from: 0, to: read - Int(hop) + 1, by: Int(hop)) {
                var power: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    var meanSquare: Float = 0
                    vDSP_measqv(channels[channel] + frame, 1, &meanSquare, vDSP_Length(hop))
                    power += meanSquare
                }
                frames.append(10 * log10(power / Float(format.channelCount) + 1e-10))
            }
        }
        return frames
    }

    private static func standardized(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        var mean: Float = 0
        var deviation: Float = 0
        var output = [Float](repeating: 0, count: values.count)
        vDSP_normalize(values, 1, &output, 1, &mean, &deviation, vDSP_Length(values.count))
        return deviation > 0 ? output : [Float](repeating: 0, count: values.count)
    }
}
