import AVFoundation
import Foundation
import ObjCExceptions
import Testing
@testable import quill

/// Rewrites a closed CAF into what a killed process leaves on disk: the same
/// bytes, an open-ended data chunk and no packet table.
func stripPacketTable(_ url: URL, droppingLast dropped: Int = 0) throws {
    let bytes = try Data(contentsOf: url)
    var offset = 8
    var out = bytes.prefix(8)
    while offset + 12 <= bytes.count {
        let type = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
        let length = Int(bytes[offset + 4..<offset + 12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        let body = offset + 12
        if type == "data" {
            out.append(bytes[offset..<offset + 4])
            out.append(contentsOf: [UInt8](repeating: 0xff, count: 8))
            out.append(bytes[body..<body + length - dropped])
        } else if type != "pakt" {
            out.append(bytes[offset..<body + length])
        }
        offset = body + length
    }
    try out.write(to: url)
}

@Suite(.serialized) struct UnindexedCAFTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-unindexed-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Noise over a sweep, so packet sizes vary the way speech makes them.
    private func writeVariedAAC(to url: URL, seconds: Double) throws {
        let rate = 48_000.0
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
        ))
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData)[0]
        var state: UInt32 = 0x1234_5678
        for frame in 0..<Int(frames) {
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Float(state >> 8) / Float(1 << 24) - 0.5
            let envelope = Float(sin(Double(frame) / rate * 3).magnitude)
            let tone = Float(sin(Double(frame) / rate * 2 * .pi * 220))
            samples[frame] = envelope * (0.2 * noise + 0.3 * tone)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0], count: Int(buffer.frameLength)
        ))
    }

    @Test func rebuildsTheSameAudioFromAFileWithNoPacketTable() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.caf")
        let crashed = directory.appendingPathComponent("crashed.caf")
        let rebuilt = directory.appendingPathComponent("rebuilt.caf")
        try writeVariedAAC(to: original, seconds: 8)
        try FileManager.default.copyItem(at: original, to: crashed)
        try stripPacketTable(crashed)

        #expect(try AVAudioFile(forReading: crashed).length == 0)
        #expect(UnindexedCAF.needsRepair(crashed))
        #expect(!UnindexedCAF.needsRepair(original))

        let repair = try UnindexedCAF.repair(crashed, to: rebuilt)

        #expect(repair.unrecoveredBytes == 0)
        let expected = try samples(of: original)
        let actual = try samples(of: rebuilt)
        #expect(abs(expected.count - actual.count) < 1024)
        #expect(zip(expected, actual).allSatisfy { $0 == $1 })
    }

    @Test func aPartialFinalPacketCostsOnlyThatPacket() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.caf")
        let crashed = directory.appendingPathComponent("crashed.caf")
        let rebuilt = directory.appendingPathComponent("rebuilt.caf")
        try writeVariedAAC(to: original, seconds: 4)
        try FileManager.default.copyItem(at: original, to: crashed)
        try stripPacketTable(crashed, droppingLast: 40)

        let repair = try UnindexedCAF.repair(crashed, to: rebuilt)

        #expect(repair.unrecoveredBytes > 0)
        #expect(repair.unrecoveredBytes <= UnindexedCAF.ignorableTailBytes)
        let expected = try samples(of: original)
        let actual = try samples(of: rebuilt)
        #expect(expected.count - actual.count < 2048)
        #expect(zip(expected, actual).allSatisfy { $0 == $1 })
    }

    @Test func aClosedEmptyRecordingIsNotUnindexed() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.caf")
        _ = try AVAudioFile(
            forWriting: empty,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        #expect(!UnindexedCAF.needsRepair(empty))
    }

    @Test func aRaisedExceptionBecomesAThrownError() {
        #expect(throws: NSError.self) {
            try ObjCExceptionCatcher.perform {
                NSException(
                    name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                    reason: "format mismatch",
                    userInfo: nil
                ).raise()
            }
        }
    }
}
