import AVFoundation
import Foundation
import Testing
@testable import quill

@Suite(.serialized) struct AudioFinalizerTests {
    @Test func finalizesSourcesAndMeetingAudioBeforePublishingMetadata() async throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }

        let microphone = session.appendingPathComponent("mic.caf")
        let call = session.appendingPathComponent("system.caf")
        try writeAAC(to: microphone, channels: 1, seconds: 0.6, frequency: 330)
        try writeAAC(to: call, channels: 2, seconds: 0.5, frequency: 660)
        let microphoneLength = try AVAudioFile(forReading: microphone).length
        let callLength = try AVAudioFile(forReading: call).length
        try writeJSON(
            metadata(microphoneOffset: 0, callOffset: 100),
            to: session.appendingPathComponent("meta.json")
        )

        try await AudioFinalizer.shared.finalize(session: session)
        try await AudioFinalizer.shared.finalize(session: session)

        let published = try readJSON(session.appendingPathComponent("meta.json"))
        let files = try #require(published["files"] as? [String: String])
        #expect(files["mic"] == AudioFinalizer.microphonePath)
        #expect(files["system"] == AudioFinalizer.callPath)
        #expect(files["meeting"] == AudioFinalizer.meetingAudioPath)
        #expect(published["audio_state"] as? String == "finalized")
        #expect(!FileManager.default.fileExists(atPath: microphone.path))
        #expect(!FileManager.default.fileExists(atPath: call.path))

        let finalMicrophone = session.appendingPathComponent(AudioFinalizer.microphonePath)
        let finalCall = session.appendingPathComponent(AudioFinalizer.callPath)
        let meeting = session.appendingPathComponent(AudioFinalizer.meetingAudioPath)
        #expect(try AVAudioFile(forReading: finalMicrophone).length == microphoneLength)
        #expect(try AVAudioFile(forReading: finalCall).length == callLength)
        #expect(try AVAudioFile(forReading: meeting).length > 0)
    }

    @Test func interruptedCaptureJournalRecoversBeforeFinalization() async throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }

        try writeAAC(
            to: session.appendingPathComponent("mic.caf"),
            channels: 1,
            seconds: 0.4,
            frequency: 440
        )
        try writeJSON(
            [
                "started": "2026-08-19T00:00:00Z",
                "meeting_profile": "neither",
                "files": ["mic": "mic.caf", "system": "system.caf"],
                "start_offset_ms": ["mic": 0, "system": 0],
            ],
            to: session.appendingPathComponent(RecordingSession.captureJournalName)
        )

        try await AudioFinalizer.shared.finalize(session: session)

        let published = try readJSON(session.appendingPathComponent("meta.json"))
        #expect(published["recovered_after_interruption"] as? Bool == true)
        let tracks = try #require(published["tracks"] as? [String: [String: Any]])
        #expect(tracks["mic"]?["gaps_known"] as? Bool == false)
        #expect(
            !FileManager.default.fileExists(
                atPath: session.appendingPathComponent(RecordingSession.captureJournalName).path
            )
        )
    }

    @Test func corruptCAFIsPreservedWhenExportFails() async throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }

        let microphone = session.appendingPathComponent("mic.caf")
        try Data("not audio".utf8).write(to: microphone)
        var json = metadata(microphoneOffset: 0, callOffset: 0)
        json["files"] = ["mic": "mic.caf"]
        try writeJSON(json, to: session.appendingPathComponent("meta.json"))

        var failed = false
        do {
            try await AudioFinalizer.shared.finalize(session: session)
        } catch {
            failed = true
        }

        #expect(failed)
        #expect(FileManager.default.fileExists(atPath: microphone.path))
        let preserved = try readJSON(session.appendingPathComponent("meta.json"))
        let files = try #require(preserved["files"] as? [String: String])
        #expect(files["mic"] == "mic.caf")
        #expect(preserved["audio_state"] == nil)
    }

    private func temporarySession() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-finalizer-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func metadata(microphoneOffset: Int, callOffset: Int) -> [String: Any] {
        [
            "started": "2026-08-19T00:00:00Z",
            "ended": "2026-08-19T00:00:01Z",
            "duration_seconds": 1,
            "meeting_profile": "neither",
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": microphoneOffset, "system": callOffset],
            "tracks": [
                "mic": ["file": "mic.caf", "gaps": []],
                "system": ["file": "system.caf", "gaps": []],
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
