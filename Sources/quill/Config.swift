import Foundation

/// User configuration at ~/Library/Application Support/Quill/config.json.
enum Config {
    static var home: URL {
        if let override = ProcessInfo.processInfo.environment["QUILL_HOME"], !override.isEmpty {
            return URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quill", isDirectory: true)
    }

    static var path: URL { home.appendingPathComponent("config.json") }

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/Quill", isDirectory: true)

    static func recordingsDir() -> URL? {
        guard let dir = load()["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func setRecordingsDir(_ url: URL) {
        set("recordings_dir", url.path)
    }

    static func companionPlacement() -> MeetingCompanionPlacement? {
        guard
            let value = load()["companion_placement"] as? [String: Any],
            let rightEdge = (value["right_edge"] as? NSNumber)?.doubleValue,
            let centerY = (value["center_y"] as? NSNumber)?.doubleValue,
            rightEdge.isFinite,
            centerY.isFinite
        else { return nil }
        return MeetingCompanionPlacement(rightEdge: rightEdge, centerY: centerY)
    }

    static func setCompanionPlacement(_ placement: MeetingCompanionPlacement) {
        set("companion_placement", [
            "center_y": placement.centerY,
            "right_edge": placement.rightEdge,
        ])
    }

    static func onStop() -> String? {
        guard let command = load()["on_stop"] as? String, !command.isEmpty else { return nil }
        return command
    }

    static func transcriptionEngine() -> String {
        transcription()["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any] {
        load()["transcription"] as? [String: Any] ?? [:]
    }

    enum AudioRetention: String, CaseIterable {
        case indefinitely
        case thirtyDays = "30_days"
        case afterTranscription = "after_transcription"

        var title: String {
            switch self {
            case .indefinitely: "Keep indefinitely"
            case .thirtyDays: "Keep for 30 days"
            case .afterTranscription: "Delete after transcription"
            }
        }
    }

    static func audioRetention() -> AudioRetention {
        guard
            let value = load()["audio_retention"] as? String,
            let retention = AudioRetention(rawValue: value)
        else { return .indefinitely }
        return retention
    }

    static func setAudioRetention(_ retention: AudioRetention) {
        set("audio_retention", retention.rawValue)
    }

    static func loginItemInitialized() -> Bool {
        load()["launch_at_login_initialized"] as? Bool ?? false
    }

    static func setLoginItemInitialized() {
        set("launch_at_login_initialized", true)
    }

    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }

    private static func set(_ key: String, _ value: Any) {
        var root = load()
        root[key] = value
        writeReporting(root)
    }

    private static func load() -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            warn("\(path.path) is not valid JSON - ignoring it")
            return [:]
        }
        return json
    }

    private static func writeReporting(_ root: [String: Any]) {
        do {
            try write(root)
        } catch {
            warn("couldn't write \(path.path): \(error)")
        }
    }

    private static func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: path, options: .atomic)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }
}
