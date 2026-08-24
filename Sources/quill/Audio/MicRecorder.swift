import AVFoundation
import Foundation

/// Captures the default input device into a `TrackWriter`, encoding AAC mono.
/// Buffers stream straight to disk — nothing is held in memory, so session
/// length is unbounded.
///
/// Rebuild policy lives in `CaptureSupervisor`; this owns only the graph.
@MainActor
final class MicRecorder: Capture {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)
        case notPrepared

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "unusable mic format \(f)"
            case .notPrepared: return "mic capture attached before its file was created"
            }
        }
    }

    /// Fixed for the session. An AAC file's rate is set at creation and the
    /// capture device's is not — AirPods arrive at 24 kHz, the built-in mic at
    /// 48 — so the writer resamples every route to this.
    static let trackSampleRate: Double = 48000

    private static let fileFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: trackSampleRate,
        channels: 1, interleaved: false
    )!

    let name = "mic"
    var lastBufferAt: Date? { liveness.last }
    var firstBufferAt: Date? { writer?.firstBufferAt }
    var gaps: [TrackWriter.Gap] { writer?.gaps ?? [] }
    var duration: TimeInterval { writer?.duration ?? 0 }
    var lastAudibleAt: Date? { writer?.lastAudibleAt }
    var hasEverBeenAudible: Bool { writer?.hasEverBeenAudible ?? false }
    var archiveFailure: String? { writer?.writeFailure }

    var onInvalidated: ((String) -> Void)?
    var onArchiveFailed: ((String) -> Void)?

    private var engine = AVAudioEngine()
    private let liveness = LivenessClock()
    private var writer: TrackWriter?
    private var log: SessionLog?
    private var configurationObserver: NSObjectProtocol?

    /// Use a .caf extension: CAF needs no finalization pass, so a crash loses
    /// nothing already written.
    func prepare(writingTo url: URL, log: SessionLog) throws {
        self.log = log
        do {
            let writer = try TrackWriter(
                url: url, format: Self.fileFormat, name: name, log: log, watchSilence: true
            )
            writer.onProlongedSilence = { [weak self] in
                Task { @MainActor in self?.onInvalidated?("capturing digital silence") }
            }
            writer.onWriteFailure = { [weak self] detail in
                Task { @MainActor in self?.onArchiveFailed?(detail) }
            }
            self.writer = writer
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    /// Set after `prepare` and before capture starts.
    func monitor(with monitor: any TrackMonitor) {
        writer?.monitor(with: monitor)
    }

    func attach() throws {
        guard let writer else { throw RecorderError.notPrepared }

        engine = AVAudioEngine()
        let input = engine.inputNode

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        // @Sendable required: the tap runs on the render thread, and inherited
        // main-actor isolation traps the process there.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            @Sendable [weak writer, liveness] buffer, _ in
            liveness.mark()
            writer?.write(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error)
        }
        observeConfigurationChange()

        log?.log(
            "mic: attached — device=\(AudioDevices.defaultInputName()) "
                + "input=\(inputFormat.short)"
        )
    }

    func detach() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    func close(at date: Date) {
        writer?.close(paddingTo: date)
    }

    // MARK: -

    /// A route change stops the engine and discards its taps, reporting nothing
    /// through the tap itself.
    private func observeConfigurationChange() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // assumeIsolated traps if this ever arrives off-main; `queue: .main`
            // above is the only thing making it safe.
            MainActor.assumeIsolated { self?.onInvalidated?("route changed") }
        }
    }
}
