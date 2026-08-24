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

    @Test func sourceWriteFailureIsTerminalAndReportedOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("mic.caf")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let attempts = LockedCounter()
        let failures = LockedMessages()
        let writer = try TrackWriter(
            url: output,
            format: format,
            name: "mic",
            log: SessionLog(dir: directory),
            watchSilence: false,
            fileWrite: { file, buffer in
                if attempts.increment() == 2 {
                    throw NSError(domain: "TrackWriterTests", code: 28)
                }
                try file.write(from: buffer)
            }
        )
        writer.onWriteFailure = { failures.append($0) }

        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_800
        ))
        buffer.frameLength = 4_800
        for _ in 0..<3 { writer.write(buffer) }
        writer.close(paddingTo: Date())

        #expect(attempts.value == 2)
        #expect(failures.values.count == 1)
        #expect(try AVAudioFile(forReading: output).length == 4_800)
    }

    @Test func failureWhileClosingRemainsSynchronouslyVisible() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let attempts = LockedCounter()
        let failures = LockedMessages()
        let writer = try TrackWriter(
            url: directory.appendingPathComponent("mic.caf"),
            format: format,
            name: "mic",
            log: SessionLog(dir: directory),
            watchSilence: false,
            fileWrite: { file, buffer in
                if attempts.increment() == 2 {
                    throw NSError(domain: "TrackWriterTests", code: 28)
                }
                try file.write(from: buffer)
            }
        )
        writer.onWriteFailure = { failures.append($0) }

        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_800
        ))
        buffer.frameLength = 4_800
        writer.write(buffer)
        writer.close(paddingTo: Date().addingTimeInterval(1))

        #expect(writer.writeFailure != nil)
        #expect(failures.values.count == 1)
        #expect(attempts.value == 2)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class LockedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
