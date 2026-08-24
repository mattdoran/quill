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
        case exportUnavailable(String)
        case invalidAudio(String)

        var description: String {
            switch self {
            case .missingMetadata(let url): "missing session metadata at \(url.path)"
            case .missingAudio(let url): "missing source audio at \(url.path)"
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
                && (try? SessionMetadataStore.readManifest(session).audioState) != .finalized
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
        if metadata.audioState == .empty {
            removeStaleJournal(session)
            return
        }
        let files = metadata.files

        if
            metadata.audioState == .finalized,
            files.meeting == Self.meetingAudioPath
        {
            try validatePublishedOutputs(session: session, files: files)
            removeStaleJournal(session)
            return
        }

        let prepared = try AudioPreparation.prepare(
            session: session,
            manifest: metadata,
            log: { appendLog(session, $0) }
        )
        let microphoneSource = prepared.microphone
        let callSource = prepared.system
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
            published.microphone = Self.localPath
        } else {
            published.microphone = nil
        }
        if let callSource {
            let output = session.appendingPathComponent(Self.remotePath)
            try await remuxAAC(from: callSource, to: output, in: session)
            published.system = Self.remotePath
        } else {
            published.system = nil
        }

        let cleanedSource = prepared.cleanedMicrophone

        if let cleanedSource {
            let output = session.appendingPathComponent(Self.cleanedLocalPath)
            try await remuxAAC(from: cleanedSource, to: output, in: session)
            published.cleanedMicrophone = Self.cleanedLocalPath
        }

        let meetingOutput = session.appendingPathComponent(Self.meetingAudioPath)
        let meetingCandidates: [MixInput] = [
            MixInput(
                url: cleanedSource ?? microphoneSource,
                offsetMilliseconds: metadata.startOffsets.microphone
            ),
            MixInput(url: callSource, offsetMilliseconds: metadata.startOffsets.system),
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
        published.meeting = Self.meetingAudioPath

        metadata.files = published
        metadata.audioState = .finalized
        if var microphone = metadata.tracks.microphone, let path = published.microphone {
            microphone.file = path
            metadata.tracks.microphone = microphone
        }
        if var system = metadata.tracks.system, let path = published.system {
            system.file = path
            metadata.tracks.system = system
        }
        try SessionMetadataStore.writeManifest(metadata, to: session)
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

    private func recoverMetadataIfNeeded(session: URL) throws -> SessionManifest {
        let meta = SessionFiles.metadata(session)
        if FileManager.default.fileExists(atPath: meta.path) {
            return try SessionMetadataStore.readManifest(session)
        }

        let journalURL = SessionFiles.captureJournal(session)
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            throw FinalizationError.missingMetadata(meta)
        }
        let journal = try SessionMetadataStore.readJournal(session)
        var files = journal.files
        let microphone = try sourceURL(for: files.microphone, in: session)
        let call = try sourceURL(for: files.system, in: session)
        if files.microphone?.isEmpty == false, microphone == nil {
            throw FinalizationError.missingAudio(session)
        }
        if files.system?.isEmpty == false, call == nil {
            throw FinalizationError.missingAudio(session)
        }
        let microphoneDuration = try microphone.map(recoveryAudioDuration) ?? 0
        let callDuration = try call.map(recoveryAudioDuration) ?? 0

        if microphoneDuration == 0 { files.microphone = nil }
        if callDuration == 0 { files.system = nil }

        let duration = max(
            Double(journal.startOffsets.microphone) / 1000 + microphoneDuration,
            Double(journal.startOffsets.system) / 1000 + callDuration
        )
        let iso = ISO8601DateFormatter()
        let started = iso.date(from: journal.started) ?? Date()
        var tracks = SessionTracks()
        if microphoneDuration > 0 {
            tracks.microphone = recoveredTrack(
                file: files.microphone!,
                duration: microphoneDuration
            )
        }
        if callDuration > 0 {
            tracks.system = recoveredTrack(file: files.system!, duration: callDuration)
        }
        let manifest = SessionManifest(
            started: journal.started,
            ended: iso.string(from: started.addingTimeInterval(duration)),
            durationSeconds: Int(duration.rounded()),
            files: files,
            startOffsets: journal.startOffsets,
            tracks: tracks,
            recoveredAfterInterruption: true,
            audioState: files.hasSourceAudio ? nil : .empty
        )
        try SessionMetadataStore.writeManifest(manifest, to: session)
        removeStaleJournal(session)
        appendLog(
            session,
            files.hasSourceAudio
                ? "recovered interrupted capture metadata"
                : "recovered interrupted capture with no audio"
        )
        return manifest
    }

    private func recoveredTrack(file: String, duration: TimeInterval) -> SessionTrackMetadata {
        SessionTrackMetadata(
            file: file,
            durationSeconds: Int(duration.rounded()),
            capturedSeconds: Int(duration.rounded()),
            gapsKnown: false
        )
    }

    private func sourceURL(for path: String?, in session: URL) throws -> URL? {
        try AudioPreparation.url(for: path, in: session)
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

    private func validatePublishedOutputs(session: URL, files: SessionAudioFiles) throws {
        guard files.hasSourceAudio else {
            throw FinalizationError.missingAudio(session)
        }
        for path in [
            files.microphone,
            files.system,
            files.cleanedMicrophone,
            files.meeting,
        ].compactMap({ $0 }) {
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
