import AppKit

@MainActor
final class ApplicationPresenceController {
    struct State: Equatable {
        let hasUserInterface: Bool
        let isBlocking: Bool
    }

    private struct Entry {
        weak var owner: AnyObject?
        let isBlocking: Bool
    }

    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private let activateApplication: () -> Void
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    var onStateChanged: ((State) -> Void)? {
        didSet { onStateChanged?(state) }
    }

    var state: State {
        State(
            hasUserInterface: !entries.isEmpty,
            isBlocking: entries.values.contains(where: \.isBlocking)
        )
    }

    init(
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = {
            _ = NSApp.setActivationPolicy($0)
        },
        activateApplication: @escaping () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.setActivationPolicy = setActivationPolicy
        self.activateApplication = activateApplication
    }

    func begin(_ owner: AnyObject, blocking: Bool = false) {
        removeReleasedOwners()
        entries[ObjectIdentifier(owner)] = Entry(owner: owner, isBlocking: blocking)
        setActivationPolicy(.regular)
        activateApplication()
        publishState()
    }

    func end(_ owner: AnyObject) {
        end(ObjectIdentifier(owner))
    }

    private func end(_ identifier: ObjectIdentifier) {
        entries.removeValue(forKey: identifier)
        if let observer = closeObservers.removeValue(forKey: identifier) {
            NotificationCenter.default.removeObserver(observer)
        }
        updateActivationPolicy()
    }

    func present(_ window: NSWindow, blocking: Bool = false) {
        track(window, blocking: blocking)
        raise(window)
    }

    func prepare(_ window: NSWindow, blocking: Bool = false) {
        track(window, blocking: blocking)
    }

    func raise(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        let blocking = entries[identifier]?.isBlocking ?? false
        if closeObservers[identifier] == nil {
            track(window, blocking: blocking)
        } else {
            begin(window, blocking: blocking)
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func raiseFrontmostWindow() {
        removeReleasedOwners()
        setActivationPolicy(.regular)
        activateApplication()
        let trackedWindows = entries.values.compactMap { $0.owner as? NSWindow }
        let window = trackedWindows.first(where: \.isKeyWindow)
            ?? trackedWindows.first(where: \.isVisible)
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.level == .normal })
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let window = alert.window
        begin(window, blocking: true)
        defer { end(window) }
        return alert.runModal()
    }

    func showAbout(options: [NSApplication.AboutPanelOptionKey: Any]) {
        setActivationPolicy(.regular)
        activateApplication()
        NSApp.orderFrontStandardAboutPanel(options: options)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let window = NSApp.keyWindow {
                self.track(window, blocking: false)
                self.raise(window)
            } else {
                self.updateActivationPolicy()
            }
        }
    }

    private func track(_ window: NSWindow, blocking: Bool) {
        let identifier = ObjectIdentifier(window)
        begin(window, blocking: blocking)
        guard closeObservers[identifier] == nil else { return }
        closeObservers[identifier] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.end(identifier)
            }
        }
    }

    private func removeReleasedOwners() {
        let released = entries.compactMap { identifier, entry in
            entry.owner == nil ? identifier : nil
        }
        for identifier in released {
            entries.removeValue(forKey: identifier)
            if let observer = closeObservers.removeValue(forKey: identifier) {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private func updateActivationPolicy() {
        removeReleasedOwners()
        setActivationPolicy(entries.isEmpty ? .accessory : .regular)
        publishState()
    }

    private func publishState() {
        onStateChanged?(state)
    }
}
