import Foundation
import CLDAC
import CLDACABR

/// LDAC quality rungs. libldac's documented EQMIDs are HQ/SQ/MQ (0/1/2); stepping with
/// ldacBT_alter_eqmid_priority also reaches the undocumented 492/396 rungs (EQMID 3 and 4).
public enum LDACQuality: Int, CaseIterable, Sendable, Comparable, Identifiable {
    // Ordered from most robust to highest quality.
    case kbps330 = 0, kbps396, kbps492, kbps660, kbps990

    public var id: Int { rawValue }
    public var eqmid: Int32 {
        switch self {
        case .kbps990: 0
        case .kbps660: 1
        case .kbps330: 2
        case .kbps492: 3
        case .kbps396: 4
        }
    }
    public var kbps: Int { [330, 396, 492, 660, 990][rawValue] }
    public var label: String { "\(kbps) kbps" }
    public var higher: LDACQuality? { LDACQuality(rawValue: rawValue + 1) }
    public var lower: LDACQuality? { LDACQuality(rawValue: rawValue - 1) }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Wraps one libldac encode handle. Not thread-safe; owned by the media thread.
public final class LDACEncoder {
    public static let blockFrames = Int(LDACBT_ENC_LSU)   // 128 PCM frames per encode call

    public let sampleRate: Int
    public let mtu: Int
    private var handle: HANDLE_LDAC_BT?
    private var out = [UInt8](repeating: 0, count: 1024)
    public private(set) var quality: LDACQuality

    public init?(sampleRate: Int, mtu: Int, quality: LDACQuality) {
        guard let h = ldacBT_get_handle() else { return nil }
        self.sampleRate = sampleRate; self.mtu = mtu; self.quality = quality
        // Start from a documented EQMID, then step to the requested rung.
        let start: LDACQuality = quality >= .kbps660 ? quality : .kbps330
        guard ldacBT_init_handle_encode(h, Int32(mtu), start.eqmid, Int32(LDACBT_CHANNEL_MODE_STEREO),
                                        LDACBT_SMPL_FMT_F32, Int32(sampleRate)) == 0 else {
            ldacBT_free_handle(h)
            return nil
        }
        handle = h
        self.quality = start
        setQuality(quality)
    }

    deinit { if let handle { ldacBT_free_handle(handle) } }

    /// Moves to `target` one rung at a time (libldac refuses to jump to EQMID 3/4 directly).
    public func setQuality(_ target: LDACQuality) {
        guard let handle else { return }
        while quality != target {
            let up = target > quality
            guard ldacBT_alter_eqmid_priority(handle, up ? Int32(LDACBT_EQMID_INC_QUALITY) : Int32(LDACBT_EQMID_INC_CONNECTION)) == 0 else { break }
            let eq = ldacBT_get_eqmid(handle)
            guard let q = LDACQuality.allCases.first(where: { $0.eqmid == eq }), q != quality else { break }
            quality = q
        }
    }

    /// One step of Sony's adaptive bitrate (see LDACABR) for `queueDepth` packets waiting to be
    /// sent, kept at or below `ceiling`. Returns true when the rung changed.
    @discardableResult
    func adapt(_ abr: LDACABR, queueDepth: Int, ceiling: LDACQuality) -> Bool {
        guard let handle else { return false }
        let before = quality
        _ = ldac_ABR_Proc(handle, abr.handle, UInt32(min(max(queueDepth, 0), 255)), 1)
        if let q = LDACQuality.allCases.first(where: { $0.eqmid == ldacBT_get_eqmid(handle) }) { quality = q }
        // Takes effect from the next frame, so a step above the ceiling is never heard.
        if quality > ceiling { setQuality(ceiling) }
        return quality != before
    }

    public var bitrateKbps: Int { handle.map { Int(ldacBT_get_bitrate($0)) } ?? 0 }

    /// Encodes one 128-frame interleaved Float32 stereo block. Returns a media payload (LDAC header
    /// byte + transport frames) when a packet is complete, otherwise nil.
    public func encode(_ pcm: UnsafeMutablePointer<Float>) -> (payload: [UInt8], frames: Int)? {
        guard let handle else { return nil }
        var used: Int32 = 0, wrote: Int32 = 0, frames: Int32 = 0
        let r = out.withUnsafeMutableBufferPointer { o in
            ldacBT_encode(handle, pcm, &used, o.baseAddress, &wrote, &frames)
        }
        guard r == 0, wrote > 0 else { return nil }
        var payload = [UInt8](repeating: 0, count: Int(wrote) + 1)
        payload[0] = UInt8(frames & 0x0f)
        payload.withUnsafeMutableBufferPointer { p in
            out.withUnsafeBufferPointer { o in
                (p.baseAddress! + 1).update(from: o.baseAddress!, count: Int(wrote))
            }
        }
        return (payload, Int(frames))
    }
}

/// Sony's LDAC adaptive bitrate (libldac/abr), as Android runs it for LDAC "best effort": called
/// every 20 ms with the number of packets waiting to be sent, it steps down as soon as that queue
/// grows (two rungs at once from 990/660 when it is critical) and climbs back only after seconds
/// with an empty queue, waiting longer each time a climb had to be undone.
final class LDACABR {
    static let intervalSeconds = 0.020
    let handle: HANDLE_LDAC_ABR

    init?() {
        guard let h = ldac_ABR_get_handle() else { return nil }
        guard ldac_ABR_Init(h, UInt32(Self.intervalSeconds * 1000)) == 0 else { ldac_ABR_free_handle(h); return nil }
        handle = h
    }

    deinit { ldac_ABR_free_handle(handle) }
}
