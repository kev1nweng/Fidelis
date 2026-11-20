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
        case auto, k990, k660, k492, k330
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .auto: String(localized: "Auto")
            case .k990: "990"
            case .k660: "660"
            case .k492: "492"
            case .k330: "330"
            }
        }
        var mode: BitrateController.Mode {
            switch self {
            case .auto: .adaptive(ceiling: .kbps660)
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
    @Published public var source: SourceChoice = .system {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "source") }
    }
    @Published public private(set) var driverInstalled = FidelisAudioDevice.isDriverInstalled
    @Published public private(set) var logLines: [Log.Line] = []

    public let log = Log()
    public let apiAvailable = FDBTDevice.privateAPIAvailable()
    private let helperPath: String
    private var session: StreamSession?
    private var wantsStreaming = false
    private var recoveries = 0
    private let router: OutputRouter
    private var sinkDelayUs: Int?

    public init(helperPath: String) {
        self.helperPath = helperPath
        router = OutputRouter(log: log)
        selectedAddress = UserDefaults.standard.string(forKey: "selectedAddress")
        if let q = UserDefaults.standard.string(forKey: "quality").flatMap(QualityChoice.init) { quality = q }
        if let s = UserDefaults.standard.string(forKey: "source").flatMap(SourceChoice.init) { source = s }
        // A previous run that ended without restoring the output (crash, force quit).
        router.restoreIfNeeded()
        log.onLine = { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.logLines.append(line)
                if self.logLines.count > 300 { self.logLines.removeFirst(self.logLines.count - 300) }
            }
        }
        refreshDevices()
        if !apiAvailable { status = .failed(SessionError.privateAPIUnavailable.userMessage) }
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
        Task { await run(address: address) }
    }

    public func stop() {
        wantsStreaming = false
        guard let s = session else { status = .idle; return }
        status = .stopping
        Task {
            await s.stop()
            if session === s { session = nil }
            status = .idle
            stats = nil
            refreshDevices()
            await router.restore()
        }
    }

    private func run(address: String) async {
        guard let device = FDBTDevice(address: address) else { status = .failed(SessionError.deviceNotFound.userMessage); return }
        let s = StreamSession(device: device, helperPath: helperPath, log: log)
        s.mode = quality.mode
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
                if self.source == .system { self.router.routeToFidelis() }
            case .handingBack: if self.status != .stopping, !self.wantsStreaming { self.status = .stopping }
            case .ended: break
            }
        }
        s.onStats = { [weak self] st in self?.stats = st }
        s.onSinkDelay = { [weak self] us in
            guard let self else { return }
            self.sinkDelayUs = us
            self.updateLatency()
        }
        s.onUnexpectedEnd = { [weak self] why in
            guard let self, self.session === s else { return }
            self.session = nil
            self.stats = nil
            // `why` is for the log (StreamSession logged it); the menu gets a plain sentence.
            self.recover(address: address, why: String(localized: "Connection lost"))
        }
        do {
            let choice = source
            let log = log
            try await s.start { [weak self] rate in
                switch choice {
                case .system:
                    let src = SystemAudioSource(sampleRate: rate, log: log)
                    self?.systemSource = src
                    return src
                case .chime: return ChimeSource(sampleRate: rate)
                case .silence: return SilenceSource(sampleRate: rate)
                }
            }
            updateLatency()
            negotiated = s.negotiated
            if !wantsStreaming { await s.stop(); session = nil; status = .idle }
        } catch {
            log.error("start failed: \(error)")
            if session === s { session = nil }
            if wantsStreaming { recover(address: address, why: userMessage(for: error)) } else { status = .idle; await router.restore() }
        }
    }

    private weak var systemSource: SystemAudioSource?

    /// What the Fidelis device reports as its latency: our buffer, the send lead, and the
    /// headphones' own delay (reported, or a typical A2DP sink's when they don't say).
    private func updateLatency() {
        guard source == .system, let src = systemSource, let id = FidelisAudioDevice.id else { return }
        let total = src.bufferedMicroseconds + 10_000 + (sinkDelayUs ?? 150_000)
        router.setLatency(id, microseconds: total)
    }

    private func recover(address: String, why: String) {
        guard wantsStreaming else { status = .idle; Task { await router.restore() }; return }
        recoveries += 1
        guard recoveries <= 3 else {
            wantsStreaming = false
            status = .failed(why)
            refreshDevices()
            Task { await router.restore() }
            return
        }
        let delay = Double(recoveries) * 3
        status = .recovering(String(localized: "\(why) — retrying in \(Int(delay)) s"))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard wantsStreaming, session == nil else { return }
            await run(address: address)
        }
    }
}
