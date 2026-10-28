import Foundation
import Testing
@testable import quill

@Suite struct MeetingsTests {
    @Test func stateFollowsTheSessionFiles() throws {
        try withRoot { root in
            let recording = try session(root, "2026.10.28-0900")
            _ = try SessionFiles.prepare(recording)
            try SessionMetadataStore.writeJournal(
                CaptureJournal(started: "2026-10-27T22:00:00Z", files: audio, startOffsets: .init()),
                to: recording
            )
            try manifest(try session(root, "2026.10.28-1000"), state: nil)
            try manifest(try session(root, "2026.10.28-1100"), state: .finalized)
            try manifest(try session(root, "2026.10.28-1200"), state: .empty)
            let named = try session(root, "2026.10.28-1300")
            try manifest(named, state: .finalized)
            try TranscriptStore(session: named).write(document(name: "Will"))
            let unnamed = try session(root, "2026.10.28-1400")
            try manifest(unnamed, state: .finalized)
            try TranscriptStore(session: unnamed).write(document(name: nil))
            let silentCall = try session(root, "2026.10.28-1500")
            try manifest(silentCall, state: .finalized)
            var unusedVoice = document(name: "Will")
            unusedVoice.voices["system:2"] = .init(
                source: "system", audio_file: "Source Audio/Remote.m4a", machine_label: "Them",
                name: nil, samples: []
            )
            try TranscriptStore(session: silentCall).write(unusedVoice)
            let older = try session(root, "2026.08.10-0959")
            try Data("# 2026.08.10-0959\n".utf8).write(to: older.appendingPathComponent("transcript.md"))
            _ = try session(root, "not-a-meeting")

            let states = Dictionary(uniqueKeysWithValues: Meeting.all(in: root).map { ($0.id, $0.state) })
            #expect(states == [
                "2026.10.28-0900": .recording,
                "2026.10.28-1000": .finishing,
                "2026.10.28-1100": .transcribing,
                "2026.10.28-1200": .empty,
                "2026.10.28-1300": .ready,
                "2026.10.28-1400": .needsNames,
                "2026.10.28-1500": .ready,
                "2026.08.10-0959": .ready,
            ])
            #expect(Meeting.all(in: root).first?.id == "2026.10.28-1500")
        }
    }

    @Test func findTakesAnIdOrLatestAndNothingOutsideTheRoot() throws {
        try withRoot { root in
            try manifest(try session(root, "2026.10.27-0900"), state: .finalized)
            try manifest(try session(root, "2026.10.28-0900"), state: .finalized)
            #expect(Meeting.find("latest", in: root)?.id == "2026.10.28-0900")
            #expect(Meeting.find("2026.10.27-0900", in: root)?.id == "2026.10.27-0900")
            #expect(Meeting.find("2026.10.29-0900", in: root) == nil)
            #expect(Meeting.find("../\(root.lastPathComponent)/2026.10.27-0900", in: root) == nil)
        }
    }

    @Test func sinceTakesAnAgeOrADate() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Meeting.cutoff("12h", now: now) == now.addingTimeInterval(-43_200))
        #expect(Meeting.cutoff("7d", now: now) == now.addingTimeInterval(-604_800))
        #expect(Meeting.cutoff("2w", now: now) == now.addingTimeInterval(-1_209_600))
        #expect(Meeting.cutoff("2026-10-01", now: now) != nil)
        #expect(Meeting.cutoff("0d", now: now) == nil)
        #expect(Meeting.cutoff("soon", now: now) == nil)
    }

    @Test func detailJSONCarriesVoicesAndRenderedTurns() throws {
        try withRoot { root in
            let folder = try session(root, "2026.10.28-1400")
            try manifest(folder, state: .finalized, seconds: 120)
            try TranscriptStore(session: folder).write(document(name: nil))
            let meeting = try #require(Meeting.find("2026.10.28-1400", in: root))
            let json = try #require(JSONSerialization.jsonObject(
                with: Data(try Meeting.json(meeting.detailJSON).utf8)
            ) as? [String: Any])

            #expect(json["state"] as? String == "needs-names")
            #expect(json["duration_seconds"] as? Int == 120)
            #expect(json["meeting_audio"] is NSNull)
            let voices = try #require(json["voices"] as? [[String: Any]])
            #expect(voices.map { $0["id"] as? String } == ["mic:1", "system:1"])
            #expect(voices[0]["name"] as? String == "Matt")
            #expect(voices[1]["name"] is NSNull)
            #expect(voices[1]["source"] as? String == "remote")
            let turns = try #require(json["turns"] as? [[String: Any]])
            #expect(turns.map { $0["speaker"] as? String } == ["Matt", "Voice 1"])
            #expect(turns[0]["paragraphs"] as? [String] == ["Hello there. [Voice 1: Yeah] Next point."])
            #expect(turns[1]["start_ms"] as? Int == 5_000)
        }
    }

    private let audio = SessionAudioFiles(microphone: "Source Audio/Local.m4a", system: "Source Audio/Remote.m4a")

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-meetings-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func session(_ root: URL, _ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func manifest(_ folder: URL, state: SessionAudioState?, seconds: Int? = nil) throws {
        _ = try SessionFiles.prepare(folder)
        try SessionMetadataStore.writeManifest(
            SessionManifest(
                started: "2026-10-28T03:00:00Z", durationSeconds: seconds, files: audio,
                audioState: state
            ),
            to: folder
        )
    }

    private func document(name: String?) -> TranscriptDocument {
        func voice(_ source: String, _ label: String, _ name: String?) -> TranscriptDocument.Voice {
            .init(
                source: source, audio_file: "Source Audio/\(source).m4a", machine_label: label,
                name: name, samples: []
            )
        }
        return TranscriptDocument(
            schema_version: 1, engine: "parakeet", model: "test", diarizer: "test",
            created_at: "2026-10-28T03:00:00Z",
            voices: ["mic:1": voice("mic", "Me", "Matt"), "system:1": voice("system", "Voice 1", name)],
            segments: [
                .init(speaker: "Matt", voice_id: "mic:1", start_ms: 0, end_ms: 2_000, text: "Hello there."),
                .init(speaker: name ?? "Voice 1", voice_id: "system:1", start_ms: 2_100, end_ms: 2_400, text: "Yeah."),
                .init(speaker: "Matt", voice_id: "mic:1", start_ms: 2_500, end_ms: 4_000, text: "Next point."),
                .init(speaker: name ?? "Voice 1", voice_id: "system:1", start_ms: 5_000, end_ms: 8_000, text: "My own view."),
            ]
        )
    }
}

@Suite struct AssistantSkillTests {
    @Test func installLinksBothSkillFoldersAndIsRepeatable() throws {
        try withHome { home, source in
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true
            )
            let linked = try AssistantSkill.install(from: source, home: home)
            #expect(linked.map(\.lastPathComponent) == ["quill", "quill"])
            #expect(try String(
                contentsOf: home.appendingPathComponent(".claude/skills/quill/SKILL.md"), encoding: .utf8
            ) == "skill")
            #expect(try AssistantSkill.install(from: source, home: home).count == 2)
        }
    }

    @Test func installSkipsClaudeWhenItIsNotThere() throws {
        try withHome { home, source in
            let linked = try AssistantSkill.install(from: source, home: home)
            #expect(linked.count == 1)
            let claude = FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
            #expect(!claude)
        }
    }

    @Test func installReplacesAnOldQuillLinkButNotSomeoneElsesFolder() throws {
        try withHome { home, source in
            let agents = home.appendingPathComponent(".agents/skills", isDirectory: true)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            let link = agents.appendingPathComponent("quill")
            try FileManager.default.createSymbolicLink(
                atPath: link.path, withDestinationPath: "/Old/Quill.app/Contents/Resources/skills/quill"
            )
            _ = try AssistantSkill.install(from: source, home: home)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == source.path)

            try FileManager.default.removeItem(at: link)
            try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
            #expect(throws: AssistantSkill.Occupied.self) {
                try AssistantSkill.install(from: source, home: home)
            }
            #expect(try AssistantSkill.remove(home: home).isEmpty)
            #expect(FileManager.default.fileExists(atPath: link.path))
        }
    }

    @Test func removeTakesOnlyQuillsLinks() throws {
        try withHome { home, source in
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true
            )
            _ = try AssistantSkill.install(from: source, home: home)
            #expect(try AssistantSkill.remove(home: home).count == 2)
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/quill").path))
        }
    }

    private func withHome(_ body: (URL, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-skill-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Quill.app/Contents/Resources/skills/quill", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try body(home, source)
    }
}
