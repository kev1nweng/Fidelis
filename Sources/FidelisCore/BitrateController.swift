import Foundation

/// Chooses the LDAC rung. M0 showed that overrunning the link does not lose packets, it stalls
/// the socket for tens of seconds and then drops the link, so the controller steps down on the
/// first sign of backpressure and climbs back slowly.
public struct BitrateController: Sendable {
    public enum Mode: Equatable, Sendable {
        /// Adapt between the lowest rung and `ceiling`.
        case adaptive(ceiling: LDACQuality)
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
        case .adaptive(let c): quality = min(c, .kbps660)
        case .fixed(let q): quality = q
        }
    }

    private var target: LDACQuality {
        switch mode {
        case .adaptive(let c): c
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
