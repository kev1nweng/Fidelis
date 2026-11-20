#import "AVDTP.h"

NSString *FDHex(NSData *d) {
    NSMutableString *s = [NSMutableString string];
    const uint8_t *p = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x%s", p[i], i + 1 < d.length ? " " : ""];
    return s;
}

@implementation FDAVDTPReply @end
@implementation FDStreamEndpoint @end

@implementation FDAVDTPSignaling {
    uint8_t _label;
}

- (instancetype)initWithChannel:(FDL2CAPChannel *)channel {
    if ((self = [super init])) _channel = channel;
    return self;
}

- (void)respondToCommand:(uint8_t)label signal:(uint8_t)signal payload:(NSData *)payload {
    if (self.log) self.log([NSString stringWithFormat:@"  <- sink command 0x%02x label %u payload [%@]", signal, label, FDHex(payload)]);
    uint8_t hdr[3];
    NSUInteger n;
    switch (signal) {
        case FDAVDTPDelayReport:
        case FDAVDTPSuspend:
        case FDAVDTPStart:
        case FDAVDTPClose:
        case FDAVDTPAbort:
            hdr[0] = (uint8_t)(label << 4 | FDAVDTPAccept); hdr[1] = signal; n = 2;
            break;
        default:
            // We expose no endpoints of our own: reject with NOT_SUPPORTED_COMMAND.
            hdr[0] = (uint8_t)(label << 4 | FDAVDTPReject); hdr[1] = signal; hdr[2] = 0x19; n = 3;
            break;
    }
    [self.channel writeAll:[NSData dataWithBytes:hdr length:n]];
}

/// Handles one chunk read from the stream socket. Returns the reply if it matches (label, signal).
- (FDAVDTPReply *)consume:(NSData *)chunk label:(int)label signal:(int)signal {
    // The socket may be a byte stream; in practice each read carries exactly one signaling message
    // for these small exchanges. The product needs real reassembly (see docs/DESIGN.md §4.3).
    if (chunk.length < 2) return nil;
    const uint8_t *p = chunk.bytes;
    uint8_t l = p[0] >> 4, packetType = (p[0] >> 2) & 3, type = p[0] & 3, sig = p[1] & 0x3f;
    NSData *payload = [chunk subdataWithRange:NSMakeRange(2, chunk.length - 2)];
    if (packetType != 0 && self.log) self.log([NSString stringWithFormat:@"  ! fragmented AVDTP packet type %u", packetType]);
    if (type == FDAVDTPCommand) {
        [self respondToCommand:l signal:sig payload:payload];
        return nil;
    }
    if (label >= 0 && l == label && (type == FDAVDTPGeneralReject || sig == signal)) {
        FDAVDTPReply *r = [FDAVDTPReply new];
        r.type = type; r.signal = sig; r.payload = payload;
        return r;
    }
    if (self.log) self.log([NSString stringWithFormat:@"  ! stray reply label %u signal 0x%02x type %u", l, sig, type]);
    return nil;
}

- (FDAVDTPReply *)send:(FDAVDTPSignal)signal payload:(NSData *)payload timeout:(NSTimeInterval)timeout {
    uint8_t label = _label; _label = (_label + 1) & 0x0f;
    NSMutableData *msg = [NSMutableData dataWithCapacity:payload.length + 2];
    uint8_t hdr[2] = { (uint8_t)(label << 4 | FDAVDTPCommand), signal };
    [msg appendBytes:hdr length:2];
    [msg appendData:payload];
    if (![self.channel writeAll:msg]) return nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        NSData *chunk = [self.channel readWithTimeout:deadline.timeIntervalSinceNow];
        if (!chunk) break;
        if (chunk.length == 0) return nil;   // EOF
        FDAVDTPReply *r = [self consume:chunk label:label signal:signal];
        if (r) return r;
    }
    return nil;
}

- (void)pumpFor:(NSTimeInterval)seconds {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        NSData *chunk = [self.channel readWithTimeout:MIN(0.05, deadline.timeIntervalSinceNow)];
        if (chunk.length) [self consume:chunk label:-1 signal:-1];
        else if (chunk) return;   // EOF
    }
}

- (NSArray<FDStreamEndpoint *> *)discover {
    FDAVDTPReply *r = [self send:FDAVDTPDiscover payload:[NSData data] timeout:3];
    if (!r || r.type != FDAVDTPAccept) return nil;
    NSMutableArray *out = [NSMutableArray array];
    const uint8_t *p = r.payload.bytes;
    for (NSUInteger i = 0; i + 1 < r.payload.length; i += 2) {
        FDStreamEndpoint *e = [FDStreamEndpoint new];
        e.seid = p[i] >> 2;
        e.inUse = (p[i] >> 1) & 1;
        e.mediaType = p[i + 1] >> 4;
        e.isSink = (p[i + 1] >> 3) & 1;
        [out addObject:e];
    }
    return out;
}

- (NSData *)capabilitiesFor:(uint8_t)seid all:(BOOL)all {
    uint8_t b = (uint8_t)(seid << 2);
    FDAVDTPReply *r = [self send:all ? FDAVDTPGetAllCapabilities : FDAVDTPGetCapabilities
                         payload:[NSData dataWithBytes:&b length:1] timeout:3];
    if (!r || r.type != FDAVDTPAccept) return nil;
    return r.payload;
}
@end

static NSString *CategoryName(uint8_t c) {
    switch (c) {
        case 1: return @"MediaTransport";
        case 2: return @"Reporting";
        case 3: return @"Recovery";
        case 4: return @"ContentProtection";
        case 5: return @"HeaderCompression";
        case 6: return @"Multiplexing";
        case 7: return @"MediaCodec";
        case 8: return @"DelayReporting";
        default: return [NSString stringWithFormat:@"Category%u", c];
    }
}

static NSString *VendorCodecName(uint32_t vendor, uint16_t codec) {
    if (vendor == 0x012D && codec == 0x00AA) return @"LDAC";
    if (vendor == 0x004F && codec == 0x0001) return @"aptX";
    if (vendor == 0x00D7 && codec == 0x0024) return @"aptX HD";
    if (vendor == 0x00D7 && codec == 0x00AD) return @"aptX Adaptive";
    if (vendor == 0x053A && codec == 0x4C35) return @"LHDC v5";
    if (vendor == 0x053A && codec == 0x4C33) return @"LHDC v3";
    if (vendor == 0x0075 && codec == 0x0102) return @"Samsung Scalable";
    return [NSString stringWithFormat:@"vendor 0x%04x codec 0x%04x", vendor, codec];
}

static NSString *LDACRates(uint8_t bits) {
    NSMutableArray *r = [NSMutableArray array];
    if (bits & 0x20) [r addObject:@"44.1k"];
    if (bits & 0x10) [r addObject:@"48k"];
    if (bits & 0x08) [r addObject:@"88.2k"];
    if (bits & 0x04) [r addObject:@"96k"];
    if (bits & 0x02) [r addObject:@"176.4k"];
    if (bits & 0x01) [r addObject:@"192k"];
    return [r componentsJoinedByString:@"/"];
}

static NSString *LDACModes(uint8_t bits) {
    NSMutableArray *r = [NSMutableArray array];
    if (bits & 0x04) [r addObject:@"mono"];
    if (bits & 0x02) [r addObject:@"dual"];
    if (bits & 0x01) [r addObject:@"stereo"];
    return [r componentsJoinedByString:@"/"];
}

NSString *FDDescribeCapabilities(NSData *caps) {
    NSMutableString *s = [NSMutableString string];
    const uint8_t *p = caps.bytes;
    NSUInteger i = 0, n = caps.length;
    while (i + 1 < n) {
        uint8_t cat = p[i], len = p[i + 1];
        if (i + 2 + len > n) { [s appendFormat:@"    (truncated TLV at %lu)\n", (unsigned long)i]; break; }
        const uint8_t *v = p + i + 2;
        NSData *val = [NSData dataWithBytes:v length:len];
        if (cat == 7 && len >= 2) {
            uint8_t codecType = v[1];
            if (codecType == 0x00) [s appendFormat:@"    MediaCodec SBC [%@]\n", FDHex(val)];
            else if (codecType == 0x02) [s appendFormat:@"    MediaCodec AAC [%@]\n", FDHex(val)];
            else if (codecType == 0xFF && len >= 8) {
                uint32_t vendor = (uint32_t)v[2] | (uint32_t)v[3] << 8 | (uint32_t)v[4] << 16 | (uint32_t)v[5] << 24;
                uint16_t codec = (uint16_t)(v[6] | v[7] << 8);
                NSString *name = VendorCodecName(vendor, codec);
                [s appendFormat:@"    MediaCodec %@ [%@]", name, FDHex(val)];
                if ([name isEqualToString:@"LDAC"] && len >= 10)
                    [s appendFormat:@"  rates %@  modes %@", LDACRates(v[8]), LDACModes(v[9])];
                [s appendString:@"\n"];
            } else [s appendFormat:@"    MediaCodec type 0x%02x [%@]\n", codecType, FDHex(val)];
        } else {
            [s appendFormat:@"    %@ [%@]\n", CategoryName(cat), FDHex(val)];
        }
        i += 2 + len;
    }
    return s;
}

NSData *FDFindLDAC(NSData *caps) {
    const uint8_t *p = caps.bytes;
    NSUInteger i = 0, n = caps.length;
    while (i + 1 < n) {
        uint8_t cat = p[i], len = p[i + 1];
        if (i + 2 + len > n) break;
        const uint8_t *v = p + i + 2;
        if (cat == 7 && len >= 8 && v[1] == 0xFF &&
            v[2] == 0x2D && v[3] == 0x01 && v[4] == 0 && v[5] == 0 && v[6] == 0xAA && v[7] == 0) {
            return [NSData dataWithBytes:v + 8 length:len - 8];
        }
        i += 2 + len;
    }
    return nil;
}
