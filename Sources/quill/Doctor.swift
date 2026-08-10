import AVFoundation
import FluidAudio
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run(recordingsRoot: URL) -> [Check] {
        [
            checkMicrophone(),
            checkSystemAudio(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
            checkSpeakerDetection(),
        ]
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for quill (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, so all we can do is describe the flow.
    static func checkSystemAudio() -> Check {
        Check(
            name: "system audio",
            status: .warn("state unknowable until first use — will prompt on first recording"),
            remediation: "if recordings come out silent: System Settings → Privacy & Security → Screen & System Audio Recording"
        )
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        // Writable is not enough. Under TCC, Documents, Desktop and Downloads
        // stay writable while listing them returns nothing, with no error, so a
        // check that only writes would pass while the app cannot find its own
        // recordings.
        guard (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) != nil else {
            // A warning, not a failure: startup checks are fatal, and a
            // folder quill cannot read is a reason to say so in the menu, not
            // a reason to refuse to run. Starting a recording refuses on its
            // own, which is where it actually matters.
            return Check(
                name: "recordings folder",
                status: .warn("can't list \(root.path) — macOS is blocking access"),
                remediation: "pick the folder again with Change Recordings Folder… "
                    + "in the menu, which is what grants access"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model after an important meeting: report
    /// whether the parakeet models are already in FluidAudio's cache.
    static func checkTranscription() -> Check {
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        let cache = AsrModels.defaultCacheDirectory(for: .v2)
        if AsrModels.modelsExist(at: cache, version: .v2) {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        return Check(
            name: "transcription",
            status: .warn("parakeet models not downloaded (~600 MB)"),
            remediation: "downloads automatically after Quill launches on an unmetered connection"
        )
    }

    /// Report the labels a transcript will actually carry, so a config can be
    /// checked without recording a meeting and reading the result. Silent when
    /// both tracks are off — there is nothing to get wrong.
    static func checkSpeakerDetection() -> Check {
        let mic = Config.speakerDetection(track: "mic")
        let system = Config.speakerDetection(track: "system")
        guard mic.enabled || system.enabled else {
            return Check(name: "speaker detection", status: .ok, remediation: nil)
        }

        func describe(_ settings: Config.SpeakerDetection) -> String {
            guard settings.enabled else { return settings.soloLabel }
            let numbered = "\(settings.sharedLabel) 1, \(settings.sharedLabel) 2, …"
            // Only worth spelling out where the two labels differ; on the
            // system track both are "them" and the aside would say nothing.
            guard settings.soloLabel != settings.sharedLabel else { return numbered }
            return "\(numbered) (\(settings.soloLabel) if alone)"
        }

        return Check(
            name: "speaker detection",
            status: .warn("mic → \(describe(mic)) · system → \(describe(system))"),
            remediation: "at most 4 speakers per track — the model has four output slots"
        )
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
