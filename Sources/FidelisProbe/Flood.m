// flood: configure an LDAC stream, open the media channel, START, then push encoded silence as
// fast as the socket accepts it and report the sustained throughput. Silence keeps it harmless
// to listen to; the headphones simply drop what overflows their buffer.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <sys/socket.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <fcntl.h>
#import "L2CAP.h"
#import "AVDTP.h"
#include "../../third_party/libldac/inc/ldacBT.h"

void FDSay(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
int FDOpenViaHelper(NSString *addr, uint16_t psm, uint16_t *mtu, id *keepAlive, long *code);

typedef struct {
    int seconds;
    int eqmid;           // 0 HQ 990, 1 SQ 660, 2 MQ 330
    int sndbufPackets;   // 0 = leave default
    int sampleRate;
    BOOL paced;          // YES: send at real time instead of flooding
} FDFloodOptions;        // keep in sync with main.m

static double now(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static uint8_t rateBit(int sr) {
    switch (sr) { case 44100: return 0x20; case 48000: return 0x10; case 88200: return 0x08; case 96000: return 0x04; }
    return 0;
}

/// Pre-encodes `count` media payloads (LDAC header byte + transport frames) of silence.
static NSArray<NSData *> *encodeSilence(int mtu, int eqmid, int sr, int count, int *framesPerPacket, int *samplesPerPacket) {
    HANDLE_LDAC_BT h = ldacBT_get_handle();
    if (ldacBT_init_handle_encode(h, mtu, eqmid, LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_S16, sr) != 0) {
        FDSay(@"ldacBT_init_handle_encode failed: %d", ldacBT_get_error_code(h));
        ldacBT_free_handle(h);
        return nil;
    }
    FDSay(@"libldac 0x%x encoder: mtu %d eqmid %d -> %d kbps @ %d Hz", ldacBT_get_version(), mtu, eqmid,
          ldacBT_get_bitrate(h), ldacBT_get_sampling_freq(h));
    NSMutableArray *out = [NSMutableArray array];
    int16_t pcm[LDACBT_ENC_LSU * 2] = {0};
    uint8_t stream[1024];
    int blocks = 0;
    while ((int)out.count < count) {
        int used = 0, wrote = 0, frames = 0;
        if (ldacBT_encode(h, pcm, &used, stream, &wrote, &frames) != 0) {
            FDSay(@"ldacBT_encode failed: %d", ldacBT_get_error_code(h));
            break;
        }
        blocks++;
        if (wrote > 0) {
            NSMutableData *d = [NSMutableData dataWithCapacity:(NSUInteger)wrote + 1];
            uint8_t hdr = (uint8_t)(frames & 0x0f);
            [d appendBytes:&hdr length:1];
            [d appendBytes:stream length:(NSUInteger)wrote];
            [out addObject:d];
            if (out.count == 4) {   // steady state reached
                *framesPerPacket = frames;
                *samplesPerPacket = 0;
            }
        }
    }
    // Samples per packet: total PCM blocks fed / packets produced, in steady state.
    *samplesPerPacket = (int)((double)blocks * LDACBT_ENC_LSU / out.count + 0.5);
    ldacBT_free_handle(h);
    return out;
}

int FDRunFlood(IOBluetoothDevice *dev, FDL2CAPChannel *signaling, FDAVDTPSignaling *sig, FDFloodOptions opt) {
    // 1. Pick the LDAC sink.
    uint8_t seid = 0;
    NSData *ldacInfo = nil;
    for (FDStreamEndpoint *e in [sig discover]) {
        if (!e.isSink || e.inUse) continue;
        NSData *caps = [sig capabilitiesFor:e.seid all:YES] ?: [sig capabilitiesFor:e.seid all:NO];
        NSData *info = caps ? FDFindLDAC(caps) : nil;
        if (info) { seid = e.seid; ldacInfo = info; break; }
    }
    if (!seid) { FDSay(@"FAILED: no free LDAC sink"); return 1; }
    const uint8_t *li = ldacInfo.bytes;
    uint8_t rb = rateBit(opt.sampleRate);
    if (ldacInfo.length < 2 || !(li[0] & rb) || !(li[1] & 0x01)) {
        FDSay(@"FAILED: sink does not offer %d Hz stereo", opt.sampleRate);
        return 1;
    }

    // 2. SET_CONFIGURATION: media transport + LDAC 0x012D/0x00AA, chosen rate, stereo.
    uint8_t cfg[] = { (uint8_t)(seid << 2), 1 << 2,
                      0x01, 0x00,
                      0x07, 0x0A, 0x00, 0xFF, 0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00, rb, 0x01 };
    FDAVDTPReply *r = [sig send:FDAVDTPSetConfiguration payload:[NSData dataWithBytes:cfg length:sizeof cfg] timeout:3];
    FDSay(@"SET_CONFIGURATION seid %u -> %@", seid, r ? @(r.type) : @"timeout");
    if (!r || r.type != FDAVDTPAccept) { FDSay(@"  reply [%@]", r ? FDHex(r.payload) : @""); return 1; }

    uint8_t acp = (uint8_t)(seid << 2);
    NSData *acpData = [NSData dataWithBytes:&acp length:1];
    r = [sig send:FDAVDTPOpen payload:acpData timeout:3];
    FDSay(@"OPEN -> %@", r ? @(r.type) : @"timeout");
    if (!r || r.type != FDAVDTPAccept) return 1;

    // 3. Media channel: a second L2CAP channel on PSM 0x19.
    long code = 0;
    uint16_t mmtu = 0;
    id keepAlive = nil;
    int mfd = FDOpenViaHelper(dev.addressString, 0x19, &mmtu, &keepAlive, &code);
    FDL2CAPChannel *media = mfd >= 0 ? [FDL2CAPChannel adoptFD:mfd outMTU:mmtu owner:keepAlive] : nil;
    if (!media) {
        FDSay(@"FAILED: media channel via helper, code %ld", code);
        [sig send:FDAVDTPAbort payload:acpData timeout:2];
        return 1;
    }
    FDSay(@"media channel fd=%d outMTU=%u", media.fd, media.outMTU);

    r = [sig send:FDAVDTPStart payload:acpData timeout:3];
    FDSay(@"START -> %@", r ? @(r.type) : @"timeout");
    if (!r || r.type != FDAVDTPAccept) { [media close]; return 1; }

    // 4. Socket tuning.
    int mtu = media.outMTU;
    if (opt.sndbufPackets > 0) {
        int sz = mtu * opt.sndbufPackets;
        setsockopt(media.fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
    }
    int sb = 0; socklen_t sl = sizeof sb;
    getsockopt(media.fd, SOL_SOCKET, SO_SNDBUF, &sb, &sl);
    FDSay(@"SO_SNDBUF = %d bytes (%.1f packets)", sb, (double)sb / mtu);

    // 5. Encode. libldac takes the transport MTU and reserves its own 18-byte header budget.
    int fpp = 0, spp = 0;
    NSArray<NSData *> *payloads = encodeSilence(mtu, opt.eqmid, opt.sampleRate, 64, &fpp, &spp);
    if (!payloads.count) { [media close]; return 1; }
    double nominalKbps = 0;
    for (NSData *p in payloads) nominalKbps += p.length;
    nominalKbps = nominalKbps / payloads.count * 8 * opt.sampleRate / spp / 1000;
    FDSay(@"payload %lu B, %d LDAC frames, %d samples per packet -> %.0f packets/s needed for real time (~%.0f kbps on air)",
          (unsigned long)payloads[payloads.count / 2].length, fpp, spp, (double)opt.sampleRate / spp, nominalKbps);

    // 6. Send.
    uint16_t seq = 0; uint32_t ts = 0;
    double t0 = now(), lastReport = t0, packetInterval = (double)spp / opt.sampleRate;
    long sent = 0, bytes = 0, sentWin = 0, bytesWin = 0, eagain = 0;
    double maxWrite = 0, maxWriteWin = 0;
    NSUInteger pi = 0;
    BOOL failed = NO;
    while (now() - t0 < opt.seconds) {
        if (opt.paced) {
            double due = t0 + sent * packetInterval;
            double wait = due - now();
            if (wait > 0) usleep((useconds_t)(wait * 1e6));
        }
        NSData *payload = payloads[4 + pi % (payloads.count - 4)]; pi++;
        uint8_t pkt[1100];
        pkt[0] = 0x80; pkt[1] = 0x60;
        pkt[2] = seq >> 8; pkt[3] = seq & 0xff;
        pkt[4] = ts >> 24; pkt[5] = ts >> 16; pkt[6] = ts >> 8; pkt[7] = ts & 0xff;
        pkt[8] = 0; pkt[9] = 0; pkt[10] = 0; pkt[11] = 1;
        memcpy(pkt + 12, payload.bytes, payload.length);
        size_t len = 12 + payload.length;
        double w0 = now();
        ssize_t w = write(media.fd, pkt, len);
        double wdt = now() - w0;
        if (w < 0) {
            if (errno == EAGAIN || errno == ENOBUFS) { eagain++; usleep(500); continue; }
            FDSay(@"write failed: %s", strerror(errno));
            failed = YES;
            break;
        }
        if (wdt > maxWriteWin) maxWriteWin = wdt;
        seq++; ts += (uint32_t)spp;
        sent++; sentWin++; bytes += w; bytesWin += w;
        double t = now();
        if (t - lastReport >= 1.0) {
            double dt = t - lastReport;
            FDSay(@"  %5.1fs  %6.1f pkt/s  %6.0f kbps  max write %.1f ms  eagain %ld",
                  t - t0, sentWin / dt, bytesWin * 8 / dt / 1000, maxWriteWin * 1000, eagain);
            if (maxWriteWin > maxWrite) maxWrite = maxWriteWin;
            sentWin = bytesWin = 0; maxWriteWin = 0; lastReport = t;
            [sig pumpFor:0.0];
        }
    }
    double dur = now() - t0;
    double kbps = bytes * 8 / dur / 1000;
    FDSay(@"RESULT: %s %ld packets in %.1f s = %.1f pkt/s, %.0f kbps sustained (real time needs %.1f pkt/s); max write stall %.1f ms%s",
          opt.paced ? "paced" : "flood", sent, dur, sent / dur, kbps, (double)opt.sampleRate / spp, maxWrite * 1000,
          failed ? " [ended by write error]" : "");

    r = [sig send:FDAVDTPSuspend payload:acpData timeout:2];
    r = [sig send:FDAVDTPClose payload:acpData timeout:2];
    FDSay(@"CLOSE -> %@", r ? @(r.type) : @"timeout");
    [media close];
    return failed ? 1 : 0;
}
