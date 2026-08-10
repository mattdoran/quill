import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "detect_speakers": { "mic": { "enabled": false }, "system": { "enabled": true } },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Read-only: quill never writes this file. Settings it changes for itself go
/// to `State` instead, which overrides the matching keys here.
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    /// ~/Music, because Documents, Desktop and Downloads are TCC-protected and
    /// a menu-bar app has no window to hang the permission prompt on: the
    /// request is denied silently and directory listings come back empty with
    /// no error. Music is unprotected and is where Mac audio apps put generated
    /// recordings.
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/Quill", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    /// A folder picked from the menu wins, since choosing it through the open
    /// panel is also what grants access to a protected location.
    static func recordingsDir() -> URL? {
        if let chosen = State.recordingsDir() { return chosen }
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    /// The menu writes to state.json, which wins where it has an opinion.
    static func transcriptionEnabled() -> Bool {
        State.transcriptionEnabled() ?? (transcription()?["enabled"] as? Bool ?? true)
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    struct SpeakerDetection {
        let enabled: Bool
        /// What a track is called when it holds one person — which is what the
        /// mic holds whenever detection is off, and often enough when it is on.
        let soloLabel: String
        /// Base for the numbered labels once several people share a track:
        /// `room 1`, `room 2`.
        let sharedLabel: String
    }

    /// Whether a track's speakers are told apart, and what its segments are
    /// labelled. `track` is "mic" or "system".
    ///
    /// Both tracks can carry several people: the system track holds everyone on
    /// a group call, the mic track everyone in the room when the meeting is in
    /// person. They are configured separately because the useful setting
    /// differs by meeting.
    ///
    /// Labels follow how many people a track turns out to hold, not whether
    /// detection was switched on. One voice on the mic is `me` whether or not a
    /// model confirmed it; several make it the room, and `me 1` / `me 2` would
    /// be nonsense. The system track is `them` at both counts: one remote voice
    /// or four, it is still the other side.
    ///
    /// Off by default — it downloads a second model on first use, and a 1:1
    /// call gains nothing from it.
    static func speakerDetection(track: String) -> SpeakerDetection {
        let settings = (load()?["detect_speakers"] as? [String: Any])?[track] as? [String: Any]
        let configured = settings?["enabled"] as? Bool ?? false
        let isMic = track == "mic"
        return SpeakerDetection(
            // The menu writes to state.json, which wins where it has an opinion.
            enabled: State.speakerDetection(track: track) ?? configured,
            soloLabel: isMic ? "me" : "them",
            sharedLabel: isMic ? "room" : "them"
        )
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    /// Off unless asked for. The voice unit ducks system audio *into the
    /// recording*, not only out of the speakers: measured at 7.8 dB quieter on
    /// the system track, which carries the people being recorded. Losing that
    /// costs more than the echo it removes from the mic track.
    ///
    /// Re-read on every mic attach, so a mid-meeting change settles on the
    /// right answer rather than the one that was true at the start.
    static func micVoiceProcessing() -> Bool {
        State.micVoiceProcessing() ?? (load()?["mic_voice_processing"] as? Bool ?? false)
    }

    /// Flip diarization for one track and persist it, so a menu toggle survives
    /// a restart.
    ///
    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
