/**
 * The settings route table (ADR-009, docs/protocol.md §3.9 / §3.10).
 *
 * This is the piece that was missing between the three implementations: the
 * providers know how to answer, the router knows how to fall back, the app
 * knows how to draw it — but nothing turned `settings.get` into a
 * `settings.state`, and nothing asked the app for a credential.
 *
 * Three things are decided here rather than in `index.ts`, because they are the
 * parts worth testing without a socket, a key or a GPU:
 *
 * 1. **What the voice row says.** There is no `VoiceProvider` interface
 *    (`providers/types.ts` explains why), so the one route with one
 *    implementation gets its `ProviderHealth` computed here from the resolved
 *    credential plus a small seam onto the live session.
 *
 * 2. **When a `settings.state` is pushed.** §3.9 lists three triggers —
 *    `selected`, `active`, a candidate's `status`, or the credential resolution
 *    changing. Anything else (a new latency number, a fresh `checkedAt`) is not
 *    a change the window needs to be woken for, so the snapshot is compared on
 *    the fields that are.
 *
 * 3. **What a credential answer does.** §八 assigns each slot a consequence:
 *    the DashScope key renews a session, the Cloudflare pair rebuilds a
 *    stateless provider, the Hugging Face token affects nothing already loaded.
 *    Only slots that actually changed are reported, so an unrelated edit never
 *    costs the user a turn.
 *
 * 4. **What "保存并测试" actually tests on the voice row.** A Realtime handshake
 *    is not always available to answer the question — it is skipped entirely
 *    when a session is already up, and when it does fail it reports every
 *    rejection as the same opaque close reason. So the key also gets asked
 *    about over plain HTTP, where a 401 is a 401 (`checkDashScopeKey`).
 */

import {
  AUTO_PROVIDER,
  type CredentialValue,
  type LogLevel,
  type ProviderHealth,
  type RouteState,
  type SettingsProbePayload,
  type SettingsProbeResultPayload,
  type SettingsSetPayload,
  type SettingsStatePayload,
} from "./protocol.ts";
import type { CredentialResolver } from "./credentials.ts";
import { ALLOWED_REALTIME_HOSTS, DEFAULT_REALTIME_ENDPOINT } from "./realtime.ts";
import type { TextRouter } from "./providers/router.ts";
import {
  CREDENTIAL_SLOTS,
  VOICE_PROVIDER_ID,
  type CredentialSlot,
  type ProviderStatus,
} from "./providers/index.ts";

/**
 * The one Realtime session, as the settings route sees it.
 *
 * A seam rather than a direct `RealtimeClient` dependency for one reason: every
 * branch below has to be reachable in a test, and `RealtimeClient` cannot reach
 * `ok` without a real key and a real WebSocket to DashScope. `index.ts` holds
 * the only production implementation, and it is four lines long.
 */
export interface VoiceSession {
  /** Model id for the row, e.g. `"qwen3.5-omni-flash-realtime"`. */
  readonly model: string;
  /** A session is live right now. */
  connected(): boolean;
  /**
   * Non-null when there will be no session — it could not be constructed (a
   * missing key, a `DASHSCOPE_REALTIME_ENDPOINT` pointed somewhere the key must
   * not be sent) or the core was started with `--no-realtime`. English, from
   * the constructor or the flag; never shown raw to the user.
   */
  configError(): string | null;
  /** Open a session if there is not one. Rejects with the reason it could not. */
  ensureConnected(timeoutMs: number): Promise<void>;
}

export interface SettingsServiceOptions {
  credentials: CredentialResolver;
  /** The `text` route. Its `onChange` should call `publish()`. */
  router: TextRouter;
  voice: VoiceSession;
  /** Where the core looked for a `.env`, in the order it looked. */
  envFiles: { path: string; loaded: boolean }[];
  /** Ask the app for these slots. `null` means "no answer, keep what we have". */
  requestCredentials: (slots: readonly CredentialSlot[]) => Promise<CredentialValue[] | null>;
  /** Push a snapshot to the app. Called only when §3.9 says to. */
  publish: (state: SettingsStatePayload) => void;
  /** Slots whose effective value changed, for the per-slot consequences of §八. */
  onCredentialsChanged?: (slots: CredentialSlot[]) => void;
  /**
   * Ask DashScope whether a key is good, without opening a metered session.
   *
   * A seam for the same reason `VoiceSession` is one: every branch below has to
   * be reachable from a test, and none of them may reach the network. The
   * default is `checkDashScopeKey`, so `index.ts` does not have to know this
   * exists.
   */
  verifyVoiceKey?: (key: string, timeoutMs: number) => Promise<VoiceKeyVerdict>;
  log?: (level: LogLevel, message: string) => void;
}

/**
 * Classify a failure to open a Realtime session.
 *
 * A heuristic over an error string, and labelled as one: the DashScope
 * WebSocket handshake gives us an HTTP status and a message, not a machine
 * code. Only the timeout branch has been exercised against the real service —
 * the credential branches are pattern matches on what an HTTP 401/403 looks
 * like, and are covered by tests that hand this function the string, not by a
 * real rejected key.
 *
 * `SettingsService` refines the verdict with a real HTTP status where it can
 * (`checkDashScopeKey`); this function is what is left when it cannot.
 */
export function classifyVoiceFailure(message: string): ProviderStatus {
  const text = message.toLowerCase();
  if (/\b401\b|\b403\b|unauthor|invalid[ _-]?api[ _-]?key|forbidden/.test(text)) {
    return "unauthorized";
  }
  if (/\b429\b|rate[ _-]?limit|quota|throttl/.test(text)) return "quota_exhausted";
  // Bun collapses *every* non-101 answer to the WebSocket upgrade — 401, 403,
  // 429, 404, 500 alike — into close code 1002 with reason "Expected 101 status
  // code", which `RealtimeClient.openSocket` then wraps as "realtime socket
  // closed during handshake: Expected 101 status code". Measured against the
  // live endpoint on 2026-08-19 with a deliberately invalid key, and again
  // against a wrong path on the same host: identical strings. A real network
  // fault is distinguishable — it closes 1006 with "Failed to connect".
  //
  // So the status is gone but one fact survives: DashScope *answered*, which is
  // exactly what the `closed` branch below would have denied. This branch has
  // to come first, or the most common first-run failure (a key pasted wrong)
  // keeps being reported as "检查网络".
  if (/expected 101|101 status/.test(text)) return "unauthorized";
  if (/timeout|timed out|econnrefused|enotfound|dns|network|socket|closed/.test(text)) {
    return "unreachable";
  }
  return "error";
}

/**
 * What DashScope says about a key when it is asked over plain HTTP.
 *
 * `unknown` is not a verdict about the key — it means the question could not be
 * put at all (no network, a 5xx, an endpoint this core will not send a key to).
 * Callers must not turn it into either good news or bad.
 */
export type VoiceKeyVerdict = "ok" | "unauthorized" | "quota_exhausted" | "unknown";

/**
 * Where a DashScope key can be checked without opening a metered session.
 *
 * `GET /api/v1/models` lists model ids, runs no inference and bills nothing.
 * Measured against the live service on 2026-08-19: a working key answers 200, a
 * `sk-`-shaped fake answers 401 with `{"code":"InvalidApiKey"}`. That status is
 * precisely what the WebSocket handshake throws away.
 *
 * Returns null when the key must not be sent. The host is taken from the same
 * `DASHSCOPE_REALTIME_ENDPOINT` the socket dials, and only the two hosts
 * `realtime.ts` vets are accepted — `AKARI_ALLOW_CUSTOM_ENDPOINT=1` is the user
 * pointing the *socket* somewhere, not permission to invent an HTTP path on
 * that host and post the key to it.
 */
export function dashscopeKeyCheckUrl(
  env: Record<string, string | undefined> = process.env,
): string | null {
  const endpoint = env.DASHSCOPE_REALTIME_ENDPOINT || DEFAULT_REALTIME_ENDPOINT;
  let host: string;
  try {
    host = new URL(endpoint).hostname;
  } catch {
    return null;
  }
  if (!ALLOWED_REALTIME_HOSTS.includes(host)) return null;
  return `https://${host}/api/v1/models`;
}

/**
 * The one call `checkDashScopeKey` makes. Narrower than `typeof fetch` on
 * purpose: a test stub should be two lines, not two lines and a cast through
 * `unknown` to satisfy overloads this function never uses.
 */
type KeyCheckFetch = (input: string, init: RequestInit) => Promise<Response>;

/**
 * Ask DashScope whether a key is good. Never logs the key, never returns it,
 * and never reads the response body — only the status is wanted, and an
 * upstream body is exactly the thing that might echo the request back.
 */
export async function checkDashScopeKey(
  key: string,
  timeoutMs: number,
  options: { env?: Record<string, string | undefined>; fetchImpl?: KeyCheckFetch } = {},
): Promise<VoiceKeyVerdict> {
  const url = dashscopeKeyCheckUrl(options.env ?? process.env);
  if (url === null) return "unknown";
  const call = options.fetchImpl ?? fetch;
  let response: Response;
  try {
    response = await call(url, {
      method: "GET",
      headers: { Authorization: `Bearer ${key}` },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    // Nothing answered. That says something about the network, nothing about
    // the key, so it must not become a verdict on the key.
    return "unknown";
  }
  void response.body?.cancel().catch(() => {});
  if (response.status === 401 || response.status === 403) return "unauthorized";
  if (response.status === 429) return "quota_exhausted";
  if (response.ok) return "ok";
  // 5xx and anything else: DashScope is unhappy about itself, not about us.
  return "unknown";
}

/** The stored key checks out, but DashScope still refused to open a session. */
const VOICE_KEY_OK_SESSION_REFUSED =
  "这把 key 本身是有效的，DashScope 却不肯开语音会话 —— 多半是它没开通 Realtime，或服务端正出问题。看 core 的日志。";
/**
 * A live session, and the key now stored was refused. The session is still
 * running on the key it dialled with, and that is the whole problem.
 */
const VOICE_KEY_REJECTED_WHILE_LIVE =
  "DashScope 拒了现在存着的这把 key。还能说话是因为会话仍挂在旧 key 上，下一轮续会话就会断 —— 趁现在换掉它。";
/** A live session, and the stored key could not be re-checked either way. */
const VOICE_KEY_UNVERIFIED =
  "语音会话是通的，但这次没能复核已存的 key（DashScope 没应答）。刚换过 key 的话，要等下一轮对话才知道新的那把行不行。";

/** What is left of a probe's budget. Never less than a second. */
function remainingBudget(startedAt: number, timeoutMs: number): number {
  return Math.max(1_000, timeoutMs - (Date.now() - startedAt));
}

/** What to tell the user for a voice status. One line, Chinese, no credential. */
function voiceAdvice(status: ProviderStatus): string {
  switch (status) {
    case "unauthorized":
      return "DashScope 拒绝了这把 key，去百炼控制台确认它还有效、且开通了 Realtime。";
    case "quota_exhausted":
      return "DashScope 这边限流或额度用尽了，等一下再试。";
    case "unreachable":
      return "连不上 DashScope，检查网络。";
    default:
      return "开不了语音会话，看 core 的日志。";
  }
}

export class SettingsService {
  readonly #credentials: CredentialResolver;
  readonly #router: TextRouter;
  readonly #voice: VoiceSession;
  readonly #envFiles: { path: string; loaded: boolean }[];
  readonly #request: (slots: readonly CredentialSlot[]) => Promise<CredentialValue[] | null>;
  readonly #publish: (state: SettingsStatePayload) => void;
  readonly #onCredentialsChanged: (slots: CredentialSlot[]) => void;
  readonly #verifyVoiceKey: (key: string, timeoutMs: number) => Promise<VoiceKeyVerdict>;
  readonly #log: (level: LogLevel, message: string) => void;

  /** Result of the last `settings.probe` on the voice route, if any. */
  #voiceProbe: Pick<ProviderHealth, "status" | "message" | "latencyMs" | "checkedAt"> | null =
    null;
  /**
   * Fingerprint of the DashScope key `#voiceProbe` is a verdict *about*.
   *
   * A probe result outlives the key it was measured on: the user reads
   * "unauthorized", pastes a different key, and the row must go back to
   * "not tested yet" rather than keep accusing a key nobody has tried. Storing
   * the fingerprint rather than clearing the field on every credential change
   * makes that automatic — and a fingerprint is the one thing about a key that
   * is safe to keep (`credentials.ts`).
   */
  #voiceProbeKey: string | undefined;
  /** `selected` for the voice route. Only one candidate, but §3.9 still shows it. */
  #voiceSelected: string = AUTO_PROVIDER;
  #signature = "";

  constructor(options: SettingsServiceOptions) {
    this.#credentials = options.credentials;
    this.#router = options.router;
    this.#voice = options.voice;
    this.#envFiles = options.envFiles;
    this.#request = options.requestCredentials;
    this.#publish = options.publish;
    this.#onCredentialsChanged = options.onCredentialsChanged ?? (() => {});
    this.#verifyVoiceKey = options.verifyVoiceKey ?? checkDashScopeKey;
    this.#log = options.log ?? (() => {});
    this.#signature = this.#snapshotSignature();
  }

  // --- snapshot ------------------------------------------------------------

  state(): SettingsStatePayload {
    return {
      routes: [this.#voiceRoute(), this.#router.state()],
      credentials: this.#credentials.describe(),
      envFiles: this.#envFiles.map((file) => ({ ...file })),
    };
  }

  /** Push, but only if §3.9 says this counts as a change. */
  publish(): void {
    const signature = this.#snapshotSignature();
    if (signature === this.#signature) return;
    this.#signature = signature;
    this.#publish(this.state());
  }

  /**
   * Push unconditionally. Used for the answer to `settings.get` and after a
   * reconnect: a freshly attached app has no picture at all, so "nothing
   * changed since the last app" is not a reason to send it nothing.
   */
  publishNow(): void {
    this.#signature = this.#snapshotSignature();
    this.#publish(this.state());
  }

  // --- inbound -------------------------------------------------------------

  /** `settings.get`. */
  handleGet(): SettingsStatePayload {
    this.#signature = this.#snapshotSignature();
    return this.state();
  }

  /**
   * `settings.set`. Returns null for a route/provider pair this core does not
   * have, and in that case **nothing above has changed** (§3.9).
   */
  handleSet(payload: SettingsSetPayload): SettingsStatePayload | null {
    if (payload.route === "text") {
      if (!this.#router.select(payload.provider)) return null;
      this.#signature = this.#snapshotSignature();
      return this.state();
    }
    // The voice route has exactly one candidate, so the only accepted values
    // are that one and `auto`. Rejecting anything else here is what keeps a
    // typo from looking like it took effect.
    if (payload.provider !== AUTO_PROVIDER && payload.provider !== VOICE_PROVIDER_ID) {
      return null;
    }
    this.#voiceSelected = payload.provider;
    this.#signature = this.#snapshotSignature();
    return this.state();
  }

  /** `settings.probe`. Never throws: a probe failure is a status, not an error. */
  async handleProbe(payload: SettingsProbePayload): Promise<SettingsProbeResultPayload> {
    const timeoutMs = payload.timeoutMs && payload.timeoutMs > 0 ? payload.timeoutMs : 10_000;
    if (payload.route === "text") {
      const results = await this.#router.probe(payload.provider, timeoutMs);
      this.publish();
      return { route: "text", results };
    }
    if (payload.provider && payload.provider !== VOICE_PROVIDER_ID) {
      return { route: "voice", results: [] };
    }
    const health = await this.#probeVoice(timeoutMs);
    this.publish();
    return { route: "voice", results: [health] };
  }

  /**
   * `credentials.updated`, and the once-per-connection initial fetch.
   *
   * Returns the slots whose *effective* value changed — the same list §八 uses
   * to decide what to rebuild. An app that answers with the value already in
   * `.env` changes nothing, which is the ordinary case right after the user
   * pastes their key into the settings window, and is exactly when rebuilding
   * would cost a live Realtime session for no reason.
   */
  async refreshCredentials(
    slots: readonly CredentialSlot[] = CREDENTIAL_SLOTS,
  ): Promise<CredentialSlot[]> {
    if (slots.length === 0) return [];
    const values = await this.#request(slots);
    if (values === null) {
      // §八 "credentials.request 超时" / "app 断线": keep the current values.
      this.#log("warn", `no credentials answer for ${slots.join(", ")}; keeping current values`);
      return [];
    }
    const changed = this.#credentials.applyFromApp(values);
    for (const line of this.#credentials.logLines()) this.#log("info", line);
    if (changed.length > 0) this.#onCredentialsChanged(changed);
    // Published even when nothing changed: `denied` and `cleared` are reported
    // per slot and can move without any value moving with them.
    this.publish();
    return changed;
  }

  // --- voice ---------------------------------------------------------------

  /** Recompute after something outside changed the session (connect, drop). */
  voiceChanged(): void {
    this.publish();
  }

  #voiceRoute(): RouteState {
    const health = this.#voiceHealth();
    return {
      route: "voice",
      selected: this.#voiceSelected,
      active: health.status === "ok" ? VOICE_PROVIDER_ID : null,
      candidates: [health],
    };
  }

  /**
   * The voice row without touching the network.
   *
   * No `capabilities`: the field is optional and every number in it would be
   * invented here. The Realtime session's context window is not something this
   * core has verified, and `ProviderCapabilities.contextTokens` is required
   * once the object exists — a made-up 32768 on a settings screen is worse than
   * an absent field.
   */
  #voiceHealth(): ProviderHealth {
    const base = { provider: VOICE_PROVIDER_ID, model: this.#voice.model };
    const key = this.#credentials.get("dashscope.apiKey");
    if (key.value === undefined) {
      return {
        ...base,
        status: "unconfigured",
        missing: ["dashscope.apiKey"],
        message: key.cleared
          ? "DashScope key 已在设置里清空，语音停用了。"
          : "还没填 DashScope API key，语音这一路用不了。",
        checkedAt: 0,
      };
    }
    if (this.#voice.configError() !== null) {
      // Nothing is logged here on purpose: this function runs on every change
      // check, and the reason is English text that can name an endpoint. The
      // core prints it once at startup; the window gets a pointer to it.
      return { ...base, status: "error", message: "语音会话建不起来，看 core 的日志。", checkedAt: 0 };
    }
    // A verdict measured on a key that is no longer the one in force says
    // nothing about the one that is.
    const probe = this.#voiceProbeKey === key.fingerprint ? this.#voiceProbe : null;
    if (this.#voice.connected()) {
      // A live socket proves the key it dialled with, not the key stored now.
      // `RealtimeClient.setApiKey` deliberately leaves an open session on the
      // old key until the next turn boundary, so "已连接" and "这把 key 是好的"
      // can be an hour apart — which is how 保存并测试 came to report
      // "可用 · 0ms" for a key DashScope had never seen. A probe that checked
      // *this* key and was refused therefore wins over the socket: the session
      // it contradicts is the one about to die.
      if (probe?.status === "unauthorized" || probe?.status === "quota_exhausted") {
        return { ...base, ...probe };
      }
      return {
        ...base,
        status: "ok",
        checkedAt: probe?.checkedAt ?? 0,
        ...(probe?.latencyMs === undefined ? {} : { latencyMs: probe.latencyMs }),
        ...(probe?.message === undefined ? {} : { message: probe.message }),
      };
    }
    if (probe) return { ...base, ...probe };
    return { ...base, status: "unknown", checkedAt: 0 };
  }

  /**
   * `保存并测试` for the voice row.
   *
   * Two different things have to be tested depending on where the session is,
   * and conflating them is what made this button lie:
   *
   * - **No session yet** — `ensureConnected` dials with the stored key, so the
   *   handshake *is* the test. Success proves the key.
   * - **A session already up** — `ensureConnected` returns without touching the
   *   network, so it proves nothing whatsoever about the key now stored. It may
   *   well be a different one: the app writes a new key, the core adopts it, and
   *   `RealtimeClient.setApiKey` schedules the renewal for the next turn
   *   boundary rather than cutting the user off mid-sentence. So the stored key
   *   is checked over HTTP instead, where a rejection is a status code and not a
   *   dropped call an hour from now.
   */
  async #probeVoice(timeoutMs: number): Promise<ProviderHealth> {
    const health = this.#voiceHealth();
    // Nothing to test yet: no key, or a session that could not be built at all.
    if (health.status === "unconfigured" || health.status === "error") return health;

    const key = this.#credentials.get("dashscope.apiKey");
    this.#voiceProbeKey = key.fingerprint;
    // Read before the call, because the call is what destroys the distinction.
    const wasLive = this.#voice.connected();
    const started = Date.now();
    try {
      await this.#voice.ensureConnected(timeoutMs);
    } catch (error) {
      const raw = error instanceof Error ? error.message : String(error);
      let status = classifyVoiceFailure(raw);
      let message = voiceAdvice(status);
      // The handshake cannot tell 401 from 500 (see `classifyVoiceFailure`), so
      // whenever the guess is the one that blames the user's key, put the same
      // question to DashScope over HTTP, where the status code survives.
      if (status === "unauthorized" && key.value !== undefined) {
        const verdict = await this.#verifyVoiceKey(
          key.value,
          remainingBudget(started, timeoutMs),
        );
        if (verdict === "ok") {
          status = "error";
          message = VOICE_KEY_OK_SESSION_REFUSED;
        } else if (verdict !== "unknown") {
          status = verdict;
          message = voiceAdvice(status);
        }
      }
      // The upstream text may quote a header, so it is logged and not forwarded
      // (§3.9: never relay an upstream error body).
      this.#log("warn", `voice probe failed (${status}): ${raw}`);
      this.#voiceProbe = {
        status,
        message,
        checkedAt: Date.now(),
        latencyMs: Date.now() - started,
      };
      return this.#voiceHealth();
    }

    if (!wasLive) {
      // The handshake just carried the stored key and DashScope accepted it.
      this.#voiceProbe = { status: "ok", checkedAt: Date.now(), latencyMs: Date.now() - started };
      return this.#voiceHealth();
    }

    const verdict =
      key.value === undefined
        ? "unknown"
        : await this.#verifyVoiceKey(key.value, remainingBudget(started, timeoutMs));
    const checkedAt = Date.now();
    const latencyMs = checkedAt - started;
    if (verdict === "ok") {
      this.#voiceProbe = { status: "ok", checkedAt, latencyMs };
    } else if (verdict === "unknown") {
      // Still green — there is a session and the user can talk through it — but
      // the row has to admit that this press did not settle the new key.
      this.#voiceProbe = { status: "ok", message: VOICE_KEY_UNVERIFIED, checkedAt, latencyMs };
    } else {
      this.#log(
        "warn",
        `stored dashscope key was refused (${verdict}) while an older session is still live`,
      );
      this.#voiceProbe = {
        status: verdict,
        message:
          verdict === "unauthorized" ? VOICE_KEY_REJECTED_WHILE_LIVE : voiceAdvice(verdict),
        checkedAt,
        latencyMs,
      };
    }
    return this.#voiceHealth();
  }

  // --- change detection ----------------------------------------------------

  /**
   * Everything §3.9 counts as a change, and nothing else. `latencyMs` and
   * `checkedAt` are deliberately absent: a probe that returns the same verdict
   * 40ms faster is not news, and `settings.probeResult` already carried it.
   */
  #snapshotSignature(): string {
    const state = this.state();
    const routes = state.routes.map(
      (route) =>
        `${route.route}/${route.selected}/${route.active ?? "-"}/` +
        route.candidates.map((c) => `${c.provider}:${c.status}:${c.model ?? "-"}`).join(","),
    );
    const credentials = state.credentials.map(
      (c) => `${c.slot}:${c.source}:${c.present ? 1 : 0}:${c.fingerprint ?? "-"}:${c.cleared ? 1 : 0}:${c.denied ? 1 : 0}`,
    );
    const envFiles = state.envFiles.map((f) => `${f.path}:${f.loaded ? 1 : 0}`);
    return [...routes, ...credentials, ...envFiles].join("|");
  }
}
