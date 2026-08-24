import AVFoundation
import Foundation

/// Immutable mono PCM accepted by a source archive at a track-local position.
struct AcceptedFrame: Sendable {
    enum Origin: Sendable, Equatable {
        case captured
        case insertedSilence
    }

    let track: SourceTrack
    let startFrame: AVAudioFramePosition
    let sampleRate: Double
    let samples: [Float]
    let origin: Origin

    init?(
        copying buffer: AVAudioPCMBuffer,
        track: SourceTrack,
        startFrame: AVAudioFramePosition,
        origin: Origin
    ) {
        guard
            buffer.format.commonFormat == .pcmFormatFloat32,
            buffer.format.channelCount == 1,
            let source = buffer.floatChannelData?[0]
        else { return nil }

        self.track = track
        self.startFrame = startFrame
        self.sampleRate = buffer.format.sampleRate
        self.samples = Array(UnsafeBufferPointer(start: source, count: Int(buffer.frameLength)))
        self.origin = origin
    }
}

protocol AcceptedFrameSink: AnyObject, Sendable {
    var isAccepting: Bool { get }
    func offer(_ frame: AcceptedFrame)
}

/// Shares accepted frames without sharing consumer queues or overload policy.
final class AcceptedFrameFanout: AcceptedFrameSink, @unchecked Sendable {
    private let sinks: [any AcceptedFrameSink]

    init(_ sinks: [any AcceptedFrameSink]) {
        self.sinks = sinks
    }

    var isAccepting: Bool {
        sinks.contains { $0.isAccepting }
    }

    func offer(_ frame: AcceptedFrame) {
        for sink in sinks where sink.isAccepting { sink.offer(frame) }
    }
}

/// Keeps optional live consumers off the source archive queues.
///
/// Overload abandons the whole consumer stream because dropping an arbitrary
/// frame would corrupt stateful AEC. The retained source archives remain the
/// fallback.
final class AcceptedFrameMailbox: AcceptedFrameSink, @unchecked Sendable {
    private let maxQueuedFrames: Int
    private let consume: @Sendable (AcceptedFrame) -> Bool
    private let onOverflow: @Sendable () -> Void
    private let work = DispatchQueue(
        label: "com.mattdoran.quill.accepted-frame-mailbox",
        qos: .utility
    )
    private let lock = NSLock()
    private var queuedFrames = 0
    private var accepting = true

    init(
        maxQueuedFrames: Int,
        consume: @escaping @Sendable (AcceptedFrame) -> Bool,
        onOverflow: @escaping @Sendable () -> Void
    ) {
        precondition(maxQueuedFrames > 0)
        self.maxQueuedFrames = maxQueuedFrames
        self.consume = consume
        self.onOverflow = onOverflow
    }

    var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    func offer(_ frame: AcceptedFrame) {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return
        }
        guard queuedFrames + frame.samples.count <= maxQueuedFrames else {
            accepting = false
            lock.unlock()
            work.async { [onOverflow] in onOverflow() }
            return
        }
        queuedFrames += frame.samples.count
        lock.unlock()

        work.async { [self] in
            lock.lock()
            let shouldConsume = accepting
            lock.unlock()
            let keepAccepting = shouldConsume ? consume(frame) : false
            lock.lock()
            if !keepAccepting { accepting = false }
            queuedFrames -= frame.samples.count
            lock.unlock()
        }
    }

    func abandon() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    /// Waits until every accepted delivery has either run or been discarded.
    func finish() {
        work.sync {}
    }
}
