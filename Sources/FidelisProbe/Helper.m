// bluetoothd allows one channel per PSM per client session, and AVDTP needs two on PSM 0x19
// (signaling + media). A second process is a second session: it opens the media channel and
// passes the socket back with SCM_RIGHTS, then stays alive (it owns the CBL2CAPChannel object)
// until the parent closes its end of the control socket.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <spawn.h>
#include <sys/socket.h>
#include <unistd.h>
#import "L2CAP.h"

void FDSay(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
extern char **environ;

typedef struct { int32_t code; uint16_t mtu; } FDHelperReply;

static BOOL sendFD(int sock, FDHelperReply reply, int fd) {
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

static int recvFD(int sock, FDHelperReply *reply) {
    struct iovec iov = { .iov_base = reply, .iov_len = sizeof *reply };
    union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } ctl;
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl.buf, .msg_controllen = sizeof ctl.buf };
    if (recvmsg(sock, &msg, 0) != (ssize_t)sizeof *reply) return -2;
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    if (!c || c->cmsg_type != SCM_RIGHTS) return -1;
    int fd; memcpy(&fd, CMSG_DATA(c), sizeof fd);
    return fd;
}

/// Child side: `FidelisProbe helper <addr> <psm>`, control socket on fd 3.
int FDHelperMain(NSString *addr, uint16_t psm) {
    const int ctl = 3;
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:addr];
    long code = 0;
    FDL2CAPChannel *ch = nil;
    // Register this session's interest in the (already up) link; bluetoothd refuses channel
    // opens from a session that never asked for the connection.
    IOReturn oc = [d openConnection];
    FDSay(@"helper: openConnection -> 0x%x connected=%d", oc, d.isConnected);
    // A request that has not answered keeps the session busy (code 24), so wait long and do not
    // re-request on timeout.
    for (int i = 0; i < 3 && !ch; i++) {
        ch = [FDL2CAPChannel openOn:d psm:psm timeout:12 code:&code];
        if (code == -1) { FDSay(@"helper: open 0x%x timed out after 12 s", psm); break; }
        if (!ch) { FDSay(@"helper: open 0x%x attempt %d -> code %ld", psm, i + 1, code); FDSpinUntil(0.2, ^{ return NO; }); }
    }
    FDHelperReply r = { .code = ch ? 0 : (int32_t)code, .mtu = ch ? ch.outMTU : 0 };
    sendFD(ctl, r, ch ? ch.fd : -1);
    // Hold the channel until the parent goes away.
    char b;
    while (read(ctl, &b, 1) > 0) {}
    [ch close];
    return 0;
}

@interface FDHelperChannel : NSObject
@property (nonatomic) pid_t pid;
@property (nonatomic) int control;
@end
@implementation FDHelperChannel
- (void)dealloc {
    if (_control >= 0) close(_control);
}
@end

/// Parent side. Returns the media socket and keeps the helper alive through *keepAlive.
int FDOpenViaHelper(NSString *addr, uint16_t psm, uint16_t *mtu, id *keepAlive, long *code) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, sv[1], 3);
    posix_spawn_file_actions_addclose(&fa, sv[0]);
    NSString *exe = [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/FidelisProbeHelper"]
                        stringByStandardizingPath];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:exe]) exe = NSProcessInfo.processInfo.arguments[0];
    NSString *psmStr = [NSString stringWithFormat:@"%u", psm];
    char *argv[] = { (char *)exe.UTF8String, "helper", (char *)addr.UTF8String, (char *)psmStr.UTF8String, NULL };
    pid_t pid = 0;
    int err = posix_spawn(&pid, exe.UTF8String, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(sv[1]);
    if (err != 0) { close(sv[0]); FDSay(@"posix_spawn helper failed: %s", strerror(err)); return -1; }
    FDHelperReply r = {0};
    int fd = recvFD(sv[0], &r);
    if (fd < 0) { *code = r.code; close(sv[0]); return -1; }
    FDHelperChannel *h = [FDHelperChannel new];
    h.pid = pid; h.control = sv[0];
    *keepAlive = h;
    *mtu = r.mtu;
    return fd;
}
