import Foundation

/// Decides, at launch, what a leftover capture journal means.
enum CaptureResume {
    /// A restart comes back in well under this, and a meeting that lost longer
    /// is usually over. A wrong resume costs a stop; a wrong finalize costs the
    /// rest of the meeting.
    static let recentDeath: TimeInterval = 5 * 60
    static let resumeLimit = 3
    static let resumeWindow: TimeInterval = 10 * 60

    enum Decision: Equatable {
        case resume
        case finalize
        /// Capture itself may be what is killing Quill.
        case stopResuming
    }

    struct Interrupted: Sendable {
        let session: URL
        let journal: CaptureJournal
        let lastAudio: Date
    }

    static func decision(
        journal: CaptureJournal,
        lastAudio: Date,
        now: Date
    ) -> Decision {
        guard now.timeIntervalSince(lastAudio) < recentDeath else { return .finalize }
        let recentResumes = journal.resumedSegments.filter {
            let started = Date(timeIntervalSince1970: Double($0.startedAtMilliseconds) / 1000)
            return now.timeIntervalSince(started) < resumeWindow
        }
        return recentResumes.count >= resumeLimit ? .stopResuming : .resume
    }

    /// Newest last. A journal with `ended` was stopped cleanly and is only
    /// waiting to be finalized.
    static func interrupted(in root: URL) -> [Interrupted] {
        let sessions = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return sessions
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { session in
                guard
                    let journal = try? SessionMetadataStore.readJournal(session),
                    journal.ended == nil
                else { return nil }
                return Interrupted(
                    session: session,
                    journal: journal,
                    lastAudio: lastAudio(in: session, journal: journal)
                )
            }
    }

    /// The archives are written continuously, so their modification time is the
    /// last moment Quill was capturing.
    static func lastAudio(in session: URL, journal: CaptureJournal) -> Date {
        let segments = [journal.files] + journal.resumedSegments.map(\.files)
        let paths = segments.flatMap { [$0.microphone, $0.system] }.compactMap { $0 }
        let candidates = paths.map { session.appendingPathComponent($0) }
            + [SessionFiles.captureJournal(session)]
        let dates = candidates.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        }
        return dates.max() ?? .distantPast
    }

    /// `8 seconds`, `3 minutes`, for a notification or the menu.
    static func spoken(_ interval: TimeInterval) -> String {
        let seconds = max(1, Int(interval.rounded()))
        if seconds < 60 { return seconds == 1 ? "1 second" : "\(seconds) seconds" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60, rest = minutes % 60
        let whole = hours == 1 ? "1 hour" : "\(hours) hours"
        return rest == 0 ? whole : "\(whole) \(rest == 1 ? "1 minute" : "\(rest) minutes")"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
