import CoreAudio
import Foundation
import Synchronization

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
    /// output alone if the user has meanwhile picked something other than Fidelis. When it does
    /// not come back, `fallBack` moves the output to the built-in speakers, as macOS does when
    /// an output goes away, rather than leave it on Fidelis with nothing to hear.
    func restore(timeout: TimeInterval = 12, fallBack: Bool = false) async {
        rememberLiftedSlider()
        let deadline = Date().addingTimeInterval(timeout)
        if let uid = saved {
            while true {
                let current = FidelisAudioDevice.defaultOutput
                if let current, current != FidelisAudioDevice.id {
                    // Someone else (the user, or macOS when the device went away) chose; but macOS
                    // falling back to the speakers during the takeover is not a choice, so still
                    // prefer the remembered device once it is back.
                    if FidelisAudioDevice.uid(of: current) == uid { break }
                }
                if let target = FidelisAudioDevice.deviceID(uid: uid) {
                    // Their old volume first, then the audio.
                    _ = Self.applySavedLevel()
                    if FidelisAudioDevice.setDefaultOutput(target) { log.info("output: back to \(uid)") }
                    break
                }
                if Date() >= deadline {
                    if fallBack, FidelisAudioDevice.defaultOutput == FidelisAudioDevice.id,
                       let speakers = FidelisAudioDevice.builtInOutput, FidelisAudioDevice.setDefaultOutput(speakers) {
                        log.info("output: \(uid) is gone; back to the built-in output")
                    } else {
                        log.warn("output: \(uid) did not come back; leaving the output as it is")
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            saved = nil
            lastLatencyUs = nil
        }
        // Their own volume waits for them too, whatever the output: the listener that would set
        // it later dies with the app, and quitting left them at 100% (2026-11-20).
        if let level = savedLevel {
            _ = await waitFor(timeout: max(0, deadline.timeIntervalSinceNow)) { FidelisAudioDevice.deviceID(uid: level.uid) != nil }
        }
        finishHeadphoneLevel()
    }

    /// Synchronous variant for launch: only if the device is there now.
    func restoreIfNeeded() {
        finishHeadphoneLevel()
        guard let uid = saved else { return }
        if FidelisAudioDevice.defaultOutput == FidelisAudioDevice.id {
            guard let target = FidelisAudioDevice.deviceID(uid: uid) else {
                // Not back yet (still held, or off): keep it, so the next stop or quit can still
                // return there instead of leaving the output on Fidelis.
                log.warn("output: \(uid) from the last run is not here yet; will return there later")
                return
            }
            FidelisAudioDevice.setDefaultOutput(target)
            log.info("output: restored \(uid) left over from the last run")
        }
        saved = nil
    }

    // MARK: The headphones' own volume

    /// While Fidelis streams, macOS no longer sets the headphones' own (AVRCP) volume, so it stays
    /// where macOS left it and the Fidelis slider can only go quieter from there. So: lift it to
    /// 100% just before the takeover, let the Fidelis slider do all of the attenuation, and put
    /// it back when macOS has the headphones again.
    ///
    /// Nothing may get louder on the way:
    /// - the lift happens only once nothing plays on the headphones (output moved to Fidelis,
    ///   the device idle, and a moment for what was already sent to play out);
    /// - the Fidelis slider starts one step below the headphones' old volume, and the stream
    ///   fades in (SystemAudioSource);
    /// - the old volume goes back the instant the headphones' device reappears, from a CoreAudio
    ///   listener rather than a poll, and it is kept in user defaults so a crash can't lose it.
    nonisolated private static let levelKey = "restoreHeadphoneLevel"
    private var levelListener: AudioObjectPropertyListenerBlock?
    private let levelQueue = DispatchQueue(label: "fidelis.headphone-level", qos: .userInteractive)

    private var savedLevel: (uid: String, volume: Float)? {
        get {
            guard let d = UserDefaults.standard.dictionary(forKey: Self.levelKey),
                  let uid = d["uid"] as? String, let v = d["volume"] as? Double else { return nil }
            return (uid, Float(v))
        }
        set {
            if let newValue { UserDefaults.standard.set(["uid": newValue.uid, "volume": Double(newValue.volume)], forKey: Self.levelKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.levelKey) }
        }
    }

    static func headphonesUID(_ address: String) -> String { address.uppercased() + ":output" }

    /// Whether this run lifted them: the slider is then saved as the level to start at next time.
    private var lifted = false
    /// Stored in dB, not as a slider position: a later change of the curve must not turn a
    /// saved position into a louder level. (The first key, "liftedFidelisVolume", held a slider
    /// position on a -96 dB curve and is ignored.)
    nonisolated private static let liftedLevelKey = "liftedFidelisDecibels"
    /// -30 dB until the listener has picked a level with the headphones at full volume. Their
    /// full volume is unknown and differs by model, so the first stream starts low (about 32% on
    /// the cubic slider) and fades in.
    static let defaultLiftedDecibels: Float = -30

    static var liftedSlider: Float {
        let db = (UserDefaults.standard.object(forKey: liftedLevelKey) as? Double).map(Float.init) ?? defaultLiftedDecibels
        return FidelisAudioDevice.slider(forDecibels: db)
    }

    private func rememberLiftedSlider() {
        guard lifted else { return }
        lifted = false
        guard let id = FidelisAudioDevice.id, let v = FidelisAudioDevice.volume(id) else { return }
        // Silence is not a level to start at; the default is.
        let db = FidelisAudioDevice.decibels(forSlider: v) ?? Self.defaultLiftedDecibels
        UserDefaults.standard.set(Double(db), forKey: Self.liftedLevelKey)
        log.info("output: will start at \(Int(db.rounded())) dB next time")
    }

    /// Before a takeover of `address`. `firstAttempt` sets the Fidelis slider (not on reconnects,
    /// where the listener may have moved it since). Returns false when the volume was left alone.
    @discardableResult
    func liftHeadphones(address: String, firstAttempt: Bool, proceed: () -> Bool = { true }) async -> Bool {
        let uid = Self.headphonesUID(address)
        guard let hp = FidelisAudioDevice.deviceID(uid: uid), let fidelis = FidelisAudioDevice.id,
              let current = FidelisAudioDevice.volume(hp) else { return false }
        // A crashed run left them lifted: its saved value is the real one.
        let original = savedLevel.flatMap { $0.uid == uid ? $0.volume : nil } ?? current
        savedLevel = (uid, original)
        watchHeadphones()
        routeToFidelis()
        guard await waitFor(timeout: 1.5, { !FidelisAudioDevice.isRunning(hp) }) else {
            log.warn("headphones: something still plays on them directly; leaving their volume at \(Self.percent(current))")
            return false
        }
        try? await Task.sleep(for: .milliseconds(300))   // what was already sent plays out first
        // Stopped meanwhile: restore() has put their volume back and must not be undone.
        guard proceed(), savedLevel != nil else { return false }
        // The slider first: at full volume the headphones are far louder than at their old
        // level, so streaming starts at the level last chosen while lifted, or quiet.
        if firstAttempt {
            FidelisAudioDevice.setVolume(fidelis, Self.liftedSlider)
        }
        guard FidelisAudioDevice.deviceID(uid: uid) == hp, !FidelisAudioDevice.isRunning(hp),
              FidelisAudioDevice.setVolume(hp, 1) else {
            log.warn("headphones: could not lift their volume")
            return false
        }
        lifted = true
        // The volume goes to the headphones over macOS's AVRCP, which the takeover is about to
        // drop: give the command time to arrive.
        try? await Task.sleep(for: .milliseconds(500))
        log.info("headphones: own volume 100% while streaming (was \(Self.percent(original)))")
        return true
    }

    /// Whether the headphones' device was there at the last device-list change: the listener acts
    /// only when it appears. Their device also *disappears* through that listener at the start of
    /// the takeover, still listed for a moment, and restoring then undid the lift (measured
    /// 2026-11-20: 0x7F sent, 0x3F sent 140 ms later by the listener).
    nonisolated private static let headphonesPresent = Atomic<Bool>(false)

    nonisolated private static func headphonesChanged() {
        guard let d = UserDefaults.standard.dictionary(forKey: levelKey), let uid = d["uid"] as? String else { return }
        let present = FidelisAudioDevice.deviceID(uid: uid) != nil
        let was = headphonesPresent.exchange(present, ordering: .relaxed)
        if present && !was { _ = applySavedLevel() }
    }

    /// Puts the headphones' old volume back if their device is there. Returns true once done.
    @discardableResult
    nonisolated static func applySavedLevel() -> Bool {
        guard let d = UserDefaults.standard.dictionary(forKey: levelKey),
              let uid = d["uid"] as? String, let v = d["volume"] as? Double,
              let hp = FidelisAudioDevice.deviceID(uid: uid) else { return false }
        if let now = FidelisAudioDevice.volume(hp), abs(now - Float(v)) < 0.005 { return true }
        return FidelisAudioDevice.setVolume(hp, Float(v))
    }

    /// The headphones' device comes back when macOS has them again (hand-back, a reconnect, or
    /// after a crash): set their old volume before anything plays on them at 100%.
    private func watchHeadphones() {
        guard levelListener == nil else { return }
        Self.headphonesPresent.store(savedLevel.map { FidelisAudioDevice.deviceID(uid: $0.uid) != nil } ?? false, ordering: .relaxed)
        let block: AudioObjectPropertyListenerBlock = { _, _ in OutputRouter.headphonesChanged() }
        var address = FidelisAudioDevice.globalAddress(kAudioHardwarePropertyDevices)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, levelQueue, block) == noErr {
            levelListener = block
        }
    }

    /// After a hand-back: the old volume is back (or will be, when the device appears).
    private func finishHeadphoneLevel() {
        guard let level = savedLevel else { return }
        if Self.applySavedLevel() {
            log.info("headphones: own volume back to \(Self.percent(level.volume))")
            savedLevel = nil
            if let block = levelListener {
                var address = FidelisAudioDevice.globalAddress(kAudioHardwarePropertyDevices)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, levelQueue, block)
                levelListener = nil
            }
        } else {
            watchHeadphones()   // not back yet: the listener does it when they are
        }
    }

    private static func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }

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
