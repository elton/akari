/**
 * Provider contract for the three inference paths of ADR-009.
 *
 * ADR-009 splits inference into paths that are switched independently:
 *
 *   voice  -> DashScope `qwen3.5-omni-flash-realtime` (end-to-end Realtime)
 *   text   -> the user's own Cloudflare Workers AI, or local MLX
 *
 * Note what is NOT here: there is no `VoiceProvider`. ADR-004 put voice on an
 * end-to-end Realtime session and `RealtimeClient` is its only implementation,
 * so wrapping it in an interface would be an abstraction over one thing. The
 * voice path still appears in the settings protocol (docs/protocol.md §3.9) so
 * the UI can show its health — that is a wire concern, not a TypeScript one.
 *
 * `ASRProvider` / `TTSProvider` were declared here before this file was
 * rewritten and had zero implementations and zero callers: ADR-004 replaced the
 * assembled ASR+LLM+TTS path with Realtime. They come back the day the
 * assembled path does, not before.
 */

// ---------------------------------------------------------------------------
// Conversation
// ---------------------------------------------------------------------------

/**
 * One image handed to a vision-capable provider.
 *
 * Deliberately not a path and not a `data:` URL: every provider would then have
 * to do its own file IO and MIME sniffing, and the two of them want different
 * encodings on the wire (Cloudflare takes a byte array, OpenAI-compatible
 * endpoints take a `data:` URL). Whoever captures the screenshot does the
 * reading once, here.
 */
export interface ImageInput {
  /** IANA media type, e.g. `"image/png"`. */
  mediaType: string;
  /** Base64 of the raw bytes. No `data:` prefix, no newlines. */
  base64: string;
}

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  /** Attached images. Providers without `capabilities.vision` must reject these. */
  images?: ImageInput[];
  /** Set on role "tool" to answer a specific call. */
  toolCallId?: string;
  /**
   * Content that came from outside the user (screenshots, page text, file
   * contents). Any state-changing tool call made after reading untrusted
   * content is forced through the confirmation gate (spec.md §4.4).
   */
  untrusted?: boolean;
}

export interface ToolSchema {
  name: string;
  description: string;
  /** JSON Schema for the arguments object. */
  parameters: Record<string, unknown>;
}

export interface ChatRequest {
  messages: ChatMessage[];
  tools?: ToolSchema[];
  temperature?: number;
  maxTokens?: number;
  signal?: AbortSignal;
}

export interface ChatChunk {
  /** Incremental assistant text. */
  text?: string;
  toolCall?: { callId: string; name: string; arguments: Record<string, unknown> };
  /** Set on the last chunk of the turn. */
  done?: boolean;
  /** Present on the last chunk when the provider reports usage. */
  usage?: { promptTokens?: number; completionTokens?: number };
}

// ---------------------------------------------------------------------------
// Capabilities, health, quota
// ---------------------------------------------------------------------------

/**
 * What an implementation can actually do. Declared per instance rather than per
 * class because it depends on the configured model: the same Cloudflare
 * provider pointed at a text-only model has `vision: false`.
 *
 * Callers must read this instead of branching on `id` — that is the whole point
 * of having it.
 */
export interface ProviderCapabilities {
  /** Accepts `ChatMessage.images`. */
  vision: boolean;
  /** Accepts `ChatRequest.tools` and can emit `ChatChunk.toolCall`. */
  tools: boolean;
  /** Streams partial text. False means `chat()` yields one chunk at the end. */
  streaming: boolean;
  /** Context window in tokens, prompt + completion. */
  contextTokens: number;
  /** Cap on generated tokens, when the provider imposes one. */
  maxOutputTokens?: number;
  /** True when inference happens on this machine — drives the privacy badge. */
  local: boolean;
}

/**
 * Why a provider is or is not usable. One value per distinct thing the settings
 * UI has to tell the user to do about it.
 */
export type ProviderStatus =
  /** Probed and working. */
  | "ok"
  /** A required credential slot is empty. See `ProviderProbe.missing`. */
  | "unconfigured"
  /** Credentials present but rejected (401/403). A Cloudflare token with only
   *  Workers AI *Read* lands here: it can list models and 403s on inference. */
  | "unauthorized"
  /** Rate limited or out of budget (429, neuron allowance spent). */
  | "quota_exhausted"
  /** Network, DNS or timeout — nothing answered. */
  | "unreachable"
  /** Endpoint answered but the model id is not available (404), or local
   *  weights are absent. */
  | "model_missing"
  /** Local runtime is loading weights; retry shortly. */
  | "starting"
  /** Anything else. `message` says what. */
  | "error"
  /** Never probed. Only valid before the first `probe()` returns. */
  | "unknown";

/**
 * Remaining allowance, when the provider can report one.
 *
 * Every field is optional on purpose. Cloudflare bills Workers AI in "neurons"
 * and exposes the counter through dashboard analytics, not through the
 * inference endpoint — **whether a usable quota endpoint exists has not been
 * verified**. A provider that cannot get numbers returns `{ unit, note }` and
 * the UI shows the note.
 */
export interface QuotaSnapshot {
  /** Unit the numbers are in, e.g. `"neurons"`, `"tokens"`, `"requests"`. */
  unit: string;
  used?: number;
  limit?: number;
  remaining?: number;
  /** Unix epoch ms when the allowance resets. */
  resetsAt?: number;
  /** Shown when the numbers are unavailable. Chinese, one line, no credentials. */
  note?: string;
}

/** Result of `TextProvider.probe()` — what "测试连接" in the settings UI shows. */
export interface ProviderProbe {
  status: ProviderStatus;
  /** Convenience for `status === "ok"`. */
  ok: boolean;
  /**
   * One line for the user. Chinese. **Never contains a credential**, and never
   * the raw body of an upstream error that might echo one back.
   */
  message?: string;
  /** Credential slots that are empty; set when `status === "unconfigured"`. */
  missing?: CredentialSlot[];
  /** Model the probe actually exercised. */
  model?: string;
  /** Round trip of the probe request. */
  latencyMs?: number;
  quota?: QuotaSnapshot;
  /** Unix epoch ms. */
  checkedAt: number;
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/** Stable ids. These go on the wire (docs/protocol.md §3.9). */
export const TEXT_PROVIDER_IDS = ["cloudflare-workers-ai", "local-mlx"] as const;
export type TextProviderId = (typeof TEXT_PROVIDER_IDS)[number];

/** Stable id of the one voice implementation. On the wire, not a TS interface. */
export const VOICE_PROVIDER_ID = "dashscope-realtime";

/**
 * Text conversation, with images and tool calling. Implemented by
 * `./cloudflare.ts` and `./local.ts`.
 */
export interface TextProvider {
  readonly id: TextProviderId;
  /** Model this instance is configured for, e.g. `"@cf/qwen/qwen3.8-27b"`. */
  readonly model: string;
  readonly capabilities: ProviderCapabilities;

  /**
   * Stream a reply.
   *
   * Must throw `ProviderError` — never a bare `Error` — so the router can tell
   * "this provider is down, fall through to the next one" from "the request was
   * malformed". Honours `request.signal`: a barge-in aborts mid-stream.
   */
  chat(request: ChatRequest): AsyncIterable<ChatChunk>;

  /**
   * Cheapest call that proves the whole path works: credentials, endpoint,
   * model id. Never throws — a failure is a `ProviderProbe` with a status.
   */
  probe(signal?: AbortSignal): Promise<ProviderProbe>;

  /** Release sockets / stop a local runtime. Idempotent. */
  close?(): Promise<void>;
}

/**
 * Failure from a provider, carrying the same status vocabulary as `probe()` so
 * the router can decide about falling back without parsing messages.
 */
export class ProviderError extends Error {
  constructor(
    readonly provider: string,
    readonly status: ProviderStatus,
    message: string,
    cause?: unknown,
  ) {
    super(message, { cause });
    this.name = "ProviderError";
  }

  /** True when trying the next provider in the route is worth it. */
  get retryable(): boolean {
    return (
      this.status === "unreachable" ||
      this.status === "quota_exhausted" ||
      this.status === "starting"
    );
  }
}

// ---------------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------------

/**
 * Every credential the core can be given, by stable id.
 *
 * These ids are the wire values in `credentials.*` (docs/protocol.md §3.10) AND
 * the `kSecAttrAccount` of the app's Keychain items. One name, three places.
 */
export const CREDENTIAL_SLOTS = [
  "dashscope.apiKey",
  "cloudflare.accountId",
  "cloudflare.apiToken",
  "huggingface.token",
] as const;
export type CredentialSlot = (typeof CREDENTIAL_SLOTS)[number];

/** Where a resolved value came from. Reported per slot in `settings.state`. */
export type CredentialSource =
  /** The app's Keychain, delivered over the socket. */
  | "app"
  /** Process environment, which includes `.env` (docs/protocol.md §八). */
  | "env"
  /** Nothing anywhere. */
  | "unset";

/** One resolved slot. `value` is present only when `source !== "unset"`. */
export interface ResolvedCredential {
  slot: CredentialSlot;
  source: CredentialSource;
  /** **Never log this, never put it in an error, never send it anywhere.** */
  value?: string;
  /** Short non-reversible id of `value`, safe to log and to show. */
  fingerprint?: string;
  /** True when the app explicitly cleared the slot, suppressing the `.env`
   *  fallback. See docs/protocol.md §八. */
  cleared?: boolean;
}

/** Read side of the resolver in `../credentials.ts`. */
export interface CredentialStore {
  get(slot: CredentialSlot): ResolvedCredential;
  /** Value only, for the common case. `undefined` when the slot is unset. */
  value(slot: CredentialSlot): string | undefined;
}
