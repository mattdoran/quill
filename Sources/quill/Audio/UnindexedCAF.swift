import AudioToolbox
import AVFoundation
import Foundation

/// A CAF is only given its AAC packet table on close, so a process that dies
/// mid-recording leaves every byte of audio in a file CoreAudio reads as empty.
/// Raw AAC has no framing; a packet's length is the shortest prefix the decoder
/// will produce audio from.
enum UnindexedCAF {
    struct Repair: Sendable {
        let packets: Int
        let recoveredBytes: Int
        let totalBytes: Int
        var unrecoveredBytes: Int { totalBytes - recoveredBytes }
    }

    enum RepairError: Error, CustomStringConvertible {
        case notAAC(String)
        case decoderUnavailable(OSStatus)
        case noPackets(String)
        case unreadableOutput(String)

        var description: String {
            switch self {
            case .notAAC(let file): "\(file) is not AAC"
            case .decoderUnavailable(let status): "AAC decoder unavailable (\(status))"
            case .noPackets(let file): "no decodable audio in \(file)"
            case .unreadableOutput(let file): "rebuilt \(file) would not open"
            }
        }
    }

    /// A process-crash leaves one partial packet at most. Anything larger is
    /// evidence the rebuild stopped short, so the original is kept beside it.
    static let ignorableTailBytes = 4096

    private struct Layout {
        var description: Range<Int>
        var cookie: Range<Int>
        var channels: Range<Int>?
        var audio: Range<Int>
    }

    /// True only for audio bytes with no packet table: a closed empty file is
    /// a genuinely empty recording.
    static func needsRepair(_ url: URL) -> Bool {
        guard
            let data = try? Data(contentsOf: url, options: .alwaysMapped),
            let layout = layout(of: data)
        else { return false }
        return !layout.audio.isEmpty
    }

    /// Never touches `input`; `output` appears only once it opens as valid audio.
    static func repair(_ input: URL, to output: URL) throws -> Repair {
        let name = input.lastPathComponent
        let data = try Data(contentsOf: input, options: .alwaysMapped)
        guard let layout = layout(of: data) else { throw RepairError.notAAC(name) }
        let sizes = try packetSizes(in: data, layout: layout, name: name)
        let used = sizes.reduce(0, +)

        let partial = output.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        try write(data: data, layout: layout, sizes: sizes, to: partial)

        guard let file = try? AVAudioFile(forReading: partial), file.length > 0 else {
            throw RepairError.unreadableOutput(name)
        }
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: output)
        }
        return Repair(
            packets: sizes.count,
            recoveredBytes: used,
            totalBytes: layout.audio.count
        )
    }

    private static func layout(of data: Data) -> Layout? {
        guard data.count > 8, data.prefix(4) == Data("caff".utf8) else { return nil }
        var description: Range<Int>?
        var cookie: Range<Int>?
        var channels: Range<Int>?
        var offset = 8
        while offset + 12 <= data.count {
            let type = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let length = Int64(bitPattern: data[offset + 4..<offset + 12].reduce(UInt64(0)) {
                $0 << 8 | UInt64($1)
            })
            let body = offset + 12
            if type == "data" {
                // -1 is the size CoreAudio leaves until it closes the file. The
                // first four bytes are the chunk's edit count.
                guard
                    length == -1,
                    let description,
                    let cookie,
                    body + 4 <= data.count
                else { return nil }
                return Layout(
                    description: description,
                    cookie: cookie,
                    channels: channels,
                    audio: body + 4..<data.count
                )
            }
            guard length >= 0, length <= Int64(data.count - body) else { return nil }
            let range = body..<body + Int(length)
            switch type {
            case "desc": description = range
            case "kuki": cookie = range
            case "chan": channels = range
            default: break
            }
            offset = range.upperBound
        }
        return nil
    }

    private static func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func packetSizes(
        in data: Data,
        layout: Layout,
        name: String
    ) throws -> [Int] {
        let description = layout.description.lowerBound
        let sampleRate = Double(
            bitPattern: data[description..<description + 8].reduce(UInt64(0)) {
                $0 << 8 | UInt64($1)
            }
        )
        guard bigEndian32(data, at: description + 8) == kAudioFormatMPEG4AAC else {
            throw RepairError.notAAC(name)
        }
        let channels = bigEndian32(data, at: description + 24)
        let decoder = try PacketDecoder(
            sampleRate: sampleRate,
            channels: channels,
            cookie: [UInt8](data[layout.cookie])
        )
        defer { decoder.dispose() }

        // ISO 14496-3's decoder input buffer: 6144 bits per channel.
        let largestPacket = 768 * Int(channels)
        var sizes: [Int] = []
        sizes.reserveCapacity(layout.audio.count / 150)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = UnsafeMutableRawPointer(mutating: raw.baseAddress!)
            var offset = layout.audio.lowerBound
            let end = layout.audio.upperBound
            var previous = largestPacket / 2
            while offset < end {
                let start = bytes + offset
                let upper = min(end - offset, largestPacket)
                guard decoder.accepts(start, upper) else { break }
                // Consecutive packets are similar sizes, so start from the last.
                var low = 0
                var high = upper
                if previous < upper {
                    if decoder.accepts(start, previous) { high = previous } else { low = previous }
                }
                while high - low > 1 {
                    let middle = (low + high) / 2
                    if decoder.accepts(start, middle) { high = middle } else { low = middle }
                }
                sizes.append(high)
                previous = high
                offset += high
            }
        }
        guard !sizes.isEmpty else { throw RepairError.noPackets(name) }
        return sizes
    }

    private static func write(
        data: Data,
        layout: Layout,
        sizes: [Int],
        to url: URL
    ) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        func chunk(_ type: String, _ length: Int) -> Data {
            var out = Data(type.utf8)
            out.append(bigEndian(Int64(length)))
            return out
        }
        var header = Data("caff".utf8)
        header.append(contentsOf: [0, 1, 0, 0])
        header.append(chunk("desc", layout.description.count))
        header.append(data[layout.description])
        header.append(chunk("kuki", layout.cookie.count))
        header.append(data[layout.cookie])
        if let channels = layout.channels {
            header.append(chunk("chan", channels.count))
            header.append(data[channels])
        }
        let used = sizes.reduce(0, +)
        header.append(chunk("data", used + 4))
        header.append(contentsOf: [0, 0, 0, 0])
        try handle.write(contentsOf: header)
        try handle.write(
            contentsOf: data[layout.audio.lowerBound..<layout.audio.lowerBound + used]
        )

        var table = Data(capacity: sizes.count * 2)
        for size in sizes { appendVariableLength(UInt32(size), to: &table) }
        var trailer = chunk("pakt", 24 + table.count)
        trailer.append(bigEndian(Int64(sizes.count)))
        trailer.append(bigEndian(Int64(sizes.count) * 1024 - aacEncoderDelay))
        trailer.append(bigEndian(Int32(aacEncoderDelay)))
        trailer.append(bigEndian(Int32(0)))
        trailer.append(table)
        try handle.write(contentsOf: trailer)
    }

    /// What Apple's AAC encoder writes to every closed CAF.
    private static let aacEncoderDelay: Int64 = 2112

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func appendVariableLength(_ value: UInt32, to out: inout Data) {
        var shift: UInt32 = 28
        while shift > 0, value >> shift == 0 { shift -= 7 }
        while shift > 0 {
            out.append(UInt8((value >> shift) & 0x7f) | 0x80)
            shift -= 7
        }
        out.append(UInt8(value & 0x7f))
    }
}

private final class PacketDecoder {
    private final class Feed {
        let bytes: UnsafeMutableRawPointer
        let count: UInt32
        let channels: UInt32
        var supplied = false
        var description = AudioStreamPacketDescription()

        init(bytes: UnsafeMutableRawPointer, count: UInt32, channels: UInt32) {
            self.bytes = bytes
            self.count = count
            self.channels = channels
        }
    }

    private static let endOfInput: OSStatus = 1
    private static let outputFrames: UInt32 = 2048

    private let converter: AudioConverterRef
    private let channels: UInt32
    private let output: UnsafeMutableRawPointer
    private let outputBytes: UInt32

    init(sampleRate: Double, channels: UInt32, cookie: [UInt8]) throws {
        var source = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let frameBytes = 4 * channels
        var destination = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: frameBytes,
            mFramesPerPacket: 1,
            mBytesPerFrame: frameBytes,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var created: AudioConverterRef?
        let status = AudioConverterNew(&source, &destination, &created)
        guard status == noErr, let created else {
            throw UnindexedCAF.RepairError.decoderUnavailable(status)
        }
        let cookieStatus = AudioConverterSetProperty(
            created,
            kAudioConverterDecompressionMagicCookie,
            UInt32(cookie.count),
            cookie
        )
        guard cookieStatus == noErr else {
            AudioConverterDispose(created)
            throw UnindexedCAF.RepairError.decoderUnavailable(cookieStatus)
        }
        converter = created
        self.channels = channels
        outputBytes = Self.outputFrames * frameBytes
        output = UnsafeMutableRawPointer.allocate(byteCount: Int(outputBytes), alignment: 16)
    }

    func dispose() {
        AudioConverterDispose(converter)
        output.deallocate()
    }

    func accepts(_ bytes: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        AudioConverterReset(converter)
        let feed = Feed(bytes: bytes, count: UInt32(count), channels: channels)
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: outputBytes,
                mData: output
            )
        )
        var frames = Self.outputFrames
        _ = withExtendedLifetime(feed) {
            AudioConverterFillComplexBuffer(
                converter,
                { _, count, list, description, user in
                    let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
                    guard !feed.supplied else {
                        count.pointee = 0
                        return PacketDecoder.endOfInput
                    }
                    feed.supplied = true
                    count.pointee = 1
                    list.pointee.mBuffers.mData = feed.bytes
                    list.pointee.mBuffers.mDataByteSize = feed.count
                    list.pointee.mBuffers.mNumberChannels = feed.channels
                    feed.description = AudioStreamPacketDescription(
                        mStartOffset: 0,
                        mVariableFramesInPacket: 0,
                        mDataByteSize: feed.count
                    )
                    withUnsafeMutablePointer(to: &feed.description) {
                        description?.pointee = $0
                    }
                    return noErr
                },
                Unmanaged.passUnretained(feed).toOpaque(),
                &frames,
                &list,
                nil
            )
        }
        return frames > 0
    }
}
