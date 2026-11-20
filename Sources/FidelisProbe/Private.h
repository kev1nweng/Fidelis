// Private IOBluetooth / CoreBluetooth surface used by the probe.
// Verified present on macOS 27.0.1 (26A434) by runtime introspection.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>

@interface IOBluetoothDevice (FidelisPrivate)
- (id)classicPeer;   // returns a CBClassicPeer
@end

// Declared on a stand-in class so it does not clash with CBPeripheral's public openL2CAPChannel:.
@interface FDClassicPeerShim : NSObject
- (void)setConnectL2CAPCallback:(void (^)(CBL2CAPChannel *channel, long code))callback;
- (void)setDisconnectL2CAPCallback:(void (^)(CBL2CAPChannel *channel, long code))callback;
// Type encodings on macOS 27.0.1: openL2CAPChannel: v20@0:8S16, closeL2CAPChannel: v20@0:8S16
// (both take the PSM, not a channel object).
- (void)openL2CAPChannel:(uint16_t)psm;
- (void)closeL2CAPChannel:(uint16_t)psm;
@end

@interface CBL2CAPChannel (FidelisPrivate)
- (int)socketFD;
- (unsigned short)outgoingMTU;
@end
