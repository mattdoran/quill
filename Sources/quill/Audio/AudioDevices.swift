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

    /// Whether sound is currently coming out of a loudspeaker rather than
    /// something on the listener's head. Only true for the built-in speakers:
    /// a Bluetooth or USB device could be either, and guessing wrong there
    /// costs more than leaving echo cancellation off.
    static func defaultOutputIsLoudspeaker() -> Bool {
        let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        guard device != AudioObjectID(kAudioObjectUnknown),
            property(device, kAudioDevicePropertyTransportType)
                == kAudioDeviceTransportTypeBuiltIn
        else { return false }
        // The headphone jack is built-in too; only its data source says so.
        let headphones: UInt32 = 0x6864_706E  // 'hdpn'
        return property(
            device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput
        ) != headphones
    }

    private static func property(
        _ device: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    /// Calls `onChange` on the main queue whenever the system's default device
    /// for `selector` changes, for as long as the listener is held.
    private final class Listener {
        private var address: AudioObjectPropertyAddress
        private var block: AudioObjectPropertyListenerBlock?

        init(
            selector: AudioObjectPropertySelector,
            onChange: @escaping @MainActor @Sendable () -> Void
        ) {
            address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onChange() }
                }
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
    final class Watcher {
        private var listeners: [Listener] = []

        init(
            log: SessionLog,
            onOutputChange: @escaping @MainActor @Sendable () -> Void = {}
        ) {
            listeners = [
                Listener(selector: kAudioHardwarePropertyDefaultInputDevice) {
                    log.log("default input device is now \(AudioDevices.defaultInputName())")
                },
                Listener(selector: kAudioHardwarePropertyDefaultOutputDevice) {
                    log.log("default output device is now \(AudioDevices.defaultOutputName())")
                    onOutputChange()
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
