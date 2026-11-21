import Foundation
import Combine
import FidelisBluetooth

/// App-facing state and actions. Owns at most one StreamSession and supervises it: an unexpected
/// end (link loss, headphones closing the stream) is retried with back-off while the user still
/// wants to stream.
@MainActor
public final class Engine: ObservableObject {
    public struct Headphones: Identifiable, Hashable, Sendable {
        public var id: String { address }
        public let address: String
        public let name: String
        public let connected: Bool
    }

    public enum Status: Equatable, Sendable {
        case idle
        case connecting(String)
        case streaming
        case recovering(String)
        case stopping
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .idle, .failed: false
            default: true
            }
        }
    }

    public enum QualityChoice: String, CaseIterable, Identifiable, Sendable {
        /// `auto` holds back climbs that keep failing (ClimbBackoff); `autoAggressive` is libldac
        /// ABR as Android runs it.
        case auto, autoAggressive, k990, k660, k492, k330
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .auto: String(localized: "Auto (Recommended)")
            case .autoAggressive: String(localized: "Auto (Aggressive)")
            case .k990: "990"
            case .k660: "660"
            case .k492: "492"
            case .k330: "330"
            }
        }
        var mode: BitrateController.Mode {
            switch self {
            case .auto: .adaptive(ceiling: .kbps660)
            case .autoAggressive: .adaptive(ceiling: .kbps660, aggressive: true)
            case .k990: .fixed(.kbps990)
            case .k660: .fixed(.kbps660)
            case .k492: .fixed(.kbps492)
            case .k330: .fixed(.kbps330)
            }
        }
    }

    public enum SourceChoice: String, CaseIterable, Identifiable, Sendable {
        case system, chime, silence
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .system: String(localized: "System Audio")
            case .chime: String(localized: "Test Chime")
            case .silence: String(localized: "Silence")
            }
        }
    }

    @Published public private(set) var headphones: [Headphones] = []
    @Published public var selectedAddress: String? {
        didSet { UserDefaults.standard.set(selectedAddress, forKey: "selectedAddress") }
    }
    @Published public private(set) var status: Status = .idle
    @Published public private(set) var stats: MediaStreamer.Stats?
    @Published public private(set) var negotiated: StreamSession.Negotiated?
    @Published public var quality: QualityChoice = .auto {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "quality")
            session?.mode = quality.mode
        }
    }
    /// Experimental: ask IOBluetooth for high priority on the headphones' link while streaming.
    /// (Carries over the earlier "linkQualityMode" switch, which turned the same experiment on.)
    @Published public var highConnectionPriority = UserDefaults.standard.object(forKey: "highConnectionPriority") as? Bool
        ?? UserDefaults.standard.bool(forKey: "linkQualityMode") {
        didSet {
            UserDefaults.standard.set(highConnectionPriority, forKey: "highConnectionPriority")
            UserDefaults.standard.removeObject(forKey: "linkQualityMode")
            session?.raisesPriority = highConnectionPriority
        }
    }
    @Published public var source: SourceChoice = .system {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "source") }
    }
    @Published public private(set) var driverInstalled = FidelisAudioDevice.isDriverInstalled

    public let log = Log(file: Log.defaultFile)
    public let apiAvailable = FDBTDevice.privateAPIAvailable()
    private let helperPath: String
    private var session: StreamSession?
    private var wantsStreaming = false
    private var recoveries = 0
    private let router: OutputRouter
    private lazy var headphoneVolume = HeadphoneVolume(log: log)
    private lazy var softwareVolume = SoftwareVolume(log: log)
    private var sinkDelayUs: Int?
    private var connectionWatch: FDBTConnectionWatch?

    public init(helperPath: String) {
        self.helperPath = helperPath
        router = OutputRouter(log: log)
        selectedAddress = UserDefaults.standard.string(forKey: "selectedAddress")
        if let q = UserDefaults.standard.string(forKey: "quality").flatMap(QualityChoice.init) { quality = q }
        if let s = UserDefaults.standard.string(forKey: "source").flatMap(SourceChoice.init) { source = s }
        // A previous run that ended without restoring the output (crash, force quit).
        router.restoreIfNeeded()
        refreshDevices()
        if !apiAvailable { status = .failed(SessionError.privateAPIUnavailable.userMessage) }
        // A previous run that ended while streaming left macOS's Bluetooth audio off.
        if pausedMacAudio { Task { await resumeMacAudioIfPaused() } }
    }

    public func refreshDevices() {
        headphones = FDBTDevice.pairedDevices()
            .filter(\.isAudio)
            .map { Headphones(address: $0.address, name: $0.name, connected: $0.isConnected) }
            .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
        if selectedAddress == nil || !headphones.contains(where: { $0.address == selectedAddress }) {
            selectedAddress = headphones.first(where: \.connected)?.address ?? headphones.first?.address
        }
    }

    public func refreshDriverState() { driverInstalled = FidelisAudioDevice.isDriverInstalled }

    /// Set while the driver is being installed or removed.
    @Published public private(set) var driverBusy = false

    /// Installs (`remove == false`) or removes the audio driver with scripts/install-driver.sh,
    /// which asks for an administrator password and restarts coreaudiod.
    public func changeDriver(script: String, bundledDriver: String, remove: Bool) {
        guard !driverBusy, !status.isActive else { return }
        driverBusy = true
        let log = log
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script, remove ? "-u" : bundledDriver]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var output = ""
            var code: Int32 = -1
            do {
                try p.run()
                output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                code = p.terminationStatus
            } catch {
                output = "\(error)"
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0 {
                log.info("driver \(remove ? "removed" : "installed"): \(trimmed)")
            } else {
                log.warn("driver \(remove ? "removal" : "install") failed (\(code)): \(trimmed)")
            }
            // coreaudiod takes a moment to come back and load the plug-in.
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                self.driverBusy = false
                self.refreshDriverState()
            }
        }
    }

    /// Exclusive mode: macOS's own Bluetooth audio is off while Fidelis streams (through the
    /// installed helper), so it never races Fidelis for the headphones, and back on afterwards.
    /// On by default; the helper is installed the first time it is needed.
    @Published public private(set) var pausesMacAudio = UserDefaults.standard.object(forKey: "pausesMacBluetoothAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pausesMacAudio, forKey: "pausesMacBluetoothAudio") }
    }
    /// Set while the helper is being installed or removed.
    @Published public private(set) var macAudioBusy = false
    /// Fidelis turned it off and has not turned it back on (kept across a crash).
    private var pausedMacAudio: Bool {
        get { UserDefaults.standard.bool(forKey: "macBluetoothAudioPausedByFidelis") }
        set { UserDefaults.standard.set(newValue, forKey: "macBluetoothAudioPausedByFidelis") }
    }

    private static func bundledScript(_ name: String) -> String? { Bundle.main.path(forResource: name, ofType: "sh") }

    /// Installs the helper (asks for an administrator password once). False if it could not be
    /// installed or the user cancelled.
    private func installMacAudioHelper() async -> Bool {
        guard let installer = Self.bundledScript("install-bt-helper"), let helper = Self.bundledScript("bt-audio-helper") else {
            log.warn("exclusive mode: the helper scripts are missing from the app")
            return await MacBluetoothAudio.helperReady()
        }
        // Installed and current; an older version is replaced.
        if await MacBluetoothAudio.helperReady(source: helper) { return true }
        do {
            log.info("exclusive mode: \(try await MacBluetoothAudio.changeHelper(installer: installer, helperSource: helper, remove: false))")
            return true
        } catch {
            log.warn("exclusive mode: the helper was not installed: \(error.localizedDescription)")
            return false
        }
    }

    /// Turns exclusive mode on (installing the helper) or off (removing it, which turns macOS's
    /// Bluetooth audio back on).
    public func setPausesMacAudio(_ on: Bool) {
        guard !macAudioBusy, !status.isActive, on != pausesMacAudio else { return }
        macAudioBusy = true
        Task {
            defer { macAudioBusy = false }
            if on {
                guard await installMacAudioHelper() else { return }
                pausesMacAudio = true
                // Off by hand before: back on until a stream needs it off.
                if MacBluetoothAudio.isOff, !status.isActive { pausedMacAudio = true; await resumeMacAudioIfPaused() }
            } else {
                if FileManager.default.fileExists(atPath: MacBluetoothAudio.helperPath), let installer = Self.bundledScript("install-bt-helper") {
                    do {
                        log.info("exclusive mode: \(try await MacBluetoothAudio.changeHelper(installer: installer, helperSource: "", remove: true))")
                    } catch {
                        log.warn("exclusive mode: the helper was not removed: \(error.localizedDescription)")
                        return
                    }
                }
                pausesMacAudio = false
                pausedMacAudio = false
            }
        }
    }

    /// Before a takeover: macOS's Bluetooth audio off, then the headphones back (bluetoothd
    /// restarted, so every Bluetooth device reconnects).
    private func pauseMacAudio(address: String) async {
        guard pausesMacAudio else { return }
        pausing = true
        defer { pausing = false }
        // First use: install the helper now; declining turns exclusive mode off.
        guard await installMacAudioHelper() else {
            pausesMacAudio = false
            log.info("exclusive mode: off; taking over as usual")
            return
        }
        // Already off (by hand, or a run that crashed): back on when this stream ends.
        if MacBluetoothAudio.isOff, MacBluetoothAudio.remoteControlIsOff { pausedMacAudio = true; return }
        guard wantsStreaming else { return }
        status = .connecting(String(localized: "Pausing macOS Bluetooth audio…"))
        do {
            pausedMacAudio = true
            if try await MacBluetoothAudio.set(off: true) {
                log.info("macOS Bluetooth audio: off while streaming; bluetoothd restarted")
                await waitForReconnect(address: address)
            }
        } catch {
            pausedMacAudio = MacBluetoothAudio.isOff
            log.warn("macOS Bluetooth audio: could not turn it off (\(error.localizedDescription)); taking over as usual")
        }
    }

    /// run() is turning it off; a stop meanwhile leaves turning it back on to run().
    private var pausing = false

    /// After a stream (or a crash): macOS's Bluetooth audio back on, if Fidelis turned it off.
    private func resumeMacAudioIfPaused(address: String? = nil) async {
        guard pausedMacAudio else { return }
        do {
            if try await MacBluetoothAudio.set(off: false) {
                log.info("macOS Bluetooth audio: back on; bluetoothd restarted")
                if let address { await waitForReconnect(address: address) }
            }
            pausedMacAudio = false
        } catch {
            log.warn("macOS Bluetooth audio: could not turn it back on: \(error.localizedDescription)")
        }
    }

    /// bluetoothd comes back in a moment and the headphones reconnect on their own; page them if
    /// they have not after a while.
    private func waitForReconnect(address: String) async {
        try? await Task.sleep(for: .seconds(1.5))
        if await waitFor(timeout: 10, { FDBTDevice(address: address)?.isConnected ?? false }) {
            log.info("headphones: reconnected after the bluetoothd restart")
            return
        }
        guard let device = FDBTDevice(address: address) else { return }
        let status: Int32 = await withCheckedContinuation { cont in device.openConnection { cont.resume(returning: $0) } }
        log.info("headphones: reconnect after the bluetoothd restart: \(device.isConnected ? "connected" : "failed (0x\(String(UInt32(bitPattern: status), radix: 16)))")")
    }

    /// Back to idle: macOS's Bluetooth audio on again, then the output it had.
    private func finishIdle(address: String? = nil) async {
        await resumeMacAudioIfPaused(address: address ?? selectedAddress)
        await router.restore()
    }

    public func toggle() {
        if wantsStreaming || status.isActive { stop() } else { start() }
    }

    public func start() {
        guard apiAvailable, session == nil, let address = selectedAddress else { return }
        if source == .system {
            refreshDriverState()
            guard FidelisAudioDevice.id != nil else {
                status = .failed(driverInstalled ? String(localized: "The Fidelis audio device isn't loaded; reinstall the driver")
                                                 : String(localized: "Install the audio driver to stream system audio"))
                return
            }
            // Before the takeover: once the headphones leave macOS, it moves the output elsewhere.
            router.remember()
        }
        wantsStreaming = true
        recoveries = 0
        connectionWatch = nil
        status = .connecting(String(localized: "Taking over from macOS…"))
        Task { await run(address: address) }
    }

    public func stop() {
        Task { await stopAndWait() }
    }

    /// Stops streaming, hands the headphones back and puts the output back; returns when done.
    public func stopAndWait() async {
        wantsStreaming = false
        connectionWatch = nil
        guard let s = session else {
            if status.isActive { status = .idle }
            if !pausing { await finishIdle() }
            return
        }
        status = .stopping
        headphoneVolume.detach()
        softwareVolume.detach()
        await s.stop()
        if session === s { session = nil }
        stats = nil
        // Still "stopping" while bluetoothd restarts, so a new start waits for it.
        await finishIdle()
        status = .idle
        refreshDevices()
    }

    private func run(address: String) async {
        guard FDBTDevice(address: address) != nil else { status = .failed(SessionError.deviceNotFound.userMessage); return }
        // A call holds them in the hands-free profile and macOS takes every takeover straight
        // back; retrying only drops the call's audio again and again.
        if FidelisAudioDevice.microphoneInUse(address: address) {
            log.warn("headphones: their microphone is in use (a call); not taking them over")
            wantsStreaming = false
            status = .failed(SessionError.headphonesInCall.userMessage)
            await finishIdle()
            return
        }
        await pauseMacAudio(address: address)
        guard wantsStreaming else { status = .idle; await finishIdle(address: address); return }
        // Made after the pause: bluetoothd may have restarted.
        guard let device = FDBTDevice(address: address) else {
            wantsStreaming = false
            status = .failed(SessionError.deviceNotFound.userMessage)
            await finishIdle(address: address)
            return
        }
        let s = StreamSession(device: device, helperPath: helperPath, log: log)
        s.mode = quality.mode
        s.raisesPriority = highConnectionPriority
        s.pagesHeadphones = recoveries == 0
        // With macOS's AVRCP off, Fidelis holds it and sets the headphones' own volume.
        s.holdsAVRCP = StreamSession.usesAVRCP || MacBluetoothAudio.remoteControlIsOff
        if s.holdsAVRCP { log.info("avrcp: macOS's is off; holding it for the headphones' own volume") }
        session = s
        s.onPhase = { [weak self] phase in
            guard let self, self.session === s else { return }
            switch phase {
            case .takingOver(let n):
                self.status = .connecting(n == 1 ? String(localized: "Taking over from macOS…")
                                                 : String(localized: "Taking over (attempt \(n))…"))
            case .negotiating: self.status = .connecting(String(localized: "Negotiating LDAC…"))
            case .openingMedia: self.status = .connecting(String(localized: "Opening audio channel…"))
            case .streaming:
                self.status = .streaming
                self.recoveries = 0
                if self.source == .system {
                    if let ch = s.avrcp { self.headphoneVolume.attach(ch) }
                    self.router.routeToFidelis()
                }
                s.avrcp?.onKey = { [log = self.log] key in
                    if !MediaKeys.press(key) { log.warn("could not pass \(key.rawValue) on to the player") }
                }
            case .handingBack: if self.status != .stopping, !self.wantsStreaming { self.status = .stopping }
            case .ended: break
            }
        }
        // Every published change rebuilds the whole menu and its icon, which shows as a flicker;
        // the menu only shows the bitrate, so publish only when that changes.
        s.onStats = { [weak self] st in
            guard let self, self.stats?.quality != st.quality else { return }
            self.stats = st
        }
        s.onSinkDelay = { [weak self] us in
            guard let self else { return }
            self.sinkDelayUs = us
            self.updateLatency()
        }
        s.onUnexpectedEnd = { [weak self] why in
            guard let self, self.session === s else { return }
            self.headphoneVolume.detach()
            self.softwareVolume.detach()
            self.session = nil
            self.stats = nil
            // `why` is for the log (StreamSession logged it); the menu gets a plain sentence.
            self.recover(address: address, why: String(localized: "Connection lost"))
        }
        // Scaling on until the headphones' volume is known (also undoes a crashed run).
        if source == .system {
            HeadphoneVolume.reset()
            if !s.holdsAVRCP { await router.liftHeadphones(address: address, firstAttempt: recoveries == 0) { [weak self] in self?.wantsStreaming ?? false } }
        }
        do {
            let choice = source
            let log = log
            try await s.start { [weak self] rate in
                switch choice {
                case .system:
                    // Its buffer holds the cushion the streamer sends ahead, plus the usual 40 ms.
                    let src = SystemAudioSource(sampleRate: rate, cushionMs: Int(StreamSession.cushionSeconds * 1000), log: log)
                    self?.systemSource = src
                    // Before it plays: the slider's curve is applied here (not with AVRCP, which
                    // moves the headphones' own volume instead).
                    if !s.holdsAVRCP { self?.softwareVolume.attach(src) }
                    return src
                case .chime: return ChimeSource(sampleRate: rate)
                case .silence: return SilenceSource(sampleRate: rate)
                }
            }
            updateLatency()
            negotiated = s.negotiated
            if !wantsStreaming { await s.stop(); session = nil; status = .idle }
        } catch SessionError.cancelled {
            softwareVolume.detach()
            // stop() asked for it and finishes the job; or the link dropped and onUnexpectedEnd
            // already chose what comes next.
            if session === s { session = nil }
        } catch {
            softwareVolume.detach()
            log.error("start failed: \(error)")
            if session === s { session = nil }
            if wantsStreaming { recover(address: address, why: userMessage(for: error)) } else { status = .idle; await finishIdle(address: address) }
        }
    }

    private weak var systemSource: SystemAudioSource?

    private func headphonesConnected(_ address: String) -> Bool { FDBTDevice(address: address)?.isConnected ?? false }

    /// The headphones went away mid-stream (switched off, out of range). Most likely the user
    /// is done with them, so this ends the stream as a stop would, the way macOS treats a
    /// headphone disconnect: playback pauses (nothing jumps to the speakers), macOS gets its
    /// Bluetooth audio back, and the output goes to where it would be without them. When they
    /// connect again, the app asks whether to stream to them again (onHeadphonesReturned).
    private func headphonesWentAway(address: String) {
        log.info("headphones: gone (switched off or out of range); stopping")
        wantsStreaming = false
        recoveries = 0
        if source == .system, !MediaKeys.pause() { log.warn("could not pause the player") }
        status = .stopping
        Task {
            await resumeMacAudioIfPaused()
            await router.restore(timeout: 1, fallBack: true)
            status = .idle
            refreshDevices()
        }
        connectionWatch = FDBTConnectionWatch { [weak self] connected in
            MainActor.assumeIsolated {
                guard let self, connected.caseInsensitiveCompare(address) == .orderedSame, !self.status.isActive,
                      let device = FDBTDevice(address: address) else { return }
                self.connectionWatch = nil
                self.log.info("headphones: back; asking whether to stream again")
                self.refreshDevices()
                self.onHeadphonesReturned?(Headphones(address: address, name: device.name, connected: true))
            }
        }
    }

    /// The headphones that went away mid-stream are connected again (once per time they went).
    public var onHeadphonesReturned: ((Headphones) -> Void)?

    /// What the Fidelis device reports as its latency: our buffer (with the cushion), and the
    /// headphones' own delay (reported, or a typical A2DP sink's when they don't say).
    private func updateLatency() {
        guard source == .system, let src = systemSource, let id = FidelisAudioDevice.id else { return }
        // The send lead is part of the buffer now (the cushion).
        let total = src.bufferedMicroseconds + (sinkDelayUs ?? 150_000)
        router.setLatency(id, microseconds: total)
    }

    private func recover(address: String, why: String) {
        guard wantsStreaming else { status = .idle; Task { await finishIdle(address: address) }; return }
        if !headphonesConnected(address) { headphonesWentAway(address: address); return }
        recoveries += 1
        guard recoveries <= 3 else {
            wantsStreaming = false
            status = .failed(why)
            refreshDevices()
            Task { await finishIdle(address: address) }
            return
        }
        let delay = Double(recoveries) * 3
        status = .recovering(String(localized: "\(why) — retrying in \(Int(delay)) s"))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard wantsStreaming, session == nil else { return }
            // The link was still up when it dropped the stream, but they were switching off.
            if !headphonesConnected(address) { headphonesWentAway(address: address); return }
            await run(address: address)
        }
    }
}
