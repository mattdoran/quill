import CoreAudio
import Foundation

/// Names audio devices and reports property changes on them.
enum AudioDevices {
    static func defaultInputName() -> String {
        name(of: defaultDevice(kAudioHardwarePropertyDefaultInputDevice))
    }

    static func defaultOutputName() -> String {
        name(of: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    }

    /// Calls `onChange` on the main queue whenever the system's default device
    /// for `selector` changes, for as long as the listener is held.
    private final class Listener {
        private var address: AudioObjectPropertyAddress
        private var block: AudioObjectPropertyListenerBlock?

        init(selector: AudioObjectPropertySelector, onChange: @escaping @Sendable () -> Void) {
            address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                DispatchQueue.main.async { onChange() }
            }
            guard AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, nil, block
            ) == noErr else { return }
            self.block = block
        }

        deinit {
            guard let block else { return }
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, nil, block
            )
        }
    }

    /// Logs each default-device change for as long as the watcher is held.
    /// Diagnostic only — each track is rebuilt on its own evidence, not on
    /// this.
    final class Watcher {
        private var listeners: [Listener] = []

        init(log: SessionLog) {
            listeners = [
                Listener(selector: kAudioHardwarePropertyDefaultInputDevice) {
                    log.log("default input device is now \(AudioDevices.defaultInputName())")
                },
                Listener(selector: kAudioHardwarePropertyDefaultOutputDevice) {
                    log.log("default output device is now \(AudioDevices.defaultOutputName())")
                },
            ]
        }
    }

    // MARK: -

    private static func defaultDevice(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr else { return AudioObjectID(kAudioObjectUnknown) }
        return device
    }

    private static func name(of device: AudioObjectID) -> String {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return "none" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Core Audio returns a +1 CFString here.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &size, &name
        ) == noErr, let name else { return "device \(device)" }
        return name.takeRetainedValue() as String
    }
}
