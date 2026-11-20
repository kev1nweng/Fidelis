# M0 可行性探针：结论

日期：2026-11-20
环境：Apple Silicon，macOS 27.0.1 (26A434)，蓝牙芯片 **Apple N1**（PCIe），SIP 关闭（探针没有用到这一点）
耳机：SIMGOT EH500（固件 2.4.0）
代码：`Sources/FidelisProbe/`，运行入口 `scripts/probe.sh`

## 结论速览

| 问题 | 结果 |
|---|---|
| 私有接口在 macOS 27.0.1 上还在吗 | ✅ `-[IOBluetoothDevice classicPeer]`、`CBClassicPeer open/closeL2CAPChannel:`、`CBL2CAPChannel socketFD/outgoingMTU` 都在 |
| 不关 SIP、只做 ad-hoc 签名能用吗 | ✅ 只需要蓝牙 TCC 授权（打包成 .app 运行） |
| EH500 支持 LDAC 吗 | ✅ SEID 3：LDAC 44.1/48/88.2/96 kHz，单声道/双声道/立体声 |
| 能完整走完 AVDTP 吗 | ✅ DISCOVER → GET_ALL_CAPABILITIES → SET_CONFIGURATION → OPEN → 媒体通道 → START → CLOSE，全部被接受 |
| **660 kbps 能稳定吗** | ✅ **以实时速率跑 30 s：125.0 包/s，写入零阻塞，零 EAGAIN** |
| 990 kbps 能稳定吗 | ❌ 链路实际只有约 740–860 kbps（每包 661 B，约 150 包/s），积压约 6–11 s 后链路断开 |
| 需要 LQM 那套 hack 吗 | ❌ **不需要**。N1 上什么都不做就有约 800 kbps，是 CodecBlue 在 Broadcom 上测到的 ~410 kbps 的两倍 |

## 实测数据

| 测试 | 设置 | 结果 |
|---|---|---|
| flood（尽可能快地发） | eqmid 0，48 kHz，默认 SNDBUF 8192 | 前 6 s 稳定在 805–822 kbps，单次写最长阻塞 44 ms；之后写入阻塞约 55 s，最终 EPIPE |
| paced（按实时速率发） | eqmid 1（660），48 kHz | 30 s 全程 673 kbps（含 RTP 头），单次写最长 0.0 ms |
| paced | eqmid 0（990），48 kHz | 需要 188 包/s，实际只有 137–159 包/s；11 s 后阻塞约 50 s，最终 EPIPE |

## 发现的坑（都影响产品设计）

1. **`closeL2CAPChannel:` 的参数是 PSM（`uint16`），不是 channel 对象。** 运行时类型编码是 `v20@0:8S16`。传错参数时关闭不会生效，bluetoothd 认为这个 session 还占着 0x19，之后的请求都返回 **24**。
2. **结果码 24 = 本 session 已有一个未完成的请求，或已有同 PSM 的通道。** 一个进程只能拿一条 0x19 通道，所以媒体通道必须由**另一个进程**去开。实测发现这个辅助进程有两个要求：
   - 签名标识要独立（`dev.fidelis.probe.helper`），并嵌入自己的 Info.plist；
   - 开通道前自己调一次 `openConnection`。
   满足这两点后仍然要等 6–25 s（中间收到两次 code -3 的空回调），通道才会到手。这一步是目前最慢、最不确定的环节，M1 要专门攻关。
3. **抢通道是概率事件。** 拿到信令通道后用 DISCOVER 验证：没有回应，说明 macOS 自己的 A2DP 已经抢先建立了。有一次连输 10 回，之后改为"链路断开时直接请求通道"，那次一次就成功了。样本还太少，没有统计意义。
4. **超过链路容量的后果不是丢包，而是断线。** 写入阻塞数十秒后 EPIPE，耳机断开。所以码率控制器必须在积压出现的第一时间就降档；990 档默认不开放，除非链路实测能撑住。
5. **libldac 固定按 2-DH5 打包**（`tx_size = 679 − 18 = 661 B`），而 bluetoothd 给的 outMTU 也正好是 679。要上 3-DH5 需要更大的 MTU，目前拿不到。这就是 990 档跑不满的直接原因。
6. EH500 没有声明 Delay Reporting（category 8），所以延迟上报只能靠我们自己估算。
7. 工具链：Xcode 26.2 的 clang 会去找 CLT 的 macOS 27 SDK，链接失败；SwiftPM 的新构建系统报 "Unknown error parsing property list"。目前统一用 `DEVELOPER_DIR=/Library/Developer/CommandLineTools`，直接调 clang 编译。

## 对设计的影响

- 删掉 DESIGN §3 里的 LQM 风险；N1 不需要 AudioStreamKeeper 那套东西。
- 默认档位改为 **660 kbps**，并作为稳态目标。492/396/330 用来应对干扰，990 只在实测余量充足时开放。
- Transport：在 N1 + macOS 27 上，`CBClassicPeer` 这条路**已经证明能用**。CodecBlue 的 XPC 路线保留为备选，在媒体通道打开太慢的问题解决不了时启用。
- 必须新增"接管"子系统的设计：信令抢占策略、辅助进程常驻（预先建好 session，免得临时等待）、断线检测。

## 下一步（M1 前置）

1. 媒体通道提速：辅助进程常驻并预热；查清 code -3 空回调是怎么回事；必要时试 XPC 路线。
2. 抢占成功率：每种策略各跑 20 次，统计成功率和耗时。
3. 搞清楚过载后为什么断线（flush timeout？耳机主动断开？），用 PacketLogger 或 `log stream` 抓证据。SIP 关着正好可以在 bluetoothd 上挂 dtrace。
4. 播放真实音乐（WAV → LDAC 660），用耳朵听。
