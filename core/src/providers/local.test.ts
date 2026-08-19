import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CredentialResolver } from "../credentials.ts";
import {
  createLocalTextProvider,
  isLocalTextProvider,
  MLX_PARENT_WATCHDOG_PY,
  readWeightsState,
  resolveLocalConfig,
  type LocalChildHandle,
  type LocalHost,
} from "./local.ts";
import { ProviderError, type ChatChunk } from "./types.ts";

/**
 * Almost every one of these runs against a fake host: no python is spawned, no
 * socket is opened, no file is read. That is not only for speed — the weights
 * were still downloading when this was written (1.3 GB of 22.8 GB), so a test
 * that needed the real runtime could not exist yet.
 *
 * The exception is "the orphan watchdog", which runs the real python prelude
 * under a real process and really SIGKILLs its parent. That one is worth the
 * cost: it is the only way to find out whether 25 GB actually goes away.
 *
 * **Never exercised against the real thing:** generation, images, tool calls.
 * What *was* checked by hand against a live `mlx_vlm.server` over a unix socket
 * is listed in the header of `local.ts`.
 */

const WEIGHTS = "/w/Qwen3.8-27B-Uncensored-MLX/6-bit";
const SHARD_TOTAL = 22_777_600_480;

interface Fetched {
  url: string;
  init: RequestInit;
  unix?: string;
  body?: unknown;
}

class TestHost implements LocalHost {
  files = new Map<string, { size: number; text?: string }>();
  dirs: string[] = [];
  chmods: [string, number][] = [];
  spawned: string[][] = [];
  killed = 0;
  fetches: Fetched[] = [];
  clock = 1_700_000_000_000;
  serverUp = false;
  loadedModel: string | null = null;
  /** Set to make `ensureDir` / `spawn` fail the way a read-only disk does. */
  ensureDirFails: Error | undefined = undefined;
  spawnFails: Error | undefined = undefined;
  onChat: (body: unknown) => Response | Promise<Response> = () =>
    new Response("", { status: 500 });

  fileSize(path: string) {
    return this.files.get(path)?.size;
  }
  readText(path: string) {
    return this.files.get(path)?.text;
  }
  ensureDir(path: string) {
    if (this.ensureDirFails) throw this.ensureDirFails;
    this.dirs.push(path);
  }
  chmod(path: string, mode: number) {
    this.chmods.push([path, mode]);
  }
  spawn(argv: string[]): LocalChildHandle {
    if (this.spawnFails) throw this.spawnFails;
    this.spawned.push(argv);
    this.serverUp = true; // the runtime comes up on the next /health poll
    return {
      pid: 4242,
      kill: () => {
        this.killed += 1;
        this.serverUp = false;
      },
      exited: Promise.resolve(0),
    };
  }
  async fetch(url: string, init: RequestInit, unix?: string): Promise<Response> {
    const body = typeof init.body === "string" ? JSON.parse(init.body) : undefined;
    this.fetches.push({ url, init, ...(unix ? { unix } : {}), body });
    if (url.endsWith("/health")) {
      if (!this.serverUp) throw new Error("ECONNREFUSED");
      return Response.json({ status: "healthy", loaded_model: this.loadedModel });
    }
    return this.onChat(body);
  }
  now() {
    return this.clock;
  }
  async sleep(ms: number) {
    this.clock += ms; // the start deadline is reached without waiting for it
  }
}

function withWeights(host: TestHost, present: number[]): TestHost {
  const shards = ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"];
  host.files.set(`${WEIGHTS}/model.safetensors.index.json`, {
    size: 1,
    text: JSON.stringify({
      metadata: { total_size: SHARD_TOTAL },
      weight_map: { "a.weight": shards[0], "b.weight": shards[1] },
    }),
  });
  for (const index of present) {
    host.files.set(`${WEIGHTS}/${shards[index]}`, { size: SHARD_TOTAL / 2 });
  }
  return host;
}

function make(
  host: TestHost,
  extra: Record<string, string | undefined> = {},
): ReturnType<typeof createLocalTextProvider> {
  const env = {
    HOME: "/home",
    LOCAL_MLX_WEIGHTS: WEIGHTS,
    LOCAL_MLX_PYTHON: "/venv/bin/python",
    LOCAL_MLX_SOCKET: "/run/akari/mlx.sock",
    LOCAL_MLX_IDLE_MS: "0",
    ...extra,
  };
  host.files.set("/venv/bin/python", { size: 1 });
  return createLocalTextProvider(
    { credentials: new CredentialResolver(env), env },
    host,
  );
}

const ask = { messages: [{ role: "user" as const, content: "你好" }] };

async function drain(stream: AsyncIterable<ChatChunk>): Promise<ChatChunk[]> {
  const chunks: ChatChunk[] = [];
  for await (const chunk of stream) chunks.push(chunk);
  return chunks;
}

function sse(...events: unknown[]): Response {
  const body = events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") +
    "data: [DONE]\n\n";
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

// ---------------------------------------------------------------------------

describe("configuration", () => {
  test("the weights path is derived from the model, and stays local", () => {
    const config = resolveLocalConfig({ HOME: "/home" });
    expect(config.model).toBe("orcarouter/Qwen3.8-27B-Uncensored-MLX");
    expect(config.weightsPath).toEndWith("/models/Qwen3.8-27B-Uncensored-MLX/6-bit");
    expect(config.python).toEndWith("/.venv-mlx/bin/python");
    expect(config.socketPath).toBe("/home/Library/Application Support/akari/mlx.sock");
    // AF_UNIX caps the path near 104 bytes on macOS.
    expect(config.socketPath.length).toBeLessThan(100);
  });

  test("no HOME is a configuration error, not a path nobody can write", () => {
    // `env["HOME"] ?? ""` used to make this `/Library/Application Support/…`,
    // a system path, and the first sign of it was an EACCES out of mkdirSync.
    const config = resolveLocalConfig({});
    expect(config.socketPath).toBe("");
    expect(config.configError).toContain("HOME");
  });

  test("an explicit socket path does not need HOME", () => {
    const config = resolveLocalConfig({ LOCAL_MLX_SOCKET: "/run/akari/mlx.sock" });
    expect(config.socketPath).toBe("/run/akari/mlx.sock");
    expect(config.configError).toBeUndefined();
  });

  test("a model given as an absolute path is the checkpoint", () => {
    const config = resolveLocalConfig({ LOCAL_MLX_MODEL: "/elsewhere/mlx-model" });
    expect(config.weightsPath).toBe("/elsewhere/mlx-model");
  });

  test("every knob has an env override", () => {
    const config = resolveLocalConfig({
      LOCAL_MLX_WEIGHTS: "/w",
      LOCAL_MLX_PYTHON: "/p",
      LOCAL_MLX_SOCKET: "/s.sock",
      LOCAL_MLX_ENDPOINT: "http://127.0.0.1:8080",
      LOCAL_MLX_AUTOSTART: "0",
      LOCAL_MLX_IDLE_MS: "0",
      LOCAL_MLX_MAX_TOKENS: "64",
    });
    expect(config).toMatchObject({
      weightsPath: "/w",
      python: "/p",
      socketPath: "/s.sock",
      endpoint: "http://127.0.0.1:8080",
      autostart: false,
      idleUnloadMs: 0,
      maxTokens: 64,
    });
  });
});

describe("weights", () => {
  test("a checkpoint is complete only when every shard in the index is there", () => {
    const host = withWeights(new TestHost(), [0, 1]);
    expect(readWeightsState(host, WEIGHTS)).toMatchObject({
      complete: true,
      bytes: SHARD_TOTAL,
      totalBytes: SHARD_TOTAL,
      missing: [],
    });
  });

  test("a half downloaded checkpoint reports which shards are missing", () => {
    const host = withWeights(new TestHost(), [1]);
    const state = readWeightsState(host, WEIGHTS);
    expect(state.complete).toBe(false);
    expect(state.missing).toEqual(["model-00001-of-00002.safetensors"]);
    expect(state.bytes).toBe(SHARD_TOTAL / 2);
  });

  test("no index and no single-file checkpoint means nothing is there", () => {
    expect(readWeightsState(new TestHost(), WEIGHTS)).toMatchObject({
      complete: false,
      absent: true,
    });
  });

  test("an unsharded checkpoint needs no index", () => {
    const host = new TestHost();
    host.files.set(`${WEIGHTS}/model.safetensors`, { size: 10 });
    expect(readWeightsState(host, WEIGHTS)).toMatchObject({ complete: true, bytes: 10 });
  });
});

describe("probe", () => {
  test("half downloaded weights are model_missing, with how far along it is", async () => {
    const host = withWeights(new TestHost(), [1]);
    const provider = make(host);
    const probe = await provider.probe();

    expect(probe.status).toBe("model_missing");
    expect(probe.ok).toBe(false);
    expect(probe.message).toContain("还没下完");
    expect(probe.message).toContain("GB");
    expect(probe.missing).toBeUndefined(); // no credential slot is involved
    expect(provider.progress()).toMatchObject({ phase: "incomplete", fraction: 0.5 });
    expect(host.spawned).toHaveLength(0);
  });

  test("complete weights with nothing running are usable, and nothing is started", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    const provider = make(host);
    const probe = await provider.probe();

    // Starting the runtime here would make a status check the most expensive
    // button in the app: 22.8 GB pulled in to answer "is this configured".
    expect(probe.status).toBe("ok");
    expect(host.spawned).toHaveLength(0);
    // …but the message must not let a green dot stand for more than what was
    // checked, which is a file listing. Nothing has ever been generated.
    expect(probe.message).toContain("从未加载过");
    expect(provider.progress().message).toContain("从未加载过");
  });

  test("a runtime that is up but empty says so, instead of implying it is ready", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.serverUp = true;
    host.loadedModel = null;
    const probe = await make(host).probe();

    expect(probe.status).toBe("ok");
    expect(probe.message).toContain("还没装入内存");
  });

  test("a loaded runtime reports ready, with a round trip", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.serverUp = true;
    host.loadedModel = WEIGHTS;
    const provider = make(host);
    const probe = await provider.probe();

    expect(probe.status).toBe("ok");
    expect(probe.latencyMs).toBeGreaterThanOrEqual(0);
    expect(provider.progress()).toMatchObject({ phase: "ready", fraction: 1 });
  });

  test("a missing runtime is an error, not a missing credential", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    const provider = make(host);
    host.files.delete("/venv/bin/python");
    const probe = await provider.probe();
    expect(probe.status).toBe("error");
    expect(probe.message).toContain(".venv-mlx");
  });
});

describe("chat", () => {
  test("streams text, tool calls and usage, and never names the repo id", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.serverUp = true;
    host.loadedModel = WEIGHTS;
    host.onChat = () =>
      sse(
        { choices: [{ delta: { content: "你" } }] },
        { choices: [{ delta: { content: "好" } }] },
        {
          choices: [
            {
              delta: {
                tool_calls: [
                  { id: "tc-1", function: { name: "speak", arguments: '{"text":"hi"}' } },
                ],
              },
              finish_reason: "tool_calls",
            },
          ],
        },
        { choices: [], usage: { prompt_tokens: 7, completion_tokens: 3 } },
      );

    const chunks = await drain(make(host).chat(ask));
    expect(chunks.map((c) => c.text).filter(Boolean)).toEqual(["你", "好"]);
    expect(chunks.find((c) => c.toolCall)?.toolCall).toEqual({
      callId: "tc-1",
      name: "speak",
      arguments: { text: "hi" },
    });
    expect(chunks.at(-1)).toEqual({
      done: true,
      usage: { promptTokens: 7, completionTokens: 3 },
    });

    const call = host.fetches.at(-1);
    // A repo id would send the server to the Hugging Face Hub — measured, it
    // 400s after a network round trip, and this is the offline path.
    expect((call?.body as { model: string }).model).toBe(WEIGHTS);
    expect((call?.body as { stream: boolean }).stream).toBe(true);
    expect(call?.unix).toBe("/run/akari/mlx.sock");
  });

  test("images go as OpenAI content parts", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.serverUp = true;
    host.onChat = () => sse({ choices: [{ delta: { content: "看到了" } }] });

    await drain(
      make(host).chat({
        messages: [
          {
            role: "user",
            content: "这是什么",
            images: [{ mediaType: "image/png", base64: "AAAA" }],
          },
        ],
      }),
    );

    const content = (host.fetches.at(-1)?.body as { messages: { content: unknown }[] })
      .messages[0]?.content as { type: string; text?: string; image_url?: { url: string } }[];
    expect(content[0]).toEqual({ type: "text", text: "这是什么" });
    expect(content[1]?.image_url?.url).toBe("data:image/png;base64,AAAA");
  });

  test("incomplete weights fail before anything is sent", async () => {
    const host = withWeights(new TestHost(), [1]);
    const error = (await drain(make(host).chat(ask)).catch((e) => e)) as ProviderError;
    expect(error).toBeInstanceOf(ProviderError);
    expect(error.status).toBe("model_missing");
    expect(error.retryable).toBe(false);
    expect(host.fetches).toHaveLength(0);
  });

  test("a load failure is model_missing, and its body never reaches the user", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.serverUp = true;
    // What the real server answers for a half-loaded checkpoint: every missing
    // tensor, by name, tens of kilobytes of it.
    const wall = `Failed to load model: missing ${"vision_tower.blocks.9.attn.qkv.weight,".repeat(200)}`;
    host.onChat = () => new Response(JSON.stringify({ detail: wall }), { status: 400 });

    const error = (await drain(make(host).chat(ask)).catch((e) => e)) as ProviderError;
    expect(error.status).toBe("model_missing");
    expect(error.message).toBe("本地权重不完整或模型加载失败。");
    expect(error.message).not.toContain("vision_tower");
  });

  test("a dead runtime is unreachable, which is what the router falls back on", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.serverUp = true;
    host.onChat = () => Promise.reject(new Error("socket hang up"));

    const error = (await drain(make(host).chat(ask)).catch((e) => e)) as ProviderError;
    expect(error.status).toBe("unreachable");
    expect(error.retryable).toBe(true);
  });

  test("an abort is an abort, not a provider failure", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.serverUp = true;
    const controller = new AbortController();
    host.onChat = () => {
      controller.abort();
      return Promise.reject(new DOMException("aborted", "AbortError"));
    };

    const error = await drain(
      make(host).chat({ ...ask, signal: controller.signal }),
    ).catch((e) => e);
    // Turning a barge-in into `unreachable` would demote the provider for a
    // minute every time the user interrupts it.
    expect(error).not.toBeInstanceOf(ProviderError);
    expect((error as Error).name).toBe("AbortError");
  });

  test("a generation that dies mid-stream is not reported as a finished turn", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.serverUp = true;
    // A 200 that turns into an error partway through; the HTTP status already
    // said everything was fine.
    host.onChat = () =>
      sse({ choices: [{ delta: { content: "开头" } }] }, { error: "out of memory" });

    const chunks: ChatChunk[] = [];
    const error = await (async () => {
      try {
        for await (const chunk of make(host).chat(ask)) chunks.push(chunk);
      } catch (e) {
        return e as ProviderError;
      }
      return undefined;
    })();

    expect(chunks.map((c) => c.text)).toEqual(["开头"]);
    expect(error?.status).toBe("error");
    expect(error?.message).not.toContain("out of memory");
  });

  test("a tool call with unparseable arguments ends the turn instead of dropping it", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.serverUp = true;
    host.onChat = () =>
      sse({
        choices: [
          { delta: { tool_calls: [{ id: "x", function: { name: "speak", arguments: "{oops" } }] } },
        ],
      });

    const error = (await drain(make(host).chat(ask)).catch((e) => e)) as ProviderError;
    expect(error.status).toBe("error");
  });
});

describe("runtime lifecycle", () => {
  test("the runtime is started on demand, over a unix socket", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.onChat = () => sse({ choices: [{ delta: { content: "本地" } }] });

    await drain(make(host).chat(ask));

    expect(host.spawned).toHaveLength(1);
    const argv = host.spawned[0] ?? [];
    expect(argv[0]).toBe("/venv/bin/python");
    expect(argv[1]).toBe("-c");
    expect(argv[2]).toContain('uvicorn.run("mlx_vlm.server:app", uds=sys.argv[1]');
    // The socket path travels as an argument, never spliced into the source.
    expect(argv[3]).toBe("/run/akari/mlx.sock");
    // uvicorn creates the socket world-writable, so the directory is the gate.
    expect(host.dirs).toContain("/run/akari");
    expect(host.chmods).toContainEqual(["/run/akari/mlx.sock", 0o600]);
  });

  test("the child carries a parent watchdog, so a SIGKILLed core leaves no 25 GB", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.onChat = () => sse({ choices: [{ delta: { content: "本地" } }] });
    await drain(make(host).chat(ask));

    const [, , source, , period] = host.spawned[0] ?? [];
    expect(source).toContain(MLX_PARENT_WATCHDOG_PY);
    expect(source).toContain("os.getppid()");
    expect(source).toContain("os._exit");
    expect(Number(period)).toBeGreaterThan(0);
  });

  test("a directory it cannot create is a ProviderError, not a bare EACCES", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.ensureDirFails = Object.assign(new Error("EACCES: permission denied"), {
      code: "EACCES",
    });

    const error = (await drain(make(host).chat(ask)).catch((e) => e)) as ProviderError;
    expect(error).toBeInstanceOf(ProviderError);
    expect(error.status).toBe("error");
    expect(error.message).toContain("/run/akari");
    expect(host.spawned).toHaveLength(0);
  });

  test("a spawn that fails is a ProviderError too", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.spawnFails = new Error("ENOENT");

    const error = (await drain(make(host).chat(ask)).catch((e) => e)) as ProviderError;
    expect(error).toBeInstanceOf(ProviderError);
    expect(error.status).toBe("error");
    expect(error.message).toContain("本地推理服务");
  });

  test("without HOME the provider fails cleanly instead of writing to a system path", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    const provider = createLocalTextProvider(
      {
        credentials: new CredentialResolver({}),
        env: { LOCAL_MLX_WEIGHTS: WEIGHTS, LOCAL_MLX_PYTHON: "/venv/bin/python" },
      },
      host,
    );

    const probe = await provider.probe();
    expect(probe.status).toBe("error");
    expect(probe.message).toContain("HOME");

    const error = (await drain(provider.chat(ask)).catch((e) => e)) as ProviderError;
    expect(error).toBeInstanceOf(ProviderError);
    expect(error.status).toBe("error");
    expect(host.dirs).toHaveLength(0);
    expect(host.spawned).toHaveLength(0);
    // And nothing was sent to `http://localhost/…` for want of a socket.
    expect(host.fetches).toHaveLength(0);
  });

  test("a runtime that never answers gives up and does not leave the child behind", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.spawn = ((argv: string[]) => {
      host.spawned.push(argv);
      return { pid: 1, kill: () => (host.killed += 1), exited: Promise.resolve(0) };
    }) as TestHost["spawn"];

    const error = (await drain(
      make(host, { LOCAL_MLX_START_TIMEOUT_MS: "5000" }).chat(ask),
    ).catch((e) => e)) as ProviderError;

    expect(error.status).toBe("unreachable");
    expect(host.killed).toBe(1);
  });

  test("autostart off means the fallback stays off", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    const error = (await drain(
      make(host, { LOCAL_MLX_AUTOSTART: "0" }).chat(ask),
    ).catch((e) => e)) as ProviderError;
    expect(error.status).toBe("unreachable");
    expect(host.spawned).toHaveLength(0);
  });

  test("an externally run server is used as is", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.serverUp = true;
    host.onChat = () => sse({ choices: [{ delta: { content: "hi" } }] });
    await drain(make(host, { LOCAL_MLX_ENDPOINT: "http://127.0.0.1:8080" }).chat(ask));

    expect(host.spawned).toHaveLength(0);
    expect(host.fetches.at(-1)?.url).toBe("http://127.0.0.1:8080/v1/chat/completions");
    expect(host.fetches.at(-1)?.unix).toBeUndefined();
  });

  test("a socket path AF_UNIX cannot bind is refused before spawning", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    const error = (await drain(
      make(host, { LOCAL_MLX_SOCKET: `/${"x".repeat(120)}.sock` }).chat(ask),
    ).catch((e) => e)) as ProviderError;
    expect(error.status).toBe("error");
    expect(host.spawned).toHaveLength(0);
  });

  test("close releases the ~22.8 GB and can be called twice", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.onChat = () => sse({ choices: [{ delta: { content: "本地" } }] });
    const provider = make(host);
    await drain(provider.chat(ask));
    expect(provider.progress().phase).toBe("ready");

    await provider.close();
    await provider.close();
    expect(host.killed).toBe(1);
    expect(provider.progress().phase).toBe("idle");
  });

  test("an idle runtime lets go of the memory by itself", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.onChat = () => sse({ choices: [{ delta: { content: "本地" } }] });
    const provider = make(host, { LOCAL_MLX_IDLE_MS: "5" });
    await drain(provider.chat(ask));

    await Bun.sleep(40);
    expect(host.killed).toBe(1);
  });

  test("warmup loads the model so the first real turn does not pay for it", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    host.onChat = () => Response.json({ choices: [{ message: { content: "ok" } }] });
    const provider = make(host);

    const probe = await provider.warmup();
    expect(probe.ok).toBe(true);
    expect(provider.progress()).toMatchObject({ phase: "ready", fraction: 1 });
    expect((host.fetches.at(-1)?.body as { max_tokens: number }).max_tokens).toBe(1);
  });

  test("warmup reports a failure instead of throwing it", async () => {
    const host = withWeights(new TestHost(), [1]);
    const probe = await make(host).warmup();
    expect(probe.ok).toBe(false);
    expect(probe.status).toBe("model_missing");
  });

  test("two clicks on 预加载 share one load", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    let loads = 0;
    host.onChat = () => {
      loads += 1;
      return Response.json({ choices: [{ message: { content: "ok" } }] });
    };
    const provider = make(host);

    const [first, second] = await Promise.all([provider.warmup(), provider.warmup()]);
    expect(first.ok).toBe(true);
    expect(second).toBe(first);
    expect(loads).toBe(1);
  });

  test("warmup is reachable through the routed provider, for the settings button", () => {
    const provider = make(withWeights(new TestHost(), [0, 1]));
    expect(isLocalTextProvider(provider)).toBe(true);
    expect(isLocalTextProvider({ ...provider, id: "cloudflare-workers-ai" })).toBe(false);
  });
});

describe("load progress", () => {
  test("the load reports a phase and no percentage", async () => {
    const host = withWeights(new TestHost(), [0, 1]);
    let release: (() => void) | undefined;
    host.onChat = () =>
      new Promise<Response>((resolve) => {
        release = () => resolve(sse({ choices: [{ delta: { content: "本地" } }] }));
      });

    const provider = make(host);
    const turn = drain(provider.chat(ask));
    for (let spin = 0; spin < 50 && !release; spin += 1) await Bun.sleep(1);

    const loading = provider.progress();
    expect(loading.phase).toBe("loading");
    // ps RSS reads 1.63 GB of a 22.78 GB model — MLX allocates the weights in
    // IOAccelerator memory, which RSS does not count. A bar pinned at 7 % for
    // the whole load says "stuck" where "working" is the truth.
    expect(loading.fraction).toBeUndefined();
    // The size is what explains the wait, and it is a number we actually have.
    expect(loading.message).toContain("GB");

    release?.();
    await turn;
    expect(provider.progress()).toMatchObject({ phase: "ready", fraction: 1 });
  });

  test("a download still has a real percentage, because those bytes are counted", async () => {
    const provider = make(withWeights(new TestHost(), [1]));
    await provider.probe();
    expect(provider.progress()).toMatchObject({ phase: "incomplete", fraction: 0.5 });
  });
});

describe("the orphan watchdog", () => {
  const python = ["/usr/bin/python3", "/opt/homebrew/bin/python3"].find(
    (path) => Bun.file(path).size > 0,
  );

  const alive = (pid: number): boolean => {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  };

  /** Kill a child this test is done with; already gone is the normal case. */
  const reap = (pid: number): void => {
    try {
      process.kill(pid, 9);
    } catch {
      // Exited on its own, which is what these tests are here to check.
    }
  };

  /**
   * The real prelude in front of a sleep loop instead of `mlx_vlm.server`, under a
   * shell that stands in for the core.
   *
   * The shell is the process that gets killed: python is *its* child, so killing
   * it reparents python to launchd, which is what the core's death does to the
   * runtime. It resolves once python has printed `up`, and that barrier is the
   * point of the whole helper — kill the shell any earlier and python has not run
   * `getppid()` yet, so it exits down the "already an orphan" path and the test
   * passes without the watchdog ever polling.
   */
  async function spawnUnderShell(period: string) {
    const script = join(mkdtempSync(join(tmpdir(), "akari-watchdog-")), "server.py");
    writeFileSync(
      script,
      `${MLX_PARENT_WATCHDOG_PY}print("up", flush=True)\nimport time\nwhile True:\n    time.sleep(0.02)\n`,
    );
    const shell = Bun.spawn(
      ["/bin/sh", "-c", '"$0" "$1" /unused "$2" & echo $!; wait', python!, script, period],
      { stdin: "ignore", stdout: "pipe", stderr: "ignore" },
    );

    const reader = shell.stdout.getReader();
    const decoder = new TextDecoder();
    let seen = "";
    while (!seen.includes("up")) {
      const { done, value } = await reader.read();
      if (done) break;
      seen += decoder.decode(value, { stream: true });
    }
    const pid = Number(seen.split("\n").find((line) => /^\d+$/.test(line.trim())));
    return { shell, pid, up: seen.includes("up") };
  }

  /**
   * The one test in this file that runs a real process, because the failure it
   * guards is measured in gigabytes: SIGKILL the core and `mlx_vlm.server` is
   * reparented to launchd holding 25 GB that nothing gives back.
   */
  test.skipIf(python === undefined)(
    "a child whose parent is SIGKILLed exits on its own",
    async () => {
      const { shell, pid, up } = await spawnUnderShell("0.05");
      expect(up).toBe(true);
      expect(pid).toBeGreaterThan(1);
      expect(alive(pid)).toBe(true);

      shell.kill(9);
      await shell.exited;

      const deadline = Date.now() + 10_000;
      while (alive(pid) && Date.now() < deadline) await Bun.sleep(25);
      const survived = alive(pid);
      reap(pid); // a broken watchdog must not leave this test's child behind
      expect(survived).toBe(false);
    },
    15_000,
  );

  test.skipIf(python === undefined)(
    "a child that is already an orphan when it starts never comes up",
    async () => {
      // The prelude reads its ppid 0.5 s in, and the shell is gone by then: the
      // child is born reparented, which is the case the polling loop can never
      // see because it has no earlier ppid to compare against.
      const script = join(mkdtempSync(join(tmpdir(), "akari-watchdog-")), "server.py");
      writeFileSync(
        script,
        `import time\ntime.sleep(0.5)\n${MLX_PARENT_WATCHDOG_PY}print("up", flush=True)\nwhile True:\n    time.sleep(0.02)\n`,
      );
      // No `wait`: the shell exits the moment it has printed the pid.
      const shell = Bun.spawn(
        ["/bin/sh", "-c", '"$0" "$1" /unused 0.05 & echo $!', python!, script],
        { stdin: "ignore", stdout: "pipe", stderr: "ignore" },
      );
      const printed = await new Response(shell.stdout).text();
      await shell.exited;
      const pid = Number(printed.trim());
      expect(pid).toBeGreaterThan(1);

      const deadline = Date.now() + 10_000;
      while (alive(pid) && Date.now() < deadline) await Bun.sleep(25);
      const survived = alive(pid);
      reap(pid);
      expect(survived).toBe(false);
      expect(printed).not.toContain("up");
    },
    15_000,
  );

  test.skipIf(python === undefined)(
    "a child whose parent is still there keeps running",
    async () => {
      const { shell, pid } = await spawnUnderShell("0.05");

      // Ten poll periods with a live parent. A watchdog that fired here would
      // take the fallback down while it was being used.
      await Bun.sleep(500);
      expect(alive(pid)).toBe(true);

      shell.kill(9);
      await shell.exited;
      reap(pid);
    },
    15_000,
  );
});
