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

    public var description: String {
        switch self {
        case .privateAPIUnavailable: "This macOS version lacks the Bluetooth interfaces Fidelis needs"
        case .deviceNotFound: "Headphones not found"
        case .takeoverFailed(let why): "Could not take the headphones from macOS: \(why)"
        case .noLDAC: "These headphones do not offer LDAC"
        case .unsupportedFormat: "No common LDAC format"
        case .mediaChannel(let code): "Could not open the audio channel (code \(code))"
        case .signaling(let e): e.description
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
    private var media: FDBTChannel?
    private var streamer: MediaStreamer?
    private var source: AudioSource?
    private var seid: UInt8 = 0
    private var stopping = false
    public private(set) var negotiated: Negotiated?

    public var preferredSampleRate = 48000
    public var mode: BitrateController.Mode = .adaptive(ceiling: .kbps660) {
        didSet { streamer?.setMode(mode) }
    }

    public init(device: FDBTDevice, helperPath: String, log: Log) {
        self.device = device; self.helperPath = helperPath; self.log = log
    }

    // MARK: Start

    public func start(source makeSource: (Int) -> AudioSource) async throws {
        guard FDBTDevice.privateAPIAvailable() else { throw SessionError.privateAPIUnavailable }
        let sig = try await Takeover(device: device, helperPath: helperPath, log: log) { [weak self] n in
            self?.onPhase?(.takingOver(attempt: n))
        }.acquireSignaling()
        signaling = sig
        sig.onSinkCommand = { [weak self] cmd in self?.sinkCommand(cmd) }
        sig.onClose = { [weak self] in self?.lost("signaling channel closed") }

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

        onPhase?(.openingMedia)
        let (channel, code) = await openMedia()
        guard let channel else {
            _ = try? await sig.send(.abort, [seid << 2], timeout: 2)
            await teardown()
            throw SessionError.mediaChannel(code)
        }
        media = channel
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
        s.onStats = { [weak self] st in Task { @MainActor in self?.onStats?(st) } }
        s.onEnd = { [weak self] reason in
            Task { @MainActor in
                if case .writeFailed(let e) = reason { self?.lost("media write failed: \(String(cString: strerror(e)))") }
            }
        }
        streamer = s
        s.start()
        onPhase?(.streaming)
        log.info("streaming LDAC to \(device.name)")
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
        signaling?.onClose = nil
        signaling?.close()
        signaling = nil
        if handBack {
            onPhase?(.handingBack)
            await Takeover.handBack(device, log: log)
        }
        onPhase?(.ended)
    }
}
