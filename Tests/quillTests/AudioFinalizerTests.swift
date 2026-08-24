import AVFoundation
import Foundation
import Testing
@testable import quill

@Suite(.serialized) struct AudioFinalizerTests {
    @Test func finalizesSourcesAndMeetingAudioBeforePublishingMetadata() async throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }

        let microphone = SessionFiles.internalFile("mic.caf", in: session)
        let call = SessionFiles.internalFile("system.caf", in: session)
        try writeAAC(to: microphone, channels: 1, seconds: 0.6, frequency: 330)
        try writeAAC(to: call, channels: 2, seconds: 0.5, frequency: 660)
        let staleLiveMeeting = SessionFiles.internalFile(
            LiveEchoCanceller.meetingOutputName,
            in: session
        )
        try Data("not audio".utf8).write(to: staleLiveMeeting)
        let microphoneLength = try AVAudioFile(forReading: microphone).length
        let callLength = try AVAudioFile(forReading: call).length
        try writeJSON(
            metadata(microphoneOffset: 0, callOffset: 100),
            to: SessionFiles.metadata(session)
        )

        try await AudioFinalizer.shared.finalize(session: session)
        try await AudioFinalizer.shared.finalize(session: session)

        let published = try readJSON(SessionFiles.metadata(session))
        let files = try #require(published["files"] as? [String: String])
        #expect(files["mic"] == AudioFinalizer.localPath)
        #expect(files["system"] == AudioFinalizer.remotePath)
        #expect(files["meeting"] == AudioFinalizer.meetingAudioPath)
        #expect(published["audio_state"] as? String == "finalized")
        let metadataText = try String(
            contentsOf: SessionFiles.metadata(session),
            encoding: .utf8
        )
        #expect(!metadataText.contains("\\/"))
        #expect(!FileManager.default.fileExists(atPath: microphone.path))
        #expect(!FileManager.default.fileExists(atPath: call.path))
        #expect(!FileManager.default.fileExists(atPath: staleLiveMeeting.path))

        let finalMicrophone = session.appendingPathComponent(AudioFinalizer.localPath)
        let finalCall = session.appendingPathComponent(AudioFinalizer.remotePath)
        let meeting = session.appendingPathComponent(AudioFinalizer.meetingAudioPath)
        #expect(try AVAudioFile(forReading: finalMicrophone).length == microphoneLength)
        #expect(try AVAudioFile(forReading: finalCall).length == callLength)
        let meetingFile = try AVAudioFile(forReading: meeting)
        #expect(meetingFile.length > 0)
        #expect(meetingFile.processingFormat.channelCount == 1)
        let rootItems = try FileManager.default.contentsOfDirectory(
            at: session,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        #expect(rootItems == [".quill", "Meeting Audio.m4a", "Source Audio"])
    }

    @Test func publishesMeetingMixPreparedDuringRecording() async throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }

        try writeAAC(
            to: SessionFiles.internalFile("mic.caf", in: session),
            channels: 1,
            seconds: 0.6,
            frequency: 330
        )
        try writeAAC(
            to: SessionFiles.internalFile("system.caf", in: session),
            channels: 1,
            seconds: 0.5,
            frequency: 660
        )
        try writeAAC(
            to: SessionFiles.internalFile(EchoCancellation.outputName, in: session),
            channels: 1,
            seconds: 0.6,
            frequency: 330
        )
        let liveMeeting = SessionFiles.internalFile(
            LiveEchoCanceller.meetingOutputName,
            in: session
        )
        try writeAAC(to: liveMeeting, channels: 1, seconds: 0.6, frequency: 880)
        try writeJSON(
            metadata(microphoneOffset: 0, callOffset: 100),
            to: SessionFiles.metadata(session)
        )

        try await AudioFinalizer.shared.finalize(session: session)

        let meeting = session.appendingPathComponent(AudioFinalizer.meetingAudioPath)
        let file = try AVAudioFile(forReading: meeting)
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.length == AVAudioFramePosition(0.6 * 48_000))
        #expect(!FileManager.default.fileExists(atPath: liveMeeting.path))
        let log = try String(contentsOf: SessionFiles.sessionLog(session), encoding: .utf8)
        #expect(log.contains("published meeting mix prepared during recording"))
    }

    @Test func rebuildsTruncatedCleanedMicrophone() async throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }

        let microphone = SessionFiles.internalFile("mic.caf", in: session)
        try writeAAC(to: microphone, channels: 1, seconds: 0.6, frequency: 330)
        let microphoneLength = try AVAudioFile(forReading: microphone).length
        try writeAAC(
            to: SessionFiles.internalFile("system.caf", in: session),
            channels: 1,
            seconds: 0.6,
            frequency: 660
        )
        try writeAAC(
            to: SessionFiles.internalFile(EchoCancellation.outputName, in: session),
            channels: 1,
            seconds: 0.2,
            frequency: 330
        )
        try writeJSON(
            metadata(microphoneOffset: 0, callOffset: 0),
            to: SessionFiles.metadata(session)
        )

        try await AudioFinalizer.shared.finalize(session: session)

        let cleaned = session.appendingPathComponent(AudioFinalizer.cleanedLocalPath)
        let cleanedFile = try AVAudioFile(forReading: cleaned)
        #expect(cleanedFile.length == microphoneLength)
        let log = try String(contentsOf: SessionFiles.sessionLog(session), encoding: .utf8)
        #expect(log.contains("cleaned microphone unusable, rebuilding"))
    }

    @Test func concurrentRequestsShareOneFinalization() async throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }

        try writeAAC(
            to: SessionFiles.internalFile("mic.caf", in: session),
            channels: 1,
            seconds: 0.6,
            frequency: 330
        )
        try writeAAC(
            to: SessionFiles.internalFile("system.caf", in: session),
            channels: 1,
            seconds: 0.6,
            frequency: 660
        )
        try writeJSON(
            metadata(microphoneOffset: 0, callOffset: 0),
            to: SessionFiles.metadata(session)
        )

        async let first: Void = AudioFinalizer.shared.finalize(session: session)
        async let second: Void = AudioFinalizer.shared.finalize(session: session)
        _ = try await (first, second)

        let published = try readJSON(SessionFiles.metadata(session))
        #expect(published["audio_state"] as? String == "finalized")
        #expect(
            FileManager.default.fileExists(
                atPath: session.appendingPathComponent(AudioFinalizer.meetingAudioPath).path
            )
        )
    }

    @Test func interruptedCaptureJournalRecoversBeforeFinalization() async throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }

        try writeAAC(
            to: SessionFiles.internalFile("mic.caf", in: session),
            channels: 1,
            seconds: 0.4,
            frequency: 440
        )
        try writeEmptyAAC(to: SessionFiles.internalFile("system.caf", in: session))
        try writeJSON(
            [
                "started": "2026-08-19T00:00:00Z",
                "files": [
                    "mic": SessionFiles.internalPath("mic.caf"),
                    "system": SessionFiles.internalPath("system.caf"),
                ],
                "start_offset_ms": ["mic": 0, "system": 0],
            ],
            to: SessionFiles.captureJournal(session)
        )

        try await AudioFinalizer.shared.finalize(session: session)

        let published = try readJSON(SessionFiles.metadata(session))
        #expect(published["recovered_after_interruption"] as? Bool == true)
        let tracks = try #require(published["tracks"] as? [String: [String: Any]])
        #expect(tracks["mic"]?["gaps_known"] as? Bool == false)
        #expect(
            !FileManager.default.fileExists(
                atPath: SessionFiles.captureJournal(session).path
            )
        )
    }

    @Test func interruptedCaptureWithNoFramesBecomesTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-recovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let session = root.appendingPathComponent("2026-08-24 120000", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(session)

        try writeEmptyAAC(to: SessionFiles.internalFile("mic.caf", in: session))
        try writeEmptyAAC(to: SessionFiles.internalFile("system.caf", in: session))
        try writeJSON(
            [
                "started": "2026-08-24T02:00:00Z",
                "files": [
                    "mic": SessionFiles.internalPath("mic.caf"),
                    "system": SessionFiles.internalPath("system.caf"),
                ],
                "start_offset_ms": ["mic": 0, "system": 0],
            ],
            to: SessionFiles.captureJournal(session)
        )

        await AudioFinalizer.shared.recoverPending(in: root)

        let recovered = try readJSON(SessionFiles.metadata(session))
        #expect(recovered["audio_state"] as? String == "empty")
        #expect(!SessionFiles.hasProcessableAudio(session))
        #expect(!FileManager.default.fileExists(atPath: SessionFiles.captureJournal(session).path))
        let log = try String(contentsOf: SessionFiles.sessionLog(session), encoding: .utf8)
        #expect(log.contains("recovered interrupted capture with no audio"))
    }

    @Test func interruptedCaptureWithMissingArchivesRemainsRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-recovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let session = root.appendingPathComponent("2026-08-24 120001", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(session)

        try writeJSON(
            [
                "started": "2026-08-24T02:00:01Z",
                "files": [
                    "mic": SessionFiles.internalPath("mic.caf"),
                    "system": SessionFiles.internalPath("system.caf"),
                ],
                "start_offset_ms": ["mic": 0, "system": 0],
            ],
            to: SessionFiles.captureJournal(session)
        )

        await AudioFinalizer.shared.recoverPending(in: root)

        #expect(!FileManager.default.fileExists(atPath: SessionFiles.metadata(session).path))
        #expect(FileManager.default.fileExists(atPath: SessionFiles.captureJournal(session).path))
        let log = try String(contentsOf: SessionFiles.sessionLog(session), encoding: .utf8)
        #expect(log.contains("audio finalization deferred"))
    }

    @Test func corruptCAFIsPreservedWhenExportFails() async throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }

        let microphone = SessionFiles.internalFile("mic.caf", in: session)
        try Data("not audio".utf8).write(to: microphone)
        var json = metadata(microphoneOffset: 0, callOffset: 0)
        json["files"] = ["mic": SessionFiles.internalPath("mic.caf")]
        try writeJSON(json, to: SessionFiles.metadata(session))

        var failed = false
        do {
            try await AudioFinalizer.shared.finalize(session: session)
        } catch {
            failed = true
        }

        #expect(failed)
        #expect(FileManager.default.fileExists(atPath: microphone.path))
        let preserved = try readJSON(SessionFiles.metadata(session))
        let files = try #require(preserved["files"] as? [String: String])
        #expect(files["mic"] == SessionFiles.internalPath("mic.caf"))
        #expect(preserved["audio_state"] == nil)
    }

    private func temporarySession() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-finalizer-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(root)
        return root
    }

    private func metadata(microphoneOffset: Int, callOffset: Int) -> [String: Any] {
        [
            "started": "2026-08-19T00:00:00Z",
            "ended": "2026-08-19T00:00:01Z",
            "duration_seconds": 1,
            "files": [
                "mic": SessionFiles.internalPath("mic.caf"),
                "system": SessionFiles.internalPath("system.caf"),
            ],
            "start_offset_ms": ["mic": microphoneOffset, "system": callOffset],
            "tracks": [
                "mic": ["file": SessionFiles.internalPath("mic.caf"), "gaps": []],
                "system": ["file": SessionFiles.internalPath("system.caf"), "gaps": []],
            ],
        ]
    }

    private func writeAAC(
        to url: URL,
        channels: AVAudioChannelCount,
        seconds: Double,
        frequency: Double
    ) throws {
        let sampleRate = 48_000.0
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            )
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                samples[channel][frame] = Float(
                    sin(2 * Double.pi * frequency * Double(frame) / sampleRate) * 0.1
                )
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func writeEmptyAAC(to url: URL) throws {
        _ = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    private func writeJSON(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
