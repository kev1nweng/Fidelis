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

### 4.5 音频捕获
- 自写 AudioServerPlugIn 驱动（不用 BlackHole，避免 GPL，也不需要麦克风权限）。
- 环形缓冲：两端都用原子操作；写入时带 sample time，能检测断档和溢出；放在只有本用户可访问的位置。coreaudiod 沙盒里能用哪些机制，需要调研。
- 通过 `kAudioDevicePropertyLatency` 上报真实延迟（抖动缓冲 + 环 + 耳机 delay report）。
- 备选：Core Audio process tap（macOS 14.2+），省掉驱动，但需要"录制系统音频"权限。M2 时对比两种方案。

### 4.6 漂移与重采样
- PI 控制环跟踪环形缓冲深度，驱动高质量异步重采样器（如 speexdsp / libsamplerate，BSD 许可），把比例偏差控制在 ±0.5% 以内，听不出来。
- 耳机 DAC 时钟的漂移由同一个环路吸收。

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
| M2 系统音频 | HAL 驱动 + 环 + 重采样；对比 process tap | 系统音频 1 小时零断流，延迟上报准确 |
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

## 8. 待决问题
1. 测试用的 LDAC 耳机型号？
2. Transport 后端：等 M0 结果再定。
3. 捕获方案：驱动还是 process tap，等 M2 对比后定。
4. 最低支持的 macOS 版本：建议只支持 macOS 27 起，按 build 号维护消息表。
