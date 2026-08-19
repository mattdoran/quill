import AppKit
import ArgumentParser

struct PreviewVoices: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview-voices",
        abstract: "Render deterministic voice-identification previews.",
        shouldDisplay: false
    )

    @Option(name: .long)
    var out: String

    func run() throws {
        try MainActor.assumeIsolated {
            _ = NSApplication.shared
            let output = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let previewRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("quill-voice-preview-\(UUID().uuidString)")
            let session = previewRoot.appendingPathComponent("2026.08.19-1432")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: previewRoot) }
            let source = session.appendingPathComponent("Source Audio")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data().write(to: source.appendingPathComponent("Microphone.m4a"))
            try Data().write(to: source.appendingPathComponent("Call.m4a"))

            @MainActor func render(_ suffix: String) throws {
                for (name, appearance) in [
                    ("light", NSAppearance.Name.aqua), ("dark", .darkAqua),
                ] {
                    let controller = try VoiceReviewWindowController(
                        session: session,
                        isRecording: { false },
                        separateSpeakers: {},
                        appearance: NSAppearance(named: appearance)
                    )
                    guard let view = controller.window?.contentView else { continue }
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { continue }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:])
                    else { continue }
                    try png.write(to: output.appendingPathComponent("\(name)-\(suffix).png"))
                }
            }

            let basicVoices = [
                "mic:1": TranscriptDocument.Voice(
                    source: "mic", audio_file: "Source Audio/Microphone.m4a",
                    machine_label: "In the room", name: nil,
                    samples: [.init(start_ms: 12_000, end_ms: 17_000)]
                ),
                "system:1": TranscriptDocument.Voice(
                    source: "system", audio_file: "Source Audio/Call.m4a",
                    machine_label: "On the call", name: nil,
                    samples: [.init(start_ms: 7_000, end_ms: 13_000)]
                ),
            ]
            try TranscriptStore(session: session).write(TranscriptDocument(
                schema_version: 1,
                engine: "parakeet", model: "tdt-0.6b-v3", diarizer: nil,
                created_at: "2026-08-19T12:00:00Z", voices: basicVoices,
                segments: []
            ))
            try render("review-speakers")

            let voices = [
                "mic:1": TranscriptDocument.Voice(
                    source: "mic", audio_file: "Source Audio/Microphone.m4a",
                    machine_label: "room 1", name: nil,
                    samples: [
                        .init(start_ms: 12_000, end_ms: 17_000),
                        .init(start_ms: 42_000, end_ms: 48_000),
                        .init(start_ms: 62_000, end_ms: 69_000),
                    ]
                ),
                "mic:2": TranscriptDocument.Voice(
                    source: "mic", audio_file: "Source Audio/Microphone.m4a",
                    machine_label: "room 2", name: nil,
                    samples: [.init(start_ms: 22_000, end_ms: 28_000)]
                ),
                "system:1": TranscriptDocument.Voice(
                    source: "system", audio_file: "Source Audio/Call.m4a",
                    machine_label: "them 1", name: nil,
                    samples: [.init(start_ms: 7_000, end_ms: 13_000)]
                ),
                "system:2": TranscriptDocument.Voice(
                    source: "system", audio_file: "Source Audio/Call.m4a",
                    machine_label: "them 2", name: nil,
                    samples: [.init(start_ms: 31_000, end_ms: 36_000)]
                ),
            ]
            let transcript = TranscriptDocument(
                schema_version: 1,
                engine: "parakeet", model: "tdt-0.6b-v3", diarizer: "sortformer-offline-v2.1",
                created_at: "2026-08-19T12:00:00Z", voices: voices,
                segments: []
            )
            try TranscriptStore(session: session).write(transcript)
            try render("identify-voices")
        }
    }
}
