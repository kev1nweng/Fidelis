import XCTest
@testable import FidelisCore

final class AdaptiveBitrateTests: XCTestCase {
    /// The queue depth reads through the low-water mark on a local stream socket, as the
    /// bluetoothd media socket is.
    func testReadsTheSendQueueOfALocalSocket() throws {
        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }
        var sb: Int32 = 8192
        setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &sb, socklen_t(MemoryLayout<Int32>.size))
        let q = SendQueue(fd: sv[0])
        XCTAssertTrue(q.probes)
        XCTAssertEqual(q.queuedBytes(), 0)
        let bytes = [UInt8](repeating: 0, count: 3000)
        XCTAssertEqual(bytes.withUnsafeBufferPointer { write(sv[0], $0.baseAddress, 3000) }, 3000)
        XCTAssertEqual(Double(q.queuedBytes()), 3000, accuracy: 200)
        var sink = [UInt8](repeating: 0, count: 3000)
        _ = sink.withUnsafeMutableBufferPointer { read(sv[1], $0.baseAddress, 3000) }
        XCTAssertEqual(q.queuedBytes(), 0)
        // The probe leaves writes as they were: a small write still goes straight through.
        XCTAssertEqual(bytes.withUnsafeBufferPointer { write(sv[0], $0.baseAddress, 10) }, 10)
    }

    /// Sony's ABR: down at once on a critical queue (two rungs from 660), back up only after an
    /// empty queue for a while, and never above the ceiling.
    func testStepsDownAtOnceAndClimbsNoHigherThanTheCeiling() throws {
        let enc = try XCTUnwrap(LDACEncoder(sampleRate: 48000, mtu: 679, quality: .kbps660))
        let abr = try XCTUnwrap(LDACABR())
        XCTAssertTrue(enc.adapt(abr, queueDepth: 7, ceiling: .kbps660))
        XCTAssertEqual(enc.quality, .kbps396)
        var highest = enc.quality
        for _ in 0..<(60 * 50) {           // 60 s of 20 ms steps with an empty queue
            enc.adapt(abr, queueDepth: 0, ceiling: .kbps660)
            highest = max(highest, enc.quality)
        }
        XCTAssertEqual(enc.quality, .kbps660)
        XCTAssertEqual(highest, .kbps660)
    }
}
