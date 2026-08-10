import AVFoundation
import CoreAudio
import Foundation

/// Captures all system audio output into a `TrackWriter` via a Core Audio
/// process tap (macOS 14.2+). No virtual device, no kernel extension — the tap
/// mixes every process's output to stereo and delivers it through a private
/// aggregate device. First use triggers the one-time "System Audio Recording"
/// TCC prompt and lights the purple recording indicator while active.
///
/// Rebuild policy lives in `CaptureSupervisor`; this owns only the graph.
///
/// A tap whose output device disappears (Bluetooth off under live AirPods)
/// stops delivering and reports nothing; the aggregate still answers that it is
/// alive. This raises no invalidation of its own and relies on the supervisor's
/// stall check.
@MainActor
final class SystemAudioRecorder: Capture {
    enum RecorderError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):
                return "process tap creation failed (OSStatus \(s)) — check System Settings → Privacy & Security → Screen & System Audio Recording"
            case .tapFormatUnreadable(let s): return "couldn't read tap stream format (OSStatus \(s))"
            case .aggregateCreationFailed(let s): return "aggregate device creation failed (OSStatus \(s))"
            case .ioProcCreationFailed(let s): return "IO proc creation failed (OSStatus \(s))"
            case .deviceStartFailed(let s): return "device start failed (OSStatus \(s))"
            case .fileCreationFailed(let e): return "output file creation failed: \(e)"
            }
        }
    }

    let name = "system"
    var lastBufferAt: Date? { liveness.last }
    var firstBufferAt: Date? { writer?.firstBufferAt }
    var gaps: [TrackWriter.Gap] { writer?.gaps ?? [] }
    var duration: TimeInterval { writer?.duration ?? 0 }

    var onInvalidated: ((String) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let liveness = LivenessClock()
    private var writer: TrackWriter?
    private var url: URL?
    private var log: SessionLog?
    private let queue = DispatchQueue(label: "com.mattdoran.quill.system-tap")

    /// Use a .caf extension: CAF needs no finalization pass, so a crash
    /// mid-meeting loses nothing already written. The file itself waits for the
    /// first attach, when the tap's format is known.
    func prepare(writingTo url: URL, log: SessionLog) {
        self.url = url
        self.log = log
    }

    func attach() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "quill system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw RecorderError.tapCreationFailed(status) }
        tapID = newTapID

        do {
            let format = try tapStreamFormat()
            try createAggregateDevice(tapUUID: description.uuid)
            // Pinned to the first attach's tap format: a rebuild that comes
            // back with a different one is resampled to this, not written raw.
            if writer == nil, let url, let log {
                do {
                    // Silence on this track is indistinguishable from a dead
                    // tap — nobody playing anything gives exact zeroes — so it
                    // is not watched for.
                    writer = try TrackWriter(
                        url: url, format: format, name: name, log: log, watchSilence: false
                    )
                } catch {
                    throw RecorderError.fileCreationFailed(error)
                }
            }
            try installIOProc(format: format)
            log?.log("system: attached — tap=\(format.short)")
        } catch {
            detach()
            throw error
        }
    }

    func detach() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    func close(at date: Date) {
        writer?.close(paddingTo: date)
    }

    // MARK: -

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.tapFormatUnreadable(status)
        }
        return format
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "quill-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr else { throw RecorderError.aggregateCreationFailed(status) }
        aggregateID = newAggregateID
    }

    private func installIOProc(format: AVAudioFormat) throws {
        // @Sendable required: Core Audio calls this on its realtime thread, and
        // inherited main-actor isolation traps the process on the first buffer.
        let writer = writer
        let liveness = liveness
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            @Sendable _, inInputData, _, _, _ in
            liveness.mark()
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }
            writer?.write(buffer)
        }
        guard status == noErr, let procID else { throw RecorderError.ioProcCreationFailed(status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw RecorderError.deviceStartFailed(status) }
    }
}
