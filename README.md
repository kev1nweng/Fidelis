# Fidelis

**简体中文 / [English](README.en.md)**

让 Mac 通过自带蓝牙以 LDAC 推流的极简菜单栏工具。

> ⚠️ 早期预览：已能把系统音频以 LDAC 推到耳机（实测 SIMGOT EH500，660 kbps 稳定），但还没有经过长时间测试。

## 功能

- 在用户态实现 A2DP 发射端，用 LDAC 把系统音频推给耳机：不用外接发射器，不装内核扩展，不用关 SIP
- 虚拟输出设备「Fidelis」：音量键、控制中心照常可用，并向系统上报延迟，视频音画同步
- 自适应码率：链路拥塞时自动降档，稳定后再升回（990 / 660 / 492 / 396 / 330 kbps）
- 推流开始时自动切换默认输出，结束后交还耳机并切回原输出
- 原生、极简的菜单栏控制
- 不需要麦克风或屏幕录制权限

## 系统要求

- 仅官方支持 macOS 27（Apple 芯片）；macOS 26 未经测试，但不一定不能用
- 支持 LDAC 的蓝牙耳机，并且已经和这台 Mac 配对

## 安装

1. 从 [Releases](https://github.com/kev1nweng/Fidelis/releases) 下载最新的 `Fidelis.zip`，解压后将应用移动到“应用程序”文件夹。
2. 当前 Release 未签名。首次运行时，需要在“系统设置 › 隐私与安全性”中手动允许打开，或者执行：
   ```sh
   xattr -dr com.apple.quarantine /Applications/Fidelis.app
   ```
3. 首次启动时允许蓝牙权限。
4. 在菜单栏图标的「音源」菜单中选择「安装音频驱动…」。这一步需要管理员密码，并会重启 coreaudiod（所有声音会中断一秒左右）。
5. 在「耳机」菜单中选好耳机，打开「LDAC 输出」。

> 未签名的版本中，音频驱动只能按 bundle id 核对来访的 App。在签名版本发布之前，请只在自己信任的电脑上使用。
>
> 移除驱动：在「音源」菜单中选择「移除音频驱动…」。

## 从源码构建

需要 Xcode（工具链与 SDK）和 CMake。

```sh
git submodule update --init
scripts/build-app.sh release     # -> out/Fidelis.app
scripts/install-driver.sh        # 安装音频驱动（需管理员密码，会重启 coreaudiod）
```

测试：

```sh
source scripts/env.sh && swift test
Driver/tests/run_ring_test.sh                          # 驱动环形缓冲单测（需先构建）
scripts/selftest.sh <耳机地址> 30 system               # 实机推流 30 秒
```

## 原理

macOS 只会用 SBC 和 AAC 连接蓝牙耳机。Fidelis 先让 macOS 断开耳机，再抢在 bluetoothd 之前在 PSM 0x19 上建立 AVDTP 信令通道，自己完成编解码协商（LDAC），再打开媒体通道，用 [libldac](https://android.googlesource.com/platform/external/libldac) 编码并按实时节奏发送 RTP 包。停止时把耳机交还给 macOS。

系统音频来自一个 Audio Server 插件（HAL 驱动）提供的虚拟输出设备。驱动按 sample time 保存混音后的音频，App 通过自定义设备属性读回，驱动会核对调用方的代码签名。设备和发送端用的是同一个时钟，因此不需要重采样。

详细设计见 [docs/DESIGN.md](docs/DESIGN.md)，可行性结论见 [docs/M0-findings.md](docs/M0-findings.md)。

## 致谢

- [libldac](https://android.googlesource.com/platform/external/libldac)（Sony，Apache-2.0）
- [libASPL](https://github.com/gavv/libASPL)（MIT）：音频驱动的基础库
- [Sendspin for Mac](https://github.com/Sendspin/sendspin-mac)（Apache-2.0）：`Driver/` 改编自它的驱动（[许可证](Driver/LICENSE-sendspin)）
- 思路参考：[CodecBlue](https://github.com/PaoloAlbano/CodecBlue)、[hires-buddy](https://github.com/zerocolds/hires-buddy)

## 许可证

[MIT](LICENSE)。LDAC 是 Sony 的商标。
