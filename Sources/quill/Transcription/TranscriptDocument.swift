import Foundation

struct VoiceLabelSequence {
    private var nextNumber = 1

    mutating func next() -> String {
        defer { nextNumber += 1 }
        return "Voice \(nextNumber)"
    }
}

struct TranscriptDocument: Codable, Sendable {
    static let currentSchemaVersion = 1

    struct Segment: Codable, Sendable {
        var speaker: String
        var voice_id: String?
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    struct Voice: Codable, Sendable {
        struct Sample: Codable, Sendable {
            let start_ms: Int
            let end_ms: Int
        }

        let source: String
        let audio_file: String
        let machine_label: String
        var name: String?
        let samples: [Sample]

        var displayName: String { name?.nilIfBlank ?? machine_label }
    }

    let schema_version: Int
    let engine: String
    let model: String
    let diarizer: String?
    let created_at: String
    var voices: [String: Voice]
    var segments: [Segment]

    var canEditVoices: Bool { schema_version == Self.currentSchemaVersion }

    var voiceIDs: [String] {
        guard canEditVoices else { return [] }
        return voices.keys.sorted(by: Self.voiceOrder)
    }

    var unidentifiedVoiceIDs: [String] {
        guard canEditVoices else { return [] }
        return voices
            .filter { $0.value.name?.nilIfBlank == nil }
            .map(\.key)
            .sorted(by: Self.voiceOrder)
    }

    func nameToCarry(source: String, separatedVoiceCount: Int) -> String? {
        guard separatedVoiceCount == 1 else { return nil }
        let sourceVoices = voices.values.filter { $0.source == source }
        guard sourceVoices.count == 1 else { return nil }
        return sourceVoices[0].name?.nilIfBlank
    }

    mutating func applyVoiceNames(_ names: [String: String]) throws {
        guard canEditVoices else { throw TranscriptStore.StoreError.unsupportedSchema }
        for (id, name) in names {
            guard var voice = voices[id] else { continue }
            voice.name = name.nilIfBlank
            voices[id] = voice
        }
        for index in segments.indices {
            guard
                let id = segments[index].voice_id,
                let voice = voices[id]
            else { continue }
            segments[index].speaker = voice.displayName
        }
    }

    func rendered(title: String) -> String {
        var lines = ["# \(title)", ""]
        for segment in segments {
            lines.append("**[\(Self.clock(segment.start_ms))] \(segment.speaker):** \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func voiceOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ":", maxSplits: 1)
        let right = rhs.split(separator: ":", maxSplits: 1)
        let sourceRank: [Substring: Int] = ["mic": 0, "system": 1]
        let leftRank = sourceRank[left.first ?? ""] ?? 2
        let rightRank = sourceRank[right.first ?? ""] ?? 2
        if leftRank != rightRank { return leftRank < rightRank }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

struct TranscriptStore {
    enum StoreError: Error, LocalizedError {
        case unsupportedSchema

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema:
                return "This transcript was created by an incompatible version of Quill."
            }
        }
    }

    let session: URL

    var jsonURL: URL { SessionFiles.transcriptJSON(session) }
    var markdownURL: URL { SessionFiles.transcriptMarkdown(session) }
    var separationSnapshotURL: URL {
        SessionFiles.transcriptBeforeSpeakerSeparation(session)
    }

    var canRestoreBeforeSpeakerSeparation: Bool {
        FileManager.default.fileExists(atPath: separationSnapshotURL.path)
    }

    func read() throws -> TranscriptDocument {
        try JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: jsonURL))
    }

    func readBeforeSpeakerSeparation() throws -> TranscriptDocument {
        try JSONDecoder().decode(
            TranscriptDocument.self,
            from: Data(contentsOf: separationSnapshotURL)
        )
    }

    func write(_ document: TranscriptDocument) throws {
        guard document.schema_version == TranscriptDocument.currentSchemaVersion else {
            throw StoreError.unsupportedSchema
        }
        _ = try SessionFiles.prepare(session)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let oldJSON = try? Data(contentsOf: jsonURL)
        let oldMarkdown = try? Data(contentsOf: markdownURL)
        do {
            try encoder.encode(document).write(to: jsonURL, options: .atomic)
            try Data(document.rendered(title: session.lastPathComponent).utf8)
                .write(to: markdownURL, options: .atomic)
        } catch {
            if let oldJSON {
                try? oldJSON.write(to: jsonURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: jsonURL)
            }
            if let oldMarkdown {
                try? oldMarkdown.write(to: markdownURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: markdownURL)
            }
            throw error
        }
    }

    func preserveBeforeSpeakerSeparation(_ document: TranscriptDocument) throws {
        guard document.schema_version == TranscriptDocument.currentSchemaVersion else {
            throw StoreError.unsupportedSchema
        }
        guard !canRestoreBeforeSpeakerSeparation else { return }
        _ = try SessionFiles.prepare(session)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: separationSnapshotURL, options: .atomic)
    }

    func restoreBeforeSpeakerSeparation() throws {
        let snapshot = try readBeforeSpeakerSeparation()
        try write(snapshot)
        try FileManager.default.removeItem(at: separationSnapshotURL)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
