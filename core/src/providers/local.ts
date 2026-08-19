/**
 * Local MLX text provider (ADR-009) — the fallback the `text` route drops to
 * when the network, or the user's own Cloudflare account, is not available.
 *
 * ## Which runtime, and why not `mlx_lm`
 *
 * `models/Qwen3.8-27B-Uncensored-MLX/6-bit/config.json` declares
 * `architectures: ["Qwen3_5ForConditionalGeneration"]`, `language_model_only:
 * false`, a `vision_config`, an `image_token_id` and a `video_token_id`, and the
 * directory carries `preprocessor_config.json`. The vision tower survived the
 * 6-bit quantisation, so this is a vision-language checkpoint and `mlx_lm` would
 * serve the text half only. Everything below drives **`mlx_vlm`** (0.6.15).
 *
 * ## Shape (a) a resident server, over a **unix socket** — not a TCP port
 *
 * The two shapes on the table were (a) a resident OpenAI-compatible HTTP server
 * and (b) spawning a python process per request over stdio. (b) reloads 22.8 GB
 * of weights on every turn, which is not a fallback anybody would wait for, so
 * the model has to stay resident and something has to talk to it.
 *
 * The stated risk with (a) was `docs/spec.md` §3.1: on macOS Tahoe 26.3.x a
 * re-signed app disappears from the Local Network list and can no longer reach
 * local ports — which is exactly why app↔core is a unix socket. The core is a
 * child of the app and may well inherit that. So this takes the same way out
 * the rest of the project already took: **the MLX server listens on a unix
 * socket, not on 127.0.0.1**, and no TCP port exists to be blocked.
 *
 * Verified on this machine, 2026-08-19:
 *
 *   .venv-mlx/bin/python -m uvicorn mlx_vlm.server:app --uds <path>
 *
 * comes up (`/health` → 200), and Bun reaches it with
 * `fetch(url, { unix: path })`. `mlx_vlm.server`'s own CLI has no `--uds` flag,
 * but its `main()` does nothing except translate flags into env vars and call
 * `uvicorn.run("mlx_vlm.server:app", …)` — the ASGI path used here is theirs.
 *
 * Two more things that came out of running it:
 *
 * - The socket uvicorn creates is `srw-rw-rw-`, so the **directory** is the
 *   access control. It is created 0700 and the socket is chmod'ed 0600.
 * - AF_UNIX paths are capped near 104 bytes on macOS; a long path fails at
 *   `bind` with `AF_UNIX path too long`. The default here is ~55 bytes.
 *
 * ## The child must not outlive the core
 *
 * `close()` only runs on the graceful path (`index.ts` → `router.close()`).
 * SIGKILL the core and the runtime is reparented to launchd holding **25 GB of
 * footprint that nothing returns until the machine is rebooted** — measured, not
 * feared. `supervisor.ts` already fixed the same hole one level up (the app
 * SIGKILLed, the core left behind); this is that fix again, in the only place it
 * can live for a python child: **inside the child**, as a thread that polls
 * `getppid()` and `os._exit`s when it changes. See `MLX_PARENT_WATCHDOG_PY`.
 *
 * ## What is verified and what is not
 *
 * Weights were **still incomplete** while this was written — 1.3 GB of 22.8 GB,
 * shard 5 of 5 only — so **no generation has ever run through this file**.
 * Verified by hand against the real server: startup over UDS, `/health`,
 * `/v1/models`, the 400 for an unknown model id, the 400 for these
 * half-downloaded weights, and — the reason the error handling below is shaped
 * the way it is — that a `stream: true` request whose checkpoint will not load
 * still answers **400 before the stream starts**, so the in-stream `error`
 * event is the mid-generation case only.
 *
 * Read off their source, not run: the streaming chunk shape and
 * `stream_options.include_usage` (`openai.py`), the tool-call chunk shape
 * (`responses_state.py`), and `/unload`. Never exercised: generation, images,
 * tool calls.
 *
 * Since then the weights did finish and the runtime was measured on this
 * machine: 5.41 s to load, 22.78 GB resident on the GPU, 25.3 tok/s, 12.1 s to
 * the first token cold (load included), 220 ms warm. Those numbers are why the
 * load reports a phase and not a percentage — see `LocalLoadProgress`.
 *
 * One trap worth keeping: handing the server a **repo id** (`org/name`) makes it
 * call out to the Hugging Face Hub — measured, it 400s after a network round
 * trip. The fallback path must never depend on the network, so what goes on the
 * wire is always the absolute weights **path**.
 */

import { chmodSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { childEnv } from "../tools/builtin/process.ts";
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
  type TextProvider,
} from "./types.ts";

/** From `config.json`; the context number is declared, not measured. */
export const LOCAL_CAPABILITIES: ProviderCapabilities = {
  vision: true,
  tools: true,
  streaming: true,
  contextTokens: 262_144,
  local: true,
};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/** Repo root, from `core/src/providers/` up three levels. */
const REPO_ROOT = resolve(import.meta.dir, "../../..");

export interface LocalRuntimeConfig {
  /** Absolute directory of the MLX checkpoint. Always what goes on the wire. */
  weightsPath: string;
  /** Interpreter that has `mlx_vlm` and `uvicorn` importable. */
  python: string;
  /** Where the runtime listens. Must stay short — AF_UNIX caps the path. */
  socketPath: string;
  /**
   * A server somebody else runs, e.g. `http://127.0.0.1:8080`. Set it and this
   * provider never spawns anything; unset and it manages its own child.
   */
  endpoint?: string;
  /** False keeps this provider from ever starting a runtime. */
  autostart: boolean;
  /** How long to wait for `/health` after spawning. Importing mlx alone is
   *  ~20 s on this machine. */
  startTimeoutMs: number;
  /** Kill the runtime after this long without a request, releasing ~22.8 GB.
   *  `0` disables it. */
  idleUnloadMs: number;
  /** Cap when the request does not name one. */
  maxTokens: number;
  /**
   * Why this configuration cannot be used, when it cannot — today only "there is
   * no HOME to put the socket under".
   *
   * It is a field rather than a thrown error because `./index.ts` requires
   * construction to never throw: the settings window has to be able to render a
   * row for a provider that is not usable yet, and that row is how the user finds
   * out why. `probe()` reports it, `chat()` throws it as a `ProviderError`.
   */
  configError?: string;
}

/** Env overrides. `LOCAL_MLX_MODEL` is declared in `./index.ts`. */
export const LOCAL_ENV_VARS = {
  weights: "LOCAL_MLX_WEIGHTS",
  python: "LOCAL_MLX_PYTHON",
  socket: "LOCAL_MLX_SOCKET",
  endpoint: "LOCAL_MLX_ENDPOINT",
  autostart: "LOCAL_MLX_AUTOSTART",
  startTimeout: "LOCAL_MLX_START_TIMEOUT_MS",
  idle: "LOCAL_MLX_IDLE_MS",
  maxTokens: "LOCAL_MLX_MAX_TOKENS",
} as const;

function positiveInt(raw: string | undefined, fallback: number): number {
  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 ? Math.floor(value) : fallback;
}

export function resolveLocalConfig(
  env: Record<string, string | undefined>,
): LocalRuntimeConfig & { model: string } {
  const model = env[TEXT_MODEL_ENV_VARS["local-mlx"]] || DEFAULT_TEXT_MODELS["local-mlx"];
  // A model given as an absolute path *is* the checkpoint; a repo id maps to the
  // directory `make download` puts it in.
  const derived = model.startsWith("/")
    ? model
    : resolve(REPO_ROOT, "models", basename(model), "6-bit");
  // No `?? ""`: an env snapshot without HOME used to produce the *system*
  // `/Library/Application Support/akari/mlx.sock`, and the first sign of it was
  // an EACCES escaping `mkdirSync` as a bare Error. A configuration mistake has
  // to stay a configuration mistake all the way to the user.
  const home = env["HOME"];
  const socketPath =
    env[LOCAL_ENV_VARS.socket] ||
    (home ? `${home}/Library/Application Support/akari/mlx.sock` : "");

  return {
    model,
    weightsPath: env[LOCAL_ENV_VARS.weights] || derived,
    python: env[LOCAL_ENV_VARS.python] || resolve(REPO_ROOT, ".venv-mlx/bin/python"),
    socketPath,
    ...(socketPath
      ? {}
      : { configError: "找不到用户主目录（HOME 没有设置），本地推理服务没地方放它的 socket。" }),
    ...(env[LOCAL_ENV_VARS.endpoint] ? { endpoint: env[LOCAL_ENV_VARS.endpoint] } : {}),
    autostart: env[LOCAL_ENV_VARS.autostart] !== "0",
    startTimeoutMs: positiveInt(env[LOCAL_ENV_VARS.startTimeout], 120_000),
    idleUnloadMs: positiveInt(env[LOCAL_ENV_VARS.idle], 10 * 60_000),
    maxTokens: positiveInt(env[LOCAL_ENV_VARS.maxTokens], 2048),
  };
}

// ---------------------------------------------------------------------------
// Host seam
// ---------------------------------------------------------------------------

export interface LocalChildHandle {
  pid: number;
  kill(): void;
  exited: Promise<unknown>;
}

/**
 * Everything this file does outside its own process, in one injectable object.
 * Tests hand over a fake and never touch the filesystem, spawn python, or open
 * a socket — which is the only way these paths can be covered at all while the
 * weights are still downloading.
 */
export interface LocalHost {
  /** Size in bytes, or `undefined` when the path does not exist. */
  fileSize(path: string): number | undefined;
  readText(path: string): string | undefined;
  /** Create the directory (and parents) with mode 0700. */
  ensureDir(path: string): void;
  chmod(path: string, mode: number): void;
  spawn(argv: string[]): LocalChildHandle;
  fetch(url: string, init: RequestInit, unixSocket?: string): Promise<Response>;
  now(): number;
  sleep(ms: number): Promise<void>;
}

function defaultHost(): LocalHost {
  return {
    fileSize(path) {
      try {
        return statSync(path).size;
      } catch {
        return undefined;
      }
    },
    readText(path) {
      try {
        return readFileSync(path, "utf8");
      } catch {
        return undefined;
      }
    },
    ensureDir(path) {
      mkdirSync(path, { recursive: true, mode: 0o700 });
    },
    chmod(path, mode) {
      try {
        chmodSync(path, mode);
      } catch {
        // The socket may not exist yet; the caller retries.
      }
    },
    spawn(argv) {
      // `childEnv()` is the allow-list the rest of the core spawns with: no
      // credential can reach this child by accident, and the local path has no
      // credential to give it anyway.
      const child = Bun.spawn(argv, {
        stdin: "ignore",
        stdout: "ignore",
        stderr: "ignore",
        env: childEnv(),
      });
      return { pid: child.pid, kill: () => child.kill(), exited: child.exited };
    },
    fetch(url, init, unixSocket) {
      return unixSocket
        ? fetch(url, { ...init, unix: unixSocket } as RequestInit)
        : fetch(url, init);
    },
    now: () => Date.now(),
    sleep: (ms) => new Promise((done) => setTimeout(done, ms)),
  };
}

// ---------------------------------------------------------------------------
// Weights
// ---------------------------------------------------------------------------

export interface WeightsState {
  /** Every shard the index names is on disk at a non-zero size. */
  complete: boolean;
  /** Bytes present of the shards the index names. */
  bytes: number;
  /** `metadata.total_size` from the index, when it has one. */
  totalBytes?: number;
  /** Shard file names still absent. */
  missing: string[];
  /** The directory has no recognisable checkpoint at all. */
  absent: boolean;
}

/**
 * Completeness from `model.safetensors.index.json`, which lists every shard in
 * `weight_map` and the total byte count in `metadata.total_size`.
 *
 * This has to happen before anything is sent to the runtime: handed a half
 * downloaded checkpoint the server answers 400 with a body that lists every
 * missing tensor by name — tens of kilobytes that say "权重还没下完" to nobody.
 */
export function readWeightsState(host: LocalHost, weightsPath: string): WeightsState {
  const indexRaw = host.readText(`${weightsPath}/model.safetensors.index.json`);
  if (indexRaw === undefined) {
    // Unsharded checkpoints have a single file and no index.
    const single = host.fileSize(`${weightsPath}/model.safetensors`);
    if (single !== undefined && single > 0) {
      return { complete: true, bytes: single, missing: [], absent: false };
    }
    return { complete: false, bytes: 0, missing: [], absent: true };
  }

  let index: { weight_map?: Record<string, string>; metadata?: { total_size?: number } };
  try {
    index = JSON.parse(indexRaw);
  } catch {
    return { complete: false, bytes: 0, missing: [], absent: true };
  }

  const shards = [...new Set(Object.values(index.weight_map ?? {}))].sort();
  const missing: string[] = [];
  let bytes = 0;
  for (const shard of shards) {
    const size = host.fileSize(`${weightsPath}/${shard}`);
    if (size === undefined || size === 0) missing.push(shard);
    else bytes += size;
  }

  const total = index.metadata?.total_size;
  return {
    complete: shards.length > 0 && missing.length === 0,
    bytes,
    ...(typeof total === "number" ? { totalBytes: total } : {}),
    missing,
    absent: shards.length === 0,
  };
}

// ---------------------------------------------------------------------------
// Progress
// ---------------------------------------------------------------------------

export type LocalPhase =
  /** Nothing running; weights are there. */
  | "idle"
  /** Weights absent or half downloaded. */
  | "incomplete"
  /** The runtime process is coming up (importing mlx). */
  | "starting"
  /** The runtime is pulling weights into memory. */
  | "loading"
  /** Model resident, ready to answer. */
  | "ready"
  /** Being torn down. */
  | "stopping"
  /** Last attempt failed; `message` says how. */
  | "error";

export interface LocalLoadProgress {
  phase: LocalPhase;
  /**
   * 0..1, and **only when something was actually counted**: bytes of the
   * checkpoint on disk over `metadata.total_size` while downloading, and `1` once
   * the model is resident. Absent means "no number to show", not "zero".
   *
   * There is deliberately **no number for the load itself**. It used to be RSS
   * over `total_size`, and measured against the real runtime that reads 1.63 GB
   * of 22.78 GB when the model is fully loaded — MLX puts the weights in
   * IOAccelerator (Metal) memory, which never appears in RSS. The bar sat at 7 %
   * for the whole load and then jumped to done, which is worse than no bar: it
   * says "stuck" where "working" is the truth. The honest reading is
   * `phys_footprint` out of `task_info`, and that is FFI and a `task_for_pid`
   * argument for a progress indicator that is on screen for 5.41 s. A spinner
   * plus `message` is the right size for it; `updatedAt` is when the phase
   * started, so the UI can show elapsed time.
   */
  fraction?: number;
  /** One line for the settings window. Chinese. */
  message: string;
  updatedAt: number;
}

/** `TextProvider` plus the three things only a local runtime has. */
export interface LocalTextProvider extends TextProvider {
  /** Where the runtime is in its lifecycle. Cheap; call it on a timer. */
  progress(): LocalLoadProgress;
  /** Start the runtime and pull the weights in, so the first real turn does not
   *  pay for it. Resolves to the same shape `probe()` returns. */
  warmup(signal?: AbortSignal): Promise<ProviderProbe>;
  /** Stop the runtime, releasing the ~22.8 GB. Idempotent. */
  close(): Promise<void>;
}

function gib(bytes: number): string {
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
}

// ---------------------------------------------------------------------------
// The runtime command line
// ---------------------------------------------------------------------------

/**
 * Parent watchdog, in python, prepended to whatever the child goes on to run.
 *
 * The core spawns this process and is the only thing that ever kills it — on the
 * graceful path. SIGKILL the core and macOS reparents the child to launchd with
 * ~25 GB of footprint held, and nothing gives it back short of a reboot. This is
 * `supervisor.ts`'s fix one level down; it has to live inside the child because
 * there is nobody else left to do it once the core is gone.
 *
 * Three choices worth keeping:
 *
 * - **A polling thread, not a signal.** `SIGKILL` cannot be caught by the core,
 *   so nothing on this machine gets to say "my parent died" — the child has to
 *   look. `getppid()` becomes 1 on reparent, which is the same signal
 *   `supervisor.ts` watches for.
 * - **`os._exit`, not SIGTERM to itself.** Loading the weights is a synchronous
 *   call that holds the event loop for ~5 s, and a graceful shutdown queued
 *   behind it would keep the 25 GB exactly when it is most expensive. Nothing
 *   needs to be flushed here; asyncio unlinks a stale socket file at the next
 *   `bind`, so leaving one behind costs nothing.
 * - **The period comes in on argv**, so the tests can drive it in milliseconds
 *   instead of waiting out the production one.
 *
 * `sys.argv` under `python -c CODE a b` is `["-c", a, b]`, so argv[1] is the
 * socket and argv[2] the period in seconds.
 */
export const MLX_PARENT_WATCHDOG_PY = `import os, sys, threading, time
_parent = os.getppid()
_period = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
if _parent == 1:
    raise SystemExit("akari: orphaned before startup finished")
def _watch():
    while True:
        time.sleep(_period)
        if os.getppid() != _parent:
            os._exit(1)
threading.Thread(target=_watch, daemon=True).start()
`;

/** How often the child checks that the core is still there. */
const WATCHDOG_PERIOD_SECONDS = 2;

/**
 * `mlx_vlm.server`'s own CLI has no `--uds`, and its `main()` does nothing but
 * turn flags into env vars and call `uvicorn.run` — so the ASGI app is addressed
 * directly, which is also the only way to get the watchdog in front of it.
 */
export function mlxRuntimeArgv(python: string, socketPath: string): string[] {
  return [
    python,
    "-c",
    `${MLX_PARENT_WATCHDOG_PY}import uvicorn
uvicorn.run("mlx_vlm.server:app", uds=sys.argv[1], log_level="warning")
`,
    socketPath,
    String(WATCHDOG_PERIOD_SECONDS),
  ];
}

// ---------------------------------------------------------------------------
// Wire shapes (mlx_vlm's OpenAI-compatible surface)
// ---------------------------------------------------------------------------

interface HealthBody {
  status?: string;
  loaded_model?: string | null;
}

interface StreamDelta {
  content?: string | null;
  tool_calls?: {
    id?: string;
    function?: { name?: string; arguments?: string };
  }[];
}

interface StreamChunkBody {
  choices?: { delta?: StreamDelta; finish_reason?: string | null }[];
  usage?: { prompt_tokens?: number; completion_tokens?: number };
  /**
   * A generation that blows up **after** the response has started does not get
   * an HTTP status — `openai.py` yields `data: {"error": …}` into a 200 stream
   * and stops. Measured: a failure *before* generation (a checkpoint that will
   * not load) still answers 400, so this is the mid-generation case only.
   */
  error?: string;
}

function toWireMessages(messages: ChatMessage[]): unknown[] {
  return messages.map((message) => {
    const base: Record<string, unknown> = { role: message.role };
    if (message.toolCallId) base["tool_call_id"] = message.toolCallId;

    if (!message.images || message.images.length === 0) {
      base["content"] = message.content;
      return base;
    }
    // Verified against `openai.py`: a content part of type `image_url` is read
    // as `item["image_url"]["url"]`, and a `data:` URL is accepted there.
    base["content"] = [
      ...(message.content ? [{ type: "text", text: message.content }] : []),
      ...message.images.map((image) => ({
        type: "image_url",
        image_url: { url: `data:${image.mediaType};base64,${image.base64}` },
      })),
    ];
    return base;
  });
}

/**
 * HTTP status → provider status.
 *
 * The bodies are never shown to the user: a load failure answers 400 with every
 * missing tensor name in it, and `docs/protocol.md` §3.9 forbids forwarding an
 * upstream body verbatim anyway.
 */
function statusFromHttp(code: number, body: string): ProviderStatus {
  if (code === 401 || code === 403) return "unauthorized";
  if (code === 429) return "quota_exhausted";
  if (code === 404) return "model_missing";
  if (code === 400 && /failed to load model|no such file|missing/i.test(body)) {
    return "model_missing";
  }
  return "error";
}

async function* sseData(
  body: ReadableStream<Uint8Array>,
): AsyncGenerator<string, void, unknown> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true }).replaceAll("\r\n", "\n");
      let split = buffer.indexOf("\n\n");
      while (split !== -1) {
        const event = buffer.slice(0, split);
        buffer = buffer.slice(split + 2);
        for (const line of event.split("\n")) {
          if (line.startsWith("data:")) yield line.slice(5).trim();
        }
        split = buffer.indexOf("\n\n");
      }
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

export function createLocalTextProvider(
  deps: TextProviderDeps,
  host: LocalHost = defaultHost(),
): LocalTextProvider {
  const env = deps.env ?? process.env;
  const config = resolveLocalConfig(env);
  const log = deps.log ?? (() => {});
  const id = "local-mlx" as const;

  let child: LocalChildHandle | undefined;
  let starting: Promise<void> | undefined;
  let warming: Promise<ProviderProbe> | undefined;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  let phase: LocalPhase = "idle";
  let fraction: number | undefined;
  let note = "";
  let updatedAt = 0;

  const setPhase = (next: LocalPhase, message: string, at?: number) => {
    phase = next;
    note = message;
    updatedAt = host.now();
    if (at === undefined) fraction = undefined;
    else fraction = Math.max(0, Math.min(1, at));
  };

  // A function declaration, not a const: TypeScript only propagates `never`
  // through control flow for the declared form.
  function fail(status: ProviderStatus, message: string, cause?: unknown): never {
    throw new ProviderError(id, status, message, cause);
  }

  // --- runtime lifecycle ---------------------------------------------------

  const url = (path: string) =>
    config.endpoint ? `${config.endpoint.replace(/\/$/, "")}${path}` : `http://localhost${path}`;
  const unix = () => (config.endpoint ? undefined : config.socketPath);

  async function health(timeoutMs: number): Promise<HealthBody | undefined> {
    // With no endpoint and no socket path there is nothing to ask. Falling
    // through would drop the `unix:` option and send the probe to
    // `http://localhost/health` over TCP, which is somebody else's server.
    if (!config.endpoint && !config.socketPath) return undefined;
    const abort = AbortSignal.timeout(timeoutMs);
    try {
      const response = await host.fetch(url("/health"), { signal: abort }, unix());
      if (!response.ok) return undefined;
      return (await response.json()) as HealthBody;
    } catch {
      return undefined;
    }
  }

  function armIdleTimer() {
    if (idleTimer) clearTimeout(idleTimer);
    if (config.idleUnloadMs <= 0) return;
    idleTimer = setTimeout(() => {
      log("info", `local-mlx: idle for ${config.idleUnloadMs}ms, releasing the model`);
      void close();
    }, config.idleUnloadMs);
    idleTimer.unref?.();
  }

  /** Loading the model is a phase, not a percentage — see `LocalLoadProgress`. */
  function announceLoading(totalBytes: number | undefined) {
    setPhase(
      "loading",
      totalBytes
        ? `正在把本地模型装入内存（${gib(totalBytes)}）…`
        : "正在把本地模型装入内存…",
    );
  }

  async function startRuntime(): Promise<void> {
    if (config.endpoint) {
      // Somebody else owns the process; all we can do is wait for it to answer.
      if (await health(2000)) return;
      fail("unreachable", "本地推理服务没有响应。");
    }
    if (config.configError) {
      setPhase("error", config.configError);
      fail("error", config.configError);
    }
    if (!config.autostart) fail("unreachable", "本地推理服务没在跑，而自动启动是关掉的。");
    if (host.fileSize(config.python) === undefined) {
      fail("error", "找不到本地 MLX 运行时（.venv-mlx）。");
    }
    if (config.socketPath.length > 100) {
      // AF_UNIX caps the path near 104 bytes; failing here beats failing at bind.
      fail("error", "本地推理服务的 socket 路径太长了。");
    }

    setPhase("starting", "正在启动本地推理服务…");
    const directory = dirname(config.socketPath);
    // A read-only disk, a directory owned by somebody else, a path that is not a
    // directory: all of them used to come out of here as a bare Error, which the
    // router cannot classify and the settings window cannot explain.
    try {
      host.ensureDir(directory);
    } catch (cause) {
      setPhase("error", "无法创建本地推理服务的运行目录。");
      fail("error", `无法创建本地推理服务的运行目录（${directory}）。`, cause);
    }
    try {
      child = host.spawn(mlxRuntimeArgv(config.python, config.socketPath));
    } catch (cause) {
      setPhase("error", "无法启动本地推理服务进程。");
      fail("error", "无法启动本地推理服务进程。", cause);
    }
    log("info", `local-mlx: started runtime pid ${child.pid} on ${config.socketPath}`);

    const deadline = host.now() + config.startTimeoutMs;
    for (;;) {
      if (await health(2000)) {
        // uvicorn creates the socket world-writable; the 0700 directory is the
        // real gate, this closes the rest of it.
        host.chmod(config.socketPath, 0o600);
        setPhase("idle", "本地推理服务已就绪，模型尚未加载。");
        return;
      }
      if (host.now() >= deadline) {
        await close();
        setPhase("error", "本地推理服务启动超时。");
        fail("unreachable", "本地推理服务启动超时。");
      }
      await host.sleep(500);
    }
  }

  async function ensureRuntime(): Promise<WeightsState> {
    const weights = readWeightsState(host, config.weightsPath);
    if (!weights.complete) {
      const message = describeWeights(weights);
      setPhase("incomplete", message, weightsFraction(weights));
      fail("model_missing", message);
    }
    if (await health(1000)) return weights;
    starting ??= startRuntime().finally(() => {
      starting = undefined;
    });
    await starting;
    return weights;
  }

  async function close(): Promise<void> {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = undefined;
    const running = child;
    child = undefined;
    if (!running) return;
    setPhase("stopping", "正在释放本地模型…");
    running.kill();
    await running.exited.catch(() => {});
    setPhase("idle", "本地模型已卸载。");
  }

  // --- request -------------------------------------------------------------

  async function post(
    path: string,
    body: unknown,
    signal?: AbortSignal,
  ): Promise<Response> {
    let response: Response;
    try {
      response = await host.fetch(
        url(path),
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
          ...(signal ? { signal } : {}),
        },
        unix(),
      );
    } catch (cause) {
      if (signal?.aborted) throw cause;
      setPhase("error", "本地推理服务断开了。");
      fail("unreachable", "连不上本地推理服务。", cause);
    }
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      const status = statusFromHttp(response.status, text);
      // The body is kept as `cause` for the log and never put in `message`.
      setPhase("error", "本地推理失败。");
      fail(
        status,
        status === "model_missing"
          ? "本地权重不完整或模型加载失败。"
          : `本地推理失败（HTTP ${response.status}）。`,
        text.slice(0, 500),
      );
    }
    return response;
  }

  async function* chat(request: ChatRequest): AsyncIterable<ChatChunk> {
    const weights = await ensureRuntime();
    armIdleTimer();

    if (phase !== "ready") announceLoading(weights.totalBytes);

    const response = await post(
      "/v1/chat/completions",
      {
        // The absolute path, never the repo id: a repo id sends the server to
        // the Hugging Face Hub, and this is the offline path.
        model: config.weightsPath,
        messages: toWireMessages(request.messages),
        stream: true,
        stream_options: { include_usage: true },
        max_tokens: request.maxTokens ?? config.maxTokens,
        ...(request.temperature === undefined ? {} : { temperature: request.temperature }),
        ...(request.tools && request.tools.length > 0
          ? {
              tools: request.tools.map((tool) => ({
                type: "function",
                function: {
                  name: tool.name,
                  description: tool.description,
                  parameters: tool.parameters,
                },
              })),
            }
          : {}),
      },
      request.signal,
    );

    setPhase("ready", "本地模型已加载。", 1);

    const stream = response.body;
    if (!stream) fail("error", "本地推理服务没有返回内容。");
    let usage: ChatChunk["usage"];

    for await (const data of sseData(stream)) {
      if (data === "[DONE]") break;
      let body: StreamChunkBody;
      try {
        body = JSON.parse(data) as StreamChunkBody;
      } catch {
        continue; // A comment or keep-alive; nothing to hand upstream.
      }
      if (body.usage) {
        usage = {
          ...(body.usage.prompt_tokens === undefined
            ? {}
            : { promptTokens: body.usage.prompt_tokens }),
          ...(body.usage.completion_tokens === undefined
            ? {}
            : { completionTokens: body.usage.completion_tokens }),
        };
      }
      if (typeof body.error === "string") {
        fail("error", "本地推理中途失败。", body.error.slice(0, 500));
      }
      const delta = body.choices?.[0]?.delta;
      if (delta?.content) yield { text: delta.content };
      for (const call of delta?.tool_calls ?? []) {
        const name = call.function?.name;
        if (!name) continue;
        let args: Record<string, unknown>;
        try {
          args = JSON.parse(call.function?.arguments || "{}") as Record<string, unknown>;
        } catch (cause) {
          // Dropping the call silently would leave the assistant believing it
          // acted, which is worse than ending the turn.
          fail("error", "本地模型给出的工具调用参数不是合法 JSON。", cause);
        }
        yield {
          toolCall: { callId: call.id ?? `local-${host.now()}`, name, arguments: args },
        };
      }
    }

    armIdleTimer();
    yield { done: true, ...(usage ? { usage } : {}) };
  }

  // --- probe ---------------------------------------------------------------

  function describeWeights(weights: WeightsState): string {
    if (weights.absent) return "本地权重还没下载。";
    if (weights.totalBytes) {
      return `本地权重还没下完（${gib(weights.bytes)} / ${gib(weights.totalBytes)}）。`;
    }
    return `本地权重还差 ${weights.missing.length} 个分片。`;
  }

  function weightsFraction(weights: WeightsState): number | undefined {
    if (!weights.totalBytes || weights.totalBytes <= 0) return undefined;
    return weights.bytes / weights.totalBytes;
  }

  async function probe(signal?: AbortSignal): Promise<ProviderProbe> {
    const started = host.now();
    const base = { model: config.model, checkedAt: started };

    const weights = readWeightsState(host, config.weightsPath);
    if (!weights.complete) {
      const message = describeWeights(weights);
      setPhase("incomplete", message, weightsFraction(weights));
      return { ...base, status: "model_missing", ok: false, message };
    }
    if (!config.endpoint && config.configError) {
      setPhase("error", config.configError);
      return { ...base, status: "error", ok: false, message: config.configError };
    }
    if (!config.endpoint && host.fileSize(config.python) === undefined) {
      setPhase("error", "找不到本地 MLX 运行时。");
      return {
        ...base,
        status: "error",
        ok: false,
        message: "找不到本地 MLX 运行时（.venv-mlx）。",
      };
    }
    if (signal?.aborted) {
      return { ...base, status: "unknown", ok: false, message: "探测已取消。" };
    }

    // Deliberately does not start the runtime. Probing is what the settings
    // window calls; making it pull 22.8 GB into memory would turn a status
    // check into the most expensive button in the app. `warmup()` is the call
    // that proves generation works, and it is a separate, explicit button.
    const state = await health(2000);
    if (!state) {
      // A synchronous weight load blocks the server's event loop, so `/health`
      // timing out during one is expected. Reporting "idle" then would replace
      // a truthful phase with a wrong one.
      if (phase !== "loading" && phase !== "starting") {
        setPhase("idle", "权重齐全，但本地模型从未加载过。");
      }
      // `ok: true` with a message that says what has and has not been proved.
      //
      // The temptation is to report this as not-ok, since all that was checked
      // is that the shard files are on disk at the sizes the index claims. But
      // `ok: false` is what `router.ts` demotes on, and `model_missing` is
      // sticky there — the fallback would be taken out of the candidate list by
      // the very probe that says it is fine to fall back to, and a CF failure
      // right after would then have nowhere to go. So the honesty goes in the
      // message, which is what the settings window shows anyway.
      return {
        ...base,
        status: "ok",
        ok: true,
        message: `权重齐全（${gib(weights.bytes)}），但从未加载过；首次使用要先把它装入内存（约十几秒）。`,
      };
    }
    const loaded = state.loaded_model === config.weightsPath;
    if (loaded) setPhase("ready", "本地模型已加载。", 1);
    return {
      ...base,
      status: "ok",
      ok: true,
      latencyMs: host.now() - started,
      message: loaded
        ? "本地模型已加载，随时可用。"
        : "本地服务在跑，但模型还没装入内存，首次使用要等它加载。",
    };
  }

  /**
   * The only call that proves this provider can actually generate. `probe()`
   * checks that the files are on disk; this one makes the runtime read them and
   * answer, which is the difference between "本地 MLX · 可用" meaning something
   * and meaning "the file count matches".
   *
   * Concurrent calls share one load: the settings button is a button, and two
   * clicks must not queue two twelve-second loads.
   */
  function warmup(signal?: AbortSignal): Promise<ProviderProbe> {
    warming ??= runWarmup(signal).finally(() => {
      warming = undefined;
    });
    return warming;
  }

  async function runWarmup(signal?: AbortSignal): Promise<ProviderProbe> {
    const started = host.now();
    try {
      const weights = await ensureRuntime();
      announceLoading(weights.totalBytes);
      const response = await post(
        "/v1/chat/completions",
        {
          model: config.weightsPath,
          messages: [{ role: "user", content: "ok" }],
          max_tokens: 1,
          stream: false,
        },
        signal,
      );
      await response.text().catch(() => "");
      setPhase("ready", "本地模型已加载。", 1);
      armIdleTimer();
      return {
        status: "ok",
        ok: true,
        model: config.model,
        latencyMs: host.now() - started,
        message: "本地模型已加载，随时可用。",
        checkedAt: started,
      };
    } catch (error) {
      const status = error instanceof ProviderError ? error.status : "error";
      const message =
        error instanceof ProviderError ? error.message : "本地模型加载失败。";
      setPhase(status === "model_missing" ? "incomplete" : "error", message);
      return { status, ok: false, model: config.model, message, checkedAt: started };
    }
  }

  return {
    id,
    model: config.model,
    capabilities: LOCAL_CAPABILITIES,
    chat,
    probe,
    warmup,
    close,
    progress: () => ({
      phase,
      ...(fraction === undefined ? {} : { fraction }),
      message: note || "本地模型未加载。",
      updatedAt,
    }),
  };
}

/**
 * Narrow a routed provider to the local one, for the callers that want the three
 * extra members — the settings window's 预加载 button (`warmup`) and its progress
 * line (`progress`). `router.ts` deals in `TextProvider` and should keep doing
 * so; this is the one place that knows which id has more.
 */
export function isLocalTextProvider(
  provider: TextProvider,
): provider is LocalTextProvider {
  return (
    provider.id === "local-mlx" &&
    typeof (provider as LocalTextProvider).warmup === "function"
  );
}
