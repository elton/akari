# akari 技术方案

> 2026-08-19 · 基于 12 路并行技术调研（含 3 路逐条一手证伪）+ 本机实测
> 决策依据见 [`decisions.md`](./decisions.md)，调研原文见 [`research/`](./research/)

---

## 一、这是什么

一个常驻 Mac 桌面的写实风虚拟角色。她贴在壁纸层上呼吸、眨眼、转头，
你按住热键跟她说话，她用语音回答；她能读出你选中的文字、查你的日程、
帮你跑脚本、改文件——每一件有风险的事都先问过你。

**产品上真正的取舍只有两条**：

1. **要"好看"就得放弃"随心所欲地动"。** 写实感只能靠预先生成好的循环视频，
   所以她的动作是有限的几种状态，口型也只是"说话时嘴在合理地动"，对不上每个字。
   反过来，选二次元 Live2D 就能实时驱动一切，但那不是你想要的样子。
2. **要"能干活"就得放弃 App Store。** Apple 明确答复：沙盒应用不能读别的应用的界面内容。
   而"读出你选中的文字"这个最基础的需求就要这个能力。所以分发只能走 Developer ID 公证。

**成本的大头是时间不是钱。** 云端推理每月百元级，素材生成的积分你账上够用，
真正的投入是 30–50 个工作日。

---

## 二、已定决策速览

| # | 决策 | 一句话理由 |
| --- | --- | --- |
| ADR-001 | 形象 = 预渲染 AI 视频循环 | 写实风在 2026 年没有实时方案能在 Mac 上跑 |
| ADR-002 | 电脑控制 = 白名单 + 四级确认门 | GUI agent 准确率 86% ≈ 每 7 步错 1 步，不能无人值守 |
| ADR-003 | 推理 = 云端为主 + Provider 抽象 | 先跑通，本地留成配置项而非重写 |
| ADR-004 | 语音 = Realtime 端到端 | 实测首包 473ms，且服务端包办 VAD 与打断 |
| ADR-005 | v1 = 按住热键说话 | 一个决定同时绕开唤醒词误触发与 AEC 两个大坑 |

---

## 三、系统架构

### 3.1 进程划分

两个进程，各司其职，用 **Unix domain socket** 通信
（调研警告：Tahoe 26.3.x 上本地 HTTP 端口会因 Local Network 权限问题连不上，别用）。

```
┌─────────────────────────────────────────────────────────┐
│  akari.app  (Swift / AppKit)          ~2000 行，薄胶水层  │
│                                                          │
│   桌面层窗口      NSWindow.level = desktopIconWindow-1    │
│   形象渲染        AVPlayerLayer 播 HEVC-alpha 循环        │
│   菜单栏          NSStatusItem                           │
│   音频 I/O        AVAudioEngine 采集/播放 PCM             │
│   系统能力        AX / Shortcuts / shell / ScreenCapture  │
│   确认门 UI       RED 级操作的确认卡片                     │
└────────────────────────┬────────────────────────────────┘
                         │  Unix socket (JSON + PCM 帧)
┌────────────────────────┴────────────────────────────────┐
│  akari-core  (TypeScript / Bun)       业务逻辑主体        │
│                                                          │
│   Realtime 客户端  WebSocket → qwen3.5-omni-flash-realtime│
│   Provider 抽象    LLM / ASR / TTS 各自可换实现            │
│   工具注册表       四级风险分类 + 执行编排                  │
│   人格与记忆       系统提示词 + Markdown 落盘的长期记忆      │
└──────────────────────────────────────────────────────────┘
```

**为什么这样切**：你的主力语言是 TypeScript，所以业务逻辑（工具、人格、编排、记忆）
全部留在 TS 侧；Swift 只写一层不含业务判断的系统胶水，而且这层有现成代码可抄
（见 §4.6）。音频经本地 socket 多一跳，延迟增加 1–3ms，可忽略。

### 3.2 一次语音交互的完整路径

```
按住热键
  └→ Swift: AVAudioEngine 开始采集 PCM16
       └→ socket → TS: 转发到 Realtime WebSocket
            └→ 服务端 server_vad 判定说话结束
                 └→ 模型生成，473ms 后首个音频包回来
                      ├→ TS → socket → Swift: 播放 PCM
                      └→ Swift: 形象切到 talking 状态循环
       若模型发起 function call:
            └→ TS: 查工具表 → 判定风险级别
                 ├→ GREEN  直接执行，结果回传模型
                 ├→ YELLOW 通知 Swift 显示 1.5s 可撤销提示
                 └→ RED    通知 Swift 弹确认卡片，等用户点头
```

### 3.3 形象状态机

```
        ┌──────────────────────────────────┐
        ↓                                  │
  ┌──────────┐  按住热键   ┌───────────┐    │
  │   idle   │ ─────────→ │ listening │    │
  │ 呼吸/眨眼 │            │  微微侧头  │    │
  └──────────┘ ←───────── └─────┬─────┘    │
        ↑        松开             │ 松开     │
        │                        ↓          │
        │                  ┌──────────┐     │
        │                  │ thinking │     │
        │                  └────┬─────┘     │
        │                       │ 首包到达   │
        │                       ↓           │
        │                  ┌──────────┐     │
        └───────────────── │ talking  │ ────┘
             播放结束        └──────────┘
```

切换用 3–5 帧交叉溶解掩盖姿态不连续。调研提醒：
**`AVPlayerLooper` 与 `AVVideoComposition` 互斥**，"无缝循环"和"逐帧滤镜"二选一——
所以溶解要在两个 `AVPlayerLayer` 之间做 opacity 动画，不能靠 composition。

---

## 四、技术选型

### 4.1 桌面层窗口 —— 风险最低的一块

调研在 macOS 26.6.1 / M4 Max 上实测出真实窗口层归属：

```
Dock 进程「Wallpaper-<UUID>」       -2147483624   ← 真壁纸在这
       〔可用区间〕
Finder 桌面图标                     -2147483603
```

所以正确的 level 是 **-2147483604**（图标层减一），可编译代码：

```swift
window.level = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                             .ignoresCycle, .fullScreenNone]
window.isOpaque = false
window.backgroundColor = .clear
window.ignoresMouseEvents = true
window.isReleasedWhenClosed = false   // 默认 true，配 CoreAnimation 会 over-release 崩溃
```

**零 entitlement**，有 MAS 上架先例（Wallnetic，MIT，可直接抄 `DesktopWindowController.swift`）。
功耗实测：2560×1440@60fps HEVC 硬解，M4 Max 上 CPU 1.0–3.6%、内存 47MB。

省电靠 `NSWindow.didChangeOcclusionStateNotification` + 锁屏通知，
但**锁屏通知必须注册在 `DistributedNotificationCenter` 且用 `.deliverImmediately`**，
注册在 `NotificationCenter.default` 上永远收不到。

**已知死路，别浪费时间**：Wallpaper Extension 需要私有 entitlement（第三方拿不到）；
`.saver` 屏保只在空闲时播；`setDesktopImageURL` 只吃静态图；锁屏界面盖不住。

### 4.2 语音 —— 实测数据

| 轮次 | 握手 | 首个文本 | 首个音频 | 整轮 |
| --- | --- | --- | --- | --- |
| 1 | 464ms | 227ms | 473ms | 781ms |
| 2 | 335ms | 229ms | **398ms** | 733ms |
| 3 | 338ms | 647ms | 915ms | 1284ms |

`session.created` 直接返回：

```json
"turn_detection": { "type": "server_vad", "threshold": 0.5,
                    "silence_duration_ms": 800, "interrupt_response": true }
```

服务端负责端点判定和打断。调研原文说拼装方案的打断「必须同时停 TTS 播放、
cancel TTS 请求、abort 流式 LLM，漏一环就是『她还在自说自话』的破功感」——这块整个省掉。

**硬限制**：RPM 60、单会话最长 120 分钟、不支持上下文缓存、
音频上下文截断 80 轮/480 秒。长会话要自己做摘要与重连。

### 4.3 大脑

| 用途 | 模型 | 单价（每百万 token） |
| --- | --- | --- |
| 主力对话 / 工具调用 / 看截图 | **`qwen3.7-flash`** | ¥0.2 / ¥0.8，缓存命中 ¥0.04 |
| 语音对话 | `qwen3.5-omni-flash-realtime` | 音频 ¥27 入 / ¥107 出 |
| 复杂任务升级 | `qwen3.7-plus` | ¥2 / ¥8 |
| 本地（隐私模式） | `orcarouter/Qwen3.8-27B-Uncensored-MLX` 6-bit，22.8GB | 免费 |
| 备选托管 | `@cf/qwen/qwen3.8-27b`（CF Workers AI） | 免费额度内 |

全部已用本项目的 key 实测可用。`qwen3.7-flash` 原生支持图像输入，
**看屏幕截图不需要单独接 VL 模型**。

调研提醒：版本号大 ≠ 更便宜，`qwen3.6-flash` 的输出价是 `qwen3.7-flash` 的 **9 倍**。

### 4.4 电脑控制

**主路径是 Accessibility API**，实测对 Finder / Chrome / VS Code / IntelliJ / 微信全部可用，
Chrome 在 depth≤8 就暴露 8560 个节点。

三条必须写进实现的硬约束：

1. **必须调 `AXUIElementSetMessagingTimeout(app, 1.0~2.0)`**，
   否则一个卡死的 App 会阻塞整个 agent，直接让壁纸动画掉帧。AX 遍历一律放后台队列。
2. **读选中文字在 Electron 应用上必挂**（VS Code 实测 0 个可读文本节点）。
   必须三级 fallback：AX → 保存剪贴板 → 模拟 Cmd+C → 读 → **恢复剪贴板**。
   最后一步最常被忘，会吃掉用户原本复制的内容；用 `NSPasteboard.changeCount` 判断是否真变了。
3. **责任进程陷阱**：终端里编译的裸二进制 `AXIsProcessTrusted()` 直接返回 true，
   因为 TCC 把权限归属到终端。**开发期你会以为不用申请权限，打包成 .app 后全部失效。**
   必须尽早用真实签名 .app 测权限流程。

**截图是提示注入的正门**——屏幕上任何文字都能冒充指令。防御必须是架构级的：
截图内容一律标记为 untrusted，读过 untrusted 之后的任何状态变更类工具调用强制走确认门；
shell 能力与外部内容处理绝不放进同一个上下文。

### 4.5 权限与分发

- **放弃 Mac App Store**（沙盒不能用 AX），锁定 Developer ID + 公证 + stapler，$99/年。
- 权限绑定代码签名与 bundle id，**换证书或改 bundle id 会让用户已授予的权限静默失效**。
- 屏幕录制权限每月重新弹窗 → 截图能力做成按需开启，不要开机常驻。
- 全量放开要点 12–15 次 → **必须分阶段渐进授权，首启只要麦克风**。

### 4.6 可直接抄的代码

| 来源 | 抄什么 | License |
| --- | --- | --- |
| `fatihkan/wallnetic` | `DesktopWindowController.swift` 窗口配置 + `PowerManager.swift` 省电 | MIT |
| `moeru-ai/airi` | `services/computer-use-mcp` 整包（全网唯一落地的 macOS 控制 MCP） | MIT |
| `openclaw/Peekaboo` | AX + ScreenCaptureKit + 点击的 Swift 参考实现 | MIT |
| `kiyotakali/Miru` | 记忆 schema（纯 Markdown 落盘，不上向量库） | Apache-2.0 |

**AIRI 要按包窃取，不要 fork 整仓**（monorepo 极大且日更，rebase 成本极高），剥离约 1–2 人周。

**许可传染名单**（只能读设计，不能抄进代码）：MirageWallpaper / MacArkPet / Soul-of-Waifu = GPL-3.0；
LingChat / super-agent-party = AGPL-3.0；LivePortrait / MuseTalk = 自定义许可。

---

## 五、形象素材生产管线

```
① 定妆图    Nano Banana 2  +  character 参考图（你提供的照片）
              → 正面全身 / 侧身 / 不同服装，2K，约 100 积分/张
                     ↓
② 循环视频  Seedance 2.5   keyframes.start = keyframes.end = 定妆图
              → 首尾闭合的无缝循环，6 秒
                     ↓
③ 抠像      若 .mov 不带 alpha → MatAnyone2 抠像
                     ↓
④ 编码      ffmpeg → HEVC with alpha (.mov)
              -alpha_quality 0.9~1.0   ← 不是 0.1！
              -q:v 60~75
              先不加 -require_sw
                     ↓
⑤ 验证      AVAsset 检查 containsAlphaChannel
```

**ffmpeg 参数是证伪核查纠正过的**：调研初稿写 `-alpha_quality 0.1`，
而 Apple 文档明确该值域为 0–1 且 **1 接近无损**。0.1 会让发丝边缘出现锯齿、
半透明区块状、边缘暗环——对一个全屏常驻的人像是致命的。

### 素材预算（已查实价）

| 项 | 单价 | 备注 |
| --- | --- | --- |
| Nano Banana 2 出图 | ~100 积分 | |
| Seedance 2.5 · 6s · 1080p | **4,740 积分** | |
| Seedance 2.5 · 6s · 720p | **2,640 积分** | |

账户余额 **320,423 积分**。一套 8 状态素材：1080p 约 37,920 积分，720p 约 21,120 积分。
**余额够做 8 套 1080p 或 15 套 720p**，但试错会消耗数倍——
所以 §6 的 P1 阶段先用 720p 跑通全流程，确认 alpha 链路后再出 1080p 正式素材。

调研警告两点：**素材体积会爆炸**（8 状态 × 4 套服装 × 6s × 1440p60 HEVC-alpha ≈ 0.5–1.3GB，
必须按需下载）；**AI 生成片段首尾姿态不闭合**，需锁死起始 pose + 手工挑帧 + 交叉溶解，
这部分占素材流水线一半以上工时。

---

## 六、分阶段实施

### P0 · 骨架打通（8–12 人天）

目标：**桌面上出现一个会说话的方块**。形象用纯色占位视频，重点验证管道。

- [ ] Swift 桌面层窗口 + AVPlayerLayer 播占位循环视频
- [ ] 菜单栏常驻 + 退出/设置入口
- [ ] Unix socket 双向通信（Swift ↔ Bun）
- [ ] 音频采集/播放 PCM16
- [ ] TS 侧接通 Realtime，按住热键完成一轮语音问答
- [ ] **验证 RISK-2**：桌面层窗口在 Space 切换 / Mission Control / 全屏 App 下的行为

**这一阶段结束时你应该能对着 Mac 说话并听到回答。**

### P1 · 形象素材（8–15 人天，含大量试错）

- [ ] **先验证 RISK-1**：用 720p 生成一段测试视频，`ffprobe` 确认 `.mov` 是否带 alpha
      → 带：直接进编码；不带：加 MatAnyone2 抠像环节
- [ ] Nano Banana 2 出定妆图（character 参考 = 你提供的照片）
- [ ] Seedance 2.5 出 5 个状态循环（idle / listening / thinking / talking / 招手）
- [ ] 首尾闭合调优 + 交叉溶解
- [ ] HEVC-alpha 编码 + `containsAlphaChannel` 验证
- [ ] 状态机接入，替换占位视频

### P2 · Agent 能力（10–15 人天）

- [ ] 工具注册表 + 四级风险分类
- [ ] GREEN：读选中文字（含三级 fallback）、朗读、开 App、查日历、剪贴板
- [ ] YELLOW：工作区内写文件、建日程、跑快捷指令 + 1.5s 可撤销提示
- [ ] RED：跑 shell、删除、发消息 + 确认卡片（展示原始命令）
- [ ] 从 AIRI 剥离 computer-use-mcp
- [ ] 长期记忆（Markdown 落盘）
- [ ] 提示注入防御：untrusted 标记 + 强制确认门

### P3 · 打磨与分发（5–8 人天）

- [ ] 渐进授权流程（首启只要麦克风）
- [ ] 省电策略（遮挡/锁屏/电池暂停）
- [ ] 多显示器（**用 `CGDirectDisplayID` 而非 `NSScreen` 当字典 key**，
      否则合盖再打开就崩）
- [ ] 本地 Provider 实现（MLX + 6-bit 权重）
- [ ] Developer ID 签名 + 公证 + stapler
- [ ] **用真实签名 .app 重测全部权限流程**

**合计 31–50 人天。**

---

## 七、成本

| 项 | 金额 |
| --- | --- |
| Qwen Realtime 语音（每天 1h） | ¥150–210/月 |
| `qwen3.7-flash` 文本 | 100 万 token 免费额度（2026-10-23 前），之后 ¥0.2/¥0.8 每百万 |
| 素材生成 | 现有积分足够，无需额外付费 |
| Apple Developer Program | $99/年（分发必需） |
| 本地推理 | 免费，代价是 22.8GB 内存常驻 |

---

## 八、风险与待验证

| ID | 风险 | 何时验证 | 若失败怎么办 |
| --- | --- | --- | --- |
| RISK-1 | Seedance 2.5 的 `.mov` 是否带 alpha | **P1 第一件事** | 加 MatAnyone2 抠像环节，+2–3 人天 |
| RISK-2 | 桌面层窗口在 Space / 全屏 App 下的行为 | **P0 第一天** | 退回浮动桌宠形态（level `.floating`） |
| RISK-3 | 透明像素点击穿透在 26.6.1 是否失效 | P0 | 用 16ms 轮询 `NSEvent.mouseLocation` 动态切 `ignoresMouseEvents` |
| RISK-4 | 本地 MLX 推理与 60fps 渲染争抢 GPU 的程度 | P3 | 本地模式下降帧到 30fps 或暂停动画 |
| RISK-5 | Realtime 实际月成本 | P0 后一周实测 | 切拼装方案（Provider 抽象已留口） |

**调研中标注为低置信度、不可直接采信的点**：
Realtime 官方标称延迟的口径（已被本机实测取代）；
声音复刻是否免费及样本时长要求（官方页显示"暂无公开定价信息"）；
音频 token 换算率（导致成本估算不确定）；
`occlusionState` 在桌面层的触发可靠性（单次实测未复现）。

---

## 九、开放问题（需要你拍板）

1. **语音走 Realtime 还是拼装？** Realtime 每月贵约 ¥120，换来 473ms→650-900ms 的延迟优势
   和省下 5–8 人天工程。当前 ADR-004 选了 Realtime，但成本论据已被勘误，此决定应重新确认。
2. **人格设定的尺度。** 本地模型选的是 uncensored 版本，云端 Qwen 有内容审核。
   两者的行为边界会不一致，需要明确期望。
3. **形象的服装套数。** 每套约 21,120（720p）或 37,920（1080p）积分，直接决定素材预算。
