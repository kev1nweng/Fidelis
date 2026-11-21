import CoreAudio
import Foundation

/// Applies the Fidelis slider to the samples in Fidelis itself, on the cubic curve
/// of ALSA and PulseAudio (FidelisAudioDevice.gain(forSlider:)), instead of in the driver: the driver's curve leaves
/// almost no usable range once the headphones' own volume is at 100%.
///
/// Safety: the source gets the gain first and the driver stops scaling after, so the change is
/// only ever quieter for a moment. If the driver cannot hand over (an older driver), the slider
/// moves to the position that is equally loud on the driver's curve.
@MainActor
final class SoftwareVolume {
    private let log: Log
    private weak var source: SystemAudioSource?
    private var device: AudioObjectID?
    private var listener: AudioObjectPropertyListenerBlock?

    init(log: Log) { self.log = log }

    func attach(_ src: SystemAudioSource) {
        detach()
        guard let id = FidelisAudioDevice.id else { return }
        source = src
        device = id
        apply()
        let st = FidelisAudioDevice.setHardwareVolume(id, true)
        guard st == noErr else {
            log.warn("output: driver cannot leave the volume to Fidelis (\(st)); reinstall the driver")
            src.setVolumeGain(1)
            if let v = FidelisAudioDevice.volume(id) { FidelisAudioDevice.setVolume(id, FidelisAudioDevice.driverSlider(matching: v)) }
            source = nil
            device = nil
            return
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        var address = FidelisAudioDevice.volumeAddress
        if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr { listener = block }
    }

    private func apply() {
        guard let id = device, let v = FidelisAudioDevice.volume(id) else { return }
        source?.setVolumeGain(FidelisAudioDevice.gain(forSlider: v))
    }

    func detach() {
        if let id = device {
            if let block = listener {
                var address = FidelisAudioDevice.volumeAddress
                AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
            }
            // Driver scaling back on before the source's gain goes: quieter for a moment, never louder.
            _ = FidelisAudioDevice.setHardwareVolume(id, false)
        }
        source?.setVolumeGain(1)
        listener = nil
        device = nil
        source = nil
    }
}
