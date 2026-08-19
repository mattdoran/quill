import Foundation

enum AudioRetention {
    static func clean(root: URL, now: Date = Date()) {
        guard Config.audioRetention() != .indefinitely else { return }
        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        sessions.forEach { clean(session: $0, now: now) }
    }

    static func clean(session: URL, now: Date = Date()) {
        let transcript = session.appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: transcript.path) else { return }

        switch Config.audioRetention() {
        case .indefinitely:
            return
        case .afterTranscription:
            break
        case .thirtyDays:
            guard let written = transcriptDate(transcript),
                  now.timeIntervalSince(written) >= 30 * 24 * 60 * 60
            else { return }
        }

        for name in [
            "mic.caf", "system.caf", "mic-cleaned.caf", "Source Audio",
        ] {
            let audio = session.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: audio.path) else { continue }
            do {
                try FileManager.default.removeItem(at: audio)
                log(session, "deleted \(name) under the audio retention policy")
            } catch {
                log(session, "couldn't delete \(name) under the audio retention policy: \(error)")
            }
        }
    }

    private static func transcriptDate(_ transcript: URL) -> Date? {
        if
            let data = try? Data(contentsOf: transcript),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let created = root["created_at"] as? String,
            let date = ISO8601DateFormatter().date(from: created)
        {
            return date
        }
        return try? transcript.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    private static func log(_ session: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = session.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
