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

        let finalMicrophone = session.appendingPathComponent(AudioFinalizer.localPath)
        let finalCall = session.appendingPathComponent(AudioFinalizer.remotePath)
        let meeting = session.appendingPathComponent(AudioFinalizer.meetingAudioPath)
        #expect(try AVAudioFile(forReading: finalMicrophone).length == microphoneLength)
        #expect(try AVAudioFile(forReading: finalCall).length == callLength)
        #expect(try AVAudioFile(forReading: meeting).length > 0)
        let rootItems = try FileManager.default.contentsOfDirectory(
            at: session,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        #expect(rootItems == [".quill", "Meeting Audio.m4a", "Source Audio"])
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
