import AppKit

/// Swift Testing's main run loop ends the process with status 0 when it is
/// stopped, and AppKit stops it whenever WindowServer sends this process an
/// event. Start AppKit through here in every test that touches it, or the run
/// can end mid-suite looking like a pass.
@MainActor
enum AppKitTestHost {
    private static var observer: CFRunLoopObserver?

    @discardableResult
    static func start() -> NSApplication {
        let application = NSApplication.shared
        guard observer == nil else { return application }
        var nestedRuns = 0
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity([.entry, .exit]).rawValue, true, CFIndex.max
        ) { _, activity in
            if activity == .entry {
                nestedRuns += 1
            } else if nestedRuns > 0 {
                nestedRuns -= 1
            } else {
                while true { CFRunLoopRun() }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        return application
    }
}
