# Fidelis

**[简体中文](README.md) / English**

A minimal macOS menu bar app that streams LDAC over the Mac's built-in Bluetooth.

## Features

- A user-space A2DP source that streams your Mac's audio as LDAC: no dongle, no kernel extension, SIP left on
- A virtual output device, "Fidelis": volume keys and Control Center work as usual, and it reports its latency so video stays in sync
- Adaptive bitrate: steps down when the link congests and back up once it is clean (990 / 660 / 492 / 396 / 330 kbps)
- Switches the default output when streaming starts, then hands the headphones back and restores the previous output
- Native, minimal menu bar controls, in English, Simplified Chinese and Traditional Chinese
- No microphone or screen recording permission needed

## Requirements

- Officially supports macOS 27 (Apple silicon) only; macOS 26 is untested but may work
- LDAC headphones already paired with this Mac

## Installation

1. Download the latest `Fidelis.zip` from [Releases](https://github.com/kev1nweng/Fidelis/releases), unzip it and move the app to Applications.
2. Current releases are unsigned. On first launch, allow it in System Settings › Privacy & Security, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Fidelis.app
   ```
3. Allow Bluetooth access when asked.
4. From the menu bar icon, choose Source › Install Audio Driver…. This asks for an administrator password and restarts coreaudiod (all audio stops for about a second).
5. Pick your headphones under Headphones and turn on LDAC Output.

> In unsigned builds the audio driver can only check the reading app by its bundle id. Until a signed release ships, use it only on computers you trust.
>
> To remove the driver: Source › Remove Audio Driver….

## Building from source

Requires Xcode (toolchain and SDK) and CMake.

```sh
git submodule update --init
scripts/build-app.sh release     # -> out/Fidelis.app
scripts/install-driver.sh        # install the audio driver (admin; restarts coreaudiod)
```

Tests:

```sh
source scripts/env.sh && swift test
Driver/tests/run_ring_test.sh                          # driver ring buffer test (build first)
scripts/selftest.sh <headphone address> 30 system      # stream to real headphones for 30 s
```

## How it works

macOS only speaks SBC and AAC to Bluetooth headphones. Fidelis has macOS drop the headphones, opens the AVDTP signaling channel on PSM 0x19 before bluetoothd can, negotiates LDAC itself, opens the media channel, and sends RTP packets encoded with [libldac](https://android.googlesource.com/platform/external/libldac) in real time. When it stops, it hands the headphones back to macOS.

System audio comes from a virtual output device provided by an Audio Server plug-in (HAL driver). The driver keeps the mixed audio by sample time and the app reads it back through a custom device property, which the driver only serves to callers with the right code signature. The device and the sender run on the same clock, so no resampling is needed.

See [docs/DESIGN.md](docs/DESIGN.md) for the design and [docs/M0-findings.md](docs/M0-findings.md) for the feasibility findings (both in Chinese).

## Acknowledgements

- [libldac](https://android.googlesource.com/platform/external/libldac) (Sony, Apache-2.0)
- [libASPL](https://github.com/gavv/libASPL) (MIT): the audio driver's foundation
- [Sendspin for Mac](https://github.com/Sendspin/sendspin-mac) (Apache-2.0): `Driver/` is adapted from its driver ([license](Driver/LICENSE-sendspin))
- Prior art: [CodecBlue](https://github.com/PaoloAlbano/CodecBlue), [hires-buddy](https://github.com/zerocolds/hires-buddy)

## License

[MIT](LICENSE). LDAC is a trademark of Sony Corporation.
