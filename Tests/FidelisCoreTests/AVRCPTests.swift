import XCTest
@testable import FidelisCore

final class AVRCPTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    func testCommandsWeSend() {
        XCTAssertEqual(AVRCP.setAbsoluteVolume(label: 1, 0x26), hex("10 11 0E 00 48 00 00 19 58 50 00 00 01 26"))
        XCTAssertEqual(AVRCP.setAbsoluteVolume(label: 1, 0xFF).last, 0x7F)
        XCTAssertEqual(AVRCP.registerVolumeNotification(label: 2),
                       hex("20 11 0E 03 48 00 00 19 58 31 00 00 05 0D 00 00 00 00"))
    }

    func testVolumeNotifications() {
        XCTAssertEqual(AVRCP.interpret(hex("12 11 0E 0F 48 00 00 19 58 31 00 00 02 0D 17")), .volume(0x17, interim: true))
        XCTAssertEqual(AVRCP.interpret(hex("12 11 0E 0D 48 00 00 19 58 31 00 00 02 0D 40")), .volume(0x40, interim: false))
        XCTAssertEqual(AVRCP.interpret(hex("12 11 0E 0A 48 00 00 19 58 31 00 00 01 01")), .volumeUnsupported)
        XCTAssertEqual(AVRCP.interpret(hex("12 11 0E 09 48 00 00 19 58 50 00 00 01 26")), .volumeSet(0x26))
        XCTAssertEqual(AVRCP.interpret(hex("12 11 0E 0A 48 00 00 19 58 50 00 00 01 00")), .volumeSet(nil))
    }

    /// Measured by CodecBlue: GET CAPABILITIES and a notification arrived in one read.
    func testReassembly() {
        var b = hex("10 11 0E 01 48 00 00 19 58 10 00 00 01 03 12 11 0E 0F 48 00 00 19 58 31 00 00 02 0D 17")
        XCTAssertEqual(AVRCP.frameLength(b), 14)
        b.removeFirst(14)
        XCTAssertEqual(AVRCP.frameLength(b), 15)
        XCTAssertNil(AVRCP.frameLength(Array(b.prefix(12))))
        XCTAssertNil(AVRCP.frameLength(Array(b.prefix(14))))
        XCTAssertEqual(AVRCP.frameLength(hex("20 11 0E 00 48 7C 44 00 30 11 0E")), 8)
        XCTAssertEqual(AVRCP.frameLength(hex("21 11 0F")), 3)
    }

    func testRepliesToTheHeadphones() {
        guard case .command(let caps, nil, nil) = AVRCP.interpret(hex("10 11 0E 01 48 00 00 19 58 10 00 00 01 03")) else {
            return XCTFail("no reply")
        }
        XCTAssertEqual(caps, hex("12 11 0E 0C 48 00 00 19 58 10 00 00 02 03 00"))

        guard case .command(let company, nil, nil) = AVRCP.interpret(hex("30 11 0E 01 48 00 00 19 58 10 00 00 01 02")) else {
            return XCTFail("no reply")
        }
        XCTAssertEqual(company, hex("32 11 0E 0C 48 00 00 19 58 10 00 00 05 02 01 00 19 58"))

        XCTAssertEqual(AVRCP.interpret(hex("40 11 0E 00 48 7C 44 00")),
                       .command(reply: hex("42 11 0E 09 48 7C 44 00"), key: .play, volume: nil))
        // Release: answered, not a key press.
        XCTAssertEqual(AVRCP.interpret(hex("40 11 0E 00 48 7C C4 00")),
                       .command(reply: hex("42 11 0E 09 48 7C C4 00"), key: nil, volume: nil))
        XCTAssertEqual(AVRCP.interpret(hex("50 11 0E 00 48 7C 41 00")),
                       .command(reply: hex("52 11 0E 08 48 7C 41 00"), key: nil, volume: nil))

        // Volume pushed by the headphones as a command.
        XCTAssertEqual(AVRCP.interpret(hex("60 11 0E 00 48 00 00 19 58 50 00 00 01 33")),
                       .command(reply: hex("62 11 0E 09 48 00 00 19 58 50 00 00 01 33"), key: nil, volume: 0x33))
        // Unknown PDU: REJECTED, invalid command.
        XCTAssertEqual(AVRCP.interpret(hex("70 11 0E 03 48 00 00 19 58 31 00 00 05 01 00 00 00 00")),
                       .command(reply: hex("72 11 0E 0A 48 00 00 19 58 31 00 00 01 00"), key: nil, volume: nil))
        // Wrong profile: IPID.
        XCTAssertEqual(AVRCP.interpret(hex("80 11 0F 00 48 7C 44 00")), .command(reply: hex("83 11 0F"), key: nil, volume: nil))
    }
}
