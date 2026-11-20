#import "L2CAP.h"
#import "Private.h"
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

BOOL FDSpinUntil(NSTimeInterval timeout, BOOL (^cond)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!cond() && deadline.timeIntervalSinceNow > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
    }
    return cond();
}

@implementation FDL2CAPChannel {
    id _peer;       // CBClassicPeer
    id _channel;    // CBL2CAPChannel
    BOOL _closed;
}

+ (instancetype)openOn:(IOBluetoothDevice *)device psm:(uint16_t)psm
               timeout:(NSTimeInterval)timeout code:(long *)code {
    if (![device respondsToSelector:@selector(classicPeer)]) { if (code) *code = -2; return nil; }
    FDClassicPeerShim *peer = (FDClassicPeerShim *)[device classicPeer];
    if (!peer || ![peer respondsToSelector:@selector(openL2CAPChannel:)]) { if (code) *code = -2; return nil; }

    __block id gotChannel = nil;
    __block long gotCode = 0;
    __block BOOL done = NO;
    [peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long c) {
        // Ignore callbacks for other PSMs (macOS may be opening its own channels concurrently).
        if (ch && [ch respondsToSelector:@selector(PSM)] && ch.PSM != psm) return;
        gotChannel = ch; gotCode = c; done = YES;
    }];
    [peer openL2CAPChannel:psm];
    BOOL fired = FDSpinUntil(timeout, ^{ return done; });
    [peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long c) {}];

    if (!fired) { if (code) *code = -1; return nil; }
    if (gotCode != 0 || !gotChannel) { if (code) *code = gotCode ?: -3; return nil; }

    FDL2CAPChannel *me = [self new];
    me->_peer = peer;
    me->_channel = gotChannel;
    me->_fd = [gotChannel socketFD];
    me->_outMTU = [gotChannel outgoingMTU];
    int on = 1; setsockopt(me->_fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    int type = 0; socklen_t len = sizeof type;
    getsockopt(me->_fd, SOL_SOCKET, SO_TYPE, &type, &len);
    me->_socketType = type;
    if (code) *code = 0;
    return me;
}

+ (instancetype)adoptFD:(int)fd outMTU:(uint16_t)mtu owner:(id)owner {
    FDL2CAPChannel *me = [self new];
    me->_peer = owner;
    me->_fd = fd;
    me->_outMTU = mtu;
    int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    int type = 0; socklen_t len = sizeof type;
    getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len);
    me->_socketType = type;
    return me;
}

- (BOOL)writeAll:(NSData *)data {
    if (_closed) return NO;
    const uint8_t *p = data.bytes; size_t left = data.length;
    while (left) {
        ssize_t w = write(_fd, p, left);
        if (w < 0) { if (errno == EINTR) continue; return NO; }
        p += w; left -= (size_t)w;
    }
    return YES;
}

- (NSData *)readWithTimeout:(NSTimeInterval)timeout {
    if (_closed) return [NSData data];
    struct pollfd pfd = { .fd = _fd, .events = POLLIN };
    int r = poll(&pfd, 1, (int)(timeout * 1000));
    if (r <= 0) return nil;
    uint8_t buf[2048];
    ssize_t n = read(_fd, buf, sizeof buf);
    if (n <= 0) return [NSData data];
    return [NSData dataWithBytes:buf length:(NSUInteger)n];
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    if ([_peer respondsToSelector:@selector(closeL2CAPChannel:)] && _channel) {
        [(FDClassicPeerShim *)_peer closeL2CAPChannel:[(CBL2CAPChannel *)_channel PSM]];
    } else if (!_channel && _fd >= 0) {
        close(_fd);   // adopted socket: we own the descriptor; dropping _peer releases the helper
    }
    _channel = nil; _peer = nil;
}

- (void)dealloc { [self close]; }
@end
