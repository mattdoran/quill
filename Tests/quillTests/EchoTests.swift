import AVFoundation
import Foundation
import Testing
@testable import quill

@Suite struct EchoTests {
    @Test func aLocalRowRepeatingTheCallIsEcho() {
        let rows = [
            row("system:1", 1_000, "We will then put together a proposal for you."),
            row("mic:1", 1_800, "Um we will then put together a proposal for you."),
            row("mic:1", 5_000, "That sounds good, send it through please."),
        ]
        #expect(EchoRows.flags(for: rows) == [false, true, false])
    }

    @Test func echoNeedsFiveWordsTheCallFirstAndTheWindow() {
        let short = [row("system:1", 1_000, "How are you?"), row("mic:1", 1_200, "How are you?")]
        #expect(EchoRows.flags(for: short) == [false, false])

        let words = "Four hours a month is plenty."
        let first = [row("system:1", 1_100, words), row("mic:1", 1_000, words)]
        #expect(EchoRows.flags(for: first) == [false, false])

        let late = [row("system:1", 1_000, words, end: 2_000), row("mic:1", 5_100, words)]
        #expect(EchoRows.flags(for: late) == [false, false])
    }

    @Test func echoRowsAreHiddenAndDoNotCountAsSpeakingTime() {
        var echo = row("mic:1", 1_800, "Um we will then put together a proposal for you.", speaker: "Matt", end: 9_000)
        echo.echo = true
        let document = TranscriptDocument(
            schema_version: 1, engine: "parakeet", model: "test", diarizer: nil,
            created_at: "2026-10-28T00:00:00Z", voices: [:],
            segments: [
                row("system:1", 1_000, "We will then put together a proposal for you.", speaker: "Will", end: 3_000),
                echo,
                row("system:1", 3_100, "It sets out what we recommend.", speaker: "Will", end: 5_000),
            ]
        )
        #expect(document.turns.map(\.speaker) == ["Will"])
        #expect(document.speakersBySpeakingTime == ["Will"])
    }

    @Test func delayIsFoundAtTheLagTheMicrophoneHearsTheCall() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-echo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var generator = SystemRandomNumberGenerator()
        let rate = 16_000.0
        let seconds = 30
        // Bursts of speech-like loudness, so the envelope has shape to match.
        let gains = (0..<(seconds * 10)).map { _ in Float.random(in: 0...1, using: &generator) > 0.5 ? Float(0.5) : 0.01 }
        let call = (0..<(Int(rate) * seconds)).map { gains[$0 / 1_600] * Float.random(in: -1...1, using: &generator) }
        let delay = Int(rate * 0.3)
        let heard = (0..<call.count).map { index in
            (index >= delay ? 0.2 * call[index - delay] : 0) + 0.001 * Float.random(in: -1...1, using: &generator)
        }
        let silence = (0..<call.count).map { _ in 0.01 * Float.random(in: -1...1, using: &generator) }
        try write(call, rate: rate, to: dir.appendingPathComponent("call.caf"))
        try write(heard, rate: rate, to: dir.appendingPathComponent("mic.caf"))
        try write(silence, rate: rate, to: dir.appendingPathComponent("quiet.caf"))

        let echo = try #require(try EchoDelay.estimate(
            microphone: dir.appendingPathComponent("mic.caf"), microphoneOffsetMilliseconds: 0,
            call: dir.appendingPathComponent("call.caf"), callOffsetMilliseconds: 0
        ))
        #expect(echo.foundEcho)
        #expect(abs(echo.milliseconds - 300) <= 10)

        let shifted = try #require(try EchoDelay.estimate(
            microphone: dir.appendingPathComponent("mic.caf"), microphoneOffsetMilliseconds: 100,
            call: dir.appendingPathComponent("call.caf"), callOffsetMilliseconds: 0
        ))
        #expect(abs(shifted.milliseconds - 400) <= 10)

        let none = try #require(try EchoDelay.estimate(
            microphone: dir.appendingPathComponent("quiet.caf"), microphoneOffsetMilliseconds: 0,
            call: dir.appendingPathComponent("call.caf"), callOffsetMilliseconds: 0
        ))
        #expect(!none.foundEcho)
    }

    private func row(
        _ voice: String, _ start: Int, _ text: String, speaker: String? = nil, end: Int? = nil
    ) -> TranscriptDocument.Segment {
        .init(
            speaker: speaker ?? (voice.hasPrefix("mic") ? "Me" : "Them"), voice_id: voice,
            start_ms: start, end_ms: end ?? start + 1_000, text: text
        )
    }

    private func write(_ samples: [Float], rate: Double, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
