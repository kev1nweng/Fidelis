import XCTest
import Darwin
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
}

private final class ReasonBox: @unchecked Sendable {
    var reason: MediaStreamer.EndReason?
}
