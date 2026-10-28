import AppKit
import ArgumentParser
import Foundation

struct MeetingStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show where meetings are saved, and what is recording, transcribing or waiting to have named.",
        discussion: "Waiting for names covers meetings from the last 7 days."
    )

    @Flag(name: .long, help: "Print JSON.")
    var json = false

    func run() throws {
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.mattdoran.quill")
            .contains { $0.processIdentifier != getpid() }
        let root = Config.resolveRoot(cliOverride: nil)
        let meetings = Meeting.all(in: root)
        let week = Date().addingTimeInterval(-7 * 86_400)
        func inState(_ state: Meeting.State) -> [Meeting] {
            meetings.filter { $0.state == state }
        }
        let groups: [(key: String, label: String, meetings: [Meeting])] = [
            ("recording", running ? "Recording" : "Interrupted, recovered when Quill starts",
             inState(.recording)),
            ("finishing", "Finishing audio", inState(.finishing)),
            ("transcribing", "Transcribing", inState(.transcribing)),
            ("needs_names", "Waiting for names",
             inState(.needsNames).filter { ($0.started ?? .distantPast) >= week }),
        ]

        if json {
            var output: [String: Any] = ["running": running, "recordings": root.path]
            for group in groups { output[group.key] = group.meetings.map(\.summaryJSON) }
            print(try Meeting.json(output))
            return
        }
        print(running ? "Quill is running." : "Quill is not running.")
        print("Meetings are saved in \(root.path).")
        let busy = groups.filter { !$0.meetings.isEmpty }
        if busy.isEmpty { print("Nothing recording, transcribing or waiting for names.") }
        for group in busy {
            print("\(group.label): " + group.meetings.map { "\($0.title) (\($0.id))" }
                .joined(separator: ", "))
        }
    }
}

struct ListMeetings: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List meetings, newest first.",
        discussion: """
        States: recording, finishing, transcribing, needs-names (someone who \
        speaks has no name yet), ready, empty.
        """
    )

    @Option(name: .long, help: "Only meetings since then: 7d, 12h, 2w, or a date such as 2026-10-01.")
    var since: String?

    @Flag(name: .long, help: "Print JSON.")
    var json = false

    func validate() throws {
        if let since, Meeting.cutoff(since, now: Date()) == nil {
            throw ValidationError("--since takes 7d, 12h, 2w, or a date such as 2026-10-01")
        }
    }

    func run() throws {
        let cutoff = since.flatMap { Meeting.cutoff($0, now: Date()) } ?? .distantPast
        let meetings = Meeting.all(in: Config.resolveRoot(cliOverride: nil))
            .filter { ($0.started ?? .distantPast) >= cutoff }
        if json {
            print(try Meeting.json(meetings.map(\.summaryJSON)))
            return
        }
        guard !meetings.isEmpty else {
            print("No meetings.")
            return
        }
        let rows = meetings.map { meeting in
            [
                meeting.id,
                meeting.title,
                meeting.durationSeconds.map { TranscriptDocument.minutes($0 * 1000) } ?? "",
                meeting.state.rawValue,
                meeting.people.joined(separator: ", "),
            ]
        }
        let widths = (0..<4).map { column in rows.map { $0[column].count }.max() ?? 0 }
        for row in rows {
            let padded = (0..<4).map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
            print((padded + [row[4]]).joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
    }
}

struct ShowMeeting: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print a meeting's transcript.",
        discussion: """
        Prints transcript.md. With --json, prints the meeting with its voices and \
        its turns, each with start_ms from the start of the recording. Exits 1 \
        for an unknown meeting and 2 when the meeting has no transcript yet.
        """
    )

    @Argument(help: "A meeting id from `quill list`, or `latest`.")
    var meeting: String

    @Flag(name: .long, help: "Print JSON.")
    var json = false

    func run() throws {
        guard let found = Meeting.find(meeting, in: Config.resolveRoot(cliOverride: nil)) else {
            FileHandle.standardError.write(Data("no meeting \(meeting); see quill list\n".utf8))
            throw ExitCode(1)
        }
        if json {
            print(try Meeting.json(found.detailJSON))
            return
        }
        if let url = found.markdownURL {
            print(try String(contentsOf: url, encoding: .utf8), terminator: "")
        } else if let document = found.document {
            print(TranscriptStore(session: found.folder).markdown(for: document), terminator: "")
        } else {
            FileHandle.standardError.write(Data(
                "\(found.title) has no transcript yet (\(found.state.rawValue))\n".utf8
            ))
            throw ExitCode(2)
        }
    }
}
