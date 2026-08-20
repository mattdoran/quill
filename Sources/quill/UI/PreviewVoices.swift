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
            try Data().write(to: source.appendingPathComponent("Local.m4a"))
            try Data().write(to: source.appendingPathComponent("Remote.m4a"))

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
                    source: "mic", audio_file: "Source Audio/Local.m4a",
                    machine_label: "Me", name: nil,
                    samples: [.init(start_ms: 12_000, end_ms: 17_000)]
                ),
                "system:1": TranscriptDocument.Voice(
                    source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Them", name: nil,
                    samples: [.init(start_ms: 7_000, end_ms: 13_000)]
                ),
            ]
            let basicSegments = [
                TranscriptDocument.Segment(
                    speaker: "Me", voice_id: "mic:1", start_ms: 1_400,
                    end_ms: 4_800, text: "Let’s keep the first version focused on the review flow."
                ),
                TranscriptDocument.Segment(
                    speaker: "Them", voice_id: "system:1", start_ms: 5_100,
                    end_ms: 9_300, text: "Agreed. The transcript should be useful before anyone configures speakers."
                ),
                TranscriptDocument.Segment(
                    speaker: "Me", voice_id: "mic:1", start_ms: 10_200,
                    end_ms: 14_600, text: "Then speaker separation can stay optional and happen here."
                ),
            ]
            try TranscriptStore(session: session).write(TranscriptDocument(
                schema_version: 1,
                engine: "parakeet", model: "tdt-0.6b-v3", diarizer: nil,
                created_at: "2026-08-19T12:00:00Z", voices: basicVoices,
                segments: basicSegments
            ))
            try render("review-speakers")

            let voices = [
                "mic:1": TranscriptDocument.Voice(
                    source: "mic", audio_file: "Source Audio/Local.m4a",
                    machine_label: "Voice 1", name: nil,
                    samples: [
                        .init(start_ms: 12_000, end_ms: 17_000),
                        .init(start_ms: 42_000, end_ms: 48_000),
                        .init(start_ms: 62_000, end_ms: 69_000),
                    ]
                ),
                "mic:2": TranscriptDocument.Voice(
                    source: "mic", audio_file: "Source Audio/Local.m4a",
                    machine_label: "Voice 2", name: nil,
                    samples: [.init(start_ms: 22_000, end_ms: 28_000)]
                ),
                "system:1": TranscriptDocument.Voice(
                    source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Voice 3", name: nil,
                    samples: [.init(start_ms: 7_000, end_ms: 13_000)]
                ),
                "system:2": TranscriptDocument.Voice(
                    source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Voice 4", name: nil,
                    samples: [.init(start_ms: 31_000, end_ms: 36_000)]
                ),
            ]
            let transcript = TranscriptDocument(
                schema_version: 1,
                engine: "parakeet", model: "tdt-0.6b-v3", diarizer: "sortformer-offline-v2.1",
                created_at: "2026-08-19T12:00:00Z", voices: voices,
                segments: [
                    .init(
                        speaker: "Voice 1", voice_id: "mic:1", start_ms: 1_400,
                        end_ms: 4_800, text: "Let’s keep the first version focused on the review flow."
                    ),
                    .init(
                        speaker: "Voice 3", voice_id: "system:1", start_ms: 5_100,
                        end_ms: 9_300, text: "Agreed. The transcript should be useful before anyone configures speakers."
                    ),
                    .init(
                        speaker: "Voice 2", voice_id: "mic:2", start_ms: 10_200,
                        end_ms: 14_600, text: "Then speaker separation can stay optional and happen here."
                    ),
                ]
            )
            try TranscriptStore(session: session).write(transcript)
            try render("identify-voices")
        }
    }
}
