#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

/// One L2CAP channel obtained through CBClassicPeer. Keeps the peer and channel objects alive,
/// because releasing either closes the socket.
@interface FDL2CAPChannel : NSObject
@property (nonatomic, readonly) int fd;
@property (nonatomic, readonly) uint16_t outMTU;
@property (nonatomic, readonly) int socketType;   // SOCK_STREAM / SOCK_SEQPACKET as reported by the kernel

/// Opens `psm` on `device`, spinning the current run loop until the callback fires or `timeout` passes.
/// Returns nil and sets *code on failure (code is bluetoothd's result, or -1 on timeout).
+ (nullable instancetype)openOn:(IOBluetoothDevice *)device psm:(uint16_t)psm
                        timeout:(NSTimeInterval)timeout code:(long *)code;

/// Wraps a socket received from the helper process; `owner` is kept alive with the channel.
+ (instancetype)adoptFD:(int)fd outMTU:(uint16_t)mtu owner:(id)owner;

- (BOOL)writeAll:(NSData *)data;
/// Reads whatever is available within `timeout`. Returns nil on timeout, empty data on EOF.
- (nullable NSData *)readWithTimeout:(NSTimeInterval)timeout;
- (void)close;
@end

/// Spins the current run loop until `cond` is true or `timeout` passes. Returns cond().
BOOL FDSpinUntil(NSTimeInterval timeout, BOOL (^cond)(void));

NS_ASSUME_NONNULL_END
