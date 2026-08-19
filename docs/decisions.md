# akari 决策日志

记录已经拍板的方向性决策及其理由。后续设计文档以此为前提。
新决策追加到末尾，不要改写历史条目 —— 若推翻旧决策，新增一条并注明"取代 ADR-00X"。

---

## ADR-001 · 形象走「写实风 + 预渲染视频循环」

**日期**：2026-08-19  ·  **状态**：已确定

**决策**：角色形象不做实时 3D / Live2D 驱动，而是**离线预渲染一组带状态的循环视频片段**，运行时按对话状态切换播放。

**备选与落选理由**：

| 方案 | 落选理由 |
| --- | --- |
| Live2D 二次元风 | 实时驱动最强（口型、眼神跟随、表情），生态成熟，但风格与目标观感（写实 AI 偶像）根本不符 |
| 3D 数字人（VRM / 写实建模） | 写实与实时兼得，但工作量最大，且写实 3D 人脸极易掉进恐怖谷 |
| 实时 talking-head 模型 | 理论最优解，但能否在 M 系列 Mac 上跑到 25fps 是未知数；走云端则意味着持续推理成本与额外延迟 |

**接受的代价**：
- 口型无法逐音素精确同步，只能做到"说话时嘴在合理地动"
- 动作是有限的几种状态，不能响应任意指令做任意动作

**素材生产管线**（用户指定）：
- 定妆图 / 换装图 → Magnific MCP，`imagen-nano-banana-2-flash`（Nano Banana 2）
  或 `imagen-nano-banana-2`（Nano Banana Pro，角色一致性更强）
  — 两者均支持 `character` 参考图，保证换装换发型仍是同一个人
- 循环动画 → Magnific MCP，`bytedance-seedance-pro-2.5`（Seedance 2.5）

**Seedance 2.5 的能力对本方案的意义**（已通过 `video_models_list` 核实）：
- 支持 `keyframes.start` + `keyframes.end` → **首帧与尾帧用同一张图，即可得到无缝循环**
- 时长 4–30s，分辨率至 1080p
- `outputFormats: mp4, mov` → ~~`.mov` 是否携带 alpha 通道待验证~~
  **已证伪（2026-08-19 实测）**：`outputFormat: "mov"` 参数被服务端忽略，
  实际返回 `h264 / yuv420p / .mp4`，无 alpha。抠像环节必须保留，见 ADR-007
- `audioReferences` 支持 `lipsync` / `voiceover_sync`，最多 10 段音频、单段至 60s，
  且 `requiresVisualReference: false` → 口型质量可能显著优于原先预期

---

## ADR-002 · 电脑控制走「白名单自动化 + 分级确认门」

**日期**：2026-08-19  ·  **状态**：已确定

**决策**：agent 具备写操作能力，但每个工具按风险分四级，高风险操作必须经用户显式确认。
**不**实现 computer-use 式的「截图 + 视觉定位 + 模拟点击任意界面」。

**四级模型**：

| 级别 | 行为 | 示例工具 |
| --- | --- | --- |
| 🟢 GREEN | 直接执行，不打扰 | `read_selection` `speak` `search` `open_app` `calendar_read` `clipboard_read` |
| 🟡 YELLOW | 执行前提示，给 1.5s 撤销窗口 | `write_file`（工作区内） `send_imessage` `create_event` `run_shortcut` |
| 🔴 RED | 弹确认卡片，展示**将要执行的原始命令**，等用户点头 | `run_shell` `delete` 工作区外写入 发送邮件 付款类 |
| ⚫ NEVER | 不提供 | `sudo` 磁盘格式化 修改系统设置 |

**落选方案**：
- 「只读 + 朗读 + 启动」——零风险但算不上 agent，达不到"帮我处理问题"的目标
- 「再加屏幕视觉 + 键鼠接管」——GUI agent 到 2026 年准确率仍不足以无人值守；
  需常开录屏权限（屏幕内容上传给模型）；且引入提示注入攻击面（网页文字冒充指令）。
  **留作后期可选模块，默认关闭**

**衍生约束**：
- 需要的系统授权：辅助功能（Accessibility）、自动化（Automation）、麦克风
- 分发方式：Developer ID + 公证，**不能上 Mac App Store**（沙盒禁止这些能力）

---

## ADR-003 · 推理「云端为主 + Provider 抽象，本地可独立切换」

**日期**：2026-08-19  ·  **状态**：已确定

**决策**：LLM / ASR / TTS 三者各自定义 Provider 接口，默认实现走阿里云百炼（DashScope），
但每一路都能独立切到本地实现，切换不需要改动上层业务代码。

**理由**：先用云端把产品跑通（质量最好、延迟最低、不占内存），
把"是否为隐私/成本切到本地"留成一个配置项而不是一次重写。

**目标机器**：MacBook Pro · Apple M4 Max · 16 核 · **64 GB** 统一内存
—— 这个配置让本地方案是真选项，而不是画饼。

**本地 LLM 默认选型**（用户指定）：
[`orcarouter/Qwen3.8-27B-Uncensored-MLX`](https://huggingface.co/orcarouter/Qwen3.8-27B-Uncensored-MLX)

已核实（2026-08-19，经 HF API）：

| 项 | 值 |
| --- | --- |
| 最后更新 | 2026-08-17（两天前） |
| likes | 278 |
| 基座 | `Qwen/Qwen3.8-27B` |
| 能力标签 | `vision-language` `function-calling` `reasoning` `abliterated` |
| 语言 | en, zh |
| License | apache-2.0 |
| 量化档位 | 2-bit 9.3 GB · 4-bit 16.1 GB · **6-bit 22.8 GB** · 8-bit 29.5 GB |

**推荐档位：6-bit（22.8 GB）** —— 质量接近原版，64GB 机器上仍余约 40GB 给系统与其他应用。

**这个模型对架构的影响**：它是**多模态 + 支持 function calling** 的。
意味着本地 provider 不是"降级备胎"——本地同样能看屏幕截图、同样能调工具。
"涉及屏幕/文件内容的请求走本地"因此成为一条随时可启用的正常路径，而非妥协。

**⚠️ 实施前提**：该 repo 是 **gated（restricted）**，需先在 HuggingFace 上申请访问权限
并配置 token，否则无法下载权重。

**接受的代价**：默认配置下，对话内容与被读取的文件/屏幕内容会发送至阿里云。
需在首次启动时向用户明示，并提供一键切本地的开关。

---

## 待验证的关键风险

| ID | 风险 | 为什么关键 | 如何证伪 |
| --- | --- | --- | --- |
| ~~RISK-1~~ | ~~Seedance 2.5 输出的 `.mov` 是否携带 alpha~~ | **已关闭**：证伪，无 alpha。对策见 ADR-007 | 已实测 |
| RISK-2 | macOS 26 上桌面壁纸层窗口是否仍可用 | 决定形象能否"贴在桌面"而不是浮在所有窗口之上 | 写最小 Swift demo 验证 NSWindow.level + collectionBehavior |
| RISK-3 | 外放场景下的回声消除 | 不做 AEC，麦克风会听到 AI 自己的声音，打断功能直接失效 | 验证 macOS VoiceProcessingIO AudioUnit 实际效果 |
| RISK-4 | 本地模型端到端延迟 | 决定"切本地"是不是真的可用 | 拉下 6-bit 权重实测首 token 延迟与 tokens/s |

---

## ADR-004 · 语音走 Realtime 端到端，不做 ASR+LLM+TTS 拼装

**日期**：2026-08-19  ·  **状态**：已确定  ·  **依据：本机实测，推翻了技术调研的建议**

**背景**：技术调研（`docs/research/2026-08-19-tech-survey.md`）建议走拼装方案，理由是成本便宜 4-5 倍
（¥38-64/月 vs ¥150-210/月）。同一份调研又把一条数字列为**阻塞性待验证**：

> 「Realtime 官方延迟基准 flash ≈5.1s 是首包还是整轮 —— 文档未说明。
> 这个数字若是首包，端到端方案直接出局。**上线前必须自己实测首包延迟，别信这个数字做决策。**」

**实测**（2026-08-19，国际站 `wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime`，3 轮）：

| 轮次 | 握手 | 首个文本 | **首个音频** | 整轮 |
| --- | --- | --- | --- | --- |
| 1 | 464ms | 227ms | **473ms** | 781ms |
| 2 | 335ms | 229ms | **398ms** | 733ms |
| 3 | 338ms | 647ms | **915ms** | 1284ms |

**首个音频包中位数 473ms。** 官方标称的 5.1s 不是首包口径。

**决策**：v1 使用 `qwen3.5-omni-flash-realtime`，理由按重要性排序：

1. **延迟反而更优**：473ms vs 拼装方案现实可达的 p50 650-900ms。
2. **省掉三块最难的工程**：`session.created` 返回的配置里直接带
   `turn_detection: {type: "server_vad", interrupt_response: true}` ——
   端点检测和打断由服务端负责。调研原文点名拼装方案「打断逻辑是最容易做砸的一块，
   必须同时停 TTS 播放、cancel TTS 请求、abort 流式 LLM，漏一环就是『她还在自说自话』的破功感」。
3. ~~成本论点不成立~~ —— **此条已作废，见下方勘误。**

### ⚠️ 勘误（2026-08-19，用户纠正）

初稿曾把「100 万 token 免费额度」当作 Realtime 的优势写进理由 3。**这是错的**：
该免费额度属于 `qwen3.7-flash`，而 `qwen3.7-flash` 恰恰是**拼装方案**的 LLM 环节。
换言之这条免费额度是拼装方案的加分项，不是 Realtime 的。

**修正后的成本对比**（每天 1 小时语音对话）：

| | Realtime 端到端 | ASR + LLM + TTS 拼装 |
| --- | --- | --- |
| 首包延迟 | **473ms**（本机实测） | 650–900ms（调研 p50） |
| VAD / 端点 / 打断 | 服务端 `server_vad` 包办 | 自行实现，调研点名「最容易做砸的一块」 |
| 免费额度 | **无** | LLM 环节可吃 `qwen3.7-flash` 的 100 万 token（2026-10-23 过期） |
| 月成本 | ¥150–210 | ¥38–64 |
| 额外工程量 | — | +5–8 人天 |

**Realtime 确实更贵，约每月多 ¥120。** 它剩下的两条理由是延迟更优、
以及省掉 5–8 人天最易翻车的工程。

**2026-08-19 用户在知悉勘误后重新确认：维持 Realtime。**
即成本劣势已知悉并接受，换取延迟与工程量的优势。

**保留的退路**：Provider 抽象（ADR-003）同样覆盖语音。若后续遇到
Realtime 的硬限制（RPM 60、单会话 120 分钟、不支持上下文缓存）或成本超预算，
可切到拼装实现而不动上层。

**未消除的风险**：
- 音频 token 的换算率未查到官方说明，实际月成本无法准确估算，¥150–210 来自调研而非实测。
- Realtime 不支持上下文缓存，长对话成本增长快于拼装方案。

---

## ADR-005 · v1 用「按住热键说话」，不做唤醒词、暂不做 AEC

**日期**：2026-08-19  ·  **状态**：已确定

**决策**：v1 的语音输入方式是**按住热键说话**（push-to-talk）或点击角色开始收音，
不实现唤醒词，也不实现回声消除。

**理由** —— 这一个决定同时绕开了调研点名的两个最大的坑：

| 坑 | 调研原文 | push-to-talk 为何能绕开 |
| --- | --- | --- |
| **唤醒词误触发** | openWakeWord 误唤醒 **8.5 次/小时**（LiveKit 实测）；中文唤醒词无现成方案，需自训 | 根本不常驻监听 |
| **回声消除 (AEC)** | macOS 只有 `VoiceProcessingIO` 一条路，三个硬伤：AirPods 麦 + 内置扬声器直接失败（err -10875）、全机音频被切进通话模式、TTS 必须从同一 engine 播出 | 不说话时不收音，AI 的声音进不了麦克风 |

额外收益：省掉 200-500ms 的端点静默等待——调研称
「把静默阈值从 800ms 降到 200ms 省下的 600ms，比换任何模型都值钱」。

**接受的代价**：不能「喊一声就应答」。对一个常驻桌面的角色，这确实损失了一部分陪伴感。

**后续路径**：v2 若要做免手操作，优先级是 AEC > 唤醒词，
且必须先实测 `VoiceProcessingIO` 在 AirPods 切换场景下的真实表现（RISK-3）。

---

## ADR-006 · 角色一致性必须靠 Library 角色资产，不能靠每次传参考图

**日期**：2026-08-19  ·  **状态**：已确定  ·  **依据：连续三次失败后的实测结论**

**问题**：形象需要 8 个状态 × 若干套服装，每一张都必须是**同一个人**。

**三次尝试与结果**：

| 方法 | 做法 | 结果 |
| --- | --- | --- |
| ① 参考图 + Nano Banana 2 | `references: [{type:"image", …}]` | ❌ 不像。模型每次都在**重画**这张脸，参考图只是身份引导 |
| ② 换 Nano Banana Pro | 同上，但用 `character_consistency` 档位的模型 | ❌ 仍不像。**证明问题不在模型能力，在方法** |
| ③ `images_expand` 扩展原图 | 保留原像素向外补画 | ⚠️ 脸 100% 保真（不重画就不会偏），但**只能处理这一张**，生不出新姿态、新服装 |
| ④ **Library 角色资产** | `library_create(type:"character")` → 之后引用 `{type:"character", identifier:"<numeric id>"}` | ✅ **唯一同时满足保真与可扩展的机制** |

**关键认知**：`images_generate` 的文档写明 —— `character` 类型的 reference
**必须是预建的 library 资产，不能是普通 creation**。这两者不是同一个东西：
传 creation 是"参考这张图猜一个人"，传 library character 是"使用这个已注册的角色"。
Seedance 2.5 的 `references` 同样支持 `character` 类型，所以图像与视频共用同一个角色定义。

**akari 的角色资产**：Magnific Library，numeric id **2183420**，name `akari`。
参考图集 3 张（用户认可的定妆图为封面 + 2 张真人参考照），
描述中逐条固定五官特征（发色发型、脸型、眼型瞳色、鼻唇、肤色、气质）。

**运维约定**：
- 每当有新的、质量更好的图被认可，用 `library_edit` 回填进参考图集，形成正反馈
- 参考图集最多 6 张，应覆盖**不同角度**（正面 / 侧面 / 低头），单一角度会让一致性不稳
- 所有后续图像与视频生成一律引用该 id，**禁止再用一次性参考图**

**一个反直觉的教训**：一致性不达标时，第一反应是"换更强的模型"。
实测证明换模型（Flash → Pro）完全无效，因为瓶颈是**引用机制**而非模型能力。

---

## 素材生成的成本纪律（2026-08-19 确立）

| 用途 | 档位 | 单价 |
| --- | --- | --- |
| **验证性生成**（测 alpha、测循环、测一致性） | 720p | 2,640 积分 |
| **正式素材** | 1080p | 4,740 积分 |
| 定妆图 | 2K | 约 75–100 积分 |

验证与正式必须区分档位，验证环节用 1080p 属于浪费 44%。

---

## ADR-007 · 抠像用 macOS Vision 人像分割，不用 colorkey、也不引入第三方抠像模型

**日期**：2026-08-19  ·  **状态**：已确定  ·  **依据：本机实测**

**背景**：RISK-1 证伪（Seedance 不输出 alpha），抠像成为素材管线的必需环节。

**三个候选与实测结果**：

| 方案 | 结果 |
| --- | --- |
| `ffmpeg colorkey` | ❌ **失败，且失败方式有欺骗性**。背景颜色方差仅 8.6（看起来完全适合抠色），但抠出来后**额头、鼻梁、眼下出现空洞** —— 那些皮肤高光的颜色与白背景太接近，而 colorkey 只比颜色、不认语义 |
| MatAnyone2 / RVM / rembg | 能用，但要引入 Python 依赖与模型权重，且需自行处理时序稳定性 |
| **macOS Vision 人像分割** | ✅ 语义分割，不打洞；**系统框架、零依赖、跑 ANE**；实测 604×1080 / 145 帧 **8.6 秒** |

**决策**：用 `VNGeneratePersonSegmentationRequest`（`qualityLevel = .accurate`）生成遮罩，
经 `CIBlendWithMask` 合成透明帧，再用 `AVVideoCodecType.hevcWithAlpha` 编码。
工具已落地为 [`tools/matte`](../tools/matte)。

**两条必须记住的坑**：

1. **`kVTCompressionPropertyKey_TargetQualityForAlpha` 必须是 `1.0`。**
   技术调研初稿给的是 `0.1`，经一手核查 Apple 文档纠正：值域 0–1 且 **1 接近无损**。
   0.1 会让发丝边缘出现锯齿、半透明区块状、边缘暗环。
2. **`ffprobe` 在这里会骗人。** 它对 HEVC-alpha 报 `pix_fmt=yuv420p`，
   因为 alpha 走的是**辅助图层**（auxiliary picture layer），不在主层像素格式里。
   唯一权威的检查是 AVFoundation 的 `.containsAlphaChannel`
   —— 实测原始 Seedance 输出为 0，经本工具处理后为 1。

**已知待改进**：Vision 遮罩分辨率低于原帧，放大插值后边缘过渡区混入背景色，
在深色壁纸上表现为头发外围一圈暗边。修法：遮罩轻微腐蚀 + 边缘去溢色。

---

## ADR-008 · 形象定稿

**日期**：2026-08-19  ·  **状态**：已确定

经四轮迭代定稿。**关键在于用户的三条反馈推翻了我最初的方向**：
姿势太僵硬（证件照式正面站姿）、表情太拘谨、服装太正式且缺乏张力。

**定稿形象**：
- **姿态**：身体侧转约三十度，头转回镜头，肩线一高一低 —— 杂志封面式的三七身，不是正面站姿
- **表情**：明亮外向，露齿笑，眼神有神
- **服装**：一字肩修身米白罗纹针织，露出肩线与锁骨，细金手镯
- **背景**：纯白棚拍
- **比例**：3:4（不是 9:16 —— 那是手机比例，人物两侧与头顶会空掉一大片，同清晰度下多耗 25% 像素）

**衍生的技术风险**：定稿配色是**米白衣服 + 裸露肩颈 + 白背景**，三者都是浅色，
抠像难度显著高于之前测试用的深蓝毛衣。因此正式素材前须先用 720p 验证分割质量。

**提示词纪律**：实测发现模型会擅自把纯白背景换成户外场景（四张里出现一张）。
正式生产的提示词必须包含硬性负面约束：
"no scenery, no furniture, no plants, no windows and no change whatsoever"。

---

## P0 骨架的安全加固

**日期**：2026-08-19  ·  **状态**：已落地并合并

不是一条新的方向性决策，而是 P0 骨架跑通之后两路代码审查（正确性 + 安全性）
报出的 27 条问题里 P2 及以上的那 17 条的落地记录。之所以写进本文件，是因为其中
几条**改变了既有 ADR 在实现层面的含义** —— 尤其 ADR-002 的确认门，在加固之前
是不成立的。

### 一、确认门此前形同虚设（ADR-002 的实现前提）

ADR-002 说"每一件有风险的事都先问过你"。而在加固之前，socket 对连上来的进程
**不做任何身份检查**：机器上任何一个以用户身份运行的程序都能冒充 akari.app 接管
这条通道，自己收到 RED 确认卡片、自己回 `approve`，用户全程看不到。同样地，它
也能灌假麦克风音频，或者顶掉真 core、截走全部上行语音。

现在 core 在 `connect(2)` 那一刻向内核查询对端身份
（`LOCAL_PEERCRED` / `LOCAL_PEERPID` + `proc_pidpath`），只接受 uid 相符且可执行
文件在白名单内的进程，其余一律拒绝并记审计行。socket 与其目录被强制锁到
0600/0700（不再看开发机 umask 的脸色），锁不上就拒绝启动。

#### 补记（同日，第二轮）：这条校验当时只做了一个方向

第一轮只让 **core 验 app**，没让 **app 验 core**，而 socket 有两端。对抗验证一次
就打穿了：写一个没有任何权限的普通 bun 脚本监听一个 socket，用 `AKARI_SOCKET`
把 app 指过去，app 直接连上、握手、然后把剪贴板全文交了出去 —— 没有确认卡片，
没有用户介入。这正好把第一轮"把剪贴板读取挪到 app 侧"（见下面第三条）的理由
掏空了：app 能看见 `ConcealedType` 标记没有用，如果它肯把内容交给任何一个抢占了
socket 路径的进程。

补上的是 `SocketTrust`（`app/Sources/AkariApp/SocketTrust.swift`）：app 每次拨号
之前先 `lstat` socket 与其所在目录，要求**属主是自己、socket 0600、目录 0700、
两者都不是符号链接、socket 确实是 socket**，任何一条不符就不连、退避重试、按
原因去重打日志。这是 core 侧 `assertPrivate` 的镜像，两端现在校验同一条不变量。
同时 `AKARI_SOCKET` 收进 DEBUG（与 `AKARI_CORE_ROOT` / `AKARI_BUN` 同一条规矩）：
GUI 进程的环境变量是谁启动它谁说了算，发布版从环境里取 socket 路径，等于把
"启动 akari"变成"连到我指定的这条通道上"。**只加一个"我知道我在做什么"的开关
没有意义** —— 能设 `AKARI_SOCKET` 的人顺手就把开关也设了。

**两个方向的档位并不对称，必须分开说。**

| 方向 | 现在校验什么 | 挡得住 | 挡不住 |
| --- | --- | --- | --- |
| core 验 app | 内核报告的 uid + `proc_pidpath` 可执行文件白名单 | 别的用户；本机上没准备的进程；非管理员改不动 `/Applications/akari.app` 里的二进制 | 同 uid 且能覆写开发树路径的攻击者；pid 回收的窗口 |
| app 验 core | `lstat` socket 与其目录的属主 / 模式 / 类型 + 发布版忽略 `AKARI_SOCKET` | 别的用户的 socket；`/tmp` 之类谁都能写的目录；靠环境变量改道 | **同一个 uid 的进程** —— 它可以 unlink 掉真 socket，在同一个 0700 目录里 bind 一个同样 0600 的自己的 socket，`stat` 分辨不出来 |

app 这一侧**没有**去读 `LOCAL_PEERPID` 反查 core，这是权衡后的取舍，两条理由：

1. `NWConnection` 不暴露 fd。要拿到 fd 就得把 socket、写背压、增量分帧全部自己
   写一遍 —— 而且是在跑实时音频的那条路径上。风险大，收益见下。
2. 就算做了也换不来多少东西。core 是**脚本**，对端可执行文件是 `bun`，而 bun 装在
   用户可写的目录里（`~/.bun/bin`、`/opt/homebrew/bin`），谁都能拿它跑任何文件。
   "对端是个 bun"证明不了它是 akari-core。同一个路径档，用在 app 身上（bundle 里的
   真二进制）比用在 core 身上有意义得多。

所以这两个方向都停在同一个地方：**真正能结束这件事的是代码签名档**，见下。

**这是过渡方案，不是解决方案。** 真正的隔离要校验运行中进程的代码签名
（`SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity`），需要 Apple Developer
Team ID，本项目还没有。所以：

- pid 不是身份（可回收）、路径不是身份（可覆写）——**挡得住没准备的本地进程，
  挡不住认真的本地攻击者**；这句话对**两个方向同时成立**，app 侧那半尤其弱：
  它对同 uid 的攻击者基本没有防护；
- `codesign` 档位是**声明了但故意抛错拒绝启动**的，绝不用一个"跑 `codesign` 校验
  磁盘文件"的退化版冒充它 —— 那和路径档是同一个 TOCTOU 洞，只是换了个好听的名字；
- 当前档位每次启动都打进日志，README 里也写明。

拿到 Team ID 之后要做的事已经准备好：`PeerIdentity.auditToken`（32 字节
`audit_token_t`）已经在采集了，接上去即可。

### 二、发布版只执行包内的 core

旧实现从可执行文件位置向上搜 8 层找 `core/package.json`。core 是 akari 的信任
中心（socket 服务端、确认卡片的内容、麦克风上行、`DASHSCOPE_API_KEY`），所以
"把 .app 放进下载目录"就等于"谁能往 app 旁边写一个文件夹，谁就能让 akari 替他
执行代码"。现在发布版只认 `Contents/Resources/core`，且从 `.app` 里运行时一律不
向外搜；`AKARI_CORE_ROOT` / `AKARI_BUN` 覆盖仅在 DEBUG 生效。

### 三、剪贴板读取移到 app 侧（协议 §3.7 两侧均已实现）

`pbpaste` 看不见 `org.nspasteboard.ConcealedType` / `TransientType` —— 密码管理器
就是用这两个 UTI 标记它复制出去的密码。core 侧读一次，用户的主密码就可能进了云端
模型的日志。现在这一读发生在 app 侧（`NSPasteboard.general.types`），带标记就
**根本不去读文本**，只回一句"已跳过"。`clipboard_read` 因此从 🔴 RED 降为 🟢 GREEN
—— 降级的依据是能力变强了，不是要求变松了。

### 四、注入防御从"改东西"扩到"往外送东西"

原实现只在 `mutating` 的工具上做 untrusted 升级。"读一下剪贴板，然后搜一下"是
两次只读调用、零 mutation、全量泄漏。现在 `readsSensitive` / `exfiltrates` 与
`mutating` 并列，三者任一都会在污染上下文里升到 RED。

### 五、其余（不改变任何 ADR，只是修 bug）

- 断线重连后播放流被上一次会话的"取消名单"误杀 —— 她张嘴不出声且永远卡在 talking。
- 首启授权弹框期间松手会导致麦克风常开；授权移到启动时，按键路径上不再有异步步骤。
- RED 卡片加了 600ms 防误触 + 命令看全才能批准，回车默认落在**拒绝**上。
- Realtime 的 `response.done{failed}` 与"短按/未连接"两条路径此前不终结回合，
  形象永久停在 talking / thinking；现在都会收尾并通过新增的 `ui.notice` 告诉用户原因。
- 子进程不再继承完整环境（白名单 9 项），密钥不会流进 `pbpaste` / `open`。
- Realtime 端点做了白名单校验，改不动 `.env` 就改不了凭据的去向。
- app 被强杀后遗留的孤儿 core 会自己退出（`AKARI_SUPERVISED` + 父进程看门狗），
  不再挂着一条按分钟计费的 Realtime 会话。
- 工具调用落盘审计（JSONL，0600），每条记录附带当时连着的是哪个客户端。

### 遗留

| 事项 | 卡在哪里 |
| --- | --- |
| `codesign` 档位的对端校验（core 验 app） | 需要 Apple Developer Team ID |
| app 验 core 仍挡不住同 uid 的进程 | 同上；`stat` 到此为止，`LOCAL_PEERPID` 反查换不来实质保护（对端可执行文件是 `bun`） |
| SIGKILL 掉 app 时的孤儿 core | 无解，只能靠 core 侧 5 秒轮询的看门狗兜底 |
| RED 确认门从未被真人点过 | 需要 GUI 会话；目前只有 fake app 驱动的自动化覆盖 |
| 麦克风采集 / 扬声器播放 | 需要真机 GUI + 麦克风；语音闭环目前用合成语音灌入验证 |

---

## 第二轮：对抗性验证之后的收口

**日期**：2026-08-19  ·  **状态**：已落地并合并

第一轮那 17 条修完之后又做了一次**对抗性验证**（不看修复者的自述，逐条实跑）。
结论是 15 条真修好了，2 条只修了一半，另有 4 条是第一轮的修复**新引入**的。
本节记的是第二轮把这 6 条清掉的过程，以及为什么其中有些的修法与审查建议不同。

**这一轮的纪律是：每条修复都要有一个能复现该问题的测试，并且要在隔离副本里把
修复撤掉重跑，确认那个测试真的会红。** 只会变绿的测试证明不了任何事 —— 这一轮
里就有两个测试在撤掉修复后依然通过，都被重写或作废了。

### 1. 信任边界只做了一个方向（P1，第一轮引入）

见上面第一条的「补记」，两个方向的档位对照表也在那里。这里只补三件本轮实测到的事：

- **对抗复现是真跑的，不是单元测试**：一个普通 bun 脚本 bind 住某个 socket 路径，
  用 `AKARI_SOCKET` 把**真实 app 二进制**指过去。目录 0777 时 app 拒绝拨号，
  日志一行 `refusing to connect to the core socket: … is mode 0777, expected 0700`，
  假 core 从头到尾没收到 `app.hello`，剪贴板没出去。
- **对照组同样是真跑的**：同一个假 core 换到 0700 目录 + 0600 socket，app 就连上了，
  握手完成，`clipboard.read.request` 拿到了剪贴板全文。**这正是上表「挡不住同一个
  uid 的进程」那一格的实测证据** —— 写在这里而不是藏起来，因为读者需要知道这道
  校验的上限在哪。
- **`CoreProcess.probeSocket` 不走这道校验**（见下面第 2 条）：它对 socket 做一次
  `connect(2)` 就挂断，不发任何字节。抢占了路径的进程因此能知道 app 起来了，也能
  让 app 不去自启 core。这是 P3，记在下面的遗留表里。

### 2. app 会抢掉手工起的 core，多开一条计费会话（P2，第一轮引入）

第一轮给 app 加了「core 没起就自己拉一个」。判据是错的：它问的是「2 秒之后我的
握手完成了吗」，而握手完成的时刻由 app 自己的重连退避决定（累计 0 / 0.25 / 0.75 /
1.75 / 3.75s），跟「这台机器上有没有 core」是两件事。开发时 `make run-core` 起的
core 会被顶掉，被顶掉的那个挂着一条**按时长计费**的 Realtime 会话，且永远等不到
客户端。

改成问内核，不问钟：对 socket 做一次非阻塞 `connect(2)`。

| connect 的结果 | 判定 | 动作 |
| --- | --- | --- |
| 成功 / `EAGAIN`（backlog 满） | `serving` | 有人在服务，绝不 spawn |
| `ENOENT` | `absent` | 没有 core |
| `ECONNREFUSED` | `stale`（core 被 SIGKILL 留下的死 inode） | 可以 spawn |
| 其他（`EACCES` / `ENAMETOOLONG` / `ENOTDIR`） | `unusable` | 不 spawn，起一个也修不好 |

- `grace`（默认 5s，每 200ms 复问）只覆盖「core 正在 bun 冷启动、还没 bind」，
  任何一次探测成功即刻退出。方向上偏保守是免费的（最多晚点自启），偏激进的代价
  是多一条计费会话。
- spawn 前用 `flock(LOCK_EX|LOCK_NB)` 抢 `core.spawn.lock`，两个 app 实例不会同时
  拉起。用 `flock` 而不是 pid 文件：进程死了内核自动释放。
- **陈旧 socket 只识别、不删**。app 侧 unlink 与 core 侧 bind 之间有 TOCTOU 窗口，
  可能误删正在服务的 socket；`Bridge.listen` 本来就会在 bind 时 unlink 死 inode，
  那里没有这个窗口。这一条与审查建议不同，是刻意的。
- 探测路径与拨号路径统一走 `SocketTrust.resolveSocketPath()`，永不漂移，发布版
  同样不认 `AKARI_SOCKET`。

**一个可预期的副作用**：每次成功探测会在 core 的审计日志里留一行
`AUDIT peer refused … the kernel would not report the peer's identity`。因为我们
连上即挂断，`peer.ts` 来不及取 `LOCAL_PEERPID`。它看着像入侵但不是。**它同时是
好事**：core 在给出唯一那个 client 名额之前就丢弃了探测连接，所以探测永远不可能
顶掉 app 自己的真连接（实测 refused 与 accepted 相差 1ms，握手正常）。

**实测**：app 先起、1.85 秒后手工 `bun run src/index.ts` —— 12 秒后
`pgrep -f src/index.ts` 只有 1 个进程，且 app 连的就是那个手工 core。

### 3. 退出 app 会连带杀掉手工起的 core（同上，用户明确要求改掉）

`applicationWillTerminate` 现在只在 `core.isSupervising`（这个 core 是 app 自己
spawn 的、带 `AKARI_SUPERVISED=1` 的那一个）为真时才发 `app.quit`。手工起的 core
看到的只是一次普通掉线。`protocol.md` §3.6 已同步。

**实测**：让一个假 core 给 app 发 `app.quit`（走真协议帧）逼它走优雅退出路径 ——
当前构建**不回** `app.quit`；同一实验对着撤回修复的构建跑，假 core 收到了
`RECV app.quit`。

### 4. 播放队列的账本会漏一个计数（P2，第一轮引入）

换耳机、拔插外接显示器，或用户打断（barge-in）恰好撞上一帧音频入队时，形象会
**永久卡在 talking**：`pendingBuffers` 的计数被留下一个孤儿，`isPlaying` 永远为真，
`onPlaybackFinished` 不再触发，`audio.done` 不再发出。断线重连也救不回来 —— core
重连后 streamId 从 1 重新开始，新 stream 1 直接继承了那个残留计数。

审查建议「把读代次和自增放进同一个临界区」。实际采用的是更强的**票据（ticket）**
方案，理由是合并临界区修不好第二半：`beginPlaybackStream` 清掉 `pendingBuffers`
之后，旧 stream 还在飞的 buffer 其代次与当前代次相同，会去减新 stream 的计数。

```swift
private struct PlaybackRun { let ticket: UInt64; var pending: Int }
```

票据在**第一次把某个 buffer 计入某个 stream 的那个临界区里**铸出，队列每被重置
一次（`cancelPlayback` / `beginPlaybackStream`）就作废。completion 的票据对不上就
直接忽略：不减、不删。`playbackGeneration` 字段整个删掉了 —— 票据严格强于代次
（代次只能区分 flush 前后，票据能区分「这一轮 / 那一轮」），净结果少一个字段。

顺带改正了一条假前提的注释：`cancelPlayback` 的调用方**不是**串行的。
`AVAudioEngineConfigurationChange` 的两个观察者用 `queue: nil` 注册，在发帖线程
执行，与主 actor 上的 `enqueuePlayback` 真正并发。保证账本正确的是票据，不是
调用方纪律。

**撤销复跑**：独立写的四生产者压测（`AdversarialPlaybackStressTests`）在撤回票据、
改回代次方案的隔离副本上，**第 0 轮**就抓到四条流各留 1 个孤儿计数，连跑 3 次都是
第 0 轮；修复版连跑 3 次全绿。写这个测试的过程本身也是个教训：第一版在每轮末尾
补了一次 `cancelPlayback`，那会把要找的孤儿冲掉，于是它在撤销版上照样通过 ——
改成「不 flush，等账本自己归零」之后才有意义。

### 5. 说话中间停顿再松手会弹「没听清」（P2，第一轮引入）

`silence_duration_ms: 800`，所以说话中间正常停顿一下，服务端 VAD 会在**按键还按着**
的时候就 commit 并开始回答。松手时缓冲区里只剩停顿之后的那几帧，第一轮的修复据此
判定「按得太短」，弹一句「没听清」——这句提示既是假的（她听清了，正在回答），又会
诱导用户重按一次，从而**真的**打断她。

修法是加一个**按压级**字节计数器 `uplinkBytesSincePress`：`appendAudio()` 累加，
只有 `commitAudio()` 清零；而 `uplinkBytesSinceCommit` 会被**每一次**
`input_audio_buffer.committed` 清零，包括服务端自行提交的那次。于是
`appendedThisPress > pending` 精确等价于「这次按压期间落过一次 commit」，
三种情况自然分开：整轮没说话时两者严格相等（→ abandon）；中途被提交时严格大于
（→ 静默返回，回答已在路上）；未连接走在更前面的分支。

**没有采用**「看 `activeResponseId` 是否非空」的建议，它有两个真实漏口：停顿触发的
回答可能先于松手结束（`response.done` 已到，字段归 null）；停顿后又蹦出一个很短的
词会触发 server_vad 打断，`response.done{cancelled}` 同样把字段归 null。按压级计数
不依赖回复的生命周期状态。

`onSocketClosed()` 里也一并清零 `uplinkBytesSincePress`：掉线前 append 的音频从未被
提交，重连后松手必须仍算作丢掉的一轮，而不是被误判成「中途已提交」。这一条本轮
补了测试（`a press interrupted by a reconnect is still a turn nobody heard`），
撤掉那一行赋值它就红。

这条修复**不需要** `core/src/index.ts` 配合改动：`onTurnAbandoned` 的 reason 集合
没变（仍是 `not_connected` | `too_short`）。

### 本轮的遗留（P3，本轮不修）

| 事项 | 说明 |
| --- | --- |
| `probeSocket` 不做 `SocketTrust` 校验 | 抢占了 socket 路径的同 uid 进程能知道 app 启动了，并让 app 不去自启 core。不泄漏任何字节（连上即挂断）。属于「同 uid 攻击者」那一格，与主结论同级 |
| barge-in 后可能漏出一帧（20ms）音频 | `cancelPlayback` 的 `player.stop()` 返回之后、并发的 `enqueuePlayback` 才调到 `scheduleBuffer` + `play()`。关掉它要在 AVFoundation 调用上加锁，代价大于收益 |
| `cancelPlayback(nil)` 不会把「尚无 buffer 的流」加进忽略名单 | ids 取自 `pendingBuffers.keys`。目前只有全局 flush 走这条路，之后不会再有帧进来 |
| 停顿触发的回答**播完之后**才松手 | 若此时新音频 ≥100ms，会正常 commit 一段室内噪声并 `response.create`，她可能对着静音答一句；若 <100ms 则静默返回，形象停在 thinking。后者需要「整段回答在 commit 后 100ms 内播完」，实际不可达，但机制上确实没有兜底 |
| app 先起并自启了 core 之后，开发者再手工 `make run-core` | 新 core 仍会无条件 unlink 抢走 socket。根治点在 `core/src/bridge.ts` 的 unconditional unlink |
| 手工 core 冷启动超过 5 秒才 bind | app 仍会多起一个。这是 `grace` 的固有上限 |

### 本轮没有验证的部分

- **app 自己 spawn core 的那条路径没有跑真实端到端** —— 那会真的开一条计费 Realtime
  会话。该路径除新增的计数器与 `flock` 之外未改动。
- **spawn 锁的互斥只有同进程双 fd 的单元测试**，没有两个真 app 实例的实测。
- 上一节「compiles and is wired, but not yet exercised」里的那些（麦克风采集、
  扬声器播放、屏幕上的形象、确认卡片）本轮同样没有变化。

---

## ADR-009 · 三档推理：语音走 DashScope、文本走用户自己的 CF、本地 MLX 兜底

**日期**：2026-08-19  ·  **状态**：已确定

**决策**：推理分三条独立的路径，各自可在设置界面切换：

| 用途 | 默认路径 | 凭据来源 |
| --- | --- | --- |
| **语音对话** | DashScope `qwen3.5-omni-flash-realtime` | 用户的 DashScope API key |
| **文本 / 看截图** | **用户自己的 Cloudflare Workers AI** `@cf/qwen/qwen3.8-27b` | 用户的 CF account id + API token |
| **兜底（断网 / 额度耗尽 / 隐私模式）** | 本地 MLX `orcarouter/Qwen3.8-27B-Uncensored-MLX` 6-bit | 无 |

**为什么语音不能一起走 CF**：CF Workers AI 有 ASR（`@cf/deepgram/flux`、
`@cf/openai/whisper-large-v3-turbo`）、有 TTS（`@cf/deepgram/aura-2-*`）、有 LLM，
但**没有端到端 Realtime**。而 ADR-004 选 Realtime 的全部理由就是它服务端包办了
VAD 与打断（实测首包 473ms）。改走 CF 就必须退回拼装方案：
自己实现帧级 VAD、语义端点、打断三件事同步、以及 AEC —— 调研点名「最容易做砸的一块」，
+5–8 人天，且延迟退到 p50 650–900ms。

**接受的代价**：用户要配置**两套凭据**（DashScope key + CF account/token）。
首启引导需要把这件事讲清楚，不能让用户以为配一个就能用。

**为什么文本要换成用户自己的 CF 账号**：产品若要分发给他人，
不能内置作者的凭据。文本推理是用量最大、最需要按用户计费的部分，
放在用户自己的 CF 账号下最干净；CF 免费额度对个人日常用量也够。

**衍生工作**：
1. Provider 抽象要从「接口已定义、实现只有 DashScope」补齐到三个实现
2. 设置界面要能独立切换每一路，并显示当前额度 / 连通状态
3. 本地路径需要下载 22.8 GB 权重 —— 该 HF repo 是 **gated**，
   需用户先申请访问并 `huggingface-cli login`，这一步无法由程序代劳
4. 自动降级策略：网络不可用或 CF 额度耗尽时自动切本地，并在界面明示当前在用哪一档

---

## 第三轮：外部（Codex）审查发现的两条

**日期**：2026-08-19

前两轮加固全部由 Claude 自己的 agent 完成 —— 包括那些做得很扎实的对抗性验证
（写假 core 骗出剪贴板、隔离副本撤销修复确认测试会红）。
启用外部审查后，Codex 独立审同一份 diff，**又抓到两条**：

### [P1] core 会 unlink 一个活着的 core 的 socket

`core/src/bridge.ts` 在 bind 前无条件 `unlink`，注释里的理由是：

> Safe because only one core may run at a time; a live peer would have been rejected
> by the already_connected path instead.

**这个理由是错的。** `already_connected` 是应用层拒绝，发生在客户端连上*我们*之后；
而第二个 core 根本不会连第一个 core —— 它直接删掉路径名再 bind 自己的。
第一个 core 继续运行、继续挂着**按时长计费的 Realtime 会话**，但再也无法被连接，
之后所有客户端都接到新的那个上。

**值得记下的是我们自己的验证也看见了这个现象，但归成了 P3**，
描述为「开发时的不便」。定级错了：它让一个付费会话变成不可恢复的孤儿。
外部审查的价值不只在于发现没看见的问题，也在于纠正看见了却低估的问题。

**修法**：unlink 前先 probe，判据与 Swift 侧 `CoreProcess.probeSocket` 对称
（connect 成功或 EAGAIN → live；ENOENT / ECONNREFUSED → 可清理；
其余与超时**一律当作 live**）。最后一条是刻意的保守选择：
拒绝启动是可恢复的，删掉活 core 的 socket 不是。

### [P2] ptt.down 与首个麦克风帧的顺序竞态

`AppDelegate.beginTurn` 先 `startCapture()` 后发 `ptt.down`。
`startCapture()` 安装的 tap 回调跑在 CoreAudio 线程上，可能抢在主 actor 之前把上行音频帧推出去
—— core 于是**在不知道回合已开始的情况下先收到了音频**，违反 protocol.md 的回合顺序。

**修法**：先发 `ptt.down` 再开麦克风；开麦失败则补发 `ptt.up` 撤销该回合
（否则 core 会一直等一个永远不来的 `ptt.up`，而 `endTurn` 的 `guard isCapturing` 会吞掉它）。

### 验证

- socket 抢占：新增 `core/src/bridge.socket-takeover.test.ts` 两条。
  隔离副本撤掉 live 检查后，「第二个 core 拒绝接管」立刻失败；
  对照组「stale socket 仍能清理」保持通过，确认没有修过头。
- PTT 顺序：**没有加自动化测试**。`beginTurn` 是 `AppDelegate` 的 private 方法，
  测它需要先把 PTT 状态机抽成独立类型 —— 那是一个只有单一实现的新抽象。
  这条只做了编译验证与代码走查，**需要人工验证**：按住热键说话，
  确认 core 日志中 `ptt.down` 早于第一个上行音频帧。

`make check`：swift build 零警告 / swift test 80 passed / typecheck 干净 / bun test 162 pass 0 fail。

---

## ADR-009 实施记录：三档推理接起来了

**日期**：2026-08-19  ·  **状态**：已落地（本地那一档除外，权重没下完）

三个实现是并行做出来的（CF provider、本地 provider + 降级路由、设置界面 +
Keychain），这一条记录把它们接起来时**真正发生的事**，以及每一句话的证据等级。

### 接线补了什么

三份代码各自完整，中间是空的：

| 缺口 | 补法 |
| --- | --- |
| `bridge.ts` 完全不认识 `settings.*` / `credentials.*`，它们掉进 `default:` 被当成未知类型忽略 | 新增五个入站分支 + `sendSettingsState()` / `requestCredentials()`。回 `replyTo` 的记账留在 bridge 里，handler 只返回要回的 payload |
| `index.ts` 里没有 `createProviders()`，也没有 router、没有 resolver | 全部接上。`TEXT_PROVIDER_IDS` 的顺序就是降级顺序：CF → 本地 |
| 语音那一路没有 `ProviderHealth` 的来源（它不是 `TextProvider`） | 新增 `core/src/settings.ts`：`SettingsService` 从凭据解析结果 + 一个 4 方法的 `VoiceSession` 缝算出语音行 |
| `configFromEnv()` 只认 `process.env.DASHSCOPE_API_KEY`，override 补不上 | 改成 `overrides.apiKey ?? process.env…`。否则「凭据走 socket」对语音就是一句空话 |
| `RealtimeClient` 无法换 key | 新增 `setApiKey()` + `RenewReason: "credentials"`。key 只用在 WS 握手上，所以换 key 必然换 socket —— 但仍然走 `maybeRenew()` 等回合边界，中途断会丢掉用户正在说的那句 |

### 接线时发现的四个问题（都已修）

**1. [P1] shell 里的环境变量悄悄压过 `.env`，症状是「curl 能跑、程序 401」。**
`loadEnvFile` 遇到已存在的变量就跳过（常规 dotenv 行为，且是本仓文档写明的顺序）。
这台机器的 profile 为别的项目导出了另一对 `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_API_TOKEN`，
于是 core 一直在拿错账号打 Workers AI，`probe()` 回 `unauthorized`，
而同一份 `.env` 的值用 `curl` 打过去是 200。
**顺序不改**（改了会让「进程环境优先」这条约定在别处失效），但**不再沉默**：
core 启动时按变量名 warn，且只在两边的值**真的不同**时才 warn。
这一条值得记下来的原因是：它长得和「token 失效了」一模一样，
而设置界面里那套 fingerprint 对比正是为这类事故存在的 —— 只不过它比的是 `.env`，
比不到 shell 环境。

**2. [P2] 探测失败后，上一次成功的 `quota` 还留在那一行上。**
`TextRouter.probe()` 把新结果 spread 到旧 health 上，`quota` 没有被覆盖，
于是用户刚删掉 token、行变成 `unconfigured`，界面上仍然显示「今天用了 161 neurons」。
改成**整行重建，不再 merge**：探测没说的字段就是没有。
`missing` 同理；`chat()` 失败时若状态是 `unconfigured` / `unauthorized` 也清掉 `quota`。

**3. [P2] 凭据修好之后，provider 还被冷却挡着。**
`unauthorized` / `model_missing` 是粘性失败，一次就降级 60s（且翻倍）。
用户在设置里换上一把能用的 token 之后，如果这一步没有紧跟一次探测，
路由还会继续走兜底最多 15 分钟 —— 而界面会显示「可用」。
新增 `TextRouter.resetDemotions()`，凭据一变就调用。只清冷却，不动 `status`
（`status` 是最后一次**实际观测**到的事实）。

**4. [P3] `--no-realtime` 的语音行说「看 core 的日志」。**
那是个刻意的开关，不是故障。改成单独报这一种情况。

### 凭据方案最终是哪个：**socket 索取，不是 spawn 时注环境变量**

按 protocol.md §8.3 定的方案落地，没有改。理由那里写了三条，
实施过程中第二条（「密钥不进环境」）反而变得更重要了：
本轮排掉的第 1 个问题正是「环境变量里的凭据在你不知情时生效」的另一个面。

### 实测过的（真跑，不是编译过）

- **Cloudflare Workers AI**：装配好的 core + 假 app 走真 socket，
  用仓库 `.env` 里的账号探测 `@cf/qwen/qwen3.8-27b` → `ok`，1157ms，
  GraphQL 读回当日真实用量（当天 162 neurons）。
- **写错模型 id**：故意把 `CF_AI_CHAT_MODEL` 指向 `@cf/qwen/does-not-exist`
  → 线上回 **HTTP 400 + CF 错误码 7000**（不是 404）→ 映射成 `model_missing`。
  cf-provider 那份报告里「只按 404 判会错分」的结论，现在对着线上确认了。
- **设置消息往返**：`settings.get` / `settings.set`（含未知 provider 回
  `bad_payload` 且**状态没变**）/ `settings.probe`（`timeoutMs:0` 被拒）/
  `settings.probeResult`（`replyTo` 配对）。
- **凭据往返**：连上就 `credentials.request` 四个槽 → `credentials.provide` →
  钥匙串值压过 `.env`（`source:"app"`）、`cleared` 抑制回退、`denied` 回退但单独标记。
  `settings.state` 与 core 日志里**没有出现任何凭据值**，只有 8 位 fingerprint。
- **跨语言 payload**：从运行中的 core 抓了四帧原文（`ts`、字段顺序、`active:null`、
  真实 quota 块、四种凭据状态齐全），用 app 真正的 `Codable` 类型解。
  这是 Swift↔Swift 往返测不到的那一半 —— 第一版手抄的固件就漏了 `ts`，当场红。

### 没实测的，明说

- **本地 MLX 这一档不能生成。** 权重只有 5 个分片里的第 5 个（1.3 GiB / 21.2 GiB），
  下载没在跑。`probe()` 正确地报 `model_missing` 并给出百分比 —— 这一条是实测的；
  但**加载、空闲卸载、视觉塔、以及「降级之后本地真的答出来」全部未验证**。
- **降级的「换人」那一半只有 mock 覆盖。** 线上确认的是前半段：CF 真的失败、
  真的被降级、`active` 真的变。后半段没有能应答的兜底可换。
- **语音这一路本轮没有对着 DashScope 跑过。** `setApiKey` 的续会话是对着
  `FakeRealtime` 测的；`classifyVoiceFailure` 对 401/403/429 的判定是**对字符串做模式匹配**，
  只有超时那一支来自真实行为，其余是拿字符串喂给函数测的。
- **设置窗口没有人点过。** 只有离屏渲染 + 假 app 驱动。
- **`TextRouter.chat()` 没有调用方。** 文本 / 看截图这一路建好了、能选、能探测、
  凭据也通到了，但会用它的东西（看屏幕的工具、或一个文字输入口）还不存在。
  说「文本推理接通了」是指这条链路通了，不是指现在能跟她打字聊天。

### 验证

`make check`：swift build 零警告 / **swift test 146 passed** / typecheck 干净 /
**bun test 335 pass 0 fail**（接线前是 140 / 288）。

---

## RISK-4 关闭 · 本地模型实测（2026-08-19）

在目标机器（M4 Max / 64 GB / macOS 26.6.1）上实测
`orcarouter/Qwen3.8-27B-Uncensored-MLX` 6-bit：

| 项 | 实测值 |
| --- | --- |
| 磁盘占用 | 22.80 GB（16 个文件，大小与 HF 声明逐一核对一致） |
| **加载耗时** | **5.41s** |
| GPU 常驻（加载后） | 22.78 GB |
| GPU 峰值（推理中） | 26.08 GB |
| 生成速度 | **25.3 tok/s** |
| 稳态单轮平均 | 1.66s |
| **短回答（3 token）** | **0.30s** |
| 长回答（84 token） | 4.23s |

运行时：`mlx-vlm 0.6.15`（**不是 mlx-lm**）。
该模型是 `Qwen3_5ForConditionalGeneration`，带 `vision_config` / `image_token_id` /
`video_token_id`，是真·多模态，`mlx-lm` 加载不了。`mlx_vlm` 的支持列表里有 `qwen3_5`。

### 一个推翻了原设计假设的数字

原本假设「22.8 GB 模型加载很慢，必须懒加载 + 常驻」，据此要求本地 Provider
设计预热机制并暴露加载进度。**实测加载只要 5.41 秒，这个假设不成立。**

因此本地 Provider 应改为**按需加载 + 闲置卸载**：
- 切到本地时加载（用户等约 5 秒，可接受）
- 闲置若干分钟后卸载，把 22.8 GB 交还系统
- 不需要"加载进度条"这种 UI，一个转圈就够

这比常驻 22.8 GB 好得多 —— 尤其本地路径的定位是**兜底**（断网 / 额度耗尽 / 隐私模式），
常态下不该占着四分之一的内存。

### 与调研估算的对照

`docs/spec.md` 引用的调研值是「全本地栈端到端 1.5–2.5s」。
稳态平均 1.66s 落在区间内，但**短回答 0.30s 比估算好一个数量级**，
而日常对话中短回答占多数。结论：本地兜底的体验比原先预期的可用得多。

**仍未验证**：图像输入（看屏幕截图）的实际延迟与质量；
本地 LLM 推理与 60fps 形象渲染并发时的相互拖慢（spec §十 的待验证项 5）。
