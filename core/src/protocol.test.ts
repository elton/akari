import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  AUDIO_HEADER_BYTES,
  FrameError,
  FrameReader,
  FrameType,
  MAX_FRAME_BYTES,
  MESSAGE_TYPES,
  decodeAudioPayload,
  decodeControlPayload,
  encodeAudio,
  encodeControl,
  encodeFrame,
  envelope,
} from "./protocol.ts";

const bytes = (...values: number[]) => new Uint8Array(values);

function drain(reader: FrameReader, ...chunks: Uint8Array[]) {
  return chunks.flatMap((chunk) => reader.push(chunk));
}

describe("frame layout", () => {
  test("length prefix counts the type byte plus the payload", () => {
    const frame = encodeFrame(FrameType.Control, bytes(0xaa, 0xbb));
    // 4-byte BE length = 1 (type) + 2 (payload)
    expect(Array.from(frame.slice(0, 5))).toEqual([0, 0, 0, 3, 0x01]);
    expect(frame.byteLength).toEqual(7);
  });

  test("refuses to put an over-sized frame on the wire", () => {
    const payload = new Uint8Array(MAX_FRAME_BYTES);
    expect(() => encodeFrame(FrameType.Control, payload)).toThrow(FrameError);
  });
});

describe("audio frames", () => {
  test("header is big-endian and the PCM is untouched", () => {
    const pcm = bytes(0x01, 0x80, 0xff, 0x7f);
    const frame = encodeAudio(FrameType.AudioDownlink, {
      streamId: 0x0102_0304,
      sequence: 7,
      pcm,
    });
    const payload = frame.slice(5);
    expect(Array.from(payload.slice(0, AUDIO_HEADER_BYTES))).toEqual([
      0x01, 0x02, 0x03, 0x04, 0, 0, 0, 7,
    ]);
    expect(Array.from(payload.slice(AUDIO_HEADER_BYTES))).toEqual(Array.from(pcm));
  });

  test("round-trips through decodeAudioPayload", () => {
    const pcm = new Uint8Array(640).fill(0x5a);
    const frame = encodeAudio(FrameType.AudioUplink, { streamId: 9, sequence: 3, pcm });
    const decoded = decodeAudioPayload(frame.slice(5));
    expect(decoded).not.toBeNull();
    expect(decoded!.streamId).toBe(9);
    expect(decoded!.sequence).toBe(3);
    expect(decoded!.pcm).toEqual(pcm);
  });

  test("a payload shorter than the header is rejected, not guessed at", () => {
    expect(decodeAudioPayload(new Uint8Array(7))).toBeNull();
  });

  test("stream id survives the top bit", () => {
    const frame = encodeAudio(FrameType.AudioDownlink, {
      streamId: 0xffff_fffe,
      sequence: 0xffff_ffff,
      pcm: bytes(1, 2),
    });
    const decoded = decodeAudioPayload(frame.slice(5))!;
    expect(decoded.streamId).toBe(0xffff_fffe);
    expect(decoded.sequence).toBe(0xffff_ffff);
  });
});

describe("control frames", () => {
  test("round-trip keeps the envelope and the payload", () => {
    const message = envelope(
      { type: "avatar.setState", payload: { state: "talking", transitionMs: 120 } },
      "abc",
    );
    const decoded = decodeControlPayload(encodeControl(message).slice(5))!;
    expect(decoded).toEqual(message);
    expect(decoded.replyTo).toBe("abc");
  });

  test("messages with no payload omit the key entirely", () => {
    const json = JSON.parse(
      new TextDecoder().decode(encodeControl(envelope({ type: "ping" })).slice(5)),
    );
    expect("payload" in json).toBe(false);
    expect(json.v).toBe(1);
  });

  test("non-JSON is rejected rather than thrown", () => {
    expect(decodeControlPayload(bytes(0x7b, 0x7b))).toBeNull();
    expect(decodeControlPayload(new TextEncoder().encode("[1,2]"))).toBeNull();
  });
});

describe("FrameReader", () => {
  test("reassembles a frame split across three reads", () => {
    const frame = encodeControl(envelope({ type: "ping" }));
    const reader = new FrameReader();
    const out = drain(
      reader,
      frame.slice(0, 2),
      frame.slice(2, 6),
      frame.slice(6),
    );
    expect(out).toHaveLength(1);
    expect(decodeControlPayload(out[0]!.payload)!.type).toBe("ping");
  });

  test("splits several frames out of one read", () => {
    const a = encodeControl(envelope({ type: "ping" }));
    const b = encodeAudio(FrameType.AudioUplink, {
      streamId: 1,
      sequence: 0,
      pcm: new Uint8Array(16),
    });
    const merged = new Uint8Array(a.byteLength + b.byteLength);
    merged.set(a);
    merged.set(b, a.byteLength);

    const out = new FrameReader().push(merged);
    expect(out.map((f) => f.type)).toEqual([FrameType.Control, FrameType.AudioUplink]);
  });

  test("a retained partial frame is not corrupted by a reused chunk buffer", () => {
    const frame = encodeControl(envelope({ type: "pong" }));
    const reader = new FrameReader();
    // Hand over a buffer, then scribble on it — a socket layer is free to do
    // exactly this once `push` returns.
    const head = frame.slice(0, 5);
    expect(reader.push(head)).toHaveLength(0);
    head.fill(0xff);
    const out = reader.push(frame.slice(5));
    expect(out).toHaveLength(1);
    expect(decodeControlPayload(out[0]!.payload)!.type).toBe("pong");
  });

  test("a length prefix over 4 MiB is fatal, not resynced", () => {
    const reader = new FrameReader();
    const header = new Uint8Array(4);
    new DataView(header.buffer).setUint32(0, MAX_FRAME_BYTES + 1, false);
    expect(() => reader.push(header)).toThrow(FrameError);
    try {
      new FrameReader().push(header);
    } catch (error) {
      expect((error as FrameError).code).toBe("frame_too_large");
    }
  });

  test("a zero length prefix is fatal", () => {
    expect(() => new FrameReader().push(bytes(0, 0, 0, 0))).toThrow(FrameError);
  });

  test("an unknown type byte is fatal", () => {
    const reader = new FrameReader();
    try {
      reader.push(bytes(0, 0, 0, 1, 0x09));
      throw new Error("expected a FrameError");
    } catch (error) {
      expect((error as FrameError).code).toBe("bad_frame_type");
    }
  });

  test("byte-at-a-time delivery still yields whole frames", () => {
    const frame = encodeAudio(FrameType.AudioDownlink, {
      streamId: 2,
      sequence: 5,
      pcm: new Uint8Array(64).fill(7),
    });
    const reader = new FrameReader();
    let out: ReturnType<FrameReader["push"]> = [];
    for (const byte of frame) out = out.concat(reader.push(bytes(byte)));
    expect(out).toHaveLength(1);
    expect(decodeAudioPayload(out[0]!.payload)!.sequence).toBe(5);
  });
});

describe("mirror parity with Protocol.swift", () => {
  /**
   * docs/protocol.md is authoritative and says both mirrors must match it. The
   * compiler enforces that inside each language and nothing enforces it
   * *between* them: a message named `ui.notice` here and `ui.notify` there is a
   * frame the other side silently ignores (protocol.md §三 makes unknown types
   * non-fatal on purpose), so the failure is a feature that just does nothing.
   */
  const swiftSource = readFileSync(
    join(import.meta.dir, "..", "..", "app", "Sources", "AkariApp", "Protocol.swift"),
    "utf8",
  );

  function swiftMessageTypes(): string[] {
    const block = swiftSource.match(/public enum MessageType[^{]*\{([\s\S]*?)\n\}/);
    if (!block) throw new Error("could not find `enum MessageType` in Protocol.swift");
    const types: string[] = [];
    for (const line of block[1]!.split("\n")) {
      // `case pttDown = "ptt.down"` -> ptt.down; `case ping` -> ping
      const explicit = line.match(/^\s*case\s+\w+\s*=\s*"([^"]+)"/);
      if (explicit) {
        types.push(explicit[1]!);
        continue;
      }
      const implicit = line.match(/^\s*case\s+(\w+)\s*$/);
      if (implicit) types.push(implicit[1]!);
    }
    return types;
  }

  test("both sides know exactly the same message types", () => {
    expect([...swiftMessageTypes()].sort()).toEqual([...MESSAGE_TYPES].sort());
  });

  test("the extraction actually found something", () => {
    // Guards the test itself: a regex that silently matches nothing would make
    // the check above pass for the wrong reason.
    expect(swiftMessageTypes().length).toBe(MESSAGE_TYPES.length);
    expect(swiftMessageTypes()).toContain("clipboard.read.request");
  });

  test("every type the union declares is in the runtime list", () => {
    // The compiler covers the other direction (`_AllTypesListed` in protocol.ts).
    expect(new Set(MESSAGE_TYPES).size).toBe(MESSAGE_TYPES.length);
  });
});
