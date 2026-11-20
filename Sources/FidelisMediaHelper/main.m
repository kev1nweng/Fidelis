// fidelis-media-helper: opens one L2CAP channel from its own bluetoothd client session and hands
// the socket to the parent over fd 3. AVDTP needs two channels on PSM 0x19 and bluetoothd allows
// one per session, so the media channel comes from here.
//   argv: <address> <psm> [timeout-seconds]
#import <Foundation/Foundation.h>
#import "FidelisBluetooth.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: %s <address> <psm> [timeout]\n", argv[0]); return 64; }
        return FDBTHelperMain(@(argv[1]), (uint16_t)strtoul(argv[2], NULL, 0));
    }
}
