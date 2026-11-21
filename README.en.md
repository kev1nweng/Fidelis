# Fidelis

**[简体中文](README.md) / English**

Native LDAC streaming on macOS 27 and Apple silicon: a user-space A2DP source driving the Mac's built-in Bluetooth. No dongle, no kernel extension, SIP stays on.

## Features

- A user-space A2DP source that streams your Mac's audio as LDAC: no dongle, no kernel extension, SIP left on
- A virtual output device, "Fidelis": volume keys and Control Center work as usual, and it reports its latency so video stays in sync
- Adaptive bitrate: steps down when the link congests and back up once it is clean (990 / 660 / 492 / 396 / 330 kbps)
- Switches the default output when streaming starts, then hands the headphones back and restores the previous output
- Exclusive mode (on by default): turns macOS's own Bluetooth audio off while streaming, so the takeover is instant and Fidelis sets the headphones' own volume; it comes back on afterwards
- Stops and pauses playback when the headphones switch off or go out of range, and asks whether to stream again when they reconnect
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
5. Pick your headphones under Headphones and turn on LDAC Output. The first stream asks for an administrator password once more, to install the exclusive mode helper (see below).

> In unsigned builds the audio driver can only check the reading app by its bundle id. Until a signed release ships, use it only on computers you trust.
>
> To remove the driver: Source › Remove Audio Driver….

### Exclusive mode

With it on, Fidelis turns macOS's own Bluetooth audio (A2DP and AVRCP) off while it streams and back on when it stops. macOS then never competes with Fidelis for the headphones, and Fidelis sets the headphones' own volume, as macOS does.

- It uses bluetoothd's own service switches (`/Library/Preferences/com.apple.MobileBluetooth.debug`), which take a bluetoothd restart: every Bluetooth device drops for a few seconds when streaming starts and stops.
- While Fidelis streams, macOS can play to no Bluetooth headphones or speakers; this ends when you stop or quit Fidelis, or at its next launch after a crash.
- The helper, `/Library/PrivilegedHelperTools/fidelis-bt-audio`, is owned by root, with a sudoers rule (`/etc/sudoers.d/fidelis-bt-audio`) that lets only your user run its `off` and `on` without a password.
- Turning Exclusive Mode off in the menu removes the helper and the rule (admin password). Fidelis then goes back to having macOS drop the headphones and racing to reconnect them.

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

macOS only speaks SBC and AAC to Bluetooth headphones. In exclusive mode macOS never sets up its own A2DP, and Fidelis opens the AVDTP signaling channel on the link as it is; otherwise Fidelis has macOS drop the headphones and opens the signaling channel on PSM 0x19 before bluetoothd can. Either way it negotiates LDAC itself, opens the media channel, and sends RTP packets encoded with [libldac](https://android.googlesource.com/platform/external/libldac) in real time. When it stops, it hands the headphones back to macOS.

System audio comes from a virtual output device provided by an Audio Server plug-in (HAL driver). The driver keeps the mixed audio by sample time and the app reads it back through a custom device property, which the driver only serves to callers with the right code signature. The device and the sender run on the same clock, so no resampling is needed.

See [docs/DESIGN.md](docs/DESIGN.md) for the design (in Chinese).

## Acknowledgements

- [libldac](https://android.googlesource.com/platform/external/libldac) (Sony, Apache-2.0)
- [libASPL](https://github.com/gavv/libASPL) (MIT): the audio driver's foundation
- [Sendspin for Mac](https://github.com/Sendspin/sendspin-mac) (Apache-2.0): `Driver/` is adapted from its driver ([license](Driver/LICENSE-sendspin))
- Prior art: [CodecBlue](https://github.com/PaoloAlbano/CodecBlue), [hires-buddy](https://github.com/zerocolds/hires-buddy)

## License

[MIT](LICENSE). LDAC is a trademark of Sony Corporation.
