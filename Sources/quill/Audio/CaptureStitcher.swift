@preconcurrency import AVFoundation
import Foundation

/// Joins the capture segments of a meeting that survived a crash into one file
/// per track, so everything downstream still sees one timeline.
enum CaptureStitcher {
    struct Piece: Equatable {
        let silenceBefore: AVAudioFramePosition
        let source: Int
    }

    struct Plan: Equatable {
        let startOffsetMilliseconds: Int
        let pieces: [Piece]
    }

    struct SegmentAudio: Sendable {
        let url: URL
        let frames: AVAudioFramePosition
        let offsetMilliseconds: Int
    }

    enum StitchError: Error, CustomStringConvertible {
        case unreadable(String)
        case wrongLength(String, expected: AVAudioFramePosition, actual: AVAudioFramePosition)

        var description: String {
            switch self {
            case .unreadable(let file): "couldn't stitch \(file)"
            case .wrongLength(let file, let expected, let actual):
                "stitched \(file) has \(actual) frames, expected \(expected)"
            }
        }
    }

    /// Measured from the timeline each time, so a segment that ran long or short
    /// against the wall clock is absorbed by the next gap. An overlap cannot be
    /// silence and places the next segment directly after.
    static func plan(_ segments: [SegmentAudio], sampleRate: Double) -> Plan? {
        guard let first = segments.first else { return nil }
        var cursor = frames(milliseconds: first.offsetMilliseconds, sampleRate: sampleRate)
        var pieces: [Piece] = []
        for (index, segment) in segments.enumerated() {
            let wanted = frames(milliseconds: segment.offsetMilliseconds, sampleRate: sampleRate)
            let silence = max(0, wanted - cursor)
            pieces.append(Piece(silenceBefore: silence, source: index))
            cursor += silence + segment.frames
        }
        return Plan(startOffsetMilliseconds: first.offsetMilliseconds, pieces: pieces)
    }

    /// Never touches the segments; `output` appears only once it has the planned
    /// length.
    static func stitch(_ segments: [SegmentAudio], plan: Plan, to output: URL) throws {
        guard let first = segments.first else {
            throw StitchError.unreadable(output.lastPathComponent)
        }
        let format = try AVAudioFile(forReading: first.url).processingFormat
        let partial = output.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw StitchError.unreadable(output.lastPathComponent)
        }
        var expected: AVAudioFramePosition = 0
        do {
            let writer = try AVAudioFile(
                forWriting: partial,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                ],
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            for piece in plan.pieces {
                var silence = piece.silenceBefore
                expected += silence
                while silence > 0 {
                    buffer.frameLength = AVAudioFrameCount(
                        min(AVAudioFramePosition(capacity), silence)
                    )
                    for list in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                        memset(list.mData, 0, Int(list.mDataByteSize))
                    }
                    try writer.write(from: buffer)
                    silence -= AVAudioFramePosition(buffer.frameLength)
                }
                let reader = try AVAudioFile(forReading: segments[piece.source].url)
                expected += reader.length
                while reader.framePosition < reader.length {
                    buffer.frameLength = 0
                    try reader.read(into: buffer, frameCount: capacity)
                    guard buffer.frameLength > 0 else {
                        throw StitchError.unreadable(segments[piece.source].url.lastPathComponent)
                    }
                    try writer.write(from: buffer)
                }
            }
        }
        let written = try AVAudioFile(forReading: partial).length
        guard written == expected else {
            throw StitchError.wrongLength(
                output.lastPathComponent, expected: expected, actual: written
            )
        }
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: output)
        }
    }

    private static func frames(milliseconds: Int, sampleRate: Double) -> AVAudioFramePosition {
        AVAudioFramePosition((Double(milliseconds) * sampleRate / 1000).rounded())
    }
}
