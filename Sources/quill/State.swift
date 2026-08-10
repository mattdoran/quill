import Foundation

/// Settings quill writes for itself, at ~/.config/quill/state.json:
///
///     { "separate_voices": { "mic": false, "system": true } }
///
/// Kept apart from config.json because that file is hand-edited. Serializing a
/// whole document back out restyles it — escaping slashes, reordering keys —
/// and a menu checkbox has no business reformatting someone's JSON. This file
/// is quill's, so rewriting it costs nothing.
///
/// A value here overrides the matching config key; absent values fall through,
/// so config.json still supplies the defaults.
enum State {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/state.json")

    /// Whether the menu has set speaker detection for this track, or nil if it
    /// never has.
    static func speakerDetection(track: String) -> Bool? {
        let root = load()
        let group = (root["separate_voices"] ?? root["detect_speakers"]) as? [String: Any]
        return group?[track] as? Bool
    }

    static func setSpeakerDetection(track: String, enabled: Bool) {
        var root = load()
        var voices = (root["separate_voices"] ?? root["detect_speakers"]) as? [String: Any] ?? [:]
        voices[track] = enabled
        root["separate_voices"] = voices
        // Written under the new name, so the old one is dropped rather than
        // left to disagree with it.
        root["detect_speakers"] = nil
        write(root)
    }

    static func micVoiceProcessing() -> Bool? { load()["mic_voice_processing"] as? Bool }

    static func setMicVoiceProcessing(_ enabled: Bool) {
        set("mic_voice_processing", enabled)
    }

    static func transcriptionEnabled() -> Bool? { load()["transcription_enabled"] as? Bool }

    static func setTranscriptionEnabled(_ enabled: Bool) {
        set("transcription_enabled", enabled)
    }

    /// Where the user pointed quill with the folder picker. Stored as a plain
    /// path rather than a security-scoped bookmark: quill is not sandboxed, so
    /// choosing a folder through the open panel grants access that persists.
    static func recordingsDir() -> URL? {
        guard let path = load()["recordings_dir"] as? String, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func setRecordingsDir(_ url: URL) {
        var root = load()
        root["recordings_dir"] = url.path
        write(root)
    }

    private static func set(_ key: String, _ value: Bool) {
        var root = load()
        root[key] = value
        write(root)
    }

    /// Unreadable state is discarded rather than reported: it is quill's own
    /// file, the values in it are re-derivable from the menu, and config.json
    /// still holds the defaults it falls back to.
    private static func load() -> [String: Any] {
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    /// A failed write is reported but not thrown: the menu re-reads after
    /// setting, so a checkmark that didn't stick is visible immediately.
    private static func write(_ root: [String: Any]) {
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: path, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "warning: couldn't write \(path.path): \(error)\n".utf8
            ))
        }
    }
}
