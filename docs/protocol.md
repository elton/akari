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
