import Foundation
import FidelisBluetooth

public enum SignalingError: Error, CustomStringConvertible {
    case closed
    case timeout(AVDTP.Signal)
    case rejected(AVDTP.Signal, UInt8?)
    case malformed(AVDTP.Signal)

    public var description: String {
        switch self {
        case .closed: "signaling channel closed"
        case .timeout(let s): "\(s) timed out"
        case .rejected(let s, let e): "\(s) rejected" + (e.map { String(format: " (0x%02x)", $0) } ?? "")
        case .malformed(let s): "\(s) reply malformed"
        }
    }
}

/// AVDTP signaling over an L2CAP stream socket. All public methods are main-actor; reads happen on
/// a private queue and are delivered back to the main actor.
@MainActor
public final class SignalingChannel {
    public let channel: FDBTChannel
    /// Called for every command the sink sends us, after we answered it.
    public var onSinkCommand: ((AVDTP.Message) -> Void)?
    /// Called once when the socket hits EOF or an error.
    public var onClose: (() -> Void)?

    private let queue = DispatchQueue(label: "fidelis.signaling", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var nextLabel: UInt8 = 0
    private var pending: [UInt8: (signal: UInt8, cont: CheckedContinuation<AVDTP.Message, Error>)] = [:]
    private var isClosed = false
    private let log: Log

    public init(channel: FDBTChannel, log: Log) {
        self.channel = channel
        self.log = log
        let fd = channel.fd
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 2048)
            let n = read(fd, &buf, buf.count)
            let chunk: [UInt8]? = n > 0 ? Array(buf[0..<n]) : (n < 0 && (errno == EAGAIN || errno == EINTR) ? [] : nil)
            Task { @MainActor [weak self] in self?.received(chunk) }
        }
        readSource = source
        source.resume()
    }

    /// Note on framing: the socket is SOCK_STREAM, so message boundaries are not preserved by the
    /// API. In practice each read carries exactly one signaling message for our sizes (all well
    /// under the 672-byte signaling MTU). TODO: length-aware reassembly per signal type.
    private func received(_ chunk: [UInt8]?) {
        guard let chunk else { shutDown(); return }
        guard !chunk.isEmpty else { return }
        guard let msg = AVDTP.Message.decode(chunk) else {
            log.warn("AVDTP: undecodable packet [\(hex(chunk))]")
            return
        }
        if msg.type == .command {
            answer(msg)
            return
        }
        if let p = pending[msg.label], msg.type == .generalReject || p.signal == msg.signalID {
            pending[msg.label] = nil
            p.cont.resume(returning: msg)
        } else {
            log.debug("AVDTP: stray reply label \(msg.label) signal \(msg.signalID) type \(msg.type)")
        }
    }

    private func answer(_ cmd: AVDTP.Message) {
        let reply: AVDTP.Message
        switch cmd.signal {
        case .delayReport, .suspend, .start, .close, .abort:
            reply = AVDTP.Message(label: cmd.label, type: .accept, signal: cmd.signalID)
        default:
            // We register no endpoints of our own, so anything else is not supported.
            reply = AVDTP.Message(label: cmd.label, type: .reject, signal: cmd.signalID,
                                  payload: [AVDTP.ErrorCode.notSupportedCommand.rawValue])
        }
        writeRaw(reply.encoded())
        onSinkCommand?(cmd)
    }

    private func writeRaw(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { p in _ = write(channel.fd, p.baseAddress, p.count) }
    }

    public func send(_ signal: AVDTP.Signal, _ payload: [UInt8] = [], timeout: TimeInterval = 3) async throws -> AVDTP.Message {
        guard !isClosed else { throw SignalingError.closed }
        let label = nextLabel
        nextLabel = (nextLabel + 1) & 0x0f
        let msg = AVDTP.Message(label: label, type: .command, signal: signal.rawValue, payload: payload)
        let reply: AVDTP.Message = try await withCheckedThrowingContinuation { cont in
            pending[label] = (signal.rawValue, cont)
            writeRaw(msg.encoded())
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let p = self.pending[label] else { return }
                self.pending[label] = nil
                p.cont.resume(throwing: SignalingError.timeout(signal))
            }
        }
        switch reply.type {
        case .accept: return reply
        case .reject: throw SignalingError.rejected(signal, reply.payload.last)
        default: throw SignalingError.rejected(signal, nil)
        }
    }

    // MARK: Convenience

    public func discover(timeout: TimeInterval = 3) async throws -> [AVDTP.Endpoint] {
        AVDTP.Endpoint.parseDiscover(try await send(.discover, timeout: timeout).payload)
    }

    public func capabilities(of seid: UInt8) async throws -> [AVDTP.Capability] {
        let reply: AVDTP.Message
        do {
            reply = try await send(.getAllCapabilities, [seid << 2])
        } catch SignalingError.rejected {
            reply = try await send(.getCapabilities, [seid << 2])
        }
        guard let caps = AVDTP.Capability.parseList(reply.payload) else { throw SignalingError.malformed(.getAllCapabilities) }
        return caps
    }

    public func close() {
        shutDown()
        channel.close()
    }

    private func shutDown() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        let waiting = pending
        pending = [:]
        for (_, p) in waiting { p.cont.resume(throwing: SignalingError.closed) }
        onClose?()
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
