import AppKit
import ArgumentParser
import CoreAudio
import Foundation

struct CallApplication: Hashable, Sendable {
    let id: String
    let name: String
}

enum CallApplicationRegistry {
    private struct Entry {
        let application: CallApplication
        let bundleIDs: Set<String>
        let helperPrefixes: [String]
    }

    private static let entries = [
        Entry(
            application: CallApplication(id: "facetime", name: "FaceTime"),
            bundleIDs: ["com.apple.FaceTime", "com.apple.avconferenced"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "chrome", name: "Chrome"),
            bundleIDs: ["com.google.Chrome", "com.google.Chrome.beta"],
            helperPrefixes: ["com.google.Chrome.helper", "com.google.Chrome.beta.helper"]
        ),
        Entry(
            application: CallApplication(id: "firefox", name: "Firefox"),
            bundleIDs: ["org.mozilla.firefox"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "safari", name: "Safari"),
            bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "zoom", name: "Zoom"),
            bundleIDs: ["us.zoom.xos"],
            helperPrefixes: ["us.zoom.xos.helper"]
        ),
        Entry(
            application: CallApplication(id: "teams", name: "Microsoft Teams"),
            bundleIDs: ["com.microsoft.teams2"],
            helperPrefixes: ["com.microsoft.teams2.helper"]
        ),
        Entry(
            application: CallApplication(id: "slack", name: "Slack"),
            bundleIDs: ["com.tinyspeck.slackmacgap"],
            helperPrefixes: ["com.tinyspeck.slackmacgap.helper"]
        ),
        Entry(
            application: CallApplication(id: "webex", name: "Webex"),
            bundleIDs: ["com.cisco.webexmeetingsapp"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "whatsapp", name: "WhatsApp"),
            bundleIDs: ["net.whatsapp.WhatsApp"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "arc", name: "Arc"),
            bundleIDs: ["company.thebrowser.Browser"],
            helperPrefixes: ["company.thebrowser.Browser.helper"]
        ),
        Entry(
            application: CallApplication(id: "dia", name: "Dia"),
            bundleIDs: ["company.thebrowser.dia"],
            helperPrefixes: ["company.thebrowser.dia.helper"]
        ),
        Entry(
            application: CallApplication(id: "brave", name: "Brave"),
            bundleIDs: ["com.brave.Browser"],
            helperPrefixes: ["com.brave.Browser.helper"]
        ),
        Entry(
            application: CallApplication(id: "edge", name: "Microsoft Edge"),
            bundleIDs: ["com.microsoft.edgemac"],
            helperPrefixes: ["com.microsoft.edgemac.helper"]
        ),
        Entry(
            application: CallApplication(id: "opera", name: "Opera"),
            bundleIDs: ["com.operasoftware.Opera"],
            helperPrefixes: ["com.operasoftware.Opera.helper"]
        ),
        Entry(
            application: CallApplication(id: "vivaldi", name: "Vivaldi"),
            bundleIDs: ["com.vivaldi.Vivaldi"],
            helperPrefixes: ["com.vivaldi.Vivaldi.helper"]
        ),
        Entry(
            application: CallApplication(id: "helium", name: "Helium"),
            bundleIDs: ["net.imput.helium"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "comet", name: "Comet"),
            bundleIDs: ["ai.perplexity.comet"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "atlas", name: "Atlas"),
            bundleIDs: ["com.openai.atlas"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "zen", name: "Zen Browser"),
            bundleIDs: ["app.zen-browser.zen"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "discord", name: "Discord"),
            bundleIDs: ["com.hnc.Discord"],
            helperPrefixes: ["com.hnc.Discord.helper"]
        ),
        Entry(
            application: CallApplication(id: "aircall", name: "Aircall"),
            bundleIDs: ["io.aircall.phone"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "dialpad", name: "Dialpad"),
            bundleIDs: ["com.electron.dialpad"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "uberconference", name: "UberConference"),
            bundleIDs: ["com.electron.uberconference"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "gather", name: "Gather"),
            bundleIDs: ["com.gather.Gather", "com.gather.GatherV2"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "tuple", name: "Tuple"),
            bundleIDs: ["app.tuple.app"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "tencent-meeting", name: "Tencent Meeting"),
            bundleIDs: ["com.tencent.tencentmeeting"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "clickup", name: "ClickUp"),
            bundleIDs: ["com.clickup.desktop-app"],
            helperPrefixes: []
        ),
        Entry(
            application: CallApplication(id: "lark", name: "Lark"),
            bundleIDs: ["com.larksuite.larkApp"],
            helperPrefixes: []
        ),
    ]

    static func application(for bundleID: String) -> CallApplication? {
        entries.first { entry in
            entry.bundleIDs.contains(bundleID)
                || entry.helperPrefixes.contains { bundleID.hasPrefix($0) }
        }?.application
    }
}

struct ActiveInputProcess: Hashable, Sendable {
    let pid: pid_t
    let bundleID: String
    let deviceUIDs: [String]
    let callApplication: CallApplication?
}

enum ActiveInputProcessScanner {
    static func snapshot(includeUnknown: Bool) throws -> [ActiveInputProcess] {
        try processObjects().compactMap { objectID in
            guard let isRunningInput = scalar(
                objectID,
                selector: kAudioProcessPropertyIsRunningInput,
                as: UInt32.self
            ), isRunningInput != 0,
                let pid = scalar(
                    objectID,
                    selector: kAudioProcessPropertyPID,
                    as: pid_t.self
                )
            else { return nil }

            let bundleID = string(objectID, selector: kAudioProcessPropertyBundleID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? "unknown"
            let application = CallApplicationRegistry.application(for: bundleID)
            guard includeUnknown || application != nil else { return nil }

            let devices: [AudioObjectID] = array(
                objectID,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput,
                as: AudioObjectID.self
            ) ?? []
            let deviceUIDs = devices.compactMap {
                string($0, selector: kAudioDevicePropertyDeviceUID)
            }.sorted()

            return ActiveInputProcess(
                pid: pid,
                bundleID: bundleID,
                deviceUIDs: deviceUIDs,
                callApplication: application
            )
        }.sorted {
            ($0.callApplication?.name ?? $0.bundleID, $0.pid)
                < ($1.callApplication?.name ?? $1.bundleID, $1.pid)
        }
    }

    private static func processObjects() throws -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            throw CallAppMonitorError.coreAudio(
                operation: "read process-list size", status: sizeStatus
            )
        }

        var objects = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        let dataStatus = objects.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                system, &address, 0, nil, &size, bytes.baseAddress!
            )
        }
        guard dataStatus == noErr else {
            throw CallAppMonitorError.coreAudio(
                operation: "read process list", status: dataStatus
            )
        }
        return objects
    }

    private static func scalar<T>(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: T.Type
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        )
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, value
        ) == noErr else { return nil }
        return value.load(as: T.self)
    }

    private static func array<T>(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        as type: T.Type
    ) -> [T]? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            objectID, &address, 0, nil, &size
        ) == noErr else { return nil }

        guard size > 0 else { return [] }
        let value = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<T>.alignment
        )
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, value
        ) == noErr else { return nil }
        return Array(UnsafeBufferPointer(
            start: value.assumingMemoryBound(to: T.self),
            count: Int(size) / MemoryLayout<T>.size
        ))
    }

    private static func string(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, &value
        ) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

private enum CallAppMonitorError: LocalizedError {
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let operation, let status):
            return "Core Audio could not \(operation) (OSStatus \(status))"
        }
    }
}

struct InputSnapshotChangeDetector {
    private var previous: [ActiveInputProcess]?

    mutating func observe(_ snapshot: [ActiveInputProcess]) -> Bool {
        defer { previous = snapshot }
        return previous != snapshot
    }
}

struct CallLifecycleChange {
    let started: Set<CallApplication>
    let ended: Set<CallApplication>
}

struct CallLifecycleReducer {
    private let stabilityInterval: TimeInterval
    private var initialized = false
    private(set) var active: Set<CallApplication> = []
    private var pendingStarts: [CallApplication: Date] = [:]
    private var pendingEnds: [CallApplication: Date] = [:]

    init(stabilityInterval: TimeInterval = 2) {
        self.stabilityInterval = stabilityInterval
    }

    mutating func observe(
        _ observed: Set<CallApplication>, at now: Date
    ) -> CallLifecycleChange {
        guard initialized else {
            initialized = true
            active = observed
            return CallLifecycleChange(started: [], ended: [])
        }

        pendingStarts = pendingStarts.filter { observed.contains($0.key) }
        pendingEnds = pendingEnds.filter { !observed.contains($0.key) }

        for application in observed.subtracting(active) where pendingStarts[application] == nil {
            pendingStarts[application] = now
        }
        for application in active.subtracting(observed) where pendingEnds[application] == nil {
            pendingEnds[application] = now
        }

        let started = Set(pendingStarts.compactMap { application, since in
            now.timeIntervalSince(since) >= stabilityInterval ? application : nil
        })
        let ended = Set(pendingEnds.compactMap { application, since in
            now.timeIntervalSince(since) >= stabilityInterval ? application : nil
        })

        active.formUnion(started)
        active.subtract(ended)
        for application in started { pendingStarts.removeValue(forKey: application) }
        for application in ended { pendingEnds.removeValue(forKey: application) }

        return CallLifecycleChange(started: started, ended: ended)
    }
}

final class CallDetectionLog {
    static var defaultPath: URL {
        Config.home.appendingPathComponent("cache/call-detection.log")
    }

    let path: URL
    private let handle: FileHandle

    init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            FileHandle.standardError.write(Data(
                "warning: couldn't write call-detection log: \(error)\n".utf8
            ))
        }
    }
}

@MainActor
final class CallObservationController {
    private let includeUnknown: Bool
    private let printSnapshots: Bool
    private let log: CallDetectionLog?
    private let onStarted: (CallApplication) -> Void
    private let onEnded: (CallApplication) -> Void
    private var detector = InputSnapshotChangeDetector()
    private var lifecycle = CallLifecycleReducer()
    private var timer: Timer?

    var activeApplications: Set<CallApplication> { lifecycle.active }

    init(
        includeUnknown: Bool,
        printSnapshots: Bool,
        log: CallDetectionLog?,
        onStarted: @escaping (CallApplication) -> Void = { _ in },
        onEnded: @escaping (CallApplication) -> Void = { _ in }
    ) {
        self.includeUnknown = includeUnknown
        self.printSnapshots = printSnapshots
        self.log = log
        self.onStarted = onStarted
        self.onEnded = onEnded
    }

    func start() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        log?.write("\n\(timestamp) observation started\n")
        poll()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        scheduleInteractiveTimer(timer)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        do {
            let snapshot = try ActiveInputProcessScanner.snapshot(includeUnknown: includeUnknown)
            let applications = Set(snapshot.compactMap(\.callApplication))
            let lifecycleChange = lifecycle.observe(applications, at: Date())
            for application in lifecycleChange.started.sorted(by: { $0.name < $1.name }) {
                onStarted(application)
            }
            for application in lifecycleChange.ended.sorted(by: { $0.name < $1.name }) {
                onEnded(application)
            }

            guard detector.observe(snapshot) else { return }
            let text = Self.format(snapshot)
            if let log {
                log.write(text)
            }
            if printSnapshots { FileHandle.standardOutput.write(Data(text.utf8)) }
        } catch {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let text = "\(timestamp) scan failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(text.utf8))
            log?.write(text)
        }
    }

    private static func format(_ snapshot: [ActiveInputProcess]) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard !snapshot.isEmpty else {
            return "\(timestamp) no active call input\n"
        }

        var lines = ["\(timestamp) active input"]
        lines += snapshot.map { process in
            let name = process.callApplication?.name ?? "unknown"
            let devices = process.deviceUIDs.isEmpty
                ? "none"
                : process.deviceUIDs.joined(separator: ",")
            return "  \(name) bundle=\(process.bundleID) pid=\(process.pid) devices=\(devices)"
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct WatchCalls: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch-calls",
        abstract: "Print changes to applications using audio input."
    )

    @Flag(name: .long, help: "Include input processes not recognized as call applications.")
    var all = false

    func run() throws {
        MainActor.assumeIsolated { runMain() }
    }

    @MainActor
    private func runMain() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        FileHandle.standardError.write(Data(
            "watching call input - diagnostic only - ^C to quit\n".utf8
        ))
        let controller = CallObservationController(
            includeUnknown: all,
            printSnapshots: true,
            log: nil,
            onStarted: { application in
                FileHandle.standardOutput.write(Data(
                    "possible call started: \(application.name)\n".utf8
                ))
            },
            onEnded: { application in
                FileHandle.standardOutput.write(Data(
                    "possible call ended: \(application.name)\n".utf8
                ))
            }
        )
        controller.start()

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            controller.stop()
            FileHandle.standardError.write(Data("\nstopped watching call input\n".utf8))
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)
        app.run()

        withExtendedLifetime((controller, sigint)) {}
    }
}
