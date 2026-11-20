import Foundation
import CLDAC

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
                                        LDACBT_SMPL_FMT_S16, Int32(sampleRate)) == 0 else {
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

    public var bitrateKbps: Int { handle.map { Int(ldacBT_get_bitrate($0)) } ?? 0 }

    /// Encodes one 128-frame interleaved S16 stereo block. Returns a media payload (LDAC header
    /// byte + transport frames) when a packet is complete, otherwise nil.
    public func encode(_ pcm: UnsafeMutablePointer<Int16>) -> (payload: [UInt8], frames: Int)? {
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
