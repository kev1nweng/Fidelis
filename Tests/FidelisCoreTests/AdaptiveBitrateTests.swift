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

    /// Depth is PipeWire's: unsent bytes in units of 1280, rounded down.
    func testQueueDepthCountsUnsentBytesInUnitsOf1280() {
        XCTAssertEqual(LDACABR.depth(queuedBytes: 0), 0)
        XCTAssertEqual(LDACABR.depth(queuedBytes: 1279), 0)     // a packet on its way is not a queue
        XCTAssertEqual(LDACABR.depth(queuedBytes: 5119), 3)
        XCTAssertEqual(LDACABR.depth(queuedBytes: 5120), 4)
        XCTAssertEqual(LDACABR.depth(queuedBytes: 8192), 6)     // the whole socket: critical
    }

    /// A radio that looks away for a few packets' time and comes back (most of what the link does,
    /// 2026-11-21) is not a reason to leave 660 kbps.
    func testAShortHiccupAt660KeepsTheRung() throws {
        let enc = try XCTUnwrap(LDACEncoder(sampleRate: 48000, mtu: 679, quality: .kbps660))
        let abr = try XCTUnwrap(LDACABR())
        let packet = 672
        for _ in 0..<50 { enc.adapt(abr, queueDepth: LDACABR.depth(queuedBytes: 0), ceiling: .kbps660) }
        // Six packets (48 ms of audio) pile up, then drain over the next 100 ms.
        for queued in [2, 4, 6, 5, 4, 3, 2, 1, 0] {
            XCTAssertFalse(enc.adapt(abr, queueDepth: LDACABR.depth(queuedBytes: queued * packet), ceiling: .kbps660))
        }
        for _ in 0..<50 { enc.adapt(abr, queueDepth: 0, ceiling: .kbps660) }
        XCTAssertEqual(enc.quality, .kbps660)
    }

    /// A queue that reaches 5120 bytes at 660 kbps (about 60 ms behind) steps down at once.
    func testADeepQueueAt660StepsDown() throws {
        let enc = try XCTUnwrap(LDACEncoder(sampleRate: 48000, mtu: 679, quality: .kbps660))
        let abr = try XCTUnwrap(LDACABR())
        XCTAssertFalse(enc.adapt(abr, queueDepth: LDACABR.depth(queuedBytes: 5119), ceiling: .kbps660))
        XCTAssertTrue(enc.adapt(abr, queueDepth: LDACABR.depth(queuedBytes: 5120), ceiling: .kbps660))
        XCTAssertEqual(enc.quality, .kbps492)
    }

    /// A link that cannot carry the rung shows as a queue that stays: libldac steps down when its
    /// average over half a second is above 1.5, here four packets waiting all the time.
    func testAQueueThatStaysStepsDown() throws {
        let enc = try XCTUnwrap(LDACEncoder(sampleRate: 48000, mtu: 679, quality: .kbps660))
        let abr = try XCTUnwrap(LDACABR())
        var changed = false
        for _ in 0..<40 where !changed {      // 0.8 s
            changed = enc.adapt(abr, queueDepth: LDACABR.depth(queuedBytes: 4 * 672), ceiling: .kbps660)
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(enc.quality, .kbps492)
    }
}

final class ClimbBackoffTests: XCTestCase {
    func testAFailedClimbIsHeldOffLongerEachTime() {
        var b = ClimbBackoff()
        b.changed(from: .kbps492, to: .kbps660, at: 0)
        XCTAssertEqual(b.changed(from: .kbps660, to: .kbps492, at: 10), 30)
        XCTAssertEqual(b.ceiling(.kbps660, at: 39), .kbps492)
        XCTAssertEqual(b.ceiling(.kbps660, at: 40), .kbps660)
        b.changed(from: .kbps492, to: .kbps660, at: 45)
        XCTAssertEqual(b.changed(from: .kbps660, to: .kbps492, at: 50), 60)
        XCTAssertEqual(b.ceiling(.kbps660, at: 100), .kbps492)
    }

    func testARungThatHeldClearsItsRecord() {
        var b = ClimbBackoff()
        b.changed(from: .kbps492, to: .kbps660, at: 0)
        b.changed(from: .kbps660, to: .kbps492, at: 5)          // held off 30 s
        b.changed(from: .kbps492, to: .kbps660, at: 40)
        XCTAssertNil(b.changed(from: .kbps660, to: .kbps492, at: 100))   // held a minute: a real change
        b.changed(from: .kbps492, to: .kbps660, at: 110)
        XCTAssertEqual(b.changed(from: .kbps660, to: .kbps492, at: 115), 30)   // starts over
    }

    func testBlockedRungsStack() {
        var b = ClimbBackoff()
        b.changed(from: .kbps492, to: .kbps660, at: 0)
        b.changed(from: .kbps660, to: .kbps492, at: 1)
        b.changed(from: .kbps396, to: .kbps492, at: 2)
        b.changed(from: .kbps492, to: .kbps396, at: 3)
        XCTAssertEqual(b.ceiling(.kbps660, at: 10), .kbps396)
    }
}
