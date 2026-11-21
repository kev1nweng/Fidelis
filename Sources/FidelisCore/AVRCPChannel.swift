import Foundation
import FidelisBluetooth

/// Holds the headphones' AVRCP channel while Fidelis streams: sets their own volume and reports
/// what their buttons do. Main-actor; reads happen on a private queue.
@MainActor
public final class AVRCPChannel {
    public let channel: FDBTChannel
    /// The headphones' volume, 0…1: first the value they report when we register, then every
    /// change made on the headphones themselves.
    public var onVolume: ((Float, _ initial: Bool) -> Void)?
    /// The headphones refused volume notifications, or never answered: no absolute volume.
    public var onVolumeUnsupported: (() -> Void)?
    public var onKey: ((AVRCP.Key) -> Void)?
    public var onClose: (() -> Void)?

    private let queue = DispatchQueue(label: "fidelis.avrcp", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var pending: [UInt8] = []
    private var nextLabel: UInt8 = 0
    private var isClosed = false
    private var gotVolume = false
    private var lastSent: UInt8?
    private let log: Log

    public init(channel: FDBTChannel, log: Log) {
        self.channel = channel
        self.log = log
        let fd = channel.fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = read(fd, &buf, buf.count)
            let chunk: [UInt8]? = n > 0 ? Array(buf[0..<n]) : (n < 0 && (errno == EAGAIN || errno == EINTR) ? [] : nil)
            Task { @MainActor [weak self] in self?.received(chunk) }
        }
        readSource = source
        source.resume()
    }

    /// Asks for the headphones' volume and its changes. Gives up after `timeout` without an answer.
    public func start(timeout: TimeInterval = 2) {
        send(AVRCP.registerVolumeNotification(label: label()))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !self.isClosed, !self.gotVolume else { return }
            self.log.warn("avrcp: no volume answer in \(Int(timeout)) s")
            self.onVolumeUnsupported?()
        }
    }

    /// Sets the headphones' own volume, 0…1 (repeats of the last value are not sent).
    public func setVolume(_ value: Float) {
        let v = UInt8((min(max(value, 0), 1) * 127).rounded())
        guard v != lastSent else { return }
        lastSent = v
        send(AVRCP.setAbsoluteVolume(label: label(), v))
    }

    public func close() {
        shutDown()
        channel.close()
    }

    private func label() -> UInt8 {
        defer { nextLabel = (nextLabel + 1) & 0x0F }
        return nextLabel
    }

    private func received(_ chunk: [UInt8]?) {
        guard let chunk else { shutDown(); return }
        pending += chunk
        while let n = AVRCP.frameLength(pending), n > 0 {
            let frame = Array(pending[0..<n])
            pending.removeFirst(n)
            handle(frame)
        }
    }

    private func handle(_ frame: [UInt8]) {
        switch AVRCP.interpret(frame) {
        case .volume(let v, let interim):
            if !interim {
                // A notification is used up by CHANGED: register again for the next one.
                send(AVRCP.registerVolumeNotification(label: label()))
            }
            let initial = !gotVolume
            gotVolume = true
            lastSent = v
            log.info("avrcp: headphone volume \(Int((Float(v) / 127 * 100).rounded()))%\(initial ? "" : " (changed on the headphones)")")
            onVolume?(Float(v) / 127, initial)
        case .volumeUnsupported:
            log.warn("avrcp: headphones refused volume notifications")
            gotVolume = true   // answered; stops the timeout from firing as well
            onVolumeUnsupported?()
        case .volumeSet(let v):
            if let v { log.info("avrcp: headphones set to \(Int((Float(v) / 127 * 100).rounded()))%") }
            else { log.warn("avrcp: SET ABSOLUTE VOLUME refused") }
        case .command(let reply, let key, let volume):
            send(reply)
            if let key { log.info("avrcp: headphone button \(key.rawValue)"); onKey?(key) }
            if let volume { lastSent = volume; onVolume?(Float(volume) / 127, false) }
        case .ignored:
            break
        }
    }

    private func send(_ bytes: [UInt8]) {
        guard !isClosed else { return }
        var off = 0
        // A stream socket may take part of a frame; resume, never resend. Frames are tiny, so a
        // full buffer is a dead link: give up after a few tries rather than block the main actor.
        var tries = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { write(channel.fd, $0.baseAddress! + off, bytes.count - off) }
            if n > 0 { off += n; continue }
            if n < 0, errno == EAGAIN || errno == EINTR, tries < 20 { tries += 1; usleep(1000); continue }
            log.warn("avrcp: write failed (\(n < 0 ? String(cString: strerror(errno)) : "0 bytes"))")
            shutDown()
            return
        }
    }

    private func shutDown() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        onClose?()
    }
}
