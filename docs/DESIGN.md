# Fidelis 设计文档（草案 v0）

日期：2026-11-20
状态：调研完成，待 M0 可行性验证

## 1. 目标

用 Mac **内置蓝牙**把系统音频以 LDAC 推给耳机，做到：

- **稳定**：连续播放 24 小时零手动干预；合盖睡眠、走出范围、bluetoothd 重启、来电之后都能自动恢复。
- **完整**：44.1/48/88.2/96 kHz；自适应码率；音量、媒体键；真实延迟上报（视频音画同步）；通话时平滑交还 macOS。
- **安全**：不关 SIP、无内核扩展、无 root 常驻进程；共享内存不对其他用户开放。
- **诚实**：界面上显示实际码率、丢包和链路状态，不虚报 "990 kbps"。

非目标（第一版）：aptX 系列、LE Audio、iOS、多耳机同时输出。

## 2. 参考项目结论

| | CodecBlue（MIT） | hires-buddy（GPL-3.0） |
|---|---|---|
| 拿通道 | bluetoothd 私有 XPC `com.apple.server.bluetooth.classic.xpc`，消息 29 `openChannel`，fd 从 `kCBMsgArgSocket` 取出 | 私有 `-[IOBluetoothDevice classicPeer]` → `CBClassicPeer openL2CAPChannel:`，KVC 读 `_socketFD` |
| 两条 0x19 通道 | 每个 XPC session 只能开一条 → 开 6 个 session | 同上限制 → 辅助进程 + SCM_RIGHTS 传 fd |
| 接管耳机 | 强制断开后抢在 bluetoothd 之前开通道；**先占 AVRCP、HFP** 阻止 macOS 重连 | 断开基带再重连，硬抢；不占 AVRCP，于是 bluetoothd 每 ~10 s 重试，出现杂音 |
| 吞吐 | **LQM（Broadcom 厂商命令）** 是关键：关掉约 50 kbps，打开约 440 kbps。靠伪造 `BTAudioHALPlugin.xpc StartAudio` 骗 bluetoothd 发出，格式错一点就会把 bluetoothd 搞崩 | 未处理，990 kbps 卡顿，默认 660 kbps |
| AVDTP | 较完整，对端命令回 not-supported，支持 delay report 协商 | 精简，对端命令一律 ACCEPT |
| MTU | 固定 679（为了塞进 2-DH5） | 固定 679（真实 MTU 读了没用） |
| 码率自适应 | 有：按实测 goodput 选档 + 抖动缓冲伸缩 | 无 |
| 音频捕获 | 自写 AudioServerPlugIn + `/tmp` 0666 mmap 环形缓冲 | BlackHole 改版回环，要麦克风权限 |
| 漂移 | 线性插值挤压（无滤波） | 无 |
| 掉线 / 睡眠 | 回调没接线，靠进程退出让 launchd 重启；睡眠完全没处理 | 轮询恢复输出设备 |

两边都依赖 macOS 26–27 才有的私有接口，都没有版本检测。

## 3. 关键风险：本机是 Apple N1 蓝牙芯片

本机是 **Apple N1（PCIe）**，不是参考项目测试用的 Broadcom 芯片，所以：

1. **LQM 是 Broadcom 厂商命令，在 N1 上可能不存在，也可能根本不需要。** CodecBlue 整套最脆弱的 "AudioStreamKeeper" 可能直接作废，也可能需要找 N1 上对应的机制。
2. **吞吐上限要重新测。** CodecBlue 的 ~410 kbps 来自 bluetoothd 中转加 LQM 调度，而且从没用上 3-DH5。如果 N1 能用 3-DH5，990 kbps 就有希望。
3. 两种拿通道的方式在 N1 / macOS 27.0.1 上是否都能用，要实测确认。

**所以第一步不是写产品，而是 M0 可行性探针。** 探针结果决定后面的架构分支。

> **M0 已完成（2026-11-20）**。要点：N1 不需要 LQM，裸跑就有约 800 kbps；660 kbps 实时 30 s 零阻塞；990 档撑不住；`CBClassicPeer` 路线可用，但媒体通道要等 6–25 s。

## 4. 架构

```
┌──────────────┐  共享内存环 (私有, 原子)   ┌───────────────────────────────┐
│ HAL 驱动      │ ───────────────────────▶ │ ldacd（用户态守护, LaunchAgent）│
│ AudioServer   │  ◀── 延迟/状态回写 ────── │                                │
│ PlugIn        │                          │  Supervisor 状态机              │
└──────────────┘                          │   ├ Transport（通道获取，可替换） │
                                          │   ├ AVDTP 发起端 + 应答端        │
┌──────────────┐  XPC/本地 socket          │   ├ AVRCP / HFP 占位与转发       │
│ 菜单栏 App    │ ◀──────────────────────▶ │   ├ 重采样 + 漂移 PI 环          │
└──────────────┘                          │   ├ LDAC 编码 (libldac)          │
                                          │   └ RT 发送线程 + 码率控制器      │
                                          └───────────────────────────────┘
```

### 4.1 Transport 层（隔离所有私有接口）
- 统一接口：`open(psm) -> (fd, outMTU)`、`close`、`linkState` 事件流、`forceDisconnect`、`connect`。
- 两个后端：`XPCClassicTransport`（CodecBlue 路线）和 `ClassicPeerTransport`（hires-buddy 路线），启动时探测并选可用的那个。
- **版本表 + 运行时预检**：按 macOS build 号选消息表，预检失败就优雅降级，把耳机交还系统，绝不崩 bluetoothd。
- 所有私有接口集中在这一层，升级系统后只需改这一层。

### 4.2 接管策略
- 学 CodecBlue：**先占 AVRCP（0x17）和 HFP（RFCOMM）**，让 bluetoothd 没有理由重连 A2DP，从根上消掉"10 s 杂音"。
- 抢通道用事件驱动加超时，不用写死的 sleep；每一步都带 epoch/token，可取消。
- 交还：优先尝试"原地交还"（不断链），失败再走断开重连。

### 4.3 AVDTP
- 完整的发起端和应答端：DISCOVER、GET_(ALL_)CAPABILITIES、SET/GET_CONFIGURATION、RECONFIGURE、OPEN、START、SUSPEND、CLOSE、ABORT、DELAY_REPORT。
- SOCK_STREAM 会丢掉消息边界：用"能力 TLV 自描述长度 + 按信号类型的结构化解析"重建边界，并配上 fuzz 测试。
- 校验对端声明的采样率和声道模式，取交集。

### 4.4 媒体发送
- 专用实时线程（`thread_policy_set` 设成 time-constraint），按包计算 `mach_wait_until` 截止时间。
- 用真实的 `outMTU`；L2CAP SDU 大小作为实验参数（按 2-DH5 或 3-DH5 的载荷对齐），由 M0 测出最优值。
- 在 M0 确定发送缓冲深度：SO_SNDBUF 设为 1 个包还是 N 个包。
- **码率控制器**：输入 EAGAIN/stall、实测 goodput、队列深度；输出 LDAC 档位（990/660/492/396/330）。降档快、升档慢，失败过的档位指数退避。

### 4.5 音频捕获（M2 已实现）
- 虚拟输出设备 "Fidelis"：`Driver/` 改编自 Sendspin for Mac 的驱动（Apache-2.0），基于 libASPL（MIT，submodule 固定在 v3.1.2）。不自写驱动：属性分发、音量和静音控件、采样率切换这些最容易漏的边界，交给成熟的库。BlackHole 和 Background Music 是 GPL，不用。
- 驱动内部的环形缓冲按设备 sample time 索引，用 seqlock 防读到写一半的数据（RT 写端从不等待）。断档读出来是静音，时间线重启时换 session 编号。
- IPC 不走共享文件：App 通过自定义设备属性 `'fdau'` 按 sample time 读音频，驱动用内核记录的代码签名（`csops`）核对调用方，只给 `dev.fidelis.app`。这样不碰 coreaudiod 沙盒，也没有 `/tmp` 下 0666 的文件（CodecBlue 的弱点）。注意：ad-hoc 签名的开发版只能按 identifier 核对，正式发布要用 Developer ID 签名，让驱动按 team 核对。
- 音量和静音由 libASPL 默认的 `OnProcessMixedOutput` 直接乘到混音上（没有 AVRCP 绝对音量，耳机自己调不了），所以音量键可用。
- 延迟：App 用自定义属性 `'fdlu'`（µs）告诉驱动，驱动报成输出流延迟。数值 = FIFO 目标 40 ms + 发送提前量 10 ms + 耳机延迟。耳机支持 AVDTP Delay Reporting 时用它报的值，否则按 150 ms 估算（EH500 不支持）。每次修改都会让设备 IO 重启一下，所以变化小于 20 ms 就不改。
- App 侧（`SystemAudio.swift`）：一个静音 IOProc 让设备持续运行、时间线不断；每 5 ms 轮询 `'fdau'`，写入无锁 SPSC FIFO；媒体线程按 LDAC 节奏取走。先积到 40 ms 再出声；欠载时补静音并重新预充；积压超过目标 60 ms 就丢回目标值。
- 全链路 Float32：libldac 支持 `LDACBT_SMPL_FMT_F32`，内部本身是浮点，所以不在 16 bit 截断。
- 默认输出切换（`OutputRouter.swift`）：开始时（接管之前，因为耳机离开 macOS 后系统会自动切到扬声器）按 UID 记下当前输出，存进 UserDefaults；开始推流后切到 Fidelis；停止后等原设备重新出现（最多 12 s）再切回去。崩溃后下次启动也会恢复。
- 驱动的采样率只开放 LDAC 的 44.1/48/88.2/96 kHz，并由 App 设成协商好的那个，所以中间不重采样。

### 4.6 漂移与重采样
- 不需要重采样器：libASPL 设备的时钟就是 host time × 标称采样率，MediaStreamer 也按 mach 时钟定节奏，两边同一个时钟，FIFO 水位保持稳定（实测 45 s 内 0 欠载、0 丢弃）。
- 耳机 DAC 相对 Mac 时钟的漂移由耳机端自己吸收（A2DP 发射端本来就按自己的时钟发）。如果以后发现某些耳机缓冲会慢慢漂空或漂满，再在发送节奏上加一个很小的 PI 微调。

### 4.7 Supervisor（稳定性核心）
显式状态机：

`Idle → Acquiring → Configuring → Streaming ⇄ Suspended → HandingBack → Idle`，另有 `Recovering`。

处理的事件包括：
- 通道关闭、链路断开
- 蓝牙电源开关
- bluetoothd 重启（XPC 连接失效）
- 系统睡眠与唤醒（`IORegisterForSystemPower`）
- 默认输出设备变化
- 通话（HFP 的 AT 事件，比"任何进程在用麦克风"更精确）

每个状态都有超时和明确的退路。守护进程本身不靠退出来恢复，launchd 只是最后的保险。
崩溃恢复：启动时检查并恢复默认输出设备，耳机状态复位。

### 4.8 可观测性
- 结构化日志（os_log 子系统），环形保存最近 N 分钟的指标：码率、goodput、stall、队列、漂移 ppm、延迟。
- 菜单栏实时显示；一键导出诊断包。

## 5. 里程碑

| 编号 | 内容 | 退出标准 |
|---|---|---|
| **M0 可行性探针** | 只做 CLI：1) 两种 Transport 在本机能否拿到 0x19 的 fd；2) 用 LDAC 耳机跑 AVDTP 到 START；3) 洪泛测吞吐，覆盖不同 SDU 大小和 SNDBUF 深度，有无 AVRCP 占位；4) 查 N1 上有没有 LQM 的等价物 | 得到 N1 上可持续吞吐数据，选定 Transport 后端 |
| M1 播放 WAV | CLI 把 WAV 文件以 LDAC 播放 10 分钟不中断；AVDTP 单元测试 + fuzz | 10 分钟零断流 |
| M2 系统音频 | HAL 驱动（改编 Sendspin，基于 libASPL）+ FIFO；同一时钟，无需重采样 | 系统音频 1 小时零断流，延迟上报准确（已过 45 s 实测，长测待做） |
| M3 稳定性 | Supervisor 状态机 + 故障注入：`killall bluetoothd`、睡眠唤醒、走出范围、来电、关蓝牙 | 每类故障 20 次全部自动恢复 |
| M4 质量 | 码率控制器、AVRCP 音量/按键、delay report | 24 小时浸泡测试通过 |
| M5 产品化 | 菜单栏 App、安装/卸载、签名公证、诊断导出 | 新机器 5 分钟内装好可用 |

## 6. 测试策略
- **单元测试**：AVDTP 编解码、帧重建（fuzz）、码率控制器、PI 环、环形缓冲。
- **仿真**：假 sink（在 socketpair 上实现 AVDTP 对端，注入拒绝、延迟、半包）。
- **实机**：至少 2 款 LDAC 耳机（索尼加另一个品牌）；浸泡测试脚本记录指标曲线。
- **故障注入脚本**：自动化 M3 的各类故障。

## 7. 许可与合规
- 本项目 MIT；libldac 是 Apache-2.0（只有编码器）。
- **不复制 hires-buddy 代码**（GPL-3.0），只参考思路；CodecBlue（MIT）的代码如有借用，保留版权声明。
- 私有协议的字段表属于事实信息，自行实现。
- 个人使用没有问题；如果要公开分发，需注意 LDAC 的商标和认证问题。

## 8. 开发环境说明
- 开发机的 SIP 是关的。我们利用它来调试：对 bluetoothd 挂 dtrace/lldb，抓取它真实收发的 XPC 字典，代替 CodecBlue 那种靠猜的逆向。**产品本身必须在 SIP 开启时工作**，任何只有关 SIP 才能用的手段都只能作为诊断工具。
- 语言：
  - 私有蓝牙接口层用 Objective-C；
  - HAL 驱动和实时音频用 C；
  - libldac 本身是 C；
  - 守护进程主体和 UI 建议用 Swift（备选 Rust + objc2），在 M1 开始前定下来。

## 9. 已定决策（2026-11-20）
- **语言**：Swift 写主体（`FidelisCore` 和 App），Objective-C 写私有蓝牙层（`FidelisBluetooth`），libldac 是 C。
- **GUI**：只做一个原生菜单栏菜单（`MenuBarExtra` 的 `.menu` 样式），风格参照 Notchless：一行状态、"LDAC 输出"开关、耳机 / 码率 / 音源三个子菜单、登录时启动、拷贝诊断日志、退出。不做浮窗面板。
- **系统版本**：只官方支持 macOS 27；macOS 26 标注为"未测试，不一定不能用"（`LSMinimumSystemVersion` 设为 26.0，运行时用 `privateAPIAvailable` 预检）。
- **单进程 + 辅助进程**：App 进程本身完全不持有 L2CAP 通道，信令和媒体通道**各由一个辅助进程**打开（`FidelisMediaHelper`，签名标识独立）。原因：
  - 一个请求如果一直没有回应，它所在的 client session 就会永久卡在 code 24，只有结束进程才能解开；
  - bluetoothd 的 session 名里带 pid，所以每个新进程就是一个新 session。

## 10. 接管机制：目前的理解
- **为什么会"抢输"**：AVDTP 1.3 §5.4 规定，耳机把 PSM 0x19 上**第一条**建立的 L2CAP 通道当作信令，之后的都当作媒体通道。链路一起来，bluetoothd 就会做 `A2DPService - handling connection that was pending` → `AVDTP_Connect`。如果它的通道先到耳机，我们那条就被当成媒体通道，DISCOVER 不会有回应。
- **`closeConnection` 不一定真的断链**：只有当前进程之前对这条链路调过 `openConnection`，它的 `closeConnection` 才会生效。所以要先 `openConnection`（链路已在时立刻返回），再 `closeConnection`。修了这一点之后，App 实测第 1 次就接管成功，耗时 1.03 s。
- **在链路断开时直接请求通道不会触发寻呼**：请求只会挂起，并让 session 卡在 code 24。所以必须先建好链路。
- **用 `CBClassicManager connectPeer:options:` 传 `kCBOptionServicesKey=[]`，挡不住 bluetoothd 启动 A2DP。**
- 待研究：
  - 媒体通道要等 6–25 s（期间收到 code -3 空回调）；
  - 能不能让 bluetoothd 对这个设备暂停 A2DP 自动连接（例如通过 bluetoothd 的 XPC 消息，SIP 关着可以挂 dtrace 去找）。

## 11. 待决问题
1. ~~测试用的 LDAC 耳机型号？~~ SIMGOT EH500（已确认支持 LDAC 44.1–96 kHz）。
2. Transport 后端：等 M0 结果再定。
3. ~~捕获方案~~：已定为虚拟输出设备（驱动），见 §4.5。process tap 需要录屏/录音权限，而且拿不到音量键和延迟上报。
4. 最低支持的 macOS 版本：建议只支持 macOS 27 起，按 build 号维护消息表。
