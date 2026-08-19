import {
  DEFAULT_DOWNLINK_FORMAT,
  DEFAULT_UPLINK_FORMAT,
  type AudioFormat,
} from "./protocol.ts";

/**
 * Qwen Realtime WebSocket client (ADR-004).
 *
 * Endpoint: wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=<model>
 * Auth:     Authorization: Bearer $DASHSCOPE_API_KEY
 *
 * Everything below was verified against the live service on 2026-08-19 rather
 * than taken from the docs. What the probes showed:
 *
 * - The event protocol IS OpenAI-Realtime shaped: `session.created`,
 *   `session.update(d)`, `input_audio_buffer.*`, `response.audio.delta`,
 *   `response.audio_transcript.delta`, `response.function_call_arguments.*`,
 *   `response.done`, `error`. (The tech survey's "incompatible with OpenAI"
 *   claim was an inference, and `docs/research/verification.json` already
 *   flagged it as unsupported. It is wrong.)
 * - Uplink is 16 kHz PCM16LE mono, downlink is 24 kHz PCM16LE mono. Settled by
 *   experiment: the reply audio was fed back to the ASR both as-is and after a
 *   24k->16k resample; only the resampled version transcribed correctly.
 *   That matches DEFAULT_UPLINK_FORMAT / DEFAULT_DOWNLINK_FORMAT.
 * - `session.created` reports
 *   `turn_detection: {type:"server_vad", ..., create_response:true,
 *   interrupt_response:true}`. The server does endpointing and barge-in, so
 *   this file implements NEITHER. A barge-in surfaces as `response.done` with
 *   `status:"cancelled"` and `status_details:{reason:"turn_detected"}` — that
 *   is the only thing we have to react to.
 * - `create_response:true` only fires on a VAD-detected end of speech. A manual
 *   `input_audio_buffer.commit` (what push-to-talk needs, ADR-005) commits the
 *   buffer and then NOTHING happens. `response.create` must follow it. Verified
 *   both ways: commit alone hung, commit + response.create answered in 409ms.
 * - Committing an empty buffer is a non-fatal `error` ("buffer too small, or
 *   have no audio"), so short/empty push-to-talk presses are filtered here.
 *
 * Known hard limits, all handled by renewSession(): 60 RPM, 120 minutes per
 * session, no context caching, audio context truncated at 80 turns / 480s.
 */

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

export const DEFAULT_REALTIME_ENDPOINT =
  "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime";
export const DEFAULT_REALTIME_MODEL = "qwen3.5-omni-flash-realtime";
/** Model that produces the transcript of what the user said. */
export const DEFAULT_TRANSCRIPTION_MODEL = "qwen3-asr-flash-realtime";
/** Server default voice for qwen3.5-omni. */
export const DEFAULT_VOICE = "Tina";

/** Documented server-side ceilings. We renew before reaching any of them. */
export const SERVER_LIMITS = {
  sessionMillis: 120 * 60_000,
  audioTurns: 80,
  audioSeconds: 480,
} as const;

export interface RealtimeLimits {
  /** Renew the session once it is this old. */
  maxSessionMillis: number;
  /** Renew after this many audio turns (user utterances + spoken replies). */
  maxAudioTurns: number;
  /** Renew after this much audio has passed through the session. */
  maxAudioSeconds: number;
}

/** ~90% of each server limit, leaving room for one in-flight turn. */
export const DEFAULT_LIMITS: RealtimeLimits = {
  maxSessionMillis: 110 * 60_000,
  maxAudioTurns: 70,
  maxAudioSeconds: 420,
};

/** 60 RPM means one connection attempt per second, sustained. */
const MIN_CONNECT_INTERVAL_MS = 1_000;
const INITIAL_RECONNECT_DELAY_MS = 500;
/**
 * Reconnection retries forever at this ceiling rather than giving up — a closed
 * lid or a wifi change must heal by itself. 5s is also inside the 60 RPM budget.
 */
const MAX_RECONNECT_DELAY_MS = 5_000;
const RECONNECT_JITTER = 0.2;
/** Handshake measured at 335-464ms; 15s is a dead endpoint, not a slow one. */
const CONNECT_TIMEOUT_MS = 15_000;
/** Below this the server rejects the commit outright. */
const MIN_COMMIT_MILLIS = 100;
/** How often to re-check the session budgets when nothing else is happening. */
const BUDGET_CHECK_INTERVAL_MS = 30_000;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/** One callable tool, in the shape `session.update` wants. */
export interface RealtimeTool {
  name: string;
  description: string;
  /** JSON Schema for the arguments object. */
  parameters: Record<string, unknown>;
}

export interface RealtimeConfig {
  /** Never logged, never put in an error message. */
  apiKey: string;
  model?: string;
  /** Base wss URL without `?model=`; the client appends it. */
  endpoint?: string;
  voice?: string;
  instructions?: string;
  uplink?: AudioFormat;
  downlink?: AudioFormat;
  tools?: RealtimeTool[];
  limits?: Partial<RealtimeLimits>;
}

export interface RealtimeToolCall {
  callId: string;
  name: string;
  /** Parsed arguments. Empty object if the model emitted invalid JSON. */
  arguments: Record<string, unknown>;
  /** Exactly what the model sent, for logging and confirmation cards. */
  argumentsRaw: string;
}

/** Why the session is being torn down and rebuilt. */
export type RenewReason =
  | "session_age"
  | "audio_turns"
  | "audio_seconds"
  | "reconnect";

export interface RealtimeResponseInfo {
  responseId: string;
  /** True when the reply carried audio (a tool-call-only reply does not). */
  hadAudio: boolean;
}

export interface RealtimeCancelInfo {
  responseId: string;
  /** `"turn_detected"` when the user talked over her. */
  reason: string;
}

/** Why a reply the server had started will never arrive. */
export interface RealtimeFailureInfo {
  responseId: string;
  /** Server-supplied reason, safe to show the user. */
  message: string;
  /** e.g. `"rate_limit_exceeded"`. */
  code?: string;
  /** True when some audio was already streamed and has to be discarded. */
  hadAudio: boolean;
}

/**
 * Why a push-to-talk release produced no turn at all.
 *
 * - `not_connected` — there is no live session, so nothing was even sent. The
 *   user needs to be told this is a connection problem, not thinking.
 * - `too_short` — the whole press carried less than the server's 100ms minimum,
 *   so the commit was filtered here instead of bouncing off the server. A press
 *   whose audio server VAD already committed mid-way is NOT this: that turn is
 *   under way, and this callback does not fire for it at all.
 */
export type TurnAbandonedReason = "not_connected" | "too_short";

export interface RealtimeTurnAbandonedInfo {
  reason: TurnAbandonedReason;
  /** How much microphone audio was buffered when the turn was dropped. */
  bufferedMillis: number;
}

export type RealtimeLogLevel = "debug" | "info" | "warn" | "error";

/** A non-fatal `error` event from the service. */
export class RealtimeApiError extends Error {
  constructor(
    message: string,
    readonly code?: string,
    readonly param?: string,
  ) {
    super(message);
    this.name = "RealtimeApiError";
  }
}

export interface RealtimeHandlers {
  /** Session negotiated; `serverVad` reflects what the server actually chose. */
  onSessionCreated?: (info: { sessionId: string; serverVad: boolean }) => void;
  /** Server VAD decided the user started speaking. */
  onSpeechStarted?: () => void;
  onSpeechStopped?: () => void;
  /**
   * Transcript of the user's utterance. `text` is CUMULATIVE, not a delta —
   * the partial event carries the whole utterance so far in a `stash` field
   * (verified: `text` is always empty and `stash` grows and gets revised).
   */
  onInputTranscript?: (text: string, final: boolean) => void;
  /** Transcript of the reply. Also cumulative; deltas are accumulated here. */
  onOutputTranscript?: (text: string, final: boolean) => void;
  /** One chunk of reply audio, PCM16LE at the downlink format. */
  onAudioDelta?: (pcm: Uint8Array) => void;
  /** The reply finished normally. Not called for a cancelled reply. */
  onResponseDone?: (info: RealtimeResponseInfo) => void;
  /**
   * The server cancelled the in-flight reply because the user interrupted.
   * Drop whatever is still queued for playback; no `onResponseDone` follows.
   */
  onResponseCancelled?: (info: RealtimeCancelInfo) => void;
  /**
   * The server gave up on the reply — rate limit, content filter, internal
   * error. Terminal for the turn: neither `onResponseDone` nor
   * `onResponseCancelled` follows, so this is the only chance to close the
   * playback stream and put the avatar back to idle. `onError` fires as well,
   * for the core log; this callback is the one that has to end the turn.
   *
   * With 60 RPM to share, a rejected reply is routine rather than exotic.
   */
  onResponseFailed?: (info: RealtimeFailureInfo) => void;
  /**
   * A push-to-talk release produced no turn: nothing was committed and no
   * response will ever come back. Whoever moved the avatar to `thinking` on
   * `ptt.up` has to move it back, and say why — a silent stall looks like a
   * hang, and "not connected" looks exactly like "still thinking".
   */
  onTurnAbandoned?: (info: RealtimeTurnAbandonedInfo) => void;
  /**
   * The model wants a tool run. Hand it to the tool registry and call
   * `sendToolResult(call.callId, ...)` — always, including on failure, or the
   * turn never completes.
   */
  onToolCall?: (call: RealtimeToolCall) => void;
  onError?: (error: Error) => void;
  /** The socket went away. `willReconnect` is false only after `close()`. */
  onDisconnected?: (info: { reason: string; willReconnect: boolean }) => void;
  /**
   * Asked just before a fresh session replaces the current one. Return a short
   * summary to carry across the boundary — it is appended to `instructions`,
   * because a new session starts with an empty conversation. Return undefined
   * to start clean.
   */
  onCarryOver?: (reason: RenewReason) => string | undefined;
  onSessionRenewed?: (info: { reason: RenewReason; sessionId: string }) => void;
  onLog?: (level: RealtimeLogLevel, message: string) => void;
}

/** The hosts that actually serve the Qwen Realtime API. */
export const ALLOWED_REALTIME_HOSTS: readonly string[] = [
  "dashscope-intl.aliyuncs.com",
  "dashscope.aliyuncs.com",
];

/** Set to `1` to dial an endpoint outside `ALLOWED_REALTIME_HOSTS`. */
export const ALLOW_CUSTOM_ENDPOINT_ENV = "AKARI_ALLOW_CUSTOM_ENDPOINT";

/**
 * Check an endpoint before the API key is ever sent to it.
 *
 * The key travels in an `Authorization` header rather than the URL, which keeps
 * it out of logs — but says nothing about *where* it goes. Anyone who can write
 * `.env` or the core's launch environment can repoint the socket and collect the
 * key on the next connect, and over `ws://` they would not even need to break
 * TLS to read it off the wire. So the destination is validated, not just the
 * logging around it.
 *
 * Throws on anything unusable; returns the endpoint unchanged when it is fine.
 */
export function assertUsableEndpoint(
  endpoint: string,
  env: Record<string, string | undefined> = process.env,
): string {
  let url: URL;
  try {
    url = new URL(endpoint);
  } catch {
    throw new Error(`realtime endpoint is not a URL: ${endpoint}`);
  }
  if (url.protocol !== "wss:") {
    throw new Error(
      `realtime endpoint must use wss: (got ${url.protocol}//) — the DashScope ` +
        "API key is sent to it as a bearer token, and ws: puts that token on the wire in cleartext",
    );
  }
  if (url.username || url.password) {
    throw new Error("realtime endpoint must not carry credentials in the URL");
  }
  if (url.search || url.hash) {
    // Also a plain bug: the client appends `?model=`, so a second `?` would
    // produce a malformed URL.
    throw new Error(
      "realtime endpoint must not carry a query string or fragment; the client appends ?model=",
    );
  }
  if (!ALLOWED_REALTIME_HOSTS.includes(url.hostname)) {
    if (env[ALLOW_CUSTOM_ENDPOINT_ENV] !== "1") {
      throw new Error(
        `realtime endpoint host "${url.hostname}" is not one of ${ALLOWED_REALTIME_HOSTS.join(", ")}; ` +
          `the DashScope API key would be sent there. Set ${ALLOW_CUSTOM_ENDPOINT_ENV}=1 if that is deliberate.`,
      );
    }
    // Deliberate, but loud: this is the shape of a stolen key, so it is printed
    // whatever AKARI_LOG_LEVEL says.
    console.warn(
      `!! akari: sending the DashScope API key to a non-default realtime host "${url.hostname}" ` +
        `(${ALLOW_CUSTOM_ENDPOINT_ENV}=1). Unset that variable unless you put the host there yourself.`,
    );
  }
  return endpoint;
}

/** Read the pieces of the config that live in the environment. */
export function configFromEnv(
  overrides: Partial<RealtimeConfig> = {},
): RealtimeConfig {
  const apiKey = process.env.DASHSCOPE_API_KEY;
  if (!apiKey) {
    throw new Error(
      "DASHSCOPE_API_KEY is not set (see .env.example; the value must never be logged)",
    );
  }
  // Validate what will actually be dialed, overrides included, so the check
  // cannot be stepped around by the spread below.
  const endpoint = assertUsableEndpoint(
    overrides.endpoint ??
      (process.env.DASHSCOPE_REALTIME_ENDPOINT || DEFAULT_REALTIME_ENDPOINT),
  );
  return {
    apiKey,
    model: process.env.QWEN_REALTIME_MODEL || DEFAULT_REALTIME_MODEL,
    endpoint,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

type ServerEvent = Record<string, unknown> & { type?: unknown };

export class RealtimeClient {
  private readonly config: Required<
    Omit<RealtimeConfig, "limits" | "tools" | "instructions">
  > & { instructions: string };
  private readonly limits: RealtimeLimits;
  private readonly handlers: RealtimeHandlers;

  private ws: WebSocket | null = null;
  private sessionId = "";
  private sessionReady = false;
  private tools: RealtimeTool[];

  /** Set by close(); stops every reconnect and renewal. */
  private shuttingDown = false;
  private reconnectAttempts = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private budgetTimer: ReturnType<typeof setInterval> | null = null;
  private lastConnectAt = 0;
  private renewing = false;
  /** A budget was blown mid-turn; renew as soon as the turn ends. */
  private renewPending: RenewReason | null = null;
  private carryOver: string | undefined;

  // Session budgets.
  private sessionStartedAt = 0;
  private audioTurns = 0;
  private audioSeconds = 0;

  // Turn state.
  private uplinkBytesSinceCommit = 0;
  /**
   * Bytes appended since the last `commitAudio()` — i.e. over the whole
   * push-to-talk press, not just since the last commit.
   *
   * `uplinkBytesSinceCommit` is zeroed by every `input_audio_buffer.committed`,
   * including the ones server VAD raises in the *middle* of a press when the
   * user pauses. Keeping a second, press-scoped counter is what tells "this
   * press said nothing" apart from "this press was already committed for us".
   */
  private uplinkBytesSincePress = 0;
  private activeResponseId: string | null = null;
  private responseHadAudio = false;
  private outputTranscript = "";
  /** responseId -> outstanding tool calls + whether the response has finished. */
  private toolBatches = new Map<
    string,
    { outstanding: Set<string>; responseDone: boolean }
  >();
  private callToResponse = new Map<string, string>();

  constructor(config: RealtimeConfig, handlers: RealtimeHandlers = {}) {
    this.config = {
      apiKey: config.apiKey,
      model: config.model ?? DEFAULT_REALTIME_MODEL,
      endpoint: config.endpoint ?? DEFAULT_REALTIME_ENDPOINT,
      voice: config.voice ?? DEFAULT_VOICE,
      instructions: config.instructions ?? "",
      uplink: config.uplink ?? DEFAULT_UPLINK_FORMAT,
      downlink: config.downlink ?? DEFAULT_DOWNLINK_FORMAT,
    };
    this.limits = { ...DEFAULT_LIMITS, ...config.limits };
    this.tools = config.tools ? [...config.tools] : [];
    this.handlers = handlers;
  }

  /** The negotiated downlink format, to announce in `core.ready`. */
  get downlinkFormat(): AudioFormat {
    return this.config.downlink;
  }

  get uplinkFormat(): AudioFormat {
    return this.config.uplink;
  }

  get connected(): boolean {
    return this.sessionReady && this.ws?.readyState === WebSocket.OPEN;
  }

  /** Open the socket and resolve once `session.update` has been acknowledged. */
  async connect(): Promise<void> {
    if (this.connected) return;
    this.shuttingDown = false;
    await this.openSocket();
    this.startBudgetTimer();
  }

  async close(): Promise<void> {
    this.shuttingDown = true;
    this.clearReconnectTimer();
    this.stopBudgetTimer();
    this.teardownSocket(1000, "client closing");
    this.sessionReady = false;
  }

  /**
   * Declare the callable tools. Safe before or after `connect()`; when the
   * session is live it is pushed immediately with a `session.update`.
   */
  setTools(tools: RealtimeTool[]): void {
    this.tools = [...tools];
    if (this.connected) this.sendSessionUpdate();
  }

  /** Append one microphone chunk (PCM16LE at the uplink format). */
  appendAudio(pcm: Uint8Array): void {
    if (pcm.byteLength === 0) return;
    if (!this.connected) {
      this.log("warn", "dropping mic audio: realtime session is not live");
      return;
    }
    this.uplinkBytesSinceCommit += pcm.byteLength;
    this.uplinkBytesSincePress += pcm.byteLength;
    this.send({
      type: "input_audio_buffer.append",
      audio: base64(pcm),
    });
  }

  /**
   * Commit the input buffer and ask for a reply. Sent on `ptt.up`.
   *
   * Both halves are required: with `turn_detection: server_vad` the server's
   * `create_response` only fires on a VAD-detected end of speech, so a manual
   * commit on its own produces no reply at all (verified). If server VAD got
   * there first the buffer is already empty and this is a no-op, which is also
   * how the double-response race is avoided.
   *
   * The early exits report `onTurnAbandoned` — but only the ones where no
   * response event will ever come back. The caller has already put the avatar
   * into `thinking` on `ptt.up`, so returning silently there is what leaves her
   * thinking forever; reporting on a turn that *is* under way is just as wrong,
   * see the `uplinkBytesSincePress` check below.
   */
  commitAudio(): void {
    const pending = this.uplinkBytesSinceCommit;
    const appendedThisPress = this.uplinkBytesSincePress;
    this.uplinkBytesSinceCommit = 0;
    this.uplinkBytesSincePress = 0;
    if (!this.connected) {
      this.log("warn", "ignoring commit: realtime session is not live");
      this.handlers.onTurnAbandoned?.({
        reason: "not_connected",
        bufferedMillis: this.bytesToMillis(pending),
      });
      return;
    }
    if (pending < this.minCommitBytes()) {
      // Two very different things end up here, and only one of them is a lost
      // turn. Pausing mid-sentence for longer than silence_duration_ms makes
      // server VAD commit and answer while the key is still held; the release
      // then sees only the handful of bytes recorded since that commit. The
      // press as a whole was not too short — its audio is already committed and
      // being answered — so abandoning it would pop "没听清" over a reply that
      // is on its way, and invite the user to press again and cut her off.
      // `appendedThisPress > pending` is exactly "a commit landed mid-press":
      // nothing else drains the buffer while the session is up.
      if (appendedThisPress > pending) {
        this.log(
          "debug",
          `ptt release after a mid-press commit: ${pending} bytes since it, not a new turn`,
        );
        this.afterTurn();
        return;
      }
      if (pending > 0) {
        this.log(
          "warn",
          `ignoring commit: only ${pending} bytes buffered, below the ${MIN_COMMIT_MILLIS}ms server minimum`,
        );
      }
      this.handlers.onTurnAbandoned?.({
        reason: "too_short",
        bufferedMillis: this.bytesToMillis(pending),
      });
      this.afterTurn();
      return;
    }
    this.send({ type: "input_audio_buffer.commit" });
    if (this.activeResponseId === null) {
      this.send({ type: "response.create" });
    }
  }

  /** Return a tool result to the model and let it continue the turn. */
  sendToolResult(callId: string, result: unknown): void {
    const responseId = this.callToResponse.get(callId);
    this.callToResponse.delete(callId);
    if (!this.connected) {
      this.log("warn", `dropping tool result for ${callId}: session is down`);
      return;
    }
    this.send({
      type: "conversation.item.create",
      item: {
        type: "function_call_output",
        call_id: callId,
        output: typeof result === "string" ? result : JSON.stringify(result),
      },
    });
    if (responseId) {
      const batch = this.toolBatches.get(responseId);
      batch?.outstanding.delete(callId);
      this.maybeContinueAfterTools(responseId);
    } else {
      // Unknown call id: still ask for the continuation rather than stall.
      if (this.activeResponseId === null) this.send({ type: "response.create" });
    }
  }

  /** Inject text as if the user had said it. */
  sendText(text: string): void {
    if (!this.connected) {
      this.log("warn", "dropping text input: session is down");
      return;
    }
    this.send({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text }],
      },
    });
    if (this.activeResponseId === null) this.send({ type: "response.create" });
  }

  // -------------------------------------------------------------------------
  // Socket lifecycle
  // -------------------------------------------------------------------------

  private async openSocket(): Promise<void> {
    const wait = MIN_CONNECT_INTERVAL_MS - (Date.now() - this.lastConnectAt);
    if (this.lastConnectAt !== 0 && wait > 0) await sleep(wait);
    this.lastConnectAt = Date.now();

    const url = `${this.config.endpoint}?model=${encodeURIComponent(this.config.model)}`;
    const startedAt = Date.now();

    await new Promise<void>((resolve, reject) => {
      let settled = false;
      let ws: WebSocket;
      try {
        // The key travels in a header, never in the URL, so it cannot leak
        // through a logged URL or an error message.
        ws = new WebSocket(url, {
          headers: { Authorization: `Bearer ${this.config.apiKey}` },
        });
      } catch (error) {
        reject(asError(error));
        return;
      }
      this.ws = ws;

      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        try {
          ws.close();
        } catch {
          /* already gone */
        }
        reject(new Error(`realtime handshake timed out after ${CONNECT_TIMEOUT_MS}ms`));
      }, CONNECT_TIMEOUT_MS);

      const settle = (error?: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (error) reject(error);
        else resolve();
      };

      ws.onopen = () => {
        this.log("debug", `realtime socket open in ${Date.now() - startedAt}ms`);
      };

      ws.onmessage = (event: MessageEvent) => {
        const data = event.data;
        if (typeof data !== "string") {
          this.log("warn", "ignoring non-text frame from realtime endpoint");
          return;
        }
        let parsed: ServerEvent;
        try {
          parsed = JSON.parse(data) as ServerEvent;
        } catch {
          this.log("warn", "ignoring unparsable realtime event");
          return;
        }
        // `session.updated` is the point where our voice, tools and turn
        // detection are actually in force, so that — not `session.created` —
        // is when connect() resolves.
        if (parsed.type === "session.updated") {
          this.sessionReady = true;
          this.sessionStartedAt = Date.now();
          this.audioTurns = 0;
          this.audioSeconds = 0;
          this.reconnectAttempts = 0;
          // Every budget just reset, so a renewal deferred by the old session
          // must not fire again on the first turn of this one.
          this.renewPending = null;
          settle();
        }
        this.handleEvent(parsed);
      };

      ws.onerror = () => {
        // The event carries no usable detail in Bun; the close event does.
        this.log("warn", "realtime socket reported an error");
      };

      ws.onclose = (event: CloseEvent) => {
        const reason = event.reason || `code ${event.code}`;
        settle(new Error(`realtime socket closed during handshake: ${reason}`));
        this.onSocketClosed(ws, reason);
      };
    });
  }

  private onSocketClosed(ws: WebSocket, reason: string): void {
    if (this.ws !== ws) return; // A superseded socket from a renewal.
    // Only a socket that had a working session gets an automatic reconnect. A
    // socket that died during the handshake — a bad key, a wrong endpoint — is
    // reported by rejecting openSocket() instead, so a permanently broken
    // credential does not turn into an endless retry loop nobody asked for.
    const wasReady = this.sessionReady;
    this.ws = null;
    this.sessionReady = false;
    this.uplinkBytesSinceCommit = 0;
    // Audio appended before the drop was never committed, so a release after a
    // reconnect must still count as a lost turn rather than a mid-press commit.
    this.uplinkBytesSincePress = 0;

    // Whatever she was saying is gone; tell the owner so the app stops playing.
    if (this.activeResponseId !== null) {
      const responseId = this.activeResponseId;
      this.resetTurnState();
      this.handlers.onResponseCancelled?.({ responseId, reason: "disconnected" });
    }
    this.toolBatches.clear();
    this.callToResponse.clear();

    const willReconnect = !this.shuttingDown && !this.renewing && wasReady;
    this.handlers.onDisconnected?.({ reason, willReconnect });
    if (willReconnect) this.scheduleReconnect(reason);
  }

  private scheduleReconnect(reason: string): void {
    if (this.reconnectTimer) return;
    this.reconnectAttempts += 1;
    const base = Math.min(
      INITIAL_RECONNECT_DELAY_MS * 2 ** (this.reconnectAttempts - 1),
      MAX_RECONNECT_DELAY_MS,
    );
    const delay = Math.round(base * (1 + (Math.random() * 2 - 1) * RECONNECT_JITTER));
    this.log(
      "warn",
      `realtime disconnected (${reason}); reconnect attempt ${this.reconnectAttempts} in ${delay}ms`,
    );
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (this.shuttingDown) return;
      // A reconnect always loses the conversation, so it goes through the same
      // carry-over hook as a planned renewal.
      this.carryOver = this.handlers.onCarryOver?.("reconnect");
      void this.openSocket().then(
        () => {
          this.handlers.onSessionRenewed?.({
            reason: "reconnect",
            sessionId: this.sessionId,
          });
        },
        (error: unknown) => {
          this.handlers.onError?.(asError(error));
          if (!this.shuttingDown) this.scheduleReconnect(String(asError(error).message));
        },
      );
    }, delay);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private teardownSocket(code: number, reason: string): void {
    const ws = this.ws;
    if (!ws) return;
    this.ws = null;
    ws.onmessage = null;
    ws.onclose = null;
    ws.onerror = null;
    ws.onopen = null;
    try {
      ws.close(code, reason);
    } catch {
      /* already closing */
    }
  }

  // -------------------------------------------------------------------------
  // Session renewal
  // -------------------------------------------------------------------------

  private startBudgetTimer(): void {
    if (this.budgetTimer) return;
    this.budgetTimer = setInterval(
      () => this.maybeRenew(),
      BUDGET_CHECK_INTERVAL_MS,
    );
    this.budgetTimer.unref?.();
  }

  private stopBudgetTimer(): void {
    if (this.budgetTimer) {
      clearInterval(this.budgetTimer);
      this.budgetTimer = null;
    }
  }

  private budgetReason(): RenewReason | null {
    if (Date.now() - this.sessionStartedAt >= this.limits.maxSessionMillis) {
      return "session_age";
    }
    if (this.audioTurns >= this.limits.maxAudioTurns) return "audio_turns";
    if (this.audioSeconds >= this.limits.maxAudioSeconds) return "audio_seconds";
    return null;
  }

  /** Renew only between turns, never mid-utterance. */
  private maybeRenew(): void {
    if (this.shuttingDown || this.renewing || !this.sessionReady) return;
    const reason = this.renewPending ?? this.budgetReason();
    if (!reason) return;
    // Never mid-turn: a reply is streaming, the mic is filling the buffer, or a
    // tool result is still owed and the continuation has not been asked for.
    if (
      this.activeResponseId !== null ||
      this.uplinkBytesSinceCommit > 0 ||
      this.toolBatches.size > 0
    ) {
      this.renewPending = reason;
      return;
    }
    this.renewPending = null;
    void this.renewSession(reason);
  }

  private async renewSession(reason: RenewReason): Promise<void> {
    this.renewing = true;
    this.log("info", `renewing realtime session (${reason})`);
    this.carryOver = this.handlers.onCarryOver?.(reason);
    this.sessionReady = false;
    this.teardownSocket(1000, "session renewal");
    try {
      await this.openSocket();
      this.handlers.onSessionRenewed?.({ reason, sessionId: this.sessionId });
    } catch (error) {
      this.handlers.onError?.(asError(error));
      this.renewing = false;
      this.scheduleReconnect("renewal failed");
      return;
    }
    this.renewing = false;
  }

  // -------------------------------------------------------------------------
  // Event handling
  // -------------------------------------------------------------------------

  private handleEvent(event: ServerEvent): void {
    const type = typeof event.type === "string" ? event.type : "";
    switch (type) {
      case "session.created": {
        this.sessionId = str(dig(event, "session", "id"));
        const turnDetection = dig(event, "session", "turn_detection");
        const serverVad = str(dig(turnDetection, "type")) === "server_vad";
        this.handlers.onSessionCreated?.({
          sessionId: this.sessionId,
          serverVad,
        });
        if (!serverVad) {
          this.log(
            "warn",
            "server did not select server_vad; barge-in will not work (ADR-004 assumes it does)",
          );
        }
        this.sendSessionUpdate();
        return;
      }
      case "session.updated":
        this.sessionId = str(dig(event, "session", "id")) || this.sessionId;
        return;

      case "input_audio_buffer.speech_started":
        this.handlers.onSpeechStarted?.();
        return;
      case "input_audio_buffer.speech_stopped":
        this.handlers.onSpeechStopped?.();
        return;
      case "input_audio_buffer.committed":
        // Server-side commits land here too; clearing the counter is what keeps
        // a push-to-talk release from committing an already-empty buffer.
        this.uplinkBytesSinceCommit = 0;
        this.audioTurns += 1;
        return;

      case "conversation.item.input_audio_transcription.delta": {
        // Qwen deviates from OpenAI here: `text` is always empty and the
        // cumulative partial arrives in `stash`.
        const partial =
          str(event.stash) || str(event.text) || str(event.delta);
        if (partial) this.handlers.onInputTranscript?.(partial, false);
        return;
      }
      case "conversation.item.input_audio_transcription.completed":
        this.handlers.onInputTranscript?.(str(event.transcript), true);
        return;
      case "conversation.item.input_audio_transcription.failed":
        // Seen in the wild on short or clipped utterances. The reply still
        // happens, only the text of what the user said is lost, so this is a
        // log line rather than an onError — it is not something to show her
        // owner as a failure.
        this.log("warn", "input audio transcription failed for this utterance");
        return;

      case "response.created":
        this.activeResponseId = str(dig(event, "response", "id"));
        this.responseHadAudio = false;
        this.outputTranscript = "";
        return;

      case "response.output_item.added": {
        const item = dig(event, "item");
        if (str(dig(item, "type")) !== "function_call") return;
        const callId = str(dig(item, "call_id"));
        const responseId = str(event.response_id) || this.activeResponseId || "";
        if (!callId || !responseId) return;
        this.batchFor(responseId).outstanding.add(callId);
        this.callToResponse.set(callId, responseId);
        return;
      }

      case "response.function_call_arguments.done": {
        const callId = str(event.call_id);
        const name = str(event.name);
        const argumentsRaw = str(event.arguments);
        if (!callId || !name) return;
        let parsed: Record<string, unknown> = {};
        let parseError: string | null = null;
        try {
          const value: unknown = argumentsRaw ? JSON.parse(argumentsRaw) : {};
          if (value && typeof value === "object" && !Array.isArray(value)) {
            parsed = value as Record<string, unknown>;
          } else {
            parseError = "arguments were not a JSON object";
          }
        } catch (error) {
          parseError = asError(error).message;
        }
        if (parseError) {
          // Answer immediately: an unanswered call leaves the turn hanging.
          this.log("warn", `tool ${name}: ${parseError}`);
          this.sendToolResult(callId, {
            error: `could not parse arguments: ${parseError}`,
          });
          return;
        }
        if (!this.handlers.onToolCall) {
          this.sendToolResult(callId, { error: "no tool registry is attached" });
          return;
        }
        this.handlers.onToolCall({ callId, name, arguments: parsed, argumentsRaw });
        return;
      }

      case "response.audio.delta": {
        const pcm = decodeBase64(str(event.delta));
        if (pcm.byteLength === 0) return;
        this.responseHadAudio = true;
        this.audioSeconds +=
          pcm.byteLength / 2 / this.config.downlink.sampleRate;
        this.handlers.onAudioDelta?.(pcm);
        return;
      }
      case "response.audio.done":
        this.audioTurns += 1;
        return;

      case "response.audio_transcript.delta": {
        const delta = str(event.delta);
        if (!delta) return;
        this.outputTranscript += delta;
        this.handlers.onOutputTranscript?.(this.outputTranscript, false);
        return;
      }
      case "response.audio_transcript.done":
        this.outputTranscript = str(event.transcript) || this.outputTranscript;
        this.handlers.onOutputTranscript?.(this.outputTranscript, true);
        return;

      case "response.done": {
        this.handleResponseDone(event);
        return;
      }

      case "error": {
        const err = dig(event, "error");
        this.handlers.onError?.(
          new RealtimeApiError(
            str(dig(err, "message")) || "realtime error",
            str(dig(err, "code")) || undefined,
            str(dig(err, "param")) || undefined,
          ),
        );
        return;
      }

      default:
        // Unknown events are ignored on purpose: the service adds them without
        // a version bump.
        return;
    }
  }

  private handleResponseDone(event: ServerEvent): void {
    const response = dig(event, "response");
    const responseId = str(dig(response, "id")) || this.activeResponseId || "";
    const status = str(dig(response, "status"));
    const hadAudio = this.responseHadAudio;
    this.resetTurnState();

    if (status === "cancelled") {
      // Barge-in: the server stopped her because the user started talking.
      const reason =
        str(dig(response, "status_details", "reason")) || "cancelled";
      this.toolBatches.delete(responseId);
      this.handlers.onResponseCancelled?.({ responseId, reason });
    } else if (status === "failed") {
      const message =
        str(dig(response, "status_details", "error", "message")) ||
        "response failed";
      const code =
        str(dig(response, "status_details", "error", "code")) || undefined;
      this.toolBatches.delete(responseId);
      this.handlers.onError?.(new RealtimeApiError(message, code));
      if (this.handlers.onResponseFailed) {
        this.handlers.onResponseFailed({ responseId, message, code, hadAudio });
      } else {
        // No dedicated handler: still end the turn through the cancel path.
        // A failure with no terminal callback leaves the playback stream that
        // `onAudioDelta` opened unclosed, and the avatar stuck in `talking`.
        this.handlers.onResponseCancelled?.({ responseId, reason: "failed" });
      }
    } else {
      const batch = this.toolBatches.get(responseId);
      if (batch) {
        // A tool-call response is only half a turn: mark it finished and wait
        // for the results before asking the model to continue.
        batch.responseDone = true;
        this.maybeContinueAfterTools(responseId);
      } else {
        this.handlers.onResponseDone?.({ responseId, hadAudio });
      }
    }
    this.afterTurn();
  }

  private resetTurnState(): void {
    this.activeResponseId = null;
    this.responseHadAudio = false;
    this.outputTranscript = "";
  }

  /** A turn just ended — the only safe moment to rebuild the session. */
  private afterTurn(): void {
    this.maybeRenew();
  }

  private batchFor(responseId: string) {
    let batch = this.toolBatches.get(responseId);
    if (!batch) {
      batch = { outstanding: new Set<string>(), responseDone: false };
      this.toolBatches.set(responseId, batch);
    }
    return batch;
  }

  private maybeContinueAfterTools(responseId: string): void {
    const batch = this.toolBatches.get(responseId);
    if (!batch || !batch.responseDone || batch.outstanding.size > 0) return;
    this.toolBatches.delete(responseId);
    if (this.activeResponseId === null) this.send({ type: "response.create" });
  }

  // -------------------------------------------------------------------------
  // Outbound
  // -------------------------------------------------------------------------

  private sendSessionUpdate(): void {
    const instructions = this.carryOver
      ? `${this.config.instructions}\n\n[Earlier in this conversation]\n${this.carryOver}`.trim()
      : this.config.instructions;

    this.send({
      type: "session.update",
      session: {
        modalities: ["text", "audio"],
        voice: this.config.voice,
        // Verified accepted values; `session.created` reports plain "pcm".
        input_audio_format: "pcm16",
        output_audio_format: "pcm16",
        input_audio_transcription: { model: DEFAULT_TRANSCRIPTION_MODEL },
        // Server-side endpointing and barge-in (ADR-004). Do not replace this
        // with client-side VAD.
        turn_detection: {
          type: "server_vad",
          threshold: 0.5,
          prefix_padding_ms: 300,
          silence_duration_ms: 800,
          create_response: true,
          interrupt_response: true,
        },
        ...(instructions ? { instructions } : {}),
        ...(this.tools.length > 0
          ? {
              tools: this.tools.map((tool) => ({ type: "function", ...tool })),
              tool_choice: "auto",
            }
          : {}),
      },
    });
  }

  private send(event: Record<string, unknown>): void {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      this.log("warn", `dropping ${String(event.type)}: socket is not open`);
      return;
    }
    ws.send(JSON.stringify(event));
  }

  private minCommitBytes(): number {
    const f = this.config.uplink;
    return (f.sampleRate * f.channels * 2 * MIN_COMMIT_MILLIS) / 1000;
  }

  private bytesToMillis(bytes: number): number {
    const f = this.config.uplink;
    return Math.round((bytes * 1000) / (f.sampleRate * f.channels * 2));
  }

  private log(level: RealtimeLogLevel, message: string): void {
    this.handlers.onLog?.(level, message);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function base64(bytes: Uint8Array): string {
  return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString(
    "base64",
  );
}

function decodeBase64(value: string): Uint8Array {
  if (!value) return new Uint8Array(0);
  return Buffer.from(value, "base64");
}

/** Walk a plain JSON object without trusting any of its shape. */
function dig(value: unknown, ...path: string[]): unknown {
  let current = value;
  for (const key of path) {
    if (current === null || typeof current !== "object") return undefined;
    current = (current as Record<string, unknown>)[key];
  }
  return current;
}

function str(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function asError(value: unknown): Error {
  return value instanceof Error ? value : new Error(String(value));
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
