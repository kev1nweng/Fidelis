import Darwin

/// How many bytes written to the media socket have not yet been taken by bluetoothd: the
/// queue depth that LDAC's adaptive bitrate works from.
///
/// The socket is one end of a local stream socket to bluetoothd, where SO_NWRITE is always 0
/// (the bytes sit in the peer's receive buffer). Its free space still shows through POLLOUT,
/// which waits for the send low-water mark: probing a few marks (binary search) finds the free
/// space, and the queue is the capacity minus that. Checked on macOS 27 with a socketpair.
struct SendQueue {
    let fd: Int32
    /// Free space with nothing queued, taken before the first write.
    let capacity: Int
    /// False when the low-water mark cannot be set: the queue then reads 0, or `capacity` when
    /// the socket is full.
    let probes: Bool
    private let lowat: Int32
    private static let resolution = 128

    init(fd: Int32) {
        self.fd = fd
        var v: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        lowat = getsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &v, &len) == 0 ? v : 1
        var sb: Int32 = 0
        len = socklen_t(MemoryLayout<Int32>.size)
        let sndbuf = getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sb, &len) == 0 ? Int(sb) : 8192
        var one: Int32 = 1
        probes = setsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
        capacity = probes ? Self.freeSpace(fd, upTo: sndbuf) : sndbuf
        Self.restore(fd, lowat)
    }

    /// Bytes waiting in the socket.
    func queuedBytes() -> Int {
        guard probes else { return Self.writable(fd) ? 0 : capacity }
        let free = Self.freeSpace(fd, upTo: capacity)
        Self.restore(fd, lowat)
        return max(0, capacity - free)
    }

    private static func freeSpace(_ fd: Int32, upTo limit: Int) -> Int {
        if setLowat(fd, limit), writable(fd) { return limit }
        var lo = 0, hi = limit              // free space is at least lo, below hi
        while hi - lo > resolution {
            let mid = (lo + hi) / 2
            if setLowat(fd, max(mid, 1)), writable(fd) { lo = mid } else { hi = mid }
        }
        return lo
    }

    private static func setLowat(_ fd: Int32, _ bytes: Int) -> Bool {
        var v = Int32(bytes)
        return setsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &v, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private static func restore(_ fd: Int32, _ lowat: Int32) { _ = setLowat(fd, Int(lowat)) }

    private static func writable(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&p, 1, 0) > 0 && p.revents & Int16(POLLOUT) != 0
    }
}
