import XCTest
@testable import FidelisCore

final class AVDTPTests: XCTestCase {
    func testMessageRoundTrip() {
        let m = AVDTP.Message(label: 5, type: .command, signal: AVDTP.Signal.setConfiguration.rawValue, payload: [0x0c, 0x04])
        XCTAssertEqual(m.encoded(), [0x50, 0x03, 0x0c, 0x04])
        XCTAssertEqual(AVDTP.Message.decode(m.encoded()), m)
    }

    func testFragmentedPacketsAreRejected() {
        XCTAssertNil(AVDTP.Message.decode([0x54, 0x03]))   // packet type 01 (start)
    }

    func testDiscoverParsing() {
        // Captured from a SIMGOT EH500: five free audio sinks.
        let eps = AVDTP.Endpoint.parseDiscover([0x04, 0x08, 0x08, 0x08, 0x0c, 0x08, 0x10, 0x08, 0x14, 0x08])
        XCTAssertEqual(eps.map(\.seid), [1, 2, 3, 4, 5])
        XCTAssertTrue(eps.allSatisfy { $0.isSink && !$0.inUse && $0.mediaType == 0 })
    }

    func testLDACCapabilityFromEH500() throws {
        // GET_ALL_CAPABILITIES payload for SEID 3 on the EH500.
        let payload: [UInt8] = [0x01, 0x00, 0x07, 0x0a, 0x00, 0xff, 0x2d, 0x01, 0x00, 0x00, 0xaa, 0x00, 0x3c, 0x07]
        let caps = try XCTUnwrap(AVDTP.Capability.parseList(payload))
        let ldac = try XCTUnwrap(LDACCodecInfo.find(in: caps))
        XCTAssertEqual(ldac.sampleRates.hertz, [44100, 48000, 88200, 96000])
        XCTAssertTrue(ldac.channelModes.contains(.stereo))
        XCTAssertEqual(describeCodec(caps[1]), "LDAC")
    }

    func testLDACConfigurationEncoding() {
        let cfg = LDACCodecInfo(sampleRates: .hz48000, channelModes: .stereo).capability
        XCTAssertEqual(AVDTP.Capability.encodeList([cfg]),
                       [0x07, 0x0a, 0x00, 0xff, 0x2d, 0x01, 0x00, 0x00, 0xaa, 0x00, 0x10, 0x01])
    }

    func testTruncatedCapabilityListIsRejected() {
        XCTAssertNil(AVDTP.Capability.parseList([0x07, 0x0a, 0x00]))
    }
}

final class BitrateControllerTests: XCTestCase {
    private let clean = BitrateController.Window(maxWriteMs: 0, lagMs: 1)
    private let congested = BitrateController.Window(maxWriteMs: 30, lagMs: 40)

    func testAdaptiveStartsAt660AndStepsDownOnCongestion() {
        var c = BitrateController(mode: .adaptive(ceiling: .kbps990))
        XCTAssertEqual(c.quality, .kbps660)
        XCTAssertEqual(c.observe(congested), .kbps492)
        XCTAssertEqual(c.observe(congested), .kbps396)
    }

    func testClimbsBackAfterCleanPeriodButNotIntoBlockedRung() {
        var c = BitrateController(mode: .adaptive(ceiling: .kbps660))
        _ = c.observe(congested)                     // 660 -> 492, 660 blocked for 30 s
        for _ in 0..<BitrateController.climbAfterSeconds { XCTAssertNil(c.observe(clean)) }
        XCTAssertEqual(c.quality, .kbps492)          // still blocked at 16 s
        var climbed: LDACQuality?
        for _ in 0..<40 { if let q = c.observe(clean) { climbed = q } }
        XCTAssertEqual(climbed, .kbps660)
    }

    func testNeverExceedsCeiling() {
        var c = BitrateController(mode: .adaptive(ceiling: .kbps660))
        for _ in 0..<200 { _ = c.observe(clean) }
        XCTAssertEqual(c.quality, .kbps660)
    }

    func testLowestRungHolds() {
        var c = BitrateController(mode: .fixed(.kbps330))
        XCTAssertNil(c.observe(congested))
        XCTAssertEqual(c.quality, .kbps330)
    }
}

final class LDACEncoderTests: XCTestCase {
    func testEncodesSilenceIntoMTUSizedPackets() throws {
        let enc = try XCTUnwrap(LDACEncoder(sampleRate: 48000, mtu: 679, quality: .kbps660))
        XCTAssertEqual(enc.bitrateKbps, 660)
        let pcm = UnsafeMutablePointer<Int16>.allocate(capacity: 256)
        defer { pcm.deallocate() }
        pcm.update(repeating: 0, count: 256)
        var packets = 0
        for _ in 0..<64 {
            if let (payload, frames) = enc.encode(pcm) {
                packets += 1
                XCTAssertLessThanOrEqual(payload.count, 679 - 12)
                XCTAssertEqual(Int(payload[0]), frames)
            }
        }
        XCTAssertGreaterThan(packets, 10)
    }

    func testReachesUndocumentedRungs() throws {
        let enc = try XCTUnwrap(LDACEncoder(sampleRate: 48000, mtu: 679, quality: .kbps492))
        XCTAssertEqual(enc.quality, .kbps492)
        enc.setQuality(.kbps396)
        XCTAssertEqual(enc.quality, .kbps396)
        enc.setQuality(.kbps990)
        XCTAssertEqual(enc.quality, .kbps990)
    }
}
