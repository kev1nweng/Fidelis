# Fidelis

让 Mac 原生输出 LDAC 的极简菜单栏工具 | A minimal macOS menu bar app that streams LDAC over the built-in Bluetooth.

> ⚠️ 早期开发中，尚不可用。 | Early development — not usable yet.

## 是什么 | What

macOS 只支持 SBC 和 AAC。Fidelis 在用户态实现 A2DP 发射端，把系统音频用 LDAC 编码，通过 Mac 自带的蓝牙推给耳机：不用外接发射器，不装内核扩展，也不用关 SIP。

macOS only speaks SBC and AAC to Bluetooth headphones. Fidelis implements an A2DP source in user space and streams your Mac's audio as LDAC over the built-in radio, with no dongle, no kernel extension and SIP left on.

## 状态 | Status

- [ ] M0 可行性探针 | Feasibility probe（Apple N1 吞吐、通道获取）
- [ ] M1 LDAC 播放 WAV | Play a WAV file over LDAC
- [ ] M2 系统音频 | System audio (HAL driver, resampling)
- [ ] M3 稳定性 | Robustness (state machine, fault injection)
- [ ] M4 音质与控制 | Adaptive bitrate, AVRCP, delay reporting
- [ ] M5 菜单栏 App | Menu bar app, install & notarisation

设计见 [docs/DESIGN.md](docs/DESIGN.md)。 | See [docs/DESIGN.md](docs/DESIGN.md) for the design.

## 致谢 | Acknowledgements

- [libldac](https://android.googlesource.com/platform/external/libldac)（Sony，Apache-2.0）
- 思路参考 | Prior art: [CodecBlue](https://github.com/PaoloAlbano/CodecBlue)、[hires-buddy](https://github.com/zerocolds/hires-buddy)

## 许可 | License

MIT。LDAC 是 Sony 的商标。 | MIT. LDAC is a trademark of Sony Corporation.
