import AppKit
import Testing
@testable import quill

@MainActor
@Suite(.serialized) struct MeetingsWindowTests {
    @Test func listsNewestFirstAndOffersReviewOnlyWhenNotRecording() throws {
        AppKitTestHost.start()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-meetings-window-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["2026.10.27-0900", "2026.10.28-0900"] {
            let session = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try TranscriptStore(session: session).write(TranscriptDocument(
                schema_version: 1, engine: "parakeet", model: "test", diarizer: "test",
                created_at: "2026-10-28T00:00:00Z",
                voices: ["mic:1": .init(
                    source: "mic", audio_file: "Source Audio/Local.m4a", machine_label: "Me",
                    name: "Matt", samples: []
                )],
                segments: [.init(speaker: "Matt", voice_id: "mic:1", start_ms: 0, end_ms: 1_000, text: "Hello.")]
            ))
        }
        var recording = false
        let controller = MeetingsWindowController(root: { root }, presence: ApplicationPresenceController())
        controller.isRecording = { recording }
        controller.reload()

        let content = try #require(controller.window?.contentView)
        let table = try #require(views(NSTableView.self, in: content).first)
        let review = try #require(views(NSButton.self, in: content).first { $0.title == "Review" })
        let open = try #require(views(NSButton.self, in: content).first { $0.title == "Open Transcript" })
        #expect(table.numberOfRows == 2)
        #expect(table.selectedRow == 0)
        #expect(review.isEnabled)
        #expect(open.isEnabled)
        #expect(review.keyEquivalent == "\r")

        recording = true
        controller.reload()
        #expect(!review.isEnabled)
        #expect(open.isEnabled)
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
}
