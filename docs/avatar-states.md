# 形象状态机与素材规格

对应 ADR-001（预渲染视频循环）与 ADR-008（形象定稿）。
本文件定义有哪些状态、每个状态的身体语言、以及生产每段素材的确切参数。

---

## 一、状态定义

形象不是一段循环动画，而是**一组按对话状态切换的循环**。
这是"配合对话内容"的落地方式 —— 同一个人，不同身体语言。

| 状态 | 触发时机 | 身体语言 | 时长 |
| --- | --- | --- | --- |
| `idle` | 无对话，待机 | 安静，偶尔眨眼与轻微换姿势，视线偶尔飘开又回来 | 8–12s |
| `listening` | 用户按住热键说话中 | **托腮**，身体微微前倾，眼神专注注视，偶尔轻点头 | 6s |
| `thinking` | 已收到语音、等待模型首包 | 视线微微上移或侧移，手指轻触下巴，若有所思 | 4s |
| `talking` | 正在播放 TTS 音频 | 身体前倾，手在胸前有小幅度手势，嘴部持续开合 | 6s（循环至播放结束） |
| `greeting` | 首次唤起 / 长时间未互动后 | 抬头看向你，笑容变深，轻轻挥手 | 4s |

状态切换用两层 `AVPlayerLayer` 之间的 opacity 交叉溶解（3–5 帧）。
**不能用 `AVVideoComposition` 做溶解** —— 它与 `AVPlayerLooper` 互斥，
挂了 composition 无缝循环就失效（见 spec §3.3）。

---

## 二、素材生产规格

### 2.1 定妆图（keyframe）

- 模型：`imagen-nano-banana-2-flash`
- 引用：**必须**是 `{type: "character", identifier: "2183420"}`（见 ADR-006）
- 比例 `3:4`，分辨率 `2k`
- 打光固定：暗调 low-key、深炭灰近黑背景、前左侧柔和主光、**冷色青紫轮廓光**勾勒发梢与肩线

轮廓光不只是美术选择，它同时是**抠像的技术保障** ——
暗背景配深色头发时，轮廓光给 Vision 分割提供了边缘分离线索。

### 2.2 循环视频

- 模型：`bytedance-seedance-pro-2.5`
- `keyframes.start` 与 `keyframes.end` **填同一张图** → 直接得到无缝循环
  （实测首尾帧平均像素差 1.5，无需手工挑帧做交叉溶解）
- `cameraMotion: "static"`
- `withSoundEffects: false` —— **完全不要音轨**。她的声音由 Qwen Realtime 实时生成，
  视频内置音频纯属多余（前两段测试都白带了一条 aac 轨）
- 验证用 720p（2,640 积分），正式素材 1080p（4,740 积分）

### 2.3 视频提示词的两条硬规则

**规则一：只写动作，绝不写服装或身体部位。**

Seedance 的内容审核会拦截。实测对照：

| 提示词 | 结果 |
| --- | --- |
| 含 `bare shoulder` / `exposing collarbone` | ❌ `Seedance blocked this request due to moderation rules` |
| 同一张 keyframe 图，只描述呼吸/眨眼/微笑/发丝 | ✅ 通过 |

结论：**卡的是提示词，不是图片**。而且服装与身体本来就由 keyframe 图定死了，
在提示词里重复描述既无必要又会触发审核。

**规则二：背景约束必须写死。**

实测四张里出现过一张模型擅自把纯色背景换成户外庭院。提示词固定加上：

> The background remains a perfectly uniform dark charcoal backdrop with
> no scenery, no furniture, no plants, no windows and no change whatsoever.

### 2.4 微风吹发

让循环"活"起来的关键细节，静态图做不到，必须写进视频提示词：

> A gentle steady breeze blows toward her from the front, as if a small fan
> were placed just off camera: her long hair drifts and lifts continuously in
> the airflow, individual strands floating and settling.

### 2.5 抠像与编码

见 [`tools/matte`](../tools/matte)。Vision 人像分割 → HEVC-with-alpha。

**注意裁剪**：模型有时会在画面底部生成桌面（即使提示词写了 `no table`）。
抠像会把桌子去掉、留下悬空的小臂。对策是**生成后裁掉底部约 20%**，
把支撑点藏到画面外 —— 顺带还提高了人物在画面中的占比。

---

## 三、素材命名与目录

```
assets/
  akari/
    listening.mov      # HEVC-with-alpha, 3:4
    idle.mov
    thinking.mov
    talking.mov
    greeting.mov
    keyframes/         # 对应的定妆图，便于重新生成
```

素材体积可观（1080p HEVC-alpha 每段数 MB），已在 `.gitignore` 中排除 `*.mov` / `*.mp4`，
不入库，按需分发。

---

## 四、运动幅度与速度的调校

用户反馈「头发飘动幅度太大、频率太快，要微微拂动，也要慢一点」时，
量化对比揭示了一件事：**这是两个独立的问题，需要两个不同的手段**。

测量方法：按 8fps 抽帧，取人物右侧头发区域，计算相邻帧的平均像素变化。

| 版本 | 平均帧间变化 | 峰值 |
| --- | --- | --- |
| 原版（`gentle steady breeze`） | 0.71 | 1.45 |
| 改提示词为「几乎静止的空气」 | 0.52 (73%) | **0.96 (66%)** |
| 原版后期放慢 1.5× | **0.49 (69%)** | 1.38 (95%) |
| **两者叠加（采用）** | **0.35 (49%)** | **0.68 (47%)** |

**结论**：
- **提示词砍的是「幅度」** —— 峰值从 1.45 降到 0.96，大摆动被消除
- **后期放慢砍的是「速度」** —— 平均值降了，但峰值几乎不变（放慢不改变摆动幅度）

两者解决的不是同一件事，所以要叠加：先用「几乎静止」的提示词生成，再用
[`tools/retime`](../tools/retime) 放慢 1.4×。

### 生效的提示词写法

不要写 `gentle` / `subtle` 这类形容词，模型对它们不敏感。要写**具体的物理约束**：

> The air around her is almost completely still. Only the very faintest, slowest
> drift of air reaches her — just two or three fine strands near her cheek stir
> gently and settle again over several seconds, barely perceptible. The bulk of
> her hair stays essentially at rest throughout; it does not sweep, flutter,
> billow or lift.

关键是三点：给出**数量**（两三缕而非整头发）、给出**时间尺度**（数秒才完成一次）、
**逐一否定**不想要的运动（sweep / flutter / billow / lift）。

### 采用的最终参数

`listening` 状态：6s 生成 → retime 1.4× → **8.37s / 30fps**，
再经 `tools/matte` 抠像为 HEVC-with-alpha。


---

## 五、Seedance 会在首帧重绘人物（重要，会影响所有素材）

`keyframes.start` **不是像素级锁定第一帧** —— Seedance 会按自己的理解重绘一遍人物。

实测证据（`idle` 状态）：把定妆图原图与生成视频的首帧/中段/尾帧并排对比，
**从定妆图到视频首帧，脸就已经变宽变圆了**，之后整段视频维持这个新脸型。
也就是说这不是"生成过程中逐渐漂移"，而是**转换的第一步就发生了身份偏移**。

### 什么情况下会暴露

- **正面或接近正面的姿态最容易暴露** —— 脸宽的变化在正面视角下最显眼
- **侧脸姿态不容易暴露** —— 同一批生成的 `thinking`（侧脸、眼神上飘）就没有明显变化

所以不能因为某一条素材看起来正常，就假设整批都没问题。**每条素材都要单独比对定妆图。**

### 对策：提示词里显式钉住面部结构

只写动作是不够的，必须在提示词开头加一段身份约束：

> IDENTITY MUST NOT CHANGE: reproduce the person in the first frame exactly.
> Her face keeps precisely the same shape, width, jawline and chin as in that frame —
> do not widen, round, soften or fill out her face; do not alter her cheekbones or the
> slimness of her jaw. Her body proportions, shoulder width and silhouette stay identical
> to the first frame throughout. Every frame must look like the same photograph, only alive.

注意这与 §2.3 的「只写动作，不写服装或身体部位」并不矛盾：
那条规则是为了规避内容审核（审核卡的是**裸露相关**的身体部位描述），
而这里写的是**面部结构与比例**，不触发审核。实测这段约束能通过审核。

### 验收步骤（必做）

每生成一条素材，把**定妆图原图**与**视频首帧**并排比一次。
不要只看视频内部各帧是否一致 —— 首帧本身就可能已经偏了。

```bash
ffmpeg -i keyframe.png -vf scale=380:-1 K.png
ffmpeg -i clip.mp4 -vf "select='eq(n\,0)',scale=380:-1" -frames:v 1 F.png
ffmpeg -i K.png -i F.png -filter_complex hstack compare.png
```
