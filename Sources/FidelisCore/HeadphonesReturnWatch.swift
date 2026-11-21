import CoreAudio
import Foundation

/// Calls back each time the headphones' own audio device (macOS's, for its Bluetooth audio)
/// appears: they reconnected to the Mac. CoreAudio's device list is the signal, not
/// IOBluetooth's connect notifications: after headphones switch off mid-stream this process's
/// IOBluetooth can go on reporting them connected (2026-11-21), and then never reports them
/// connecting again.
@MainActor
final class HeadphonesReturnWatch {
    private let uid: String
    private let onReturn: () -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    private var present: Bool

    init(address: String, onReturn: @escaping () -> Void) {
        uid = OutputRouter.headphonesUID(address)
        self.onReturn = onReturn
        present = FidelisAudioDevice.deviceID(uid: uid) != nil
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        var address = FidelisAudioDevice.globalAddress(kAudioHardwarePropertyDevices)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listener = block
        }
    }

    private func devicesChanged() {
        let now = FidelisAudioDevice.deviceID(uid: uid) != nil
        defer { present = now }
        guard now, !present, listener != nil else { return }
        onReturn()
    }

    func stop() {
        guard let block = listener else { return }
        var address = FidelisAudioDevice.globalAddress(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        listener = nil
    }

    isolated deinit { stop() }
}
