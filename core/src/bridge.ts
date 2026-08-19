import { chmodSync, statSync } from "node:fs";
import { mkdir, unlink } from "node:fs/promises";
import { connect as netConnect } from "node:net";
import { dirname } from "node:path";
import type { Socket, UnixSocketListener } from "bun";
import {
  describePeer,
  identifyPeer,
  peerPolicyFromEnv,
  type PeerIdentity,
  type PeerPolicy,
} from "./peer.ts";
import {
  DEFAULT_DOWNLINK_FORMAT,
  DEFAULT_UPLINK_FORMAT,
  FrameError,
  FrameReader,
  FrameType,
  PROTOCOL_VERSION,
  decodeAudioPayload,
  decodeControlPayload,
  encodeAudio,
  encodeControl,
  envelope,
  type AudioFormat,
  type AudioFrame,
  type AvatarState,
  type ClipboardReadResponsePayload,
  type ConfirmDecision,
  type ControlBody,
  type ControlMessage,
  type LogLevel,
  type ToolConfirmRequestPayload,
  type ToolUndoablePayload,
} from "./protocol.ts";

/**
 * Is somebody currently accepting connections on this socket path?
 *
 * Used before unlinking a leftover inode, to tell "a previous core crashed and left
 * this behind" apart from "a core is running right now". Deleting the latter's pathname
 * strands it: it keeps running with its metered Realtime session but becomes unreachable,
 * while clients attach to whoever binds next.
 *
 * The verdicts mirror `CoreProcess.probeSocket` on the Swift side so both processes agree
 * on what the socket means:
 *   - connect succeeds        → live
 *   - EAGAIN                  → live (the backlog is full, so somebody IS listening)
 *   - ENOENT                  → not live (no socket at all)
 *   - ECONNREFUSED            → not live (the inode outlived its server)
 *   - anything else / timeout → treated as live, deliberately
 *
 * That last line is the conservative choice: refusing to start is recoverable, deleting a
 * live core's socket is not.
 */
function isSocketLive(path: string): Promise<boolean> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (live: boolean) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.removeAllListeners();
      socket.destroy();
      resolve(live);
    };
    const socket = netConnect(path);
    const timer = setTimeout(() => finish(true), 500);
    timer.unref?.();
    socket.once("connect", () => finish(true));
    socket.once("error", (error: NodeJS.ErrnoException) => {
      finish(!(error.code === "ENOENT" || error.code === "ECONNREFUSED"));
    });
  });
}

/**
 * Unix domain socket server. The core listens, akari.app connects.
 *
 * Not a local HTTP port: on macOS Tahoe 26.3.x a re-signed app disappears from
 * the Local Network list and can no longer reach localhost (spec.md §3.1).
 *
 * Only one client at a time (protocol.md §一). The app owns reconnection; this
 * side never dials out and never replays anything after a reconnect.
 */

/** Default socket path; `AKARI_SOCKET` overrides it. Mirrored in Protocol.swift. */
export function defaultSocketPath(): string {
  const override = Bun.env.AKARI_SOCKET;
  if (override) return override;
  return `${Bun.env.HOME}/Library/Application Support/akari/core.sock`;
}

export interface BridgeHandlers {
  /** Handshake completed: `app.hello` accepted, `core.ready` sent. */
  onConnect?: (info: { appVersion: string; appBuild: string }) => void;
  onDisconnect?: (reason: string) => void;
  onPttDown?: () => void;
  onPttUp?: () => void;
  /** One 20ms microphone chunk. */
  onMicAudio?: (frame: AudioFrame) => void;
  /** The app finished rendering every sample of this playback stream. */
  onPlaybackDone?: (streamId: number) => void;
  onConfirmResponse?: (requestId: string, decision: ConfirmDecision) => void;
  onUndo?: (requestId: string) => void;
  /** User picked Quit from the menu bar. */
  onQuit?: () => void;
  /** Any control message, after the typed handlers above. */
  onMessage?: (message: ControlMessage) => void;
  /** Bridge-level diagnostics. Never carries credentials. */
  onLog?: (level: LogLevel, message: string) => void;
}

export interface BridgeOptions {
  socketPath?: string;
  uplink?: AudioFormat;
  downlink?: AudioFormat;
  coreVersion?: string;
  handlers?: BridgeHandlers;
  /**
   * Who may connect. Defaults to `peerPolicyFromEnv()`. Read `peer.ts` before
   * relying on it: the shipping tier is a speed bump, not isolation.
   */
  peerPolicy?: PeerPolicy;
}

/** How long the app gets to answer a clipboard read before it counts as failed. */
const CLIPBOARD_TIMEOUT_MS = 5_000;

/** What the app reported for one `clipboard.read` (protocol.md §3.7). */
export interface ClipboardReadResult {
  /** The text flavour of the pasteboard, or null when it holds none. */
  text: string | null;
  /** The pasteboard is marked concealed/transient; `text` is then always null. */
  concealed: boolean;
}

/**
 * A clipboard read either produced the app's answer or failed. Failure is a
 * distinct case rather than an empty answer: §3.7 forbids treating "could not
 * read" as "nothing was there", because the fallback that would follow is
 * `pbpaste`, which is the exact read this port exists to prevent.
 */
type ClipboardOutcome =
  | { ok: true; payload: ClipboardReadResponsePayload }
  | { ok: false; reason: string };

/** protocol.md §六: over 8 MiB queued, drop the oldest audio. Control never drops. */
const MAX_QUEUED_BYTES = 8 * 1024 * 1024;

interface Outbound {
  data: Uint8Array;
  isAudio: boolean;
}

interface Pending<T> {
  resolve: (value: T) => void;
  timer: ReturnType<typeof setTimeout> | null;
}

export class Bridge {
  readonly #socketPath: string;
  readonly #handlers: BridgeHandlers;
  #uplink: AudioFormat;
  #downlink: AudioFormat;
  readonly #coreVersion: string;
  readonly #peerPolicy: PeerPolicy;

  #listener: UnixSocketListener<undefined> | null = null;
  #socket: Socket<undefined> | null = null;
  #reader = new FrameReader();
  /** The handshake has to be the first frame; nothing else is accepted first. */
  #handshakeDone = false;
  #closing = false;

  #queue: Outbound[] = [];
  #queuedBytes = 0;
  #droppedAudio = 0;

  /** protocol.md §3.4: uint32, starts at 1, wraps past 0. */
  #nextStreamId = 1;
  /** Streams for which `audio.begin` was sent and `audio.end` was not. */
  #openStreams = new Set<number>();
  /** streamId -> next sequence number. Outlives `#openStreams` so a chunk that
   *  races `endPlayback` is still numbered correctly. */
  #streams = new Map<number, { sequence: number }>();
  /** True while the head of the send queue has been partially written. */
  #partialHead = false;

  #confirms = new Map<string, Pending<ConfirmDecision>>();
  #undos = new Map<string, Pending<boolean>>();
  #clipboardReads = new Map<string, Pending<ClipboardOutcome>>();
  #clipboardSeq = 0;
  /** Kernel-reported identity of the attached client, for the audit trail. */
  #peer: string | undefined;

  constructor(options: BridgeOptions = {}) {
    this.#socketPath = options.socketPath ?? defaultSocketPath();
    this.#uplink = options.uplink ?? DEFAULT_UPLINK_FORMAT;
    this.#downlink = options.downlink ?? DEFAULT_DOWNLINK_FORMAT;
    this.#coreVersion = options.coreVersion ?? "0.1.0";
    this.#peerPolicy = options.peerPolicy ?? peerPolicyFromEnv();
    this.#handlers = options.handlers ?? {};
  }

  get socketPath(): string {
    return this.#socketPath;
  }

  /** Announced in `core.ready`. Set before `listen()`; the app reads it once. */
  setFormats(uplink: AudioFormat, downlink: AudioFormat): void {
    this.#uplink = uplink;
    this.#downlink = downlink;
  }

  /**
   * Remove a stale socket file, bind, and accept exactly one client at a time —
   * a second connection is rejected with `error{code:"already_connected"}`.
   */
  async listen(): Promise<void> {
    if (this.#listener) return;
    // `sun_path` is 104 bytes on macOS. Past that bind() fails with a message
    // that says nothing about why, so check it here where the fix is obvious.
    const pathBytes = Buffer.byteLength(this.#socketPath, "utf8");
    if (pathBytes > 103) {
      throw new Error(
        `socket path is ${pathBytes} bytes, over the 103 byte limit macOS puts on a unix socket: ${this.#socketPath}`,
      );
    }
    // `mode` on mkdir is masked by umask, and so is the mode bind() gives the
    // socket inode — on a machine with umask 002/000 (plenty of dev shells, CI
    // and launchd plists set one) the defaults land world-writable. So: ask for
    // the tight mode, force it with chmod, then verify and refuse to run if it
    // did not take.
    const directory = dirname(this.#socketPath);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    try {
      chmodSync(directory, 0o700);
    } catch {
      // Someone else owns it. Not fixable from here; the check below explains
      // exactly what is wrong and stops startup.
    }
    assertPrivate(directory, "directory", 0o700);

    // A crash leaves the inode behind and bind() would fail with EADDRINUSE, so the
    // stale one has to go. But it must be PROVEN stale first.
    //
    // The earlier reasoning here — "safe because only one core may run at a time; a live
    // peer would have been rejected by the already_connected path" — was wrong.
    // already_connected is an application-layer rejection that happens after a client
    // connects to US. A second core never connects to the first one: it unlinks the
    // pathname and binds its own. The first core keeps running, keeps its metered Realtime
    // session open, and can never be reached again, while every client attaches to the
    // newcomer. Refuse to start instead.
    if (await isSocketLive(this.#socketPath)) {
      throw new Error(
        `another core is already serving ${this.#socketPath}; refusing to take over its socket`,
      );
    }
    await unlink(this.#socketPath).catch(() => {});

    // bind() happens inside Bun.listen. Narrowing umask around it closes the
    // window where the socket exists at 0777 & ~umask before the chmod below.
    const previousUmask = process.umask(0o177);
    try {
      this.#listener = Bun.listen<undefined>({
        unix: this.#socketPath,
        socket: {
          open: (socket) => this.#onOpen(socket),
          data: (socket, data) => this.#onData(socket, data),
          close: (socket) => this.#onClose(socket, "app closed the socket"),
          error: (socket, error) => this.#onClose(socket, `socket error: ${error.message}`),
          drain: (socket) => {
            if (socket === this.#socket) this.#flush();
          },
        },
      });
    } finally {
      process.umask(previousUmask);
    }

    try {
      chmodSync(this.#socketPath, 0o600);
      assertPrivate(this.#socketPath, "socket", 0o600);
    } catch (error) {
      this.#listener?.stop(true);
      this.#listener = null;
      await unlink(this.#socketPath).catch(() => {});
      throw error;
    }

    this.#log("info", `listening on ${this.#socketPath} (0600, in a 0700 directory)`);
    this.#log("info", `peer policy: ${this.#peerPolicy.describe}`);
    if (this.#peerPolicy.tier === "off") {
      this.#log("error", "peer verification is DISABLED: any local process can drive akari");
    }
  }

  async close(): Promise<void> {
    this.#closing = true;
    this.#settleAllPending("bridge closing");
    this.#socket?.end();
    this.#socket = null;
    this.#listener?.stop(true);
    this.#listener = null;
    await unlink(this.#socketPath).catch(() => {});
  }

  get connected(): boolean {
    return this.#socket !== null && this.#handshakeDone;
  }

  /**
   * Who is on the other end right now, as the audit trail records it, or
   * undefined when nobody is. Read per call rather than captured once: the app
   * can drop and a different client can take its place while the core stays up.
   */
  get peerDescription(): string | undefined {
    return this.#socket ? this.#peer : undefined;
  }

  // -------------------------------------------------------------------------
  // Outbound control
  // -------------------------------------------------------------------------

  /** Tell the app which loop to play. */
  setAvatarState(state: AvatarState, transitionMs?: number): void {
    this.#send({
      type: "avatar.setState",
      payload: {
        state,
        ...(transitionMs === undefined ? {} : { transitionMs }),
      },
    });
  }

  /** Open a playback stream and return its id. */
  beginPlayback(format?: AudioFormat): number {
    const streamId = this.#takeStreamId();
    this.#openStreams.add(streamId);
    this.#send({
      type: "audio.begin",
      payload: { streamId, ...(format ? { format } : {}) },
    });
    return streamId;
  }

  /** Push one chunk of TTS PCM into an open playback stream. */
  sendPlaybackAudio(streamId: number, pcm: Uint8Array): void {
    if (pcm.byteLength === 0) return;
    const state = this.#streams.get(streamId);
    if (!state) {
      this.#log("warn", `dropping audio for unknown stream ${streamId}`);
      return;
    }
    this.#enqueue(
      encodeAudio(FrameType.AudioDownlink, {
        streamId,
        sequence: state.sequence++,
        pcm,
      }),
      true,
    );
  }

  endPlayback(streamId: number): void {
    if (!this.#openStreams.has(streamId)) return;
    this.#openStreams.delete(streamId);
    this.#send({ type: "audio.end", payload: { streamId } });
  }

  /** Barge-in: drop queued audio. Omit the id to cancel every stream. */
  cancelPlayback(streamId?: number): void {
    if (streamId === undefined) {
      this.#openStreams.clear();
      this.#streams.clear();
      // Queued PCM for a cancelled stream is exactly what must not be played;
      // dropping it here also unblocks a backed-up socket.
      this.#dropQueuedAudio();
      this.#send({ type: "audio.cancel", payload: {} });
      return;
    }
    this.#openStreams.delete(streamId);
    this.#streams.delete(streamId);
    this.#dropQueuedAudio();
    this.#send({ type: "audio.cancel", payload: { streamId } });
  }

  /** Show the RED confirmation card and wait for the user. */
  requestConfirm(payload: ToolConfirmRequestPayload): Promise<ConfirmDecision> {
    if (!this.connected) return Promise.resolve<ConfirmDecision>("deny");
    return new Promise<ConfirmDecision>((resolve) => {
      const settle = (decision: ConfirmDecision) => {
        const pending = this.#confirms.get(payload.requestId);
        if (!pending) return;
        this.#confirms.delete(payload.requestId);
        if (pending.timer) clearTimeout(pending.timer);
        resolve(decision);
      };
      // `timeoutMs === 0` means wait forever (protocol.md §3.5).
      const timer =
        payload.timeoutMs > 0
          ? setTimeout(() => settle("timeout"), payload.timeoutMs)
          : null;
      this.#confirms.set(payload.requestId, { resolve: settle, timer });
      this.#send({ type: "tool.confirm.request", payload });
    });
  }

  /** Show the YELLOW 1.5s undo toast. Resolves true if the user undid it. */
  notifyUndoable(payload: ToolUndoablePayload): Promise<boolean> {
    if (!this.connected) return Promise.resolve(false);
    return new Promise<boolean>((resolve) => {
      const settle = (undone: boolean) => {
        const pending = this.#undos.get(payload.requestId);
        if (!pending) return;
        this.#undos.delete(payload.requestId);
        if (pending.timer) clearTimeout(pending.timer);
        resolve(undone);
      };
      const timer = setTimeout(() => settle(false), Math.max(0, payload.undoMs));
      this.#undos.set(payload.requestId, { resolve: settle, timer });
      this.#send({ type: "tool.undoable", payload });
    });
  }

  /**
   * Put one short line in front of the user (the menu bar status item).
   *
   * Deliberately not `log`: protocol.md §3.6 says `log` carries no control
   * semantics and it lands in os_log, where nobody is looking. The cases this
   * exists for are the ones where she goes quiet and the silence is
   * indistinguishable from thinking — no session, a press too short to commit,
   * a reply the service refused.
   */
  sendNotice(level: LogLevel, text: string): void {
    this.#send({ type: "ui.notice", payload: { level, text } });
  }

  /**
   * Ask the app to read the pasteboard (protocol.md §3.7).
   *
   * This is a port, not a convenience: `pbpaste` cannot see the
   * `org.nspasteboard.ConcealedType` marker a password manager sets, so a
   * core-side read cannot tell a copied URL from a copied master password.
   * A dropped connection rejects — the core must never fall back to `pbpaste`.
   */
  readClipboardText(signal?: AbortSignal): Promise<ClipboardReadResult> {
    if (!this.connected) {
      return Promise.reject(new Error("clipboard read failed: akari.app is not connected"));
    }
    const requestId = `cb-${++this.#clipboardSeq}`;
    return new Promise<ClipboardOutcome>((resolve) => {
      const settle = (outcome: ClipboardOutcome) => {
        const pending = this.#clipboardReads.get(requestId);
        if (!pending) return;
        this.#clipboardReads.delete(requestId);
        if (pending.timer) clearTimeout(pending.timer);
        resolve(outcome);
      };
      const timer = setTimeout(
        () => settle({ ok: false, reason: `the app did not answer in ${CLIPBOARD_TIMEOUT_MS}ms` }),
        CLIPBOARD_TIMEOUT_MS,
      );
      this.#clipboardReads.set(requestId, { resolve: settle, timer });
      signal?.addEventListener(
        "abort",
        () => settle({ ok: false, reason: "the read was aborted" }),
        { once: true },
      );
      this.#send({ type: "clipboard.read.request", payload: { requestId } });
    }).then((outcome) => {
      if (!outcome.ok) throw new Error(`clipboard read failed: ${outcome.reason}`);
      return {
        text: outcome.payload.text ?? null,
        concealed: outcome.payload.concealed,
      };
    });
  }

  /** Ask the app to quit (core-initiated shutdown). */
  requestAppQuit(): void {
    this.#send({ type: "app.quit" });
  }

  /** Forward a core-side log line to the app's console. */
  sendLog(level: LogLevel, message: string): void {
    this.#send({ type: "log", payload: { level, message } });
  }

  // -------------------------------------------------------------------------
  // Connection lifecycle
  // -------------------------------------------------------------------------

  #onOpen(socket: Socket<undefined>): void {
    // Identity first: an unrecognised process must not even learn whether the
    // real app is already attached.
    const peer = peerOf(socket);
    const verdict = this.#peerPolicy.check(peer);
    if (!verdict.allowed) {
      this.#log(
        "error",
        `AUDIT peer refused (policy ${this.#peerPolicy.tier}): ${describePeer(peer)} — ${verdict.reason}`,
      );
      socket.write(
        encodeControl(
          envelope({
            type: "error",
            payload: {
              code: "unauthorized",
              message: "this process is not a recognised akari.app",
              fatal: true,
            },
          }),
        ),
      );
      socket.end();
      return;
    }

    if (this.#socket) {
      // protocol.md §一: exactly one client. Answer, then hang up.
      const frame = encodeControl(
        envelope({
          type: "error",
          payload: {
            code: "already_connected",
            message: "another akari.app is already connected",
            fatal: true,
          },
        }),
      );
      socket.write(frame);
      socket.end();
      return;
    }
    this.#socket = socket;
    this.#peer = describePeer(peer);
    this.#reader = new FrameReader();
    this.#handshakeDone = false;
    this.#queue = [];
    this.#queuedBytes = 0;
    this.#droppedAudio = 0;
    this.#log(
      "info",
      `AUDIT peer accepted (policy ${this.#peerPolicy.tier}): ${describePeer(peer)}`,
    );
    this.#log("info", "app connected; waiting for app.hello");
  }

  #onData(socket: Socket<undefined>, chunk: Uint8Array): void {
    if (socket !== this.#socket) return;
    let frames;
    try {
      frames = this.#reader.push(chunk);
    } catch (error) {
      if (error instanceof FrameError) {
        this.#fatal(error.code, error.message);
        return;
      }
      throw error;
    }

    for (const frame of frames) {
      if (this.#socket !== socket) return; // torn down mid-batch
      if (frame.type === FrameType.Control) {
        this.#handleControl(frame.payload);
      } else if (frame.type === FrameType.AudioUplink) {
        this.#handleAudio(frame.payload);
      } else {
        // 0x03 is core -> app only; receiving it means the app is confused.
        this.#fatal("bad_frame_type", "audio.downlink is not valid app → core");
        return;
      }
    }
  }

  #handleAudio(payload: Uint8Array): void {
    if (!this.#handshakeDone) {
      this.#fatal("handshake_expected", "audio arrived before app.hello");
      return;
    }
    const frame = decodeAudioPayload(payload);
    if (!frame) {
      this.#badPayload(undefined, "audio frame shorter than its 8 byte header");
      return;
    }
    this.#handlers.onMicAudio?.(frame);
  }

  #handleControl(payload: Uint8Array): void {
    const message = decodeControlPayload(payload);
    if (!message) {
      this.#badPayload(undefined, "control frame is not a JSON object");
      return;
    }
    if (typeof message.v === "number" && message.v !== PROTOCOL_VERSION) {
      this.#fatal(
        "protocol_mismatch",
        `envelope v=${message.v}, core speaks v=${PROTOCOL_VERSION}`,
      );
      return;
    }
    // `type` comes off the wire, so it is read as an unknown string rather
    // than through the ControlBody union — an unrecognised value has to reach
    // the `default` branch and be ignored, not fail to type-check.
    const type = (message as { type?: unknown }).type;
    if (typeof type !== "string" || type.length === 0) {
      this.#badPayload(message.id, "control frame has no `type`");
      return;
    }

    if (!this.#handshakeDone && type !== "app.hello") {
      this.#fatal("handshake_expected", `first frame was ${type}, not app.hello`);
      return;
    }

    switch (type) {
      case "app.hello":
        this.#handleHello(message);
        return;

      case "ping":
        this.#send({ type: "pong" }, message.id);
        return;
      case "pong":
        return;

      case "ptt.down":
        this.#handlers.onPttDown?.();
        break;
      case "ptt.up":
        this.#handlers.onPttUp?.();
        break;

      case "audio.done": {
        const streamId = numberField(message, "streamId");
        if (streamId === null) {
          this.#badPayload(message.id, "audio.done: streamId must be a number");
          return;
        }
        this.#streams.delete(streamId);
        this.#handlers.onPlaybackDone?.(streamId);
        break;
      }

      case "tool.confirm.response": {
        const requestId = stringField(message, "requestId");
        const decision = stringField(message, "decision");
        if (!requestId) {
          this.#badPayload(message.id, "tool.confirm.response: requestId missing");
          return;
        }
        // protocol.md §3.5: anything that is not a literal approve is a deny.
        const verdict: ConfirmDecision =
          decision === "approve" ? "approve" : decision === "timeout" ? "timeout" : "deny";
        this.#confirms.get(requestId)?.resolve(verdict);
        this.#handlers.onConfirmResponse?.(requestId, verdict);
        break;
      }

      case "tool.undo": {
        const requestId = stringField(message, "requestId");
        if (!requestId) {
          this.#badPayload(message.id, "tool.undo: requestId missing");
          return;
        }
        // A `tool.undo` after the window closed is ignored (protocol.md §3.5):
        // the entry is already gone, so this resolves nothing.
        this.#undos.get(requestId)?.resolve(true);
        this.#handlers.onUndo?.(requestId);
        break;
      }

      case "clipboard.read.response": {
        const requestId = stringField(message, "requestId");
        if (!requestId) {
          this.#badPayload(message.id, "clipboard.read.response: requestId missing");
          return;
        }
        const raw = payloadOf(message)["text"];
        const concealed = booleanField(message, "concealed");
        this.#clipboardReads.get(requestId)?.resolve({
          ok: true,
          payload: {
            requestId,
            concealed,
            // §3.7: `concealed` wins. An app that sent both is not trusted to
            // have meant it, and the text is dropped here rather than reasoned
            // about downstream.
            ...(!concealed && typeof raw === "string" ? { text: raw } : {}),
          },
        });
        break;
      }

      case "app.quit":
        this.#handlers.onQuit?.();
        break;

      case "error": {
        const code = stringField(message, "code") || "unknown";
        const text = stringField(message, "message");
        this.#log("error", `app error ${code}: ${text}`);
        if (booleanField(message, "fatal")) {
          this.#teardown(`app sent fatal ${code}`);
          return;
        }
        break;
      }

      case "log": {
        const level = stringField(message, "level");
        this.#log(
          isLogLevel(level) ? level : "info",
          `[app] ${stringField(message, "message")}`,
        );
        break;
      }

      default:
        // protocol.md §三: unknown types are ignored, never fatal. This is the
        // only forward-compatibility mechanism the protocol has.
        this.#log("warn", `ignoring unknown control type ${type}`);
        return;
    }

    this.#handlers.onMessage?.(message);
  }

  #handleHello(message: ControlMessage): void {
    if (this.#handshakeDone) {
      this.#log("warn", "ignoring a second app.hello");
      return;
    }
    const version = numberField(message, "protocolVersion");
    if (version !== PROTOCOL_VERSION) {
      this.#fatal(
        "protocol_mismatch",
        `app speaks v${version}, core speaks v${PROTOCOL_VERSION}`,
      );
      return;
    }
    this.#handshakeDone = true;
    this.#nextStreamId = 1;
    this.#streams.clear();
    this.#openStreams.clear();

    this.#send(
      {
        type: "core.ready",
        payload: {
          protocolVersion: PROTOCOL_VERSION,
          coreVersion: this.#coreVersion,
          uplink: this.#uplink,
          downlink: this.#downlink,
        },
      },
      message.id,
    );

    const info = {
      appVersion: stringField(message, "appVersion") || "unknown",
      appBuild: stringField(message, "appBuild") || "0",
    };
    this.#log("info", `handshake done with akari.app ${info.appVersion} (${info.appBuild})`);
    this.#handlers.onConnect?.(info);
    this.#handlers.onMessage?.(message);
  }

  #onClose(socket: Socket<undefined>, reason: string): void {
    if (socket !== this.#socket) return;
    this.#teardown(reason);
  }

  /**
   * protocol.md §六: reset PTT, deny every waiting confirmation, drop in-flight
   * playback. Nothing is replayed when the app comes back.
   */
  #teardown(reason: string): void {
    const socket = this.#socket;
    this.#socket = null;
    this.#handshakeDone = false;
    this.#queue = [];
    this.#queuedBytes = 0;
    this.#streams.clear();
    this.#openStreams.clear();
    this.#reader = new FrameReader();
    this.#settleAllPending(reason);
    socket?.end();
    if (!this.#closing) {
      this.#log("warn", `app disconnected: ${reason}`);
      this.#handlers.onDisconnect?.(reason);
    }
  }

  #settleAllPending(reason: string): void {
    for (const [, pending] of this.#confirms) {
      if (pending.timer) clearTimeout(pending.timer);
      pending.resolve("deny");
    }
    this.#confirms.clear();
    for (const [, pending] of this.#undos) {
      if (pending.timer) clearTimeout(pending.timer);
      pending.resolve(false);
    }
    this.#undos.clear();
    for (const [, pending] of this.#clipboardReads) {
      if (pending.timer) clearTimeout(pending.timer);
      // §3.7: a read that loses the connection is a failure, never a retry
      // through `pbpaste`.
      pending.resolve({ ok: false, reason });
    }
    this.#clipboardReads.clear();
  }

  // -------------------------------------------------------------------------
  // Wire helpers
  // -------------------------------------------------------------------------

  #takeStreamId(): number {
    const id = this.#nextStreamId;
    // uint32, wrapping, skipping 0 (reserved for "no stream").
    this.#nextStreamId = this.#nextStreamId >= 0xffff_ffff ? 1 : this.#nextStreamId + 1;
    this.#streams.set(id, { sequence: 0 });
    return id;
  }

  #send(body: ControlBody, replyTo?: string): void {
    if (!this.#socket) return;
    this.#enqueue(encodeControl(envelope(body, replyTo)), false);
  }

  #fatal(code: string, message: string): void {
    this.#log("error", `protocol violation ${code}: ${message}`);
    if (this.#socket) {
      // Best effort: a desynchronised peer may never parse this.
      this.#enqueue(
        encodeControl(envelope({ type: "error", payload: { code, message, fatal: true } })),
        false,
      );
    }
    this.#teardown(code);
  }

  #badPayload(replyTo: string | undefined, message: string): void {
    this.#log("warn", `bad payload: ${message}`);
    this.#send({ type: "error", payload: { code: "bad_payload", message, fatal: false } }, replyTo);
  }

  #enqueue(data: Uint8Array, isAudio: boolean): void {
    if (!this.#socket) return;
    this.#queue.push({ data, isAudio });
    this.#queuedBytes += data.byteLength;

    while (this.#queuedBytes > MAX_QUEUED_BYTES) {
      const index = this.#queue.findIndex((f) => f.isAudio);
      if (index < 0) break; // control frames are never dropped
      this.#queuedBytes -= this.#queue.splice(index, 1)[0]!.data.byteLength;
      this.#droppedAudio += 1;
    }
    if (this.#droppedAudio > 0 && this.#droppedAudio % 50 === 1) {
      this.#log(
        "warn",
        `send queue over 8 MiB: ${this.#droppedAudio} audio frames dropped — the app is not draining`,
      );
    }
    this.#flush();
  }

  /** Drop queued PCM without touching queued control frames. */
  #dropQueuedAudio(): void {
    if (this.#queue.length === 0) return;
    // The head may be half-written; splitting it would corrupt the stream.
    const head = this.#partialHead ? this.#queue.slice(0, 1) : [];
    const tail = this.#queue.slice(head.length).filter((f) => !f.isAudio);
    this.#queue = [...head, ...tail];
    this.#queuedBytes = this.#queue.reduce((n, f) => n + f.data.byteLength, 0);
  }

  #flush(): void {
    const socket = this.#socket;
    if (!socket) return;
    while (this.#queue.length > 0) {
      const head = this.#queue[0]!;
      let written: number;
      try {
        written = socket.write(head.data);
      } catch (error) {
        this.#teardown(`write failed: ${(error as Error).message}`);
        return;
      }
      if (written >= head.data.byteLength) {
        this.#queue.shift();
        this.#queuedBytes -= head.data.byteLength;
        this.#partialHead = false;
        continue;
      }
      if (written > 0) {
        head.data = head.data.subarray(written);
        this.#queuedBytes -= written;
      }
      // Backpressure: the rest goes out from the `drain` callback.
      this.#partialHead = true;
      return;
    }
    this.#partialHead = false;
  }

  #log(level: LogLevel, message: string): void {
    this.#handlers.onLog?.(level, message);
  }
}

// ---------------------------------------------------------------------------
// Payload field readers — the app is a peer, not a trusted caller.
// ---------------------------------------------------------------------------

function payloadOf(message: ControlMessage): Record<string, unknown> {
  const payload = (message as { payload?: unknown }).payload;
  return payload && typeof payload === "object" && !Array.isArray(payload)
    ? (payload as Record<string, unknown>)
    : {};
}

function stringField(message: ControlMessage, key: string): string {
  const value = payloadOf(message)[key];
  return typeof value === "string" ? value : "";
}

function numberField(message: ControlMessage, key: string): number | null {
  const value = payloadOf(message)[key];
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function booleanField(message: ControlMessage, key: string): boolean {
  return payloadOf(message)[key] === true;
}

function isLogLevel(value: string): value is LogLevel {
  return value === "debug" || value === "info" || value === "warn" || value === "error";
}

// ---------------------------------------------------------------------------
// Peer identity and socket hygiene
// ---------------------------------------------------------------------------

/**
 * Bun's `Socket` carries the accepted file descriptor on `fd`; it is on the
 * prototype but missing from `@types/bun`, hence the cast. Without a descriptor
 * there is nothing to ask the kernel about, and the policy fails closed.
 */
function peerOf(socket: Socket<undefined>): PeerIdentity | null {
  const fd = (socket as unknown as { fd?: unknown }).fd;
  if (typeof fd !== "number" || fd < 0) return null;
  return identifyPeer(fd);
}

/**
 * The socket and its directory must be reachable by this user only. A wrong
 * mode here is not a warning: it means anything on the machine can talk to the
 * core, so startup stops.
 */
function assertPrivate(path: string, what: string, expected: number): void {
  const stats = statSync(path);
  const mode = stats.mode & 0o777;
  const self = process.getuid?.();
  if (self !== undefined && stats.uid !== self) {
    throw new Error(`refusing to run: ${what} ${path} is owned by uid ${stats.uid}, not ${self}`);
  }
  if (mode !== expected) {
    throw new Error(
      `refusing to run: ${what} ${path} is mode 0${mode.toString(8)}, expected 0${expected.toString(8)} — ` +
        "anything on this machine could then impersonate akari.app",
    );
  }
}
