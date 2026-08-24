import AVFoundation
import Foundation
import Testing
@testable import quill

@Suite struct AudioPreparationTests {
    @Test func cleanupFailureFallsBackToRawMicrophone() throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let microphone = SessionFiles.internalFile("mic.caf", in: session)
        let system = SessionFiles.internalFile("system.caf", in: session)
        try writeAAC(to: microphone, seconds: 0.2)
        try Data("not audio".utf8).write(to: system)
        let manifest = SessionManifest(
            started: "2026-08-24T00:00:00Z",
            files: SessionAudioFiles(
                microphone: SessionFiles.internalPath("mic.caf"),
                system: SessionFiles.internalPath("system.caf")
            )
        )
        var messages: [String] = []

        let prepared = try AudioPreparation.prepare(
            session: session,
            manifest: manifest,
            log: { messages.append($0) }
        )

        #expect(prepared.microphone == microphone)
        #expect(prepared.cleanedMicrophone == nil)
        #expect(messages.contains { $0.contains("using mic.caf") })
    }

    @Test func validPublishedCleanedMicrophoneIsTheTranscriptionInput() throws {
        let session = try temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let microphone = SessionFiles.internalFile("mic.caf", in: session)
        let cleaned = session.appendingPathComponent(AudioFinalizer.cleanedLocalPath)
        try FileManager.default.createDirectory(
            at: cleaned.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAAC(to: microphone, seconds: 0.2)
        try writeAAC(to: cleaned, seconds: 0.2)
        let manifest = SessionManifest(
            started: "2026-08-24T00:00:00Z",
            files: SessionAudioFiles(
                microphone: SessionFiles.internalPath("mic.caf"),
                cleanedMicrophone: AudioFinalizer.cleanedLocalPath
            )
        )

        let prepared = try AudioPreparation.prepare(
            session: session,
            manifest: manifest,
            log: { _ in }
        )

        #expect(prepared.cleanedMicrophone == cleaned)
        #expect(prepared.transcriptionSource(for: .microphone) == cleaned)
    }

    private func temporarySession() throws -> URL {
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-audio-preparation-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        _ = try SessionFiles.prepare(session)
        return session
    }

    private func writeAAC(to url: URL, seconds: Double) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frames
        ))
        buffer.frameLength = frames
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}
