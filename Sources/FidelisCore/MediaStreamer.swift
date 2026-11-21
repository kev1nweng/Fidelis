import Foundation
import Darwin

/// Sends LDAC media packets in real time from a dedicated time-constraint thread.
public final class MediaStreamer: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public var seconds: Double = 0
        public var quality: LDACQuality = .kbps660
        public var kbps: Double = 0
        public var packetsPerSecond: Double = 0
        public var maxWriteMs: Double = 0
        public var lagMs: Double = 0
        public var qualityChanges = 0
        public var skips = 0
    }

    public enum EndReason: Sendable { case stopped, writeFailed(Int32), stalled(Double) }

    /// A write that cannot proceed for this long means the link is stuck. Left alone, the
    /// socket stays blocked for tens of seconds before failing with EPIPE; ending the session
    /// here lets the engine reconnect instead.
    public static let stallLimit = 3.0

    private let fd: Int32
    private let mtu: Int
    private let source: AudioSource
    private let log: Log
    private var controller: BitrateController
    private let lock = NSLock()
    private var pendingMode: BitrateController.Mode?
    private var thread: Thread?
    private let stopFlag = ManagedAtomicBool()
    private let done = DispatchSemaphore(value: 0)

    /// Called about once a second (from the media thread).
    public var onStats: (@Sendable (Stats) -> Void)?
    /// Called once when the stream ends (from the media thread).
    public var onEnd: (@Sendable (EndReason) -> Void)?

    public init(fd: Int32, mtu: Int, source: AudioSource, mode: BitrateController.Mode, log: Log) {
        self.fd = fd; self.mtu = mtu; self.source = source; self.log = log
        self.controller = BitrateController(mode: mode)
    }

    public func setMode(_ mode: BitrateController.Mode) { lock.withLock { pendingMode = mode } }

    public func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "fidelis.media"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops and waits for the thread to exit.
    public func stop() {
        guard thread != nil else { return }
        stopFlag.set(true)
        _ = done.wait(timeout: .now() + 2)
        thread = nil
    }

    // MARK: Media thread

    private func run() {
        defer { done.signal() }
        makeRealtime()
        let sampleRate = source.sampleRate
        guard let encoder = LDACEncoder(sampleRate: sampleRate, mtu: mtu, quality: controller.quality) else {
            log.error("LDAC encoder init failed (rate \(sampleRate), mtu \(mtu))")
            onEnd?(.writeFailed(EINVAL))
            return
        }
        log.info("media: LDAC \(encoder.bitrateKbps) kbps @ \(sampleRate) Hz, MTU \(mtu)")

        let block = LDACEncoder.blockFrames
        let pcm = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { pcm.deallocate() }
        var packet = [UInt8](repeating: 0, count: 1100)

        var seq: UInt16 = 0
        var rtpTimestamp: UInt32 = 0
        let t0 = Clock.now
        var framesSent = 0          // PCM frames covered by packets already written
        var pendingFrames = 0       // PCM frames fed into the encoder for the packet being built
        let leadSeconds = 0.010     // encode/send this far ahead of real time

        var stats = Stats(quality: encoder.quality)
        var winStart = Clock.now, winBytes = 0, winPackets = 0
        var winMaxWrite = 0.0, winMaxLag = 0.0
        var endReason: EndReason = .stopped

        while !stopFlag.get() {
            // Pace: the packet being built starts at framesSent; do not get more than `lead` ahead.
            let due = t0 + Double(framesSent) / Double(sampleRate)
            let now = Clock.now
            if due - leadSeconds > now {
                Clock.sleep(until: due - leadSeconds)
                continue
            }
            let lag = now - due
            if lag > 0.25 {
                // Far behind (stall): skip ahead rather than burst, so playback stays live.
                let skip = Int(lag * Double(sampleRate)) / block * block
                framesSent += skip
                rtpTimestamp &+= UInt32(skip)
                source.didSkip(frames: skip)
                stats.skips += 1
                log.warn("media: \(Int(lag * 1000)) ms behind, skipped \(skip) frames")
                continue
            }
            winMaxLag = max(winMaxLag, lag)

            source.render(pcm, frames: block)
            pendingFrames += block
            guard let (payload, _) = encoder.encode(pcm) else { continue }

            // RTP header (RFC 3550): V=2, PT=96, sequence, timestamp in PCM frames, SSRC 1.
            packet[0] = 0x80; packet[1] = 0x60
            packet[2] = UInt8(seq >> 8); packet[3] = UInt8(seq & 0xff)
            packet[4] = UInt8(rtpTimestamp >> 24); packet[5] = UInt8(rtpTimestamp >> 16 & 0xff)
            packet[6] = UInt8(rtpTimestamp >> 8 & 0xff); packet[7] = UInt8(rtpTimestamp & 0xff)
            packet[8] = 0; packet[9] = 0; packet[10] = 0; packet[11] = 1
            let len = 12 + payload.count
            packet.withUnsafeMutableBufferPointer { p in
                payload.withUnsafeBufferPointer { s in (p.baseAddress! + 12).update(from: s.baseAddress!, count: s.count) }
            }

            let w0 = Clock.now
            switch waitWritable(since: w0) {
            case .ready: break
            case .stopped: continue
            case .failed(let e):
                log.error("media: socket error: \(String(cString: strerror(e)))")
                endReason = .writeFailed(e)
            case .stalled:
                let secs = Clock.now - w0
                log.error("media: link stalled, no write for \(String(format: "%.1f", secs)) s")
                endReason = .stalled(secs)
            }
            if case .stopped = endReason {} else { break }
            let written = packet.withUnsafeBufferPointer { write(fd, $0.baseAddress, len) }
            let writeTime = Clock.now - w0
            if written < 0 {
                let e = errno
                if e == EINTR || e == EAGAIN { continue }
                log.error("media: write failed: \(String(cString: strerror(e)))")
                endReason = .writeFailed(e)
                break
            }
            winMaxWrite = max(winMaxWrite, writeTime)
            seq &+= 1
            rtpTimestamp &+= UInt32(pendingFrames)
            framesSent += pendingFrames
            pendingFrames = 0
            winBytes += len; winPackets += 1

            let wnow = Clock.now
            if wnow - winStart >= 1.0 {
                let dt = wnow - winStart
                stats.seconds = wnow - t0
                stats.kbps = Double(winBytes) * 8 / dt / 1000
                stats.packetsPerSecond = Double(winPackets) / dt
                stats.maxWriteMs = winMaxWrite * 1000
                stats.lagMs = winMaxLag * 1000
                if let m = lock.withLock({ () -> BitrateController.Mode? in defer { pendingMode = nil }; return pendingMode }) {
                    controller.mode = m
                    if controller.quality != encoder.quality { encoder.setQuality(controller.quality); stats.qualityChanges += 1 }
                }
                if let q = controller.observe(.init(maxWriteMs: stats.maxWriteMs, lagMs: stats.lagMs)) {
                    encoder.setQuality(q)
                    stats.qualityChanges += 1
                    log.info("media: rung -> \(q.label) (write \(String(format: "%.1f", stats.maxWriteMs)) ms, lag \(String(format: "%.1f", stats.lagMs)) ms)")
                }
                stats.quality = encoder.quality
                if Int(stats.seconds) % 5 == 0 {
                    log.debug(String(format: "media: %.0fs %@ %.0f kbps %.1f pkt/s write %.1f ms lag %.1f ms",
                                     stats.seconds, stats.quality.label, stats.kbps, stats.packetsPerSecond, stats.maxWriteMs, stats.lagMs))
                }
                onStats?(stats)
                winStart = wnow; winBytes = 0; winPackets = 0; winMaxWrite = 0; winMaxLag = 0
            }
        }
        onEnd?(endReason)
    }

    private enum WaitResult { case ready, stopped, failed(Int32), stalled }

    /// Waits until the socket can take a packet, so the blocking write below never sits on a
    /// stuck link for longer than `stallLimit`.
    private func waitWritable(since start: Double) -> WaitResult {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while true {
            if stopFlag.get() { return .stopped }
            pfd.revents = 0
            let r = poll(&pfd, 1, 100)
            if r > 0 {
                if pfd.revents & Int16(POLLOUT) != 0 { return .ready }
                if pfd.revents & Int16(POLLNVAL) != 0 { return .failed(EBADF) }
                return .failed(EPIPE)       // POLLERR / POLLHUP without POLLOUT
            }
            if r < 0, errno != EINTR, errno != EAGAIN { return .failed(errno) }
            if Clock.now - start >= Self.stallLimit { return .stalled }
        }
    }

    private func makeRealtime() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func abs(_ ns: Double) -> UInt32 { UInt32(ns * Double(tb.denom) / Double(tb.numer)) }
        var policy = thread_time_constraint_policy_data_t(
            period: abs(2_666_667),       // ~ one 128-frame block at 48 kHz
            computation: abs(500_000),
            constraint: abs(2_000_000),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                                  $0, count)
            }
        }
        if r != KERN_SUCCESS { log.warn("media: time-constraint policy refused (\(r))") }
    }
}

/// Monotonic seconds on the mach clock.
enum Clock {
    private static let tb: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    static var now: Double { Double(mach_absolute_time()) * Double(tb.numer) / Double(tb.denom) / 1e9 }
    static func sleep(until t: Double) {
        let ticks = UInt64(t * 1e9 * Double(tb.denom) / Double(tb.numer))
        mach_wait_until(ticks)
    }
}

/// Minimal atomic flag (avoids a dependency on swift-atomics).
final class ManagedAtomicBool: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func get() -> Bool { lock.withLock { value } }
    func set(_ v: Bool) { lock.withLock { value = v } }
}
