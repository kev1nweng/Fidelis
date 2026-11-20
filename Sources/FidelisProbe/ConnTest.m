// conntest: bring the link up through CBClassicManager connectPeer:options: with an explicit
// service list, to see whether bluetoothd can be kept from starting its own A2DP (which is what
// beats our AVDTP signaling channel).
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import "Private.h"
#import "L2CAP.h"
#import "AVDTP.h"

void FDSay(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

@interface FDClassicManagerShim : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)q options:(NSDictionary *)o;
- (long)powerState;
- (id)retrievePeerWithAddress:(id)address;
- (void)connectPeer:(id)peer options:(NSDictionary *)options;
- (void)cancelPeerConnection:(id)peer force:(BOOL)force;
- (void)setConnectCallback:(id)block;
@end

int FDRunConnTest(NSString *addr, NSArray<NSNumber *> *services, BOOL lowLatency) {
    Class cls = NSClassFromString(@"CBClassicManager");
    if (!cls) { FDSay(@"no CBClassicManager"); return 1; }
    FDClassicManagerShim *mgr = [[cls alloc] initWithQueue:dispatch_get_main_queue() options:nil];
    FDSpinUntil(8, ^{ return (BOOL)([(CBManager *)mgr state] == CBManagerStatePoweredOn); });
    FDSay(@"CBClassicManager powerState=%ld state=%ld", [mgr powerState], (long)[(CBManager *)mgr state]);

    NSString *colon = [[addr stringByReplacingOccurrencesOfString:@"-" withString:@":"] uppercaseString];
    id peer = nil;
    @try { peer = [mgr retrievePeerWithAddress:colon]; } @catch (NSException *e) { FDSay(@"retrievePeerWithAddress threw %@", e); }
    FDSay(@"peer for %@: %@", colon, peer);
    IOBluetoothDevice *d0 = [IOBluetoothDevice deviceWithAddressString:addr];
    id ioPeer = [d0 classicPeer];
    FDSay(@"IOBluetooth classicPeer: %@ (same object: %d)", ioPeer, ioPeer == peer);
    if (!peer) {
        for (id p in [(id)mgr valueForKey:@"peers"] ?: @[]) FDSay(@"  known peer %@", p);
        peer = ioPeer;
    }
    if (!peer) return 1;

    __block BOOL connectFired = NO;
    [mgr setConnectCallback:^(id a, id b) { connectFired = YES; FDSay(@"connect callback a=%@ b=%@", a, b); }];

    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:addr];
    if (d.isConnected) {
        FDSay(@"link up; cancelPeerConnection force");
        [mgr cancelPeerConnection:peer force:YES];
        FDSpinUntil(15, ^{ return (BOOL)!d.isConnected; });
        FDSpinUntil(1.0, ^{ return NO; });
        FDSay(@"link down=%d", !d.isConnected);
    }

    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    if (services) opts[@"kCBOptionServicesKey"] = services;
    if (lowLatency) {
        opts[@"kCBConnectOptionRequiresLowLatency"] = @1;
        opts[@"kCBConnectOptionLatencyCritical"] = @1;
    }
    FDSay(@"connectPeer options %@", opts);
    [mgr connectPeer:peer options:opts];
    BOOL up = FDSpinUntil(12, ^{ return d.isConnected; });
    FDSay(@"link up=%d callback=%d", up, connectFired);
    if (!up) return 1;

    long code = 0;
    FDL2CAPChannel *ch = [FDL2CAPChannel openOn:d psm:0x19 timeout:4 code:&code];
    FDSay(@"open 0x19 -> %@ code %ld", ch ? @"channel" : @"none", code);
    int rc = 1;
    if (ch) {
        FDAVDTPSignaling *sig = [[FDAVDTPSignaling alloc] initWithChannel:ch];
        sig.log = ^(NSString *l) { FDSay(@"%@", l); };
        [sig pumpFor:0.3];
        NSArray *eps = [sig discover];
        FDSay(@"RESULT: DISCOVER %@", eps ? [NSString stringWithFormat:@"answered (%lu SEPs) -> channel is ours", (unsigned long)eps.count] : @"unanswered -> bluetoothd owns AVDTP");
        rc = eps ? 0 : 1;
        [ch close];
    }
    FDSay(@"handing back");
    [mgr cancelPeerConnection:peer force:YES];
    FDSpinUntil(15, ^{ return (BOOL)!d.isConnected; });
    FDSpinUntil(1.5, ^{ return NO; });
    [d openConnection];
    FDSay(@"reconnected=%d", d.isConnected);
    return rc;
}
