import Foundation

/// The part of AVRCP (over AVCTP, PSM 0x17) Fidelis needs: setting the headphones' own volume
/// (AVRCP 1.4 absolute volume), hearing about changes their buttons make, and answering what they
/// ask us so they keep the channel up.
///
/// While Fidelis streams, macOS has no audio device for the headphones, so nothing sets their
/// volume and it stays wherever macOS left it. Holding this channel lets the Fidelis slider move
/// it instead of scaling the samples.
///
/// The frame layouts follow the AVRCP 1.6 and AV/C Panel Subunit specifications. CodecBlue's
/// AVCTPHolder (MIT, github.com/PaoloAlbano/CodecBlue) documents which mistakes headphones
/// answer REJECTED to; the stream reassembly rule comes from there.
public enum AVRCP {
    public static let psm: UInt16 = 0x17
    static let profileID: UInt16 = 0x110E
    /// PANEL subunit (type 9), id 0.
    static let panel: UInt8 = 0x48
    static let bluetoothSIG: [UInt8] = [0x00, 0x19, 0x58]
    static let eventVolumeChanged: UInt8 = 0x0D

    public enum CType: UInt8, Sendable {
        case control = 0x00, status = 0x01, notify = 0x03
        case notImplemented = 0x08, accepted = 0x09, rejected = 0x0A, stable = 0x0C, changed = 0x0D, interim = 0x0F
    }

    enum Opcode: UInt8 { case vendorDependent = 0x00, unitInfo = 0x30, subunitInfo = 0x31, passThrough = 0x7C }
    enum PDU: UInt8 { case getCapabilities = 0x10, registerNotification = 0x31, setAbsoluteVolume = 0x50 }

    /// A button on the headphones (PASS THROUGH press).
    public enum Key: String, Sendable { case play, pause, stop, next, previous }

    /// One AVCTP single packet carrying an AV/C frame.
    struct Frame: Equatable {
        var label: UInt8
        var isResponse: Bool
        var invalidProfile: Bool
        var profile: UInt16
        var ctype: UInt8
        var subunit: UInt8
        var opcode: UInt8
        var operands: [UInt8]

        init?(_ b: [UInt8]) {
            guard b.count >= 3 else { return nil }
            label = b[0] >> 4
            isResponse = b[0] & 0x02 != 0
            invalidProfile = b[0] & 0x01 != 0
            profile = UInt16(b[1]) << 8 | UInt16(b[2])
            guard b.count >= 6 else {
                guard invalidProfile else { return nil }
                ctype = 0; subunit = 0; opcode = 0; operands = []
                return
            }
            ctype = b[3] & 0x0F
            subunit = b[4]
            opcode = b[5]
            operands = Array(b[6...])
        }

        /// For vendor dependent frames: PDU, then its parameters (after company id, PDU, packet
        /// type and the two-byte length).
        var vendorPDU: (pdu: UInt8, params: [UInt8])? {
            guard opcode == Opcode.vendorDependent.rawValue, operands.count >= 7,
                  Array(operands[0..<3]) == AVRCP.bluetoothSIG else { return nil }
            let length = Int(operands[5]) << 8 | Int(operands[6])
            let params = Array(operands.dropFirst(7).prefix(length))
            return (operands[3], params)
        }
    }

    // MARK: Building

    static func packet(label: UInt8, response: Bool, ctype: UInt8, subunit: UInt8 = panel,
                       opcode: UInt8, operands: [UInt8]) -> [UInt8] {
        [(label & 0x0F) << 4 | (response ? 0x02 : 0x00), UInt8(profileID >> 8), UInt8(profileID & 0xFF),
         ctype, subunit, opcode] + operands
    }

    static func vendor(label: UInt8, response: Bool = false, ctype: CType, pdu: UInt8, params: [UInt8]) -> [UInt8] {
        packet(label: label, response: response, ctype: ctype.rawValue, opcode: Opcode.vendorDependent.rawValue,
               operands: bluetoothSIG + [pdu, 0x00, UInt8(params.count >> 8), UInt8(params.count & 0xFF)] + params)
    }

    /// SET ABSOLUTE VOLUME, 0…127.
    static func setAbsoluteVolume(label: UInt8, _ volume: UInt8) -> [UInt8] {
        vendor(label: label, ctype: .control, pdu: PDU.setAbsoluteVolume.rawValue, params: [volume & 0x7F])
    }

    /// REGISTER NOTIFICATION for VOLUME CHANGED. Answered INTERIM with the volume now, then
    /// CHANGED once when it changes; each CHANGED needs a new registration.
    static func registerVolumeNotification(label: UInt8) -> [UInt8] {
        vendor(label: label, ctype: .notify, pdu: PDU.registerNotification.rawValue,
               params: [eventVolumeChanged, 0, 0, 0, 0])
    }

    // MARK: Reassembly

    /// Length of the frame at the start of `b`, or nil until enough has arrived. The socket is
    /// SOCK_STREAM, so one read can carry part of a frame or several; frames are cut by the
    /// length their own layout implies.
    static func frameLength(_ b: [UInt8]) -> Int? {
        guard b.count >= 3 else { return nil }
        if b[0] & 0x01 != 0 { return 3 }                 // IPID: header only
        guard b[0] & 0x0C == 0 else { return b.count }    // fragmented AVCTP: not used by our peers
        guard b.count >= 6 else { return nil }
        switch b[5] {
        case Opcode.vendorDependent.rawValue:
            guard b.count >= 13 else { return nil }
            let total = 13 + (Int(b[11]) << 8 | Int(b[12]))
            return total <= b.count ? total : nil
        case Opcode.passThrough.rawValue:
            guard b.count >= 8 else { return nil }
            let total = 8 + Int(b[7])
            return total <= b.count ? total : nil
        case Opcode.unitInfo.rawValue, Opcode.subunitInfo.rawValue:
            return b.count >= 11 ? 11 : nil
        default:
            return b.count
        }
    }

    // MARK: Reading

    /// What an incoming frame means to us.
    enum Event: Equatable {
        /// The headphones' volume (0…127): `interim` answers a registration, otherwise it changed.
        case volume(UInt8, interim: Bool)
        /// Our registration was refused: no absolute volume on these headphones.
        case volumeUnsupported
        /// The answer to SET ABSOLUTE VOLUME: the volume they actually set, or nil if refused.
        case volumeSet(UInt8?)
        /// A command from the headphones, with the reply to send and the key it carried, if any.
        case command(reply: [UInt8], key: Key?, volume: UInt8?)
        case ignored
    }

    static func interpret(_ b: [UInt8]) -> Event {
        guard let f = Frame(b) else { return .ignored }
        if f.isResponse {
            guard let (pdu, params) = f.vendorPDU else { return .ignored }
            let ok = f.ctype == CType.interim.rawValue || f.ctype == CType.changed.rawValue
                || f.ctype == CType.accepted.rawValue || f.ctype == CType.stable.rawValue
            switch PDU(rawValue: pdu) {
            case .registerNotification:
                guard ok else { return .volumeUnsupported }
                guard params.count >= 2, params[0] == eventVolumeChanged else { return .ignored }
                return .volume(params[1] & 0x7F, interim: f.ctype == CType.interim.rawValue)
            case .setAbsoluteVolume:
                return .volumeSet(ok && !params.isEmpty ? params[0] & 0x7F : nil)
            default:
                return .ignored
            }
        }
        if f.profile != profileID {
            return .command(reply: [(f.label << 4) | 0x03, b[1], b[2]], key: nil, volume: nil)
        }
        return reply(to: f)
    }

    /// The reply to a command from the headphones (they are a controller too: they ask what we
    /// support, and their transport buttons arrive as PASS THROUGH).
    static func reply(to f: Frame) -> Event {
        func answer(_ ctype: CType, _ operands: [UInt8]) -> [UInt8] {
            packet(label: f.label, response: true, ctype: ctype.rawValue, subunit: f.subunit, opcode: f.opcode, operands: operands)
        }
        switch Opcode(rawValue: f.opcode) {
        case .unitInfo:
            return .command(reply: answer(.stable, [0x07, panel] + bluetoothSIG), key: nil, volume: nil)
        case .subunitInfo:
            return .command(reply: answer(.stable, [0x07, panel, 0xFF, 0xFF, 0xFF]), key: nil, volume: nil)
        case .passThrough:
            guard let op = f.operands.first else { return .ignored }
            let names: [UInt8: Key] = [0x44: .play, 0x46: .pause, 0x45: .stop, 0x4B: .next, 0x4C: .previous]
            let key = names[op & 0x7F]
            // Release (high bit) is answered like the press, but only the press is a key.
            return .command(reply: answer(key != nil ? .accepted : .notImplemented, f.operands),
                            key: op & 0x80 == 0 ? key : nil, volume: nil)
        case .vendorDependent:
            guard let (pdu, params) = f.vendorPDU else {
                return .command(reply: answer(.notImplemented, f.operands), key: nil, volume: nil)
            }
            func vendorReply(_ ctype: CType, _ p: [UInt8]) -> [UInt8] {
                vendor(label: f.label, response: true, ctype: ctype, pdu: pdu, params: p)
            }
            switch PDU(rawValue: pdu) {
            case .getCapabilities:
                // Company ids: only the SIG's. Events we can notify: none.
                let list: [UInt8] = params.first == 0x02 ? [0x02, 0x01] + bluetoothSIG : [params.first ?? 0x03, 0x00]
                return .command(reply: vendorReply(.stable, list), key: nil, volume: nil)
            case .setAbsoluteVolume where !params.isEmpty:
                // Some headphones push their volume this way instead of notifying.
                let v = params[0] & 0x7F
                return .command(reply: vendorReply(.accepted, [v]), key: nil, volume: v)
            default:
                // REJECTED with "invalid command" (0x00), as AVRCP asks for an unknown PDU.
                return .command(reply: vendorReply(.rejected, [0x00]), key: nil, volume: nil)
            }
        case nil:
            return .command(reply: answer(.notImplemented, f.operands), key: nil, volume: nil)
        }
    }
}
