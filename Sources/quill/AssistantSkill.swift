import ArgumentParser
import Foundation

struct Skill: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Teach AI assistants on this Mac to use Quill's commands.",
        subcommands: [InstallSkill.self, RemoveSkill.self]
    )
}

struct InstallSkill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Link Quill's skill into ~/.agents/skills, and ~/.claude/skills when it exists."
    )

    func run() throws {
        guard let source = AssistantSkill.bundled else {
            FileHandle.standardError.write(Data(
                "run this from Quill.app: /Applications/Quill.app/Contents/MacOS/quill skill install\n".utf8
            ))
            throw ExitCode(1)
        }
        do {
            for link in try AssistantSkill.install(from: source, home: AssistantSkill.home) {
                print("linked \(link.path)")
            }
        } catch let error as AssistantSkill.Occupied {
            FileHandle.standardError.write(Data(
                "\(error.url.path) already exists and is not Quill's; remove it first\n".utf8
            ))
            throw ExitCode(1)
        }
    }
}

struct RemoveSkill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove the links that `quill skill install` made."
    )

    func run() throws {
        let removed = try AssistantSkill.remove(home: AssistantSkill.home)
        if removed.isEmpty { print("no Quill skill links found") }
        for link in removed { print("removed \(link.path)") }
    }
}

/// Links rather than copies, so the skill follows the installed app through
/// updates and always describes the commands that app has.
enum AssistantSkill {
    struct Occupied: Error { let url: URL }

    static var home: URL {
        ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static var bundled: URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let skill = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/skills/quill", isDirectory: true)
        let manifest = skill.appendingPathComponent("SKILL.md")
        return FileManager.default.fileExists(atPath: manifest.path) ? skill : nil
    }

    private static let claudeLink = "../../.agents/skills/quill"

    static func install(from source: URL, home: URL) throws -> [URL] {
        let fm = FileManager.default
        let agents = home.appendingPathComponent(".agents/skills", isDirectory: true)
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let primary = agents.appendingPathComponent("quill")
        try link(primary, to: source.path)
        var linked = [primary]
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        if fm.fileExists(atPath: claude.path) {
            let skills = claude.appendingPathComponent("skills", isDirectory: true)
            try fm.createDirectory(at: skills, withIntermediateDirectories: true)
            let secondary = skills.appendingPathComponent("quill")
            try link(secondary, to: claudeLink)
            linked.append(secondary)
        }
        return linked
    }

    static func isInstalled(home: URL) -> Bool {
        let link = home.appendingPathComponent(".agents/skills/quill").path
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: link)).map(isQuills) ?? false
    }

    static func remove(home: URL) throws -> [URL] {
        try [
            home.appendingPathComponent(".claude/skills/quill"),
            home.appendingPathComponent(".agents/skills/quill"),
        ].filter { url in
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path),
                  isQuills(destination)
            else { return false }
            try FileManager.default.removeItem(at: url)
            return true
        }
    }

    private static func link(_ url: URL, to destination: String) throws {
        let fm = FileManager.default
        if let existing = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            if existing == destination { return }
            guard isQuills(existing) else { throw Occupied(url: url) }
            try fm.removeItem(at: url)
        } else if fm.fileExists(atPath: url.path) {
            throw Occupied(url: url)
        }
        try fm.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    private static func isQuills(_ destination: String) -> Bool {
        destination == claudeLink || destination.hasSuffix(".app/Contents/Resources/skills/quill")
    }
}
