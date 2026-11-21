# Fidelis

**简体中文 / [English](README.en.md)**

在 macOS 27 与 Apple 芯片上原生推流 LDAC：一个跑在用户态的 A2DP 发射端，直接驱动 Mac 自带蓝牙。不用发射器，不装内核扩展，SIP 保持开启。

## 功能

- 在用户态实现 A2DP 发射端，用 LDAC 把系统音频推给耳机：不用外接发射器，不装内核扩展，不用关 SIP
- 虚拟输出设备「Fidelis」：音量键、控制中心照常可用，并向系统上报延迟，视频音画同步
- 自适应码率：链路拥塞时自动降档，稳定后再升回（990 / 660 / 492 / 396 / 330 kbps）
- 推流开始时自动切换默认输出，结束后交还耳机并切回原输出
- 独占模式（默认开启）：推流期间暂时关闭 macOS 自带的蓝牙音频，接管瞬间完成，并直接调节耳机自身的音量；结束后自动恢复
- 耳机关机或离开范围时自动停止并暂停播放，耳机重新连上后询问是否继续 LDAC 推流
- 原生、极简的菜单栏控制，支持简体中文、繁體中文和 English
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
5. 在「耳机」菜单中选好耳机，打开「LDAC 输出」。第一次推流时会再要一次管理员密码，用来安装独占模式的辅助程序（见下文）。

> 未签名的版本中，音频驱动只能按 bundle id 核对来访的 App。在签名版本发布之前，请只在自己信任的电脑上使用。
>
> 移除驱动：在「音源」菜单中选择「移除音频驱动…」。

### 独占模式

开启后，Fidelis 在推流期间关闭 macOS 自带的蓝牙音频（A2DP 和 AVRCP），停止时再打开。这样 macOS 不会和 Fidelis 争抢耳机，Fidelis 也能像 macOS 一样直接调节耳机自身的音量。

- 用的是 bluetoothd 自带的服务开关（`/Library/Preferences/com.apple.MobileBluetooth.debug`），改完要重启 bluetoothd，因此每次开始和停止推流时，所有蓝牙设备会断开几秒。
- 推流期间，macOS 无法用任何蓝牙耳机或音箱播放音频；停止或退出 Fidelis 后恢复。若 Fidelis 中途崩溃，下次启动时恢复。
- 辅助程序 `/Library/PrivilegedHelperTools/fidelis-bt-audio` 归 root 所有，另有一条 sudoers 规则（`/etc/sudoers.d/fidelis-bt-audio`），只允许当前用户免密码执行它的 `off` 和 `on`。
- 在菜单中关闭「独占模式」会卸载辅助程序和 sudoers 规则（需管理员密码）。之后 Fidelis 会回到“先让 macOS 断开耳机，再抢先建立连接”的旧方式。

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

macOS 只会用 SBC 和 AAC 连接蓝牙耳机。独占模式下 macOS 不会建立自己的 A2DP 连接，Fidelis 直接在现有链路上建立信令通道；否则 Fidelis 先让 macOS 断开耳机，再抢在 bluetoothd 之前在 PSM 0x19 上建立 AVDTP 信令通道，自己完成编解码协商（LDAC），再打开媒体通道，用 [libldac](https://android.googlesource.com/platform/external/libldac) 编码并按实时节奏发送 RTP 包。停止时把耳机交还给 macOS。

系统音频来自一个 Audio Server 插件（HAL 驱动）提供的虚拟输出设备。驱动按 sample time 保存混音后的音频，App 通过自定义设备属性读回，驱动会核对调用方的代码签名。设备和发送端用的是同一个时钟，因此不需要重采样。

详细设计见 [docs/DESIGN.md](docs/DESIGN.md)。

## 致谢

- [libldac](https://android.googlesource.com/platform/external/libldac)（Sony，Apache-2.0）
- [libASPL](https://github.com/gavv/libASPL)（MIT）：音频驱动的基础库
- [Sendspin for Mac](https://github.com/Sendspin/sendspin-mac)（Apache-2.0）：`Driver/` 改编自它的驱动（[许可证](Driver/LICENSE-sendspin)）
- 思路参考：[CodecBlue](https://github.com/PaoloAlbano/CodecBlue)、[hires-buddy](https://github.com/zerocolds/hires-buddy)

## 许可证

[MIT](LICENSE)。LDAC 是 Sony 的商标。
