import AVFoundation
import Foundation
import Testing
@testable import quill

@Suite struct TrackWriterTests {
    /// AVAudioConverter answers a 2ch to 1ch request with the left channel
    /// alone, so a right-panned participant would vanish. Content on one
    /// channel has to survive at half amplitude, not full and not zero.
    @Test func averagesStereoCaptureIntoAMonoTrack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("system.caf")
        let fileFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000,
            channels: 1, interleaved: false
        ))
        let tapFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000,
            channels: 2, interleaved: true
        ))

        let writer = try TrackWriter(
            url: output,
            format: fileFormat,
            name: "system",
            log: SessionLog(dir: directory),
            watchSilence: false
        )

        let blockFrames = 4096
        var phase = 0.0
        let step = 2 * Double.pi * 440 / 48000
        for _ in 0..<Int(48000 / Double(blockFrames)) {
            let block = try #require(AVAudioPCMBuffer(
                pcmFormat: tapFormat, frameCapacity: AVAudioFrameCount(blockFrames)
            ))
            block.frameLength = AVAudioFrameCount(blockFrames)
            let samples = try #require(block.floatChannelData)[0]
            for frame in 0..<blockFrames {
                samples[2 * frame] = Float(0.5 * sin(phase))
                samples[2 * frame + 1] = 0
                phase += step
            }
            writer.write(block)
        }
        writer.close(paddingTo: Date())

        let file = try AVAudioFile(forReading: output)
        #expect(file.processingFormat.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        var peak: Float = 0
        let samples = try #require(buffer.floatChannelData)[0]
        for frame in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[frame]))
        }
        #expect(peak > 0.2 && peak < 0.3, "expected ~0.25, got \(peak)")
    }
}
