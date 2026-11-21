// FidelisBluetooth — the only place Fidelis touches private Bluetooth API.
// Everything here runs on the main thread (IOBluetooth and CoreBluetooth deliver their callbacks
// on the main run loop); callers hop off to their own queues for I/O.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Result codes seen from bluetoothd on macOS 27 (CBClassicPeer path). Not exhaustive.
typedef NS_ENUM(long, FDBTOpenCode) {
    FDBTOpenOK = 0,
    FDBTOpenTimedOut = -1,       // no callback within the timeout
    FDBTOpenUnavailable = -2,    // private API missing on this macOS
    FDBTOpenEmptyCallback = -3,  // callback fired with result 0 but no channel
    FDBTOpenSessionBusy = 24,    // this client session already has a request / channel on the PSM
};

/// An open L2CAP channel. The socket is a SOCK_STREAM socket owned by this object.
@interface FDBTChannel : NSObject
@property (nonatomic, readonly) int fd;
@property (nonatomic, readonly) uint16_t psm;
@property (nonatomic, readonly) uint16_t outMTU;
/// YES once -close was called or the remote closed it.
@property (nonatomic, readonly, getter=isClosed) BOOL closed;
- (void)close;
@end

@interface FDBTDevice : NSObject
@property (nonatomic, readonly, copy) NSString *address;   // "91-5e-99-c9-d5-ae"
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) BOOL isConnected;
/// Major device class is audio/video.
@property (nonatomic, readonly) BOOL isAudio;
/// IOBluetooth's private connection priority for this device: -1 if not available, else 0/1.
@property (nonatomic, readonly) int highPriorityState;
/// Sets it; returns the state read back (-1 if not available).
- (int)setHighPriorityState:(BOOL)on;

+ (NSArray<FDBTDevice *> *)pairedDevices;
+ (nullable FDBTDevice *)deviceWithAddress:(NSString *)address;
/// YES if the private surface Fidelis depends on is present on this macOS.
+ (BOOL)privateAPIAvailable;

/// Pages the device (async). Completion gets the IOReturn status.
- (void)openConnectionWithCompletion:(void (^)(int status))completion;
/// Drops the baseband link (and with it every macOS profile on it).
- (void)closeConnection;

/// Opens an L2CAP channel from this process's client session.
- (void)openL2CAPChannel:(uint16_t)psm timeout:(NSTimeInterval)timeout
              completion:(void (^)(FDBTChannel *_Nullable channel, long code))completion;

/// Opens an L2CAP channel from a helper process (a second bluetoothd client session). The helper
/// executable lives at `helperPath`; it stays alive for as long as the returned channel is open.
- (void)openL2CAPChannelViaHelper:(NSString *)helperPath psm:(uint16_t)psm timeout:(NSTimeInterval)timeout
                       completion:(void (^)(FDBTChannel *_Nullable channel, long code))completion;
@end

/// Watches for Bluetooth devices connecting (IOBluetooth's connect notifications, delivered on
/// the main run loop). Keep the object for as long as you want the calls; it stops when released.
@interface FDBTConnectionWatch : NSObject
- (instancetype)initWithHandler:(void (^)(NSString *address))handler;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Entry point for the helper executable: opens `psm` on `address` and hands the socket to the
/// parent over fd 3. Returns the process exit code.
int FDBTHelperMain(NSString *address, uint16_t psm);

NS_ASSUME_NONNULL_END
