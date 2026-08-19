import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, statSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Socket } from "bun";
import { Bridge } from "./bridge.ts";
import { allowAnyPeer, executablePathPolicy } from "./peer.ts";
import { ToolExecutor, createRegistry } from "./tools/index.ts";
import {
  DEFAULT_DOWNLINK_FORMAT,
  DEFAULT_UPLINK_FORMAT,
  FrameReader,
  FrameType,
  decodeAudioPayload,
  decodeControlPayload,
  encodeAudio,
  encodeControl,
  envelope,
  type AudioFrame,
  type ControlBody,
  type ControlMessage,
} from "./protocol.ts";

/**
 * These run the real thing: a Bun unix socket, the real framing, and a stand-in
 * for akari.app on the other end. Anything mocked here would be the part most
 * likely to be wrong.
 */

const cleanups: Array<() => Promise<void>> = [];

afterEach(async () => {
  while (cleanups.length) await cleanups.pop()!();
});

/** Minimal stand-in for the app side of the socket. */
class FakeApp {
  #socket: Socket<undefined> | null = null;
  #reader = new FrameReader();
  readonly control: ControlMessage[] = [];
  readonly audio: AudioFrame[] = [];
  closed = false;

  static async connect(path: string): Promise<FakeApp> {
    const app = new FakeApp();
    app.#socket = await Bun.connect<undefined>({
      unix: path,
      socket: {
        data: (_s, chunk) => app.#ingest(chunk),
        close: () => {
          app.closed = true;
        },
        error: () => {
          app.closed = true;
        },
      },
    });
    return app;
  }

  #ingest(chunk: Uint8Array): void {
    for (const frame of this.#reader.push(chunk)) {
      if (frame.type === FrameType.Control) {
        const message = decodeControlPayload(frame.payload);
        if (message) this.control.push(message);
      } else {
        const audio = decodeAudioPayload(frame.payload);
        if (audio) this.audio.push(audio);
      }
    }
  }

  send(body: ControlBody, replyTo?: string): void {
    this.#socket?.write(encodeControl(envelope(body, replyTo)));
  }

  sendAudio(frame: AudioFrame): void {
    this.#socket?.write(encodeAudio(FrameType.AudioUplink, frame));
  }

  /** Raw bytes, for the malformed-frame cases. */
  sendRaw(bytes: Uint8Array): void {
    this.#socket?.write(bytes);
  }

  end(): void {
    this.#socket?.end();
  }

  /** Wait for a control message of `type`. */
  async expect(type: string, timeoutMs = 2000): Promise<ControlMessage> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const hit = this.control.find((m) => (m as { type: string }).type === type);
      if (hit) return hit;
      if (Date.now() > deadline) {
        throw new Error(
          `timed out waiting for ${type}; saw [${this.control.map((m) => (m as { type: string }).type).join(", ")}]`,
        );
      }
      await Bun.sleep(5);
    }
  }

  take(type: string): ControlMessage[] {
    return this.control.filter((m) => (m as { type: string }).type === type);
  }
}

function payload(message: ControlMessage): Record<string, unknown> {
  return ((message as { payload?: unknown }).payload ?? {}) as Record<string, unknown>;
}

/**
 * The peer check is on for every test below: the test process is the "app", so
 * the allow-list is the bun binary running them. That keeps the real
 * verification path in the loop instead of stubbing it out.
 */
function testPeerPolicy() {
  return executablePathPolicy([process.execPath]);
}

async function withBridge(
  options: ConstructorParameters<typeof Bridge>[0] = {},
): Promise<{ bridge: Bridge; path: string }> {
  const dir = await mkdtemp(join(tmpdir(), "akari-test-"));
  const path = join(dir, "core.sock");
  const bridge = new Bridge({ peerPolicy: testPeerPolicy(), ...options, socketPath: path });
  await bridge.listen();
  cleanups.push(async () => {
    await bridge.close();
    await rm(dir, { recursive: true, force: true });
  });
  return { bridge, path };
}

/** Connected and past the handshake, which is the precondition for everything. */
async function connectedApp(bridge: Bridge, path: string): Promise<FakeApp> {
  const app = await FakeApp.connect(path);
  app.send({
    type: "app.hello",
    payload: { protocolVersion: 1, appVersion: "0.1.0", appBuild: "42" },
  });
  await app.expect("core.ready");
  await Bun.sleep(5);
  expect(bridge.connected).toBe(true);
  return app;
}

describe("handshake", () => {
  test("app.hello is answered with the negotiated formats", async () => {
    const seen: Array<{ appVersion: string; appBuild: string }> = [];
    const { bridge, path } = await withBridge({
      handlers: { onConnect: (info) => seen.push(info) },
    });

    const app = await FakeApp.connect(path);
    app.send({
      type: "app.hello",
      payload: { protocolVersion: 1, appVersion: "0.1.0", appBuild: "42" },
    });

    const ready = await app.expect("core.ready");
    expect(payload(ready)["protocolVersion"]).toBe(1);
    expect(payload(ready)["uplink"]).toEqual(DEFAULT_UPLINK_FORMAT);
    expect(payload(ready)["downlink"]).toEqual(DEFAULT_DOWNLINK_FORMAT);
    // core.ready answers the hello, so it carries its id.
    expect(typeof ready.replyTo).toBe("string");
    await Bun.sleep(5);
    expect(seen).toEqual([{ appVersion: "0.1.0", appBuild: "42" }]);
  });

  test("a first frame that is not app.hello is fatal", async () => {
    const { path } = await withBridge();
    const app = await FakeApp.connect(path);
    app.send({ type: "ptt.down", payload: { source: "hotkey" } });

    const error = await app.expect("error");
    expect(payload(error)["code"]).toBe("handshake_expected");
    expect(payload(error)["fatal"]).toBe(true);
  });

  test("a version mismatch is fatal and not negotiated down", async () => {
    const { path } = await withBridge();
    const app = await FakeApp.connect(path);
    app.send({
      type: "app.hello",
      payload: { protocolVersion: 2, appVersion: "9.9.9", appBuild: "1" },
    });
    const error = await app.expect("error");
    expect(payload(error)["code"]).toBe("protocol_mismatch");
  });

  test("a second client is rejected with already_connected", async () => {
    const { bridge, path } = await withBridge();
    const first = await connectedApp(bridge, path);

    const second = await FakeApp.connect(path);
    const error = await second.expect("error");
    expect(payload(error)["code"]).toBe("already_connected");

    // The live connection is untouched.
    expect(first.closed).toBe(false);
    expect(bridge.connected).toBe(true);
  });
});

describe("push to talk", () => {
  test("ptt and mic audio reach the handlers in order", async () => {
    const events: string[] = [];
    const frames: AudioFrame[] = [];
    const { bridge, path } = await withBridge({
      handlers: {
        onPttDown: () => events.push("down"),
        onPttUp: () => events.push("up"),
        onMicAudio: (f) => frames.push(f),
      },
    });
    const app = await connectedApp(bridge, path);

    app.send({ type: "ptt.down", payload: { source: "hotkey" } });
    for (let i = 0; i < 3; i++) {
      app.sendAudio({ streamId: 1, sequence: i, pcm: new Uint8Array(640).fill(i) });
    }
    app.send({ type: "ptt.up", payload: { source: "hotkey" } });

    await Bun.sleep(50);
    expect(events).toEqual(["down", "up"]);
    expect(frames.map((f) => f.sequence)).toEqual([0, 1, 2]);
    expect(frames[0]!.pcm.byteLength).toBe(640);
    expect(frames[2]!.pcm[0]).toBe(2);
  });

  test("audio before the handshake is fatal", async () => {
    const { path } = await withBridge();
    const app = await FakeApp.connect(path);
    app.sendAudio({ streamId: 1, sequence: 0, pcm: new Uint8Array(4) });
    const error = await app.expect("error");
    expect(payload(error)["code"]).toBe("handshake_expected");
  });
});

describe("playback streams", () => {
  test("begin/audio/end carry sequential frames on one stream id", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);

    const id = bridge.beginPlayback();
    expect(id).toBe(1);
    bridge.sendPlaybackAudio(id, new Uint8Array(960).fill(1));
    bridge.sendPlaybackAudio(id, new Uint8Array(960).fill(2));
    bridge.endPlayback(id);

    await app.expect("audio.end");
    expect(payload(await app.expect("audio.begin"))["streamId"]).toBe(1);
    expect(app.audio.map((f) => [f.streamId, f.sequence])).toEqual([
      [1, 0],
      [1, 1],
    ]);
  });

  test("audio.done from the app is reported once", async () => {
    const done: number[] = [];
    const { bridge, path } = await withBridge({
      handlers: { onPlaybackDone: (id) => done.push(id) },
    });
    const app = await connectedApp(bridge, path);

    const id = bridge.beginPlayback();
    bridge.endPlayback(id);
    app.send({ type: "audio.done", payload: { streamId: id } });

    await Bun.sleep(30);
    expect(done).toEqual([id]);
  });

  test("cancel with no id cancels everything", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);
    bridge.beginPlayback();
    bridge.cancelPlayback();

    const cancel = await app.expect("audio.cancel");
    expect(payload(cancel)["streamId"]).toBeUndefined();
  });

  test("stream ids increase and never repeat within a session", async () => {
    const { bridge, path } = await withBridge();
    await connectedApp(bridge, path);
    const ids = [bridge.beginPlayback(), bridge.beginPlayback(), bridge.beginPlayback()];
    expect(ids).toEqual([1, 2, 3]);
  });
});

describe("confirmation gate", () => {
  const request = {
    requestId: "c-1",
    tool: "run_shell",
    risk: "red" as const,
    title: "运行 shell 命令",
    command: "rm -rf /tmp/nothing",
    timeoutMs: 5000,
  };

  test("approve reaches the caller and the command is sent verbatim", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);

    const decision = bridge.requestConfirm(request);
    const card = await app.expect("tool.confirm.request");
    expect(payload(card)["command"]).toBe("rm -rf /tmp/nothing");

    app.send(
      { type: "tool.confirm.response", payload: { requestId: "c-1", decision: "approve" } },
      card.id,
    );
    expect(await decision).toBe("approve");
  });

  test("an unknown decision value is treated as deny", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);

    const decision = bridge.requestConfirm(request);
    await app.expect("tool.confirm.request");
    app.send({
      type: "tool.confirm.response",
      // Deliberately off-contract: the protocol says anything that is not a
      // literal "approve" is a deny, so a garbage value has to be tested.
      payload: { requestId: "c-1", decision: "maybe" },
    } as unknown as ControlBody);
    expect(await decision).toBe("deny");
  });

  test("the timeout fires on its own", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);
    const decision = bridge.requestConfirm({ ...request, timeoutMs: 30 });
    await app.expect("tool.confirm.request");
    expect(await decision).toBe("timeout");
  });

  test("a dropped connection settles a pending card as deny", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);
    const decision = bridge.requestConfirm({ ...request, timeoutMs: 0 });
    await app.expect("tool.confirm.request");
    app.end();
    expect(await decision).toBe("deny");
  });

  test("a confirm requested while disconnected is denied without a card", async () => {
    const { bridge } = await withBridge();
    expect(await bridge.requestConfirm(request)).toBe("deny");
  });
});

describe("undo toast", () => {
  const undoable = { requestId: "u-1", tool: "write_file", title: "已写入", undoMs: 60 };

  test("resolves true when the user undoes it", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);
    const undone = bridge.notifyUndoable(undoable);
    await app.expect("tool.undoable");
    app.send({ type: "tool.undo", payload: { requestId: "u-1" } });
    expect(await undone).toBe(true);
  });

  test("resolves false when the window expires", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);
    const undone = bridge.notifyUndoable(undoable);
    await app.expect("tool.undoable");
    expect(await undone).toBe(false);
  });

  test("a late tool.undo is ignored", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);
    const undone = bridge.notifyUndoable(undoable);
    await app.expect("tool.undoable");
    expect(await undone).toBe(false);
    app.send({ type: "tool.undo", payload: { requestId: "u-1" } });
    await Bun.sleep(20); // must not throw or resolve anything a second time
  });
});

describe("protocol hygiene", () => {
  test("ping is answered with a pong that quotes the id", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);
    const ping = envelope({ type: "ping" });
    app.sendRaw(encodeControl(ping));
    const pong = await app.expect("pong");
    expect(pong.replyTo).toBe(ping.id);
  });

  test("an unknown control type is ignored, not fatal", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);
    app.sendRaw(
      encodeControl({
        v: 1,
        id: "x",
        ts: Date.now(),
        type: "avatar.doTheThing",
      } as unknown as ControlMessage),
    );
    await Bun.sleep(30);
    expect(app.take("error")).toHaveLength(0);
    expect(bridge.connected).toBe(true);

    // ...and the connection still works afterwards.
    app.sendRaw(encodeControl(envelope({ type: "ping" })));
    await app.expect("pong");
  });

  test("a bad payload on a known type is non-fatal", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);
    app.send({ type: "audio.done", payload: { streamId: "seven" } } as unknown as ControlBody);
    const error = await app.expect("error");
    expect(payload(error)["code"]).toBe("bad_payload");
    expect(payload(error)["fatal"]).toBe(false);
    expect(bridge.connected).toBe(true);
  });

  test("an oversized length prefix closes the connection", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);
    const header = new Uint8Array(4);
    new DataView(header.buffer).setUint32(0, 5 * 1024 * 1024, false);
    app.sendRaw(header);

    const error = await app.expect("error");
    expect(payload(error)["code"]).toBe("frame_too_large");
    await Bun.sleep(30);
    expect(bridge.connected).toBe(false);
  });

  test("downlink audio from the app is a protocol violation", async () => {
    const { path } = await withBridge();
    const app = await FakeApp.connect(path);
    app.send({
      type: "app.hello",
      payload: { protocolVersion: 1, appVersion: "0.1.0", appBuild: "1" },
    });
    await app.expect("core.ready");
    app.sendRaw(
      encodeAudio(FrameType.AudioDownlink, { streamId: 1, sequence: 0, pcm: new Uint8Array(2) }),
    );
    const error = await app.expect("error");
    expect(payload(error)["code"]).toBe("bad_frame_type");
  });

  test("a reconnect starts stream ids over", async () => {
    const { bridge, path } = await withBridge();
    const first = await connectedApp(bridge, path);
    expect(bridge.beginPlayback()).toBe(1);
    expect(bridge.beginPlayback()).toBe(2);

    first.end();
    await Bun.sleep(30);
    await connectedApp(bridge, path);
    expect(bridge.beginPlayback()).toBe(1);
  });
});

describe("peer verification", () => {
  test("a process that is not an allow-listed akari.app never gets past connect", async () => {
    const refused: string[] = [];
    const { bridge, path } = await withBridge({
      // Nothing on this machine has that path, so the test runner is a stranger
      // — exactly the position a malicious local process is in.
      peerPolicy: executablePathPolicy(["/nonexistent/akari.app/Contents/MacOS/akari"]),
      handlers: { onLog: (level, message) => level === "error" && refused.push(message) },
    });

    const impostor = await FakeApp.connect(path);
    const error = await impostor.expect("error");
    expect(payload(error)["code"]).toBe("unauthorized");
    expect(payload(error)["fatal"]).toBe(true);

    // ...and the handshake is not merely ignored, the socket is gone.
    impostor.send({
      type: "app.hello",
      payload: { protocolVersion: 1, appVersion: "0.1.0", appBuild: "42" },
    });
    await Bun.sleep(50);
    expect(impostor.take("core.ready")).toHaveLength(0);
    expect(bridge.connected).toBe(false);

    // The refusal is auditable: pid, uid and executable are on the record.
    expect(refused.join("\n")).toContain("AUDIT peer refused");
    expect(refused.join("\n")).toContain(`pid=${process.pid}`);
  });

  test("an impostor cannot approve a RED confirmation card", async () => {
    const { bridge, path } = await withBridge({
      peerPolicy: executablePathPolicy(["/nonexistent/akari.app/Contents/MacOS/akari"]),
    });
    const impostor = await FakeApp.connect(path);
    await impostor.expect("error");

    // ADR-002 says a RED tool waits for a person. With nobody attached the
    // gate must answer deny by itself, and the impostor must never see the card.
    const decision = bridge.requestConfirm({
      requestId: "c-evil",
      tool: "run_shell",
      risk: "red",
      title: "运行 shell 命令",
      command: "rm -rf /",
      timeoutMs: 200,
    });
    impostor.send({
      type: "tool.confirm.response",
      payload: { requestId: "c-evil", decision: "approve" },
    });
    expect(await decision).toBe("deny");
    expect(impostor.take("tool.confirm.request")).toHaveLength(0);
  });

  test("an allow-listed executable is accepted and logged", async () => {
    const accepted: string[] = [];
    const { bridge, path } = await withBridge({
      handlers: { onLog: (_l, message) => accepted.push(message) },
    });
    await connectedApp(bridge, path);
    expect(accepted.join("\n")).toContain("AUDIT peer accepted");
  });

  test("policy off still connects, and says so loudly", async () => {
    const logs: Array<[string, string]> = [];
    const { bridge, path } = await withBridge({
      peerPolicy: allowAnyPeer(),
      handlers: { onLog: (level, message) => logs.push([level, message]) },
    });
    await connectedApp(bridge, path);
    expect(logs.some(([l, m]) => l === "error" && m.includes("peer verification is DISABLED"))).toBe(
      true,
    );
  });
});

describe("socket permissions", () => {
  test("socket and directory are private even under a wide-open umask", async () => {
    const previous = process.umask(0o000);
    try {
      const dir = await mkdtemp(join(tmpdir(), "akari-umask-"));
      const path = join(dir, "nested", "core.sock");
      const bridge = new Bridge({ socketPath: path, peerPolicy: testPeerPolicy() });
      cleanups.push(async () => {
        await bridge.close();
        await rm(dir, { recursive: true, force: true });
      });
      await bridge.listen();

      // Under umask 000 the unpatched code produced 0777 / 0777 here.
      expect(statSync(path).mode & 0o777).toBe(0o600);
      expect(statSync(join(dir, "nested")).mode & 0o777).toBe(0o700);
    } finally {
      process.umask(previous);
    }
  });

  test("an already too-open directory is tightened, not accepted as found", async () => {
    const dir = await mkdtemp(join(tmpdir(), "akari-wide-"));
    chmodSync(dir, 0o777);
    const path = join(dir, "core.sock");
    const bridge = new Bridge({ socketPath: path, peerPolicy: testPeerPolicy() });
    cleanups.push(async () => {
      await bridge.close();
      await rm(dir, { recursive: true, force: true });
    });
    await bridge.listen();
    expect(statSync(dir).mode & 0o777).toBe(0o700);
    expect(statSync(path).mode & 0o777).toBe(0o600);
  });

  test("a directory this user cannot lock down stops startup instead of listening", async () => {
    // /private/var/tmp is root-owned and 1777 — the shape of the attack in the
    // review: anyone can unlink the socket and bind their own in its place.
    const path = join("/private/var/tmp", `akari-perm-${process.pid}.sock`);
    const bridge = new Bridge({ socketPath: path, peerPolicy: testPeerPolicy() });
    cleanups.push(async () => {
      await bridge.close();
    });
    await expect(bridge.listen()).rejects.toThrow(/refusing to run/);
    expect(existsSync(path)).toBe(false);
  });
});

describe("clipboard read (protocol.md §3.7)", () => {
  test("the app is asked, and its answer is what the core gets", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);

    const read = bridge.readClipboardText();
    const request = await app.expect("clipboard.read.request");
    const requestId = payload(request)["requestId"] as string;
    expect(typeof requestId).toBe("string");

    app.send({
      type: "clipboard.read.response",
      payload: { requestId, concealed: false, text: "https://example.com" },
    });
    expect(await read).toEqual({ text: "https://example.com", concealed: false });
  });

  test("a concealed pasteboard yields no text, even if the app sent some", async () => {
    // The app is not supposed to send `text` alongside `concealed`. If it does,
    // the secret is dropped here rather than reasoned about downstream — this
    // is the one hop where a master password would otherwise enter the core.
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);

    const read = bridge.readClipboardText();
    const request = await app.expect("clipboard.read.request");
    app.send({
      type: "clipboard.read.response",
      payload: {
        requestId: payload(request)["requestId"] as string,
        concealed: true,
        text: "correct-horse-battery-staple",
      },
    });
    expect(await read).toEqual({ text: null, concealed: true });
  });

  test("losing the app fails the read; it never falls back to pbpaste", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);

    const read = bridge.readClipboardText();
    await app.expect("clipboard.read.request");
    app.end();

    await expect(read).rejects.toThrow(/clipboard read failed/);
  });

  test("with no app attached there is nothing to ask", async () => {
    const { bridge } = await withBridge();
    await expect(bridge.readClipboardText()).rejects.toThrow(/not connected/);
  });

  test("clipboard_read reaches the model as a skip, not as the password", async () => {
    // End to end through the real registry and executor: the tool the model
    // calls, the socket, the app's verdict, and the string handed back.
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);

    const registry = createRegistry({
      clipboard: { readText: (signal) => bridge.readClipboardText(signal) },
    });
    const executor = new ToolExecutor({ registry, host: bridge });

    // Supplying a host is what makes the tool green; the pbpaste fallback is red.
    expect(registry.get("clipboard_read")!.risk).toBe("green");

    const call = executor.execute("clipboard_read", {});
    const request = await app.expect("clipboard.read.request");
    app.send({
      type: "clipboard.read.response",
      payload: { requestId: payload(request)["requestId"] as string, concealed: true },
    });

    const invocation = await call;
    expect(invocation.status).toBe("ok");
    expect(invocation.content).toContain("机密");
    expect(invocation.content).not.toContain("untrusted");
  });
});

describe("ui.notice", () => {
  test("a notice reaches the app as its own message, not as a log line", async () => {
    const { bridge, path } = await withBridge();
    const app = await connectedApp(bridge, path);

    bridge.sendNotice("warn", "按得太短了（只录到 10ms），没听清。");
    const notice = await app.expect("ui.notice");
    expect(payload(notice)["level"]).toBe("warn");
    expect(payload(notice)["text"]).toContain("按得太短");
    // protocol.md §3.6: `log` carries no control semantics, so this must not
    // have been smuggled through it.
    expect(app.take("log")).toHaveLength(0);
  });
});

describe("audit peer attribution", () => {
  test("the attached client is named while it is attached, and only then", async () => {
    const { bridge, path } = await withBridge();
    expect(bridge.peerDescription).toBeUndefined();

    const app = await connectedApp(bridge, path);
    expect(bridge.peerDescription).toContain(`pid=${process.pid}`);
    expect(bridge.peerDescription).toContain(process.execPath);

    app.end();
    await Bun.sleep(20);
    expect(bridge.peerDescription).toBeUndefined();
  });
});
