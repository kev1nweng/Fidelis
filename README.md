# Fidelis

让 Mac 原生输出 LDAC 的极简菜单栏工具 | A minimal macOS menu bar app that streams LDAC over the built-in Bluetooth.

> ⚠️ 早期开发中，尚不可用。 | Early development — not usable yet.

## 是什么 | What

macOS 只支持 SBC 和 AAC。Fidelis 在用户态实现 A2DP 发射端，把系统音频用 LDAC 编码，通过 Mac 自带的蓝牙推给耳机：不用外接发射器，不装内核扩展，也不用关 SIP。

macOS only speaks SBC and AAC to Bluetooth headphones. Fidelis implements an A2DP source in user space and streams your Mac's audio as LDAC over the built-in radio, with no dongle, no kernel extension and SIP left on.

## 状态 | Status

- [x] M0 可行性探针 | Feasibility probe — [结论 | findings](docs/M0-findings.md)
- [x] M1 LDAC 推流 | LDAC streaming (takeover, AVDTP, adaptive bitrate)
- [ ] M2 系统音频 | System audio — 虚拟输出设备已可用，待 1 小时长测 | virtual output device "Fidelis" works; 1-hour soak pending
- [ ] M3 稳定性 | Robustness (state machine, fault injection)
- [ ] M4 音质与控制 | Adaptive bitrate, AVRCP, delay reporting
- [ ] M5 菜单栏 App | Menu bar app, install & notarisation

设计见 [docs/DESIGN.md](docs/DESIGN.md)。 | See [docs/DESIGN.md](docs/DESIGN.md) for the design.

## 构建 | Build

```bash
git submodule update --init
scripts/build-app.sh          # -> out/Fidelis.app
swift test                    # 需先 source scripts/env.sh | after `source scripts/env.sh`
scripts/install-driver.sh     # 安装音频驱动（需管理员密码，会重启 coreaudiod）| install the audio driver (admin; restarts coreaudiod)
scripts/selftest.sh <耳机地址 | address> 30 system   # 实机推流 30 s | stream system audio to real headphones for 30 s
Driver/tests/run_ring_test.sh # 驱动环形缓冲单测 | driver ring buffer test (after building the app)
```

需要 Xcode（工具链 + SDK）和 CMake。也可以在菜单「音源」里安装或移除驱动。 | Requires Xcode and CMake. The driver can also be installed or removed from the Source menu.

仅官方支持 macOS 27；macOS 26 未测试。 | Requires Xcode. Officially supports macOS 27 only; macOS 26 is untested.

## 致谢 | Acknowledgements

- [libldac](https://android.googlesource.com/platform/external/libldac)（Sony，Apache-2.0）
- [libASPL](https://github.com/gavv/libASPL)（MIT）：音频驱动的基础库 | the audio driver's foundation
- [Sendspin for Mac](https://github.com/Sendspin/sendspin-mac)（Apache-2.0）：`Driver/` 改编自它的驱动 | `Driver/` is adapted from its driver ([LICENSE](Driver/LICENSE-sendspin))
- 思路参考 | Prior art: [CodecBlue](https://github.com/PaoloAlbano/CodecBlue)、[hires-buddy](https://github.com/zerocolds/hires-buddy)

## 许可 | License

MIT。LDAC 是 Sony 的商标。 | MIT. LDAC is a trademark of Sony Corporation.
