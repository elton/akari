# akari 进程间协议 v1

akari.app（Swift）与 akari-core（TypeScript/Bun）之间的全部通信。
**本文件是权威定义**，两侧的类型镜像必须与它保持一致：

| 侧 | 镜像文件 |
| --- | --- |
| Swift | [`app/Sources/AkariApp/Protocol.swift`](../app/Sources/AkariApp/Protocol.swift) |
| TypeScript | [`core/src/protocol.ts`](../core/src/protocol.ts) |

改协议的顺序是：先改本文件 → 同一个 commit 里改两个镜像。

---

## 一、传输层

- **Unix domain socket**，不用本地 HTTP 端口。
  原因见 `spec.md` §3.1：macOS Tahoe 26.3.x 上重签名的 App 会从 Local Network
  列表中消失，之后连不上 localhost。
- **core 是服务端**（`bind` + `listen`），**app 是客户端**（`connect`）。
  core 可以先于 app 启动，app 负责重连。
- 默认路径：`~/Library/Application Support/akari/core.sock`
  环境变量 `AKARI_SOCKET` 覆盖（两侧都读这个变量）。
- **同一时刻只接受一个客户端连接。** 已有连接时的新连接会收到
  `error{code:"already_connected", fatal:true}` 然后被关闭。
- core 启动时若发现路径已存在残留 socket 文件，先 `unlink` 再 bind。
- 双向流式，无请求-响应约束：任一侧可随时主动发送。

---

## 二、帧格式

**每一帧都是**：

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+---------------------------------------------------------------+
|                        length (uint32 BE)                     |
+--------+------------------------------------------------------+
|  type  |                     payload                          |
| uint8  |                  (length - 1 bytes)                  |
+--------+------------------------------------------------------+
```

- `length` = **type 字节 + payload 的总字节数**（即长度前缀之后的所有字节）。
  最小合法值为 1（只有 type、payload 为空）。
- 字节序：长度前缀与所有二进制头部字段一律 **大端（big-endian）**。
  ⚠️ 音频采样点本身是 **PCM16 小端（little-endian）** —— 这是 CoreAudio 与
  Realtime API 的原生格式，不做转换。两处字节序不同是刻意的，别统一。
- `length > 4194304`（4 MiB）视为流已错位：**直接关闭连接，不要尝试重新同步**。
- 一次 socket read 可能拿到半帧或多帧，两侧都必须实现增量解析器
  （`FrameReader` / Swift 侧同名逻辑）。

### type 取值

| 值 | 名称 | 方向 | payload |
| --- | --- | --- | --- |
| `0x01` | `control` | 双向 | UTF-8 JSON，见 §三 |
| `0x02` | `audio.uplink` | app → core | 麦克风 PCM，见 §四 |
| `0x03` | `audio.downlink` | core → app | 扬声器 PCM，见 §四 |

其它取值 = 协议错误，回一条 `error{code:"bad_frame_type", fatal:true}` 后关闭。

---

## 三、控制帧（`0x01`）

payload 是**一个** UTF-8 JSON 对象，**不带换行、不做分隔** —— 边界由长度前缀决定。

### 信封

```json
{
  "v": 1,
  "id": "b3f1c0e4-...",
  "ts": 1755607200123,
  "replyTo": "a1b2...",
  "type": "avatar.setState",
  "payload": { "state": "listening" }
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `v` | `number` | 是 | 协议版本，当前恒为 `1` |
| `id` | `string` | 是 | 发送方内唯一，建议 UUIDv4 |
| `ts` | `number` | 是 | 发送时刻的 Unix 毫秒时间戳 |
| `replyTo` | `string` | 否 | 回应某条消息时填对方的 `id` |
| `type` | `string` | 是 | 见下表 |
| `payload` | `object` | 视消息而定 | 无 payload 的消息**省略该字段**，不要写 `null` |

**未知 `type` 必须被忽略**（记一条 warn 日志即可，不要断连）——
这是唯一的向前兼容手段，让一侧可以先上新消息。
已知 `type` 但 payload 字段缺失/类型不符，则回 `error{code:"bad_payload"}`，不断连。

### 消息一览

| `type` | 方向 | 说明 |
| --- | --- | --- |
| `app.hello` | app → core | 连接后的第一帧 |
| `core.ready` | core → app | 握手应答，宣告音频格式 |
| `avatar.setState` | core → app | 切换形象状态 |
| `ptt.down` | app → core | 按下热键，开始收音 |
| `ptt.up` | app → core | 松开热键，停止收音 |
| `audio.begin` | core → app | 开始一段播放流 |
| `audio.end` | core → app | 该播放流的音频已发完 |
| `audio.cancel` | core → app | 丢弃未播完的音频（打断） |
| `audio.done` | app → core | 该播放流已全部播完 |
| `tool.confirm.request` | core → app | 弹 RED 确认卡片 |
| `tool.confirm.response` | app → core | 用户的裁决 |
| `tool.undoable` | core → app | YELLOW 的 1.5s 可撤销提示 |
| `tool.undo` | app → core | 用户点了撤销 |
| `clipboard.read.request` | core → app | 读剪贴板（app 侧判断是否被标记为机密）|
| `clipboard.read.response` | app → core | 剪贴板内容，或"已标记为机密"|
| `ui.notice` | core → app | 一行给用户看的提示（菜单栏状态行）|
| `settings.get` | app → core | 要一份当前设置快照 |
| `settings.state` | core → app | 每一路在用哪个 provider、连通状态、额度 |
| `settings.set` | app → core | 切换某一路的 provider |
| `settings.probe` | app → core | 测试连接 |
| `settings.probeResult` | core → app | 测试结果 |
| `credentials.updated` | app → core | 钥匙串变了（只报槽名，不带值）|
| `credentials.request` | core → app | 索取某几个槽的值 |
| `credentials.provide` | app → core | **唯一携带凭据明文的消息** |
| `app.quit` | 双向 | 请求退出 |
| `ping` / `pong` | 双向 | 保活 |
| `error` | 双向 | 错误 |
| `log` | 双向 | 转发日志 |

---

### 3.1 握手

#### `app.hello` — app → core，**必须是连接后的第一帧**

```json
{ "protocolVersion": 1, "appVersion": "0.1.0", "appBuild": "42" }
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `protocolVersion` | `number` | app 实现的版本 |
| `appVersion` | `string` | CFBundleShortVersionString |
| `appBuild` | `string` | CFBundleVersion |

若第一帧不是 `app.hello`，或 `protocolVersion` 与 core 不一致，
core 回 `error{code:"protocol_mismatch", fatal:true}` 并关闭连接。
**版本不匹配不做降级协商** —— 两侧同仓发布，不需要。

#### `core.ready` — core → app

```json
{
  "protocolVersion": 1,
  "coreVersion": "0.1.0",
  "uplink":   { "sampleRate": 16000, "channels": 1, "encoding": "pcm16le", "frameMillis": 20 },
  "downlink": { "sampleRate": 24000, "channels": 1, "encoding": "pcm16le", "frameMillis": 20 }
}
```

**音频格式由 core 宣告，不在两侧硬编码。** 因为采样率取决于 core 当前
选用的 Realtime provider，app 只是执行者。app 在收到 `core.ready` 之前
**不得**发送任何音频帧。

`AudioFormat` 字段：

| 字段 | 类型 | 取值 |
| --- | --- | --- |
| `sampleRate` | `number` | Hz，如 `16000` / `24000` |
| `channels` | `number` | v1 恒为 `1` |
| `encoding` | `string` | v1 恒为 `"pcm16le"` |
| `frameMillis` | `number` | 每帧毫秒数，如 `20` |

一帧的 PCM 字节数 = `sampleRate × channels × 2 × frameMillis / 1000`。
上表默认值下：上行 640 字节/帧，下行 960 字节/帧。

> ⚠️ **上下行采样率的默认值（16k/24k）尚未在本项目实测**，取自 Qwen Realtime
> 的常见配置。这正是把它做成协商字段而不是常量的原因：实测后只改 core 一处，
> app 无需改动。

---

### 3.2 形象

#### `avatar.setState` — core → app

```json
{ "state": "talking", "transitionMs": 120 }
```

| 字段 | 类型 | 取值 |
| --- | --- | --- |
| `state` | `string` | `"idle"` \| `"listening"` \| `"thinking"` \| `"talking"` \| `"greeting"` |
| `transitionMs` | `number?` | 交叉溶解时长，省略则用 app 默认值（约 120ms） |

状态含义与素材规格见 [`avatar-states.md`](./avatar-states.md)。
**状态由 core 决定**，app 不自行推断（唯一例外见 §六 断线降级）。
重复设置同一状态是合法的 no-op。

---

### 3.3 按住说话

#### `ptt.down` / `ptt.up` — app → core

```json
{ "source": "hotkey" }
```

| 字段 | 类型 | 取值 |
| --- | --- | --- |
| `source` | `string` | `"hotkey"` \| `"click"` \| `"menu"` |

语义：

- `ptt.down`：app **已经**开始采集，随后立即开始发 `0x02` 音频帧。
  core 收到后通常回 `avatar.setState{listening}`。
- `ptt.up`：app **已经**停止采集，之后不再发音频帧。
  core 据此 commit 输入缓冲，通常回 `avatar.setState{thinking}`。
- 未配对的 `ptt.up`（没有对应的 down）必须被忽略，不是错误 ——
  热键在窗口失焦时丢 keyUp 是常见情况。
- 收到第二个 `ptt.down` 而中间没有 `ptt.up`：core 视作前一轮已结束并开始新一轮。

**不要在任何一侧实现 VAD 或打断逻辑。** 服务端 `server_vad` 负责端点检测，
`interrupt_response: true` 负责打断（ADR-004）。

---

### 3.4 音频播放流

一段回复 = 一个 **playback stream**，由 `streamId`（uint32）标识，从 1 递增，
回绕后跳过 0（0 保留为"无效流"）。

#### `audio.begin` — core → app

```json
{ "streamId": 7, "format": { "sampleRate": 24000, "channels": 1, "encoding": "pcm16le", "frameMillis": 20 } }
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `streamId` | `number` | uint32 |
| `format` | `AudioFormat?` | 仅本流覆盖 `core.ready` 的 `downlink`，省略即沿用 |

#### `audio.end` — core → app

```json
{ "streamId": 7 }
```

音频**已发完**，但通常尚未播完。app 继续播完队列里剩余的样本。

#### `audio.cancel` — core → app

```json
{ "streamId": 7 }
```

`streamId` 省略 = 取消所有在途播放流。app 必须**立即**丢弃队列中的样本。
用于被打断的场景。被取消的流**不再**发 `audio.done`。

#### `audio.done` — app → core

```json
{ "streamId": 7 }
```

最后一个样本已渲染完毕。core 通常据此把形象切回 `idle`。

**迟到帧规则**：收到 `audio.cancel` 或 `audio.end` 之后仍到达的、属于该
`streamId` 的音频帧，一律静默丢弃，不报错 —— 这是流水线里的正常竞态。

---

### 3.5 确认门（ADR-002）

#### `tool.confirm.request` — core → app（RED）

```json
{
  "requestId": "c-1042",
  "tool": "run_shell",
  "risk": "red",
  "title": "运行 shell 命令",
  "detail": "她想删掉构建产物目录",
  "command": "rm -rf /Users/elton/Dev/01-PWR/akari/app/.build",
  "timeoutMs": 30000
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `requestId` | `string` | core 生成，用于配对 |
| `tool` | `string` | 工具名 |
| `risk` | `string` | `"green"` \| `"yellow"` \| `"red"` \| `"never"`；实际只会出现 `"red"` |
| `title` | `string` | 卡片标题，一行 |
| `detail` | `string?` | 补充说明 |
| `command` | `string?` | **将要执行的原始内容，必须原样展示，不得截断或美化** |
| `timeoutMs` | `number` | 超时自动 deny；`0` = 无限等待 |

#### `tool.confirm.response` — app → core

```json
{ "requestId": "c-1042", "decision": "approve" }
```

| 字段 | 类型 | 取值 |
| --- | --- | --- |
| `requestId` | `string` | 原样回填 |
| `decision` | `string` | `"approve"` \| `"deny"` \| `"timeout"` |

`decision` 只有 `"approve"` 才算通过。**未知取值一律按 deny 处理。**
连接在等待期间断开 = 视同 `"deny"`，core 不得因重连而复用旧的批准。

#### `tool.undoable` — core → app（YELLOW）

```json
{ "requestId": "u-88", "tool": "write_file", "title": "已写入 notes.md", "undoMs": 1500 }
```

工具**已经执行**，app 显示一个可撤销提示条。

#### `tool.undo` — app → core

```json
{ "requestId": "u-88" }
```

用户在窗口内点了撤销。`undoMs` 过后仍到达的 `tool.undo` 由 core 忽略。
GREEN 级工具不产生任何消息。

---

### 3.6 生命周期与杂项

#### `app.quit` — 双向，无 payload

- app → core：用户从菜单栏选了退出。core 应收尾并退出进程。
  **仅当这个 core 是 app 自己拉起来的**（即带 `AKARI_SUPERVISED=1` 的那一个）
  才发这一帧。开发者手工 `make run-core` 起的 core 不归 app 管，退出 app
  不应该把它一起带走 —— app 只是关掉自己那条连接，core 看到的是普通掉线。
- core → app：core 主动要求 app 退出（例如致命配置错误）。

发送方在发出后可直接开始退出，不等对方确认。

#### `ping` / `pong` — 双向，无 payload

任一侧可发 `ping`，对方必须回 `pong` 并带上 `replyTo`。
**建议**：app 每 10s 发一次 ping；连续 3 次未收到 pong（30s）视为连接已死，
主动断开并进入重连。core 侧同理，但只需被动响应。

#### `error` — 双向

```json
{ "code": "bad_payload", "message": "avatar.setState: unknown state 'sleeping'", "fatal": false }
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `code` | `string` | 见下表 |
| `message` | `string` | 人读的说明，**不得包含 API key 等凭据** |
| `fatal` | `boolean` | `true` = 发送方在此帧之后立刻关闭连接 |

| `code` | 含义 | fatal |
| --- | --- | --- |
| `protocol_mismatch` | `v` 或 `protocolVersion` 不一致 | 是 |
| `bad_frame_type` | 未知 type 字节 | 是 |
| `frame_too_large` | 长度前缀超过 4 MiB | 是 |
| `already_connected` | 已有客户端占用 | 是 |
| `handshake_expected` | 第一帧不是 `app.hello` | 是 |
| `bad_payload` | 已知消息但字段缺失/类型错 | 否 |
| `audio_format_unsupported` | app 无法按宣告的格式采集或播放 | 是 |
| `internal` | 其它内部错误 | 视情况 |

#### `log` — 双向

```json
{ "level": "warn", "message": "AX query timed out for com.microsoft.VSCode" }
```

`level`：`"debug"` \| `"info"` \| `"warn"` \| `"error"`。
用于把一侧的日志汇总到另一侧的终端，**不承载任何控制语义**。
同样禁止写入凭据。

---

### 3.7 剪贴板读取

> **状态：两侧都已实现。** core 侧 `Bridge.readClipboardText()` 作为
> `ClipboardHost` 注入 `createRegistry({ clipboard })`，app 侧是
> `Clipboard.response(...)`（`app/Sources/AkariApp/Clipboard.swift`）。
> 因为端口已接上，`clipboard_read` 现在按 🟢 GREEN 注册；`pbpaste` 退路仍在
> 代码里（`readViaPbpaste`），但生产路径不再走它 —— 它看不见机密标记，
> 所以没有端口时才会用，并且那种情况下按 🔴 RED 注册。

**为什么剪贴板不能在 core 侧读。** macOS 上剪贴板是密码流经的主要通道：
1Password / Bitwarden 复制出的密码会在里面躺 30-90 秒。业界的约定是写入方
给这类内容打上 UTI 标记 —— `org.nspasteboard.ConcealedType`（机密）与
`org.nspasteboard.TransientType`（短暂，不应被归档）。
**`pbpaste` 看不到这两个标记**，只有 AppKit 的 `NSPasteboard.general.types` 能看到。
所以这一读必须发生在 app 侧，否则模型自主读一次，用户的主密码就进了云端模型的日志。

#### `clipboard.read.request` — core → app

```json
{ "requestId": "cb-7", "maxChars": 8000 }
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `requestId` | `string` | 是 | core 生成，用于配对 |
| `maxChars` | `number` | 否 | 超过则由 app 截断；缺省不截断，由 core 处理 |

#### `clipboard.read.response` — app → core

```json
{ "requestId": "cb-7", "concealed": false, "text": "https://example.com" }
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `requestId` | `string` | 是 | 原样回填 |
| `concealed` | `boolean` | 是 | 剪贴板带 `ConcealedType` 或 `TransientType` 标记 |
| `text` | `string?` | 否 | 剪贴板的文本内容；无文本时省略 |

**`concealed: true` 时必须省略 `text`** —— app 不读、不传，core 也就无从泄漏。
core 会回给模型一句"内容被标记为机密，已跳过"，不解释里面是什么。

app 侧的判断（实现时的参照）：

```swift
let types = NSPasteboard.general.types ?? []
let concealed = types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
```

连接在等待期间断开 = core 视同读取失败，**不得**退回 `pbpaste` 重试。
超时同理：app 5 秒不答就算失败。

---

### 3.8 给用户看的提示

#### `ui.notice` — core → app

```json
{ "level": "warn", "text": "按得太短了（只录到 40ms），没听清。" }
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `level` | `string` | 同 `log`：`"debug"` \| `"info"` \| `"warn"` \| `"error"` |
| `text` | `string` | 一行中文，直接展示给用户。**不得包含凭据。** |

**为什么不用 `log`。** `log`（§3.6）明确"不承载任何控制语义"，而且它在 app 侧
落进 os_log —— 没有人在看。`ui.notice` 是唯一一条"请把这句话放到用户眼前"的消息。
app 把它显示在菜单栏状态行上几秒，然后退回连接状态。

**它是给哪一类情况准备的**：她安静下来了，而这份安静和"她在想"长得一模一样。
目前有三处发送方：

| 场景 | 谁发的 |
| --- | --- |
| 松开热键但没有 Realtime 会话 | `onTurnAbandoned{not_connected}` |
| 按得太短，不够服务端 100ms 下限 | `onTurnAbandoned{too_short}` |
| 服务端放弃了这一轮（限流、内容过滤） | `onResponseFailed` |

`ui.notice` 不改变任何状态 —— 形象状态仍然只由 `avatar.setState` 决定。


---

### 3.9 设置（ADR-009）

推理分成两条**可独立切换的路径**（route）：

| `route` | 干什么 | 候选 provider |
| --- | --- | --- |
| `"voice"` | 语音对话（Realtime 端到端） | `dashscope-realtime` |
| `"text"` | 文本与看截图 | `cloudflare-workers-ai`、`local-mlx` |

**为什么是两条而不是三条。** ADR-009 的表格有三行，但第三行「兜底」不是用户
去选的一条路，而是 `text` 这一路选不到人时往下落的那一档。把它建成第三条 route，
设置界面上就会出现一个「当前两路互相矛盾时无意义」的开关。它在协议里表现为
`RouteState.candidates` 的顺序，以及 `selected: "auto"`。

**语音那一路只有一个候选**，仍然出现在这里 —— 界面要显示它的连通状态与凭据是否配好，
这跟能不能切是两件事。

#### 类型

```ts
type ProviderStatus =
  | "ok" | "unconfigured" | "unauthorized" | "quota_exhausted"
  | "unreachable" | "model_missing" | "starting" | "error" | "unknown";
```

| `status` | 含义 | 界面该让用户做什么 |
| --- | --- | --- |
| `ok` | 探测通过 | — |
| `unconfigured` | 必需的凭据槽是空的，见 `missing` | 去填凭据 |
| `unauthorized` | 凭据被拒（401 / 403） | 换一个 token，或补权限 —— **CF 的 token 只给「读取」时会列得出模型、跑推理 403**，消息里必须点名缺的是 Workers AI「编辑」 |
| `quota_exhausted` | 限流或额度用尽（429） | 等窗口重置，或切本地 |
| `unreachable` | 网络 / DNS / 超时，没人应答 | 检查网络 |
| `model_missing` | 端点通了但模型 id 不存在（404），或本地权重缺失 | 换模型 / 等权重下完 |
| `starting` | 本地运行时正在加载权重 | 等一下再试 |
| `error` | 其它，看 `message` | — |
| `unknown` | 从没探测过 | — |

`ProviderHealth`：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `provider` | `string` | 是 | `"dashscope-realtime"` \| `"cloudflare-workers-ai"` \| `"local-mlx"` |
| `status` | `string` | 是 | 上表取值 |
| `message` | `string?` | 否 | 一行中文，直接展示。**不得包含凭据**，也不得原样转发上游错误体（它可能把 token 回显回来） |
| `missing` | `string[]?` | 否 | 空着的凭据槽，`status="unconfigured"` 时填 |
| `model` | `string?` | 否 | 这一行说的是哪个模型 |
| `capabilities` | `object?` | 否 | `{ vision, tools, streaming, contextTokens, maxOutputTokens?, local }` |
| `quota` | `object?` | 否 | `{ unit, used?, limit?, remaining?, resetsAt?, note? }`，全部可选 |
| `latencyMs` | `number?` | 否 | 上次探测往返 |
| `checkedAt` | `number` | 是 | 上次探测的 Unix 毫秒；从没探测过填 `0` |

> `quota` 每个数字都是可选的，因为**能不能拿到额度数字尚未核实**：CF Workers AI
> 按 neuron 计费，计数在 dashboard / analytics 那边，不在推理端点上。拿不到数字的
> 实现只填 `unit` 与 `note`，界面显示 `note`。

#### `settings.get` — app → core，无 payload

core 回一条 `settings.state`（`replyTo` 填这条的 `id`）。

#### `settings.state` — core → app

```json
{
  "routes": [
    { "route": "voice", "selected": "dashscope-realtime", "active": "dashscope-realtime",
      "candidates": [ { "provider": "dashscope-realtime", "status": "ok", "checkedAt": 1755607200123 } ] },
    { "route": "text", "selected": "auto", "active": "cloudflare-workers-ai",
      "candidates": [
        { "provider": "cloudflare-workers-ai", "status": "ok", "model": "@cf/qwen/qwen3.8-27b",
          "capabilities": { "vision": true, "tools": true, "streaming": true,
                            "contextTokens": 262144, "local": false },
          "latencyMs": 312, "checkedAt": 1755607200123 },
        { "provider": "local-mlx", "status": "model_missing",
          "message": "权重还没下完。", "checkedAt": 1755607190000 }
      ] }
  ],
  "credentials": [
    { "slot": "dashscope.apiKey", "source": "app", "present": true,
      "fingerprint": "3f9a1c02", "envVar": "DASHSCOPE_API_KEY" },
    { "slot": "huggingface.token", "source": "unset", "present": false,
      "cleared": true, "envVar": "HF_TOKEN" }
  ],
  "envFiles": [ { "path": "/Users/…/akari/.env", "loaded": true } ]
}
```

`RouteState.selected` 是 provider id 或 `"auto"`；`active` 是**此刻真正在服务的那个**，
一条路全挂时为 `null`。`credentials` 的字段见 §八。

**core 在下列时刻主动推送 `settings.state`，不必等 `settings.get`**：路由的
`selected` / `active` 变了、某个候选的 `status` 变了、凭据解析结果变了。
握手完成（`core.ready` 已发出）之前不发。

#### `settings.set` — app → core

```json
{ "route": "text", "provider": "local-mlx" }
```

`provider` 可以是 `"auto"`。core 应用之后回一条 `settings.state`（带 `replyTo`）。
route 或 provider 不认识 → 回 `error{code:"bad_payload", fatal:false}`，**且不改动任何状态**。

#### `settings.probe` — app → core

```json
{ "route": "text", "provider": "cloudflare-workers-ai", "timeoutMs": 10000 }
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `route` | `string` | 是 | |
| `provider` | `string?` | 否 | 省略 = 探测这一路的全部候选 |
| `timeoutMs` | `number?` | 否 | 缺省 10000。**不接受 `0`** —— 设置界面上一个永远转圈的按钮不是一种可用状态 |

#### `settings.probeResult` — core → app

```json
{ "route": "text", "results": [ { "provider": "cloudflare-workers-ai", "status": "ok", "latencyMs": 312, "checkedAt": 1755607200123 } ] }
```

`replyTo` 填对应 `settings.probe` 的 `id`。

**「测试连接」测的是已存的凭据，不是输入框里的字。** 探测消息里没有凭据字段，
所以界面上的流程必然是「保存 → `credentials.updated` → `settings.probe`」，
按钮文案应当是「保存并测试」。这是刻意的取舍：另一条路是让 `settings.probe`
携带待测凭据，那就等于在一条为了显示状态而存在的消息上开了个凭据入口，
而这条消息的 payload 是会被日志、错误、审计顺手带走的那一类。
存一个错的 token 在用户自己机器的钥匙串里，代价远小于此。

---

### 3.10 凭据传递（ADR-009）

凭据存在 app 侧的 **Keychain**，core 需要时向 app 要。存储方案、优先级与落选方案见 §八；
这里只定义线上的三条消息。

```
app                                  core
 |-- app.hello --------------------->|
 |<------------------- core.ready ---|
 |<--- credentials.request{cr-1} ----|   core 索取它关心的槽
 |-- credentials.provide{cr-1} ----->|   ★ 唯一带明文的一帧
 |<--- settings.state ---------------|   重建 provider 之后
 |                                   |
 |   （用户在设置里改了 CF token）      |
 |-- credentials.updated{slots} ---->|   只报槽名
 |<--- credentials.request{cr-2} ----|
 |-- credentials.provide{cr-2} ----->|
 |<--- settings.state ---------------|
```

#### `credentials.updated` — app → core

```json
{ "slots": ["cloudflare.accountId", "cloudflare.apiToken"] }
```

只报**哪些槽变了**，不带值。core 收到后对这些槽发 `credentials.request`。
这一条可以随便记日志。

#### `credentials.request` — core → app

```json
{ "requestId": "cr-2", "slots": ["cloudflare.accountId", "cloudflare.apiToken"] }
```

core 生成 `requestId`。app 5 秒不答，core 视同失败并沿用现有值（**不**退回 `.env`，
见 §八「不同步时怎么办」）。

#### `credentials.provide` — app → core

```json
{
  "requestId": "cr-2",
  "values": [
    { "slot": "cloudflare.accountId", "state": "set", "value": "…" },
    { "slot": "cloudflare.apiToken",  "state": "denied" }
  ]
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `requestId` | `string` | 是 | 原样回填 |
| `values[].slot` | `string` | 是 | 见 §八 的槽表；core **忽略**不认识的槽名 |
| `values[].state` | `string` | 是 | `"set"` \| `"cleared"` \| `"unset"` \| `"denied"` |
| `values[].value` | `string?` | 视 state | **仅** `state="set"` 时出现 |

`state` 的四个取值不是同义词，区别在 §八：

- `set` —— 钥匙串里有，`value` 就是它
- `cleared` —— 用户在设置里删掉了。**抑制 `.env` 回退**
- `unset` —— 从没在这里配过。`.env` 回退生效
- `denied` —— 钥匙串没解锁 / 拒绝访问。回退行为同 `unset`，但在
  `settings.state` 里单独标 `denied:true`，好让界面解释这个空字段

**这一帧的纪律，两侧同等约束：**

1. **不得记录。** 任何级别都不行，包括 debug。可以记的只有 `requestId`、
   `slot`、`state`，以及 §八 定义的 `fingerprint`。
   Swift 侧 `CredentialValuePayload` / `CredentialsProvidePayload` 自定义了
   `description`，把 `\(payload)` 这种写法从会泄漏变成不会 —— 有测试守着。
2. app **只答**请求里点名的槽。
3. app **只在自己拨号、且通过了 `SocketTrust` 校验的那条连接上**回答。
4. core 不得把值放进 `settings.state`、`error`、`log`、`ui.notice` 或工具审计。
5. `state != "set"` 时必须**不写** `value` 字段（Swift 侧构造器直接丢掉它）。


---

## 四、音频帧（`0x02` / `0x03`）

payload 布局：

```
+--------+--------+--------+--------+--------+--------+--------+--------+
|              streamId (uint32 BE)  |            sequence (uint32 BE)  |
+--------+--------+--------+--------+--------+--------+--------+--------+
|                  PCM16 little-endian 采样点 ...                        |
+-----------------------------------------------------------------------+
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `streamId` | uint32 BE | 下行 = `audio.begin` 里的流 id；上行 = 本次 PTT 轮次号，`ptt.down` 时自增 |
| `sequence` | uint32 BE | 该流内从 `0` 开始递增，每帧 +1 |
| PCM | 变长 | 交错的 PCM16LE 采样点 |

规则：

- **不使用 base64。** 音频始终走二进制帧，JSON 里永远不出现音频数据。
- 每帧携带 `frameMillis` 毫秒的音频（默认 20ms），最后一帧可以短于此值。
- `sequence` 只用于检测丢帧与乱序（本地 socket 上不该发生，发生了就是 bug）。
  **不要**据此重排序或重传 —— 检测到间断就记 warn 并按原样播放。
- 上行：`ptt.down` 与 `ptt.up` 之间才允许发送。
- 下行：`audio.begin` 与 `audio.end` 之间才允许发送。
- 单帧 payload 上限同样受 4 MiB 约束，正常值在 1KB 量级。

---

## 五、典型时序

### 5.1 一轮完整的语音问答

```
app                                  core
 |-- app.hello ---------------------->|
 |<------------------- core.ready ----|
 |                                    |
 |   （用户按住热键）                   |
 |-- ptt.down{hotkey} --------------->|
 |<--------- avatar.setState{listening}
 |-- 0x02 audio (seq 0,1,2,...) ----->|   → Realtime WebSocket
 |   （松开）                          |
 |-- ptt.up{hotkey} ----------------->|   → input_audio_buffer.commit
 |<--------- avatar.setState{thinking}|
 |                                    |   ← 首个音频包（实测中位 473ms）
 |<--------- audio.begin{streamId:7} -|
 |<--------- avatar.setState{talking} |
 |<--------- 0x03 audio (seq 0,1,...) |
 |<--------- audio.end{streamId:7} ---|
 |   （播完队列）                       |
 |-- audio.done{streamId:7} --------->|
 |<--------- avatar.setState{idle} ---|
```

### 5.2 打断（服务端发起）

```
 |   （用户在她说话时又按住热键）        |
 |-- ptt.down ---------------------->|
 |<-------- audio.cancel{streamId:7} -|   ← 服务端 interrupt_response
 |<--------- avatar.setState{listening}
 |   （丢弃队列，不发 audio.done）      |
```

### 5.3 RED 确认

```
 |<--- tool.confirm.request{c-1042} --|
 |   （卡片，用户点"允许"）             |
 |-- tool.confirm.response{approve} ->|   replyTo = 该 request 的 id
 |                                    |   → 执行工具，结果回传模型
```

---

## 六、连接、错误与重连语义

**谁重连**：只有 app 重连。core 永远只是 listen。

**app 侧退避**：250ms 起，每次翻倍，上限 5s，加 ±20% 抖动。
`disconnect()` 被显式调用后不再重连。

**断线时 app 必须做的四件事**（顺序无关，但一件都不能少）：

1. 停止麦克风采集（丢弃采集中的音频，不缓冲）
2. 丢弃全部待播 PCM，停止播放
3. 形象切到 `idle` —— 这是 app 唯一一次自行决定状态
4. 菜单栏显示"未连接"

**断线时 core 必须做的**：

1. 复位 PTT 状态（视作 `ptt.up`）
2. 所有等待中的 `tool.confirm.request` 按 **deny** 结算
3. 丢弃在途播放流；重连后**不续播**，未说完的话就是丢了
4. Realtime WebSocket **保持连接**（会话贵且有 120 分钟上限，不因 UI 断开而重建）

**重连后**：一切从 `app.hello` 重新开始。`streamId` 计数器两侧都复位。
**不做任何消息重放。**

**缓冲上限**：任一侧的发送队列超过 8 MiB 时，丢弃最旧的音频帧（控制帧永不丢弃）
并记一条 warn。本地 socket 上这只可能发生在对端卡死时，此时保活最重要。

---

## 七、版本演进

- 加**新消息**：不算破坏性变更，`v` 不变。旧实现按"忽略未知 type"规则跳过。
- 加**可选字段**：不算破坏性变更，`v` 不变。
- 改字段类型/取值、改帧布局、删消息：**必须**递增 `v`，
  并同步更新本文件与两个镜像文件。

---

## 八、凭据存储：Keychain 叠加 `.env`（ADR-009）

### 8.1 四个凭据槽

槽名（`slot`）在三个地方是同一个字符串：协议字段、Keychain 的 `kSecAttrAccount`、
core 里 `CredentialSlot` 的取值。**不要为其中任何一处起别名。**

| `slot` | 用途 | `.env` 变量 |
| --- | --- | --- |
| `dashscope.apiKey` | 语音（Realtime） | `DASHSCOPE_API_KEY` |
| `cloudflare.accountId` | 文本 / 看截图 | `CLOUDFLARE_ACCOUNT_ID` |
| `cloudflare.apiToken` | 同上。**需要 Workers AI「编辑」权限**，「读取」跑推理会 403（实测） | `CLOUDFLARE_API_TOKEN` |
| `huggingface.token` | 拉本地权重（该 repo 是 gated） | `HF_TOKEN` |

`cloudflare.accountId` 严格说不是秘密，但它和 token 是同一份配置、同一次修改、
同一次失效，拆到两个地方存只会制造「改了一半」的状态。

### 8.2 app 侧的 Keychain 布局

| 属性 | 值 |
| --- | --- |
| class | `kSecClassGenericPassword` |
| `kSecAttrService` | `"me.eltonzheng.akari"`（= bundle id） |
| `kSecAttrAccount` | 槽名，如 `"dashscope.apiKey"` |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` —— **请求了，当前构建下没有生效**，见下 |
| value | 凭据的 UTF-8 字节；**长度为 0 表示「用户明确清空了」** |

- `WhenUnlocked`：core 只在用户登录并解锁时才会被拉起来，不需要更宽的档位。
- `ThisDeviceOnly`：不进 iCloud 钥匙串。这些凭据配的是**这台机器上的** core，
  同步到一台没装 akari 的设备上没有用途，只是多一份副本。
- **`kSecAttrAccessible` 只在数据保护钥匙串上是真的访问控制。** 落在登录（文件）钥匙串上时，
  这个属性被 API 收下然后丢掉：把探针条目写进去再读回属性，返回的键是
  `["acct","cdat","class","labl","mdat","svce"]` —— **`pdmn` 根本不在里面**（实测）。
  要用数据保护钥匙串就得在每个查询上带 `kSecUseDataProtectionKeychain: true`，
  而它需要 `keychain-access-groups` / `application-identifier` 授权，
  **没有 Apple Developer Team ID 就签不出来**（实测：`SecItemAdd` 回
  `errSecMissingEntitlement` -34018；用 ad-hoc 签名把授权塞进去，进程在 exec 时被内核 SIGKILL）。
  所以当前构建的凭据躺在登录钥匙串里，实际保护是按代码签名匹配的 ACL —— 未签名 / ad-hoc
  签名下每次重编译都会变，接近于零，也是反复弹「akari 想访问钥匙串」的原因。
  **这与 core 的 `codesign` 对端校验卡在同一件事上**，见 decisions.md 的遗留表。
  app 侧的 `KeychainCredentialStore.dataProtectionAvailable` 每次启动实测一次，
  设置窗口按实测结果如实显示，不假装生效。
- **长度为 0 的墓碑必须用「删掉再加」写。** `SecItemUpdate` 带一个零长度
  `kSecValueData` 在登录钥匙串上回 `errSecSuccess` 并**保留原值**（实测），
  于是「清空」会报成功而凭据还在，`.env` 抑制根本没发生。
- **「没有这一项」与「有这一项但长度为 0」是两回事**，对应 `unset` 与 `cleared`
  （§3.10）。这是把「用户删掉了它」这件事记下来的最省的编码 —— 不需要额外的墓碑存储。

### 8.3 core 怎么拿到：走 socket 要，不走环境变量

**决定：core 通过 socket 向 app 索取（§3.10），不由 app 在 spawn 时注入环境变量。**

选它的三条理由：

1. **凭据要能热换。** 设置界面上「保存并测试」必须当场生效。环境变量只在 spawn
   那一刻定死，改凭据就得重启 core —— 而重启 core 会掐掉一条**按时长计费**的
   Realtime 会话（ADR-004），且 app 那边还要走一遍自启/探测的那套逻辑
   （decisions.md 第二轮第 2 条）。为改一个 CF token 付这个代价是荒唐的。
2. **本仓已经把「密钥不进环境」立成了规矩。** 上一轮加固给子进程做了 9 项白名单
   环境（`core/src/tools/builtin/process.ts`），理由原文是「一次注入的
   `run env` 就是整把钥匙」。把凭据放回 core 自己的环境，等于在这条规矩的
   上游把口子重新开出来：往后任何一处忘了用白名单的 spawn 都会重新泄漏。
   环境变量还会出现在同 uid 可读的进程信息、崩溃报告和任何一次顺手的 `env` dump 里。
3. **威胁模型上并不吃亏。** 两个方案都挡不住同 uid 的攻击者：它既能读进程环境，
   也能读 0600 的 `.env`。socket 方案没有让这一格变得更差（见 8.6）。

**落选方案（a）app 在 spawn 时注入环境变量**：实现最简单，且不需要新增协议消息；
但它同时踩了上面三条的前两条，而它省下的复杂度只有两条消息。

代价要说清楚：这条路让**凭据明文经过 socket**。这条 socket 是 0600、位于 0700
目录下的 unix domain socket，两端各自做了对端校验（decisions.md「安全加固」一节），
但 app 验 core 这一侧的上限就是 `stat` —— 见 8.6。

### 8.4 优先级：**按槽**，app 优先

```
app 提供的（Keychain） →  process.env（含 .env） →  未配置
```

- **按槽（per slot），不是按来源。** 钥匙串里只填了 DashScope，CF 仍然从 `.env` 读。
  否则一次填了一半的配置会把一份本来能用的 `.env` 整个作废。
- **app 优先。** 设置界面是用户刚刚动过手的地方；让它输给一个用户早就忘了的文件，
  是最难被报告出来的那种 bug。
- **`.env` 一直有效，而且是唯一完整的无界面配置。** `make run-core` 没有 app，
  也就永远不会有 `app` 来源的值 —— 那条路径必须、也确实只靠 `.env` 就能跑起来。
  Keychain 是**叠加**，不是替代。
- 空白值（全是空格）在任何一侧都按「没有」处理。

`settings.state.credentials[]` 逐槽汇报解析结果：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `slot` | `string` | 见 8.1 |
| `source` | `string` | `"app"` \| `"env"` \| `"unset"` |
| `present` | `boolean` | 解析出了一个可用的值 |
| `fingerprint` | `string?` | 值的 SHA-256 前 8 位十六进制；`source="unset"` 时省略 |
| `cleared` | `boolean?` | 用户在设置里清空了这一槽，`.env` 回退已被抑制 |
| `denied` | `boolean?` | app 读不到钥匙串（锁着 / 被拒） |
| `envVar` | `string` | 这一槽回退去读哪个变量，好让界面直接把名字告诉用户 |

**`fingerprint` 为什么是哈希前缀而不是「后四位」。** 后四位是凭据本身的一部分；
高熵 API key 的 32 位哈希前缀不是可用的爆破口，而它足够回答「变了没有」和
「两边拿的是不是同一份」。app 手里有明文，要在自己的输入框里显示 `sk-…3f9a`
是它自己的事，core 不参与。

### 8.5 不同步时怎么办

| 情况 | 行为 |
| --- | --- |
| 两边都有，值相同（fingerprint 相同） | `source="app"`，**不重建任何 provider**。这是用户把 `.env` 里的 key 复制进设置界面之后的常态，为它重建等于白丢一轮对话 |
| 两边都有，值不同 | app 赢。core 记一条 warn：`credential X: app value overrides .env`（只有 fingerprint，没有值），并重建依赖该槽的 provider |
| 只有 `.env` | `source="env"`，照常工作 |
| app 报 `cleared` | 视为未配置，**且不回退 `.env`**。依赖它的 provider 变成 `unconfigured` |
| app 报 `denied`（钥匙串锁着） | 回退 `.env`。锁着的钥匙串不该顺带把语音一起弄没 |
| app 从没连上过 | 只有 `.env`。这就是 `make run-core` |
| app 断线 | core **保留**最后一次拿到的值，不回退 `.env`。中途换回另一份凭据等于悄悄换了计费账号，还会连带掐掉语音会话 |
| `credentials.request` 超时（5s） | 同「断线」：沿用现有值，记 warn |

**哪些槽变了要重建什么**：`dashscope.apiKey` 变 → 续一次 Realtime 会话
（`RealtimeClient` 已有 `renewSession`，代价是一轮）；`cloudflare.*` 变 →
重建 CF provider（无状态，无代价）；`huggingface.token` 变 → 不影响已加载的本地模型。
**只对真正变了的槽做这件事** —— core 侧 `CredentialResolver.applyFromApp()`
返回的就是这个列表。

### 8.6 已知缺口

- **同 uid 的假 core 能骗到凭据。** app 验 core 只有 `lstat`（属主 / 0600 / 0700 /
  非符号链接），同 uid 的进程可以 unlink 掉真 socket 再 bind 一个一模一样的
  —— decisions.md 里已经实测演示过这条，用它骗出过剪贴板全文。现在它能多骗到凭据。
  **这不是新增的攻击面**：同一个攻击者本来就能直接读 0600 的 `.env`。
  真正终结它的是代码签名档的对端校验（`SecCodeCopyGuestWithAttributes`），
  卡在还没有 Apple Developer Team ID，`PeerIdentity.auditToken` 已经在采集了。
- **`.env` 仍是明文文件。** 保留它是用户明确要求，也是无界面路径的唯一配置来源。
  它的权限不由本协议保证。
- **额度数字未必拿得到**（§3.9），`quota` 全字段可选就是为此。
