import Foundation

/// AVDTP 1.3 signaling: message framing and service-capability encoding.
public enum AVDTP {
    public enum Signal: UInt8, Sendable {
        case discover = 0x01, getCapabilities, setConfiguration, getConfiguration, reconfigure,
             open, start, close, suspend, abort, securityControl, getAllCapabilities, delayReport
    }

    public enum MessageType: UInt8, Sendable {
        case command = 0, generalReject = 1, accept = 2, reject = 3
    }

    /// Error codes (AVDTP 1.3 §8.20.6.2) we send or care about.
    public enum ErrorCode: UInt8, Sendable {
        case badHeaderFormat = 0x01, badLength = 0x11, badACPSEID = 0x12, sepInUse = 0x13,
             sepNotInUse = 0x14, badServiceCategory = 0x17, badPayloadFormat = 0x18,
             notSupportedCommand = 0x19, badState = 0x31
    }

    /// One signaling message (single-packet form; fragmentation is not used for our sizes).
    public struct Message: Equatable, Sendable {
        public var label: UInt8
        public var type: MessageType
        public var signalID: UInt8
        public var payload: [UInt8]

        public var signal: Signal? { Signal(rawValue: signalID) }

        public init(label: UInt8, type: MessageType, signal: UInt8, payload: [UInt8] = []) {
            self.label = label & 0x0f; self.type = type; self.signalID = signal & 0x3f; self.payload = payload
        }

        public func encoded() -> [UInt8] {
            [label << 4 | type.rawValue, signalID] + payload
        }

        /// Parses one message. Returns nil for fragmented packets (packet type != single).
        public static func decode(_ bytes: [UInt8]) -> Message? {
            guard bytes.count >= 2 else { return nil }
            let packetType = (bytes[0] >> 2) & 0x3
            guard packetType == 0, let type = MessageType(rawValue: bytes[0] & 0x3) else { return nil }
            return Message(label: bytes[0] >> 4, type: type, signal: bytes[1] & 0x3f, payload: Array(bytes[2...]))
        }
    }

    public struct Endpoint: Equatable, Sendable {
        public var seid: UInt8
        public var inUse: Bool
        public var mediaType: UInt8   // 0 = audio
        public var isSink: Bool

        public static func parseDiscover(_ payload: [UInt8]) -> [Endpoint] {
            stride(from: 0, to: payload.count - 1, by: 2).map { i in
                Endpoint(seid: payload[i] >> 2, inUse: (payload[i] >> 1) & 1 == 1,
                         mediaType: payload[i + 1] >> 4, isSink: (payload[i + 1] >> 3) & 1 == 1)
            }
        }
    }

    /// A service capability TLV.
    public struct Capability: Equatable, Sendable {
        public enum Category: UInt8, Sendable {
            case mediaTransport = 1, reporting, recovery, contentProtection, headerCompression,
                 multiplexing, mediaCodec, delayReporting
        }
        public var category: UInt8
        public var value: [UInt8]

        public static func parseList(_ bytes: [UInt8]) -> [Capability]? {
            var out: [Capability] = []
            var i = 0
            while i < bytes.count {
                guard i + 1 < bytes.count else { return nil }
                let len = Int(bytes[i + 1])
                guard i + 2 + len <= bytes.count else { return nil }
                out.append(Capability(category: bytes[i], value: Array(bytes[(i + 2)..<(i + 2 + len)])))
                i += 2 + len
            }
            return out
        }

        public static func encodeList(_ caps: [Capability]) -> [UInt8] {
            caps.flatMap { [$0.category, UInt8($0.value.count)] + $0.value }
        }
    }
}

/// The LDAC media codec element (vendor 0x0000012D, codec 0x00AA).
public struct LDACCodecInfo: Equatable, Sendable {
    public static let vendorID: UInt32 = 0x0000_012D
    public static let codecID: UInt16 = 0x00AA

    public struct SampleRates: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let hz44100 = SampleRates(rawValue: 0x20)
        public static let hz48000 = SampleRates(rawValue: 0x10)
        public static let hz88200 = SampleRates(rawValue: 0x08)
        public static let hz96000 = SampleRates(rawValue: 0x04)
        public static let hz176400 = SampleRates(rawValue: 0x02)
        public static let hz192000 = SampleRates(rawValue: 0x01)

        public static func rate(_ hz: Int) -> SampleRates? {
            switch hz {
            case 44100: .hz44100
            case 48000: .hz48000
            case 88200: .hz88200
            case 96000: .hz96000
            case 176400: .hz176400
            case 192000: .hz192000
            default: nil
            }
        }

        public var hertz: [Int] {
            [(Self.hz44100, 44100), (.hz48000, 48000), (.hz88200, 88200), (.hz96000, 96000),
             (.hz176400, 176400), (.hz192000, 192000)].filter { contains($0.0) }.map(\.1)
        }
    }

    public struct ChannelModes: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let mono = ChannelModes(rawValue: 0x04)
        public static let dual = ChannelModes(rawValue: 0x02)
        public static let stereo = ChannelModes(rawValue: 0x01)
    }

    public var sampleRates: SampleRates
    public var channelModes: ChannelModes

    public init(sampleRates: SampleRates, channelModes: ChannelModes) {
        self.sampleRates = sampleRates; self.channelModes = channelModes
    }

    /// Finds LDAC in a capability list.
    public static func find(in caps: [AVDTP.Capability]) -> LDACCodecInfo? {
        for c in caps where c.category == AVDTP.Capability.Category.mediaCodec.rawValue {
            let v = c.value
            guard v.count >= 10, v[1] == 0xFF else { continue }
            let vendor = UInt32(v[2]) | UInt32(v[3]) << 8 | UInt32(v[4]) << 16 | UInt32(v[5]) << 24
            let codec = UInt16(v[6]) | UInt16(v[7]) << 8
            guard vendor == vendorID, codec == codecID else { continue }
            return LDACCodecInfo(sampleRates: SampleRates(rawValue: v[8] & 0x3f), channelModes: ChannelModes(rawValue: v[9] & 0x07))
        }
        return nil
    }

    /// The media codec capability for SET_CONFIGURATION (exactly one rate and one mode set).
    public var capability: AVDTP.Capability {
        let vendor = Self.vendorID, codec = Self.codecID
        let value: [UInt8] = [0x00 /* audio */, 0xFF /* non-A2DP */,
                              UInt8(vendor & 0xff), UInt8(vendor >> 8 & 0xff), UInt8(vendor >> 16 & 0xff), UInt8(vendor >> 24),
                              UInt8(codec & 0xff), UInt8(codec >> 8), sampleRates.rawValue, channelModes.rawValue]
        return AVDTP.Capability(category: AVDTP.Capability.Category.mediaCodec.rawValue, value: value)
    }
}

/// Human-readable names for the codecs a sink advertises (diagnostics only).
public func describeCodec(_ cap: AVDTP.Capability) -> String {
    let v = cap.value
    guard v.count >= 2 else { return "codec?" }
    switch v[1] {
    case 0x00: return "SBC"
    case 0x01: return "MPEG-1,2"
    case 0x02: return "AAC"
    case 0xFF where v.count >= 8:
        let vendor = UInt32(v[2]) | UInt32(v[3]) << 8 | UInt32(v[4]) << 16 | UInt32(v[5]) << 24
        let codec = UInt16(v[6]) | UInt16(v[7]) << 8
        switch (vendor, codec) {
        case (0x012D, 0x00AA): return "LDAC"
        case (0x004F, 0x0001): return "aptX"
        case (0x00D7, 0x0024): return "aptX HD"
        case (0x00D7, 0x00AD): return "aptX Adaptive"
        case (0x053A, _): return "LHDC"
        default: return String(format: "vendor %04x/%04x", vendor, codec)
        }
    default: return String(format: "codec 0x%02x", v[1])
    }
}
