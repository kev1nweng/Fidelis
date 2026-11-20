// fidelis-probe — M0 feasibility probe.
//
//   list                 paired devices and their link state
//   caps <addr>          take the headphones from macOS, read every stream endpoint's
//                        capabilities over AVDTP, then hand them back
//
// Must run as its own TCC-responsible process (see scripts/probe.sh), otherwise Bluetooth
// access is charged to whatever launched it.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import "Private.h"
#import "L2CAP.h"
#import "AVDTP.h"
#include <sys/socket.h>

void FDSay(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
#define say FDSay
void FDSay(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDate *t0; if (!t0) t0 = [NSDate date];
    fprintf(stdout, "[%7.3f] %s\n", -t0.timeIntervalSinceNow, s.UTF8String);
    fflush(stdout);
}

// ---- Bluetooth authorization --------------------------------------------------------------

@interface FDAuth : NSObject <CBCentralManagerDelegate>
@property (nonatomic) CBCentralManager *central;
@property (nonatomic) BOOL decided;
@end
@implementation FDAuth
- (void)centralManagerDidUpdateState:(CBCentralManager *)c { self.decided = YES; }
@end

static BOOL ensureBluetoothAuthorized(void) {
    // Creating a CBCentralManager is what triggers the TCC prompt for a fresh binary.
    static FDAuth *auth; auth = [FDAuth new];
    auth.central = [[CBCentralManager alloc] initWithDelegate:auth queue:nil];
    FDSpinUntil(60, ^{ return auth.decided; });
    CBManagerAuthorization a = CBManager.authorization;
    say(@"bluetooth authorization=%ld state=%ld", (long)a, (long)auth.central.state);
    return a == CBManagerAuthorizationAllowedAlways;
}

// ---- Link management ------------------------------------------------------------------------

static IOBluetoothDevice *deviceFor(NSString *addr) {
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:addr];
    if (!d) say(@"no device %@", addr);
    return d;
}

static BOOL waitConnected(IOBluetoothDevice *d, BOOL want, NSTimeInterval t) {
    return FDSpinUntil(t, ^{ return (BOOL)(d.isConnected == want); });
}

/// Takes the headphones' AVDTP signaling channel away from macOS.
static FDL2CAPChannel *takeSignaling(IOBluetoothDevice *d) {
    if (d.isConnected) {
        say(@"%@ is connected to macOS; dropping the link", d.name);
        [d closeConnection];
        if (!waitConnected(d, NO, 15)) say(@"link still up after 15 s, trying anyway");
        FDSpinUntil(1.0, ^{ return NO; });
    }
    for (int attempt = 1; attempt <= 10; attempt++) {
        long code = 0;
        FDL2CAPChannel *ch = nil;
        if (!d.isConnected) {
            // Note: requesting the channel on an idle link does not page; the request just hangs
            // and leaves the session busy (code 24). Always bring the link up first.
            IOReturn r = [d openConnection];
            say(@"attempt %d: openConnection -> 0x%x, connected=%d", attempt, r, d.isConnected);
            if (r != kIOReturnSuccess && !d.isConnected) { FDSpinUntil(1.0, ^{ return NO; }); continue; }
        }
        if (!ch) ch = [FDL2CAPChannel openOn:d psm:0x19 timeout:3 code:&code];
        if (!ch) {
            say(@"attempt %d: open PSM 0x19 failed, code %ld", attempt, code);
            FDSpinUntil(0.5, ^{ return NO; });
            continue;
        }
        say(@"attempt %d: AVDTP signaling open fd=%d outMTU=%u socket=%s", attempt, ch.fd, ch.outMTU,
            ch.socketType == SOCK_STREAM ? "STREAM" : ch.socketType == SOCK_SEQPACKET ? "SEQPACKET" : "other");
        id peer = [d classicPeer];
        if ([peer respondsToSelector:@selector(L2CAPChannels)])
        {
            id table = [peer valueForKey:@"L2CAPChannels"];   // NSHashTable (weak)
            NSArray *all = [table respondsToSelector:@selector(allObjects)] ? [table allObjects] : @[];
            NSMutableArray *psms = [NSMutableArray array];
            for (CBL2CAPChannel *c in all) [psms addObject:[NSString stringWithFormat:@"0x%x", c.PSM]];
            say(@"  peer L2CAP channels (this process): %@", [psms componentsJoinedByString:@","]);
        }
        // A channel that never answers DISCOVER is not really ours (bluetoothd won the race).
        FDAVDTPSignaling *probe = [[FDAVDTPSignaling alloc] initWithChannel:ch];
        probe.log = ^(NSString *l) { say(@"%@", l); };
        [probe pumpFor:0.3];
        if ([probe discover]) { say(@"attempt %d: DISCOVER answered, channel is ours", attempt); return ch; }
        say(@"attempt %d: DISCOVER unanswered; dropping the link and retrying", attempt);
        [ch close];
        [d closeConnection];
        waitConnected(d, NO, 15);
        FDSpinUntil(1.0, ^{ return NO; });
    }
    return nil;
}

/// Gives the headphones back to macOS so its own A2DP reconnects.
static void handBack(IOBluetoothDevice *d, FDL2CAPChannel *ch) {
    say(@"handing %@ back to macOS", d.name);
    [ch close];
    if (d.isConnected) {
        [d closeConnection];
        waitConnected(d, NO, 15);
    }
    FDSpinUntil(1.5, ^{ return NO; });
    for (int i = 1; i <= 3; i++) {
        IOReturn r = [d openConnection];
        say(@"reconnect %d -> 0x%x connected=%d", i, r, d.isConnected);
        if (d.isConnected) return;
        FDSpinUntil(1.0, ^{ return NO; });
    }
    say(@"could not reconnect; use the Bluetooth menu to reconnect manually");
}

// ---- Commands -------------------------------------------------------------------------------

static int cmdList(void) {
    for (IOBluetoothDevice *d in [IOBluetoothDevice pairedDevices]) {
        say(@"%@  %-28@ connected=%d class=0x%06x", d.addressString, d.name, d.isConnected, (unsigned)d.classOfDevice);
    }
    return 0;
}

static int cmdCaps(NSString *addr) {
    IOBluetoothDevice *d = deviceFor(addr);
    if (!d) return 2;
    FDL2CAPChannel *ch = takeSignaling(d);
    if (!ch) { say(@"FAILED: could not open AVDTP signaling"); handBack(d, nil); return 1; }

    FDAVDTPSignaling *sig = [[FDAVDTPSignaling alloc] initWithChannel:ch];
    sig.log = ^(NSString *l) { say(@"%@", l); };
    int rc = 0;
    NSArray<FDStreamEndpoint *> *eps = [sig discover];
    if (!eps) { say(@"FAILED: DISCOVER got no answer"); rc = 1; }
    BOOL ldac = NO;
    for (FDStreamEndpoint *e in eps) {
        say(@"SEP seid=%u %@ media=%u inUse=%d", e.seid, e.isSink ? @"sink" : @"source", e.mediaType, e.inUse);
        NSData *caps = [sig capabilitiesFor:e.seid all:YES] ?: [sig capabilitiesFor:e.seid all:NO];
        if (!caps) { say(@"  (no capabilities)"); continue; }
        printf("%s", FDDescribeCapabilities(caps).UTF8String);
        if (e.isSink && FDFindLDAC(caps)) ldac = YES;
    }
    say(@"RESULT: LDAC sink endpoint %@", ldac ? @"PRESENT" : @"ABSENT");
    handBack(d, ch);
    return rc;
}

typedef struct { int seconds, eqmid, sndbufPackets, sampleRate; BOOL paced; } FDFloodOptions;
int FDRunFlood(IOBluetoothDevice *dev, FDL2CAPChannel *signaling, FDAVDTPSignaling *sig, FDFloodOptions opt);

/// flood <addr> [secs=N] [eqmid=0|1|2] [sndbuf=packets] [rate=48000] [paced]
static int cmdFlood(NSArray<NSString *> *args) {
    FDFloodOptions o = { .seconds = 15, .eqmid = 0, .sndbufPackets = 0, .sampleRate = 48000, .paced = NO };
    for (NSString *a in [args subarrayWithRange:NSMakeRange(3, args.count - 3)]) {
        NSArray *kv = [a componentsSeparatedByString:@"="];
        NSString *k = kv[0]; int v = kv.count > 1 ? [kv[1] intValue] : 1;
        if ([k isEqualToString:@"secs"]) o.seconds = v;
        else if ([k isEqualToString:@"eqmid"]) o.eqmid = v;
        else if ([k isEqualToString:@"sndbuf"]) o.sndbufPackets = v;
        else if ([k isEqualToString:@"rate"]) o.sampleRate = v;
        else if ([k isEqualToString:@"paced"]) o.paced = YES;
    }
    say(@"flood options: secs=%d eqmid=%d sndbuf=%d rate=%d paced=%d", o.seconds, o.eqmid, o.sndbufPackets, o.sampleRate, o.paced);
    IOBluetoothDevice *d = deviceFor(args[2]);
    if (!d) return 2;
    FDL2CAPChannel *ch = takeSignaling(d);
    if (!ch) { say(@"FAILED: could not open AVDTP signaling"); handBack(d, nil); return 1; }
    FDAVDTPSignaling *sig = [[FDAVDTPSignaling alloc] initWithChannel:ch];
    sig.log = ^(NSString *l) { say(@"%@", l); };
    int rc = FDRunFlood(d, ch, sig, o);
    handBack(d, ch);
    return rc;
}

int FDHelperMain(NSString *addr, uint16_t psm);
int FDRunConnTest(NSString *addr, NSArray<NSNumber *> *services, BOOL lowLatency);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        NSString *cmd = args.count > 1 ? args[1] : @"list";
        say(@"fidelis-probe %@ (pid %d, macOS %@)", cmd, getpid(), NSProcessInfo.processInfo.operatingSystemVersionString);
        if (!ensureBluetoothAuthorized()) { say(@"FAILED: Bluetooth permission not granted"); return 3; }
        if ([cmd isEqualToString:@"list"]) return cmdList();
        if ([cmd isEqualToString:@"caps"] && args.count > 2) return cmdCaps(args[2]);
        if ([cmd isEqualToString:@"helper"] && args.count > 3) return FDHelperMain(args[2], (uint16_t)[args[3] intValue]);
        if ([cmd isEqualToString:@"conntest"] && args.count > 2) {
            // conntest <addr> [none|default|n,n,...] [lowlat]
            NSString *spec = args.count > 3 ? args[3] : @"none";
            NSArray *svc = nil;
            if ([spec isEqualToString:@"none"]) svc = @[];
            else if (![spec isEqualToString:@"default"]) {
                NSMutableArray *m = [NSMutableArray array];
                for (NSString *n in [spec componentsSeparatedByString:@","]) [m addObject:@(strtol(n.UTF8String, NULL, 0))];
                svc = m;
            }
            return FDRunConnTest(args[2], svc, args.count > 4 && [args[4] isEqualToString:@"lowlat"]);
        }
        if ([cmd isEqualToString:@"flood"] && args.count > 2) return cmdFlood(args);
        say(@"usage: fidelis-probe list | caps <addr> | flood <addr> [secs=N] [eqmid=0|1|2] [sndbuf=N] [rate=Hz] [paced]");
        return 64;
    }
}
