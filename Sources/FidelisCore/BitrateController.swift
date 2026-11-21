import Foundation

/// Chooses the LDAC rung. M0 showed that overrunning the link does not lose packets, it stalls
/// the socket for tens of seconds and then drops the link, so the controller steps down on the
/// first sign of backpressure and climbs back slowly.
public struct BitrateController: Sendable {
    public enum Mode: Equatable, Sendable {
        /// Adapt between the lowest rung and `ceiling`. `aggressive` runs libldac ABR as Android
        /// does, without ClimbBackoff: it retries a higher rung every few seconds.
        case adaptive(ceiling: LDACQuality, aggressive: Bool = false)
        /// Hold one rung (still steps down in an emergency, and returns afterwards).
        case fixed(LDACQuality)
    }

    /// One second of sender statistics.
    public struct Window: Sendable {
        public var maxWriteMs: Double
        public var lagMs: Double        // how late the sender was against real time, at worst
        public init(maxWriteMs: Double, lagMs: Double) { self.maxWriteMs = maxWriteMs; self.lagMs = lagMs }
        /// Thresholds: at a sustainable rate M0 measured 0.0 ms writes; at an unsustainable one
        /// 20–50 ms. The socket holds ~12 packets (~96 ms at 660 kbps).
        public var congested: Bool { maxWriteMs > 8 || lagMs > 25 }
    }

    public private(set) var quality: LDACQuality
    public var mode: Mode { didSet { clampToMode() } }
    private var cleanSeconds = 0
    private var blockedUntil: [LDACQuality: Int] = [:]   // rung -> clock second it may be retried
    private var penalty: [LDACQuality: Int] = [:]        // rung -> current back-off seconds
    private var clock = 0

    public static let climbAfterSeconds = 15

    public init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .adaptive(let c, _): quality = min(c, .kbps660)
        case .fixed(let q): quality = q
        }
    }

    private var target: LDACQuality {
        switch mode {
        case .adaptive(let c, _): c
        case .fixed(let q): q
        }
    }

    private mutating func clampToMode() {
        if quality > target { quality = target }
        if case .fixed(let q) = mode { quality = q }
    }

    /// Feeds one window; returns the new rung if it changed.
    public mutating func observe(_ w: Window) -> LDACQuality? {
        clock += 1
        if w.congested {
            cleanSeconds = 0
            guard let lower = quality.lower else { return nil }
            let back = min(240, (penalty[quality] ?? 15) * 2)
            penalty[quality] = back
            blockedUntil[quality] = clock + back
            quality = lower
            return quality
        }
        cleanSeconds += 1
        guard cleanSeconds >= Self.climbAfterSeconds, quality < target, let higher = quality.higher,
              clock >= (blockedUntil[higher] ?? 0) else { return nil }
        cleanSeconds = 0
        quality = higher
        return quality
    }
}

/// Holds libldac ABR back from climbs that keep failing. Its own back-off waits at most four
/// times longer after an undone climb, so on a link that carries one rung but not the next it
/// tries the higher rung every few seconds, and each try backs the queue up (heard as a glitch,
/// and on headphones that pace playback by their buffer level, as a wobble in speed). A rung
/// left within `failWithin` of reaching it is kept off for `firstHold`, doubling with each
/// failure up to `maxHold`; one held for longer clears its record.
struct ClimbBackoff {
    static let failWithin = 30.0
    static let firstHold = 30.0
    static let maxHold = 600.0

    private var reachedAt: [LDACQuality: Double] = [:]
    private var hold: [LDACQuality: Double] = [:]
    private var blockedUntil: [LDACQuality: Double] = [:]

    /// The rung went from `old` to `new` at time `t` (seconds); returns how long `old` is now
    /// kept off, if it is.
    @discardableResult
    mutating func changed(from old: LDACQuality, to new: LDACQuality, at t: Double) -> Double? {
        if new > old { reachedAt[new] = t; return nil }
        guard new < old, let reached = reachedAt[old] else { return nil }
        reachedAt[old] = nil
        guard t - reached < Self.failWithin else { hold[old] = nil; return nil }
        let h = min(Self.maxHold, hold[old].map { $0 * 2 } ?? Self.firstHold)
        hold[old] = h
        blockedUntil[old] = t + h
        return h
    }

    /// The highest rung allowed at time `t`, at most `ceiling`.
    func ceiling(_ ceiling: LDACQuality, at t: Double) -> LDACQuality {
        var c = ceiling
        while let until = blockedUntil[c], t < until, let lower = c.lower { c = lower }
        return c
    }
}
