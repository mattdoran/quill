import Foundation

enum SourceTrack: String, Codable, CaseIterable, Sendable {
    case microphone = "mic"
    case system
}

enum SessionAudioState: String, Codable, Sendable {
    case empty
    case finalized
}

struct SessionAudioFiles: Codable, Sendable {
    var microphone: String?
    var system: String?
    var cleanedMicrophone: String?
    var meeting: String?

    init(
        microphone: String? = nil,
        system: String? = nil,
        cleanedMicrophone: String? = nil,
        meeting: String? = nil
    ) {
        self.microphone = microphone
        self.system = system
        self.cleanedMicrophone = cleanedMicrophone
        self.meeting = meeting
    }

    subscript(track: SourceTrack) -> String? {
        get {
            switch track {
            case .microphone: microphone
            case .system: system
            }
        }
        set {
            switch track {
            case .microphone: microphone = newValue
            case .system: system = newValue
            }
        }
    }

    var hasSourceAudio: Bool { microphone != nil || system != nil }

    enum CodingKeys: String, CodingKey {
        case microphone = "mic"
        case system
        case cleanedMicrophone = "mic_cleaned"
        case meeting
    }
}

struct SessionTrackOffsets: Codable, Sendable {
    var microphone: Int
    var system: Int

    init(microphone: Int = 0, system: Int = 0) {
        self.microphone = microphone
        self.system = system
    }

    subscript(track: SourceTrack) -> Int {
        get {
            switch track {
            case .microphone: microphone
            case .system: system
            }
        }
        set {
            switch track {
            case .microphone: microphone = newValue
            case .system: system = newValue
            }
        }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        microphone = try values.decodeIfPresent(Int.self, forKey: .microphone) ?? 0
        system = try values.decodeIfPresent(Int.self, forKey: .system) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case microphone = "mic"
        case system
    }
}

struct SessionGap: Codable, Sendable {
    var at: Int
    var seconds: Int
}

struct SessionTrackMetadata: Codable, Sendable {
    var file: String
    var durationSeconds: Int
    var capturedSeconds: Int
    var gaps: [SessionGap]
    var gapsKnown: Bool?

    init(
        file: String,
        durationSeconds: Int,
        capturedSeconds: Int,
        gaps: [SessionGap] = [],
        gapsKnown: Bool? = nil
    ) {
        self.file = file
        self.durationSeconds = durationSeconds
        self.capturedSeconds = capturedSeconds
        self.gaps = gaps
        self.gapsKnown = gapsKnown
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        file = try values.decode(String.self, forKey: .file)
        durationSeconds = try values.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        capturedSeconds = try values.decodeIfPresent(Int.self, forKey: .capturedSeconds)
            ?? durationSeconds
        gaps = try values.decodeIfPresent([SessionGap].self, forKey: .gaps) ?? []
        gapsKnown = try values.decodeIfPresent(Bool.self, forKey: .gapsKnown)
    }

    enum CodingKeys: String, CodingKey {
        case file
        case durationSeconds = "duration_seconds"
        case capturedSeconds = "captured_seconds"
        case gaps
        case gapsKnown = "gaps_known"
    }
}

struct SessionTracks: Codable, Sendable {
    var microphone: SessionTrackMetadata?
    var system: SessionTrackMetadata?

    init(
        microphone: SessionTrackMetadata? = nil,
        system: SessionTrackMetadata? = nil
    ) {
        self.microphone = microphone
        self.system = system
    }

    subscript(track: SourceTrack) -> SessionTrackMetadata? {
        get {
            switch track {
            case .microphone: microphone
            case .system: system
            }
        }
        set {
            switch track {
            case .microphone: microphone = newValue
            case .system: system = newValue
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case microphone = "mic"
        case system
    }
}

struct CaptureJournal: Codable, Sendable {
    var started: String
    var files: SessionAudioFiles
    var startOffsets: SessionTrackOffsets

    init(started: String, files: SessionAudioFiles, startOffsets: SessionTrackOffsets) {
        self.started = started
        self.files = files
        self.startOffsets = startOffsets
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        started = try values.decode(String.self, forKey: .started)
        files = try values.decode(SessionAudioFiles.self, forKey: .files)
        startOffsets = try values.decodeIfPresent(
            SessionTrackOffsets.self,
            forKey: .startOffsets
        ) ?? SessionTrackOffsets()
    }

    enum CodingKeys: String, CodingKey {
        case started
        case files
        case startOffsets = "start_offset_ms"
    }
}

struct SessionManifest: Codable, Sendable {
    var started: String
    var ended: String?
    var durationSeconds: Int?
    var files: SessionAudioFiles
    var startOffsets: SessionTrackOffsets
    var tracks: SessionTracks
    var recoveredAfterInterruption: Bool?
    var audioState: SessionAudioState?

    init(
        started: String,
        ended: String? = nil,
        durationSeconds: Int? = nil,
        files: SessionAudioFiles,
        startOffsets: SessionTrackOffsets = SessionTrackOffsets(),
        tracks: SessionTracks = SessionTracks(),
        recoveredAfterInterruption: Bool? = nil,
        audioState: SessionAudioState? = nil
    ) {
        self.started = started
        self.ended = ended
        self.durationSeconds = durationSeconds
        self.files = files
        self.startOffsets = startOffsets
        self.tracks = tracks
        self.recoveredAfterInterruption = recoveredAfterInterruption
        self.audioState = audioState
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        started = try values.decodeIfPresent(String.self, forKey: .started) ?? ""
        ended = try values.decodeIfPresent(String.self, forKey: .ended)
        durationSeconds = try values.decodeIfPresent(Int.self, forKey: .durationSeconds)
        files = try values.decode(SessionAudioFiles.self, forKey: .files)
        startOffsets = try values.decodeIfPresent(
            SessionTrackOffsets.self,
            forKey: .startOffsets
        ) ?? SessionTrackOffsets()
        tracks = try values.decodeIfPresent(SessionTracks.self, forKey: .tracks)
            ?? SessionTracks()
        recoveredAfterInterruption = try values.decodeIfPresent(
            Bool.self,
            forKey: .recoveredAfterInterruption
        )
        audioState = try values.decodeIfPresent(SessionAudioState.self, forKey: .audioState)
    }

    enum CodingKeys: String, CodingKey {
        case started
        case ended
        case durationSeconds = "duration_seconds"
        case files
        case startOffsets = "start_offset_ms"
        case tracks
        case recoveredAfterInterruption = "recovered_after_interruption"
        case audioState = "audio_state"
    }
}

struct SessionSourceAudio: Sendable {
    let track: SourceTrack
    let file: String
    let offsetMilliseconds: Int
}

extension SessionManifest {
    var sourceAudio: [SessionSourceAudio] {
        SourceTrack.allCases.compactMap { track in
            files[track].map {
                SessionSourceAudio(
                    track: track,
                    file: $0,
                    offsetMilliseconds: startOffsets[track]
                )
            }
        }
    }
}

enum SessionMetadataStore {
    static func readManifest(_ session: URL) throws -> SessionManifest {
        try decode(SessionManifest.self, from: SessionFiles.metadata(session))
    }

    static func writeManifest(_ manifest: SessionManifest, to session: URL) throws {
        try encode(manifest, to: SessionFiles.metadata(session))
    }

    static func readJournal(_ session: URL) throws -> CaptureJournal {
        try decode(CaptureJournal.self, from: SessionFiles.captureJournal(session))
    }

    static func writeJournal(_ journal: CaptureJournal, to session: URL) throws {
        try encode(journal, to: SessionFiles.captureJournal(session))
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws
        -> Value
    {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private static func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
