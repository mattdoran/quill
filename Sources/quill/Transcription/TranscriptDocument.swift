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
        static let unassigned = "Unassigned"

        var speaker: String
        var voice_id: String?
        let start_ms: Int
        let end_ms: Int
        let text: String

        var isUnassigned: Bool { voice_id == nil && speaker == Self.unassigned }
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
        var embedding_model: String? = nil
        var embedding: [Float]? = nil
        var remembered_profile_id: String? = nil

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

    /// Voice IDs grouped by person, in voice order. Voices on one track with
    /// the same name, ignoring case and spacing, are one person.
    var people: [[String]] {
        var groups: [[String]] = []
        var groupIndex: [String: Int] = [:]
        for id in voiceIDs {
            guard let voice = voices[id], let name = voice.name?.nilIfBlank else {
                groups.append([id])
                continue
            }
            let key = voice.source + "\n" + name.lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if let index = groupIndex[key] {
                groups[index].append(id)
            } else {
                groupIndex[key] = groups.count
                groups.append([id])
            }
        }
        return groups
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

    func rendered(title: String, durationMilliseconds: Int? = nil) -> String {
        let duration = durationMilliseconds ?? segments.map(\.end_ms).max() ?? 0
        let minutes = "\(max(1, Int((Double(duration) / 60_000).rounded()))) min"
        let speakers = speakersBySpeakingTime.joined(separator: ", ")
        return (["# \(title)", "", speakers.isEmpty ? minutes : "\(minutes) · \(speakers)", ""]
            + renderedTurns(longForm: duration >= 3_600_000)).joined(separator: "\n")
    }

    func renderedTurns(longForm: Bool) -> [String] {
        var lines: [String] = []
        for turn in turns {
            for (index, paragraph) in turn.paragraphs.enumerated() {
                let text = paragraph.map { part in
                    switch part {
                    case .speech(let text), .guess(let text): text
                    case .replies(let speaker, let text): "[\(speaker): \(text)]"
                    }
                }.joined(separator: " ")
                lines.append(index == 0
                    ? "**\(turn.speaker)** (\(Self.clock(turn.startMilliseconds, longForm: longForm))): \(text)"
                    : text)
                lines.append("")
            }
        }
        return lines
    }

    /// Exactly what Quill wrote before speaker turns. A `transcript.md` that
    /// still matches it was never edited, so it is safe to rewrite.
    func legacyMarkdown(title: String) -> String {
        var lines = ["# \(title)", ""]
        for segment in segments {
            lines.append("**[\(Self.clock(segment.start_ms))] \(segment.speaker):** \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private var speakersBySpeakingTime: [String] {
        var speech: [String: Int] = [:]
        var order: [String] = []
        for segment in segments where !segment.isUnassigned {
            if speech[segment.speaker] == nil { order.append(segment.speaker) }
            speech[segment.speaker, default: 0] += segment.end_ms - segment.start_ms
        }
        return order.enumerated()
            .sorted {
                (speech[$0.element, default: 0], -$0.offset)
                    > (speech[$1.element, default: 0], -$1.offset)
            }
            .map(\.element)
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

    static func clock(_ ms: Int, longForm: Bool = false) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 || longForm
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

    var isReviewable: Bool {
        guard let document = try? read() else { return false }
        return document.canEditVoices && !document.voiceIDs.isEmpty
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
            try Data(markdown(for: document).utf8).write(to: markdownURL, options: .atomic)
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

    var recordedMilliseconds: Int? {
        let seconds = (try? SessionMetadataStore.readManifest(session))?.durationSeconds
        return seconds.flatMap { $0 > 0 ? $0 * 1000 : nil }
    }

    func markdown(for document: TranscriptDocument) -> String {
        document.rendered(
            title: SessionName.dated(session),
            durationMilliseconds: recordedMilliseconds
        )
    }

    static func upgradeUneditedMarkdown(in root: URL) {
        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for session in sessions { TranscriptStore(session: session).upgradeUneditedMarkdown() }
    }

    func upgradeUneditedMarkdown() {
        guard
            let markdown = try? String(contentsOf: markdownURL, encoding: .utf8),
            markdown.hasPrefix("# \(session.lastPathComponent)\n"),
            let document = try? read(),
            document.schema_version == TranscriptDocument.currentSchemaVersion,
            markdown == document.legacyMarkdown(title: session.lastPathComponent)
        else { return }
        try? Data(self.markdown(for: document).utf8).write(to: markdownURL, options: .atomic)
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
