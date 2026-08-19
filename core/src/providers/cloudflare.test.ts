import { describe, expect, test } from "bun:test";
import { CredentialResolver } from "../credentials.ts";
import { CLOUDFLARE_CAPABILITIES, createCloudflareTextProvider } from "./cloudflare.ts";
import { ProviderError, type ChatChunk } from "./types.ts";

/**
 * Everything here runs against an injected `fetch`. No credential in this file
 * is real: the two below are literals chosen to be obviously fake, and several
 * tests assert that neither of them ever reaches a user-visible message.
 *
 * The SSE bodies are trimmed copies of what `@cf/qwen/qwen3.8-27b` actually
 * emitted on 2026-08-19 — same field names, same ordering, same trailing
 * `{"response":"","usage":{…}}` + `[DONE]` tail — so a change in CF's framing
 * shows up here as a failure rather than as silence in production.
 */
const ACCOUNT = "acct-not-a-real-account";
const TOKEN = "cf-token-not-a-real-token";

const CONFIGURED_ENV = {
  CLOUDFLARE_ACCOUNT_ID: ACCOUNT,
  CLOUDFLARE_API_TOKEN: TOKEN,
};

function deps(env: Record<string, string | undefined> = CONFIGURED_ENV) {
  return { credentials: new CredentialResolver(env), env };
}

/** A `Response` whose body streams the given pieces, byte-for-byte as given. */
function streamed(pieces: string[], status = 200): Response {
  const encoder = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const piece of pieces) controller.enqueue(encoder.encode(piece));
      controller.close();
    },
  });
  return new Response(body, {
    status,
    headers: { "content-type": "text/event-stream" },
  });
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function cfError(status: number, code?: number): Response {
  return json(
    {
      result: null,
      success: false,
      // Deliberately echoes the token, the way a badly behaved upstream might:
      // the provider must not pass this through to the settings window.
      errors: code === undefined ? [] : [{ code, message: `boom ${TOKEN}` }],
      messages: [],
    },
    status,
  );
}

interface Call {
  url: string;
  init: RequestInit;
  body: Record<string, unknown>;
}

/** Records every request and answers from a queue keyed by URL substring. */
function mockFetch(handler: (url: string, init: RequestInit) => Response | Promise<Response>) {
  const calls: Call[] = [];
  const fn = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const url = String(input);
    const raw = typeof init.body === "string" ? init.body : "{}";
    calls.push({ url, init, body: JSON.parse(raw) as Record<string, unknown> });
    return handler(url, init);
  }) as unknown as typeof fetch;
  return { fn, calls };
}

async function collect(chunks: AsyncIterable<ChatChunk>): Promise<ChatChunk[]> {
  const out: ChatChunk[] = [];
  for await (const chunk of chunks) out.push(chunk);
  return out;
}

const TEXT_STREAM = [
  `data: {"choices":[{"delta":{"content":"","role":"assistant"},"finish_reason":null,"index":0}],"object":"chat.completion.chunk"}\n\n`,
  `data: {"choices":[{"delta":{"reasoning":"the user wants"},"finish_reason":null,"index":0}],"object":"chat.completion.chunk"}\n\n`,
  `data: {"choices":[{"delta":{"content":"你"},"finish_reason":null,"index":0}],"object":"chat.completion.chunk"}\n\n`,
  `data: {"choices":[{"delta":{"content":"好"},"finish_reason":null,"index":0}],"object":"chat.completion.chunk"}\n\n`,
  `data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}],"object":"chat.completion.chunk"}\n\n`,
  `data: {"choices":[],"object":"chat.completion.chunk","usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}\n\n`,
  `data: {"response":"","usage":{"prompt_tokens":57,"completion_tokens":28,"total_tokens":85,"neurons":10.47}}\n\n`,
  `data: [DONE]\n\n`,
];

const TOOL_STREAM = [
  `data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"get_weather"},"id":"chatcmpl-tool-abc","index":0,"type":"function"}]},"finish_reason":null,"index":0}]}\n\n`,
  `data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\\"city\\": \\""},"index":0}]},"finish_reason":null,"index":0}]}\n\n`,
  `data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"Tok"},"index":0}]},"finish_reason":null,"index":0}]}\n\n`,
  `data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"yo\\"}"},"index":0}]},"finish_reason":null,"index":0}]}\n\n`,
  `data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}]}\n\n`,
  `data: [DONE]\n\n`,
];

const chat = { messages: [{ role: "user" as const, content: "hi" }] };

// ---------------------------------------------------------------------------
// Capabilities
// ---------------------------------------------------------------------------

describe("capabilities", () => {
  test("match what the models/search endpoint reports for the default model", () => {
    // context_window 262144, function_calling true, vision true — and all three
    // were exercised live before being written down here.
    expect(CLOUDFLARE_CAPABILITIES).toEqual({
      vision: true,
      tools: true,
      streaming: true,
      contextTokens: 262_144,
      local: false,
    });
  });

  test("no output cap is claimed, because Cloudflare publishes none", () => {
    expect(CLOUDFLARE_CAPABILITIES.maxOutputTokens).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// Request shape
// ---------------------------------------------------------------------------

describe("request", () => {
  test("hits the account-scoped run endpoint with a bearer token", async () => {
    const { fn, calls } = mockFetch(() => streamed(TEXT_STREAM));
    await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));

    expect(calls[0]?.url).toBe(
      `https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/ai/run/@cf/qwen/qwen3.8-27b`,
    );
    const headers = calls[0]?.init.headers as Record<string, string>;
    expect(headers.Authorization).toBe(`Bearer ${TOKEN}`);
    expect(calls[0]?.body.stream).toBe(true);
  });

  test("uses the model from CF_AI_CHAT_MODEL when one is set", async () => {
    const { fn, calls } = mockFetch(() => streamed(TEXT_STREAM));
    const env = { ...CONFIGURED_ENV, CF_AI_CHAT_MODEL: "@cf/meta/llama-3.1-8b-instruct" };
    const provider = createCloudflareTextProvider(deps(env), { fetch: fn });
    expect(provider.model).toBe("@cf/meta/llama-3.1-8b-instruct");
    await collect(provider.chat(chat));
    expect(calls[0]?.url).toEndWith("/ai/run/@cf/meta/llama-3.1-8b-instruct");
  });

  test("turns the reasoning trace off — ChatChunk has nowhere to put it", async () => {
    const { fn, calls } = mockFetch(() => streamed(TEXT_STREAM));
    await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(calls[0]?.body.chat_template_kwargs).toEqual({ enable_thinking: false });
  });

  test("images go out as OpenAI image_url parts carrying a data URL", async () => {
    const { fn, calls } = mockFetch(() => streamed(TEXT_STREAM));
    await collect(
      createCloudflareTextProvider(deps(), { fetch: fn }).chat({
        messages: [
          {
            role: "user",
            content: "屏幕上是什么？",
            images: [{ mediaType: "image/png", base64: "iVBORw0KGgo=" }],
            untrusted: true,
          },
        ],
      }),
    );

    expect((calls[0]?.body.messages as unknown[])[0]).toEqual({
      role: "user",
      content: [
        { type: "text", text: "屏幕上是什么？" },
        { type: "image_url", image_url: { url: "data:image/png;base64,iVBORw0KGgo=" } },
      ],
    });
  });

  test("a message with no images stays a plain string, not a one-part array", async () => {
    const { fn, calls } = mockFetch(() => streamed(TEXT_STREAM));
    await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect((calls[0]?.body.messages as { content: unknown }[])[0]?.content).toBe("hi");
  });

  test("tool results carry tool_call_id, and tool schemas take the function shape", async () => {
    const { fn, calls } = mockFetch(() => streamed(TEXT_STREAM));
    await collect(
      createCloudflareTextProvider(deps(), { fetch: fn }).chat({
        messages: [{ role: "tool", content: "18°C", toolCallId: "call-1" }],
        tools: [
          {
            name: "get_weather",
            description: "Get weather",
            parameters: { type: "object", properties: { city: { type: "string" } } },
          },
        ],
        temperature: 0.3,
        maxTokens: 256,
      }),
    );

    expect((calls[0]?.body.messages as unknown[])[0]).toEqual({
      role: "tool",
      content: "18°C",
      tool_call_id: "call-1",
    });
    expect(calls[0]?.body.tools).toEqual([
      {
        type: "function",
        function: {
          name: "get_weather",
          description: "Get weather",
          parameters: { type: "object", properties: { city: { type: "string" } } },
        },
      },
    ]);
    expect(calls[0]?.body.temperature).toBe(0.3);
    expect(calls[0]?.body.max_tokens).toBe(256);
  });

  test("`tools` is omitted entirely when the caller passes none", async () => {
    const { fn, calls } = mockFetch(() => streamed(TEXT_STREAM));
    await collect(
      createCloudflareTextProvider(deps(), { fetch: fn }).chat({ ...chat, tools: [] }),
    );
    expect("tools" in (calls[0]?.body ?? {})).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

describe("streaming", () => {
  test("yields text deltas, then a done chunk carrying the turn totals", async () => {
    const { fn } = mockFetch(() => streamed(TEXT_STREAM));
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));

    expect(chunks.map((c) => c.text).filter(Boolean)).toEqual(["你", "好"]);
    expect(chunks.at(-1)).toEqual({
      done: true,
      usage: { promptTokens: 57, completionTokens: 28 },
    });
    expect(chunks.filter((c) => c.done).length).toBe(1);
  });

  test("drops the reasoning trace instead of speaking it", async () => {
    const { fn } = mockFetch(() => streamed(TEXT_STREAM));
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(chunks.some((c) => c.text?.includes("the user wants"))).toBe(false);
  });

  test("the per-chunk usage deltas do not overwrite the turn totals", async () => {
    // The zero-filled `choices: []` heartbeat arrives after the real numbers in
    // some turns; taking the last `usage` seen would report zero tokens.
    const { fn } = mockFetch(() =>
      streamed([
        `data: {"choices":[{"delta":{"content":"a"},"index":0}]}\n\n`,
        `data: {"response":"","usage":{"prompt_tokens":57,"completion_tokens":28}}\n\n`,
        `data: {"choices":[],"usage":{"prompt_tokens":0,"completion_tokens":0}}\n\n`,
        `data: [DONE]\n\n`,
      ]),
    );
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(chunks.at(-1)?.usage).toEqual({ promptTokens: 57, completionTokens: 28 });
  });

  test("reassembles an event split across network reads", async () => {
    const joined = TEXT_STREAM.join("");
    const cut = Math.floor(joined.length / 2);
    const { fn } = mockFetch(() => streamed([joined.slice(0, cut), joined.slice(cut)]));
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(chunks.map((c) => c.text).filter(Boolean)).toEqual(["你", "好"]);
  });

  test("reads one byte at a time without losing or duplicating a delta", async () => {
    const joined = TEXT_STREAM.join("");
    const { fn } = mockFetch(() => streamed([...joined]));
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(chunks.map((c) => c.text).filter(Boolean)).toEqual(["你", "好"]);
  });

  test("accepts CRLF framing", async () => {
    const { fn } = mockFetch(() =>
      streamed([TEXT_STREAM.join("").replaceAll("\n", "\r\n")]),
    );
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(chunks.map((c) => c.text).filter(Boolean)).toEqual(["你", "好"]);
  });

  test("does not drop a final event that has no trailing blank line", async () => {
    const { fn } = mockFetch(() =>
      streamed([
        `data: {"choices":[{"delta":{"content":"末"},"index":0}]}\n\n`,
        `data: {"choices":[{"delta":{"content":"尾"},"index":0}]}`,
      ]),
    );
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(chunks.map((c) => c.text).filter(Boolean)).toEqual(["末", "尾"]);
  });

  test("survives one unparsable frame rather than losing the turn", async () => {
    const logged: string[] = [];
    const { fn } = mockFetch(() =>
      streamed([
        `data: {"choices":[{"delta":{"content":"a"},"index":0}]}\n\n`,
        `data: {not json\n\n`,
        `data: {"choices":[{"delta":{"content":"b"},"index":0}]}\n\n`,
        `data: [DONE]\n\n`,
      ]),
    );
    const provider = createCloudflareTextProvider(
      { ...deps(), log: (_level, message) => logged.push(message) },
      { fetch: fn },
    );
    const chunks = await collect(provider.chat(chat));
    expect(chunks.map((c) => c.text).filter(Boolean)).toEqual(["a", "b"]);
    expect(logged.some((line) => line.includes("unparsable"))).toBe(true);
  });

  test("stops at [DONE] and ignores anything after it", async () => {
    const { fn } = mockFetch(() =>
      streamed([
        `data: {"choices":[{"delta":{"content":"a"},"index":0}]}\n\n`,
        `data: [DONE]\n\n`,
        `data: {"choices":[{"delta":{"content":"ghost"},"index":0}]}\n\n`,
      ]),
    );
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(chunks.map((c) => c.text).filter(Boolean)).toEqual(["a"]);
  });
});

// ---------------------------------------------------------------------------
// Tool calls
// ---------------------------------------------------------------------------

describe("tool calls", () => {
  test("assembles name, id and argument fragments into one call", async () => {
    const { fn } = mockFetch(() => streamed(TOOL_STREAM));
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(chunks.find((c) => c.toolCall)?.toolCall).toEqual({
      callId: "chatcmpl-tool-abc",
      name: "get_weather",
      arguments: { city: "Tokyo" },
    });
  });

  test("keeps parallel calls apart by their index", async () => {
    const { fn } = mockFetch(() =>
      streamed([
        `data: {"choices":[{"delta":{"tool_calls":[{"id":"a","index":0,"function":{"name":"one","arguments":"{\\"x\\":1}"}}]},"index":0}]}\n\n`,
        `data: {"choices":[{"delta":{"tool_calls":[{"id":"b","index":1,"function":{"name":"two","arguments":"{\\"y\\":2}"}}]},"index":0}]}\n\n`,
        `data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}]}\n\n`,
        `data: [DONE]\n\n`,
      ]),
    );
    const calls = (await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat)))
      .map((c) => c.toolCall)
      .filter(Boolean);
    expect(calls).toEqual([
      { callId: "a", name: "one", arguments: { x: 1 } },
      { callId: "b", name: "two", arguments: { y: 2 } },
    ]);
  });

  test("emits a call whose stream ended without a finish_reason", async () => {
    const { fn } = mockFetch(() =>
      streamed([
        `data: {"choices":[{"delta":{"tool_calls":[{"id":"a","index":0,"function":{"name":"one","arguments":"{}"}}]},"index":0}]}\n\n`,
        `data: [DONE]\n\n`,
      ]),
    );
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(chunks.find((c) => c.toolCall)?.toolCall?.name).toBe("one");
  });

  test("a call is emitted once, not again at the end of the stream", async () => {
    const { fn } = mockFetch(() => streamed(TOOL_STREAM));
    const chunks = await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    expect(chunks.filter((c) => c.toolCall).length).toBe(1);
  });

  test("malformed arguments raise a ProviderError, not a JSON SyntaxError", async () => {
    const { fn } = mockFetch(() =>
      streamed([
        `data: {"choices":[{"delta":{"tool_calls":[{"id":"a","index":0,"function":{"name":"one","arguments":"{oops"}}]},"index":0}]}\n\n`,
        `data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}]}\n\n`,
        `data: [DONE]\n\n`,
      ]),
    );
    const attempt = collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
    await expect(attempt).rejects.toBeInstanceOf(ProviderError);
    await expect(attempt).rejects.toThrow(/工具参数/);
  });

  test("arguments that parse to a non-object are rejected too", async () => {
    const { fn } = mockFetch(() =>
      streamed([
        `data: {"choices":[{"delta":{"tool_calls":[{"id":"a","index":0,"function":{"name":"one","arguments":"[1,2]"}}]},"index":0}]}\n\n`,
        `data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}]}\n\n`,
        `data: [DONE]\n\n`,
      ]),
    );
    await expect(
      collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat)),
    ).rejects.toBeInstanceOf(ProviderError);
  });
});

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

describe("error mapping", () => {
  const cases: {
    label: string;
    http: number;
    code?: number;
    status: string;
    retryable: boolean;
    says: RegExp;
  }[] = [
    // Measured: a wrong token and a wrong account id both answer 401/10000.
    { label: "401", http: 401, code: 10000, status: "unauthorized", retryable: false, says: /account ID 或 API token/ },
    // Not measured — this is the read-only-token case from an earlier session.
    { label: "403", http: 403, status: "unauthorized", retryable: false, says: /编辑/ },
    // Measured: a typo'd model id is HTTP 400 with CF code 7000, not a 404.
    { label: "400/7000", http: 400, code: 7000, status: "model_missing", retryable: false, says: /没有这个模型/ },
    { label: "404", http: 404, status: "model_missing", retryable: false, says: /没有这个模型/ },
    { label: "429", http: 429, status: "quota_exhausted", retryable: true, says: /限流或额度用尽/ },
    { label: "500", http: 500, status: "unreachable", retryable: true, says: /服务端故障/ },
    { label: "400 other", http: 400, code: 8007, status: "error", retryable: false, says: /拒绝了这次请求/ },
  ];

  test.each(cases)("$label maps to $status", async ({ http, code, status, retryable, says }) => {
    const { fn } = mockFetch(() => cfError(http, code));
    try {
      await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
      throw new Error("expected a ProviderError");
    } catch (error) {
      expect(error).toBeInstanceOf(ProviderError);
      const providerError = error as ProviderError;
      expect(providerError.status).toBe(status as ProviderError["status"]);
      expect(providerError.retryable).toBe(retryable);
      expect(providerError.message).toMatch(says);
    }
  });

  test("the upstream error body is never forwarded — it can echo the token", async () => {
    const { fn } = mockFetch(() => cfError(401, 10000));
    try {
      await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
      throw new Error("expected a ProviderError");
    } catch (error) {
      const message = (error as ProviderError).message;
      expect(message).not.toContain(TOKEN);
      expect(message).not.toContain("boom");
      // The numeric code is the one thing worth surfacing.
      expect(message).toContain("10000");
    }
  });

  test("an error body that is not JSON still produces a usable message", async () => {
    const { fn } = mockFetch(() => new Response("<html>502</html>", { status: 502 }));
    await expect(
      collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat)),
    ).rejects.toThrow(/服务端故障/);
  });

  test("a transport failure is unreachable, so the router can fall through", async () => {
    const { fn } = mockFetch(() => {
      throw new TypeError("fetch failed");
    });
    try {
      await collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat));
      throw new Error("expected a ProviderError");
    } catch (error) {
      expect((error as ProviderError).status).toBe("unreachable");
      expect((error as ProviderError).retryable).toBe(true);
    }
  });

  test("chatting with no credentials reports unconfigured rather than calling out", async () => {
    const { fn, calls } = mockFetch(() => streamed(TEXT_STREAM));
    try {
      await collect(createCloudflareTextProvider(deps({}), { fetch: fn }).chat(chat));
      throw new Error("expected a ProviderError");
    } catch (error) {
      expect((error as ProviderError).status).toBe("unconfigured");
    }
    expect(calls.length).toBe(0);
  });

  test("an empty response body is an error, not a silent empty turn", async () => {
    const { fn } = mockFetch(() => new Response(null, { status: 200 }));
    await expect(
      collect(createCloudflareTextProvider(deps(), { fetch: fn }).chat(chat)),
    ).rejects.toBeInstanceOf(ProviderError);
  });
});

// ---------------------------------------------------------------------------
// Hanging networks
// ---------------------------------------------------------------------------

describe("the connect deadline", () => {
  test("a network that accepts and then says nothing is reported unreachable", async () => {
    // The failure mode this exists for: a captive portal or a half-dead VPN
    // completes the TCP handshake and then never answers, so `fetch` sits
    // until the system timeout — about 75 s — before the local model gets a
    // turn. "断网就自动切本地" has to mean seconds, not a minute and a quarter.
    const { fn } = mockFetch(
      (_url, init) =>
        new Promise<Response>((_resolve, reject) => {
          init.signal?.addEventListener("abort", () =>
            reject(Object.assign(new Error("aborted"), { name: "AbortError" })),
          );
        }),
    );
    const provider = createCloudflareTextProvider(deps(), {
      fetch: fn,
      connectTimeoutMs: 20,
    });
    const error = await collect(provider.chat(chat)).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ProviderError);
    expect((error as ProviderError).status).toBe("unreachable");
    expect((error as ProviderError).message).toContain("没有应答");
  });

  test("a caller's own abort is still a barge-in, not a failure", async () => {
    // Both signals reach the same `fetch`, so which one fired decides whether
    // this is control flow or a fault.
    const controller = new AbortController();
    const { fn } = mockFetch((_url, init) => {
      // The caller barges in while the connect is still in flight, and wins
      // the race against a deadline that is an order of magnitude away.
      setTimeout(() => controller.abort(), 5);
      return new Promise<Response>((_resolve, reject) => {
        init.signal?.addEventListener("abort", () =>
          reject(Object.assign(new Error("aborted"), { name: "AbortError" })),
        );
      });
    });
    const provider = createCloudflareTextProvider(deps(), {
      fetch: fn,
      connectTimeoutMs: 500,
    });
    expect(await collect(provider.chat({ ...chat, signal: controller.signal }))).toEqual([]);
  });

  test("the deadline is disarmed once headers arrive, so a slow answer survives", async () => {
    // The trap avoided here: `AbortSignal.timeout` keeps counting against the
    // whole request including the body, so a budget meant for the connect
    // phase would silently truncate any answer that took longer to stream.
    const encoder = new TextEncoder();
    let piece = 0;
    const { fn } = mockFetch(
      (_url, init) =>
        new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              // A real `fetch` tears the body down when its signal fires, so
              // the mock has to as well — otherwise a deadline that keeps
              // counting through the body would look harmless here.
              init.signal?.addEventListener("abort", () =>
                controller.error(Object.assign(new Error("aborted"), { name: "AbortError" })),
              );
            },
            async pull(controller) {
              if (piece >= TEXT_STREAM.length) return controller.close();
              await new Promise((resolve) => setTimeout(resolve, 8));
              controller.enqueue(encoder.encode(TEXT_STREAM[piece++]!));
            },
          }),
          { status: 200, headers: { "content-type": "text/event-stream" } },
        ),
    );
    const provider = createCloudflareTextProvider(deps(), {
      fetch: fn,
      connectTimeoutMs: 20,
    });
    const chunks = await collect(provider.chat(chat));
    expect(chunks.map((c) => c.text ?? "").join("")).toBe("你好");
    expect(chunks.at(-1)?.done).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Barge-in
// ---------------------------------------------------------------------------

describe("abort", () => {
  test("an aborted turn ends the stream instead of raising", async () => {
    // Barge-in is control flow: the caller asked to stop and is not waiting for
    // a reason. Raising here would make every call site wrap it in a try.
    const controller = new AbortController();
    controller.abort();
    const { fn } = mockFetch(() => {
      const error = new Error("aborted");
      error.name = "AbortError";
      throw error;
    });
    const chunks = await collect(
      createCloudflareTextProvider(deps(), { fetch: fn }).chat({
        ...chat,
        signal: controller.signal,
      }),
    );
    expect(chunks).toEqual([]);
  });

  test("the caller's abort reaches fetch so the socket actually closes", async () => {
    // Not `toBe(controller.signal)` any more: what goes to `fetch` is the
    // caller's signal composed with the connect deadline, so the property that
    // matters is that a barge-in still aborts it.
    const controller = new AbortController();
    const { fn, calls } = mockFetch(() => streamed(TEXT_STREAM));
    await collect(
      createCloudflareTextProvider(deps(), { fetch: fn }).chat({
        ...chat,
        signal: controller.signal,
      }),
    );
    const handed = calls[0]?.init.signal as AbortSignal;
    expect(handed).toBeInstanceOf(AbortSignal);
    expect(handed.aborted).toBe(false);
    controller.abort();
    expect(handed.aborted).toBe(true);
  });

  test("a mid-stream abort ends the turn quietly", async () => {
    const controller = new AbortController();
    const encoder = new TextEncoder();
    let reads = 0;
    const { fn } = mockFetch(
      () =>
        new Response(
          new ReadableStream<Uint8Array>({
            // The first read delivers a delta; the second is where the caller's
            // abort lands, which is what a real barge-in looks like.
            pull(streamController) {
              if (reads++ === 0) {
                streamController.enqueue(
                  encoder.encode(`data: {"choices":[{"delta":{"content":"a"},"index":0}]}\n\n`),
                );
                return;
              }
              controller.abort();
              streamController.error(
                Object.assign(new Error("aborted"), { name: "AbortError" }),
              );
            },
          }),
          { status: 200 },
        ),
    );
    const chunks = await collect(
      createCloudflareTextProvider(deps(), { fetch: fn }).chat({
        ...chat,
        signal: controller.signal,
      }),
    );
    expect(chunks.map((c) => c.text)).toEqual(["a"]);
    expect(chunks.some((c) => c.done)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// probe
// ---------------------------------------------------------------------------

describe("probe", () => {
  const okRun = () => json({ success: true, result: { choices: [] } }, 200);
  const okQuota = (neurons: number) =>
    json(
      {
        data: {
          viewer: {
            accounts: [{ aiInferenceAdaptiveGroups: [{ sum: { totalNeurons: neurons } }] }],
          },
        },
      },
      200,
    );

  test("names both empty slots so the UI can point at the right field", async () => {
    const { fn, calls } = mockFetch(() => okRun());
    const probe = await createCloudflareTextProvider(deps({}), { fetch: fn }).probe();
    expect(probe.status).toBe("unconfigured");
    expect(probe.missing).toEqual(["cloudflare.accountId", "cloudflare.apiToken"]);
    expect(calls.length).toBe(0);
  });

  test("names only the slot that is actually empty", async () => {
    const { fn } = mockFetch(() => okRun());
    const probe = await createCloudflareTextProvider(
      deps({ CLOUDFLARE_ACCOUNT_ID: ACCOUNT }),
      { fetch: fn },
    ).probe();
    expect(probe.missing).toEqual(["cloudflare.apiToken"]);
  });

  test("runs real inference, because listing models cannot prove Edit access", async () => {
    const { fn, calls } = mockFetch((url) =>
      url.includes("/graphql") ? okQuota(52) : okRun(),
    );
    const probe = await createCloudflareTextProvider(deps(), { fetch: fn }).probe();

    expect(probe.status).toBe("ok");
    expect(probe.ok).toBe(true);
    expect(probe.model).toBe("@cf/qwen/qwen3.8-27b");
    expect(probe.latencyMs).toBeGreaterThanOrEqual(0);
    expect(probe.checkedAt).toBeGreaterThan(0);
    const run = calls.find((call) => call.url.includes("/ai/run/"));
    expect(run?.body.max_tokens).toBe(1);
  });

  test("reports the neurons burnt today, and says what it cannot know", async () => {
    const { fn } = mockFetch((url) => (url.includes("/graphql") ? okQuota(52.7) : okRun()));
    const probe = await createCloudflareTextProvider(deps(), { fetch: fn }).probe();
    expect(probe.quota?.unit).toBe("neurons");
    expect(probe.quota?.used).toBe(53);
    // Cloudflare publishes no allowance through the API; inventing one would be
    // worse than the note.
    expect(probe.quota?.limit).toBeUndefined();
    expect(probe.quota?.remaining).toBeUndefined();
    expect(probe.quota?.resetsAt).toBeGreaterThan(Date.now());
  });

  test("says 额度未知 rather than guessing when analytics is refused", async () => {
    const { fn } = mockFetch((url) =>
      url.includes("/graphql") ? json({ errors: ["nope"] }, 403) : okRun(),
    );
    const probe = await createCloudflareTextProvider(deps(), { fetch: fn }).probe();
    expect(probe.status).toBe("ok");
    expect(probe.quota).toEqual({
      unit: "neurons",
      note: expect.stringContaining("额度余量拿不到"),
    });
  });

  test("a failed quota lookup never fails the probe itself", async () => {
    const { fn } = mockFetch((url) => {
      if (url.includes("/graphql")) throw new TypeError("fetch failed");
      return okRun();
    });
    const probe = await createCloudflareTextProvider(deps(), { fetch: fn }).probe();
    expect(probe.status).toBe("ok");
    expect(probe.quota?.note).toBeDefined();
  });

  test("a read-only token is unauthorized, and the message names the permission", async () => {
    const { fn } = mockFetch((url) =>
      url.includes("/graphql") ? okQuota(0) : cfError(403),
    );
    const probe = await createCloudflareTextProvider(deps(), { fetch: fn }).probe();
    expect(probe.status).toBe("unauthorized");
    expect(probe.ok).toBe(false);
    expect(probe.message).toContain("编辑");
    expect(probe.message).not.toContain(TOKEN);
  });

  test("never throws — a failure is a probe with a status", async () => {
    const { fn } = mockFetch(() => {
      throw new TypeError("fetch failed");
    });
    const probe = await createCloudflareTextProvider(deps(), { fetch: fn }).probe();
    expect(probe.status).toBe("unreachable");
    expect(probe.ok).toBe(false);
    expect(probe.message).toMatch(/连不上/);
  });

  test("a caller's abort signal is passed through to the request", async () => {
    const controller = new AbortController();
    const { fn, calls } = mockFetch((url) =>
      url.includes("/graphql") ? okQuota(0) : okRun(),
    );
    await createCloudflareTextProvider(deps(), { fetch: fn }).probe(controller.signal);
    const run = calls.find((call) => call.url.includes("/ai/run/"));
    expect(run?.init.signal).toBeInstanceOf(AbortSignal);
  });
});
