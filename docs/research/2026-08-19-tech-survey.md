# akari 技术现状简报

> 来源：8 份技术调研 + 3 份证伪核查（Qwen 云端 API / macOS 桌面窗口 / 形象渲染三份被逐条一手核对）。凡与核查冲突处，本文一律采用**纠正后**版本并标注 `【已纠正】`。

---

## 一、6 条最重要的结论

1. **写实形象只能靠预渲染 AI 视频循环 + HEVC-with-alpha，不是实时渲染** —— 2026 年所有实时数字人 SOTA（LiveAvatar 14B、Ditto、MuseTalk）在 Apple Silicon 上**没有任何公开帧率实测**，代价是口型对不上，必须一开始就设计降级方案。
2. **对话大脑锁定 `qwen3.7-flash`（¥0.2/¥0.8 每百万 token，1M 上下文，原生图像+视频输入）**，语音走 ASR+LLM+TTS 拼装而非端到端 Realtime —— 成本差 4-5 倍（¥38-64/月 vs ¥150-210/月），且拼装链能吃到上下文缓存，Realtime 全系不支持缓存。
3. **桌面驻留窗口这条路完全通，零 entitlement、可上 MAS**：`NSWindow.level = CGWindowLevelForKey(.desktopIconWindow) - 1`（= -2147483604），已有 MIT 开源实现 + MAS 上架先例（Wallnetic）。这是整个项目风险最低的一块。
4. **但只要 akari 要"控制电脑"，就必须放弃 Mac App Store**：Apple DTS 明确答复沙盒 App 不能用 `AXUIElementCreateApplication` 读别的 App 的 UI 树。分发形态一开始就要定死为 Developer ID + 公证，别做双版本。
5. **【已纠正】Live2D 对 akari 不是"个人免费"**：只要支持换装/换形象/用户导入模型，就落入 Live2D 的 **Expandable Application** 定义，无论公司规模都必须**预审批 + 签 Publication License + 按每笔销售 ¥300 或销售额 20%（取高者）分成**，还要季度上报、强制展示 logo、强制进 Showcase。这是选型层面的否决项，不是可后补的法务细节。
6. **全本地不是"能不能跑"的问题，是资源竞争**：MLX 的 LLM 推理和 2560×1440@60fps 渲染抢同一块 GPU 与统一内存带宽。可行架构是"语音全推 ANE（Apple SpeechAnalyzer / CoreML TTS）+ GPU 分时给 LLM + 云端兜底"，不是把所有东西塞进 GPU。

---

## 二、Qwen 云端 API

### 文本主力（价格全部经官方文档一手核实，北京地域，每百万 token）

| 模型 ID | 输入/输出 | 上下文 | 视觉 | 备注 |
|---|---|---|---|---|
| `qwen3.7-flash` | **¥0.2/¥0.8**（≤32K）<br>¥0.6/¥2.4（32K-256K）<br>¥1.2/¥4.8（256K-1M） | 1M | ✅ | 缓存命中三档 **¥0.04/¥0.12/¥0.24** |
| `qwen3.7-plus` | ¥2/¥8（≤256K）<br>¥6/¥24（256K-1M） | 1M | ✅ | 快照 `qwen3.7-plus-2026-05-26` |
| `qwen3.8-max` | ¥12/¥36 | 1M | ✅ | 缓存命中 ¥1.5，Batch ¥6/¥18 |
| `qwen3.7-max` | ¥12/¥36 | 1M | **❌**【已纠正】 | 官方模型页模态只有"文本" |
| `qwen3.6-flash` | ¥1.2/¥7.2 | 1M | ✅ | 比 3.7-flash 输入贵 6×、**输出贵 9×**【已纠正】 |

全系 RPM 30000 / TPM 5,000,000，最大输出 131,072，思维链预算 262,144，Function Calling 全支持。
来源：`https://help.aliyun.com/zh/model-studio/qwen3-7-flash` 及同系列各模型页

**选型硬结论**：截屏理解不需要单独接 `qwen3-vl-plus`/`-flash`，直接塞进 `qwen3.7-flash` 的 `image_url`。版本号大 ≠ 便宜，`qwen3.6-flash` 比 `qwen3.7-flash` 贵一个数量级。

### 语音链路

- **ASR**：`qwen-audio-3.0-asr-flash-streaming` ¥0.00033/秒（≈¥1.19/小时），RPM 1200；离线版 `qwen-audio-3.0-asr-flash` ¥0.00022/秒，RPM 600，覆盖 7 大方言 + 20+ 口音 + 30 语种。
- **TTS**：`qwen-audio-3.0-tts-flash` **¥1/万字符，首包 <200ms**，RPM 180。高质量档 `qwen-audio-3.0-tts-plus`。
- **端到端 Realtime**：`qwen3.5-omni-flash-realtime`，音频输入 ¥27 / 音频输出 ¥107 每百万 token，**RPM 仅 60 / TPM 10 万**，不支持上下文缓存/Batch/结构化输出。
- 端点：`wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=...`
- OpenAI 兼容 base_url：`https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`（旧 `dashscope.aliyuncs.com` 官方写明"仍可正常使用"）

### 【已纠正】五条必须改掉的说法

| 原调研说法 | 核实结果 |
|---|---|
| WebRTC DataChannel 名叫 `oai-events` | **错**。官方原文："名称可自定义，服务端会通过名为 **`txt`** 的通道推送事件"。按 `oai-events` 监听会收不到任何事件 |
| Realtime 事件协议与 OpenAI 不兼容 | 文档**从未提及**兼容性比较，属作者推断，需实测才能定论 |
| Realtime 支持 55 个音色（47+8） | **数字系杜撰**。官方 voice-list 页无此合计数，实际按系列列出 100+ 个 |
| 声音复刻免费 / 10-20s 样本 / 每系列 1000 个 | **全部无法证实**。官方页显示"暂无公开定价信息"，无样本时长、无数量上限。唯一证实：`qwen-audio-3.0-realtime` 系列支持把复刻 `voice_id` 填入 `voice` 参数（格式 `qwen-audio-3.0-realtime-plus-myvoice-xxxxxx`） |
| AOQ = 自研 QUIC，仅 iOS/Android SDK，无 macOS | 协议存在属实，**底层与 SDK 平台覆盖均无文档依据** |

其余核实为真的关键约束：Realtime 单会话最长 120 分钟；音频上下文 flash 硬性截断 80 轮/480 秒（plus 100 轮/600 秒）；官方延迟基准 flash ≈5.1s / plus ≈5.8s（文档未说明是首包还是整轮）；Realtime 里联网搜索与工具调用不能同时开启；新人免费额度每模型 100 万 token / 90 天，**仅华北2（北京）**；ASR 模型需在控制台业务空间逐一开权限。

---

## 三、本地推理（Apple Silicon）

- **LLM 主力**：`mlx-community/Qwen3.5-9B-4bit`（磁盘 5.95 GB，含视觉塔，由 mlx-vlm 0.3.12 转换）。运行时四条路：`mlx_lm.server`（WWDC26 Session 232 官方推荐，OpenAI 兼容 127.0.0.1:8080）、Ollama 0.19 MLX runner（**要求统一内存 >32GB**，否则回落 llama.cpp）、LM Studio 0.4.14、`mlx-swift-lm`（分发最干净但架构支持滞后 Python 数周）。
  `https://huggingface.co/mlx-community/Qwen3.5-9B-4bit` / `https://ollama.com/blog/mlx`
- **ASR 首选 Apple `SpeechAnalyzer` / `SpeechTranscriber`**（macOS 26+）：`supportedLocales` 含 zh_CN/zh_HK/zh_TW/yue_CN，约 whisper large-v3-turbo 的 2 倍速度，零打包零内存、跑系统进程不抢 GPU。坑：模型经 `AssetInventory` 按语种下载，首次有等待；闭源无法加自定义词表。
- **TTS 必须上 Qwen3-TTS-12Hz**（Apache-2.0，3 秒克隆，`mlx-audio` 支持）或 GPT-SoVITS。**Kokoro 中文音色官方评级全是 D 且不支持克隆，对"固定人设"是死路**。
- **FluidAudio 的 ASR 不支持中文**（Parakeet TDT v3 只覆盖 25 种欧洲语言）——大量 2026 年 Mac 语音文章推荐它时不提这点。它的 Silero VAD 和说话人分离仍值得用（纯 ANE）。
- **延迟现实**：Apple 栈约 0.7–1.2s，全 Qwen 本地栈约 1.5–2.5s，行业"可接受"线是 600–800ms。Apple 自家论文 ChipChat 在 M2 Ultra 上全本地级联约 920ms（不含端点静默等待）。
- **内存预算**：Qwen3.5-9B-4bit ~6GB + KV cache + ASR ~1.2GB + TTS ~2GB + 渲染纹理。**16GB Mac 做不了全本地，建议 ≥32GB，舒适区 48-64GB**；Swift App 还要申请 `com.apple.developer.kernel.increased-memory-limit`。
- **网上 2026 年的 tok/s 对比站大量疑似 AI 批量生成**（llmcheck.net 上 M5 Max 64GB 和 128GB 跑同一模型都是 82 tok/s、TTFT 0.5s，明显模板填充）。落地前必须自己跑 `mlx_lm.benchmark`。

---

## 四、桌面窗口（本机 macOS 26.6.1 / M4 Max 实测）

### 可直接抄的窗口配置

```swift
window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1) // -2147483604
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
window.isOpaque = false; window.backgroundColor = .clear
window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
```

实测窗口层归属：Window Server `Display N Backstop` −2147483626 → Wallpaper 进程 `Offscreen Wallpaper Window` −2147483625 → **Dock 进程 `Wallpaper-<UUID>` −2147483624** →〔可用区间〕→ Window Server `underbelly` −2147483602【核查补充】→ Finder 桌面图标 −2147483603 → 通知中心小组件 −2147483601。
`NSWindow.Level.screenSaver` 真实值是 **1000**，不是流传甚广的 101（Jim Fisher 那张表错了）。`NSWindow.Level.dock` 自 10.13 起已废弃【核查补充】。

**零 entitlement 已验证**：Wallnetic（MIT，51★，MAS id6760347328）的 entitlements 只有 app-sandbox / application-groups / network.client / files 读写 / photos-library / scripting-targets，沙盒开启且成功上架。
`https://github.com/fatihkan/wallnetic/blob/main/src/Wallnetic/Engine/DesktopWindowController.swift`

**功耗实测**：2560×1440@60fps HEVC 硬解经 AVPlayerLayer 渲染，M4 Max 上 CPU 1.0–3.6%、RSS 47MB。省电杠杆是 `NSWindow.didChangeOcclusionStateNotification` + 锁屏/屏保通知（**必须注册在 `DistributedNotificationCenter` 且用 `.deliverImmediately`**，注册在 `NotificationCenter.default` 上永远收不到）。

### 死路（别投入）

- **Wallpaper Extension**：`com.apple.wallpaper` 扩展点真实存在（系统自用 11 个 appex），但 `.appexpt` 明确要求私有 entitlement `com.apple.private.wallpaper.extension`，第三方拿不到。本机 `plutil` 逐字验证。
- **`.saver` 屏保**：macOS 26.6 SDK 中未弃用（头文件 grep 零 `API_DEPRECATED` 命中），但只在空闲时播放，≠ 桌面常驻。
- **`NSWorkspace.setDesktopImageURL`**：只吃静态图。
- **锁屏界面无论如何盖不住**（独立 secure session），Wallnetic 试过并删掉了该功能。

### 【已纠正】关于"点击穿透失效"

原调研断言"macOS 26.6.1 上透明像素自动穿透已失效，是 26.3 引入的回归"。核查结论：

- 引用的两个 Apple 论坛帖（thread/814798、thread/814875）**都不支持该结论**——一个讲 `styleMask` 行为变化，一个讲 borderless 窗口整体收不到交互，**通篇未涉及透明像素穿透**。该结论只有本机单次实测这一个来源，**confidence 应从 high 降为 medium**。
- 实测**存在混淆变量**：若 contentView 设了 `wantsLayer` 或用 SwiftUI 放了 `Color.clear`/material，backing store 未必真是 alpha=0，收到 mouseDown 是正常行为而非系统 bug。需用纯 AppKit `NSView`（不 `wantsLayer`、空 `drawRect`）重测。
- `hitTest` 返回 nil 无法实现部分穿透 **不是 macOS 26 的回归，所有版本一贯如此**——nil 只表示窗口内无 view 接收，从不转发给下层窗口。
- `LyricShiori` 被称为"生产项目"是夸大（**0 star、无 license**）；且 16ms 轮询 `NSEvent.mouseLocation` 在 macOS 26 之前就是常见写法，**不能反过来当作回归的证据**。

**工程结论不变**：桌宠交互层用 16ms 轮询动态切 `ignoresMouseEvents` 是安全做法，但不要把"透明穿透坏了"当作既定事实写进设计文档。

### 【核查补充】跨栈能力对照

| 外壳 | 桌面层支持 |
|---|---|
| **Swift/AppKit** | 完整，推荐 |
| **Electron** | 原生支持 `new BrowserWindow({type:'desktop'})`，源码 `native_window_mac.mm:273-278` 实现为 `[window_ setLevel:kCGDesktopWindowLevel - 1]`（= −2147483624，**恰好等于 Dock 壁纸窗层级，只能靠同层 z 序压过去，比 −2147483604 少 20 层余量**）。官方文档明确该类型窗口**不接收焦点/键盘/鼠标事件**（只能用 globalShortcut）。文档位置是 `docs/api/structures/base-window-options.md`，不在 browser-window.md |
| **Tauri** | **没有任何窗口 level API**。tao 的 `WindowExtMacOS` 只暴露 `ns_window`/`ns_view`/`simple_fullscreen`。必须取裸 `NSWindow` 指针自己写 objc2 胶水 |

**别参考 `liwenka1/bongo-cat-next`**：读了 `src-tauri/src/core/setup/macos.rs`，macOS 分支全部内容只是调 `CGPreflightListenEventAccess` 检查权限，**没有任何 level / collectionBehavior / 穿透代码**，对本议题参考价值为零。

---

## 五、形象渲染

### 路线 A（主线）：预渲染 AI 视频循环 + HEVC-alpha

macOS 是对透明视频支持最好的平台。**WWDC19 Session 506 核实为真**：AVPlayer/AVPlayerLayer 直接以透明背景与 Core Animation/AppKit 合成；`AVPlayerItemVideoOutput` 取帧给 Metal；`AVAssetImageGenerator` 取带 alpha 的 CGImage；检测用 `AVMediaCharacteristic.containsAlphaChannel`。编码侧 `AVAssetWriter` / `AVAssetExportSession` 的 "with Alpha" 预设 / `VTCompressionSession`。
`https://developer.apple.com/videos/play/wwdc2019/506/`

**【已纠正】ffmpeg 参数原调研是错的，会毁掉抠像边缘**：

- `-alpha_quality 0.1` → **应改为 0.9 或 1.0**。Apple 明确 `targetQualityForAlpha` 取值 0-1，**1 接近无损**，alpha 通道走固定质量编码、与基础层码率无关。0.1 等于把 alpha 压到接近最低质量，对全屏常驻人像直接表现为发丝锯齿、半透明区块状、边缘暗环。
- `-q:v 35` 偏低，写实人像建议 **60-75** 起步（videotoolbox 常量质量刻度 1-100）。
- `-require_sw 1` 在 Apple Silicon 上很可能多余甚至有害——它是 Intel Mac 时代硬件编码器不支持 alpha 的遗留建议。ffmpeg 源码 `vtenc_qscale_enabled()` 显示 `-q:v` 只在 macOS+arm64 生效。**建议先不加，编码后用 `AVAsset` 检查 `containsAlphaChannel`，失败再回退。**
- 产物容器是 **`.mov`（QuickTime）不是 mp4**，源建议 ProRes 4444。原调研引用的 kitcross.net 当前证书过期不可访问。

其余真实约束：HEVC-alpha 是 Apple 规范外扩展，x265/nvenc/Adobe Media Encoder 均无法产出，素材离开 Apple 生态 alpha 直接丢失；`AVPlayerLooper` 与 `AVVideoComposition` 冲突（挂了 composition 就失效，"无缝循环"和"逐帧滤镜"二选一）；AI 生成片段首尾姿态不闭合，需锁死起始 pose + 手工挑帧 + 3-5 帧交叉溶解，这部分占素材流水线一半以上工时。

生成端：Kling 3.0 约 $0.10/秒（30 段 × 6 秒 ≈ $18/套装），或开源 `WeChatCV/Wan-Alpha` v2.0（MIT，CVPR 2026 Highlight，直出 RGBA，但推理示例 `--nproc_per_node=8`，Mac 跑不动）。抠像用 `pq-yang/MatAnyone2`（CVPR 2026 Highlight）。换装 = 用 `Qwen-Image-Edit-2511` 改首帧后重新 I2V 生成整套素材。

**素材量会爆炸**：8 状态 × 4 套服装 × 6 秒 × 1440p60 HEVC-alpha ≈ 0.5–1.3GB，必须按需下载。

### 【已纠正】路线 B（口型贴片）：可行性完全未知，不是 30-40% 风险

原调研称"LiteAvatar 纯 CPU 30fps 意味着 M 系列上留有大量性能余量"。核查结论：

- `HumanAIGC/lite-avatar` README 原文只有一句 "which can run in 30fps on only CPU devices"，**未指明任何 CPU 型号、核心数、分辨率或测量方法**；仓库同时推荐 CUDA 11.8，全文无 Apple Silicon / macOS / MPS / CoreML 任何字样；也**没有为新形象制作数据的流程文档**（只给 sample_data.zip 下载）。
- `TMElyralab/MuseTalk` 的 30fps+ 是 **Tesla V100** 数字，且对应 preparation 完成后的 generation 阶段，**不含人脸检测/VAE 编码等前处理**；已于 2025-09 停更。
- `ivanfioravanti/fasterliveportrait-mlx` **连一个 FPS 数字都没公布**——README 只说 benchmark 脚本会打印 ms 与 FPS，无任何实测结果、无任何 M 系列机型标注。"支持 `--realtime`"是循环论证：能启动实时模式 ≠ 能达到 25fps+。

**修正后的行动项**：不要写"移植失败概率 30-40%"，改为——**先做 1-2 人天 spike**（在目标 Mac 上跑 lite-avatar 纯 CPU 推理与 fasterliveportrait-mlx 的 benchmark，实测 256px 下的 ms/frame），拿到数字再决定是否投入那 20-30 人天。

### 【已纠正】Live2D 授权：个人免费不成立

macOS 桌面应用归 **One-time Purchase Content Plan (Console or PC)**，对 <1000 万日元的个人/小规模企业初装费与单价确实为 Free —— **但这个豁免有唯一例外，就是 Expandable Application**。

官方定义（`https://www.live2d.com/en/sdk/license/expandable/`）：任何"在 SDK 产品的服务或内容中具有显著可扩展性"的作品，明确点名两类——(1) 通过增删组合文件/数据可产生不特定数量模型的衍生作品（avatar 类）；(2) 一个平台下可访问多个作品的集合。**akari 规划的"可换装""可换形象""用户可导入自己的模型"任一成立即命中。**

后果：无论公司规模都必须**先审核并签署 Publication License Agreement 才能发布**；个人/小规模企业虽然初装费与年费为 0，仍要付**每笔销售 ¥300 或销售额 20%（取高者）**；另需按季度上报销售额、强制展示 Expandable Application logo、强制列入 Showcase；官方写明**"原则上完全免费的应用不符合资格"**。

另两处纠正：VTuber 条款的 2000 万日元门槛针对的是"用 tracking software 生产出的内容"的销售额，而 **tracking software 本身归 Expandable Application，需发布前批准、与当前营收无关**；公示的费率是**有条件折扣价**（隐含 logo + Showcase 义务），不接受则需另行询价。原调研引用的 ¥50,000/¥20,000 属于 Running Royalty 计划，**对 macOS 桌面应用根本不适用**。

### 其余路线判定

- **3D VRM/VRoid**：天生二次元，风格还原度 25-35%，性价比最差。走 MetaHuman 则授权状态模糊（Creator 网页版 **2026-11-05 关停**）+ 引入完整引擎运行时。
- **云端实时数字人**：腾讯 3D 写实实时并发 **6,750 元/月/路**、形象租赁 37,500 元/月；阿里 `wan2.2-s2v` **异步 5-10 分钟出片、同时处理任务数=1**，根本不是实时，只能当离线素材工具。个人项目均不可行。
- **本地全量实时扩散**：LiveAvatar 单卡需 ≥80GB 显存（FP8 后 48GB），Ditto 只有 TensorRT/A100 实现且代码库无任何 CoreML/MPS 痕迹。**Mac 上 dead-end。**
- **内容审核会拦"虚拟女友"类素材**：国内所有视频生成 API 都有合规检测，写实女性形象 + 暗示性提示词被拒概率高。建议形象设定偏"助理/伙伴"。

---

## 六、电脑控制

### 四条通路（本机 macOS 26.6.1 实测）

**A. 结构化工具层（AX + Shortcuts + shell 白名单）—— 推荐主路径**

Accessibility API 完全健在：`AXUIElementCreateApplication(pid)` 对 Finder/Chrome/VS Code/IntelliJ/微信/文本编辑全部返回 `kAXErrorSuccess`。AX 树深度实测（depth≤8）：**Chrome 8560 节点**（无需任何开关即完整暴露网页 AX 树）、IntelliJ 1570、文本编辑 406、VS Code 507、微信 199。文本编辑的 `AXTextArea` 读到 `AXValue` 长度 1943 且 `AXSelectedText` 可用。

**必须调 `AXUIElementSetMessagingTimeout(app, 1.0~2.0)`**，否则卡死的 App 会阻塞整个 agent、直接让壁纸动画掉帧。所有 AX 遍历放后台队列。

**B. 截图 + VLM 坐标点击 —— 只当兜底逃生舱**

`CGWindowListCreateImage` 已在 **macOS 15.0 obsoleted（硬编译错误，不是 warning）**，必须走 `SCScreenshotManager.captureImage(contentFilter:configuration:)`。实测单次拿到 2560×1440 CGImage。Qwen3-VL grounding 坐标是**归一化 0-1000 整数**，`px = coord/1000 × 边长`。

准确率现实：OSWorld-Verified 榜首 Qwen3.8 Max 86.1%（人类基线 72.4%），但**ScreenSpot-Pro 高分辨率 grounding SOTA 才 81.5%**——2560×1440 上点错像素很常见。**86% = 每 7 步错 1 步**，绝不能把"删除文件/发送消息/付款"交给纯坐标点击。

**C. 复用 MCP 生态**：`openclaw/Peekaboo`（Swift，MIT，4.7k★，`brew install steipete/tap/peekaboo`，同时封装 AX 树 + 截图 + 点击 + MCP server，源码本身就是最佳参考实现）、`wonderwhy-er/DesktopCommanderMCP`（6.1k★）、`steipete/macos-automator-mcp`（816★，200+ AppleScript 配方）、`mattt/iMCP`（1.45k★，日历/通讯录/信息）。**`supermemoryai/apple-mcp` 已于 2025-08 归档只读，别再用**。

**D. 只用 Shortcuts / App Intents**：`/usr/bin/shortcuts` 子命令只有 `run/list/view/sign`。几乎零权限成本、能上 MAS、天然白名单，但能力天花板极低。

### 直接可抄：AIRI 的 computer-use-mcp

`moeru-ai/airi`（48,060★，MIT）里的 `services/computer-use-mcp` 是全网唯一已落地的"macOS 原生电脑控制 + MCP + 人工审批"实现。executor 分 dry-run / macos-local / linux-x11；macos-local 用 `NSWorkspace` + `CGWindowList` 观察窗口、Swift + Quartz `CGEvent` 注入输入。工具名可直接照搬：`desktop_observe_windows` / `desktop_screenshot` / `desktop_click` / `desktop_type_text` / `desktop_press_keys` / `terminal_exec` / `browser_dom_*` / `desktop_list_pending_actions` / `desktop_approve_pending_action` / `desktop_get_session_trace`。

**正确姿势是"按包窃取"，不要 fork 整仓**（monorepo 极大 + 日更节奏，rebase 成本极高）。剥离约 1-2 人周。

### 权限与分发（硬约束）

- **沙盒 App 不能用 `AXUIElementCreateApplication`**（Apple DTS 明确答"No"）→ 放弃 MAS，锁定 Developer ID + 公证 + stapler（自 10.15 起强制，$99/年）。
- **责任进程陷阱**：终端里 `swiftc` 编译的裸二进制 `AXIsProcessTrusted()` 直接返回 true 且能读所有 App 的 AX 树——因为 TCC 把权限归属到 responsible process（终端）。**开发期你会以为不用申请权限，打包成独立 .app 后全部失效。必须尽早用真实 .app + Developer ID 签名测权限流程。**
- **权限绑定代码签名 + bundle id**：换证书、改 bundle id、CI 重签名都会让用户已授予的权限静默失效。
- **屏幕录制每月重新弹窗**（Sequoia 15 起，Tahoe 沿用，面板改名 "Screen & System Audio Recording"）。对常驻桌面的角色体验极差，**截图能力要做成按需开启，不要开机常驻 SCStream**。
- **Automation 权限是 N×M 的**：控制 10 个 App 就弹 10 次，且无 API 主动触发，只能第一次真实发 Apple Event 时弹。
- **用户全量放开需点 12-15 次**，其中辅助功能和完全磁盘访问要手动进系统设置 + 输密码。**必须分阶段渐进授权：首启只要麦克风+通知。**
- **AXSelectedText 在 Electron 上必挂**：VS Code depth≤10 内 0 个可读文本节点；`AXManualAccessibility=true` 返回成功(0) 但树纹丝不动（519→519 实测）；`AXEnhancedUserInterface` 返回 `kAXErrorNotImplemented(-25208)`。必须三级 fallback：AX → 保存剪贴板 → 模拟 Cmd+C → 读 pbpaste → **恢复剪贴板**（这步最常被忘，会吃掉用户原本复制的内容；用 `NSPasteboard.changeCount` 判断是否真变了）。
- **macOS 26 AppleScript 有回归**：Music 的 `current track` 事件被移除，Automator 的 AppleScript actions 已 deprecated。别当长期基座。
- **截图是 prompt injection 的正门**：屏幕上任何文字都能变成指令。防御必须架构级——截图内容一律标 untrusted，读过 untrusted 之后的任何状态变更类工具调用强制走人工确认门；shell 能力与外部内容处理绝不放同一上下文。

---

## 七、语音流水线

### 延迟预算（这是体验的决定项）

云端级联现实可达 p50 **650–900ms**：端点判定 200–500ms（**最大头**）+ 流式 ASR 收尾 100–200ms + LLM TTFT 200–400ms + TTS 首包 100–300ms + 播放抖动 50–100ms。端到端 Realtime 可压到 400–800ms。

**行业共识：把静默阈值从 800ms 降到 200ms 省下的 600ms，比换任何模型都值钱。** 这要靠语义端点模型（**smart-turn v3**，CPU 12ms 推理、约 8M 参数、BSD-2），不是靠调 VAD 阈值。

### VAD 选型

**Silero VAD 6.2.1**（MIT，2MB，30ms 块 <1ms CPU）通用但在"语音→静音"转换上慢几百毫秒，**直接拿它做端点等于白送延迟**。**TEN VAD**（Apache-2.0，macOS arm64 预编译 731KB，M1 上 RTF 0.016，10/16ms hop）转换更快更省。推荐组合：**TEN VAD 帧级门控 + smart-turn v3 语义端点**。

### AEC 是最大的坑

macOS 只有一条真正可用的路：`kAudioUnitSubType_VoiceProcessingIO` / `AVAudioInputNode.setVoiceProcessingEnabled(true)`。三个硬伤：

1. **输入输出设备不一致会直接失败**（AirPods 麦 + 内置扬声器 → err -10875，AggregateDevice 声道数不匹配，Apple 论坛无人回复）——AirPods 切换是高频场景；
2. 会把全机音频切进"通话模式"，别的 App 音乐被 duck；
3. **TTS 音频必须从同一个 engine 的 output 节点播出**，否则 AEC 拿不到参考信号、完全失效。

最省事的绕法：把音频前端做成 Chromium（Electron）里的 WebView，用 `getUserMedia({echoCancellation:true})` 白嫖 **AEC3**。pipecat 官方 macOS 本地样例正是这么做的。**注意 Tauri 在 macOS 上是 WKWebView，没有 AEC3。** Electron 的 echoCancellation 有已确认 bug（#47043，closed as not planned），macOS 上必须亲自实测。

### 唤醒词：建议直接跳过

openWakeWord 误唤醒 **8.5 次/小时**（LiveKit 实测）——一个 24h 挂桌面的角色会随机自言自语。v1 用"按住热键说话 / 点角色开始听"，成本为零、体验可控、**还省掉 200-500ms 端点等待**，且不说话时可直接静音 TTS、绕开绝大部分 AEC 复杂度。真要唤醒词用 `livekit-wakeword`（0.08 FPPH、86% recall）或 Porcupine。中文唤醒词无现成方案，都要自训。

### 框架

**Pipecat 1.7.0**（2026-08-01，Python ≥3.11，BSD-2）是唯一同时具备 `qwen` extra（`QwenLLMService`）、`mlx-whisper`/`kokoro`/`silero` 本地 extra、以及现成 macOS 全本地样例的框架，首选。LiveKit Agents 适合多端/远程；TEN Framework 强在 WebRTC + 可视化编排；**Vocode 已停滞，别用**。

拼装方案的**打断逻辑是最容易做砸的一块**：收到用户开口信号后必须同时做三件事——停 TTS 播放、cancel TTS WebSocket 请求、abort 流式 LLM 请求。漏一环就是"她还在自说自话"的破功感。

---

## 八、App 外壳

| 方案 | 桌面层 | AEC | AX 控制 | 分发 | 判定 |
|---|---|---|---|---|---|
| **Swift 原生（AppKit + Metal/AVFoundation）** | ✅ 完整 | ⚠️ VoiceProcessingIO 设备切换要自己兜 | ✅ 最直接 | 单 .app，签名公证一条龙 | **推荐**，单进程、启动快、内存小、功耗低（ANE） |
| **Electron** | ⚠️ `type:'desktop'` 层级余量小、不接收鼠标 | ✅ 白嫖 AEC3 | 需子进程 | 多进程打包 + TCC 权限继承麻烦 | 音频前端可用，主壳不推荐 |
| **Tauri** | ❌ 无 API，需 objc2 胶水 | ❌ WKWebView 无 AEC3 | 需子进程 | 体积小 | 不推荐 |

**若混合**：Swift 主壳 + 一个 Chromium WebView 只承担音频 I/O，可同时拿到原生桌面层和 AEC3。代价是多一个进程和一次签名。

其他外壳级坑：`isReleasedWhenClosed` 必须设 false（默认 true，配合 CoreAnimation 动画会 over-release 崩溃）；多显示器**必须用 `CGDirectDisplayID` 而非 `NSScreen` 对象当字典 key**（睡眠/唤醒/热插拔后 NSScreen 会被重建，这个 bug 只在用户合盖再打开后才暴露）；macOS 26 上给 titled 窗口设 `backgroundColor=.clear + isOpaque=false` 会让红绿灯按钮消失（borderless 不受影响，但主设置窗口要小心）；本地进程间通信**用 Unix domain socket 或 XPC 而非本地 HTTP**（Tahoe 26.3.x 上 Electron/重签名 App 会从 Local Network 列表消失导致连不上本地端口）。

---

## 九、可抄的现成项目

| 项目 | 星/许可 | 抄什么 | 备注 |
|---|---|---|---|
| **`moeru-ai/airi`** | 48,060★ MIT | **`services/computer-use-mcp` 整段** + 多窗口分层设计（main/desktop-overlay/spotlight/caption/widgets） | 全网唯一落地的 macOS 电脑控制 MCP；**按包窃取，别 fork 整仓** |
| **`fatihkan/wallnetic`** | 51★ MIT | `DesktopWindowController.swift` 窗口配置 + `PowerManager.swift` 省电策略 + entitlements 清单 | 已上架 MAS，最值得抄 |
| **`openclaw/Peekaboo`** | 4,677★ MIT | AX + ScreenCaptureKit + 点击的 Swift 参考实现，可直接当 MCP server | `brew install steipete/tap/peekaboo` |
| **`Open-LLM-VTuber`** | 13,329★ MIT | **只抄 asr/tts/agent 三个目录的后端抽象设计** | **已半停更**：最后实质提交 2026-02-11，最后 release 2025-08-26，长期记忆被"临时移除"至今未回，v2 是完全重写的早期规划。基于它开发会踩空 |
| **`kiyotakali/Miru`** | 68★ Apache-2.0 | AttentionEngine（何时主动开口）+ 记忆 schema（projects/people/yourself/topics + 日志 + commitment，**全纯 Markdown 落盘，不上向量库**） | 唯一"原生 macOS + 长期记忆 + 主动性"齐全的参考，但成熟度未知 |
| **`kwindla/macos-local-voice-agents`** | 334★ **无 LICENSE** | 组件选型清单 + 延迟基准（Silero VAD + MLX Whisper + LM Studio + Kokoro，声称 <800ms） | 已停更近一年，Pipecat API 变动大，**无 LICENSE 严格说不能复制代码** |
| **`thusvill/LiveWallpaperMacOS`** | 919★ ObjC++ | 壁纸引擎架构（含 wallpaperdaemon） | 活跃 |

**许可传染名单（只能读设计，不能抄进闭源产品）**：MirageWallpaper / MacArkPet / Shijima-Qt / Soul-of-Waifu = GPL-3.0；LingChat / super-agent-party / Alife = AGPL-3.0；LivePortrait / MuseTalk = NOASSERTION（自定义许可，商用前逐条读）。
**安全可用**：AIRI、Peekaboo、three-vrm、sherpa-onnx、silero-vad、whisper.cpp（MIT/Apache-2.0）。

**GitHub API 的 license 字段会骗人**：Open-LLM-VTuber 返回 NOASSERTION 但 LICENSE 文件实际是标准 MIT（因仓库内含另有授权的 Live2D 示例模型）。反之亦然，看到 SPDX ID 也要打开 LICENSE 确认。

**竞品警告**：**Desktop Mate 已上架 macOS Tahoe + Apple Silicon**（Steam app 3301060，本体免费 + ¥2,200/角色 DLC，39+ 款官方授权 IP）。走 3D VRM 桌宠路线是正面撞上一个有版权弹药库的对手。
**Wallpaper Engine 永远不会有 Mac 版**，别把"移植 WE 壁纸包"写进方案。
**Plash 已闭源**（仓库只剩 readme + 一张图，`DesktopWindow.swift` 已删），很多博客还在教"去看 Plash 的源码"。

---

## 十、待验证（低置信度，落地前必须自测）

**必须实测才能决策的（阻塞项）**

1. **透明窗口点击穿透在 macOS 26.6.1 是否真的失效** —— 唯一来源是单次本机实测，且存在 `wantsLayer`/SwiftUI 背景的混淆变量。用纯 AppKit `NSView`（不 `wantsLayer`、空 `drawRect`）重测一次。
2. **Realtime 官方延迟基准 flash ≈5.1s / plus ≈5.8s 是首包还是整轮** —— 文档未说明。这个数字若是首包，端到端方案直接出局。**上线前必须自己实测首包延迟，别信这个数字做决策。**
3. **本地口型模型在目标 Mac 上的实际帧率** —— lite-avatar / MuseTalk / fasterliveportrait-mlx **三个候选没有一个存在公开的 Apple Silicon 实测**。1-2 人天 spike 拿到 ms/frame 再决定是否投 20-30 人天。
4. **声音复刻是否免费、样本时长要求、音色数量上限** —— 官方页显示"暂无公开定价信息"，路径 404。这是"固定人设音色"的核心卖点，动工前必须到控制台或走工单确认。
5. **MLX LLM 推理与 60fps Metal 渲染并发时的实际互相拖慢程度** —— 无任何公开测量数据，纯属统一内存架构推断（`powermetrics` 需 sudo，本机未能实测）。

**未证实但不阻塞的**

6. AOQ 协议底层是否为 QUIC、SDK 是否覆盖 macOS（文档只确认协议存在）。
7. Qwen 视觉模型的视频时长/文件体积上限（"2 小时 / 2GB"在官方 vision 文档中未出现）。
8. `qwen3.8-max` 的 "95B 激活参数""首个开源 Max 级模型"仅见于第三方博客 developersdigest.tech，官方只确认"2.4 万亿参数 MoE"。
9. `qwen-audio-3.0-realtime` 系列的音频 token 换算率（Qwen3.5-Omni 是 ×7 秒，该系列未查到），成本估算不确定。
10. Qwen-UI-Agent（arXiv 2607.28227）**未确认开放权重、无 HuggingFace repo 名、无 DashScope model id、未提及 macOS**。
11. macOS 26 桌面层窗口在 Space 切换 / Mission Control / 全屏 App 下的行为 —— 只有代码与文档证据，无实机交互验证。**上手第一天就该手动验一遍**（含 `fullScreenNone` vs `fullScreenAuxiliary` 的差异、进全屏 App 后桌面层是否仍在渲染浪费电）。
12. `occlusionState` 在桌面层的触发可靠性、2560×1440@60fps 的 1.0-3.6% CPU / 47MB RSS 数字 —— 均为单次本机实测，未复现。
13. Electron 的 `echoCancellation` 在 macOS 上是否受 #47043 影响（该 bug 在 Windows ARM64 复现，closed as not planned）。
14. 【表述纠正】"macOS 26 点击壁纸显示桌面" —— 该功能实为 **macOS 14 Sonoma 引入**，不是 26 新增；其与第三方桌面层窗口的交互仍未验证。

**方法论提醒**

- 网上 2026 年的 Apple Silicon tok/s 对比站大量疑似 AI 批量生成，数字互相打架（llmcheck.net、markaicode、willitrunai），**一律不可作为决策依据**。
- 本简报输入的 8 份调研中，语音流水线那份**在传输中被截断**（`hard_facts` 第一条中断），其中的 ChipChat 具体分项数字（ASR 175ms / LLM 560ms / 总计 920ms）来自摘要段而非可核对的 fact 条目，标为 medium。
- 三份证伪核查均因 WebSearch 配额耗尽（200/200）改用 WebFetch 一手抓取与本机实测，**证据强度实际高于搜索摘要**，但覆盖面窄于原计划——未核实的部分（Kling/Wan-Alpha 定价、腾讯云与百炼价格表、MetaHuman 授权现状）仍应视为未验证。

---

## 十一、3 条路线骨架

### 路线一：保守 —— "会说话的动态壁纸"

**技术栈**
Swift 原生 .app（单进程）｜桌面层 `NSWindow(level: -2147483604)` + `AVPlayerLayer` 播预渲染 HEVC-alpha 循环（`AVQueuePlayer` + `AVPlayerLooper`）｜PTT 全局热键触发录音（绕开 VAD/唤醒词/大部分 AEC）｜`qwen-audio-3.0-asr-flash-streaming` → `qwen3.7-flash` → `qwen-audio-3.0-tts-flash`｜口型走 `AVAudioEngine` installTap 的 RMS 包络驱动张嘴（attack 30ms / release 120ms）｜"控制电脑"只做 `shortcuts run` + App Intents｜截屏理解直接塞进 `qwen3.7-flash` 的 `image_url`

**能做到**：桌面常驻写实形象（90-95% 还原参考效果）；按键说话、多轮对话、看屏幕答问；跑用户已编好的快捷指令；被遮挡自动停解码、锁屏/电池自动暂停；**可上 Mac App Store**

**做不到**：真口型同步（只有粗糙的音量驱动）；开放麦随时搭话、打断；任意 App 的 GUI 操作与文本读取；换装（素材未做）；离线

**工作量**：**25-35 人天**（桌面层窗口+播放器+状态机 5｜素材流水线 8｜过渡打磨 3｜语音三段串联 6｜降级口型 2｜Shortcuts 层 3｜打包签名公证 4）
**月成本**：¥40-70（每天 1 小时）+ 一次性素材生成 $20-50/套装

---

### 路线二：推荐 —— "会随时搭话、能动手的桌面助理"

**技术栈**
路线一全部 ＋ **Chromium WebView 只承担音频 I/O**（白嫖 AEC3）或 Swift `VoiceProcessingIO` + 设备切换状态机 ｜ **TEN VAD 帧级门控 + smart-turn v3 语义端点**（把静默阈值从 800ms 压到 200ms）｜ 打断状态机（同时停播放 / cancel TTS WS / abort LLM stream）｜ **AX 结构化工具层约 20 个工具**（照抄 AIRI `computer-use-mcp` 的工具面 + Peekaboo 的 Swift 实现），带 approval queue + audit log ｜ 换装素材管线（`Qwen-Image-Edit-2511` 改首帧 → 重新 I2V）｜ 记忆用纯 Markdown 四类文件（抄 Miru）｜ **Developer ID + 公证分发**

**能做到**：开放麦随时搭话、可打断、p50 650-900ms 端到端；读写常见原生 App 的 UI（Finder / Chrome 网页 AX 树 8560 节点 / 文本编辑 / IntelliJ）；填表单、点按钮、读选中文本（三级 fallback）；跑 shell 白名单命令；换装（换素材包）；分阶段渐进授权、每步可 dry-run 可回滚

**做不到**：音素级精确口型（仍是能量包络）；Electron/Java Swing App 的文本读取（必须退化到模拟 Cmd+C）；**上不了 Mac App Store**（沙盒禁用 `AXUIElementCreateApplication`）；离线

**工作量**：**70-95 人天**（路线一 30 ＋ VAD/端点/AEC/打断 15 ＋ AX 工具层与审批 20 ＋ 换装管线 8 ＋ 权限引导与分发加固 10 ＋ 缓冲 12）
**月成本**：¥40-70 ＋ Apple Developer $99/年

---

### 路线三：激进 —— "有真口型、能离线、能操作任何 App"

**技术栈**
路线二全部 ＋ **本地口型贴片**（LiteAvatar 或 MuseTalk 导 ONNX/CoreML，256px 嘴部区域重绘后 Metal 羽化贴回视频层）｜ **混合路由**：Apple Foundation Models 或 Qwen3.5-0.8B 做零成本意图分诊 → 闲聊/控制走本地 `mlx-community/Qwen3.5-9B-4bit` → 复杂推理走云端（都是 OpenAI 兼容，路由只换 baseURL）｜ **VLM 截图点击兜底**（`SCScreenshotManager` + Qwen3-VL grounding，0-1000 归一化坐标 → `CGEventPost`），强制人工确认门 ｜ 本地 ASR/TTS（Apple `SpeechAnalyzer` + Qwen3-TTS-12Hz-CustomVoice via mlx-audio）

**能做到**：真口型同步 + 保留写实画质（85-92% 还原）；断网可用、对话内容不出机（虚拟伴侣场景的隐私是硬需求）；理论上能操作任何 App 包括 AX 完全不暴露的（游戏、Canvas、远程桌面）；零 API 费用

**做不到**：**保证 60fps**（MLX LLM 与 Metal 渲染抢同一块 GPU 与内存带宽，必须在推理窗口内主动降到 30fps）；**保证移植成功**（三个口型模型在 Apple Silicon 上无任何公开帧率数据）；16GB Mac 完全跑不动（需 ≥32GB，舒适区 48-64GB）；VLM 点击的可靠性（ScreenSpot-Pro SOTA 才 81.5%，不可逆操作绝不能交给它）；笔记本发热与风扇噪音会直接伤害"桌面伴侣"体验

**工作量**：**130-180 人天**，其中 **30-50 人天是有失败风险的研究性投入**（口型模型 CoreML 移植 + 贴片边界的色彩/光照连续性 —— 后者最容易出"嘴巴是另一个人的"）
**前置门槛**：先花 **1-2 人天 spike** 实测 lite-avatar 纯 CPU 推理与 fasterliveportrait-mlx 的 ms/frame，**拿不到 ≥25fps 就不要启动这条路线**
**月成本**：¥0-40（本地为主，云端只兜底）＋ 电费与散热的隐性代价

---

### 决策建议

**先做路线一，一个月内让形象站上桌面并能对话**——它验证的是最不确定的两件事：写实视频循环的实际观感，以及"音量驱动张嘴"能骗过多少人。这两件事验证不过，后面 100+ 人天全部白投。

**路线二是终态目标**，但其中的 AX 工具层可以在路线一上线后独立增量交付，不必等。

**路线三的口型部分先做 spike 再决定**；本地 LLM 部分建议永远只作为"离线降级"存在，不做主路径——`qwen3.7-flash` 每天 1 小时才 ¥40/月，为省这点钱去和 60fps 渲染抢 GPU 不划算。

**两件必须现在就启动、不能等的事**：(1) 若还想保留 Live2D 选项，立刻书面向 Live2D 确认 akari 是否被判定为 Expandable Application（官方要求发布前至少 1 个月完成审批，实际应预留 3 个月）；(2) 分发形态现在就定死为 Developer ID，别做"能上 MAS"的假设去设计架构。