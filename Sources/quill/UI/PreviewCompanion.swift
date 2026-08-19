import AppKit
import ArgumentParser

struct PreviewCompanion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview-companion",
        abstract: "Render deterministic meeting companion previews.",
        shouldDisplay: false
    )

    @Option(name: .long)
    var out: String

    func run() throws {
        try MainActor.assumeIsolated {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let zoom = CallApplication(
                id: "zoom",
                name: "Zoom Workplace Enterprise for Contoso Engineering"
            )
            let transcript = URL(fileURLWithPath: "/tmp/2026.08.19-1432/transcript.md")
            let states: [(String, MeetingCompanionState.Phase)] = [
                ("detected", .detected(application: zoom, token: UUID())),
                ("recording", .recording(
                    application: zoom,
                    elapsed: "1:12:34",
                    profile: .neither,
                    voiceControlVisible: false
                )),
                ("recording-voices", .recording(
                    application: zoom,
                    elapsed: "12:34",
                    profile: .onTheCall,
                    voiceControlVisible: true
                )),
                ("possible-end", .possibleEnd(
                    application: zoom,
                    elapsed: "12:34",
                    profile: .both,
                    voiceControlVisible: true
                )),
                ("saving", .finalizing),
                ("processing", .processing),
                ("ready", .ready(transcript: transcript)),
                ("failed", .failed(message: "The source recording is safe.")),
            ]

            for appearance in ["light", "dark"] {
                for (name, state) in states {
                    let view = MeetingCompanionView(
                        frame: NSRect(x: 0, y: 0, width: 468, height: 108)
                    )
                    view.appearance = NSAppearance(
                        named: appearance == "dark" ? .darkAqua : .aqua
                    )
                    view.render(state)
                    view.layoutSubtreeIfNeeded()
                    guard view.visibleControlsFitBounds() else {
                        throw PreviewError.controlsOutsideBounds("\(appearance)-\(name)")
                    }
                    guard
                        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { throw PreviewError.renderFailed(name) }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw PreviewError.renderFailed(name)
                    }
                    try png.write(
                        to: directory.appendingPathComponent("\(appearance)-\(name).png"),
                        options: .atomic
                    )
                }
            }

            let accessible = MeetingCompanionView(
                frame: NSRect(x: 0, y: 0, width: 468, height: 108)
            )
            accessible.appearance = NSAppearance(named: .aqua)
            accessible.applyAccessibilityOptions(
                reduceTransparency: true,
                increaseContrast: true
            )
            accessible.render(states[2].1)
            accessible.layoutSubtreeIfNeeded()
            guard
                accessible.visibleControlsFitBounds(),
                let bitmap = accessible.bitmapImageRepForCachingDisplay(in: accessible.bounds)
            else { throw PreviewError.controlsOutsideBounds("accessibility-recording") }
            accessible.cacheDisplay(in: accessible.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw PreviewError.renderFailed("accessibility-recording")
            }
            try png.write(
                to: directory.appendingPathComponent("accessibility-recording.png"),
                options: .atomic
            )
        }
    }

    enum PreviewError: Error {
        case renderFailed(String)
        case controlsOutsideBounds(String)
    }
}
