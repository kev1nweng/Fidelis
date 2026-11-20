#import <Foundation/Foundation.h>
#import "L2CAP.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, FDAVDTPSignal) {
    FDAVDTPDiscover = 0x01,
    FDAVDTPGetCapabilities = 0x02,
    FDAVDTPSetConfiguration = 0x03,
    FDAVDTPGetConfiguration = 0x04,
    FDAVDTPReconfigure = 0x05,
    FDAVDTPOpen = 0x06,
    FDAVDTPStart = 0x07,
    FDAVDTPClose = 0x08,
    FDAVDTPSuspend = 0x09,
    FDAVDTPAbort = 0x0A,
    FDAVDTPSecurityControl = 0x0B,
    FDAVDTPGetAllCapabilities = 0x0C,
    FDAVDTPDelayReport = 0x0D,
};

typedef NS_ENUM(uint8_t, FDAVDTPMessageType) {
    FDAVDTPCommand = 0,
    FDAVDTPGeneralReject = 1,
    FDAVDTPAccept = 2,
    FDAVDTPReject = 3,
};

@interface FDAVDTPReply : NSObject
@property (nonatomic) FDAVDTPMessageType type;
@property (nonatomic) uint8_t signal;
@property (nonatomic, copy) NSData *payload;   // bytes after the 2-byte header
@end

@interface FDStreamEndpoint : NSObject
@property (nonatomic) uint8_t seid;
@property (nonatomic) BOOL inUse;
@property (nonatomic) uint8_t mediaType;   // 0 audio
@property (nonatomic) BOOL isSink;
@property (nonatomic, copy, nullable) NSData *capabilities;
@end

/// Minimal AVDTP initiator over a signaling channel. Synchronous; good enough for a probe.
@interface FDAVDTPSignaling : NSObject
- (instancetype)initWithChannel:(FDL2CAPChannel *)channel;
@property (nonatomic, readonly) FDL2CAPChannel *channel;
/// When set, every incoming command from the sink is logged through this block.
@property (nonatomic, copy, nullable) void (^log)(NSString *line);

- (nullable FDAVDTPReply *)send:(FDAVDTPSignal)signal payload:(NSData *)payload timeout:(NSTimeInterval)timeout;
- (nullable NSArray<FDStreamEndpoint *> *)discover;
- (nullable NSData *)capabilitiesFor:(uint8_t)seid all:(BOOL)all;
/// Answers any pending sink-initiated commands; call periodically while idle.
- (void)pumpFor:(NSTimeInterval)seconds;
@end

/// Human-readable dump of a capability TLV list.
NSString *FDDescribeCapabilities(NSData *caps);
/// Finds the LDAC codec info (bytes after vendor+codec id) in a capability TLV list, or nil.
NSData *_Nullable FDFindLDAC(NSData *caps);
NSString *FDHex(NSData *d);

NS_ASSUME_NONNULL_END
