import AVFoundation
import Foundation
import WebRTCAudio

enum EchoCancellation {
    static let outputName = "mic-cleaned.caf"

    enum CancellationError: Error, CustomStringConvertible {
        case unsupportedFormat(String)
        case initializationFailed
        case processingFailed

        var description: String {
            switch self {
            case .unsupportedFormat(let detail): "unsupported audio format: \(detail)"
            case .initializationFailed: "AEC3 initialization failed"
            case .processingFailed: "AEC3 processing failed"
            }
        }
    }

    static func clean(
        mic: URL,
        micOffsetMs: Int,
        system: URL,
        systemOffsetMs: Int,
        in session: URL
    ) throws -> URL {
        let output = session.appendingPathComponent(outputName)
        if let file = try? AVAudioFile(forReading: output), file.length > 0 {
            return output
        }

        let partial = session.appendingPathComponent("\(outputName).partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            try render(
                mic: mic,
                micOffsetMs: micOffsetMs,
                system: system,
                systemOffsetMs: systemOffsetMs,
                output: partial
            )
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.moveItem(at: partial, to: output)
            return output
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private static func render(
        mic: URL,
        micOffsetMs: Int,
        system: URL,
        systemOffsetMs: Int,
        output: URL
    ) throws {
        let micFile = try AVAudioFile(forReading: mic)
        let systemFile = try AVAudioFile(forReading: system)
        let micFormat = micFile.processingFormat
        let systemFormat = systemFile.processingFormat
        guard
            micFormat.commonFormat == .pcmFormatFloat32,
            systemFormat.commonFormat == .pcmFormatFloat32,
            !micFormat.isInterleaved,
            !systemFormat.isInterleaved,
            micFormat.channelCount >= 1,
            systemFormat.channelCount >= 1,
            micFormat.sampleRate == systemFormat.sampleRate,
            [16_000.0, 32_000.0, 48_000.0].contains(micFormat.sampleRate)
        else {
            throw CancellationError.unsupportedFormat(
                "mic=\(micFormat), system=\(systemFormat)"
            )
        }

        let rate = Int(micFormat.sampleRate)
        let frameSize = rate / 100
        let batchSize = frameSize * 100
        guard let canceller = quill_aec_create(Int32(rate)) else {
            throw CancellationError.initializationFailed
        }
        defer { quill_aec_destroy(canceller) }

        guard
            let micBuffer = AVAudioPCMBuffer(
                pcmFormat: micFormat, frameCapacity: AVAudioFrameCount(batchSize)
            ),
            let systemBuffer = AVAudioPCMBuffer(
                pcmFormat: systemFormat, frameCapacity: AVAudioFrameCount(batchSize)
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: micFormat.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(batchSize)
            )
        else {
            throw CancellationError.unsupportedFormat("couldn't allocate processing buffers")
        }
        let outputFile = try AVAudioFile(
            forWriting: output,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: outputFormat.sampleRate,
                AVNumberOfChannelsKey: outputFormat.channelCount,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let farStart = Int64(
            (Double(micOffsetMs - systemOffsetMs) / 1000 * micFormat.sampleRate).rounded()
        )
        var leadingFarFrames = max(0, -farStart)
        if farStart > 0 {
            systemFile.framePosition = min(farStart, systemFile.length)
        }

        var near = [Float](repeating: 0, count: batchSize)
        var far = [Float](repeating: 0, count: batchSize)
        var cleaned = [Float](repeating: 0, count: batchSize)

        while micFile.framePosition < micFile.length {
            micBuffer.frameLength = 0
            try micFile.read(into: micBuffer, frameCount: AVAudioFrameCount(batchSize))
            let validFrames = Int(micBuffer.frameLength)
            guard validFrames > 0, let micChannels = micBuffer.floatChannelData else { break }

            near.withUnsafeMutableBufferPointer { destination in
                destination.initialize(repeating: 0)
                destination.baseAddress?.update(from: micChannels[0], count: validFrames)
            }
            far.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }

            let farPrefix = min(Int(leadingFarFrames), validFrames)
            leadingFarFrames -= Int64(farPrefix)
            let farNeeded = validFrames - farPrefix
            if farNeeded > 0, systemFile.framePosition < systemFile.length {
                systemBuffer.frameLength = 0
                try systemFile.read(
                    into: systemBuffer,
                    frameCount: AVAudioFrameCount(farNeeded)
                )
                if let channels = systemBuffer.floatChannelData {
                    let readFrames = Int(systemBuffer.frameLength)
                    let channelCount = Int(systemFormat.channelCount)
                    for frame in 0..<readFrames {
                        var sample: Float = 0
                        for channel in 0..<channelCount {
                            sample += channels[channel][frame]
                        }
                        far[farPrefix + frame] = sample / Float(channelCount)
                    }
                }
            }

            let paddedFrames = ((validFrames + frameSize - 1) / frameSize) * frameSize
            let succeeded = near.withUnsafeBufferPointer { nearPointer in
                far.withUnsafeBufferPointer { farPointer in
                    cleaned.withUnsafeMutableBufferPointer { outputPointer in
                        quill_aec_process(
                            canceller,
                            nearPointer.baseAddress,
                            farPointer.baseAddress,
                            outputPointer.baseAddress,
                            Int32(paddedFrames)
                        )
                    }
                }
            }
            guard succeeded == 1, let outputChannel = outputBuffer.floatChannelData?[0] else {
                throw CancellationError.processingFailed
            }
            outputChannel.update(from: cleaned, count: validFrames)
            outputBuffer.frameLength = AVAudioFrameCount(validFrames)
            try outputFile.write(from: outputBuffer)
        }
    }
}
