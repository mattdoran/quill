import Foundation

/// Conformers own the graph and the `TrackWriter`; they own no policy about
/// when to rebuild.
@MainActor
protocol Capture: AnyObject {
    var name: String { get }

    /// The only evidence capture is happening: a dead graph raises no error and
    /// delivers no final callback, it simply stops.
    var lastBufferAt: Date? { get }

    /// Raised when the system reports the graph gone.
    var onInvalidated: ((String) -> Void)? { get set }

    /// The file is untouched, so a rebuild resumes the track it was already
    /// writing.
    func attach() throws

    /// Stop and discard the graph, keeping the file.
    func detach()

    /// Finish the track, padding it out to `date`.
    func close(at date: Date)
}

/// Records when a capture graph last delivered, written from its own thread and
/// read on the main actor. Kept at the capture boundary rather than taken from
/// the file: a track that stops being written for any other reason must not
/// look like a dead device, since rebuilding the graph would not fix it.
final class LivenessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp: Date?

    var last: Date? {
        lock.lock()
        defer { lock.unlock() }
        return stamp
    }

    func mark() {
        lock.lock()
        stamp = Date()
        lock.unlock()
    }
}

/// Decides when a track's capture graph is rebuilt, and is the only thing that
/// does.
///
/// Invalidation and the stall check feed one state machine, so a route change
/// during a retry, or two signals for the same failure, cannot start
/// overlapping rebuilds.
@MainActor
final class CaptureSupervisor {
    private enum State: Equatable {
        case capturing
        case recovering(attempt: Int, nextTry: Date)
        case stopped
    }

    /// No buffers for this long means the graph is dead, whatever it claims.
    /// Long enough to clear a route change settling (~2s observed), short
    /// enough to lose seconds rather than minutes.
    private static let stallTimeout: TimeInterval = 5

    /// Below this, recovery was quick enough that the recording is still what
    /// the user expects, and warning on every headphone connection only teaches
    /// them to ignore it.
    private static let troubleThreshold: TimeInterval = 3

    /// A track still down this long has failed four rebuilds — backoff caps at
    /// 15s by the sixth attempt — so it is not coming back on its own. Route
    /// changes settle inside 5s and never reach this.
    static let deadThreshold: TimeInterval = 30

    /// A device that has gone for good must not be hammered for the rest of the
    /// meeting: each system-track rebuild creates and destroys an aggregate
    /// device.
    private static func backoff(attempt: Int) -> TimeInterval {
        min(0.5 * pow(2, Double(attempt - 1)), 15)
    }

    var name: String { capture.name }

    private var state: State = .stopped

    /// Whether capture is live right now, as opposed to the sticky record of
    /// what has gone wrong this session.
    var isHealthy: Bool {
        if case .recovering = state { return false }
        return true
    }

    private let capture: Capture
    private let log: SessionLog

    private let onTrouble: (String) -> Void

    /// Latest moment capture is known to have been alive, so the stall check
    /// has an anchor before the first buffer arrives.
    private var lastEvidence: Date
    private var outageStartedAt: Date?
    private var troubleReported = false
    private var deadReported = false

    /// How long this track has been continuously unhealthy, or nil when it is
    /// capturing. Read by the session to decide whether to say anything.
    var outage: TimeInterval? {
        guard let outageStartedAt, !isHealthy else { return nil }
        return Date().timeIntervalSince(outageStartedAt)
    }

    /// Set once a track has been reported dead, so a track that stays dead is
    /// not announced again.
    var hasReportedDead: Bool {
        get { deadReported }
        set { deadReported = newValue }
    }

    init(
        capture: Capture,
        log: SessionLog,
        startedAt: Date,
        onTrouble: @escaping (String) -> Void
    ) {
        self.capture = capture
        self.log = log
        self.lastEvidence = startedAt
        self.onTrouble = onTrouble
        capture.onInvalidated = { [weak self] reason in self?.invalidate(reason) }
    }

    /// Initial attach. Throws rather than entering recovery: a session that
    /// cannot capture at all should fail in front of the user, not quietly
    /// retry into an empty file.
    func start() throws {
        try capture.attach()
        state = .capturing
    }

    /// Safe on a supervisor that never started, so a session that failed
    /// half-way still finishes the track its sibling opened.
    func stop(at date: Date) {
        if state != .stopped { capture.detach() }
        state = .stopped
        capture.close(at: date)
    }

    func invalidate(_ reason: String) {
        guard state == .capturing else { return }
        log.warn("\(capture.name): \(reason)")
        // The outage runs from the last good buffer, not from noticing it.
        outageStartedAt = lastEvidence
        capture.detach()
        rebuild(attempt: 1, now: Date())
    }

    /// Called on a fixed tick.
    func tick() {
        let now = Date()
        switch state {
        case .stopped:
            return

        case .capturing:
            if let last = capture.lastBufferAt { lastEvidence = max(lastEvidence, last) }
            guard now.timeIntervalSince(lastEvidence) > Self.stallTimeout else { return }
            invalidate("no audio for \(Int(Self.stallTimeout))s")

        case .recovering(let attempt, let nextTry):
            // A rebuild that took hold shows buffers; that is the only proof
            // that counts, since attach() succeeding says nothing about
            // whether the device will deliver.
            if let last = capture.lastBufferAt, last > lastEvidence {
                resume(at: last)
                return
            }
            // A device that never comes back would otherwise retry in silence
            // for the rest of the meeting with nothing shown to the user.
            if let started = outageStartedAt,
                now.timeIntervalSince(started) > Self.troubleThreshold {
                report("\(capture.name) capture lost")
            }
            guard now >= nextTry else { return }
            capture.detach()
            rebuild(attempt: attempt + 1, now: now)
        }
    }

    // MARK: -

    private func resume(at last: Date) {
        let outage = last.timeIntervalSince(outageStartedAt ?? last)
        lastEvidence = last
        outageStartedAt = nil
        deadReported = false
        state = .capturing
        log.log(String(format: "%@: capture resumed after %.1fs", capture.name, outage))
        if outage > Self.troubleThreshold {
            report("\(capture.name) lost \(Int(outage.rounded()))s")
        }
        troubleReported = false
    }

    private func rebuild(attempt: Int, now: Date) {
        let delay = Self.backoff(attempt: attempt)
        do {
            try capture.attach()
            // A rebuilt graph gets at least the stall timeout to prove itself,
            // and longer as attempts mount.
            state = .recovering(attempt: attempt, nextTry: now + max(Self.stallTimeout, delay))
            log.log("\(capture.name): rebuilt on attempt \(attempt)")
        } catch {
            state = .recovering(attempt: attempt, nextTry: now + delay)
            log.warn(String(
                format: "%@: rebuild attempt %d failed (%@) — retrying in %.1fs",
                capture.name, attempt, "\(error)", delay
            ))
            report("\(capture.name) capture failed to restart")
        }
    }

    /// One report per outage: a track that stays broken is not re-announced on
    /// every retry.
    private func report(_ message: String) {
        guard !troubleReported else { return }
        troubleReported = true
        onTrouble(message)
    }
}
