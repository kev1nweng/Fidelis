import CoreAudio
import Foundation

/// Makes the Fidelis volume slider move the headphones' own volume (AVRCP absolute volume)
/// instead of scaling the samples, the way macOS does for its own Bluetooth audio.
///
/// Safety: the slider takes the headphones' current volume first, and only then does the driver
/// stop scaling, so nothing gets louder on the way in. Losing AVRCP turns scaling back on, which
/// stacks on the headphones' volume and can only make it quieter.
@MainActor
final class HeadphoneVolume {
    private let log: Log
    private var channel: AVRCPChannel?
    private var device: AudioObjectID?
    private var listener: AudioObjectPropertyListenerBlock?

    init(log: Log) { self.log = log }

    /// Software scaling on, as the driver must be whenever nothing drives the headphones.
    /// Called before every session, so a crashed run cannot leave it off.
    static func reset() {
        if let id = FidelisAudioDevice.id { _ = FidelisAudioDevice.setHardwareVolume(id, false) }
    }

    func attach(_ ch: AVRCPChannel) {
        detach()
        guard let id = FidelisAudioDevice.id else { return }
        channel = ch
        device = id
        ch.onVolume = { [weak self] v, initial in
            guard let self else { return }
            // The headphones' value becomes the slider's, from their buttons as well.
            FidelisAudioDevice.setVolume(id, v)
            if initial { self.engage() }
        }
        ch.onVolumeUnsupported = { [weak self] in self?.detach() }
        ch.onClose = { [weak self] in
            self?.log.warn("avrcp: channel closed; volume back in software")
            self?.detach()
        }
        ch.start()
    }

    private func engage() {
        guard let id = device, listener == nil else { return }
        let st = FidelisAudioDevice.setHardwareVolume(id, true)
        guard st == noErr else {
            // Most likely an older driver without 'fdhw': keep scaling in software.
            log.warn("output: driver cannot hand the volume to the headphones (\(st)); reinstall the driver")
            return
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.device, let v = FidelisAudioDevice.volume(id) else { return }
                self.channel?.setVolume(v)
            }
        }
        var address = FidelisAudioDevice.volumeAddress
        if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr { listener = block }
        log.info("output: volume now set on the headphones")
    }

    func detach() {
        if let id = device {
            if let block = listener {
                var address = FidelisAudioDevice.volumeAddress
                AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
            }
            _ = FidelisAudioDevice.setHardwareVolume(id, false)
        }
        listener = nil
        device = nil
        channel?.onVolume = nil
        channel?.onVolumeUnsupported = nil
        channel?.onClose = nil
        channel = nil
    }
}
