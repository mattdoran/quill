import Foundation

/// A main thread stuck inside a CoreAudio call leaves no line of its own in the
/// session log, however long it lasts.
struct MainThreadStall {
    static let threshold: TimeInterval = 2

    private var lastBeat: TimeInterval
    private var reported = false

    init(now: TimeInterval) { lastBeat = now }

    /// True once per stall, when it first crosses the threshold.
    mutating func check(now: TimeInterval) -> Bool {
        guard !reported, now - lastBeat > Self.threshold else { return false }
        reported = true
        return true
    }

    /// The stall's length, if this beat ended a reported one.
    mutating func beat(now: TimeInterval) -> TimeInterval? {
        defer {
            lastBeat = now
            reported = false
        }
        return reported ? now - lastBeat : nil
    }
}

final class MainThreadWatchdog: @unchecked Sendable {
    private let log: SessionLog
    private let lock = NSLock()
    private var stall: MainThreadStall
    private var timer: DispatchSourceTimer?

    /// `systemUptime` stops during sleep, which a wall clock would report as a stall.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(log: SessionLog) {
        self.log = log
        stall = MainThreadStall(now: Self.now)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.mattdoran.quill.main-watchdog", qos: .utility)
        )
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        lock.lock()
        let stalled = stall.check(now: Self.now)
        lock.unlock()
        if stalled {
            log.warn(String(
                format: "main thread blocked for over %.0fs", MainThreadStall.threshold
            ))
        }
        DispatchQueue.main.async { [weak self] in self?.beat() }
    }

    private func beat() {
        lock.lock()
        let ended = stall.beat(now: Self.now)
        lock.unlock()
        if let ended {
            log.warn(String(format: "main thread recovered after %.1fs", ended))
        }
    }
}
