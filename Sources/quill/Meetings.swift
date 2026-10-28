import Foundation

/// A session in the recordings folder as the command line reports it. It is
/// read from the files alone, so the reading commands work whether or not
/// Quill is running.
struct Meeting {
    enum State: String {
        case recording
        case finishing
        case transcribing
        case needsNames = "needs-names"
        case ready
        case empty
    }

    let folder: URL
    let state: State
    let started: Date?
    let durationSeconds: Int?
    let document: TranscriptDocument?
    let manifest: SessionManifest?

    var id: String { folder.lastPathComponent }
    var title: String { SessionName.dated(folder) }
    var people: [String] { document?.speakersBySpeakingTime ?? [] }

    var markdownURL: URL? {
        let url = SessionFiles.transcriptMarkdown(folder)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var meetingAudioURL: URL? {
        guard let name = manifest?.files.meeting else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    init?(folder: URL) {
        let fm = FileManager.default
        let manifest = try? SessionMetadataStore.readManifest(folder)
        let document = try? TranscriptStore(session: folder).read()
        let state: State
        if fm.fileExists(atPath: SessionFiles.captureJournal(folder).path) {
            state = .recording
        } else if let document {
            state = document.unidentifiedVoiceIDs.isEmpty ? .ready : .needsNames
        } else if let manifest {
            if manifest.audioState == .empty || !manifest.files.hasSourceAudio {
                state = .empty
            } else if manifest.audioState != .finalized {
                state = .finishing
            } else {
                state = .transcribing
            }
        } else if fm.fileExists(atPath: SessionFiles.transcriptMarkdown(folder).path) {
            // Sessions from before `.quill` keep only their Markdown readable.
            state = .ready
        } else {
            return nil
        }
        self.folder = folder
        self.state = state
        self.manifest = manifest
        self.document = document
        started = manifest.flatMap { try? Date($0.started, strategy: .iso8601) }
            ?? SessionName.recorded(folder)
        durationSeconds = manifest?.durationSeconds.flatMap { $0 > 0 ? $0 : nil }
            ?? document.map { $0.spokenMilliseconds / 1000 }
    }

    /// Newest first. Folder names sort by recording time.
    static func all(in root: URL) -> [Meeting] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap(Meeting.init(folder:))
    }

    static func find(_ query: String, in root: URL) -> Meeting? {
        if query == "latest" { return all(in: root).first }
        guard !query.contains("/") else { return nil }
        return Meeting(folder: root.appendingPathComponent(query, isDirectory: true))
    }

    /// `7d`, `12h`, `2w`, or a local date such as `2026-10-01`.
    static func cutoff(_ spec: String, now: Date) -> Date? {
        let units: [Character: TimeInterval] = ["h": 3_600, "d": 86_400, "w": 604_800]
        if let unit = spec.last.flatMap({ units[$0] }), let count = Int(spec.dropLast()), count > 0 {
            return now.addingTimeInterval(-Double(count) * unit)
        }
        return day.date(from: spec)
    }

    var summaryJSON: [String: Any] {
        [
            "id": id,
            "title": title,
            "started": started.map { $0.ISO8601Format() } ?? NSNull(),
            "duration_seconds": durationSeconds ?? NSNull(),
            "state": state.rawValue,
            "people": people,
            "transcript": markdownURL?.path ?? NSNull(),
        ]
    }

    var detailJSON: [String: Any] {
        var json = summaryJSON
        json["meeting_audio"] = meetingAudioURL?.path ?? NSNull()
        let unnamed = Set(document?.unidentifiedVoiceIDs ?? [])
        json["voices"] = (document?.voiceIDs ?? []).compactMap { id -> [String: Any]? in
            guard let voice = document?.voices[id] else { return nil }
            return [
                "id": id,
                "name": unnamed.contains(id) ? NSNull() : voice.displayName,
                "label": voice.machine_label,
                "source": voice.source == "mic" ? "local" : "remote",
            ]
        }
        json["turns"] = (document?.turns ?? []).map { turn -> [String: Any] in
            [
                "speaker": turn.speaker,
                "voice_id": turn.voiceID ?? NSNull(),
                "start_ms": turn.startMilliseconds,
                "paragraphs": turn.paragraphTexts,
            ]
        }
        return json
    }

    static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
