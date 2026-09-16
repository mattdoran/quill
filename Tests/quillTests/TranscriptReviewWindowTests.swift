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
        let source = session.appendingPathComponent("Source Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("Local.m4a"))
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
        #expect(titles.contains("Copy Markdown"))
        #expect(titles.contains("Show in Finder"))
        #expect(titles.contains("Open Transcript File"))
        #expect(titles.contains("Close"))
        #expect(titles.contains("Save Names"))
        #expect(titles.contains("Separate Voices…"))
    }

    @Test func presentsOneSeparationActionForLocalAndRemoteAudio() throws {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-review-separation-sources-\(UUID().uuidString)")
        let source = session.appendingPathComponent("Source Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("Local.m4a"))
        try Data().write(to: source.appendingPathComponent("Remote.m4a"))
        defer { try? FileManager.default.removeItem(at: session) }
        try TranscriptStore(session: session).write(TranscriptDocument(
            schema_version: 1,
            engine: "test",
            model: "test",
            diarizer: nil,
            created_at: "2026-08-20T00:00:00Z",
            voices: [
                "mic:1": .init(
                    source: "mic", audio_file: "Source Audio/Local.m4a",
                    machine_label: "Me", name: nil, samples: []
                ),
                "system:1": .init(
                    source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Them", name: nil, samples: []
                ),
            ],
            segments: []
        ))

        let controller = try VoiceReviewWindowController(
            session: session,
            isRecording: { false },
            separateSpeakers: {}
        )
        let titles = buttonTitles(in: try #require(controller.window?.contentView))

        #expect(titles.filter { $0 == "Separate Voices…" }.count == 1)
    }

    @Test func separationSavesTheNameStillBeingEdited() throws {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-review-pending-name-\(UUID().uuidString)")
        let source = session.appendingPathComponent("Source Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        try Data().write(to: source.appendingPathComponent("Remote.m4a"))
        try TranscriptStore(session: session).write(TranscriptDocument(
            schema_version: 1,
            engine: "test",
            model: "test",
            diarizer: nil,
            created_at: "2026-08-20T00:00:00Z",
            voices: [
                "system:1": .init(
                    source: "system",
                    audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Them",
                    name: nil,
                    samples: []
                ),
            ],
            segments: []
        ))

        let controller = try VoiceReviewWindowController(
            session: session,
            isRecording: { false },
            separateSpeakers: { _, _ in },
            chooseSpeakerCounts: { _ in
                let saved = try? TranscriptStore(session: session).read()
                #expect(saved?.voices["system:1"]?.name == "Matt")
                return nil
            }
        )
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        let content = try #require(window.contentView)
        let nameField = try #require(textFields(in: content).first {
            $0.placeholderString == "Name this voice"
        })
        let editor = try #require(nameField.currentEditor())
        #expect(window.firstResponder === editor)
        editor.string = "Matt"
        let separate = try #require(buttons(in: content).first {
            $0.title == "Separate Voices…"
        })

        separate.performClick(nil)
        let saved = try TranscriptStore(session: session).read()
        #expect(saved.voices["system:1"]?.name == "Matt")
    }

    @Test func speakerControlsHaveAnExplicitKeyboardPath() throws {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-review-keyboard-\(UUID().uuidString)")
        let source = session.appendingPathComponent("Source Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        try Data().write(to: source.appendingPathComponent("Local.m4a"))
        try TranscriptStore(session: session).write(TranscriptDocument(
            schema_version: 1,
            engine: "test",
            model: "test",
            diarizer: "test",
            created_at: "2026-08-20T00:00:00Z",
            voices: [
                "mic:1": .init(
                    source: "mic", audio_file: "Source Audio/Local.m4a",
                    machine_label: "Voice 1", name: nil,
                    samples: [.init(start_ms: 0, end_ms: 1_000)]
                ),
                "mic:2": .init(
                    source: "mic", audio_file: "Source Audio/Local.m4a",
                    machine_label: "Voice 2", name: nil,
                    samples: [.init(start_ms: 1_000, end_ms: 2_000)]
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
        let content = try #require(window.contentView)
        let fields = textFields(in: content).filter { $0.placeholderString == "Name this voice" }
        let play = buttons(in: content).filter { $0.title.hasPrefix("Play Sample") }
        let separate = try #require(buttons(in: content).first { $0.title == "Separate Voices Again…" })
        let copy = try #require(buttons(in: content).first { $0.title == "Copy Markdown" })
        let finder = try #require(buttons(in: content).first { $0.title == "Show in Finder" })
        let markdown = try #require(buttons(in: content).first { $0.title == "Open Transcript File" })
        let close = try #require(buttons(in: content).first { $0.title == "Close" })
        let save = try #require(buttons(in: content).first { $0.title == "Save Names" })
        let transcript = try #require(textViews(in: content).first)

        #expect(fields.count == 2)
        #expect(play.count == 2)
        #expect(window.initialFirstResponder === fields[0])
        #expect(fields[0].nextKeyView === play[0])
        #expect(play[0].nextKeyView === fields[1])
        #expect(fields[1].nextKeyView === play[1])
        #expect(play[1].nextKeyView === separate)
        #expect(separate.nextKeyView === copy)
        #expect(copy.nextKeyView === finder)
        #expect(finder.nextKeyView === markdown)
        #expect(markdown.nextKeyView === close)
        #expect(close.nextKeyView === save)
        #expect(save.nextKeyView === transcript)
        #expect(transcript.nextKeyView === fields[0])
        #expect(fields[1].nextValidKeyView === play[1])
        #expect(play[1].nextValidKeyView === separate)
        #expect(fields[0].accessibilityHelp() == "Press Return to move to the next speaker name.")
        #expect(fields[1].accessibilityHelp() == "Press Return to save speaker names.")

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let firstEditor = try #require(fields[0].currentEditor())
        firstEditor.string = "Finn"
        firstEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(window.firstResponder === play[0])
        window.selectNextKeyView(play[0])
        let secondEditor = try #require(fields[1].currentEditor())
        #expect(window.firstResponder === secondEditor)
        secondEditor.string = "Matt"
        secondEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(window.firstResponder === play[1])
        window.selectNextKeyView(play[1])
        #expect(window.firstResponder === separate)
        window.selectNextKeyView(separate)
        #expect(window.firstResponder === copy)
        window.selectNextKeyView(copy)
        #expect(window.firstResponder === finder)

        window.makeFirstResponder(fields[0])
        let refreshedFirstEditor = try #require(fields[0].currentEditor())
        refreshedFirstEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let refreshedSecondEditor = try #require(fields[1].currentEditor())
        #expect(window.firstResponder === refreshedSecondEditor)
        refreshedSecondEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        let saved = try TranscriptStore(session: session).read()
        #expect(saved.voices["mic:1"]?.name == "Finn")
        #expect(saved.voices["mic:2"]?.name == "Matt")
        let refreshedFields = textFields(in: try #require(window.contentView)).filter {
            $0.placeholderString == "Name this voice"
        }
        #expect(window.firstResponder === refreshedFields[1].currentEditor())
    }

    @Test func separatedTranscriptOffersUndoWhenBaselineSnapshotExists() throws {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-review-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        let baseline = TranscriptDocument(
            schema_version: 1,
            engine: "test",
            model: "test",
            diarizer: nil,
            created_at: "2026-08-20T00:00:00Z",
            voices: [:],
            segments: []
        )
        let source = session.appendingPathComponent("Source Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("Remote.m4a"))
        let separated = TranscriptDocument(
            schema_version: 1,
            engine: "test",
            model: "test",
            diarizer: "sortformer-offline-v2.1",
            created_at: baseline.created_at,
            voices: [
                "system:1": .init(
                    source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Voice 1", name: nil, samples: []
                ),
            ],
            segments: []
        )
        let store = TranscriptStore(session: session)
        try store.preserveBeforeSpeakerSeparation(baseline)
        try store.write(separated)

        let controller = try VoiceReviewWindowController(
            session: session,
            isRecording: { false },
            separateSpeakers: {}
        )
        let content = try #require(controller.window?.contentView)
        #expect(buttonTitles(in: content).contains("Undo Voice Separation"))
        #expect(buttonTitles(in: content).contains("Separate Voices Again…"))
    }

    @Test func unavailableSampleHasAnAccurateAccessibilityLabel() throws {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-review-unavailable-sample-\(UUID().uuidString)")
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
                    source: "mic", audio_file: "Source Audio/Local.m4a",
                    machine_label: "Me", name: nil, samples: []
                ),
            ],
            segments: []
        ))

        let controller = try VoiceReviewWindowController(
            session: session,
            isRecording: { false },
            separateSpeakers: {}
        )
        let content = try #require(controller.window?.contentView)
        let sample = try #require(buttons(in: content).first { $0.title == "Sample Unavailable" })

        #expect(sample.accessibilityLabel() == "Sample unavailable for Me")
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

    @Test func sixSpeakerReviewStartsAtTheFirstVoiceAndScrolls() throws {
        _ = NSApplication.shared
        let session = try makeHybridSession()
        defer { try? FileManager.default.removeItem(at: session) }
        let store = TranscriptStore(session: session)
        var document = try store.read()
        for number in 2...4 {
            document.voices["system:\(number)"] = .init(
                source: "system", audio_file: "Source Audio/Remote.m4a",
                machine_label: "Voice \(number + 2)", name: nil, samples: []
            )
        }
        try store.write(document)
        let controller = try VoiceReviewWindowController(
            session: session, isRecording: { false }, separateSpeakers: {}
        )
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let fields = textFields(in: content).filter { $0.placeholderString == "Name this voice" }
        #expect(fields.count == 6)
        let first = try #require(fields.first)
        var ancestor = first.superview
        while ancestor != nil && !(ancestor is NSScrollView) { ancestor = ancestor?.superview }
        let scroll = try #require(ancestor as? NSScrollView)
        let list = try #require(scroll.documentView)
        #expect(scroll.documentVisibleRect.intersects(first.convert(first.bounds, to: list)))
        #expect(list.bounds.height > scroll.documentVisibleRect.height)
        let last = try #require(fields.last)
        last.scrollToVisible(last.bounds)
        #expect(scroll.documentVisibleRect.intersects(last.convert(last.bounds, to: list)))
    }

    @Test func countPickerKeepsLocalAndRemoteCountsIndependent() throws {
        _ = NSApplication.shared
        let (alert, picker) = SpeakerCountPicker.makeAlert(
            tracks: [.microphone, .system],
            selections: [.microphone: .exact(2), .system: .exact(4)],
            replacingSeparatedTracks: true
        )
        #expect(alert.accessoryView === picker)
        #expect(picker.selections == [.microphone: .exact(2), .system: .exact(4)])
        let remote = try #require(picker.arrangedSubviews.compactMap { $0 as? NSPopUpButton }
            .first { $0.identifier?.rawValue == "system" })
        remote.selectItem(withTag: 0)
        #expect(picker.selections == [.microphone: .exact(2), .system: .automatic])
        remote.selectItem(withTag: 1)
        #expect(picker.selections[.system] == .exact(1))
        remote.selectItem(withTag: -1)
        #expect(picker.selections == [.microphone: .exact(2)])
    }

    @Test func countPickerStartsUnchangedAndRequiresASelection() throws {
        _ = NSApplication.shared
        let (alert, picker) = SpeakerCountPicker.makeAlert(
            tracks: [.microphone, .system], selections: [:], replacingSeparatedTracks: false
        )
        #expect(picker.selections.isEmpty)
        #expect(!alert.buttons[0].isEnabled)

        let remote = try #require(picker.arrangedSubviews.compactMap { $0 as? NSPopUpButton }
            .first { $0.identifier?.rawValue == "system" })
        remote.selectItem(withTag: 3)
        remote.sendAction(remote.action, to: remote.target)
        #expect(picker.selections == [.system: .exact(3)])
        #expect(alert.buttons[0].isEnabled)
    }

    @Test func separationActionPassesSelectedLocalAndRemoteCounts() async throws {
        _ = NSApplication.shared
        let session = try makeHybridSession()
        defer { try? FileManager.default.removeItem(at: session) }
        actor Capture {
            var received: [SourceTrack: SpeakerCountSelection]?
            func setReceived(_ value: [SourceTrack: SpeakerCountSelection]) {
                received = value
            }
        }
        let capture = Capture()
        var observedPrevious: [SourceTrack: SpeakerCountSelection]?
        let controller = try VoiceReviewWindowController(
            session: session, isRecording: { false },
            separateSpeakers: { selections, _ in
                await capture.setReceived(selections)
            },
            chooseSpeakerCounts: { previous in
                observedPrevious = previous
                return [.microphone: .exact(2), .system: .exact(4)]
            }
        )
        let content = try #require(controller.window?.contentView)
        let separate = try #require(buttons(in: content).first { $0.title == "Separate Voices Again…" })
        separate.performClick(nil)
        var completed = false
        for _ in 0..<100 {
            if await capture.received != nil,
               let current = controller.window?.contentView,
               buttons(in: current).contains(where: { $0.title == "Save Names" && $0.isEnabled }) {
                completed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(completed, "Wait for the review to finish refreshing before removing its session")
        let received = await capture.received
        #expect(observedPrevious == [.microphone: .exact(2)])
        #expect(received == [.microphone: .exact(2), .system: .exact(4)])
    }

    @Test func separationActionRemembersSourcesLeftUnchanged() async throws {
        _ = NSApplication.shared
        let session = try makeHybridSession()
        defer { try? FileManager.default.removeItem(at: session) }
        var previousSelections: [[SourceTrack: SpeakerCountSelection]] = []
        let controller = try VoiceReviewWindowController(
            session: session, isRecording: { false },
            separateSpeakers: { _, _ in },
            chooseSpeakerCounts: { previous in
                previousSelections.append(previous)
                return previousSelections.count == 1 ? [.system: .exact(4)] : nil
            }
        )
        var content = try #require(controller.window?.contentView)
        try #require(buttons(in: content).first { $0.title == "Separate Voices Again…" })
            .performClick(nil)
        for _ in 0..<100 {
            content = try #require(controller.window?.contentView)
            if buttons(in: content).contains(where: { $0.title == "Separate Voices Again…" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(buttons(in: content).first { $0.title == "Separate Voices Again…" })
            .performClick(nil)

        #expect(previousSelections == [
            [.microphone: .exact(2)],
            [.system: .exact(4)],
        ])
    }

    @Test func cancellingCountSelectionDoesNotRunAnalysis() async throws {
        _ = NSApplication.shared
        let session = try makeHybridSession()
        defer { try? FileManager.default.removeItem(at: session) }
        actor Capture {
            var invoked = false
            func setInvoked() { invoked = true }
            func isInvoked() -> Bool { invoked }
        }
        let capture = Capture()
        let controller = try VoiceReviewWindowController(
            session: session, isRecording: { false },
            separateSpeakers: { _, _ in await capture.setInvoked() },
            chooseSpeakerCounts: { _ in nil }
        )
        let content = try #require(controller.window?.contentView)
        let separate = try #require(buttons(in: content)
            .first { $0.title == "Separate Voices Again…" })
        separate.performClick(nil)
        let invoked = await capture.isInvoked()
        #expect(!invoked)
        #expect(separate.isEnabled)
    }

    @Test func copyMarkdownIncludesActiveNameEditsAndAllSegments() throws {
        _ = NSApplication.shared
        let session = try makeHybridSession()
        defer { try? FileManager.default.removeItem(at: session) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quill-markdown-\(UUID().uuidString)"))
        let controller = try VoiceReviewWindowController(
            session: session, isRecording: { false }, separateSpeakers: { _, _ in },
            pasteboard: pasteboard
        )
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        let field = try #require(textFields(in: content).first { $0.placeholderString == "Name this voice" })
        let editor = try #require(field.currentEditor())
        editor.string = "Eugene"
        let copy = try #require(buttons(in: content).first { $0.title == "Copy Markdown" })
        #expect(copy.keyEquivalent == "c")
        #expect(copy.keyEquivalentModifierMask == [.command, .shift])
        copy.performClick(nil)
        let saved = try TranscriptStore(session: session).read()
        let expected = saved.rendered(title: session.lastPathComponent)
        #expect(pasteboard.string(forType: .string) == expected)
        #expect(pasteboard.string(forType: .init("net.daringfireball.markdown")) == expected)
        #expect(expected.contains("**[0:00] Eugene:** Local words"))
        #expect(expected.contains("Remote words"))
        #expect(saved.voices["mic:1"]?.name == "Eugene")
        #expect(try String(contentsOf: TranscriptStore(session: session).markdownURL, encoding: .utf8) == expected)
    }

    @Test func rememberingIsExplicitAndSuggestionsNeedAcceptance() throws {
        _ = NSApplication.shared
        let session = try makeHybridSession()
        defer { try? FileManager.default.removeItem(at: session) }
        try SessionMetadataStore.writeManifest(
            SessionManifest(
                started: "2026-09-16T09:30:00Z",
                files: SessionAudioFiles(
                    microphone: "Source Audio/Local.m4a",
                    system: "Source Audio/Remote.m4a"
                )
            ),
            to: session
        )
        let store = TranscriptStore(session: session)
        var document = try store.read()
        document.voices["mic:1"]?.embedding_model = "test-embedding"
        document.voices["mic:1"]?.embedding = [1, 0, 0]
        try store.write(document)
        let memory = VoiceProfileStore(url: session.appendingPathComponent("profiles.json"))
        let controller = try VoiceReviewWindowController(
            session: session, isRecording: { false }, separateSpeakers: { _, _ in },
            profileStore: memory
        )
        var content = try #require(controller.window?.contentView)
        let field = try #require(textFields(in: content).first { $0.placeholderString == "Name this voice" })
        field.stringValue = "Eugene"
        try #require(buttons(in: content).first { $0.title == "Save Names" }).performClick(nil)
        #expect(try memory.load().isEmpty)
        content = try #require(controller.window?.contentView)
        let remember = try #require(buttons(in: content).first { $0.title == "Remember Voice" })
        #expect(remember.isEnabled)
        remember.performClick(nil)
        #expect(try memory.load().count == 1)
        #expect(try memory.load().first?.contributions.first?.session_id == "2026-09-16T09:30:00Z")
        #expect(try store.read().voices["mic:1"]?.remembered_profile_id != nil)
        #expect(buttonTitles(in: try #require(controller.window?.contentView)).contains("Voice Remembered"))

        let nextSession = try makeHybridSession()
        defer { try? FileManager.default.removeItem(at: nextSession) }
        let nextStore = TranscriptStore(session: nextSession)
        var next = try nextStore.read()
        next.voices["mic:1"]?.embedding_model = "test-embedding"
        next.voices["mic:1"]?.embedding = [1, 0, 0]
        try nextStore.write(next)
        let nextController = try VoiceReviewWindowController(
            session: nextSession, isRecording: { false }, separateSpeakers: { _, _ in },
            profileStore: memory
        )
        let nextContent = try #require(nextController.window?.contentView)
        let nextField = try #require(textFields(in: nextContent).first { $0.placeholderString == "Name this voice" })
        #expect(nextField.stringValue.isEmpty)
        #expect(try nextStore.read().voices["mic:1"]?.name == nil)
        let use = try #require(buttons(in: nextContent).first { $0.title == "Use Eugene" })
        use.performClick(nil)
        #expect(nextField.stringValue == "Eugene")
        try #require(buttons(in: nextContent).first { $0.title == "Save Names" }).performClick(nil)
        #expect(try nextStore.read().voices["mic:1"]?.name == "Eugene")
        #expect(try memory.load().first?.contribution_count == 1)
    }

    private func makeHybridSession() throws -> URL {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-review-hybrid-\(UUID().uuidString)")
        let source = session.appendingPathComponent("Source Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("Local.m4a"))
        try Data().write(to: source.appendingPathComponent("Remote.m4a"))
        try TranscriptStore(session: session).write(TranscriptDocument(
            schema_version: 1, engine: "test", model: "test", diarizer: "test",
            created_at: "2026-09-16T00:00:00Z",
            voices: [
                "mic:1": .init(source: "mic", audio_file: "Source Audio/Local.m4a",
                    machine_label: "Voice 1", name: nil, samples: []),
                "mic:2": .init(source: "mic", audio_file: "Source Audio/Local.m4a",
                    machine_label: "Voice 2", name: nil, samples: []),
                "system:1": .init(source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Them", name: nil, samples: []),
                "system:2": .init(source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Them 2", name: nil, samples: []),
                "system:3": .init(source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Them 3", name: nil, samples: []),
                "system:4": .init(source: "system", audio_file: "Source Audio/Remote.m4a",
                    machine_label: "Them 4", name: nil, samples: []),
            ],
            segments: [
                .init(speaker: "Voice 1", voice_id: "mic:1", start_ms: 0, end_ms: 1000, text: "Local words"),
                .init(speaker: "Them", voice_id: "system:1", start_ms: 2000, end_ms: 3000, text: "Remote words"),
            ]
        ))
        return session
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

    private func textViews(in view: NSView) -> [NSTextView] {
        let own = (view as? NSTextView).map { [$0] } ?? []
        return own + view.subviews.flatMap(textViews)
    }
}
