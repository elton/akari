import Foundation

// Swift mirror of the wire contract defined in docs/protocol.md.
// docs/protocol.md is authoritative: change it first, then both mirrors
// (this file and core/src/protocol.ts) in the same commit.

public enum ProtocolConstants {
    /// Bumped on any breaking change to the frame layout or message set.
    public static let version = 1

    /// 4-byte big-endian length + 1-byte frame type.
    public static let lengthPrefixBytes = 4
    public static let typeByteBytes = 1

    /// Largest accepted value of the length prefix. Anything larger is a
    /// desynchronised stream: close the connection, do not try to resync.
    public static let maxFrameBytes = 4 * 1024 * 1024

    /// Unix domain socket the core listens on. `AKARI_SOCKET` overrides it.
    public static var defaultSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["AKARI_SOCKET"],
           !override.isEmpty {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appending(path: "akari/core.sock").path(percentEncoded: false)
    }
}

// MARK: - Frames

public enum WireFrameType: UInt8, Sendable {
    /// UTF-8 JSON control message. Payload is a `ControlMessage`.
    case control = 0x01
    /// Microphone PCM, app -> core. Payload is an `AudioFrame`.
    case audioUplink = 0x02
    /// Speaker PCM, core -> app. Payload is an `AudioFrame`.
    case audioDownlink = 0x03
}

/// Audio frame payload: 4-byte BE stream id, 4-byte BE sequence, then raw
/// interleaved PCM16 little-endian samples. No base64, no JSON.
public struct AudioFrame: Sendable, Equatable {
    public var streamID: UInt32
    public var sequence: UInt32
    public var pcm: Data

    public init(streamID: UInt32, sequence: UInt32, pcm: Data) {
        self.streamID = streamID
        self.sequence = sequence
        self.pcm = pcm
    }

    public static let headerBytes = 8

    /// Serialise header + samples: two big-endian UInt32 fields, then the PCM
    /// exactly as captured. The samples stay little-endian — that mismatch is
    /// deliberate (protocol.md §二).
    ///
    /// The hot send path in CoreBridge writes the header and the PCM as two
    /// separate socket writes so the samples are never copied; this is the
    /// single-buffer form, for tests and for callers that want one `Data`.
    public func encodePayload() -> Data {
        var out = Data(capacity: Self.headerBytes + pcm.count)
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: streamID >> UInt32(shift)))
        }
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: sequence >> UInt32(shift)))
        }
        out.append(pcm)
        return out
    }

    /// Parse a frame payload; returns nil when shorter than the 8-byte header.
    public static func decodePayload(_ payload: Data) -> AudioFrame? {
        guard payload.count >= headerBytes else { return nil }
        let base = payload.startIndex
        func be32(_ offset: Int) -> UInt32 {
            (UInt32(payload[base + offset]) << 24)
                | (UInt32(payload[base + offset + 1]) << 16)
                | (UInt32(payload[base + offset + 2]) << 8)
                | UInt32(payload[base + offset + 3])
        }
        // Rebased copy: consumers index the PCM from zero, and a `Data` slice
        // keeps its parent's indices.
        return AudioFrame(streamID: be32(0),
                          sequence: be32(4),
                          pcm: Data(payload[(base + headerBytes)...]))
    }
}

// MARK: - Enumerations

public enum AvatarState: String, Codable, CaseIterable, Sendable {
    case idle, listening, thinking, talking, greeting
}

/// ADR-002 four-level risk model. `never` never reaches the app; it exists so
/// both sides can round-trip the value without a decoding failure.
public enum RiskLevel: String, Codable, Sendable {
    case green, yellow, red, never
}

public enum ConfirmDecision: String, Codable, Sendable {
    case approve, deny, timeout
}

public enum PttSource: String, Codable, Sendable {
    case hotkey, click, menu
}

public enum LogLevel: String, Codable, Sendable {
    case debug, info, warn, error
}

/// PCM description. Negotiated at connect time via `core.ready` rather than
/// hardcoded on both sides — the core owns the realtime session and therefore
/// owns the sample rates.
public struct AudioFormat: Codable, Sendable, Equatable {
    /// Samples per second, e.g. 16000 uplink / 24000 downlink.
    public var sampleRate: Int
    /// 1 = mono.
    public var channels: Int
    /// Always "pcm16le" in protocol version 1.
    public var encoding: String
    /// Milliseconds of audio per frame, e.g. 20.
    public var frameMillis: Int

    public init(sampleRate: Int, channels: Int, encoding: String = "pcm16le", frameMillis: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.encoding = encoding
        self.frameMillis = frameMillis
    }

    /// Bytes of PCM in one frame at this format.
    public var bytesPerFrame: Int {
        sampleRate * channels * 2 * frameMillis / 1000
    }
}

// MARK: - Payloads

public struct AppHelloPayload: Codable, Sendable {
    public var protocolVersion: Int
    public var appVersion: String
    public var appBuild: String
}

public struct CoreReadyPayload: Codable, Sendable {
    public var protocolVersion: Int
    public var coreVersion: String
    public var uplink: AudioFormat
    public var downlink: AudioFormat
}

public struct AvatarSetStatePayload: Codable, Sendable {
    public var state: AvatarState
    /// Cross-fade duration; nil means the app's default (~120ms).
    public var transitionMs: Int?
}

public struct PttPayload: Codable, Sendable {
    public var source: PttSource
}

public struct AudioBeginPayload: Codable, Sendable {
    public var streamId: UInt32
    /// Overrides the format announced in `core.ready` for this stream only.
    public var format: AudioFormat?
}

public struct AudioEndPayload: Codable, Sendable {
    public var streamId: UInt32
}

public struct AudioCancelPayload: Codable, Sendable {
    /// nil cancels every in-flight playback stream.
    public var streamId: UInt32?
}

public struct AudioDonePayload: Codable, Sendable {
    public var streamId: UInt32
}

public struct ToolConfirmRequestPayload: Codable, Sendable {
    public var requestId: String
    public var tool: String
    public var risk: RiskLevel
    /// One line, shown as the card title.
    public var title: String
    /// Optional longer explanation.
    public var detail: String?
    /// Verbatim command / file path / payload. RED cards must show it unedited.
    public var command: String?
    /// Auto-deny after this many ms. 0 = wait forever.
    public var timeoutMs: Int
}

public struct ToolConfirmResponsePayload: Codable, Sendable {
    public var requestId: String
    public var decision: ConfirmDecision
}

public struct ToolUndoablePayload: Codable, Sendable {
    public var requestId: String
    public var tool: String
    public var title: String
    /// Undo window in ms (1500 per ADR-002).
    public var undoMs: Int
}

public struct ToolUndoPayload: Codable, Sendable {
    public var requestId: String
}

public struct ClipboardReadRequestPayload: Codable, Sendable {
    public var requestId: String
    /// Truncate on this side; nil means hand over everything and let the core cap it.
    public var maxChars: Int?
}

public struct ClipboardReadResponsePayload: Codable, Sendable {
    public var requestId: String
    /// The pasteboard is marked `org.nspasteboard.ConcealedType` or
    /// `...TransientType`. `text` is then nil — the content is never read.
    public var concealed: Bool
    public var text: String?

    public init(requestId: String, concealed: Bool, text: String? = nil) {
        self.requestId = requestId
        self.concealed = concealed
        self.text = concealed ? nil : text
    }
}

public struct UiNoticePayload: Codable, Sendable {
    public var level: LogLevel
    /// One short line for the menu bar. Never carries credentials.
    public var text: String
}

public struct ErrorPayload: Codable, Sendable {
    public var code: String
    public var message: String
    /// true = the sender is closing the connection after this frame.
    public var fatal: Bool
}

public struct LogPayload: Codable, Sendable {
    public var level: LogLevel
    public var message: String
}


// MARK: - Settings and credentials (ADR-009, docs/protocol.md §3.9 / §3.10)

/// Well-known route ids. Plain strings rather than an enum on purpose: see
/// `ProviderID`.
public enum SettingsRoute {
    public static let voice = "voice"
    public static let text = "text"
}

/// Well-known provider ids.
///
/// These are `String`, not a `Codable` enum, and so are `status`, `slot`,
/// `source` and `state` below. A `Codable` enum throws on a raw value it has
/// never heard of, which would turn "the core learned about a new provider"
/// into "the settings window fails to decode and shows nothing" — the exact
/// failure protocol.md §三 forbids by making unknown message types a no-op.
/// Unknown values here render as an unavailable row instead.
public enum ProviderID {
    public static let dashscopeRealtime = "dashscope-realtime"
    public static let cloudflareWorkersAI = "cloudflare-workers-ai"
    public static let localMLX = "local-mlx"
    /// `selected` value meaning "core decides"; never an `active` value.
    public static let auto = "auto"
}

/// Well-known credential slot ids. Also the `kSecAttrAccount` of the Keychain
/// item that holds each one (docs/protocol.md §八).
public enum CredentialSlotID {
    public static let dashscopeAPIKey = "dashscope.apiKey"
    public static let cloudflareAccountID = "cloudflare.accountId"
    public static let cloudflareAPIToken = "cloudflare.apiToken"
    public static let huggingFaceToken = "huggingface.token"

    public static let all = [
        dashscopeAPIKey, cloudflareAccountID, cloudflareAPIToken, huggingFaceToken,
    ]
}

public struct ProviderCapabilitiesPayload: Codable, Sendable, Equatable {
    /// Accepts image input — this is what decides whether "看一下我的屏幕" works.
    public var vision: Bool
    public var tools: Bool
    public var streaming: Bool
    /// Context window in tokens, prompt + completion.
    public var contextTokens: Int
    public var maxOutputTokens: Int?
    /// Inference happens on this machine; drives the privacy badge.
    public var local: Bool

    public init(vision: Bool, tools: Bool, streaming: Bool,
                contextTokens: Int, maxOutputTokens: Int? = nil, local: Bool) {
        self.vision = vision
        self.tools = tools
        self.streaming = streaming
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.local = local
    }
}

/// Remaining allowance. Every field is optional: a provider that cannot get
/// numbers sends `unit` and `note`, and the UI shows the note.
public struct QuotaSnapshotPayload: Codable, Sendable, Equatable {
    public var unit: String
    public var used: Double?
    public var limit: Double?
    public var remaining: Double?
    /// Unix epoch milliseconds when the allowance resets.
    public var resetsAt: Int64?
    public var note: String?

    public init(unit: String, used: Double? = nil, limit: Double? = nil,
                remaining: Double? = nil, resetsAt: Int64? = nil, note: String? = nil) {
        self.unit = unit
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.note = note
    }
}

public struct ProviderHealthPayload: Codable, Sendable, Equatable {
    public var provider: String
    /// `ok` | `unconfigured` | `unauthorized` | `quota_exhausted` |
    /// `unreachable` | `model_missing` | `starting` | `error` | `unknown`.
    public var status: String
    /// One line for the user. Never carries a credential.
    public var message: String?
    /// Credential slots that are empty; set when `status == "unconfigured"`.
    public var missing: [String]?
    public var model: String?
    public var capabilities: ProviderCapabilitiesPayload?
    public var quota: QuotaSnapshotPayload?
    public var latencyMs: Int?
    /// Unix epoch ms of the last probe; 0 when never probed.
    public var checkedAt: Int64

    public var isOK: Bool { status == "ok" }

    public init(provider: String, status: String, message: String? = nil,
                missing: [String]? = nil, model: String? = nil,
                capabilities: ProviderCapabilitiesPayload? = nil,
                quota: QuotaSnapshotPayload? = nil, latencyMs: Int? = nil,
                checkedAt: Int64) {
        self.provider = provider
        self.status = status
        self.message = message
        self.missing = missing
        self.model = model
        self.capabilities = capabilities
        self.quota = quota
        self.latencyMs = latencyMs
        self.checkedAt = checkedAt
    }
}

public struct RouteStatePayload: Codable, Sendable, Equatable {
    public var route: String
    /// A provider id, or `ProviderID.auto`.
    public var selected: String
    /// What is serving right now; nil when nothing on this route works.
    public var active: String?
    /// Every provider that could serve this route, in fallback order.
    public var candidates: [ProviderHealthPayload]

    public init(route: String, selected: String, active: String?,
                candidates: [ProviderHealthPayload]) {
        self.route = route
        self.selected = selected
        self.active = active
        self.candidates = candidates
    }
}

/// One credential slot, without the credential.
public struct CredentialSlotStatePayload: Codable, Sendable, Equatable {
    public var slot: String
    /// `app` | `env` | `unset`.
    public var source: String
    public var present: Bool
    /// First 8 hex of SHA-256 of the value: lets both sides compare what they
    /// hold without either of them sending it.
    public var fingerprint: String?
    /// Cleared in settings; the `.env` fallback is suppressed for this slot.
    public var cleared: Bool?
    /// The app could not read the Keychain.
    public var denied: Bool?
    /// Variable the `env` fallback reads, so the UI can name it.
    public var envVar: String

    public init(slot: String, source: String, present: Bool,
                fingerprint: String? = nil, cleared: Bool? = nil,
                denied: Bool? = nil, envVar: String) {
        self.slot = slot
        self.source = source
        self.present = present
        self.fingerprint = fingerprint
        self.cleared = cleared
        self.denied = denied
        self.envVar = envVar
    }
}

public struct EnvFileStatePayload: Codable, Sendable, Equatable {
    public var path: String
    public var loaded: Bool

    public init(path: String, loaded: Bool) {
        self.path = path
        self.loaded = loaded
    }
}

public struct SettingsStatePayload: Codable, Sendable, Equatable {
    public var routes: [RouteStatePayload]
    public var credentials: [CredentialSlotStatePayload]
    /// Where the core looked for a `.env`, in the order it looked.
    public var envFiles: [EnvFileStatePayload]

    public init(routes: [RouteStatePayload],
                credentials: [CredentialSlotStatePayload],
                envFiles: [EnvFileStatePayload]) {
        self.routes = routes
        self.credentials = credentials
        self.envFiles = envFiles
    }
}

public struct SettingsSetPayload: Codable, Sendable, Equatable {
    public var route: String
    /// A provider id, or `ProviderID.auto`.
    public var provider: String

    public init(route: String, provider: String) {
        self.route = route
        self.provider = provider
    }
}

public struct SettingsProbePayload: Codable, Sendable, Equatable {
    public var route: String
    /// nil probes every candidate on the route.
    public var provider: String?
    /// Give up after this long. Core default 10000; 0 is not allowed.
    public var timeoutMs: Int?

    public init(route: String, provider: String? = nil, timeoutMs: Int? = nil) {
        self.route = route
        self.provider = provider
        self.timeoutMs = timeoutMs
    }
}

public struct SettingsProbeResultPayload: Codable, Sendable, Equatable {
    public var route: String
    public var results: [ProviderHealthPayload]

    public init(route: String, results: [ProviderHealthPayload]) {
        self.route = route
        self.results = results
    }
}

/// The Keychain changed. Slot ids only — the values follow, and only because
/// the core asks for them (docs/protocol.md §3.10).
public struct CredentialsUpdatedPayload: Codable, Sendable, Equatable {
    public var slots: [String]

    public init(slots: [String]) {
        self.slots = slots
    }
}

public struct CredentialsRequestPayload: Codable, Sendable, Equatable {
    public var requestId: String
    public var slots: [String]

    public init(requestId: String, slots: [String]) {
        self.requestId = requestId
        self.slots = slots
    }
}

/// What the Keychain holds for one slot.
///
/// `cleared` and `unset` are different answers and the difference is
/// load-bearing: `cleared` means the user deleted it here and the core must
/// **not** fall back to `.env`; `unset` means it was never configured here and
/// the fallback applies. `denied` is a locked Keychain — it falls back like
/// `unset` so a locked Keychain cannot take voice down, and is reported
/// separately so the UI can explain the empty field.
public struct CredentialValuePayload: Codable, Sendable, CustomStringConvertible,
                                      CustomDebugStringConvertible {
    public var slot: String
    /// `set` | `cleared` | `unset` | `denied`.
    public var state: String
    /// Present only when `state == "set"`.
    ///
    /// This is the one secret-bearing field in the whole protocol. It is never
    /// logged, never shown, never put in an error — which is why this type
    /// prints itself without it.
    public var value: String?

    public init(slot: String, state: String, value: String? = nil) {
        self.slot = slot
        self.state = state
        self.value = state == "set" ? value : nil
    }

    public var description: String { "CredentialValue(\(slot), \(state))" }
    public var debugDescription: String { description }
}

public struct CredentialsProvidePayload: Codable, Sendable, CustomStringConvertible,
                                         CustomDebugStringConvertible {
    public var requestId: String
    /// Answers only the slots the request named.
    public var values: [CredentialValuePayload]

    public init(requestId: String, values: [CredentialValuePayload]) {
        self.requestId = requestId
        self.values = values
    }

    public var description: String {
        "CredentialsProvide(\(requestId), \(values.map(\.description).joined(separator: ", ")))"
    }
    public var debugDescription: String { description }
}

// MARK: - Control messages

public enum MessageType: String, Codable, Sendable {
    case appHello = "app.hello"
    case coreReady = "core.ready"
    case avatarSetState = "avatar.setState"
    case pttDown = "ptt.down"
    case pttUp = "ptt.up"
    case audioBegin = "audio.begin"
    case audioEnd = "audio.end"
    case audioCancel = "audio.cancel"
    case audioDone = "audio.done"
    case toolConfirmRequest = "tool.confirm.request"
    case toolConfirmResponse = "tool.confirm.response"
    case toolUndoable = "tool.undoable"
    case toolUndo = "tool.undo"
    case clipboardReadRequest = "clipboard.read.request"
    case clipboardReadResponse = "clipboard.read.response"
    case uiNotice = "ui.notice"
    case settingsGet = "settings.get"
    case settingsState = "settings.state"
    case settingsSet = "settings.set"
    case settingsProbe = "settings.probe"
    case settingsProbeResult = "settings.probeResult"
    case credentialsUpdated = "credentials.updated"
    case credentialsRequest = "credentials.request"
    case credentialsProvide = "credentials.provide"
    case appQuit = "app.quit"
    case ping
    case pong
    case error
    case log
}

public enum ControlBody: Sendable {
    case appHello(AppHelloPayload)
    case coreReady(CoreReadyPayload)
    case avatarSetState(AvatarSetStatePayload)
    case pttDown(PttPayload)
    case pttUp(PttPayload)
    case audioBegin(AudioBeginPayload)
    case audioEnd(AudioEndPayload)
    case audioCancel(AudioCancelPayload)
    case audioDone(AudioDonePayload)
    case toolConfirmRequest(ToolConfirmRequestPayload)
    case toolConfirmResponse(ToolConfirmResponsePayload)
    case toolUndoable(ToolUndoablePayload)
    case toolUndo(ToolUndoPayload)
    case clipboardReadRequest(ClipboardReadRequestPayload)
    case clipboardReadResponse(ClipboardReadResponsePayload)
    case uiNotice(UiNoticePayload)
    case settingsGet
    case settingsState(SettingsStatePayload)
    case settingsSet(SettingsSetPayload)
    case settingsProbe(SettingsProbePayload)
    case settingsProbeResult(SettingsProbeResultPayload)
    case credentialsUpdated(CredentialsUpdatedPayload)
    case credentialsRequest(CredentialsRequestPayload)
    case credentialsProvide(CredentialsProvidePayload)
    case appQuit
    case ping
    case pong
    case error(ErrorPayload)
    case log(LogPayload)

    public var type: MessageType {
        switch self {
        case .appHello: .appHello
        case .coreReady: .coreReady
        case .avatarSetState: .avatarSetState
        case .pttDown: .pttDown
        case .pttUp: .pttUp
        case .audioBegin: .audioBegin
        case .audioEnd: .audioEnd
        case .audioCancel: .audioCancel
        case .audioDone: .audioDone
        case .toolConfirmRequest: .toolConfirmRequest
        case .toolConfirmResponse: .toolConfirmResponse
        case .toolUndoable: .toolUndoable
        case .toolUndo: .toolUndo
        case .clipboardReadRequest: .clipboardReadRequest
        case .clipboardReadResponse: .clipboardReadResponse
        case .uiNotice: .uiNotice
        case .settingsGet: .settingsGet
        case .settingsState: .settingsState
        case .settingsSet: .settingsSet
        case .settingsProbe: .settingsProbe
        case .settingsProbeResult: .settingsProbeResult
        case .credentialsUpdated: .credentialsUpdated
        case .credentialsRequest: .credentialsRequest
        case .credentialsProvide: .credentialsProvide
        case .appQuit: .appQuit
        case .ping: .ping
        case .pong: .pong
        case .error: .error
        case .log: .log
        }
    }
}

/// Envelope: `{ "v", "id", "ts", "replyTo"?, "type", "payload"? }`.
public struct ControlMessage: Codable, Sendable {
    public var v: Int
    /// Unique per sender; correlates request/response pairs.
    public var id: String
    /// Unix epoch milliseconds at send time.
    public var ts: Int64
    /// Set on a message that answers another message's `id`.
    public var replyTo: String?
    public var body: ControlBody

    public init(body: ControlBody,
                id: String = UUID().uuidString,
                replyTo: String? = nil,
                ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                v: Int = ProtocolConstants.version) {
        self.v = v
        self.id = id
        self.ts = ts
        self.replyTo = replyTo
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case v, id, ts, replyTo, type, payload
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        ts = try c.decode(Int64.self, forKey: .ts)
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)

        func payload<T: Decodable>(_ type: T.Type) throws -> T {
            try c.decode(T.self, forKey: .payload)
        }

        switch try c.decode(MessageType.self, forKey: .type) {
        case .appHello: body = .appHello(try payload(AppHelloPayload.self))
        case .coreReady: body = .coreReady(try payload(CoreReadyPayload.self))
        case .avatarSetState: body = .avatarSetState(try payload(AvatarSetStatePayload.self))
        case .pttDown: body = .pttDown(try payload(PttPayload.self))
        case .pttUp: body = .pttUp(try payload(PttPayload.self))
        case .audioBegin: body = .audioBegin(try payload(AudioBeginPayload.self))
        case .audioEnd: body = .audioEnd(try payload(AudioEndPayload.self))
        case .audioCancel: body = .audioCancel(try payload(AudioCancelPayload.self))
        case .audioDone: body = .audioDone(try payload(AudioDonePayload.self))
        case .toolConfirmRequest: body = .toolConfirmRequest(try payload(ToolConfirmRequestPayload.self))
        case .toolConfirmResponse: body = .toolConfirmResponse(try payload(ToolConfirmResponsePayload.self))
        case .toolUndoable: body = .toolUndoable(try payload(ToolUndoablePayload.self))
        case .toolUndo: body = .toolUndo(try payload(ToolUndoPayload.self))
        case .clipboardReadRequest: body = .clipboardReadRequest(try payload(ClipboardReadRequestPayload.self))
        case .clipboardReadResponse: body = .clipboardReadResponse(try payload(ClipboardReadResponsePayload.self))
        case .uiNotice: body = .uiNotice(try payload(UiNoticePayload.self))
        case .settingsGet: body = .settingsGet
        case .settingsState: body = .settingsState(try payload(SettingsStatePayload.self))
        case .settingsSet: body = .settingsSet(try payload(SettingsSetPayload.self))
        case .settingsProbe: body = .settingsProbe(try payload(SettingsProbePayload.self))
        case .settingsProbeResult: body = .settingsProbeResult(try payload(SettingsProbeResultPayload.self))
        case .credentialsUpdated: body = .credentialsUpdated(try payload(CredentialsUpdatedPayload.self))
        case .credentialsRequest: body = .credentialsRequest(try payload(CredentialsRequestPayload.self))
        case .credentialsProvide: body = .credentialsProvide(try payload(CredentialsProvidePayload.self))
        case .appQuit: body = .appQuit
        case .ping: body = .ping
        case .pong: body = .pong
        case .error: body = .error(try payload(ErrorPayload.self))
        case .log: body = .log(try payload(LogPayload.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(ts, forKey: .ts)
        try c.encodeIfPresent(replyTo, forKey: .replyTo)
        try c.encode(body.type, forKey: .type)

        switch body {
        case .appHello(let p): try c.encode(p, forKey: .payload)
        case .coreReady(let p): try c.encode(p, forKey: .payload)
        case .avatarSetState(let p): try c.encode(p, forKey: .payload)
        case .pttDown(let p): try c.encode(p, forKey: .payload)
        case .pttUp(let p): try c.encode(p, forKey: .payload)
        case .audioBegin(let p): try c.encode(p, forKey: .payload)
        case .audioEnd(let p): try c.encode(p, forKey: .payload)
        case .audioCancel(let p): try c.encode(p, forKey: .payload)
        case .audioDone(let p): try c.encode(p, forKey: .payload)
        case .toolConfirmRequest(let p): try c.encode(p, forKey: .payload)
        case .toolConfirmResponse(let p): try c.encode(p, forKey: .payload)
        case .toolUndoable(let p): try c.encode(p, forKey: .payload)
        case .toolUndo(let p): try c.encode(p, forKey: .payload)
        case .clipboardReadRequest(let p): try c.encode(p, forKey: .payload)
        case .clipboardReadResponse(let p): try c.encode(p, forKey: .payload)
        case .uiNotice(let p): try c.encode(p, forKey: .payload)
        case .settingsState(let p): try c.encode(p, forKey: .payload)
        case .settingsSet(let p): try c.encode(p, forKey: .payload)
        case .settingsProbe(let p): try c.encode(p, forKey: .payload)
        case .settingsProbeResult(let p): try c.encode(p, forKey: .payload)
        case .credentialsUpdated(let p): try c.encode(p, forKey: .payload)
        case .credentialsRequest(let p): try c.encode(p, forKey: .payload)
        case .credentialsProvide(let p): try c.encode(p, forKey: .payload)
        case .settingsGet, .appQuit, .ping, .pong: break
        case .error(let p): try c.encode(p, forKey: .payload)
        case .log(let p): try c.encode(p, forKey: .payload)
        }
    }
}
