import Foundation
import FidelisBluetooth

public enum SessionError: Error, CustomStringConvertible {
    case privateAPIUnavailable
    case deviceNotFound
    case takeoverFailed(String)
    case noLDAC
    case unsupportedFormat
    case mediaChannel(Int)
    case signaling(SignalingError)
    /// Their microphone is in use (a call): macOS holds them in the hands-free profile.
    case headphonesInCall
    /// stop() was called before streaming began.
    case cancelled

    public var description: String {
        switch self {
        case .privateAPIUnavailable: "This macOS version lacks the Bluetooth interfaces Fidelis needs"
        case .deviceNotFound: "Headphones not found"
        case .takeoverFailed(let why): "Could not take the headphones from macOS: \(why)"
        case .noLDAC: "These headphones do not offer LDAC"
        case .unsupportedFormat: "No common LDAC format"
        case .mediaChannel(let code): "Could not open the audio channel (code \(code))"
        case .signaling(let e): e.description
        case .headphonesInCall: "The headphones' microphone is in use (a call)"
        case .cancelled: "Stopped before streaming began"
        }
    }
}

/// One LDAC streaming session to one pair of headphones: take them from macOS, negotiate, stream,
/// hand them back. Main-actor; the media itself runs on MediaStreamer's thread.
@MainActor
public final class StreamSession {
    public enum Phase: Equatable, Sendable {
        case takingOver(attempt: Int)
        case negotiating
        case openingMedia
        case streaming
        case handingBack
        case ended
    }

    public struct Negotiated: Sendable, Equatable {
        public var sampleRate: Int
        public var codecs: [String]
        public var mtu: Int
    }

    public let device: FDBTDevice
    public let helperPath: String
    private let log: Log
    public var onPhase: ((Phase) -> Void)?
    public var onStats: ((MediaStreamer.Stats) -> Void)?
    /// The headphones' own playback delay (AVDTP delay report), in microseconds.
    public var onSinkDelay: ((Int) -> Void)?
    /// The session ended without stop() being called (link loss, write failure).
    public var onUnexpectedEnd: ((String) -> Void)?

    private var signaling: SignalingChannel?
    /// The headphones' AVRCP channel, if we got it (their own volume). Nil when macOS kept it.
    public private(set) var avrcp: AVRCPChannel?
    private var media: FDBTChannel?
    private var streamer: MediaStreamer?
    private var source: AudioSource?
    private var seid: UInt8 = 0
    private var stopping = false
    /// The takeover has begun dropping and paging the link, so stopping must hand it back.
    private var touchedLink = false
    private var starting = false
    public private(set) var negotiated: Negotiated?

    public var preferredSampleRate = 48000
    /// Audio sent ahead into the headphones' buffer (MediaStreamer.cushionSeconds). The SIMGOT
    /// EH500 holds writes for 100–300 ms several times a minute (2026-11-20), each heard as a
    /// tear with the old 10 ms lead.
    public static let cushionSeconds = 0.2
    public var cushionSeconds = StreamSession.cushionSeconds
    public var mode: BitrateController.Mode = .adaptive(ceiling: .kbps660) {
        didSet { streamer?.setMode(mode) }
    }

    /// FIDELIS_AVRCP=1: try to hold AVRCP and drive the headphones' volume over it (see start).
    /// Otherwise their volume is lifted to 100% before the takeover (OutputRouter).
    nonisolated static let usesAVRCP = ProcessInfo.processInfo.environment["FIDELIS_AVRCP"] == "1"

    public init(device: FDBTDevice, helperPath: String, log: Log) {
        self.device = device; self.helperPath = helperPath; self.log = log
    }

    // MARK: Start

    public func start(source makeSource: (Int) -> AudioSource) async throws {
        starting = true
        defer { starting = false }
        do {
            try await startSteps(makeSource)
        } catch {
            // stop() during start() leaves the hand-back to us: one hand-back, after whatever
            // the step in flight (a takeover attempt can take the link again) has done.
            guard stopping else { throw error }
            await teardown(handBack: true)
            throw SessionError.cancelled
        }
    }

    private func startSteps(_ makeSource: (Int) -> AudioSource) async throws {
        guard FDBTDevice.privateAPIAvailable() else { throw SessionError.privateAPIUnavailable }
        try bailIfStopped()
        touchedLink = true
        var takeover = Takeover(device: device, helperPath: helperPath, log: log) { [weak self] n in
            self?.onPhase?(.takingOver(attempt: n))
        }
        takeover.isCancelled = { [weak self] in self?.stopping ?? true }
        let sig = try await takeover.acquireSignaling()
        signaling = sig
        try bailIfStopped()
        sig.onSinkCommand = { [weak self] cmd in self?.sinkCommand(cmd) }
        sig.onClose = { [weak self] in self?.lost("signaling channel closed") }
        // AVRCP (the headphones' own volume). Off by default: when the takeover reconnects the
        // link, bluetoothd opens its own AVRCP the instant the link is up (measured 2026-11-20,
        // 54 ms before our request), and the request then hangs until its timeout. Taking over in
        // place, which would leave AVRCP free, does not work on the SIMGOT EH500: it drops the
        // link itself about 1 s after macOS closes its profiles. FIDELIS_AVRCP=1 tries anyway.
        let wantsAVRCP = Self.usesAVRCP
        let avrcpOpen = Task { @MainActor [weak self] in wantsAVRCP ? await self?.openAVRCP() ?? nil : nil }

        onPhase?(.negotiating)
        do {
            try await negotiate(sig)
        } catch let e as SignalingError {
            await teardown()
            throw SessionError.signaling(e)
        } catch {
            await teardown()
            throw error
        }

        if let ch = await avrcpOpen.value {
            if stopping { ch.close() } else { avrcp = AVRCPChannel(channel: ch, log: log) }
        }
        try bailIfStopped()

        onPhase?(.openingMedia)
        let (channel, code) = await openMedia()
        guard let channel else {
            _ = try? await sig.send(.abort, [seid << 2], timeout: 2)
            await teardown()
            throw SessionError.mediaChannel(code)
        }
        media = channel
        try bailIfStopped()
        negotiated?.mtu = Int(channel.outMTU)
        do {
            _ = try await sig.send(.start, [seid << 2])
        } catch let e as SignalingError {
            await teardown()
            throw SessionError.signaling(e)
        }

        let rate = negotiated?.sampleRate ?? preferredSampleRate
        let src = makeSource(rate)
        do {
            try src.start()
        } catch {
            _ = try? await sig.send(.suspend, [seid << 2], timeout: 1.5)
            _ = try? await sig.send(.close, [seid << 2], timeout: 1.5)
            await teardown()
            throw error
        }
        source = src
        let s = MediaStreamer(fd: channel.fd, mtu: Int(channel.outMTU), source: src, mode: mode, log: log)
        s.cushionSeconds = cushionSeconds
        s.onStats = { [weak self] st in Task { @MainActor in self?.onStats?(st) } }
        s.onEnd = { [weak self] reason in
            Task { @MainActor in
                switch reason {
                case .stopped: break
                case .writeFailed(let e): self?.lost("media write failed: \(String(cString: strerror(e)))")
                case .stalled(let secs): self?.lost("media link stalled for \(String(format: "%.1f", secs)) s")
                }
            }
        }
        streamer = s
        s.start()
        onPhase?(.streaming)
        log.info("streaming LDAC to \(device.name)")
    }

    /// After each wait in start(): stop() came meanwhile (start() then tears down).
    private func bailIfStopped() throws {
        if stopping { throw SessionError.cancelled }
    }

    private func negotiate(_ sig: SignalingChannel) async throws {
        let endpoints = try await sig.discover()
        var codecs: [String] = []
        var chosen: (UInt8, LDACCodecInfo, Bool)?
        for ep in endpoints where ep.isSink && ep.mediaType == 0 {
            let caps = try await sig.capabilities(of: ep.seid)
            if let c = caps.first(where: { $0.category == AVDTP.Capability.Category.mediaCodec.rawValue }) {
                codecs.append(describeCodec(c))
            }
            if chosen == nil, !ep.inUse, let ldac = LDACCodecInfo.find(in: caps) {
                let delayReporting = caps.contains { $0.category == AVDTP.Capability.Category.delayReporting.rawValue }
                chosen = (ep.seid, ldac, delayReporting)
            }
        }
        log.info("sink endpoints: \(codecs.joined(separator: ", "))")
        guard let (seid, offered, delayReporting) = chosen else { throw SessionError.noLDAC }
        let rates = offered.sampleRates.hertz
        guard offered.channelModes.contains(.stereo),
              let rate = rates.contains(preferredSampleRate) ? preferredSampleRate : rates.first(where: { $0 <= 96000 }),
              let rateBit = LDACCodecInfo.SampleRates.rate(rate) else { throw SessionError.unsupportedFormat }
        self.seid = seid

        let config = LDACCodecInfo(sampleRates: rateBit, channelModes: .stereo)
        var caps = [AVDTP.Capability(category: AVDTP.Capability.Category.mediaTransport.rawValue, value: []), config.capability]
        // With delay reporting the headphones tell us their playback delay, which the Fidelis
        // device then reports as its latency (lip sync).
        if delayReporting { caps.append(AVDTP.Capability(category: AVDTP.Capability.Category.delayReporting.rawValue, value: [])) }
        _ = try await sig.send(.setConfiguration, [seid << 2, 1 << 2] + AVDTP.Capability.encodeList(caps))
        _ = try await sig.send(.open, [seid << 2])
        negotiated = Negotiated(sampleRate: rate, codecs: codecs, mtu: 0)
        log.info("configured LDAC \(rate) Hz stereo on SEID \(seid)\(delayReporting ? ", delay reporting" : "")")
    }

    private func openAVRCP() async -> FDBTChannel? {
        await withCheckedContinuation { cont in
            let t0 = Date()
            device.openL2CAPChannel(viaHelper: helperPath, psm: AVRCP.psm, timeout: 5) { [log] ch, code in
                let dt = String(format: "%.1f", Date().timeIntervalSince(t0))
                if ch != nil { log.info("avrcp: channel held after \(dt) s") }
                else { log.warn("avrcp: not available (code \(code), \(dt) s); volume stays in software") }
                cont.resume(returning: ch)
            }
        }
    }

    private func openMedia() async -> (FDBTChannel?, Int) {
        await withCheckedContinuation { cont in
            let t0 = Date()
            device.openL2CAPChannel(viaHelper: helperPath, psm: 0x19, timeout: 30) { [log] ch, code in
                log.info("media channel: \(ch != nil ? "open" : "failed (\(code))") after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                cont.resume(returning: (ch, code))
            }
        }
    }

    private func sinkCommand(_ cmd: AVDTP.Message) {
        log.info("sink sent \(cmd.signal.map { "\($0)" } ?? "signal \(cmd.signalID)")")
        switch cmd.signal {
        case .delayReport where cmd.payload.count >= 3:
            // Delay in 1/10 ms, big-endian, after the ACP SEID (AVDTP 1.3 §8.19).
            let tenthsMs = Int(cmd.payload[1]) << 8 | Int(cmd.payload[2])
            log.info("headphones report \(Double(tenthsMs) / 10) ms playback delay")
            onSinkDelay?(tenthsMs * 100)
        case .close, .abort: lost("headphones closed the stream")
        default: break
        }
    }

    private func lost(_ why: String) {
        guard !stopping else { return }
        log.warn("session lost: \(why)")
        stopping = true
        Task { @MainActor in
            await teardown(handBack: true)
            onUnexpectedEnd?(why)
        }
    }

    // MARK: Stop

    public func stop() async {
        guard !stopping else { return }
        stopping = true
        if starting {
            // start() notices between steps, tears down and hands back; wait for that.
            _ = await waitFor(timeout: 90) { !starting }
            return
        }
        streamer?.stop()
        streamer = nil
        if let sig = signaling, seid != 0 {
            _ = try? await sig.send(.suspend, [seid << 2], timeout: 1.5)
            _ = try? await sig.send(.close, [seid << 2], timeout: 1.5)
        }
        await teardown(handBack: true)
    }

    private func teardown(handBack: Bool = true) async {
        streamer?.stop()
        streamer = nil
        source?.stop()
        source = nil
        media?.close()
        media = nil
        avrcp?.close()
        avrcp = nil
        signaling?.onClose = nil
        signaling?.close()
        signaling = nil
        if handBack, touchedLink {
            touchedLink = false
            onPhase?(.handingBack)
            await Takeover.handBack(device, log: log)
        }
        onPhase?(.ended)
    }
}
