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
            case .auto: "Auto"
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
        case chime, silence
        public var id: String { rawValue }
        public var title: String { self == .chime ? "Test chime" : "Silence" }
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
    @Published public var source: SourceChoice = .chime
    @Published public private(set) var logLines: [Log.Line] = []

    public let log = Log()
    public let apiAvailable = FDBTDevice.privateAPIAvailable()
    private let helperPath: String
    private var session: StreamSession?
    private var wantsStreaming = false
    private var recoveries = 0

    public init(helperPath: String) {
        self.helperPath = helperPath
        selectedAddress = UserDefaults.standard.string(forKey: "selectedAddress")
        if let q = UserDefaults.standard.string(forKey: "quality").flatMap(QualityChoice.init) { quality = q }
        log.onLine = { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.logLines.append(line)
                if self.logLines.count > 300 { self.logLines.removeFirst(self.logLines.count - 300) }
            }
        }
        refreshDevices()
        if !apiAvailable { status = .failed("This macOS lacks the Bluetooth interfaces Fidelis uses") }
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

    public func toggle() {
        if wantsStreaming || status.isActive { stop() } else { start() }
    }

    public func start() {
        guard apiAvailable, session == nil, let address = selectedAddress else { return }
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
        }
    }

    private func run(address: String) async {
        guard let device = FDBTDevice(address: address) else { status = .failed("Headphones not found"); return }
        let s = StreamSession(device: device, helperPath: helperPath, log: log)
        s.mode = quality.mode
        session = s
        s.onPhase = { [weak self] phase in
            guard let self, self.session === s else { return }
            switch phase {
            case .takingOver(let n): self.status = .connecting(n == 1 ? "Taking over from macOS…" : "Taking over (attempt \(n))…")
            case .negotiating: self.status = .connecting("Negotiating LDAC…")
            case .openingMedia: self.status = .connecting("Opening audio channel…")
            case .streaming: self.status = .streaming; self.recoveries = 0
            case .handingBack: if self.status != .stopping, !self.wantsStreaming { self.status = .stopping }
            case .ended: break
            }
        }
        s.onStats = { [weak self] st in self?.stats = st }
        s.onUnexpectedEnd = { [weak self] why in
            guard let self, self.session === s else { return }
            self.session = nil
            self.stats = nil
            self.recover(address: address, why: why)
        }
        do {
            let src = source
            try await s.start { rate in
                src == .chime ? ChimeSource(sampleRate: rate) as AudioSource : SilenceSource(sampleRate: rate)
            }
            negotiated = s.negotiated
            if !wantsStreaming { await s.stop(); session = nil; status = .idle }
        } catch {
            log.error("start failed: \(error)")
            if session === s { session = nil }
            if wantsStreaming { recover(address: address, why: "\(error)") } else { status = .idle }
        }
    }

    private func recover(address: String, why: String) {
        guard wantsStreaming else { status = .idle; return }
        recoveries += 1
        guard recoveries <= 3 else {
            wantsStreaming = false
            status = .failed(why)
            refreshDevices()
            return
        }
        let delay = Double(recoveries) * 3
        status = .recovering("\(why) — retrying in \(Int(delay)) s")
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard wantsStreaming, session == nil else { return }
            await run(address: address)
        }
    }
}
