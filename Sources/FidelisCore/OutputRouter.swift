import CoreAudio
import Foundation

/// Moves the system output to the Fidelis device while streaming system audio, and back after.
///
/// The output to go back to is kept by UID in user defaults, so a run that ends without
/// restoring it (crash, force quit) is put right at the next launch. It is remembered before
/// the takeover: when the headphones leave macOS, macOS moves the output to the speakers, and
/// restoring that would be wrong. After hand-back the headphones' own device takes a few
/// seconds to come back, so restoring waits for it.
@MainActor
final class OutputRouter {
    private static let key = "restoreOutputUID"
    private let log: Log
    private var lastLatencyUs: Int?

    init(log: Log) { self.log = log }

    private var saved: String? {
        get { UserDefaults.standard.string(forKey: Self.key) }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }

    /// Notes the current output, unless it is already ours or one is already noted.
    func remember() {
        guard saved == nil, let current = FidelisAudioDevice.defaultOutput,
              let uid = FidelisAudioDevice.uid(of: current), uid != FidelisAudioDevice.uid else { return }
        saved = uid
        log.info("output: will return to \(uid)")
    }

    func routeToFidelis() {
        guard let id = FidelisAudioDevice.id else { log.warn("output: Fidelis device missing"); return }
        if FidelisAudioDevice.defaultOutput == id { return }
        if FidelisAudioDevice.setDefaultOutput(id) {
            log.info("output: system audio now plays through Fidelis")
        } else {
            log.warn("output: could not make Fidelis the default output")
        }
    }

    /// Back to the remembered output, waiting up to `timeout` for it to (re)appear. Leaves the
    /// output alone if the user has meanwhile picked something other than Fidelis.
    func restore(timeout: TimeInterval = 12) async {
        guard let uid = saved else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let current = FidelisAudioDevice.defaultOutput
            if let current, current != FidelisAudioDevice.id {
                // Someone else (the user, or macOS when the device went away) chose; but macOS
                // falling back to the speakers during the takeover is not a choice, so still
                // prefer the remembered device once it is back.
                if FidelisAudioDevice.uid(of: current) == uid { break }
            }
            if let target = FidelisAudioDevice.deviceID(uid: uid) {
                if FidelisAudioDevice.setDefaultOutput(target) { log.info("output: back to \(uid)") }
                break
            }
            if Date() >= deadline {
                log.warn("output: \(uid) did not come back; leaving the output as it is")
                break
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        saved = nil
        lastLatencyUs = nil
    }

    /// Synchronous variant for launch: only if the device is there now.
    func restoreIfNeeded() {
        guard let uid = saved else { return }
        if FidelisAudioDevice.defaultOutput == FidelisAudioDevice.id, let target = FidelisAudioDevice.deviceID(uid: uid) {
            FidelisAudioDevice.setDefaultOutput(target)
            log.info("output: restored \(uid) left over from the last run")
        }
        saved = nil
    }

    /// Each change restarts the device's IO (a short gap), so small changes are ignored.
    func setLatency(_ device: AudioObjectID, microseconds: Int) {
        if let last = lastLatencyUs, abs(last - microseconds) < 20_000 { return }
        let st = FidelisAudioDevice.setPresentationLatency(device, microseconds: microseconds)
        if st == noErr {
            lastLatencyUs = microseconds
            log.info("output: reporting \(microseconds / 1000) ms latency")
        } else {
            log.warn("output: could not set the latency (\(st))")
        }
    }
}
