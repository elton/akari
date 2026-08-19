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
- `outputFormats: mp4, mov` → **`.mov` 是否携带 alpha 通道待验证**（关键技术风险，见 RISK-1）
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
| RISK-1 | Seedance 2.5 输出的 `.mov` 是否携带 alpha 通道 | 决定角色能否真正"抠像"贴在桌面上，还是只能带背景显示 | 实际生成一段短视频，`ffprobe` 检查 pix_fmt 是否为 `yuva*` / 编码是否为 ProRes 4444 |
| RISK-2 | macOS 26 上桌面壁纸层窗口是否仍可用 | 决定形象能否"贴在桌面"而不是浮在所有窗口之上 | 写最小 Swift demo 验证 NSWindow.level + collectionBehavior |
| RISK-3 | 外放场景下的回声消除 | 不做 AEC，麦克风会听到 AI 自己的声音，打断功能直接失效 | 验证 macOS VoiceProcessingIO AudioUnit 实际效果 |
| RISK-4 | 本地模型端到端延迟 | 决定"切本地"是不是真的可用 | 拉下 6-bit 权重实测首 token 延迟与 tokens/s |
