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
    private static let fileFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
    )!

    let name = "mic"
    var lastBufferAt: Date? { liveness.last }
    var firstBufferAt: Date? { writer?.firstBufferAt }
    var gaps: [TrackWriter.Gap] { writer?.gaps ?? [] }
    var duration: TimeInterval { writer?.duration ?? 0 }
    var lastAudibleAt: Date? { writer?.lastAudibleAt }
    var hasEverBeenAudible: Bool { writer?.hasEverBeenAudible ?? false }

    var onInvalidated: ((String) -> Void)?

    private var engine = AVAudioEngine()
    private let liveness = LivenessClock()
    private var writer: TrackWriter?
    private var log: SessionLog?
    private var configurationObserver: NSObjectProtocol?

    /// Cleared for the rest of the session once a voice-processing graph is
    /// caught delivering silence, so rebuilds stop trying it.
    private var voiceProcessingAllowed = Config.micVoiceProcessing()

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
            self.writer = writer
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    func attach() throws {
        guard let writer else { throw RecorderError.notPrepared }

        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessingAllowed
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                log?.warn("mic: voice processing unavailable (\(error)) — recording raw")
                voice = false
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        if voice {
            try attachVoiceTap(on: input, deviceRate: inputFormat.sampleRate, writer: writer)
        } else {
            // @Sendable required: the tap runs on the render thread, and
            // inherited main-actor isolation traps the process there.
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
                @Sendable [weak writer, liveness] buffer, _ in
                liveness.mark()
                writer?.write(buffer)
            }
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
                + "voiceProcessing=\(input.isVoiceProcessingEnabled) input=\(inputFormat.short)"
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

    /// VoiceProcessingIO is a duplex unit, not an input effect: it needs a
    /// rendered output path and one explicit mono client format on both sides,
    /// or it delivers zeroed buffers (rca-001). The mixer has no sources —
    /// nothing is monitored or played — its connection exists solely to give
    /// the unit a formatted output path.
    private func attachVoiceTap(
        on input: AVAudioInputNode, deviceRate: Double, writer: TrackWriter
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: deviceRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(input.outputFormat(forBus: 0))
        }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)

        // Some routes build this graph successfully and still yield digital
        // zeroes, recoverable only by capturing raw.
        let probe = VoiceLivenessProbe(sampleRate: deviceRate) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.voiceProcessingAllowed = false
                self.onInvalidated?("voice processing delivered silence")
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) {
            @Sendable [weak writer, liveness] buffer, _ in
            liveness.mark()
            guard probe.accept(buffer) else { return }
            writer?.write(buffer)
        }
    }

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

private final class VoiceLivenessProbe: @unchecked Sendable {
    private let deadline: Int
    private let onSilent: @Sendable () -> Void
    private var frames = 0
    private var peak: Float = 0
    private var settled = false

    init(sampleRate: Double, onSilent: @escaping @Sendable () -> Void) {
        deadline = Int(sampleRate)
        self.onSilent = onSilent
    }

    /// False once the graph is judged dead, so nothing more is appended before
    /// the rebuild.
    func accept(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard !settled else { return true }
        if let samples = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) }
        }
        frames += Int(buffer.frameLength)
        guard frames >= deadline else { return true }
        settled = true
        guard peak == 0 else { return true }
        onSilent()
        return false
    }
}
