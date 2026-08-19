import { describe, expect, test } from "bun:test";
import type { LogLevel, RouteState } from "../protocol.ts";
import { TextRouter, type RouterConfig } from "./router.ts";
import {
  ProviderError,
  type ChatChunk,
  type ProviderProbe,
  type TextProvider,
  type TextProviderId,
} from "./types.ts";

/**
 * The router is tested against mock providers only. Nothing here opens a
 * socket, and the clock is injected, so a 15 minute backoff is one assignment.
 */

/** What one `chat()` call should do. Reused for every call past the last. */
type Turn =
  | { say: string }
  | { fail: ProviderError }
  /** Yield something, then fail — the case where failing over would splice. */
  | { say: string; then: ProviderError }
  /** Never produce anything and never end: a network that hung, not one that
   *  refused. Honours the signal the router hands down, so the abort is what
   *  ends it. */
  | { hang: true }
  /** Yield, then hang: the mid-stream stall. */
  | { say: string; thenHang: true };

class MockProvider implements TextProvider {
  chatCalls = 0;
  probeCalls = 0;
  closeCalls = 0;
  probeResult: ProviderProbe;

  /** Signals the router handed down, newest last. */
  readonly signals: (AbortSignal | undefined)[] = [];

  constructor(
    readonly id: TextProviderId,
    readonly model: string,
    private readonly turns: Turn[],
  ) {
    this.probeResult = { status: "ok", ok: true, model, checkedAt: 1 };
    // `local` drives the attempt budget (only network providers get one), so
    // it has to be the real answer rather than a constant.
    this.capabilities = {
      vision: true,
      tools: true,
      streaming: true,
      contextTokens: 1024,
      local: id === "local-mlx",
    };
  }

  readonly capabilities: {
    vision: boolean;
    tools: boolean;
    streaming: boolean;
    contextTokens: number;
    local: boolean;
  };

  async *chat(request?: { signal?: AbortSignal }): AsyncIterable<ChatChunk> {
    const turn = this.turns[Math.min(this.chatCalls, this.turns.length - 1)];
    this.chatCalls += 1;
    this.signals.push(request?.signal);
    if (!turn) throw new Error("mock provider has no turn scripted");
    if ("say" in turn) yield { text: turn.say };
    if ("fail" in turn) throw turn.fail;
    if ("then" in turn && turn.then) throw turn.then;
    if ("hang" in turn || "thenHang" in turn) {
      await new Promise<void>((resolve) => {
        request?.signal?.addEventListener("abort", () => resolve(), { once: true });
      });
      return;
    }
    yield { done: true };
  }

  async probe(): Promise<ProviderProbe> {
    this.probeCalls += 1;
    return this.probeResult;
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
  }
}

const unreachable = (id: string) => new ProviderError(id, "unreachable", "网络不可用。");
const quotaGone = (id: string) => new ProviderError(id, "quota_exhausted", "额度用尽。");
const malformed = (id: string) => new ProviderError(id, "error", "请求有问题。");
const noWeights = (id: string) => new ProviderError(id, "model_missing", "权重还没下完。");

function collect(stream: AsyncIterable<ChatChunk>): Promise<string> {
  return (async () => {
    let text = "";
    for await (const chunk of stream) text += chunk.text ?? "";
    return text;
  })();
}

interface Harness {
  router: TextRouter;
  cloud: MockProvider;
  local: MockProvider;
  states: RouteState[];
  notices: { level: LogLevel; text: string }[];
  advance(ms: number): void;
}

function harness(
  cloudTurns: Turn[],
  localTurns: Turn[] = [{ say: "本地" }],
  config?: Partial<RouterConfig>,
): Harness {
  const cloud = new MockProvider("cloudflare-workers-ai", "@cf/qwen/qwen3.8-27b", cloudTurns);
  const local = new MockProvider("local-mlx", "local", localTurns);
  const states: RouteState[] = [];
  const notices: { level: LogLevel; text: string }[] = [];
  let clock = 1_000_000;
  const router = new TextRouter({
    providers: [cloud, local],
    now: () => clock,
    onChange: (state) => states.push(state),
    onNotice: (level, text) => notices.push({ level, text }),
    // The clock is injected but the attempt budget runs on real timers, so the
    // default 15 s would be 15 s of wall time. Every test that wants the
    // budget passes its own; the rest just need it out of the way.
    config: { attemptTimeoutMs: 0, ...config },
  });
  return {
    router,
    cloud,
    local,
    states,
    notices,
    advance: (ms) => {
      clock += ms;
    },
  };
}

const request = { messages: [{ role: "user" as const, content: "hi" }] };

describe("selection", () => {
  test("auto serves the first candidate", async () => {
    const h = harness([{ say: "云端" }]);
    expect(await collect(h.router.chat(request))).toBe("云端");
    expect(h.local.chatCalls).toBe(0);
    expect(h.router.state().active).toBe("cloudflare-workers-ai");
  });

  test("an unknown provider is refused and changes nothing", () => {
    const h = harness([{ say: "云端" }]);
    expect(h.router.select("openai")).toBe(false);
    expect(h.router.state().selected).toBe("auto");
    expect(h.states).toHaveLength(0);
  });

  test("pinning one provider lets the others release what they hold", () => {
    const h = harness([{ say: "云端" }]);
    expect(h.router.select("local-mlx")).toBe(true);
    expect(h.cloud.closeCalls).toBe(1);
    expect(h.router.state().active).toBe("local-mlx");
  });

  test("a pinned route does not fall back", async () => {
    // Someone who pinned the local model did it to keep the request off the
    // network; quietly using Cloudflare instead would defeat the point.
    const h = harness([{ say: "云端" }], [{ fail: unreachable("local-mlx") }]);
    h.router.select("local-mlx");
    await expect(collect(h.router.chat(request))).rejects.toThrow("网络不可用。");
    expect(h.cloud.chatCalls).toBe(0);
  });
});

describe("falling back", () => {
  test("an unreachable provider falls through to the local one", async () => {
    const h = harness([{ fail: unreachable("cloudflare-workers-ai") }]);
    expect(await collect(h.router.chat(request))).toBe("本地");
    expect(h.local.chatCalls).toBe(1);
  });

  test("a malformed request is not blamed on the provider", async () => {
    // `error` means the provider could not diagnose itself. Sending the same
    // broken request down the whole list just breaks it twice.
    const h = harness([{ fail: malformed("cloudflare-workers-ai") }]);
    await expect(collect(h.router.chat(request))).rejects.toThrow("请求有问题。");
    expect(h.local.chatCalls).toBe(0);
  });

  test("a failure after the first chunk is not failed over", async () => {
    const h = harness([{ say: "开头", then: unreachable("cloudflare-workers-ai") }]);
    await expect(collect(h.router.chat(request))).rejects.toThrow("网络不可用。");
    expect(h.local.chatCalls).toBe(0);
  });

  test("an exhausted allowance is not retried on the next turn", async () => {
    const h = harness([{ fail: quotaGone("cloudflare-workers-ai") }]);
    await collect(h.router.chat(request));
    await collect(h.router.chat(request));
    expect(h.cloud.chatCalls).toBe(1); // demoted on the first failure
    expect(h.local.chatCalls).toBe(2);
  });

  test("a transient failure takes two in a row to demote", async () => {
    const h = harness([{ fail: unreachable("cloudflare-workers-ai") }]);
    await collect(h.router.chat(request));
    // Still the one a request is *tried* on — one transient failure is not
    // enough to skip it — but no longer the one the window reports, because it
    // is not the one that answered. See rule 4.
    expect(h.router.activeProvider()?.id).toBe("cloudflare-workers-ai");
    expect(h.router.state().active).toBe("local-mlx");
    await collect(h.router.chat(request));
    expect(h.cloud.chatCalls).toBe(2);
    expect(h.router.activeProvider()?.id).toBe("local-mlx");
    expect(h.router.state().active).toBe("local-mlx");
  });

  test("everything demoted still gets tried rather than refusing to answer", async () => {
    // Both demoted on the first turn: an exhausted allowance and absent weights
    // are both sticky, so neither is eligible on the second.
    const h = harness([{ fail: quotaGone("cloudflare-workers-ai") }], [
      { fail: noWeights("local-mlx") },
    ]);
    await expect(collect(h.router.chat(request))).rejects.toThrow();
    await expect(collect(h.router.chat(request))).rejects.toThrow();
    expect(h.cloud.chatCalls).toBe(2);
    expect(h.local.chatCalls).toBe(2);
  });
});

describe("visibility", () => {
  test("degrading is reported with the reason on the row", async () => {
    const h = harness([{ fail: quotaGone("cloudflare-workers-ai") }]);
    await collect(h.router.chat(request));

    const last = h.states.at(-1);
    expect(last?.active).toBe("local-mlx");
    expect(last?.route).toBe("text");
    const cf = last?.candidates.find((c) => c.provider === "cloudflare-workers-ai");
    expect(cf?.status).toBe("quota_exhausted");
    expect(cf?.message).toBe("额度用尽。");
    // Capabilities ride along so the window can render the row without probing.
    expect(cf?.capabilities?.contextTokens).toBe(1024);
  });

  test("nothing is emitted while the state is unchanged", async () => {
    const h = harness([{ say: "云端" }]);
    await collect(h.router.chat(request));
    const afterFirst = h.states.length; // unknown -> ok is a change
    await collect(h.router.chat(request));
    expect(h.states.length).toBe(afterFirst);
  });

  test("the very first fallback is visible on the turn it happens", async () => {
    // Two real turns on a disconnected network: turn 1's answer came out of
    // the local model, and `active` still said `cloudflare-workers-ai` — it
    // only flipped on turn 2, once the second failure crossed the threshold.
    // The user was told the opposite of the truth about whether that sentence
    // went to the cloud, which is the one thing the local tier exists for.
    const h = harness([{ fail: unreachable("cloudflare-workers-ai") }]);
    expect(await collect(h.router.chat(request))).toBe("本地");
    expect(h.router.state().active).toBe("local-mlx");
    expect(h.states.at(-1)?.active).toBe("local-mlx");
  });

  test("the state starts as never-probed, per §3.9", () => {
    const h = harness([{ say: "云端" }]);
    expect(h.router.state().candidates.map((c) => [c.status, c.checkedAt])).toEqual([
      ["unknown", 0],
      ["unknown", 0],
    ]);
  });
});

describe("telling the user", () => {
  // `auto` is the default and the settings window is the only place the state
  // shows up, so without a notice the whole degradation is silent for anyone
  // who does not happen to have that window open.

  test("falling back says so, in one line, naming both ends", async () => {
    const h = harness([{ fail: unreachable("cloudflare-workers-ai") }]);
    await collect(h.router.chat(request));
    expect(h.notices).toEqual([
      { level: "warn", text: "Cloudflare 连不上，已自动切到本地模型（内容不再上云）。" },
    ]);
  });

  test("the reason comes from the failure, not from a template", async () => {
    const h = harness([{ fail: quotaGone("cloudflare-workers-ai") }]);
    await collect(h.router.chat(request));
    expect(h.notices[0]?.text).toContain("额度用尽");
  });

  test("coming back says so too — it means the content is leaving again", async () => {
    const h = harness([
      { fail: quotaGone("cloudflare-workers-ai") },
      { say: "云端回来了" },
    ]);
    await collect(h.router.chat(request));
    h.advance(60_001);
    await collect(h.router.chat(request));
    expect(h.notices.at(-1)).toEqual({
      level: "info",
      text: "Cloudflare 恢复了，之后的文本对话走云端。",
    });
  });

  test("one degradation is announced once, not once per cooldown", async () => {
    // The cooldown lapses, the retry fails again, the local model answers
    // again. Nothing changed, so there is nothing to say — otherwise the
    // status line would blink the same warning every 60 s, 2 min, 4 min…
    const h = harness([{ fail: unreachable("cloudflare-workers-ai") }]);
    await collect(h.router.chat(request));
    await collect(h.router.chat(request));
    h.advance(60_001);
    await collect(h.router.chat(request));
    h.advance(120_001);
    await collect(h.router.chat(request));
    expect(h.notices).toHaveLength(1);
  });

  test("a lapsed cooldown does not put the window back on a dead provider", async () => {
    // The reported bug: the backoff expires, the provider becomes *eligible*
    // again, and `active` flipped back to it on the strength of nothing but a
    // timer — the window claimed the text route was on Cloudflare while its own
    // row underneath still read `unreachable`. Eligibility is a routing
    // decision; `active` is a report about who last served, and a timer is not
    // evidence of service.
    const h = harness([{ fail: unreachable("cloudflare-workers-ai") }]);
    await collect(h.router.chat(request));
    await collect(h.router.chat(request));
    expect(h.router.state().active).toBe("local-mlx");

    h.advance(60_001);
    // Eligible to be *tried* again — that retry is the only way to learn
    // whether the path came back...
    expect(h.router.activeProvider()?.id).toBe("cloudflare-workers-ai");
    // ...but until it answers, the window must not change its story.
    expect(h.router.state().active).toBe("local-mlx");
    const row = h.router.state().candidates.find((c) => c.provider === "cloudflare-workers-ai");
    expect(row?.status).toBe("unreachable");

    // And the retry failing again leaves it exactly where it was.
    await collect(h.router.chat(request));
    expect(h.router.state().active).toBe("local-mlx");
  });

  test("a pinned route announces nothing — the user made the change", async () => {
    const h = harness([{ say: "云端" }]);
    await collect(h.router.chat(request));
    h.router.select("local-mlx");
    expect(await collect(h.router.chat(request))).toBe("本地");
    expect(h.router.state().active).toBe("local-mlx");
    expect(h.notices).toHaveLength(0);
  });

  test("an ordinary first turn is not a change of anything", async () => {
    const h = harness([{ say: "云端" }]);
    await collect(h.router.chat(request));
    expect(h.notices).toHaveLength(0);
  });
});

describe("the attempt budget", () => {
  // ADR-009's "断网就自动切本地" only holds if a hung network ends. `fetch`
  // against a captive portal or a half-dead VPN sits until the system TCP
  // timeout — about 75 s — and every lapsed cooldown pays it again.

  test("a provider that goes quiet is given up on and fallen through", async () => {
    const h = harness([{ hang: true }], [{ say: "本地" }], { attemptTimeoutMs: 25 });
    const started = Date.now();
    expect(await collect(h.router.chat(request))).toBe("本地");
    expect(Date.now() - started).toBeLessThan(2_000);
    expect(h.router.state().candidates[0]?.status).toBe("unreachable");
    expect(h.router.state().active).toBe("local-mlx");
    // Given up on by aborting, not by walking away from a live socket.
    expect(h.cloud.signals.at(-1)?.aborted).toBe(true);
  });

  test("a stall after the first chunk ends the turn instead of hanging", async () => {
    // Rule 2 forbids failing over once bytes are out, so the honest end is an
    // error — but it still has to end.
    const h = harness([{ say: "开头", thenHang: true }], [{ say: "本地" }], {
      attemptTimeoutMs: 25,
    });
    await expect(collect(h.router.chat(request))).rejects.toThrow("没有任何回应");
    expect(h.local.chatCalls).toBe(0);
  });

  test("the budget is per chunk, so a long answer is never cut off", async () => {
    const slow: TextProvider = {
      id: "cloudflare-workers-ai",
      model: "x",
      capabilities: {
        vision: true,
        tools: true,
        streaming: true,
        contextTokens: 1024,
        local: false,
      },
      async *chat() {
        for (const word of ["一", "二", "三", "四", "五", "六"]) {
          await new Promise((resolve) => setTimeout(resolve, 15));
          yield { text: word };
        }
        yield { done: true };
      },
      probe: async () => ({ status: "ok", ok: true, model: "x", checkedAt: 1 }),
    };
    const router = new TextRouter({ providers: [slow], config: { attemptTimeoutMs: 40 } });
    // 90 ms of streaming under a 40 ms budget: it is silence that is capped,
    // not the turn.
    expect(await collect(router.chat(request))).toBe("一二三四五六");
    await router.close();
  });

  test("the local runtime is exempt — loading 22.8 GB is not a network fault", async () => {
    // Measured 12.1 s to the first token cold. A network-sized budget would
    // shoot the fallback in exactly the situation it exists for.
    const h = harness([{ fail: unreachable("cloudflare-workers-ai") }], [{ say: "本地" }], {
      attemptTimeoutMs: 25,
    });
    await collect(h.router.chat(request));
    expect(h.local.signals.at(-1)).toBeUndefined();
  });
});

describe("recovery", () => {
  test("the demoted provider is preferred again once its cooldown passes", async () => {
    const h = harness([
      { fail: quotaGone("cloudflare-workers-ai") },
      { say: "云端回来了" },
    ]);
    await collect(h.router.chat(request));
    expect(h.router.state().active).toBe("local-mlx");

    h.advance(60_001);
    // Eligible again — that retry is how we find out the path is back.
    expect(h.router.activeProvider()?.id).toBe("cloudflare-workers-ai");
    expect(await collect(h.router.chat(request))).toBe("云端回来了");
    expect(h.router.state().candidates[0]?.status).toBe("ok");
    expect(h.router.state().active).toBe("cloudflare-workers-ai");
  });

  test("a lapsed cooldown does not report a still-broken provider as active", async () => {
    // Measured on a real outage: `active` flipped back to Cloudflare the
    // instant the cooldown passed, while its own row still read `unreachable`.
    // The settings window then said "当前在用：Cloudflare" directly above a red
    // "连不上" on the same provider, once per cooldown, forever.
    const h = harness([{ fail: quotaGone("cloudflare-workers-ai") }]);
    await collect(h.router.chat(request));
    expect(h.router.state().active).toBe("local-mlx");

    h.advance(60_001);
    expect(h.router.activeProvider()?.id).toBe("cloudflare-workers-ai");
    expect(h.router.state().candidates[0]?.status).toBe("quota_exhausted");
    expect(h.router.state().active).toBe("local-mlx");
  });

  test("everything broken reports nobody as active, per §3.9", async () => {
    // Cloudflare serves first, so it is genuinely the one that last answered —
    // and `active` still must not keep naming it once its own row has gone red.
    const h = harness(
      [{ say: "云端" }, { fail: quotaGone("cloudflare-workers-ai") }],
      [{ fail: noWeights("local-mlx") }],
    );
    expect(await collect(h.router.chat(request))).toBe("云端");
    expect(h.router.state().active).toBe("cloudflare-workers-ai");

    await expect(collect(h.router.chat(request))).rejects.toThrow();
    expect(h.router.state().active).toBeNull();
  });

  test("each further demotion waits longer, up to the cap", async () => {
    const h = harness([{ fail: quotaGone("cloudflare-workers-ai") }]);
    await collect(h.router.chat(request)); // demotion 1: 60s
    h.advance(60_001);
    await collect(h.router.chat(request)); // demotion 2: 120s
    h.advance(60_001);
    expect(h.router.activeProvider()?.id).toBe("local-mlx");
    h.advance(60_001);
    expect(h.router.activeProvider()?.id).toBe("cloudflare-workers-ai");
  });
});

describe("probing", () => {
  test("a probe failure demotes, and a probe success brings it back", async () => {
    const h = harness([{ say: "云端" }]);
    h.cloud.probeResult = {
      status: "unauthorized",
      ok: false,
      message: "这个 token 只有读取权限。",
      model: "@cf/qwen/qwen3.8-27b",
      checkedAt: 5,
    };
    const results = await h.router.probe();
    expect(results.map((r) => r.status)).toEqual(["unauthorized", "ok"]);
    expect(h.router.state().active).toBe("local-mlx");

    h.cloud.probeResult = { status: "ok", ok: true, model: "x", checkedAt: 6 };
    await h.router.probe("cloudflare-workers-ai");
    expect(h.router.state().active).toBe("cloudflare-workers-ai");
  });

  test("an allowance that names its reset is trusted over the backoff", async () => {
    const h = harness([{ say: "云端" }]);
    h.cloud.probeResult = {
      status: "quota_exhausted",
      ok: false,
      model: "x",
      checkedAt: 5,
      quota: { unit: "neurons", remaining: 0, resetsAt: 1_000_000 + 5 * 60_000 },
    };
    await h.router.probe();
    h.advance(60_001); // past the default backoff, still inside the window
    expect(h.router.activeProvider()?.id).toBe("local-mlx");
    h.advance(4 * 60_000);
    expect(h.router.activeProvider()?.id).toBe("cloudflare-workers-ai");
  });

  test("a probe that hangs is reported as unreachable rather than hanging", async () => {
    const cloud = new MockProvider("cloudflare-workers-ai", "x", [{ say: "云端" }]);
    cloud.probe = () => new Promise(() => {});
    const local = new MockProvider("local-mlx", "local", [{ say: "本地" }]);
    const router = new TextRouter({ providers: [cloud, local] });
    const results = await router.probe(undefined, 20);
    expect(results[0]?.status).toBe("unreachable");
    await router.close();
  });

  test("a provider that throws from probe does not take the window down", async () => {
    const cloud = new MockProvider("cloudflare-workers-ai", "x", [{ say: "云端" }]);
    cloud.probe = () => Promise.reject(new Error("boom"));
    const router = new TextRouter({ providers: [cloud] });
    const results = await router.probe();
    expect(results[0]?.status).toBe("error");
    expect(results[0]?.message).toBe("探测失败。");
  });
});

test("close releases every candidate", async () => {
  const h = harness([{ say: "云端" }]);
  await h.router.close();
  expect(h.cloud.closeCalls).toBe(1);
  expect(h.local.closeCalls).toBe(1);
});

describe("what a probe result replaces", () => {
  test("a quota number does not survive onto a result that has none", async () => {
    const h = harness([{ say: "云端" }]);
    h.cloud.probeResult = {
      status: "ok",
      ok: true,
      model: "@cf/qwen/qwen3.8-27b",
      checkedAt: 1,
      quota: { unit: "neurons", used: 161 },
    };
    await h.router.probe("cloudflare-workers-ai");
    expect(h.router.state().candidates[0]!.quota?.used).toBe(161);

    // The user just deleted the token. The allowance that number described is
    // not theirs to spend any more, and showing it says the opposite.
    h.cloud.probeResult = {
      status: "unconfigured",
      ok: false,
      message: "还没填 Cloudflare 账号 ID 或 API token。",
      missing: ["cloudflare.apiToken"],
      model: "@cf/qwen/qwen3.8-27b",
      checkedAt: 2,
    };
    await h.router.probe("cloudflare-workers-ai");
    expect(h.router.state().candidates[0]!.quota).toBeUndefined();
    expect(h.router.state().candidates[0]!.missing).toEqual(["cloudflare.apiToken"]);
  });

  test("a `missing` list does not outlive the failure it belonged to", async () => {
    const h = harness([{ say: "云端" }]);
    h.cloud.probeResult = {
      status: "unconfigured",
      ok: false,
      missing: ["cloudflare.apiToken"],
      model: "@cf/qwen/qwen3.8-27b",
      checkedAt: 1,
    };
    await h.router.probe("cloudflare-workers-ai");
    expect(h.router.state().candidates[0]!.missing).toHaveLength(1);

    h.cloud.probeResult = { status: "ok", ok: true, model: "@cf/qwen/qwen3.8-27b", checkedAt: 2 };
    await h.router.probe("cloudflare-workers-ai");
    expect(h.router.state().candidates[0]!.missing).toBeUndefined();
  });
});

describe("resetDemotions", () => {
  test("fixing the credential un-skips the provider immediately", async () => {
    // Sticky: one unauthorized is enough to demote for a full cooldown.
    const h = harness([
      { fail: new ProviderError("cloudflare-workers-ai", "unauthorized", "token 被拒。") },
      { say: "云端" },
    ]);
    expect(await collect(h.router.chat(request))).toBe("本地");
    expect(h.router.state().active).toBe("local-mlx");

    // The user pastes a working token. Without this, the settings window would
    // say the row is fine while requests kept going to the fallback for the
    // rest of the cooldown.
    h.router.resetDemotions();
    expect(h.router.activeProvider()?.id).toBe("cloudflare-workers-ai");
    // The window still names the local model, because that is still the one
    // that last answered. Clearing a cooldown is not evidence about anything.
    expect(h.router.state().active).toBe("local-mlx");
    expect(await collect(h.router.chat(request))).toBe("云端");
    expect(h.router.state().active).toBe("cloudflare-workers-ai");
  });

  test("it clears cooldowns without inventing a verdict", async () => {
    const h = harness([{ fail: noWeights("cloudflare-workers-ai") }]);
    await collect(h.router.chat(request));
    const before = h.router.state().candidates[0]!.status;
    h.router.resetDemotions();
    // The status is the last thing actually observed; only the cooldown goes.
    expect(h.router.state().candidates[0]!.status).toBe(before);
  });
});
