import AVFoundation
import Foundation

actor AudioFinalizer {
    static let shared = AudioFinalizer()

    private var inFlight: [URL: Task<Void, any Error>] = [:]

    static let meetingAudioPath = "Meeting Audio.m4a"
    static let sourceAudioDirectory = "Source Audio"
    static let localPath = "Source Audio/Local.m4a"
    static let remotePath = "Source Audio/Remote.m4a"
    static let cleanedLocalPath = "Source Audio/Local Cleaned.m4a"

    enum FinalizationError: Error, CustomStringConvertible {
        case missingMetadata(URL)
        case missingAudio(URL)
        case unsafePath(String)
        case exportUnavailable(String)
        case invalidAudio(String)

        var description: String {
            switch self {
            case .missingMetadata(let url): "missing session metadata at \(url.path)"
            case .missingAudio(let url): "missing source audio at \(url.path)"
            case .unsafePath(let path): "unsafe session audio path \(path)"
            case .exportUnavailable(let detail): "audio export unavailable: \(detail)"
            case .invalidAudio(let detail): "invalid audio: \(detail)"
            }
        }
    }

    func recoverPending(in root: URL) async {
        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for session in sessions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let journal = SessionFiles.captureJournal(session)
            let meta = SessionFiles.metadata(session)
            let hasInterruptedCapture = FileManager.default.fileExists(atPath: journal.path)
            let needsFinalization =
                FileManager.default.fileExists(atPath: meta.path)
                && SessionFiles.hasProcessableAudio(session)
                && (try? readJSON(meta)["audio_state"] as? String) != "finalized"
            guard hasInterruptedCapture || needsFinalization else { continue }
            do {
                try await finalize(session: session)
            } catch {
                appendLog(session, "audio finalization deferred: \(error)")
            }
        }
    }

    func finalize(session: URL) async throws {
        let session = session.standardizedFileURL
        if let existing = inFlight[session] {
            return try await existing.value
        }

        let task = Task { try await performFinalization(session: session) }
        inFlight[session] = task
        defer { inFlight[session] = nil }
        try await task.value
    }

    private func performFinalization(session: URL) async throws {
        var metadata = try recoverMetadataIfNeeded(session: session)
        if metadata["audio_state"] as? String == "empty" {
            removeStaleJournal(session)
            return
        }
        let files = metadata["files"] as? [String: String] ?? [:]

        if
            metadata["audio_state"] as? String == "finalized",
            files["meeting"] == Self.meetingAudioPath
        {
            try validatePublishedOutputs(session: session, files: files)
            removeStaleJournal(session)
            return
        }

        let microphoneSource = try sourceURL(for: files["mic"], in: session)
        let callSource = try sourceURL(for: files["system"], in: session)
        guard microphoneSource != nil || callSource != nil else {
            throw FinalizationError.missingAudio(session)
        }

        let sourceDirectory = session.appendingPathComponent(
            Self.sourceAudioDirectory,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )

        var published = files
        if let microphoneSource {
            let output = session.appendingPathComponent(Self.localPath)
            try await remuxAAC(from: microphoneSource, to: output, in: session)
            published["mic"] = Self.localPath
        } else {
            published.removeValue(forKey: "mic")
        }
        if let callSource {
            let output = session.appendingPathComponent(Self.remotePath)
            try await remuxAAC(from: callSource, to: output, in: session)
            published["system"] = Self.remotePath
        } else {
            published.removeValue(forKey: "system")
        }

        var cleanedSource = microphoneSource.flatMap {
            existingCleanedMicrophone(in: session, matching: $0)
        }
        if cleanedSource == nil, let microphoneSource, let callSource {
            let offsets = metadata["start_offset_ms"] as? [String: Int] ?? [:]
            do {
                appendLog(session, "cleaning speaker playback before audio finalization")
                let workingDirectory = try SessionFiles.prepare(session)
                cleanedSource = try EchoCancellation.clean(
                    mic: microphoneSource,
                    micOffsetMs: offsets["mic"] ?? 0,
                    system: callSource,
                    systemOffsetMs: offsets["system"] ?? 0,
                    in: workingDirectory
                )
            } catch {
                appendLog(session, "echo cancellation failed before finalization: \(error)")
            }
        }

        if let cleanedSource {
            let output = session.appendingPathComponent(Self.cleanedLocalPath)
            try await remuxAAC(from: cleanedSource, to: output, in: session)
            published["mic_cleaned"] = Self.cleanedLocalPath
        }

        let offsets = metadata["start_offset_ms"] as? [String: Int] ?? [:]
        let meetingOutput = session.appendingPathComponent(Self.meetingAudioPath)
        let meetingCandidates: [MixInput] = [
            MixInput(
                url: cleanedSource ?? microphoneSource,
                offsetMilliseconds: offsets["mic"] ?? 0
            ),
            MixInput(url: callSource, offsetMilliseconds: offsets["system"] ?? 0),
        ]
        let meetingInputs = meetingCandidates.filter { $0.url != nil }
        let expectedMeetingDuration = try meetingDuration(inputs: meetingInputs)
        var liveMeetingSource = existingLiveMeeting(in: session)
        if let source = liveMeetingSource {
            do {
                try validateMeetingAudio(source, expectedDuration: expectedMeetingDuration)
                try await remuxAAC(from: source, to: meetingOutput, in: session)
                appendLog(session, "published meeting mix prepared during recording")
            } catch {
                appendLog(session, "live meeting mix unusable, rebuilding: \(error)")
                try? FileManager.default.removeItem(at: source)
                liveMeetingSource = nil
            }
        }
        if liveMeetingSource == nil {
            try mix(inputs: meetingInputs, to: meetingOutput, in: session)
        }
        published["meeting"] = Self.meetingAudioPath

        metadata["files"] = published
        metadata["audio_state"] = "finalized"
        if var tracks = metadata["tracks"] as? [String: [String: Any]] {
            if var microphone = tracks["mic"], published["mic"] != nil {
                microphone["file"] = published["mic"]
                tracks["mic"] = microphone
            }
            if var system = tracks["system"], published["system"] != nil {
                system["file"] = published["system"]
                tracks["system"] = system
            }
            metadata["tracks"] = tracks
        }
        try writeMetadata(metadata, to: SessionFiles.metadata(session))
        removeStaleJournal(session)

        for source in [
            microphoneSource, callSource, cleanedSource, liveMeetingSource,
        ].compactMap({ $0 }) {
            guard source.pathExtension.lowercased() == "caf" else { continue }
            do {
                try FileManager.default.removeItem(at: source)
            } catch {
                appendLog(session, "couldn't remove finalized \(source.lastPathComponent): \(error)")
            }
        }
        appendLog(session, "finished audio published as M4A")
    }

    // MARK: - Recovery and metadata

    private func recoverMetadataIfNeeded(session: URL) throws -> [String: Any] {
        let meta = SessionFiles.metadata(session)
        if FileManager.default.fileExists(atPath: meta.path) {
            return try readJSON(meta)
        }

        let journalURL = SessionFiles.captureJournal(session)
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            throw FinalizationError.missingMetadata(meta)
        }
        var journal = try readJSON(journalURL)
        var files = journal["files"] as? [String: String] ?? [:]
        let offsets = journal["start_offset_ms"] as? [String: Int] ?? [:]
        let microphone = try sourceURL(for: files["mic"], in: session)
        let call = try sourceURL(for: files["system"], in: session)
        if files["mic"]?.isEmpty == false, microphone == nil {
            throw FinalizationError.missingAudio(session)
        }
        if files["system"]?.isEmpty == false, call == nil {
            throw FinalizationError.missingAudio(session)
        }
        let microphoneDuration = try microphone.map(recoveryAudioDuration) ?? 0
        let callDuration = try call.map(recoveryAudioDuration) ?? 0

        if microphoneDuration == 0 { files.removeValue(forKey: "mic") }
        if callDuration == 0 { files.removeValue(forKey: "system") }

        let duration = max(
            Double(offsets["mic"] ?? 0) / 1000 + microphoneDuration,
            Double(offsets["system"] ?? 0) / 1000 + callDuration
        )
        let iso = ISO8601DateFormatter()
        let started = (journal["started"] as? String).flatMap(iso.date(from:)) ?? Date()
        journal["ended"] = iso.string(from: started.addingTimeInterval(duration))
        journal["duration_seconds"] = Int(duration.rounded())
        journal["recovered_after_interruption"] = true
        journal["files"] = files
        var tracks: [String: [String: Any]] = [:]
        if microphoneDuration > 0 {
            tracks["mic"] = recoveredTrack(file: files["mic"], duration: microphoneDuration)
        }
        if callDuration > 0 {
            tracks["system"] = recoveredTrack(file: files["system"], duration: callDuration)
        }
        journal["tracks"] = tracks
        if tracks.isEmpty { journal["audio_state"] = "empty" }
        try writeMetadata(journal, to: meta)
        removeStaleJournal(session)
        appendLog(
            session,
            tracks.isEmpty
                ? "recovered interrupted capture with no audio"
                : "recovered interrupted capture metadata"
        )
        return journal
    }

    private func recoveredTrack(file: String?, duration: TimeInterval) -> [String: Any] {
        [
            "file": file ?? "",
            "duration_seconds": Int(duration.rounded()),
            "captured_seconds": Int(duration.rounded()),
            "gaps_known": false,
        ]
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FinalizationError.missingMetadata(url)
        }
        return json
    }

    private func writeMetadata(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    private func sourceURL(for path: String?, in session: URL) throws -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let components = (path as NSString).pathComponents
        guard !path.hasPrefix("/"), !components.contains("..") else {
            throw FinalizationError.unsafePath(path)
        }
        let url = session.appendingPathComponent(path).standardizedFileURL
        let root = session.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(root) else { throw FinalizationError.unsafePath(path) }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func removeStaleJournal(_ session: URL) {
        try? FileManager.default.removeItem(
            at: SessionFiles.captureJournal(session)
        )
    }

    // MARK: - Media work

    private func remuxAAC(from input: URL, to output: URL, in session: URL) async throws {
        let expectedDuration = try audioDuration(input)
        if
            FileManager.default.fileExists(atPath: output.path),
            (try? validateAudio(output, expectedDuration: expectedDuration)) != nil
        {
            return
        }

        let partial = try partialURL(for: output, in: session)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        let asset = AVURLAsset(url: input)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw FinalizationError.exportUnavailable(input.lastPathComponent)
        }
        try await exporter.export(to: partial, as: .m4a)
        try validateAudio(partial, expectedDuration: expectedDuration)
        try publish(partial: partial, to: output)
    }

    private struct MixInput {
        let url: URL?
        let offsetMilliseconds: Int
    }

    private func mix(inputs: [MixInput], to output: URL, in session: URL) throws {
        guard !inputs.isEmpty else { throw FinalizationError.missingAudio(output) }

        let sampleRate = 48_000.0
        struct PreparedInput {
            let file: AVAudioFile
            let offset: AVAudioFramePosition
        }
        var prepared: [PreparedInput] = []
        var totalFrames: AVAudioFramePosition = 0
        for input in inputs {
            guard let url = input.url else { continue }
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate == sampleRate else {
                throw FinalizationError.invalidAudio(
                    "\(url.lastPathComponent) is \(Int(file.processingFormat.sampleRate))Hz"
                )
            }
            let offset = AVAudioFramePosition(
                (Double(max(0, input.offsetMilliseconds)) / 1000 * sampleRate).rounded()
            )
            prepared.append(PreparedInput(file: file, offset: offset))
            totalFrames = max(totalFrames, offset + file.length)
        }
        let expectedDuration = Double(totalFrames) / sampleRate

        if
            FileManager.default.fileExists(atPath: output.path),
            (try? validateMeetingAudio(output, expectedDuration: expectedDuration)) != nil
        {
            return
        }

        let partial = try partialURL(for: output, in: session)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw FinalizationError.invalidAudio("couldn't create meeting format")
        }
        var outputFile: AVAudioFile? = try AVAudioFile(
            forWriting: partial,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let capacity: AVAudioFrameCount = 16_384
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ), let outputSamples = outputBuffer.floatChannelData?[0] else {
            throw FinalizationError.invalidAudio("couldn't allocate meeting buffer")
        }

        var position: AVAudioFramePosition = 0
        while position < totalFrames {
            let count = Int(min(AVAudioFramePosition(capacity), totalFrames - position))
            for frame in 0..<count { outputSamples[frame] = 0 }

            for input in prepared {
                let overlapStart = max(position, input.offset)
                let overlapEnd = min(
                    position + AVAudioFramePosition(count),
                    input.offset + input.file.length
                )
                guard overlapStart < overlapEnd else { continue }
                let readCount = AVAudioFrameCount(overlapEnd - overlapStart)
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: input.file.processingFormat,
                    frameCapacity: readCount
                ) else {
                    throw FinalizationError.invalidAudio("couldn't allocate input buffer")
                }
                input.file.framePosition = overlapStart - input.offset
                try input.file.read(into: inputBuffer, frameCount: readCount)
                guard let channels = inputBuffer.floatChannelData else {
                    throw FinalizationError.invalidAudio("couldn't decode meeting input")
                }
                let channelCount = Int(inputBuffer.format.channelCount)
                let destinationStart = Int(overlapStart - position)
                for frame in 0..<Int(inputBuffer.frameLength) {
                    var sample: Float = 0
                    for channel in 0..<channelCount { sample += channels[channel][frame] }
                    outputSamples[destinationStart + frame] += sample / Float(channelCount) * 0.7071
                }
            }

            for frame in 0..<count {
                outputSamples[frame] = min(1, max(-1, outputSamples[frame]))
            }
            outputBuffer.frameLength = AVAudioFrameCount(count)
            try outputFile?.write(from: outputBuffer)
            position += AVAudioFramePosition(count)
        }
        outputFile = nil
        try validateMeetingAudio(partial, expectedDuration: expectedDuration)
        try publish(partial: partial, to: output)
    }

    private func meetingDuration(inputs: [MixInput]) throws -> TimeInterval {
        var duration: TimeInterval = 0
        for input in inputs {
            guard let url = input.url else { continue }
            duration = max(
                duration,
                Double(max(0, input.offsetMilliseconds)) / 1000 + (try audioDuration(url))
            )
        }
        return duration
    }

    private func validatePublishedOutputs(session: URL, files: [String: String]) throws {
        guard files["mic"] != nil || files["system"] != nil else {
            throw FinalizationError.missingAudio(session)
        }
        for key in ["mic", "system", "mic_cleaned", "meeting"] {
            guard let path = files[key] else { continue }
            guard let url = try sourceURL(for: path, in: session) else {
                throw FinalizationError.missingAudio(session.appendingPathComponent(path))
            }
            try decodeCompletely(url)
        }
    }

    private func validateAudio(_ url: URL, expectedDuration: TimeInterval) throws {
        let duration = try audioDuration(url)
        guard abs(duration - expectedDuration) <= 0.03 else {
            throw FinalizationError.invalidAudio(
                "\(url.lastPathComponent) duration \(duration), expected \(expectedDuration)"
            )
        }
        try decodeCompletely(url)
    }

    private func validateMeetingAudio(_ url: URL, expectedDuration: TimeInterval) throws {
        let duration = try audioDuration(url)
        guard abs(duration - expectedDuration) <= 0.05 else {
            throw FinalizationError.invalidAudio(
                "\(url.lastPathComponent) duration \(duration), expected \(expectedDuration)"
            )
        }
        try decodeCompletely(url)
    }

    private func audioDuration(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.sampleRate > 0, file.length > 0 else {
            throw FinalizationError.invalidAudio(url.lastPathComponent)
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func recoveryAudioDuration(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.sampleRate > 0 else {
            throw FinalizationError.invalidAudio(url.lastPathComponent)
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func decodeCompletely(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: 16_384
        ) else {
            throw FinalizationError.invalidAudio("can't allocate decoder buffer")
        }
        var decoded: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            guard buffer.frameLength > 0 else {
                throw FinalizationError.invalidAudio("truncated \(url.lastPathComponent)")
            }
            decoded += AVAudioFramePosition(buffer.frameLength)
        }
        guard decoded > 0 else { throw FinalizationError.invalidAudio(url.lastPathComponent) }
    }

    private func partialURL(for output: URL, in session: URL) throws -> URL {
        try SessionFiles.prepare(session).appendingPathComponent(
            ".\(output.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.m4a"
        )
    }

    private func publish(partial: URL, to output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: partial, to: output)
    }

    private func existingCleanedMicrophone(in session: URL, matching microphone: URL) -> URL? {
        let legacy = SessionFiles.internalFile(EchoCancellation.outputName, in: session)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        do {
            try EchoCancellation.validateCleaned(legacy, matching: microphone)
            return legacy
        } catch {
            appendLog(session, "cleaned microphone unusable, rebuilding: \(error)")
            try? FileManager.default.removeItem(at: legacy)
            return nil
        }
    }

    private func existingLiveMeeting(in session: URL) -> URL? {
        let url = SessionFiles.internalFile(LiveEchoCanceller.meetingOutputName, in: session)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated func appendLog(_ session: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = SessionFiles.sessionLog(session)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
