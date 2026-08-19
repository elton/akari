/**
 * TypeScript mirror of the wire contract in docs/protocol.md.
 *
 * docs/protocol.md is authoritative: change it first, then both mirrors
 * (this file and app/Sources/AkariApp/Protocol.swift) in the same commit.
 */

/** Bumped on any breaking change to the frame layout or message set. */
export const PROTOCOL_VERSION = 1;

export const LENGTH_PREFIX_BYTES = 4;
export const TYPE_BYTE_BYTES = 1;

/**
 * Largest accepted value of the length prefix. Anything larger means the stream
 * is desynchronised: close the connection, never try to resync.
 */
export const MAX_FRAME_BYTES = 4 * 1024 * 1024;

/** Frame type byte. */
export const FrameType = {
  /** UTF-8 JSON control message; payload is a ControlMessage. */
  Control: 0x01,
  /** Microphone PCM, app -> core; payload is an AudioFrame. */
  AudioUplink: 0x02,
  /** Speaker PCM, core -> app; payload is an AudioFrame. */
  AudioDownlink: 0x03,
} as const;
export type FrameType = (typeof FrameType)[keyof typeof FrameType];

/** streamId (u32 BE) + sequence (u32 BE), then raw PCM16LE samples. */
export const AUDIO_HEADER_BYTES = 8;

export interface AudioFrame {
  streamId: number;
  sequence: number;
  /** Interleaved PCM16 little-endian. */
  pcm: Uint8Array;
}

export type AvatarState =
  | "idle"
  | "listening"
  | "thinking"
  | "talking"
  | "greeting";

/**
 * ADR-002 four-level risk model. `never` tools are not registered at all; the
 * value exists so the level can be named in errors and logs.
 */
export type RiskLevel = "green" | "yellow" | "red" | "never";

export type ConfirmDecision = "approve" | "deny" | "timeout";

export type PttSource = "hotkey" | "click" | "menu";

export type LogLevel = "debug" | "info" | "warn" | "error";

/**
 * PCM description. Negotiated in `core.ready` instead of being hardcoded on both
 * sides — the core owns the realtime session, so the core owns the sample rates.
 */
export interface AudioFormat {
  /** Samples per second, e.g. 16000 uplink / 24000 downlink. */
  sampleRate: number;
  /** 1 = mono. */
  channels: number;
  /** Always "pcm16le" in protocol version 1. */
  encoding: "pcm16le";
  /** Milliseconds of audio per frame, e.g. 20. */
  frameMillis: number;
}

/** Bytes of PCM in one frame at this format. */
export function bytesPerFrame(f: AudioFormat): number {
  return (f.sampleRate * f.channels * 2 * f.frameMillis) / 1000;
}

/** Defaults the core announces unless the provider requires otherwise. */
export const DEFAULT_UPLINK_FORMAT: AudioFormat = {
  sampleRate: 16000,
  channels: 1,
  encoding: "pcm16le",
  frameMillis: 20,
};

export const DEFAULT_DOWNLINK_FORMAT: AudioFormat = {
  sampleRate: 24000,
  channels: 1,
  encoding: "pcm16le",
  frameMillis: 20,
};

// ---------------------------------------------------------------------------
// Control messages
// ---------------------------------------------------------------------------

export interface AppHelloPayload {
  protocolVersion: number;
  appVersion: string;
  appBuild: string;
}

export interface CoreReadyPayload {
  protocolVersion: number;
  coreVersion: string;
  uplink: AudioFormat;
  downlink: AudioFormat;
}

export interface AvatarSetStatePayload {
  state: AvatarState;
  /** Cross-fade duration; omit for the app default (~120ms). */
  transitionMs?: number;
}

export interface PttPayload {
  source: PttSource;
}

export interface AudioBeginPayload {
  streamId: number;
  /** Overrides the `core.ready` format for this stream only. */
  format?: AudioFormat;
}

export interface AudioEndPayload {
  streamId: number;
}

export interface AudioCancelPayload {
  /** Omit to cancel every in-flight playback stream. */
  streamId?: number;
}

export interface AudioDonePayload {
  streamId: number;
}

export interface ToolConfirmRequestPayload {
  requestId: string;
  tool: string;
  risk: RiskLevel;
  /** One line, shown as the card title. */
  title: string;
  detail?: string;
  /** Verbatim command / path / payload. RED cards must show it unedited. */
  command?: string;
  /** Auto-deny after this many ms; 0 waits forever. */
  timeoutMs: number;
}

export interface ToolConfirmResponsePayload {
  requestId: string;
  decision: ConfirmDecision;
}

export interface ToolUndoablePayload {
  requestId: string;
  tool: string;
  title: string;
  /** Undo window in ms (1500 per ADR-002). */
  undoMs: number;
}

export interface ToolUndoPayload {
  requestId: string;
}

export interface ClipboardReadRequestPayload {
  requestId: string;
  /** Truncate on the app side; omit to have the core do it. */
  maxChars?: number;
}

export interface ClipboardReadResponsePayload {
  requestId: string;
  /**
   * The pasteboard carries `org.nspasteboard.ConcealedType` or
   * `org.nspasteboard.TransientType`. `text` is then absent — the app does not
   * read it, so the core has nothing to leak.
   */
  concealed: boolean;
  text?: string;
}

export interface UiNoticePayload {
  /** Picks the tone; `error` and `warn` are the ones worth interrupting for. */
  level: LogLevel;
  /** One short line, shown to the user. Chinese, no credentials. */
  text: string;
}

export interface ErrorPayload {
  code: string;
  message: string;
  /** true = sender closes the connection right after this frame. */
  fatal: boolean;
}

export interface LogPayload {
  level: LogLevel;
  message: string;
}

/** Discriminated union of every control message body. */
export type ControlBody =
  | { type: "app.hello"; payload: AppHelloPayload }
  | { type: "core.ready"; payload: CoreReadyPayload }
  | { type: "avatar.setState"; payload: AvatarSetStatePayload }
  | { type: "ptt.down"; payload: PttPayload }
  | { type: "ptt.up"; payload: PttPayload }
  | { type: "audio.begin"; payload: AudioBeginPayload }
  | { type: "audio.end"; payload: AudioEndPayload }
  | { type: "audio.cancel"; payload: AudioCancelPayload }
  | { type: "audio.done"; payload: AudioDonePayload }
  | { type: "tool.confirm.request"; payload: ToolConfirmRequestPayload }
  | { type: "tool.confirm.response"; payload: ToolConfirmResponsePayload }
  | { type: "tool.undoable"; payload: ToolUndoablePayload }
  | { type: "tool.undo"; payload: ToolUndoPayload }
  | { type: "clipboard.read.request"; payload: ClipboardReadRequestPayload }
  | { type: "clipboard.read.response"; payload: ClipboardReadResponsePayload }
  | { type: "ui.notice"; payload: UiNoticePayload }
  | { type: "app.quit" }
  | { type: "ping" }
  | { type: "pong" }
  | { type: "error"; payload: ErrorPayload }
  | { type: "log"; payload: LogPayload };

export type MessageType = ControlBody["type"];

/**
 * Every message type, as a runtime value.
 *
 * Types are erased at runtime, so without this there is nothing to compare the
 * Swift mirror against — and a `"ui.notify"` on one side and a `"ui.notice"` on
 * the other is a silent no-op, not a compile error. `protocol.test.ts` reads
 * `Protocol.swift` and checks this list against it.
 *
 * The `_AllTypesListed` line below makes tsc fail if a message is added to
 * `ControlBody` and not added here.
 */
export const MESSAGE_TYPES = [
  "app.hello",
  "core.ready",
  "avatar.setState",
  "ptt.down",
  "ptt.up",
  "audio.begin",
  "audio.end",
  "audio.cancel",
  "audio.done",
  "tool.confirm.request",
  "tool.confirm.response",
  "tool.undoable",
  "tool.undo",
  "clipboard.read.request",
  "clipboard.read.response",
  "ui.notice",
  "app.quit",
  "ping",
  "pong",
  "error",
  "log",
] as const satisfies readonly MessageType[];

type AssertNever<T extends never> = T;
type _AllTypesListed = AssertNever<
  Exclude<MessageType, (typeof MESSAGE_TYPES)[number]>
>;

/** Envelope common to every control message. */
export interface Envelope {
  v: number;
  /** Unique per sender; correlates request/response pairs. */
  id: string;
  /** Unix epoch milliseconds at send time. */
  ts: number;
  /** Set on a message that answers another message's `id`. */
  replyTo?: string;
}

export type ControlMessage = Envelope & ControlBody;

/** Fill in `v`, `id` and `ts` around a body. */
export function envelope(
  body: ControlBody,
  replyTo?: string,
): ControlMessage {
  return {
    v: PROTOCOL_VERSION,
    id: crypto.randomUUID(),
    ts: Date.now(),
    ...(replyTo ? { replyTo } : {}),
    ...body,
  } as ControlMessage;
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

/**
 * A frame the peer sent that the stream cannot recover from. `code` is the
 * `error.code` to put on the wire before closing (protocol.md §3.6).
 */
export class FrameError extends Error {
  constructor(
    readonly code: "frame_too_large" | "bad_frame_type",
    message: string,
  ) {
    super(message);
    this.name = "FrameError";
  }
}

/** Serialise one frame: 4-byte BE length (type byte + payload) + type + payload. */
export function encodeFrame(type: FrameType, payload: Uint8Array): Uint8Array {
  const length = TYPE_BYTE_BYTES + payload.byteLength;
  if (length > MAX_FRAME_BYTES) {
    throw new FrameError(
      "frame_too_large",
      `frame of ${length} bytes exceeds the ${MAX_FRAME_BYTES} byte ceiling`,
    );
  }
  const out = new Uint8Array(LENGTH_PREFIX_BYTES + length);
  const view = new DataView(out.buffer);
  view.setUint32(0, length, false); // big-endian, protocol.md §二
  out[LENGTH_PREFIX_BYTES] = type;
  out.set(payload, LENGTH_PREFIX_BYTES + TYPE_BYTE_BYTES);
  return out;
}

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: false });

export function encodeControl(message: ControlMessage): Uint8Array {
  return encodeFrame(FrameType.Control, textEncoder.encode(JSON.stringify(message)));
}

/**
 * Audio payload: streamId (u32 BE) + sequence (u32 BE) + raw PCM16LE.
 *
 * The two header fields are big-endian while the samples stay little-endian.
 * That mismatch is deliberate (protocol.md §二): PCM16LE is what CoreAudio and
 * the Realtime API both speak natively, so converting would cost a pass over
 * every sample for nothing.
 */
export function encodeAudio(type: FrameType, frame: AudioFrame): Uint8Array {
  const payload = new Uint8Array(AUDIO_HEADER_BYTES + frame.pcm.byteLength);
  const view = new DataView(payload.buffer);
  view.setUint32(0, frame.streamId >>> 0, false);
  view.setUint32(4, frame.sequence >>> 0, false);
  payload.set(frame.pcm, AUDIO_HEADER_BYTES);
  return encodeFrame(type, payload);
}

/** Returns null when the payload is shorter than its 8-byte header. */
export function decodeAudioPayload(payload: Uint8Array): AudioFrame | null {
  if (payload.byteLength < AUDIO_HEADER_BYTES) return null;
  const view = new DataView(
    payload.buffer,
    payload.byteOffset,
    payload.byteLength,
  );
  return {
    streamId: view.getUint32(0, false),
    sequence: view.getUint32(4, false),
    // Copied, not a subarray: the reader's backing buffer is reused, and a view
    // into it would change under the consumer's feet.
    pcm: payload.slice(AUDIO_HEADER_BYTES),
  };
}

/** Parse a control payload. Returns null when it is not a JSON object. */
export function decodeControlPayload(payload: Uint8Array): ControlMessage | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(textDecoder.decode(payload));
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }
  return parsed as ControlMessage;
}

const EMPTY = new Uint8Array(0);

export interface Frame {
  type: FrameType;
  payload: Uint8Array;
}

/**
 * Incremental reader: feed it socket chunks, get whole frames back. A socket
 * read carries no message boundaries, so both sides need one of these
 * (protocol.md §二).
 */
export class FrameReader {
  #buffer: Uint8Array = EMPTY;
  /** Bytes at the front of `#buffer` already handed out, during one `push`. */
  #offset = 0;

  /**
   * Append received bytes and drain every complete frame.
   *
   * Throws `FrameError` when the stream is desynchronised. The caller must send
   * the matching fatal `error` and close — protocol.md §二 forbids resyncing.
   */
  push(chunk: Uint8Array): Frame[] {
    this.#append(chunk);

    const frames: Frame[] = [];
    for (;;) {
      const available = this.#buffer.byteLength - this.#offset;
      if (available < LENGTH_PREFIX_BYTES) break;

      const view = new DataView(
        this.#buffer.buffer,
        this.#buffer.byteOffset + this.#offset,
        available,
      );
      const length = view.getUint32(0, false);
      if (length < TYPE_BYTE_BYTES) {
        throw new FrameError(
          "bad_frame_type",
          "frame with a zero length prefix",
        );
      }
      if (length > MAX_FRAME_BYTES) {
        throw new FrameError(
          "frame_too_large",
          `length prefix ${length} exceeds ${MAX_FRAME_BYTES}`,
        );
      }
      if (available - LENGTH_PREFIX_BYTES < length) break;

      const start = this.#offset + LENGTH_PREFIX_BYTES;
      const type = this.#buffer[start] as number;
      if (type !== FrameType.Control && type !== FrameType.AudioUplink && type !== FrameType.AudioDownlink) {
        throw new FrameError(
          "bad_frame_type",
          `0x${type.toString(16).padStart(2, "0")} is not a known frame type`,
        );
      }
      frames.push({
        type: type as FrameType,
        payload: this.#buffer.slice(start + TYPE_BYTE_BYTES, start + length),
      });
      this.#offset = start + length;
    }

    // Never hold a borrowed buffer across calls. `#append` adopts the caller's
    // chunk without copying — the steady state on a local socket, where every
    // read is whole frames — but the socket layer is free to reuse that buffer
    // once `push` returns. Anything still unparsed is therefore copied out
    // here, whether or not the offset moved.
    this.#buffer =
      this.#offset === this.#buffer.byteLength
        ? EMPTY
        : this.#buffer.slice(this.#offset);
    this.#offset = 0;

    return frames;
  }

  /** `#offset` is always 0 on entry — `push` compacts before it returns. */
  #append(chunk: Uint8Array): void {
    if (this.#buffer.byteLength === 0) {
      this.#buffer = chunk;
      return;
    }
    const merged = new Uint8Array(this.#buffer.byteLength + chunk.byteLength);
    merged.set(this.#buffer, 0);
    merged.set(chunk, this.#buffer.byteLength);
    this.#buffer = merged;
  }
}
