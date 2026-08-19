import { afterEach, describe, expect, spyOn, test } from "bun:test";
import type { ServerWebSocket } from "bun";
import {
  ALLOW_CUSTOM_ENDPOINT_ENV,
  DEFAULT_REALTIME_ENDPOINT,
  RealtimeClient,
  assertUsableEndpoint,
  configFromEnv,
  type RealtimeCancelInfo,
  type RealtimeFailureInfo,
  type RealtimeResponseInfo,
  type RealtimeTurnAbandonedInfo,
} from "./realtime.ts";

/**
 * The turn-lifecycle tests run against a real WebSocket server speaking the
 * events the live service was observed to send. Mocking the socket would mock
 * away exactly the part these regressions live in.
 */

const cleanups: Array<() => void | Promise<void>> = [];

afterEach(async () => {
  while (cleanups.length) await cleanups.pop()!();
});

/** Minimal stand-in for the Qwen Realtime endpoint. */
class FakeRealtime {
  readonly received: Array<Record<string, unknown>> = [];
  #server: ReturnType<typeof Bun.serve> | null = null;
  #sockets = new Set<ServerWebSocket<undefined>>();

  static start(): FakeRealtime {
    const fake = new FakeRealtime();
    fake.#server = Bun.serve({
      port: 0,
      fetch(request, server) {
        if (server.upgrade(request)) return undefined;
        return new Response("expected a websocket upgrade", { status: 400 });
      },
      websocket: {
        open: (ws: ServerWebSocket<undefined>) => {
          fake.#sockets.add(ws);
          ws.send(
            JSON.stringify({
              type: "session.created",
              session: {
                id: "sess_fake",
                turn_detection: { type: "server_vad" },
              },
            }),
          );
        },
        message: (ws: ServerWebSocket<undefined>, message: string | Buffer) => {
          const event = JSON.parse(String(message)) as Record<string, unknown>;
          fake.received.push(event);
          // Acknowledging session.update is what resolves connect().
          if (event.type === "session.update") {
            ws.send(
              JSON.stringify({
                type: "session.updated",
                session: { id: "sess_fake" },
              }),
            );
          }
        },
        close: (ws: ServerWebSocket<undefined>) => {
          fake.#sockets.delete(ws);
        },
      },
    });
    return fake;
  }

  get url(): string {
    return `ws://127.0.0.1:${this.#server?.port}`;
  }

  /** Push a server event to the connected client. */
  send(event: Record<string, unknown>): void {
    const payload = JSON.stringify(event);
    for (const ws of this.#sockets) ws.send(payload);
  }

  types(): string[] {
    return this.received.map((event) => String(event.type));
  }

  stop(): void {
    this.#server?.stop(true);
    this.#server = null;
  }
}

async function waitFor(
  label: string,
  predicate: () => boolean,
  timeoutMs = 2_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`timed out waiting for ${label}`);
}

/** Collectors for every terminal callback, so a missing one is visible. */
function collectors() {
  const done: RealtimeResponseInfo[] = [];
  const cancelled: RealtimeCancelInfo[] = [];
  const failed: RealtimeFailureInfo[] = [];
  const abandoned: RealtimeTurnAbandonedInfo[] = [];
  const errors: Error[] = [];
  return { done, cancelled, failed, abandoned, errors };
}

// ---------------------------------------------------------------------------
// Endpoint validation
// ---------------------------------------------------------------------------

const REALTIME_PATH = "/api-ws/v1/realtime";

describe("endpoint validation", () => {
  test("accepts the shipped default and the mainland host", () => {
    expect(assertUsableEndpoint(DEFAULT_REALTIME_ENDPOINT, {})).toBe(
      DEFAULT_REALTIME_ENDPOINT,
    );
    const mainland = `wss://dashscope.aliyuncs.com${REALTIME_PATH}`;
    expect(assertUsableEndpoint(mainland, {})).toBe(mainland);
  });

  test("refuses ws:// — the bearer token would go out in cleartext", () => {
    expect(() =>
      assertUsableEndpoint(`ws://dashscope-intl.aliyuncs.com${REALTIME_PATH}`, {}),
    ).toThrow(/wss:/);
    expect(() => assertUsableEndpoint(`https://dashscope-intl.aliyuncs.com`, {})).toThrow(
      /wss:/,
    );
  });

  test("refuses an unexpected host, naming the opt-out", () => {
    expect(() => assertUsableEndpoint("wss://attacker.example/realtime", {})).toThrow(
      new RegExp(ALLOW_CUSTOM_ENDPOINT_ENV),
    );
    // A suffix of an allowed host is still a different host.
    expect(() =>
      assertUsableEndpoint("wss://dashscope-intl.aliyuncs.com.attacker.example/x", {}),
    ).toThrow(/not one of/);
  });

  test("allows an unexpected host with the opt-out, and warns loudly", () => {
    const warn = spyOn(console, "warn").mockImplementation(() => {});
    try {
      const endpoint = "wss://proxy.internal/realtime";
      expect(
        assertUsableEndpoint(endpoint, { [ALLOW_CUSTOM_ENDPOINT_ENV]: "1" }),
      ).toBe(endpoint);
      expect(warn).toHaveBeenCalledTimes(1);
      expect(String(warn.mock.calls[0]?.[0])).toContain("proxy.internal");
    } finally {
      warn.mockRestore();
    }
  });

  test("refuses embedded credentials, a query string, and non-URLs", () => {
    expect(() =>
      assertUsableEndpoint(`wss://user:pw@dashscope-intl.aliyuncs.com${REALTIME_PATH}`, {}),
    ).toThrow(/credentials/);
    // The client appends `?model=`; a second `?` is a malformed URL as well.
    expect(() =>
      assertUsableEndpoint(`wss://dashscope-intl.aliyuncs.com${REALTIME_PATH}?x=1`, {}),
    ).toThrow(/query string/);
    expect(() => assertUsableEndpoint("not a url", {})).toThrow(/not a URL/);
  });

  test("configFromEnv refuses a hijacked DASHSCOPE_REALTIME_ENDPOINT", () => {
    const saved = {
      key: process.env.DASHSCOPE_API_KEY,
      endpoint: process.env.DASHSCOPE_REALTIME_ENDPOINT,
      allow: process.env[ALLOW_CUSTOM_ENDPOINT_ENV],
    };
    try {
      process.env.DASHSCOPE_API_KEY = "sk-not-a-real-key";
      delete process.env[ALLOW_CUSTOM_ENDPOINT_ENV];

      process.env.DASHSCOPE_REALTIME_ENDPOINT = "ws://attacker.example/realtime";
      expect(() => configFromEnv()).toThrow(/wss:/);

      process.env.DASHSCOPE_REALTIME_ENDPOINT = "wss://attacker.example/realtime";
      expect(() => configFromEnv()).toThrow(new RegExp(ALLOW_CUSTOM_ENDPOINT_ENV));

      // The check must survive the overrides spread, not just the env read.
      delete process.env.DASHSCOPE_REALTIME_ENDPOINT;
      expect(() => configFromEnv({ endpoint: "ws://attacker.example" })).toThrow(/wss:/);
      expect(configFromEnv().endpoint).toBe(DEFAULT_REALTIME_ENDPOINT);
    } finally {
      restore("DASHSCOPE_API_KEY", saved.key);
      restore("DASHSCOPE_REALTIME_ENDPOINT", saved.endpoint);
      restore(ALLOW_CUSTOM_ENDPOINT_ENV, saved.allow);
    }
  });
});

function restore(key: string, value: string | undefined): void {
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
}

// ---------------------------------------------------------------------------
// Turn lifecycle
// ---------------------------------------------------------------------------

/** 16 kHz mono PCM16: 32 bytes per millisecond. */
const BYTES_PER_MS = 32;

async function connectClient(handlers = {}) {
  const server = FakeRealtime.start();
  const client = new RealtimeClient(
    // ws:// is fine here on purpose: the constructor takes a config from code,
    // and only configFromEnv reads the attacker-writable environment.
    { apiKey: "test-key", endpoint: server.url },
    handlers,
  );
  cleanups.push(async () => {
    await client.close();
    server.stop();
  });
  await client.connect();
  expect(client.connected).toBe(true);
  return { server, client };
}

describe("abandoned turns", () => {
  test("a commit with no live session reports back instead of stalling", () => {
    const c = collectors();
    const client = new RealtimeClient(
      { apiKey: "test-key" },
      { onTurnAbandoned: (info) => c.abandoned.push(info) },
    );
    expect(client.connected).toBe(false);

    client.commitAudio();

    // Without this the avatar stays in `thinking` forever and the user cannot
    // tell "not connected" from "still thinking".
    expect(c.abandoned).toEqual([{ reason: "not_connected", bufferedMillis: 0 }]);
  });

  test("a press below the 100ms server minimum reports back", async () => {
    const c = collectors();
    const { server, client } = await connectClient({
      onTurnAbandoned: (info: RealtimeTurnAbandonedInfo) => c.abandoned.push(info),
    });

    client.appendAudio(new Uint8Array(10 * BYTES_PER_MS));
    client.commitAudio();

    expect(c.abandoned).toEqual([{ reason: "too_short", bufferedMillis: 10 }]);
    // Sentinel: frames are ordered on one socket, so once this later frame has
    // landed anything the commit would have sent has landed too.
    client.setTools([]);
    await waitFor("the sentinel frame", () => {
      const types = server.types();
      return types.filter((type) => type === "session.update").length === 2;
    });
    expect(server.types()).not.toContain("input_audio_buffer.commit");
    expect(server.types()).not.toContain("response.create");
  });

  test("a long-enough press commits and asks for a reply", async () => {
    const c = collectors();
    const { server, client } = await connectClient({
      onTurnAbandoned: (info: RealtimeTurnAbandonedInfo) => c.abandoned.push(info),
    });

    client.appendAudio(new Uint8Array(150 * BYTES_PER_MS));
    client.commitAudio();

    expect(c.abandoned).toEqual([]);
    await waitFor("commit + response.create", () =>
      server.types().includes("response.create"),
    );
    expect(server.types()).toContain("input_audio_buffer.commit");
  });

  /**
   * Pausing mid-sentence is one of the most ordinary ways to talk, and with
   * `silence_duration_ms: 800` the server commits and starts answering while
   * the key is still held. The release that follows only sees the bytes
   * recorded since that commit — which must not be read as "you barely said
   * anything", because she is already answering. Getting this wrong pops
   * "没听清" over a reply that is on its way and invites the user to press
   * again, which is what would really cut her off.
   */
  test("a pause mid-press is not reported as a turn nobody heard", async () => {
    const c = collectors();
    const transcripts: string[] = [];
    const { server, client } = await connectClient({
      onTurnAbandoned: (info: RealtimeTurnAbandonedInfo) => c.abandoned.push(info),
      onOutputTranscript: (text: string) => transcripts.push(text),
    });

    // Key down, two seconds of speech, then the user pauses.
    client.appendAudio(new Uint8Array(2_000 * BYTES_PER_MS));
    await serverVadTookOver(server, () => transcripts.length > 0);

    // Still holding the key; a few frames of room tone land after the commit.
    client.appendAudio(new Uint8Array(40 * BYTES_PER_MS));
    client.commitAudio();

    expect(c.abandoned).toEqual([]);
    // 40ms is below the server minimum, so nothing may be sent either — a
    // commit of it would only bounce back as an error event.
    client.setTools([]);
    await waitFor("the sentinel frame", () =>
      server.types().filter((type) => type === "session.update").length === 2,
    );
    expect(server.types()).not.toContain("input_audio_buffer.commit");
    expect(server.types()).not.toContain("response.create");

    // ...and the next press is judged on its own: a genuinely short one still
    // reports back, so the fix above cannot swallow the stall it replaced.
    client.appendAudio(new Uint8Array(10 * BYTES_PER_MS));
    client.commitAudio();
    expect(c.abandoned).toEqual([{ reason: "too_short", bufferedMillis: 10 }]);
  });

  test("speech after a mid-press pause is committed onto the live response", async () => {
    const c = collectors();
    const transcripts: string[] = [];
    const { server, client } = await connectClient({
      onTurnAbandoned: (info: RealtimeTurnAbandonedInfo) => c.abandoned.push(info),
      onOutputTranscript: (text: string) => transcripts.push(text),
    });

    client.appendAudio(new Uint8Array(2_000 * BYTES_PER_MS));
    await serverVadTookOver(server, () => transcripts.length > 0);

    // The user kept talking after the pause: that audio does need committing.
    client.appendAudio(new Uint8Array(300 * BYTES_PER_MS));
    client.commitAudio();

    expect(c.abandoned).toEqual([]);
    await waitFor("the commit", () =>
      server.types().includes("input_audio_buffer.commit"),
    );
    // A response is already running, so asking for a second one would double it.
    expect(server.types()).not.toContain("response.create");
  });
});

/**
 * Play the events server VAD raises when it endpoints mid-press, and wait until
 * the client has actually handled them: frames are ordered on one socket, so
 * the transcript delta landing proves the three before it were processed.
 */
async function serverVadTookOver(
  server: FakeRealtime,
  sentinelSeen: () => boolean,
): Promise<void> {
  server.send({ type: "input_audio_buffer.speech_stopped" });
  server.send({ type: "input_audio_buffer.committed", item_id: "item_1" });
  server.send({ type: "response.created", response: { id: "resp_vad" } });
  server.send({ type: "response.audio_transcript.delta", delta: "嗯" });
  await waitFor("server VAD to take the turn", sentinelSeen);
}

describe("failed responses", () => {
  const failure = {
    type: "response.done",
    response: {
      id: "resp_1",
      status: "failed",
      status_details: {
        error: { message: "Requests rate limit exceeded", code: "rate_limit_exceeded" },
      },
    },
  };

  test("a failed reply ends the turn instead of leaving her talking", async () => {
    const c = collectors();
    const { server, client } = await connectClient({
      onResponseDone: (info: RealtimeResponseInfo) => c.done.push(info),
      onResponseCancelled: (info: RealtimeCancelInfo) => c.cancelled.push(info),
      onResponseFailed: (info: RealtimeFailureInfo) => c.failed.push(info),
      onError: (error: Error) => c.errors.push(error),
    });

    server.send({ type: "response.created", response: { id: "resp_1" } });
    server.send({
      type: "response.audio.delta",
      delta: Buffer.from(new Uint8Array(480)).toString("base64"),
    });
    server.send(failure);

    await waitFor("the failure to be reported", () => c.failed.length > 0);
    expect(c.failed).toEqual([
      {
        responseId: "resp_1",
        message: "Requests rate limit exceeded",
        code: "rate_limit_exceeded",
        // The stream that was already opened has to be dropped, not closed.
        hadAudio: true,
      },
    ]);
    expect(c.done).toEqual([]);
    expect(c.cancelled).toEqual([]);
    // onError still fires, so the core log keeps the reason.
    expect(c.errors.map((error) => error.message)).toEqual([
      "Requests rate limit exceeded",
    ]);
    expect(client.connected).toBe(true);
  });

  test("a consumer without onResponseFailed still gets a terminal callback", async () => {
    const c = collectors();
    const { server } = await connectClient({
      onResponseDone: (info: RealtimeResponseInfo) => c.done.push(info),
      onResponseCancelled: (info: RealtimeCancelInfo) => c.cancelled.push(info),
      onError: (error: Error) => c.errors.push(error),
    });

    server.send({ type: "response.created", response: { id: "resp_1" } });
    server.send(failure);

    await waitFor("the fallback terminator", () => c.cancelled.length > 0);
    expect(c.cancelled).toEqual([{ responseId: "resp_1", reason: "failed" }]);
    expect(c.done).toEqual([]);
  });

  test("a cancelled reply still reports cancellation, not failure", async () => {
    const c = collectors();
    const { server } = await connectClient({
      onResponseCancelled: (info: RealtimeCancelInfo) => c.cancelled.push(info),
      onResponseFailed: (info: RealtimeFailureInfo) => c.failed.push(info),
      onError: (error: Error) => c.errors.push(error),
    });

    server.send({ type: "response.created", response: { id: "resp_2" } });
    server.send({
      type: "response.done",
      response: {
        id: "resp_2",
        status: "cancelled",
        status_details: { reason: "turn_detected" },
      },
    });

    await waitFor("the cancellation", () => c.cancelled.length > 0);
    expect(c.cancelled).toEqual([{ responseId: "resp_2", reason: "turn_detected" }]);
    expect(c.failed).toEqual([]);
    expect(c.errors).toEqual([]);
  });
});
