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
            track: .system,
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
            track: .microphone,
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
            track: .microphone,
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

    @Test func stalledLiveConsumerCannotDelaySourceArchive() throws {
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
        let enteredConsumer = DispatchSemaphore(value: 0)
        let releaseConsumer = DispatchSemaphore(value: 0)
        let overflows = LockedCounter()
        let healthyDeliveries = LockedCounter()
        let healthyOverflows = LockedCounter()
        let mailbox = AcceptedFrameMailbox(
            maxQueuedFrames: 4_800,
            consume: { _ in
                enteredConsumer.signal()
                releaseConsumer.wait()
                return true
            },
            onOverflow: { _ = overflows.increment() }
        )
        let healthyMailbox = AcceptedFrameMailbox(
            maxQueuedFrames: 48_000,
            consume: { _ in
                _ = healthyDeliveries.increment()
                return true
            },
            onOverflow: { _ = healthyOverflows.increment() }
        )
        let writer = try TrackWriter(
            url: output,
            format: format,
            track: .microphone,
            log: SessionLog(dir: directory),
            watchSilence: false
        )
        writer.sendAcceptedFrames(to: AcceptedFrameFanout([mailbox, healthyMailbox]))

        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_800
        ))
        buffer.frameLength = 4_800
        writer.write(buffer)
        #expect(enteredConsumer.wait(timeout: .now() + 1) == .success)

        writer.write(buffer)
        writer.write(buffer)
        let closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            writer.close(paddingTo: Date())
            closed.signal()
        }
        let closedWithoutConsumer = closed.wait(timeout: .now() + 1)
        releaseConsumer.signal()
        if closedWithoutConsumer == .timedOut {
            _ = closed.wait(timeout: .now() + 5)
        }
        mailbox.finish()
        healthyMailbox.finish()

        #expect(closedWithoutConsumer == .success)
        #expect(overflows.value == 1)
        #expect(healthyDeliveries.value == 3)
        #expect(healthyOverflows.value == 0)
        #expect(try AVAudioFile(forReading: output).length == 14_400)
    }

    @Test func acceptedFramesIdentifyCapturedAndInsertedSilence() throws {
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
        let origins = LockedOrigins()
        let mailbox = AcceptedFrameMailbox(
            maxQueuedFrames: 96_000,
            consume: {
                origins.append($0.origin)
                return true
            },
            onOverflow: {}
        )
        let writer = try TrackWriter(
            url: directory.appendingPathComponent("mic.caf"),
            format: format,
            track: .microphone,
            log: SessionLog(dir: directory),
            watchSilence: false
        )
        writer.sendAcceptedFrames(to: mailbox)

        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_800
        ))
        buffer.frameLength = 4_800
        writer.write(buffer)
        writer.close(paddingTo: Date().addingTimeInterval(1))
        mailbox.finish()

        #expect(origins.values.first == .captured)
        #expect(origins.values.contains(.insertedSilence))
    }

    @Test func captureGapRaisesRecoverySignalButClosePaddingDoesNot() throws {
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
        let writer = try TrackWriter(
            url: directory.appendingPathComponent("system.caf"),
            format: format,
            track: .system,
            log: SessionLog(dir: directory),
            watchSilence: false
        )
        let gaps = LockedCounter()
        writer.onCaptureGap = { _ in _ = gaps.increment() }
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_800
        ))
        buffer.frameLength = 4_800

        writer.write(buffer)
        Thread.sleep(forTimeInterval: 0.8)
        writer.write(buffer)
        writer.close(paddingTo: Date().addingTimeInterval(1))

        #expect(gaps.value == 1)
    }

    @Test @MainActor func asynchronousCloseSuspendsInsteadOfBlockingMainActor() async throws {
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
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let fallbackUsed = LockedCounter()
        let writer = try TrackWriter(
            url: directory.appendingPathComponent("mic.caf"),
            format: format,
            track: .microphone,
            log: SessionLog(dir: directory),
            watchSilence: false,
            fileWrite: { file, buffer in
                writeStarted.signal()
                releaseWrite.wait()
                try file.write(from: buffer)
            }
        )
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_800
        ))
        buffer.frameLength = 4_800
        writer.write(buffer)
        let didStart = await Task.detached {
            waitForSemaphore(writeStarted, timeout: .now() + 1)
        }.value
        #expect(didStart == .success)

        let close = Task { @MainActor in
            await writer.closeAsync(paddingTo: Date())
        }
        let fallback = DispatchWorkItem {
            _ = fallbackUsed.increment()
            releaseWrite.signal()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: fallback)
        await Task.yield()

        #expect(fallbackUsed.value == 0)
        fallback.cancel()
        releaseWrite.signal()
        await close.value
        #expect(try AVAudioFile(forReading: directory.appendingPathComponent("mic.caf")).length == 4_800)
    }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
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

private final class LockedOrigins: @unchecked Sendable {
    private let lock = NSLock()
    private var origins: [AcceptedFrame.Origin] = []

    func append(_ origin: AcceptedFrame.Origin) {
        lock.lock()
        origins.append(origin)
        lock.unlock()
    }

    var values: [AcceptedFrame.Origin] {
        lock.lock()
        defer { lock.unlock() }
        return origins
    }
}
