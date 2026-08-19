/**
 * Cloudflare Workers AI text provider (ADR-009).
 *
 *   POST https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run/{model}
 *   Authorization: Bearer {token}
 *
 * The endpoint is OpenAI-compatible, with two wrappers that are easy to get
 * wrong and were both checked against the user's own account on 2026-08-19:
 *
 * - **Non-streaming** replies are wrapped: `{ success, errors, result: {...} }`,
 *   with the OpenAI `chat.completion` object under `result`.
 * - **Streaming** replies are *not* wrapped. They are plain SSE `data:` lines
 *   carrying bare `chat.completion.chunk` objects, then one final
 *   `{"response":"","usage":{...}}` event with the turn totals, then `[DONE]`.
 *
 * Verified live against `@cf/qwen/qwen3.8-27b` (all HTTP 200 unless noted):
 *   - plain chat, streaming chat, function calling, streaming function calling
 *   - vision via OpenAI `image_url` + a `data:` URL (answered correctly)
 *   - wrong model id  -> **400** with CF code 7000 "No route for that URI"
 *     (not 404 — the model id is part of the path, so a typo is a routing miss)
 *   - wrong token, and wrong account id -> **401** code 10000
 *   - `chat_template_kwargs: {enable_thinking:false}` suppresses the reasoning
 *     trace; the same body is accepted unchanged by `@cf/meta/llama-3.1-8b-instruct`
 *
 * **Not** verified, because it cannot be produced on demand: 403 (a token with
 * Workers AI *Read* only — measured in an earlier session, hence the wording of
 * that message), 429, and 5xx. Their mappings are written from the status code
 * alone.
 */

import type { TextProviderDeps } from "./index.ts";
import { DEFAULT_TEXT_MODELS, TEXT_MODEL_ENV_VARS } from "./index.ts";
import {
  ProviderError,
  type ChatChunk,
  type ChatMessage,
  type ChatRequest,
  type ProviderCapabilities,
  type ProviderProbe,
  type ProviderStatus,
  type QuotaSnapshot,
  type TextProvider,
  type ToolSchema,
} from "./types.ts";

const PROVIDER_ID = "cloudflare-workers-ai";
const API_BASE = "https://api.cloudflare.com/client/v4";
/** `settings.probe` defaults to 10s (docs/protocol.md §3.9); match it. */
const DEFAULT_PROBE_TIMEOUT_MS = 10_000;

/**
 * How long `chat()` waits for response headers before calling it unreachable.
 *
 * `chat()` used to pass `request.signal` straight through and nothing else, so
 * a network that accepts the connection and then answers nothing — a captive
 * portal, a half-dead VPN — held the turn until the system TCP timeout, about
 * 75 s. `router.ts` now also puts a budget on every chunk, but a provider that
 * can hang for a minute and a quarter on its own is a provider whose contract
 * ("throw `ProviderError`, never a bare `Error`") is only true given a careful
 * caller. This is the connect phase only; the body is a stream, and a stream
 * that has started is bounded by the router, not by a deadline here.
 *
 * Sized off measurements on the user's own account: probe round trip 1191 ms,
 * first streamed token 410 ms.
 */
const CHAT_CONNECT_TIMEOUT_MS = 15_000;

/**
 * Capabilities of `@cf/qwen/qwen3.8-27b`, read off
 * `GET /accounts/{id}/ai/models/search?search=qwen3.8-27b`, which reports
 * `context_window: 262144`, `function_calling: true`, `vision: true`,
 * `reasoning: true`. The three booleans were then each exercised for real.
 *
 * These are constants, not per-instance facts, and that is a known limitation:
 * `capabilities` has to be readable before any network call (see `./index.ts`),
 * so an operator who points `CF_AI_CHAT_MODEL` at a text-only model gets a
 * provider still claiming `vision: true`. Fixing that means either a hardcoded
 * model table or a probe-before-capabilities, and neither is worth it while the
 * default model is the only one the product ships.
 *
 * `maxOutputTokens` is deliberately absent: Cloudflare does not publish a
 * per-request output cap for this model, and inventing one would be worse than
 * saying nothing.
 */
export const CLOUDFLARE_CAPABILITIES: ProviderCapabilities = {
  vision: true,
  tools: true,
  streaming: true,
  contextTokens: 262_144,
  local: false,
};

/**
 * Test seams. Production passes nothing; `createTextProvider` in `./index.ts`
 * calls this factory with `deps` alone.
 */
export interface CloudflareOverrides {
  /** Injected so tests can drive the wire without a credential. */
  fetch?: typeof fetch;
  /** `CHAT_CONNECT_TIMEOUT_MS`, so a test can reach it without waiting 15 s. */
  connectTimeoutMs?: number;
}

// ---------------------------------------------------------------------------
// Wire shapes (only the fields this module reads)
// ---------------------------------------------------------------------------

interface CfError {
  code?: number;
  message?: string;
}

interface CfToolCallDelta {
  index?: number;
  id?: string;
  function?: { name?: string; arguments?: string };
}

interface CfStreamEvent {
  choices?: {
    delta?: {
      content?: string | null;
      reasoning?: string | null;
      tool_calls?: CfToolCallDelta[];
    };
    finish_reason?: string | null;
  }[];
  usage?: { prompt_tokens?: number; completion_tokens?: number };
}

// ---------------------------------------------------------------------------
// Request building
// ---------------------------------------------------------------------------

type CfContentPart =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };

interface CfMessage {
  role: string;
  content: string | CfContentPart[];
  tool_call_id?: string;
}

/**
 * `ImageInput` carries raw base64; Cloudflare wants the OpenAI `image_url`
 * shape, so the `data:` prefix is added here rather than stored upstream —
 * `./local.ts` needs the same bytes in a different envelope.
 */
function toCfMessage(message: ChatMessage): CfMessage {
  const base: CfMessage =
    message.images && message.images.length > 0
      ? {
          role: message.role,
          content: [
            { type: "text", text: message.content },
            ...message.images.map(
              (image): CfContentPart => ({
                type: "image_url",
                image_url: { url: `data:${image.mediaType};base64,${image.base64}` },
              }),
            ),
          ],
        }
      : { role: message.role, content: message.content };
  if (message.role === "tool" && message.toolCallId) {
    base.tool_call_id = message.toolCallId;
  }
  return base;
}

function toCfTool(tool: ToolSchema) {
  return {
    type: "function",
    function: {
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters,
    },
  };
}

function buildBody(request: ChatRequest, stream: boolean): Record<string, unknown> {
  return {
    messages: request.messages.map(toCfMessage),
    ...(request.tools && request.tools.length > 0
      ? { tools: request.tools.map(toCfTool) }
      : {}),
    ...(request.temperature === undefined ? {} : { temperature: request.temperature }),
    ...(request.maxTokens === undefined ? {} : { max_tokens: request.maxTokens }),
    stream,
    // Qwen3.8 is a reasoning model and, left alone, spends most of a turn in a
    // `delta.reasoning` trace that `ChatChunk` has nowhere to put and the user
    // never sees — measured 28 completion tokens for a two-token answer, all
    // but 3 of them reasoning. Turning it off is a deliberate default, not a
    // knob: nothing in the codebase would set the knob today. Revisit if the
    // router starts wanting visible chain-of-thought.
    chat_template_kwargs: { enable_thinking: false },
  };
}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

/**
 * Everything the settings window is told about a failure. The upstream body is
 * never forwarded verbatim (docs/protocol.md §3.9): only the numeric CF error
 * code goes into the message, because an echoed request body can carry the
 * token that produced it.
 */
function mapHttpStatus(
  httpStatus: number,
  cfErrors: CfError[],
): { status: ProviderStatus; message: string } {
  const code = cfErrors[0]?.code;
  const codeSuffix = code === undefined ? "" : `（CF 错误码 ${code}）`;

  if (httpStatus === 401) {
    return {
      status: "unauthorized",
      // A wrong account id lands here too — Cloudflare answers 401 for both,
      // so the message has to name both rather than guess.
      message: `Cloudflare 拒绝了这对凭据：account ID 或 API token 不对${codeSuffix}。`,
    };
  }
  if (httpStatus === 403) {
    return {
      status: "unauthorized",
      message: `Cloudflare token 权限不够：Workers AI 需要「编辑」权限，只给「读取」时能列出模型但跑不了推理${codeSuffix}。`,
    };
  }
  if (httpStatus === 404 || code === 7000) {
    // 7000 "No route for that URI" is what a typo'd model id actually returns,
    // and it arrives as HTTP 400 — measured.
    return {
      status: "model_missing",
      message: `Cloudflare 上没有这个模型，检查模型 id 是否写对${codeSuffix}。`,
    };
  }
  if (httpStatus === 429) {
    return {
      status: "quota_exhausted",
      message: `Cloudflare 限流或额度用尽，等窗口重置，或先切到本地模型${codeSuffix}。`,
    };
  }
  if (httpStatus >= 500) {
    // Mapped to `unreachable` rather than `error` on purpose: `ProviderError`
    // only treats unreachable / quota_exhausted / starting as retryable, and a
    // Cloudflare-side fault is exactly the case where falling through to the
    // local model is the right move.
    return {
      status: "unreachable",
      message: `Cloudflare 服务端故障（HTTP ${httpStatus}）${codeSuffix}，可以稍后重试或切到本地模型。`,
    };
  }
  return {
    status: "error",
    message: `Cloudflare 拒绝了这次请求（HTTP ${httpStatus}）${codeSuffix}。`,
  };
}

/** Pull `errors[]` out of a failed response without ever keeping the body. */
async function readCfErrors(response: Response): Promise<CfError[]> {
  try {
    const body = (await response.json()) as { errors?: CfError[] };
    return Array.isArray(body.errors) ? body.errors : [];
  } catch {
    return [];
  }
}

/**
 * `AbortSignal.timeout()` aborts with a `TimeoutError`, not an `AbortError`, so
 * checking one name only would turn every probe timeout into a mystery.
 */
function isAbort(error: unknown): boolean {
  return (
    error instanceof Error &&
    (error.name === "AbortError" || error.name === "TimeoutError")
  );
}

// ---------------------------------------------------------------------------
// SSE
// ---------------------------------------------------------------------------

/**
 * Yield the payload of each `data:` line, in order, stopping at `[DONE]`.
 *
 * Events are separated by a blank line; a partial event at the end of a network
 * chunk has to survive until the rest of it arrives, which is what `buffer` is
 * for. Not using a generic SSE library for four lines of framing.
 */
function* dataPayloads(event: string): Generator<string, void, unknown> {
  for (const line of event.split(/\r?\n/)) {
    if (!line.startsWith("data:")) continue;
    const payload = line.slice("data:".length).trim();
    if (payload.length > 0) yield payload;
  }
}

async function* sseEvents(
  body: ReadableStream<Uint8Array>,
): AsyncGenerator<string, void, unknown> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  const separator = /\r?\n\r?\n/;
  let buffer = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      for (;;) {
        const match = separator.exec(buffer);
        if (!match) break;
        const event = buffer.slice(0, match.index);
        buffer = buffer.slice(match.index + match[0].length);
        for (const payload of dataPayloads(event)) {
          if (payload === "[DONE]") return;
          yield payload;
        }
      }
    }
    // A stream that ends without a trailing blank line still has one event in
    // it; dropping it would silently truncate the last token of a reply.
    for (const payload of dataPayloads(buffer)) {
      if (payload === "[DONE]") return;
      yield payload;
    }
  } finally {
    reader.cancel().catch(() => {});
  }
}

/** One tool call being assembled across `delta.tool_calls` fragments. */
interface PendingToolCall {
  id: string;
  name: string;
  argumentsText: string;
}

function finishToolCall(pending: PendingToolCall): ChatChunk {
  const text = pending.argumentsText.trim();
  let parsed: unknown;
  try {
    parsed = text.length === 0 ? {} : JSON.parse(text);
  } catch {
    throw new ProviderError(
      PROVIDER_ID,
      "error",
      `模型给出的工具参数不是合法 JSON（工具 ${pending.name}）。`,
    );
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new ProviderError(
      PROVIDER_ID,
      "error",
      `模型给出的工具参数不是一个对象（工具 ${pending.name}）。`,
    );
  }
  return {
    toolCall: {
      callId: pending.id,
      name: pending.name,
      arguments: parsed as Record<string, unknown>,
    },
  };
}

// ---------------------------------------------------------------------------
// Quota
// ---------------------------------------------------------------------------

const QUOTA_UNKNOWN: QuotaSnapshot = {
  unit: "neurons",
  note: "额度余量拿不到：Cloudflare 只在 GraphQL analytics / dashboard 上报 neuron 用量，且需要 token 带账号分析读取权限。",
};

function startOfUtcDay(now: number): number {
  const date = new Date(now);
  return Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
}

/**
 * Neurons burned today, from the same GraphQL analytics set the dashboard uses.
 *
 * Best effort by design: the inference endpoint does not report a balance, and
 * the *allowance* is not exposed by any API at all — so `limit` and `remaining`
 * stay empty rather than being filled in from a plan number we would be
 * guessing at. Verified live: `aiInferenceAdaptiveGroups.sum.totalNeurons`
 * answers for a Workers AI token.
 */
async function fetchNeuronUsage(
  doFetch: typeof fetch,
  accountId: string,
  token: string,
  now: number,
  signal: AbortSignal | undefined,
): Promise<QuotaSnapshot> {
  const since = new Date(startOfUtcDay(now)).toISOString();
  const query =
    `query{viewer{accounts(filter:{accountTag:${JSON.stringify(accountId)}})` +
    `{aiInferenceAdaptiveGroups(limit:1,filter:{datetimeHour_geq:${JSON.stringify(since)}})` +
    `{sum{totalNeurons}}}}}`;
  try {
    const response = await doFetch(`${API_BASE}/graphql`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query }),
      ...(signal ? { signal } : {}),
    });
    if (!response.ok) return QUOTA_UNKNOWN;
    const body = (await response.json()) as {
      data?: {
        viewer?: {
          accounts?: { aiInferenceAdaptiveGroups?: { sum?: { totalNeurons?: number } }[] }[];
        };
      };
    };
    const total =
      body.data?.viewer?.accounts?.[0]?.aiInferenceAdaptiveGroups?.[0]?.sum?.totalNeurons;
    if (typeof total !== "number" || !Number.isFinite(total)) return QUOTA_UNKNOWN;
    return {
      unit: "neurons",
      used: Math.round(total),
      resetsAt: startOfUtcDay(now) + 86_400_000,
      note: "这是 UTC 当日已用量；Cloudflare 不提供剩余额度，配额上限请看 dashboard。",
    };
  } catch {
    return QUOTA_UNKNOWN;
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

export function createCloudflareTextProvider(
  deps: TextProviderDeps,
  overrides: CloudflareOverrides = {},
): TextProvider {
  const env = deps.env ?? process.env;
  const model = env[TEXT_MODEL_ENV_VARS[PROVIDER_ID]] || DEFAULT_TEXT_MODELS[PROVIDER_ID];
  const doFetch = overrides.fetch ?? fetch;
  const connectTimeoutMs = overrides.connectTimeoutMs ?? CHAT_CONNECT_TIMEOUT_MS;
  const log = deps.log ?? (() => {});

  /** Nothing here reads a credential at construction time — see `./index.ts`. */
  function readCredentials():
    | { ok: true; accountId: string; token: string }
    | { ok: false; missing: ("cloudflare.accountId" | "cloudflare.apiToken")[] } {
    const accountId = deps.credentials.value("cloudflare.accountId");
    const token = deps.credentials.value("cloudflare.apiToken");
    const missing: ("cloudflare.accountId" | "cloudflare.apiToken")[] = [];
    if (accountId === undefined) missing.push("cloudflare.accountId");
    if (token === undefined) missing.push("cloudflare.apiToken");
    if (missing.length > 0) return { ok: false, missing };
    return { ok: true, accountId: accountId as string, token: token as string };
  }

  function runUrl(accountId: string): string {
    return `${API_BASE}/accounts/${encodeURIComponent(accountId)}/ai/run/${model}`;
  }

  async function post(
    accountId: string,
    token: string,
    body: Record<string, unknown>,
    signal: AbortSignal | undefined,
  ): Promise<Response> {
    return doFetch(runUrl(accountId), {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      ...(signal ? { signal } : {}),
    });
  }

  return {
    id: PROVIDER_ID,
    model,
    capabilities: CLOUDFLARE_CAPABILITIES,

    async *chat(request: ChatRequest): AsyncIterable<ChatChunk> {
      const credentials = readCredentials();
      if (!credentials.ok) {
        throw new ProviderError(
          PROVIDER_ID,
          "unconfigured",
          "还没填 Cloudflare 账号 ID 或 API token。",
        );
      }

      const signal = request.signal;
      // A timer we cancel, not `AbortSignal.timeout`: that one keeps counting
      // against the whole `fetch`, body included, and would cut off any answer
      // that took longer than the budget to stream. This one is disarmed the
      // moment headers are in, which is the only phase it is meant to bound.
      const connect = new AbortController();
      let connectExpired = false;
      const connectTimer = setTimeout(() => {
        connectExpired = true;
        connect.abort();
      }, connectTimeoutMs);
      connectTimer.unref?.();

      let response: Response;
      try {
        response = await post(
          credentials.accountId,
          credentials.token,
          buildBody(request, true),
          signal ? AbortSignal.any([signal, connect.signal]) : connect.signal,
        );
      } catch (error) {
        // Our own deadline is a provider failure and has to be diagnosed as
        // one — the router only falls through on a `ProviderError`. Checked
        // before the barge-in branch, because that branch swallows the abort.
        if (connectExpired && !signal?.aborted) {
          throw new ProviderError(
            PROVIDER_ID,
            "unreachable",
            `Cloudflare ${Math.round(connectTimeoutMs / 1000)} 秒内没有应答，检查网络。`,
            error,
          );
        }
        // A barge-in is ordinary control flow, not a provider failure: the
        // caller aborted and is not waiting for a reason. Ending the stream is
        // the honest report — nothing more is coming.
        if (isAbort(error) || signal?.aborted) return;
        throw new ProviderError(
          PROVIDER_ID,
          "unreachable",
          "连不上 Cloudflare，检查网络。",
          error,
        );
      } finally {
        // Disarmed on every path, including the throwing ones: past this point
        // the deadline would be aborting a stream that is already answering.
        clearTimeout(connectTimer);
      }

      if (!response.ok) {
        const { status, message } = mapHttpStatus(response.status, await readCfErrors(response));
        throw new ProviderError(PROVIDER_ID, status, message);
      }
      if (!response.body) {
        throw new ProviderError(PROVIDER_ID, "error", "Cloudflare 返回了空的响应体。");
      }

      const pending = new Map<number, PendingToolCall>();
      let usage: ChatChunk["usage"];
      let emittedText = false;
      let sawReasoning = false;

      try {
        for await (const payload of sseEvents(response.body)) {
          let event: CfStreamEvent;
          try {
            event = JSON.parse(payload) as CfStreamEvent;
          } catch {
            // One unparsable frame is not worth losing the turn over.
            log("warn", `${PROVIDER_ID}: dropped an unparsable SSE frame`);
            continue;
          }

          // The turn totals arrive as a final event with no `choices` key at
          // all — distinct from the zero-filled `choices: []` heartbeat that
          // precedes it, whose per-chunk usage is a delta, not a total.
          if (!("choices" in event) && event.usage) {
            usage = {
              promptTokens: event.usage.prompt_tokens,
              completionTokens: event.usage.completion_tokens,
            };
            continue;
          }

          const choice = event.choices?.[0];
          if (!choice) continue;
          const delta = choice.delta;

          if (delta?.reasoning) sawReasoning = true;
          if (delta?.content) {
            emittedText = true;
            yield { text: delta.content };
          }

          for (const fragment of delta?.tool_calls ?? []) {
            const index = fragment.index ?? 0;
            const existing = pending.get(index);
            if (existing) {
              if (fragment.id) existing.id = fragment.id;
              if (fragment.function?.name) existing.name = fragment.function.name;
              existing.argumentsText += fragment.function?.arguments ?? "";
            } else {
              pending.set(index, {
                id: fragment.id ?? `cf-tool-${index}`,
                name: fragment.function?.name ?? "",
                argumentsText: fragment.function?.arguments ?? "",
              });
            }
          }

          if (choice.finish_reason) {
            for (const call of [...pending.values()]) yield finishToolCall(call);
            pending.clear();
          }
        }
      } catch (error) {
        if (isAbort(error) || signal?.aborted) return;
        if (error instanceof ProviderError) throw error;
        throw new ProviderError(
          PROVIDER_ID,
          "unreachable",
          "与 Cloudflare 的连接中断了。",
          error,
        );
      }

      // A stream that stopped before any `finish_reason` still owes its calls.
      for (const call of [...pending.values()]) yield finishToolCall(call);

      if (!emittedText && sawReasoning) {
        // `enable_thinking:false` should prevent this; if a model ignores it,
        // the turn looks empty and the log is the only place that says why.
        log("warn", `${PROVIDER_ID}: turn produced reasoning only, no visible text`);
      }

      yield { done: true, ...(usage ? { usage } : {}) };
    },

    async probe(signal?: AbortSignal): Promise<ProviderProbe> {
      const checkedAt = Date.now();
      const credentials = readCredentials();
      if (!credentials.ok) {
        return {
          status: "unconfigured",
          ok: false,
          message: "还没填 Cloudflare 账号 ID 或 API token。",
          missing: credentials.missing,
          model,
          checkedAt,
        };
      }

      const timeout = AbortSignal.timeout(DEFAULT_PROBE_TIMEOUT_MS);
      const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;

      // The quota lookup rides along instead of queueing behind the run call:
      // it is a different endpoint with a different permission, and making the
      // "测试连接" button wait for two round trips in series is a worse button.
      const quotaPromise = fetchNeuronUsage(
        doFetch,
        credentials.accountId,
        credentials.token,
        checkedAt,
        combined,
      );

      const started = Date.now();
      let response: Response;
      try {
        // The cheapest call that still proves what the settings window claims:
        // credentials, account, model id, and — the part listing models cannot
        // prove — that the token may actually *run* inference.
        response = await post(
          credentials.accountId,
          credentials.token,
          {
            messages: [{ role: "user", content: "ping" }],
            max_tokens: 1,
            chat_template_kwargs: { enable_thinking: false },
          },
          combined,
        );
      } catch (error) {
        // `fetchNeuronUsage` swallows its own failures, so the in-flight quota
        // promise left behind here can never become an unhandled rejection.
        return {
          status: "unreachable",
          ok: false,
          message:
            timeout.aborted && isAbort(error)
              ? "Cloudflare 没在 10 秒内应答，检查网络。"
              : "连不上 Cloudflare，检查网络。",
          model,
          latencyMs: Date.now() - started,
          checkedAt,
        };
      }

      const latencyMs = Date.now() - started;
      if (!response.ok) {
        const { status, message } = mapHttpStatus(response.status, await readCfErrors(response));
        return { status, ok: false, message, model, latencyMs, checkedAt };
      }
      // Drain so the socket can be reused; the body is one token and unused.
      await response.text().catch(() => "");

      return {
        status: "ok",
        ok: true,
        message: "Cloudflare Workers AI 可用。",
        model,
        latencyMs,
        quota: await quotaPromise,
        checkedAt,
      };
    },
  };
}
