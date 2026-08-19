import { describe, expect, test } from "bun:test";
import { CredentialResolver } from "./credentials.ts";
import {
  SettingsService,
  checkDashScopeKey,
  classifyVoiceFailure,
  dashscopeKeyCheckUrl,
  type VoiceKeyVerdict,
  type VoiceSession,
} from "./settings.ts";
import { TextRouter } from "./providers/router.ts";
import type { CredentialValue, SettingsStatePayload } from "./protocol.ts";
import {
  ProviderError,
  type ChatChunk,
  type ProviderProbe,
  type TextProvider,
  type TextProviderId,
} from "./providers/types.ts";

/**
 * Everything here runs without a socket, a key or a GPU. That is the point:
 * the branches that matter most on this screen are the ones a machine with a
 * working configuration can never reach.
 */

class StubProvider implements TextProvider {
  probeResult: ProviderProbe;
  probeCalls = 0;
  constructor(
    readonly id: TextProviderId,
    readonly model: string,
    probe: ProviderProbe,
  ) {
    this.probeResult = probe;
  }
  readonly capabilities = {
    vision: true,
    tools: true,
    streaming: true,
    contextTokens: 1024,
    local: false,
  };
  async *chat(): AsyncIterable<ChatChunk> {
    throw new ProviderError(this.id, "error", "not used here");
  }
  async probe(): Promise<ProviderProbe> {
    this.probeCalls += 1;
    return this.probeResult;
  }
}

class StubVoice implements VoiceSession {
  readonly model = "qwen3.5-omni-flash-realtime";
  live = false;
  error: string | null = null;
  /** Rejection for the next `ensureConnected`, if any. */
  failWith: string | null = null;
  connects = 0;

  connected(): boolean {
    return this.live;
  }
  configError(): string | null {
    return this.error;
  }
  async ensureConnected(): Promise<void> {
    this.connects += 1;
    if (this.failWith) throw new Error(this.failWith);
    this.live = true;
  }
}

interface Harness {
  settings: SettingsService;
  voice: StubVoice;
  router: TextRouter;
  cloud: StubProvider;
  local: StubProvider;
  pushes: SettingsStatePayload[];
  changed: string[][];
  /** Queue of answers `refreshCredentials` will get, in order. */
  answers: (CredentialValue[] | null)[];
  asked: string[][];
  /** What the stubbed DashScope key check answers. Never reaches the network. */
  verify: { verdict: VoiceKeyVerdict; calls: string[] };
}

function harness(env: Record<string, string | undefined> = {}): Harness {
  const credentials = new CredentialResolver(env);
  const cloud = new StubProvider("cloudflare-workers-ai", "@cf/qwen/qwen3.8-27b", {
    status: "ok",
    ok: true,
    model: "@cf/qwen/qwen3.8-27b",
    checkedAt: 5,
  });
  const local = new StubProvider("local-mlx", "local", {
    status: "model_missing",
    ok: false,
    message: "权重还没下完。",
    model: "local",
    checkedAt: 5,
  });
  const pushes: SettingsStatePayload[] = [];
  const changed: string[][] = [];
  const answers: (CredentialValue[] | null)[] = [];
  const asked: string[][] = [];
  const voice = new StubVoice();
  // `unknown` rather than `ok`: a stub that says "the key is fine" would quietly
  // turn every unrelated test into a green one. Each test that cares sets it.
  const verify: { verdict: VoiceKeyVerdict; calls: string[] } = { verdict: "unknown", calls: [] };
  const router = new TextRouter({ providers: [cloud, local] });
  const settings = new SettingsService({
    credentials,
    router,
    voice,
    envFiles: [{ path: "/tmp/.env", loaded: true }],
    requestCredentials: async (slots) => {
      asked.push([...slots]);
      const next = answers.shift();
      return next === undefined ? [] : next;
    },
    publish: (state) => pushes.push(state),
    onCredentialsChanged: (slots) => changed.push([...slots]),
    verifyVoiceKey: async (key) => {
      verify.calls.push(key);
      return verify.verdict;
    },
  });
  // The router's own changes have to reach the same publisher the core wires up.
  router.state();
  return { settings, voice, router, cloud, local, pushes, changed, answers, asked, verify };
}

function voiceRow(state: SettingsStatePayload) {
  return state.routes.find((r) => r.route === "voice")!.candidates[0]!;
}

function textRoute(state: SettingsStatePayload) {
  return state.routes.find((r) => r.route === "text")!;
}

describe("the voice row", () => {
  test("no key at all is `unconfigured`, and names the slot to fill", () => {
    const h = harness({});
    const row = voiceRow(h.settings.state());
    expect(row.status).toBe("unconfigured");
    expect(row.missing).toEqual(["dashscope.apiKey"]);
    expect(row.model).toBe("qwen3.5-omni-flash-realtime");
    // Never probed, so §3.9 says 0 rather than a plausible-looking timestamp.
    expect(row.checkedAt).toBe(0);
  });

  test("a cleared key is distinguishable from one that was never set", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-from-env" });
    h.answers.push([{ slot: "dashscope.apiKey", state: "cleared" }]);
    await h.settings.refreshCredentials(["dashscope.apiKey"]);
    const row = voiceRow(h.settings.state());
    expect(row.status).toBe("unconfigured");
    expect(row.message).toContain("清空");
  });

  test("a live session reads `ok` without anybody probing", () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-from-env" });
    h.voice.live = true;
    expect(voiceRow(h.settings.state()).status).toBe("ok");
    expect(h.settings.state().routes[0]!.active).toBe("dashscope-realtime");
  });

  test("a session that cannot be built is `error`, and the raw reason stays in the log", () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-from-env" });
    h.voice.error = "wss://attacker.example is not an allowed host";
    const row = voiceRow(h.settings.state());
    expect(row.status).toBe("error");
    // §3.9: never relay the upstream text — it can name an endpoint or echo a
    // header. The user gets a pointer, the log gets the detail.
    expect(row.message).not.toContain("attacker.example");
  });

  test("probing without a key never opens a session", async () => {
    const h = harness({});
    const result = await h.settings.handleProbe({ route: "voice" });
    expect(result.results[0]!.status).toBe("unconfigured");
    expect(h.voice.connects).toBe(0);
  });

  test("a probe that connects reports ok with a latency", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-from-env" });
    const result = await h.settings.handleProbe({ route: "voice" });
    expect(result.results[0]!.status).toBe("ok");
    expect(result.results[0]!.latencyMs).toBeGreaterThanOrEqual(0);
    expect(h.voice.connects).toBe(1);
  });

  test("a rejected key is reported as `unauthorized`, not as a network fault", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-from-env" });
    h.voice.failWith = "handshake failed with HTTP 401 Unauthorized";
    const result = await h.settings.handleProbe({ route: "voice" });
    expect(result.results[0]!.status).toBe("unauthorized");
    expect(result.results[0]!.message).toContain("key");
  });

  test("classifyVoiceFailure separates the four things the user can do about it", () => {
    expect(classifyVoiceFailure("unexpected server response: 403")).toBe("unauthorized");
    expect(classifyVoiceFailure("Invalid API key provided")).toBe("unauthorized");
    expect(classifyVoiceFailure("429 rate limit exceeded")).toBe("quota_exhausted");
    expect(classifyVoiceFailure("realtime connect timed out after 5000ms")).toBe("unreachable");
    expect(classifyVoiceFailure("getaddrinfo ENOTFOUND dashscope")).toBe("unreachable");
    expect(classifyVoiceFailure("something nobody predicted")).toBe("error");
  });

  // The two strings below are not invented. Both were measured against the live
  // DashScope endpoint on 2026-08-19 and passed through the exact wrapper in
  // `RealtimeClient.openSocket`: a deliberately invalid key closes 1002 with
  // reason "Expected 101 status code", an unresolvable host closes 1006 with
  // "Failed to connect". Before this branch existed the first one matched
  // `closed` and the user was sent to check their wifi.
  test("a handshake DashScope answered is not a network fault", () => {
    expect(
      classifyVoiceFailure("realtime socket closed during handshake: Expected 101 status code"),
    ).toBe("unauthorized");
    expect(
      classifyVoiceFailure("realtime socket closed during handshake: Failed to connect"),
    ).toBe("unreachable");
  });

  test("a rejected handshake is confirmed against DashScope over HTTP", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-from-env" });
    h.voice.failWith = "realtime socket closed during handshake: Expected 101 status code";
    h.verify.verdict = "unauthorized";
    const result = await h.settings.handleProbe({ route: "voice" });
    expect(result.results[0]!.status).toBe("unauthorized");
    expect(h.verify.calls).toEqual(["sk-from-env"]);
  });

  test("a handshake refused for a key that checks out is not blamed on the key", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-from-env" });
    h.voice.failWith = "realtime socket closed during handshake: Expected 101 status code";
    h.verify.verdict = "ok";
    const result = await h.settings.handleProbe({ route: "voice" });
    // The socket was refused but the key is good — telling the user to go
    // replace a working key is the mirror image of the bug being fixed.
    expect(result.results[0]!.status).toBe("error");
    expect(result.results[0]!.message).toContain("有效");
  });

  test("an unreachable endpoint is never re-asked over HTTP", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-from-env" });
    h.voice.failWith = "realtime socket closed during handshake: Failed to connect";
    const result = await h.settings.handleProbe({ route: "voice" });
    expect(result.results[0]!.status).toBe("unreachable");
    expect(h.verify.calls).toEqual([]);
  });
});

/**
 * The case the "保存并测试" button used to get wrong: a session is already up,
 * so `ensureConnected` returns immediately and the row went green — while the
 * key the user had just pasted had never been shown to DashScope at all
 * (`RealtimeClient.setApiKey` waits for the next turn boundary before adopting
 * one).
 */
describe("probing while a session is already live", () => {
  test("the stored key is actually tested, not assumed from the open socket", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-from-env" });
    h.voice.live = true;
    h.verify.verdict = "ok";
    const result = await h.settings.handleProbe({ route: "voice" });
    expect(result.results[0]!.status).toBe("ok");
    expect(h.verify.calls).toEqual(["sk-from-env"]);
    // `ensureConnected` was still called — and in production it returns without
    // dialling, which is exactly why the HTTP check above is the only real test.
    expect(h.voice.connects).toBe(1);
  });

  test("a rejected stored key reads `unauthorized` even though the old session is still up", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-old" });
    h.voice.live = true;
    h.answers.push([{ slot: "dashscope.apiKey", state: "set", value: "sk-new-and-wrong" }]);
    await h.settings.refreshCredentials(["dashscope.apiKey"]);
    h.verify.verdict = "unauthorized";
    const result = await h.settings.handleProbe({ route: "voice" });
    expect(h.verify.calls).toEqual(["sk-new-and-wrong"]);
    expect(result.results[0]!.status).toBe("unauthorized");
    expect(result.results[0]!.message).toContain("旧 key");
    // And the snapshot agrees, so the window is not left showing a green row
    // beside a red probe result.
    expect(voiceRow(h.settings.state()).status).toBe("unauthorized");
    expect(h.settings.state().routes[0]!.active).toBeNull();
  });

  test("a key that could not be re-checked stays green but says so", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-from-env" });
    h.voice.live = true;
    h.verify.verdict = "unknown";
    const result = await h.settings.handleProbe({ route: "voice" });
    expect(result.results[0]!.status).toBe("ok");
    expect(result.results[0]!.message).toContain("没能复核");
  });

  test("a verdict about the old key is dropped once the key changes", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-bad" });
    h.voice.live = true;
    h.verify.verdict = "unauthorized";
    await h.settings.handleProbe({ route: "voice" });
    expect(voiceRow(h.settings.state()).status).toBe("unauthorized");

    h.answers.push([{ slot: "dashscope.apiKey", state: "set", value: "sk-fresh" }]);
    await h.settings.refreshCredentials(["dashscope.apiKey"]);
    // Nobody has tested `sk-fresh`. Keeping the old accusation on screen would
    // send the user round the same loop with a key that may be fine.
    expect(voiceRow(h.settings.state()).status).toBe("ok");
    expect(voiceRow(h.settings.state()).message).toBeUndefined();
  });
});

describe("checking a DashScope key over HTTP", () => {
  test("the key never travels in the URL, only in the header", async () => {
    let seen: { url: string; auth: string | null } | null = null;
    const verdict = await checkDashScopeKey("sk-secret-value", 5_000, {
      env: {},
      fetchImpl: async (input, init) => {
        seen = {
          url: String(input),
          auth: new Headers(init?.headers).get("authorization"),
        };
        return new Response("{}", { status: 200 });
      },
    });
    expect(verdict).toBe("ok");
    expect(seen!.url).toBe("https://dashscope-intl.aliyuncs.com/api/v1/models");
    expect(seen!.url).not.toContain("sk-secret-value");
    expect(seen!.auth).toBe("Bearer sk-secret-value");
  });

  test("status codes map to the thing the user has to do", async () => {
    const answer = (status: number) =>
      checkDashScopeKey("sk-x", 5_000, {
        env: {},
        fetchImpl: async () => new Response("{}", { status }),
      });
    // 401 is what the live service returned for an `sk-` shaped fake on
    // 2026-08-19; 200 is what it returned for a working key.
    expect(await answer(401)).toBe("unauthorized");
    expect(await answer(403)).toBe("unauthorized");
    expect(await answer(429)).toBe("quota_exhausted");
    expect(await answer(200)).toBe("ok");
    // A 500 is DashScope being unhappy about itself. Not a verdict on the key.
    expect(await answer(500)).toBe("unknown");
  });

  test("a network failure is `unknown`, never a verdict on the key", async () => {
    const verdict = await checkDashScopeKey("sk-x", 5_000, {
      env: {},
      fetchImpl: async () => {
        throw new Error("getaddrinfo ENOTFOUND");
      },
    });
    expect(verdict).toBe("unknown");
  });

  test("the key is not sent to a host realtime.ts would not dial", async () => {
    expect(dashscopeKeyCheckUrl({})).toBe(
      "https://dashscope-intl.aliyuncs.com/api/v1/models",
    );
    expect(
      dashscopeKeyCheckUrl({
        DASHSCOPE_REALTIME_ENDPOINT: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
      }),
    ).toBe("https://dashscope.aliyuncs.com/api/v1/models");
    // AKARI_ALLOW_CUSTOM_ENDPOINT lets the *socket* go elsewhere. It is not
    // permission to invent an HTTP path on that host and post the key to it.
    expect(
      dashscopeKeyCheckUrl({
        DASHSCOPE_REALTIME_ENDPOINT: "wss://attacker.example/api-ws/v1/realtime",
        AKARI_ALLOW_CUSTOM_ENDPOINT: "1",
      }),
    ).toBeNull();
    expect(dashscopeKeyCheckUrl({ DASHSCOPE_REALTIME_ENDPOINT: "not a url" })).toBeNull();
  });

  test("a custom endpoint means the live session is checked by nothing else", async () => {
    const verdict = await checkDashScopeKey("sk-x", 5_000, {
      env: { DASHSCOPE_REALTIME_ENDPOINT: "wss://attacker.example/api-ws/v1/realtime" },
      fetchImpl: async () => {
        throw new Error("fetch must not be reached");
      },
    });
    expect(verdict).toBe("unknown");
  });
});

describe("settings.set", () => {
  test("an unknown provider changes nothing and is refused", () => {
    const h = harness({});
    expect(h.settings.handleSet({ route: "text", provider: "openai" })).toBeNull();
    expect(textRoute(h.settings.state()).selected).toBe("auto");
    expect(h.pushes).toHaveLength(0);
  });

  test("the voice route accepts only its one candidate", () => {
    const h = harness({});
    expect(h.settings.handleSet({ route: "voice", provider: "local-mlx" })).toBeNull();
    expect(h.settings.handleSet({ route: "voice", provider: "dashscope-realtime" })).not.toBeNull();
    expect(h.settings.state().routes[0]!.selected).toBe("dashscope-realtime");
  });

  test("pinning the text route is reflected in the answer", () => {
    const h = harness({});
    const state = h.settings.handleSet({ route: "text", provider: "local-mlx" });
    expect(textRoute(state!).selected).toBe("local-mlx");
    expect(textRoute(state!).active).toBe("local-mlx");
  });
});

describe("credentials", () => {
  test("a `set` value beats `.env`, and only the slots asked about are touched", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-env", CLOUDFLARE_ACCOUNT_ID: "acct-env" });
    h.answers.push([{ slot: "dashscope.apiKey", state: "set", value: "sk-app" }]);
    const changed = await h.settings.refreshCredentials(["dashscope.apiKey"]);
    expect(changed).toEqual(["dashscope.apiKey"]);
    expect(h.asked).toEqual([["dashscope.apiKey"]]);
    const credentials = h.settings.state().credentials;
    expect(credentials.find((c) => c.slot === "dashscope.apiKey")!.source).toBe("app");
    expect(credentials.find((c) => c.slot === "cloudflare.accountId")!.source).toBe("env");
  });

  test("the same value in both places is not a change, so nothing is rebuilt", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-same" });
    h.answers.push([{ slot: "dashscope.apiKey", state: "set", value: "sk-same" }]);
    expect(await h.settings.refreshCredentials(["dashscope.apiKey"])).toEqual([]);
    // This is the case that would otherwise cost a live Realtime session
    // (§8.5) the moment a user copies their .env key into the settings window.
    expect(h.changed).toEqual([]);
  });

  test("`cleared` suppresses the .env fallback; `unset` does not", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-env", CLOUDFLARE_API_TOKEN: "tok-env" });
    h.answers.push([
      { slot: "dashscope.apiKey", state: "cleared" },
      { slot: "cloudflare.apiToken", state: "unset" },
    ]);
    await h.settings.refreshCredentials(["dashscope.apiKey", "cloudflare.apiToken"]);
    const credentials = h.settings.state().credentials;
    const dash = credentials.find((c) => c.slot === "dashscope.apiKey")!;
    expect(dash.source).toBe("unset");
    expect(dash.cleared).toBe(true);
    expect(credentials.find((c) => c.slot === "cloudflare.apiToken")!.source).toBe("env");
  });

  test("`denied` falls back to .env but is still reported", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-env" });
    h.answers.push([{ slot: "dashscope.apiKey", state: "denied" }]);
    await h.settings.refreshCredentials(["dashscope.apiKey"]);
    const dash = h.settings.state().credentials.find((c) => c.slot === "dashscope.apiKey")!;
    // A locked Keychain must not take voice down when .env has a key.
    expect(dash.source).toBe("env");
    expect(dash.denied).toBe(true);
  });

  test("no answer at all keeps the values already in hand", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-env" });
    h.answers.push([{ slot: "dashscope.apiKey", state: "set", value: "sk-app" }]);
    await h.settings.refreshCredentials(["dashscope.apiKey"]);
    h.answers.push(null); // the app dropped, or took longer than 5s
    expect(await h.settings.refreshCredentials(["dashscope.apiKey"])).toEqual([]);
    // Still the app's value: reverting to .env here would silently move billing
    // back to another account (§八 "app 断线").
    expect(
      h.settings.state().credentials.find((c) => c.slot === "dashscope.apiKey")!.source,
    ).toBe("app");
  });
});

describe("when a settings.state is pushed", () => {
  test("a status change pushes; a repeat of the same picture does not", async () => {
    const h = harness({ CLOUDFLARE_ACCOUNT_ID: "a", CLOUDFLARE_API_TOKEN: "b" });
    await h.settings.handleProbe({ route: "text", provider: "cloudflare-workers-ai" });
    expect(h.pushes.length).toBe(1);
    await h.settings.handleProbe({ route: "text", provider: "cloudflare-workers-ai" });
    // Same verdict, new latency and timestamp — not news (§3.9 lists what is).
    expect(h.pushes.length).toBe(1);
  });

  test("a credential moving pushes even when no route changed", async () => {
    const h = harness({ DASHSCOPE_API_KEY: "sk-env" });
    h.answers.push([{ slot: "huggingface.token", state: "set", value: "hf-app" }]);
    await h.settings.refreshCredentials(["huggingface.token"]);
    expect(h.pushes.length).toBe(1);
    expect(
      h.pushes[0]!.credentials.find((c) => c.slot === "huggingface.token")!.source,
    ).toBe("app");
  });

  test("publishNow sends even when nothing changed, for a freshly attached app", () => {
    const h = harness({});
    h.settings.publish();
    expect(h.pushes).toHaveLength(0);
    h.settings.publishNow();
    expect(h.pushes).toHaveLength(1);
  });

  test("the snapshot carries the env files the core actually read", () => {
    const h = harness({});
    expect(h.settings.state().envFiles).toEqual([{ path: "/tmp/.env", loaded: true }]);
  });
});
