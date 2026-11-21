import Foundation
import FidelisBluetooth

/// Takes the AVDTP signaling channel from macOS.
///
/// The sink treats the first L2CAP channel on PSM 0x19 as signaling and later ones as media
/// (AVDTP 1.3 §5.4), so we must be first on the air after the link comes up; bluetoothd starts its
/// own A2DP within milliseconds of ACL-up. A channel that does not answer DISCOVER lost that race.
///
/// Each attempt opens signaling from a fresh helper process: a request that never answers leaves
/// its client session busy (code 24) for good, and a fresh process is a fresh session.
@MainActor
struct Takeover {
    let device: FDBTDevice
    let helperPath: String
    let log: Log
    let onAttempt: (Int) -> Void
    var maxAttempts = 6
    /// Checked between attempts: the session was stopped, give up.
    var isCancelled: () -> Bool = { false }

    init(device: FDBTDevice, helperPath: String, log: Log, onAttempt: @escaping (Int) -> Void) {
        self.device = device; self.helperPath = helperPath; self.log = log; self.onAttempt = onAttempt
    }

    func acquireSignaling() async throws -> SignalingChannel {
        var lastWhy = "unknown"
        for attempt in 1...maxAttempts {
            guard !isCancelled() else { throw SessionError.cancelled }
            onAttempt(attempt)
            if device.isConnected {
                // closeConnection only drops the link for a client that asked for it, so register
                // our interest first (returns at once on a link that is already up).
                _ = await withCheckedContinuation { cont in device.openConnection { cont.resume(returning: $0) } }
                device.closeConnection()
                if !(await waitFor(timeout: 15) { !device.isConnected }) {
                    log.warn("takeover \(attempt): link still up after 15 s")
                }
                try? await Task.sleep(for: .milliseconds(800))
            }
            // The helper pages the device itself and opens PSM 0x19 the moment the link is up.
            let t0 = Date()
            let (channel, code): (FDBTChannel?, Int) = await withCheckedContinuation { cont in
                device.openL2CAPChannel(viaHelper: helperPath, psm: 0x19, timeout: 10) { ch, code in
                    cont.resume(returning: (ch, code))
                }
            }
            if isCancelled() {
                channel?.close()
                throw SessionError.cancelled
            }
            guard let channel else {
                lastWhy = "open failed (code \(code))"
                log.warn("takeover \(attempt): \(lastWhy)")
                try? await Task.sleep(for: .seconds(backoff(attempt)))
                continue
            }
            let sig = SignalingChannel(channel: channel, log: log)
            let eps = try? await sig.discover(timeout: 2.0)
            if isCancelled() { sig.close(); throw SessionError.cancelled }
            if let eps, !eps.isEmpty {
                log.info("takeover \(attempt): signaling is ours after \(String(format: "%.2f", Date().timeIntervalSince(t0))) s (\(eps.count) endpoints)")
                return sig
            }
            lastWhy = "macOS won the signaling race"
            log.warn("takeover \(attempt): \(lastWhy)")
            sig.close()
            try? await Task.sleep(for: .seconds(backoff(attempt)))
        }
        throw SessionError.takeoverFailed(lastWhy)
    }

    private func backoff(_ attempt: Int) -> Double { min(4, 0.5 * Double(attempt)) }

    /// Drops our link and reconnects so macOS's own profiles come back.
    static func handBack(_ device: FDBTDevice, log: Log) async {
        if device.isConnected {
            _ = await withCheckedContinuation { cont in device.openConnection { cont.resume(returning: $0) } }
            device.closeConnection()
            _ = await waitFor(timeout: 15) { !device.isConnected }
        }
        try? await Task.sleep(for: .milliseconds(1500))
        for i in 1...3 {
            let status: Int32 = await withCheckedContinuation { cont in
                device.openConnection { cont.resume(returning: $0) }
            }
            if device.isConnected { log.info("handed \(device.name) back to macOS"); return }
            log.warn("hand-back reconnect \(i) failed (0x\(String(UInt32(bitPattern: status), radix: 16)))")
            try? await Task.sleep(for: .seconds(1))
        }
        log.error("could not reconnect \(device.name) to macOS; reconnect it from the Bluetooth menu")
    }
}

@MainActor
func waitFor(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return true
}
