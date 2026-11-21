// Private IOBluetooth / CoreBluetooth surface. Verified by runtime introspection on macOS 27.0.1
// (26A434). Type encodings are noted where they matter: getting them wrong fails silently.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>

@interface IOBluetoothDevice (FidelisPrivate)
- (id)classicPeer;   // CBClassicPeer
- (void)setHighPriority:(BOOL)on;   // v20@0:8B16
- (BOOL)highPriority;               // B16@0:8
@end

// Declared on a stand-in class so it cannot clash with CBPeripheral's public openL2CAPChannel:.
@interface FDClassicPeerShim : NSObject
- (void)setConnectL2CAPCallback:(void (^)(CBL2CAPChannel *channel, long code))callback;
- (void)openL2CAPChannel:(uint16_t)psm;    // v20@0:8S16
- (void)closeL2CAPChannel:(uint16_t)psm;   // v20@0:8S16 — takes the PSM, not a channel
@end

@interface CBL2CAPChannel (FidelisPrivate)
- (int)socketFD;
- (unsigned short)outgoingMTU;
@end
