#import "FidelisBluetooth.h"
#include <poll.h>
#import "Private.h"
#import <objc/runtime.h>
#include <spawn.h>
#include <sys/socket.h>
#include <unistd.h>

extern char **environ;

#pragma mark - Channel

@interface FDBTChannel ()
- (instancetype)initWithFD:(int)fd psm:(uint16_t)psm outMTU:(uint16_t)mtu owner:(id)owner closer:(void (^_Nullable)(void))closer;
@end

@implementation FDBTChannel {
    id _owner;                 // keeps CBClassicPeer + CBL2CAPChannel, or the helper process, alive
    void (^_closer)(void);
}

- (instancetype)initWithFD:(int)fd psm:(uint16_t)psm outMTU:(uint16_t)mtu owner:(id)owner closer:(void (^)(void))closer {
    if ((self = [super init])) {
        _fd = fd; _psm = psm; _outMTU = mtu; _owner = owner; _closer = [closer copy];
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    }
    return self;
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    if (_closer) _closer();
    _closer = nil;
    _owner = nil;
}

- (void)dealloc { [self close]; }
@end

/// Holds the CB objects of an in-process channel; closing goes through the peer by PSM.
@interface FDBTInProcessOwner : NSObject
@property (nonatomic, strong) id peer;
@property (nonatomic, strong) id channel;
@end
@implementation FDBTInProcessOwner @end

/// Holds the helper process of an out-of-process channel.
@interface FDBTHelperOwner : NSObject
@property (nonatomic) pid_t pid;
@property (nonatomic) int control;
@end
@implementation FDBTHelperOwner
- (void)dealloc {
    if (_control >= 0) close(_control);   // helper sees EOF and exits, closing its CB channel
}
@end

#pragma mark - Device

@interface FDBTConnectWaiter : NSObject
@property (nonatomic, copy) void (^completion)(int status);
@end
@implementation FDBTConnectWaiter
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    void (^c)(int) = self.completion;
    self.completion = nil;
    if (c) c(status);
}
@end

@implementation FDBTDevice {
    IOBluetoothDevice *_dev;
    NSMutableSet *_waiters;
}

- (instancetype)initWithDevice:(IOBluetoothDevice *)dev {
    if ((self = [super init])) { _dev = dev; _waiters = [NSMutableSet set]; }
    return self;
}

+ (NSArray<FDBTDevice *> *)pairedDevices {
    NSMutableArray *out = [NSMutableArray array];
    for (IOBluetoothDevice *d in [IOBluetoothDevice pairedDevices] ?: @[]) [out addObject:[[self alloc] initWithDevice:d]];
    return out;
}

+ (FDBTDevice *)deviceWithAddress:(NSString *)address {
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:address];
    return d ? [[self alloc] initWithDevice:d] : nil;
}

+ (BOOL)privateAPIAvailable {
    if (![IOBluetoothDevice instancesRespondToSelector:@selector(classicPeer)]) return NO;
    Class peer = NSClassFromString(@"CBClassicPeer");
    Class ch = NSClassFromString(@"CBL2CAPChannel");
    return peer && ch &&
        [peer instancesRespondToSelector:@selector(setConnectL2CAPCallback:)] &&
        [peer instancesRespondToSelector:@selector(openL2CAPChannel:)] &&
        [peer instancesRespondToSelector:@selector(closeL2CAPChannel:)] &&
        [ch instancesRespondToSelector:@selector(socketFD)] &&
        [ch instancesRespondToSelector:@selector(outgoingMTU)];
}

- (NSString *)address { return _dev.addressString ?: @""; }
- (NSString *)name { return _dev.name ?: self.address; }
- (BOOL)isConnected { return _dev.isConnected; }
- (BOOL)isAudio { return _dev.deviceClassMajor == kBluetoothDeviceClassMajorAudio; }

- (int)highPriorityState {
    if (![_dev respondsToSelector:@selector(highPriority)]) return -1;
    return [_dev highPriority] ? 1 : 0;
}

- (int)setHighPriorityState:(BOOL)on {
    if (![_dev respondsToSelector:@selector(setHighPriority:)]) return -1;
    [_dev setHighPriority:on];
    return self.highPriorityState;
}

- (void)openConnectionWithCompletion:(void (^)(int))completion {
    if (_dev.isConnected) {
        // Still call it: it registers this client's interest in the link, without which
        // closeConnection from this process does not drop it. Returns at once on a live link.
        completion([_dev openConnection]);
        return;
    }
    FDBTConnectWaiter *w = [FDBTConnectWaiter new];
    __weak NSMutableSet *waiters = _waiters;
    __weak FDBTConnectWaiter *weakW = w;
    w.completion = ^(int status) {
        FDBTConnectWaiter *strongW = weakW;
        if (strongW) [waiters removeObject:strongW];
        completion(status);
    };
    [_waiters addObject:w];
    IOReturn r = [_dev openConnection:w];
    if (r != kIOReturnSuccess) { [_waiters removeObject:w]; completion(r); }
}

- (void)closeConnection { [_dev closeConnection]; }

- (void)openL2CAPChannel:(uint16_t)psm timeout:(NSTimeInterval)timeout
              completion:(void (^)(FDBTChannel *, long))completion {
    if (![FDBTDevice privateAPIAvailable]) { completion(nil, FDBTOpenUnavailable); return; }
    FDClassicPeerShim *peer = (FDClassicPeerShim *)[_dev classicPeer];
    if (!peer) { completion(nil, FDBTOpenUnavailable); return; }

    __block BOOL done = NO;
    __weak FDClassicPeerShim *weakPeer = peer;
    void (^finish)(FDBTChannel *, long) = ^(FDBTChannel *c, long code) {
        if (done) return;
        done = YES;
        [weakPeer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {}];
        completion(c, code);
    };
    [peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {
        if (ch && ch.PSM != psm) return;   // a channel macOS opened for itself
        if (code != 0) { finish(nil, code); return; }
        if (!ch) { finish(nil, FDBTOpenEmptyCallback); return; }
        FDBTInProcessOwner *owner = [FDBTInProcessOwner new];
        owner.peer = peer; owner.channel = ch;
        FDBTChannel *c = [[FDBTChannel alloc] initWithFD:[ch socketFD] psm:psm outMTU:[ch outgoingMTU] owner:owner
                                                  closer:^{ [peer closeL2CAPChannel:psm]; }];
        finish(c, FDBTOpenOK);
    }];
    [peer openL2CAPChannel:psm];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        finish(nil, FDBTOpenTimedOut);
    });
}

#pragma mark Helper process

typedef struct { int32_t code; uint16_t mtu; } FDBTHelperReply;

static int recvFD(int sock, FDBTHelperReply *reply) {
    struct iovec iov = { .iov_base = reply, .iov_len = sizeof *reply };
    union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } ctl;
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl.buf, .msg_controllen = sizeof ctl.buf };
    ssize_t n;
    do { n = recvmsg(sock, &msg, 0); } while (n < 0 && errno == EINTR);
    if (n != (ssize_t)sizeof *reply) return -2;
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    if (!c || c->cmsg_type != SCM_RIGHTS) return -1;
    int fd; memcpy(&fd, CMSG_DATA(c), sizeof fd);
    return fd;
}

- (void)openL2CAPChannelViaHelper:(NSString *)helperPath psm:(uint16_t)psm timeout:(NSTimeInterval)timeout
                       completion:(void (^)(FDBTChannel *, long))completion {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { completion(nil, -10); return; }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, sv[1], 3);
    posix_spawn_file_actions_addclose(&fa, sv[0]);
    NSString *psmStr = [NSString stringWithFormat:@"%u", psm];
    NSString *timeoutStr = [NSString stringWithFormat:@"%.0f", timeout];
    char *argv[] = { (char *)helperPath.fileSystemRepresentation, (char *)self.address.UTF8String,
                     (char *)psmStr.UTF8String, (char *)timeoutStr.UTF8String, NULL };
    pid_t pid = 0;
    int err = posix_spawn(&pid, helperPath.fileSystemRepresentation, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(sv[1]);
    if (err != 0) { close(sv[0]); completion(nil, -11); return; }

    int control = sv[0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FDBTHelperReply r = {0};
        int fd = recvFD(control, &r);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (fd < 0) {
                close(control);
                completion(nil, r.code ?: -12);
                return;
            }
            FDBTHelperOwner *owner = [FDBTHelperOwner new];
            owner.pid = pid; owner.control = control;
            FDBTChannel *c = [[FDBTChannel alloc] initWithFD:fd psm:psm outMTU:r.mtu owner:owner
                                                      closer:^{ close(fd); }];
            completion(c, FDBTOpenOK);
        });
    });
}
@end

#pragma mark - Helper main

static BOOL sendFD(int sock, FDBTHelperReply reply, int fd) {
    struct iovec iov = { .iov_base = &reply, .iov_len = sizeof reply };
    union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } ctl;
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1 };
    if (fd >= 0) {
        msg.msg_control = ctl.buf; msg.msg_controllen = sizeof ctl.buf;
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS; c->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(c), &fd, sizeof fd);
    }
    return sendmsg(sock, &msg, 0) == (ssize_t)sizeof reply;
}

int FDBTHelperMain(NSString *address, uint16_t psm) {
    const int control = 3;
    NSTimeInterval timeout = 30;
    NSArray *args = NSProcessInfo.processInfo.arguments;
    if (args.count > 3) timeout = MAX(5, [args[3] doubleValue]);

    // Creating a manager makes this process a CoreBluetooth client (and checks TCC).
    CBCentralManager *central = [[CBCentralManager alloc] initWithDelegate:nil queue:nil];
    (void)central;

    FDBTDevice *dev = [FDBTDevice deviceWithAddress:address];
    __block FDBTChannel *channel = nil;
    __block long code = FDBTOpenTimedOut;
    __block BOOL finished = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

    // bluetoothd refuses opens from a session that never asked for the link, so ask first.
    // A request that has not answered keeps the session busy, so never re-request on timeout;
    // only an explicit empty callback is retried. (`attempt` lives for the whole process.)
    __block void (^attempt)(void) = nil;
    attempt = ^{
        NSTimeInterval left = deadline.timeIntervalSinceNow;
        if (left <= 0) { finished = YES; return; }
        [dev openL2CAPChannel:psm timeout:left completion:^(FDBTChannel *c, long r) {
            if (c) { channel = c; code = 0; finished = YES; return; }
            code = r;
            if (r == FDBTOpenEmptyCallback && deadline.timeIntervalSinceNow > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), attempt);
            } else {
                finished = YES;
            }
        }];
    };
    // Only once the link is up: bluetoothd refuses an open to a device that is not connected
    // ("could not connect ... on PSM:0x0019") and then never calls back (2026-11-21).
    [dev openConnectionWithCompletion:^(int status) { attempt(); }];
    // Never outlive the parent or the deadline: a page whose callback never comes kept a helper
    // waiting here for over an hour after its app had gone (2026-11-21), its pending open on
    // PSM 0x19 still registered with bluetoothd.
    while (!finished) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        if (deadline.timeIntervalSinceNow < -2) { code = FDBTOpenTimedOut; break; }
        struct pollfd p = { .fd = control, .events = POLLIN, .revents = 0 };
        if (poll(&p, 1, 0) > 0) {
            char c;
            if (p.revents & (POLLHUP | POLLERR) || recv(control, &c, 1, MSG_PEEK | MSG_DONTWAIT) == 0) return 2;
        }
    }

    FDBTHelperReply reply = { .code = (int32_t)code, .mtu = channel ? channel.outMTU : 0 };
    sendFD(control, reply, channel ? channel.fd : -1);
    if (!channel) return 1;
    // Hold the channel until the parent closes its end.
    char b;
    while (read(control, &b, 1) > 0) {}
    [channel close];
    return 0;
}
