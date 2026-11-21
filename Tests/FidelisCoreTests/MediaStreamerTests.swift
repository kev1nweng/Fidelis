import XCTest
import Darwin
import Synchronization
@testable import FidelisCore

final class MediaStreamerTests: XCTestCase {
    /// A peer that never reads fills the socket; the streamer must give up after
    /// `stallLimit` instead of blocking in write() indefinitely.
    func testStalledSocketEndsTheStream() throws {
        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }
        var size: Int32 = 4096
        setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))

        let streamer = MediaStreamer(fd: sv[0], mtu: 679, source: SilenceSource(sampleRate: 48000),
                                     mode: .fixed(.kbps330), log: Log())
        let ended = expectation(description: "stream ended")
        let box = ReasonBox()
        streamer.onEnd = { reason in box.reason = reason; ended.fulfill() }
        let t0 = Date()
        streamer.start()
        wait(for: [ended], timeout: MediaStreamer.stallLimit + 5)
        streamer.stop()

        guard case .stalled(let secs)? = box.reason else { return XCTFail("ended with \(String(describing: box.reason))") }
        XCTAssertGreaterThanOrEqual(secs, MediaStreamer.stallLimit)
        XCTAssertLessThan(Date().timeIntervalSince(t0), MediaStreamer.stallLimit + 3)
    }

    /// A closed peer is a failure, not a stall.
    func testClosedPeerFailsQuickly() throws {
        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        var on: Int32 = 1
        setsockopt(sv[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        close(sv[1])
        defer { close(sv[0]) }

        let streamer = MediaStreamer(fd: sv[0], mtu: 679, source: SilenceSource(sampleRate: 48000),
                                     mode: .fixed(.kbps330), log: Log())
        let ended = expectation(description: "stream ended")
        let box = ReasonBox()
        streamer.onEnd = { reason in box.reason = reason; ended.fulfill() }
        streamer.start()
        wait(for: [ended], timeout: 2)
        streamer.stop()

        guard case .writeFailed? = box.reason else { return XCTFail("ended with \(String(describing: box.reason))") }
    }

    /// With a cushion the streamer reads that much ahead of real time, and no further.
    func testSendsTheCushionAhead() throws {
        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }
        let reader = Thread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while read(sv[1], &buf, buf.count) > 0 {}
        }
        reader.start()

        let src = CountingSource(sampleRate: 48000)
        let streamer = MediaStreamer(fd: sv[0], mtu: 679, source: src, mode: .fixed(.kbps330), log: Log())
        streamer.cushionSeconds = 0.2
        streamer.cushionGrowth = 1   // built in about 0.2 s here; 10 s in use
        let t0 = Date()
        streamer.start()
        Thread.sleep(forTimeInterval: 1.0)
        let elapsed = Date().timeIntervalSince(t0)
        let ahead = Double(src.frames.load(ordering: .relaxed)) / 48000 - elapsed
        streamer.stop()
        XCTAssertGreaterThan(ahead, 0.15)
        XCTAssertLessThan(ahead, 0.26)
    }
}

private final class CountingSource: AudioSource, @unchecked Sendable {
    let sampleRate: Int
    let frames = Atomic<Int>(0)
    init(sampleRate: Int) { self.sampleRate = sampleRate }
    func render(_ buffer: UnsafeMutablePointer<Float>, frames n: Int) {
        buffer.update(repeating: 0, count: n * 2)
        frames.add(n, ordering: .relaxed)
    }
    func start() throws {}
    func stop() {}
}

private final class ReasonBox: @unchecked Sendable {
    var reason: MediaStreamer.EndReason?
}
