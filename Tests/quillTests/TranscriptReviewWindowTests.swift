import AppKit
import Foundation
import Testing
@testable import quill

@MainActor
@Suite(.serialized) struct TranscriptReviewWindowTests {
    @Test func usesStandardVisibleWindowControls() throws {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-review-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        try TranscriptStore(session: session).write(TranscriptDocument(
            schema_version: 1,
            engine: "test",
            model: "test",
            diarizer: nil,
            created_at: "2026-08-20T00:00:00Z",
            voices: [
                "mic:1": .init(
                    source: "mic",
                    audio_file: "Source Audio/Local.m4a",
                    machine_label: "Me",
                    name: nil,
                    samples: []
                ),
            ],
            segments: []
        ))

        let controller = try VoiceReviewWindowController(
            session: session,
            isRecording: { false },
            separateSpeakers: {}
        )
        let window = try #require(controller.window)
        let close = try #require(window.standardWindowButton(.closeButton))

        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.titleVisibility == .visible)
        #expect(!window.titlebarAppearsTransparent)
        #expect(!close.isHidden)
        #expect(close.isEnabled)
        let titles = buttonTitles(in: try #require(window.contentView))
        #expect(titles.contains("Show in Finder"))
        #expect(titles.contains("Open Transcript File"))
        #expect(titles.contains("Close"))
        #expect(titles.contains("Save Names"))
        #expect(titles.contains("Separate Voices"))
    }

    @Test func separationSavesTheNameStillBeingEdited() async throws {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-review-pending-name-\(UUID().uuidString)")
        let source = session.appendingPathComponent("Source Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        try Data().write(to: source.appendingPathComponent("Local.m4a"))
        try TranscriptStore(session: session).write(TranscriptDocument(
            schema_version: 1,
            engine: "test",
            model: "test",
            diarizer: nil,
            created_at: "2026-08-20T00:00:00Z",
            voices: [
                "mic:1": .init(
                    source: "mic",
                    audio_file: "Source Audio/Local.m4a",
                    machine_label: "Me",
                    name: nil,
                    samples: []
                ),
            ],
            segments: []
        ))

        let controller = try VoiceReviewWindowController(
            session: session,
            isRecording: { false },
            separateSpeakers: {}
        )
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        let content = try #require(window.contentView)
        let nameField = try #require(textFields(in: content).first {
            $0.placeholderString == "Name this voice"
        })
        #expect(window.makeFirstResponder(nameField))
        let editor = try #require(nameField.currentEditor())
        editor.string = "Matt"
        let separate = try #require(buttons(in: content).first { $0.title == "Separate Voices" })

        separate.performClick(nil)
        try await Task.sleep(for: .milliseconds(50))

        let saved = try TranscriptStore(session: session).read()
        #expect(saved.voices["mic:1"]?.name == "Matt")
    }

    @Test func reviewIsCmdTabVisibleOnlyWhileItsWindowIsOpen() throws {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(originalPolicy) }
        NSApp.setActivationPolicy(.accessory)
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-review-activation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        try TranscriptStore(session: session).write(TranscriptDocument(
            schema_version: 1,
            engine: "test",
            model: "test",
            diarizer: nil,
            created_at: "2026-08-20T00:00:00Z",
            voices: [:],
            segments: []
        ))
        let controller = try VoiceReviewWindowController(
            session: session,
            isRecording: { false },
            separateSpeakers: {}
        )

        controller.show()
        #expect(NSApp.activationPolicy() == .regular)
        controller.window?.performClose(nil)
        #expect(NSApp.activationPolicy() == .accessory)
    }

    private func buttonTitles(in view: NSView) -> [String] {
        let own = (view as? NSButton).map { [$0.title] } ?? []
        return own + view.subviews.flatMap(buttonTitles)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap(buttons)
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap(textFields)
    }
}
