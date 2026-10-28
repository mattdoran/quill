import ArgumentParser
import Foundation

struct CheckEchoDelay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "echo-delay",
        abstract: "Measure how far a session's microphone trails its call, from loudness."
    )

    @Argument(help: "A session folder.")
    var session: String

    func run() throws {
        let dir = URL(fileURLWithPath: (session as NSString).expandingTildeInPath, isDirectory: true)
        let manifest = try SessionMetadataStore.readManifest(dir)
        guard let call = manifest.files.system, let microphone = manifest.files.microphone else {
            throw ValidationError("the session needs both a microphone and a call track")
        }
        for (label, file) in [("microphone", microphone), ("cleaned microphone", manifest.files.cleanedMicrophone)] {
            guard let file else { continue }
            guard let estimate = try EchoDelay.estimate(
                microphone: dir.appendingPathComponent(file),
                microphoneOffsetMilliseconds: manifest.startOffsets[.microphone],
                call: dir.appendingPathComponent(call),
                callOffsetMilliseconds: manifest.startOffsets[.system]
            ) else {
                print("\(label): too short to measure")
                continue
            }
            print("\(label): \(estimate.description)")
        }
    }
}
