/**
 * akari-core entry point.
 *
 * Owns the Unix socket (akari.app dials in), the Qwen Realtime session, and the
 * tool registry. The avatar state machine lives here too: protocol.md §3.2 puts
 * that decision on the core, and the app only executes it.
 *
 *   bun run src/index.ts                 full pipeline (needs DASHSCOPE_API_KEY)
 *   bun run src/index.ts --no-realtime   socket only, for smoke tests
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { Bridge, defaultSocketPath } from "./bridge.ts";
import { startParentWatchdog } from "./supervisor.ts";
import type { AudioFrame, AvatarState, LogLevel } from "./protocol.ts";
import {
  RealtimeClient,
  configFromEnv,
  type RealtimeToolCall,
} from "./realtime.ts";
import { AuditLog, ToolExecutor, createRegistry, jsonlFileSink } from "./tools/index.ts";
import type { ChatMessage } from "./providers/types.ts";

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

/**
 * Where credentials are read from, first match wins per key:
 *
 *   1. the environment already set on this process
 *   2. `<repo>/.env` — the checkout, one level above `core/`
 *   3. `~/Library/Application Support/akari/.env`
 *
 * (2) is what `make run` uses. (3) exists because a bundled core lives at
 * `<bundle>/Contents/Resources/core`, so (2) resolves inside the .app — and
 * `make app-bundle` deliberately does not copy `.env` into a distributable
 * bundle. Without (3) the `open build/akari.app` flow the README prescribes for
 * permission testing has no key at all.
 *
 * No value read here is ever logged.
 */
function envFilePaths(): string[] {
  const home = process.env.HOME ?? "";
  return [
    resolve(import.meta.dir, "..", "..", ".env"),
    ...(home ? [`${home}/Library/Application Support/akari/.env`] : []),
  ];
}

function loadEnvFiles(): void {
  for (const path of envFilePaths()) loadEnvFile(path);
}

function loadEnvFile(path: string): void {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq <= 0) continue;
    const key = trimmed.slice(0, eq).trim();
    if (process.env[key] !== undefined) continue;
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

const LEVELS: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

function makeLogger(): (level: LogLevel, message: string) => void {
  const configured = (process.env.AKARI_LOG_LEVEL ?? "info") as LogLevel;
  const threshold = LEVELS[configured] ?? LEVELS.info;
  return (level, message) => {
    if (LEVELS[level] < threshold) return;
    const line = `${new Date().toISOString()} ${level.padEnd(5)} ${message}`;
    if (level === "error" || level === "warn") console.error(line);
    else console.log(line);
  };
}

// ---------------------------------------------------------------------------
// Persona
// ---------------------------------------------------------------------------

/** Sent as `instructions`; carried across session renewals by the client. */
const PERSONA = [
  "你叫 akari（明かり），住在用户的 macOS 桌面上，是他的私人助理与伙伴。",
  "说话简短、自然、口语化 —— 你的回答会被念出来，不是被读的。不要用 Markdown、列表或表情符号。",
  "不确定就直说不确定，不要编。",
  "需要动用户的电脑时就调用工具；风险确认由系统负责，你不必额外征求许可。",
].join("\n");

/** avatar-states.md §1: the greeting clip is a one-shot wave, about 4s. */
const GREETING_MS = 4_000;

// ---------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------

loadEnvFiles();

const log = makeLogger();
const offline = process.argv.includes("--no-realtime");

const messages: ChatMessage[] = [];

let realtime: RealtimeClient | null = null;
let avatar: AvatarState = "idle";
let greetingTimer: ReturnType<typeof setTimeout> | null = null;
/** Open downlink stream id, or null while she is not speaking. */
let stream: number | null = null;
let shuttingDown = false;

// Declared before the Bridge so its handlers can close over them; nothing here
// fires until `listen()` has a client.
const bridge = new Bridge({
  socketPath: process.env.AKARI_SOCKET || defaultSocketPath(),
  handlers: {
    onLog: log,
    onConnect: ({ appVersion }) => onAppConnected(appVersion),
    onDisconnect: () => onAppDisconnected(),
    onPttDown: () => onPttDown(),
    onPttUp: () => onPttUp(),
    onMicAudio: (frame: AudioFrame) => realtime?.appendAudio(frame.pcm),
    onPlaybackDone: () => onPlaybackDone(),
    onQuit: () => void shutdown(0),
  },
});

/**
 * `clipboard_read` goes through the app, never through `pbpaste` (protocol.md
 * §3.7). Supplying the host is also what registers the tool as 🟢 GREEN instead
 * of 🔴 RED: the app can see the `org.nspasteboard.ConcealedType` marker a
 * password manager sets and declines to read it, which is the protection the
 * CLI fallback cannot offer.
 */
const registry = createRegistry({
  clipboard: { readText: (signal) => bridge.readClipboardText(signal) },
});

/**
 * Where the audit trail lands. It holds tool arguments, so `jsonlFileSink`
 * creates it 0600 inside a 0700 directory — beside the socket, which is already
 * held to the same modes.
 */
const auditPath =
  process.env.AKARI_AUDIT_LOG || `${dirname(bridge.socketPath)}/audit.jsonl`;

const executor = new ToolExecutor({
  registry,
  host: bridge,
  audit: new AuditLog({
    sinks: [
      jsonlFileSink(auditPath, (error) =>
        log("warn", `audit log unavailable (${(error as Error).message}); calls still run`),
      ),
    ],
  }),
  // Read per call: the app can drop and another client can take its place while
  // the core stays up. "The user approved it" is only evidence if the record
  // also says which process was showing the card.
  peer: () => bridge.peerDescription,
});

function setAvatar(state: AvatarState): void {
  if (avatar === state) return;
  avatar = state;
  bridge.setAvatarState(state);
}

function openStream(): number {
  if (stream === null) {
    stream = bridge.beginPlayback();
    setAvatar("talking");
  }
  return stream;
}

function closeStream(): void {
  if (stream === null) return;
  bridge.endPlayback(stream);
  // `audio.done` from the app is what moves her back to idle; the samples are
  // still playing out at this point (protocol.md §3.4).
  stream = null;
}

function dropStream(): void {
  if (stream === null) return;
  bridge.cancelPlayback(stream);
  stream = null;
}

function clearGreeting(): void {
  if (greetingTimer) clearTimeout(greetingTimer);
  greetingTimer = null;
}

function onAppConnected(appVersion: string): void {
  log("info", `akari.app ${appVersion} attached`);
  // The app has just come up and can now be told; a core that started before it
  // had nobody to tell.
  if (realtimeConfigError) {
    bridge.sendNotice("error", "语音不可用：没读到 DASHSCOPE_API_KEY，看 core 的日志。");
  }
  setAvatar("greeting");
  clearGreeting();
  // `greeting` is the one non-looping clip; nothing on the wire reports that it
  // ended, so the core times it out and hands her back to idle.
  greetingTimer = setTimeout(() => setAvatar("idle"), GREETING_MS);
}

function onAppDisconnected(): void {
  clearGreeting();
  stream = null;
  // The app sets itself to idle on disconnect (protocol.md §六); match it so
  // the next `setAvatar` is not swallowed as a no-op.
  avatar = "idle";
}

function onPttDown(): void {
  clearGreeting();
  setAvatar("listening");
}

function onPttUp(): void {
  setAvatar("thinking");
  if (!realtime) {
    // --no-realtime: nothing will ever answer, so the `thinking` set one line
    // up is the same permanent stall `onTurnAbandoned` exists to prevent.
    abandonTurn("这个 core 是用 --no-realtime 启动的，没有语音。");
    return;
  }
  realtime.commitAudio();
}

/** A turn that produced nothing: hand her back to idle and say why. */
function abandonTurn(text: string): void {
  setAvatar("idle");
  bridge.sendNotice("warn", text);
}

function onPlaybackDone(): void {
  stream = null;
  setAvatar("idle");
}

async function runTool(call: RealtimeToolCall): Promise<void> {
  log("info", `tool ${call.name}(${call.argumentsRaw})`);
  const invocation = await executor.execute(call.name, call.arguments, {
    messages,
    callId: call.callId,
  });
  log(
    invocation.status === "ok" ? "info" : "warn",
    `tool ${call.name} → ${invocation.status}${invocation.reason ? ` (${invocation.reason})` : ""}`,
  );
  // Always answer, including on failure: an unanswered call hangs the turn.
  realtime?.sendToolResult(call.callId, invocation.content);
}

/**
 * A misconfigured voice session must not take the socket down with it.
 *
 * `configFromEnv()` throws on a missing key or a hijacked endpoint, and that
 * throw used to escape to the top level and kill the process — which, when the
 * app is the one that spawned the core, is a crash loop that ends with the menu
 * bar saying "未连接" and nothing anywhere saying why. The desktop layer is
 * worth running without voice; `realtime.connect()` below already treats a
 * failure that way, and construction now matches it.
 */
let realtimeConfigError: string | null = null;

function realtimeConfig() {
  try {
    return { ...configFromEnv(), instructions: PERSONA, tools: registry.schemas() };
  } catch (error) {
    realtimeConfigError = (error as Error).message;
    return null;
  }
}

const config = offline ? null : realtimeConfig();

if (config) {
  realtime = new RealtimeClient(
    config,
    {
      onSessionCreated: ({ sessionId, serverVad }) =>
        log("info", `realtime session ${sessionId} (server_vad=${serverVad})`),
      onInputTranscript: (text, final) => {
        if (final && text) log("info", `你: ${text}`);
      },
      onOutputTranscript: (text, final) => {
        if (final && text) log("info", `akari: ${text}`);
      },
      onAudioDelta: (pcm) => bridge.sendPlaybackAudio(openStream(), pcm),
      onResponseDone: ({ hadAudio }) => {
        if (hadAudio) closeStream();
        // A tool-call-only turn produces no audio, so no `audio.done` will ever
        // arrive; idle has to be set here or she is stuck mid-gesture.
        else setAvatar("idle");
      },
      onResponseCancelled: ({ reason }) => {
        log("info", `reply cancelled (${reason})`);
        dropStream();
        setAvatar("listening");
      },
      // Terminal for the turn, unlike a cancel: nothing else closes the stream
      // and nothing else moves her off `talking`. With 60 RPM to share, a
      // refused reply is routine.
      onResponseFailed: ({ message, code }) => {
        log("warn", `reply failed${code ? ` (${code})` : ""}: ${message}`);
        dropStream();
        setAvatar("idle");
        bridge.sendNotice(
          "error",
          code === "rate_limit_exceeded"
            ? "模型限流了，这句没答上来，等一下再说。"
            : `模型这轮出错了：${message.slice(0, 120)}`,
        );
      },
      // `ptt.up` already moved her to `thinking`; on these two paths no
      // response event will ever arrive to move her off it again.
      onTurnAbandoned: ({ reason, bufferedMillis }) => {
        const millis = Math.round(bufferedMillis);
        log("warn", `turn abandoned (${reason}, ${millis}ms buffered)`);
        abandonTurn(
          reason === "not_connected"
            ? "没连上模型，这句没送出去。"
            : `按得太短了（只录到 ${millis}ms），没听清。`,
        );
      },
      onToolCall: (call) => void runTool(call),
      onError: (error) => log("error", `realtime: ${error.message}`),
      onDisconnected: ({ reason, willReconnect }) => {
        log("warn", `realtime down (${reason})${willReconnect ? ", reconnecting" : ""}`);
        dropStream();
        setAvatar("idle");
      },
      onSessionRenewed: ({ reason }) => log("info", `realtime session renewed (${reason})`),
      onLog: log,
    },
  );
  // The provider owns the sample rates; the app is told in `core.ready`.
  bridge.setFormats(realtime.uplinkFormat, realtime.downlinkFormat);
}

async function shutdown(code: number): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  log("info", "shutting down");
  clearGreeting();
  await realtime?.close();
  await bridge.close();
  process.exit(code);
}

process.on("SIGINT", () => void shutdown(0));
process.on("SIGTERM", () => void shutdown(0));
// The app sets AKARI_SUPERVISED=1 when it spawns the core. If it is then
// SIGKILLed there is no `app.quit` and no socket close to notice, so watch the
// parent directly: an orphaned core keeps a paid Realtime session open and an
// unowned socket listening.
startParentWatchdog({ log, onOrphaned: () => void shutdown(0) });

await bridge.listen();
log("info", `socket ready at ${bridge.socketPath}`);
log("info", `${registry.list().length} tools registered: ${registry.list().map((t) => t.name).join(", ")}`);

if (realtime) {
  try {
    await realtime.connect();
    log("info", "realtime session live");
  } catch (error) {
    // The desktop layer is still worth running without voice, and the app's
    // reconnect loop would otherwise thrash against a core that exited.
    log("error", `could not open the realtime session: ${(error as Error).message}`);
    log("error", "core stays up; voice is unavailable until it is restarted");
  }
} else if (realtimeConfigError) {
  log("error", `voice is unavailable: ${realtimeConfigError}`);
  log("error", `checked for a .env in: ${envFilePaths().join(", ")}`);
  log("error", "the socket stays up so the desktop layer still runs");
} else {
  log("warn", "--no-realtime: socket only, no voice");
}
