import { afterEach, describe, expect, test } from "bun:test";
import { statSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  FrameReader,
  FrameType,
  decodeControlPayload,
  encodeControl,
  envelope,
  type ControlBody,
  type ControlMessage,
} from "./protocol.ts";

/**
 * The assembly point itself: `bun run src/index.ts`, spawned for real, driven
 * over a real socket by a stand-in app.
 *
 * Every other test file exercises one module against fakes. This one exists
 * because the bugs that survive that are the wiring bugs — a callback nobody
 * connected, a handler that ends a turn on paper but not on the wire, a
 * constructor that throws past the guard meant to catch it.
 *
 * No network: `--no-realtime`, or a deliberately absent key.
 */

const ENTRY = join(import.meta.dir, "index.ts");

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  while (cleanups.length) await cleanups.pop()!();
});

interface Harness {
  dir: string;
  socketPath: string;
  auditPath: string;
  log: () => string;
  exited: Promise<number>;
}

async function startCore(
  args: string[],
  env: Record<string, string | undefined> = {},
): Promise<Harness> {
  const dir = await mkdtemp(join(tmpdir(), "akari-index-"));
  const socketPath = join(dir, "core.sock");
  const auditPath = join(dir, "audit.jsonl");
  const child = Bun.spawn(["bun", "run", ENTRY, ...args], {
    cwd: join(import.meta.dir, ".."),
    env: {
      ...process.env,
      AKARI_SOCKET: socketPath,
      AKARI_AUDIT_LOG: auditPath,
      // The stand-in app below is this test process.
      AKARI_PEER_ALLOW: process.execPath,
      AKARI_LOG_LEVEL: "info",
      ...env,
    },
    stdout: "pipe",
    stderr: "pipe",
  });

  let text = "";
  for (const stream of [child.stdout, child.stderr]) {
    void (async () => {
      for await (const chunk of stream) text += new TextDecoder().decode(chunk);
    })();
  }

  cleanups.push(async () => {
    child.kill();
    await child.exited;
    await rm(dir, { recursive: true, force: true });
  });

  const harness: Harness = {
    dir,
    socketPath,
    auditPath,
    log: () => text,
    exited: child.exited,
  };
  await until(() => text.includes("socket ready at"), () => `core never announced its socket:\n${text}`);
  return harness;
}

async function until(
  predicate: () => boolean,
  describe: () => string,
  timeoutMs = 15_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await Bun.sleep(20);
  }
  throw new Error(`timed out: ${describe()}`);
}

/** Stand-in for akari.app, over the real socket and the real framing. */
class StandInApp {
  #socket!: import("bun").Socket<undefined>;
  #reader = new FrameReader();
  readonly control: ControlMessage[] = [];

  static async connect(path: string): Promise<StandInApp> {
    const app = new StandInApp();
    app.#socket = await Bun.connect<undefined>({
      unix: path,
      socket: {
        data: (_s, chunk) => {
          for (const frame of app.#reader.push(chunk)) {
            if (frame.type !== FrameType.Control) continue;
            const message = decodeControlPayload(frame.payload);
            if (message) app.control.push(message);
          }
        },
        open: () => {},
        close: () => {},
        error: () => {},
      },
    });
    return app;
  }

  send(body: ControlBody, replyTo?: string): void {
    this.#socket.write(encodeControl(envelope(body, replyTo)));
  }

  end(): void {
    this.#socket.end();
  }

  seen(type: string): ControlMessage[] {
    return this.control.filter((m) => (m as { type: string }).type === type);
  }

  payloads(type: string): Record<string, unknown>[] {
    return this.seen(type).map(
      (m) => ((m as { payload?: unknown }).payload ?? {}) as Record<string, unknown>,
    );
  }

  states(): string[] {
    return this.payloads("avatar.setState").map((p) => p["state"] as string);
  }

  async expect(type: string, timeoutMs = 10_000): Promise<ControlMessage> {
    await until(
      () => this.seen(type).length > 0,
      () => `no ${type}; saw [${this.control.map((m) => (m as { type: string }).type).join(", ")}]`,
      timeoutMs,
    );
    return this.seen(type)[0]!;
  }

  async handshake(): Promise<void> {
    this.send({
      type: "app.hello",
      payload: { protocolVersion: 1, appVersion: "0.1.0", appBuild: "test" },
    });
    await this.expect("core.ready");
  }
}

async function attach(core: Harness): Promise<StandInApp> {
  const app = await StandInApp.connect(core.socketPath);
  cleanups.push(async () => app.end());
  await app.handshake();
  return app;
}

describe("core assembly", () => {
  test("the socket and the audit trail are both private to this user", async () => {
    const core = await startCore(["--no-realtime"]);
    await attach(core);

    expect(statSync(core.socketPath).mode & 0o777).toBe(0o600);
    expect(statSync(core.dir).mode & 0o777).toBe(0o700);
    // The audit file holds tool arguments — paths, message bodies, whatever the
    // model passed. 0644 would leave every command akari was asked to run
    // readable by anything on the machine.
    await until(
      () => {
        try {
          statSync(core.auditPath);
          return true;
        } catch {
          return false;
        }
      },
      () => "the audit sink never created its file",
      5_000,
    );
    expect(statSync(core.auditPath).mode & 0o777).toBe(0o600);
  });

  test("an allow-listed client is accepted and the acceptance is audited", async () => {
    const core = await startCore(["--no-realtime"]);
    await attach(core);
    expect(core.log()).toContain("AUDIT peer accepted");
    expect(core.log()).toContain(`pid=${process.pid}`);
  });

  test("a turn nothing can answer ends, instead of leaving her thinking", async () => {
    // The P1 regression in one test. `ptt.up` moves her to `thinking`; with no
    // session there is no response event, so without a turn-abandoned path she
    // stays there until the core is restarted — and looks identical to a model
    // that is merely slow.
    const core = await startCore(["--no-realtime"]);
    const app = await attach(core);

    app.send({ type: "ptt.down", payload: { source: "hotkey" } });
    await until(() => app.states().includes("listening"), () => "no listening state");
    app.send({ type: "ptt.up", payload: { source: "hotkey" } });

    await until(() => app.states().at(-1) === "idle", () => `states: ${app.states().join(" → ")}`);
    expect(app.states()).toEqual(["greeting", "listening", "thinking", "idle"]);

    // And she says why: silence is indistinguishable from thinking.
    const notice = (await app.expect("ui.notice")) as unknown as {
      payload: { level: string; text: string };
    };
    expect(notice.payload.level).toBe("warn");
    expect(notice.payload.text.length).toBeGreaterThan(0);
  });

  test("a missing key costs the voice, not the socket", async () => {
    // `configFromEnv()` throws on a missing key. Escaping to the top level kills
    // the process, and when the app is what spawned the core that is a crash
    // loop whose only symptom is "未连接" in the menu bar.
    const core = await startCore([], {
      DASHSCOPE_API_KEY: "",
      HOME: await mkdtemp(join(tmpdir(), "akari-nohome-")),
    });
    const app = await attach(core);

    expect(core.log()).toContain("voice is unavailable");
    // It names every path it looked in, so the fix is obvious from the log.
    expect(core.log()).toContain("checked for a .env in:");

    const notice = (await app.expect("ui.notice")) as unknown as {
      payload: { level: string; text: string };
    };
    expect(notice.payload.level).toBe("error");
    expect(notice.payload.text).toContain("DASHSCOPE_API_KEY");
    // Never the value itself, only the name.
    expect(core.log()).not.toContain("sk-");
  });

  test("app.quit shuts the core down cleanly", async () => {
    const core = await startCore(["--no-realtime"]);
    const app = await attach(core);
    app.send({ type: "app.quit" });
    expect(await core.exited).toBe(0);
  });

  test("an unknown message type is ignored, never fatal", async () => {
    // protocol.md §三: the only forward-compatibility mechanism there is.
    const core = await startCore(["--no-realtime"]);
    const app = await attach(core);

    app.send({ type: "some.future.message" } as unknown as ControlBody);
    app.send({ type: "ping" });
    await app.expect("pong");
  });
});

/**
 * The settings and credential wiring, driven through the real core over the
 * real socket (ADR-009). No network: Cloudflare is left unconfigured and the
 * local runtime is told not to autostart, so every probe below is answered
 * from the core's own state rather than from a service.
 */
describe("settings and credentials over the wire", () => {
  /** Blank strings shadow the repo `.env`, which would otherwise supply real keys. */
  const NO_CREDENTIALS = {
    DASHSCOPE_API_KEY: "",
    CLOUDFLARE_ACCOUNT_ID: "",
    CLOUDFLARE_API_TOKEN: "",
    HF_TOKEN: "",
    LOCAL_MLX_AUTOSTART: "0",
  };

  function state(app: StandInApp): Record<string, any> | undefined {
    return app.payloads("settings.state").at(-1);
  }

  function route(app: StandInApp, id: string): Record<string, any> {
    return (state(app)!["routes"] as any[]).find((r) => r.route === id);
  }

  test("the core asks for every slot as soon as the handshake is done", async () => {
    const core = await startCore(["--no-realtime"], NO_CREDENTIALS);
    const app = await attach(core);

    const request = await app.expect("credentials.request");
    const requestPayload = (request as any).payload;
    expect(requestPayload.slots).toEqual([
      "dashscope.apiKey",
      "cloudflare.accountId",
      "cloudflare.apiToken",
      "huggingface.token",
    ]);
    expect(typeof requestPayload.requestId).toBe("string");
  });

  test("a Keychain value wins over .env, and the state says so without the value", async () => {
    const core = await startCore(["--no-realtime"], {
      ...NO_CREDENTIALS,
      CLOUDFLARE_ACCOUNT_ID: "from-the-env-file",
    });
    const app = await attach(core);
    const request = (await app.expect("credentials.request")) as any;

    app.send(
      {
        type: "credentials.provide",
        payload: {
          requestId: request.payload.requestId,
          values: [
            { slot: "cloudflare.accountId", state: "set", value: "from-the-keychain" },
            { slot: "dashscope.apiKey", state: "cleared" },
            { slot: "cloudflare.apiToken", state: "unset" },
            { slot: "huggingface.token", state: "denied" },
          ],
        },
      } as unknown as ControlBody,
      request.id,
    );
    await until(() => app.payloads("settings.state").length > 0, () => "no settings.state");
    await Bun.sleep(200);

    const credentials = state(app)!["credentials"] as any[];
    const account = credentials.find((c) => c.slot === "cloudflare.accountId");
    expect(account.source).toBe("app");
    expect(account.present).toBe(true);
    expect(account.fingerprint).toMatch(/^[0-9a-f]{8}$/);
    // §八: the resolved value never appears in settings.state, only a hash of it.
    expect(JSON.stringify(state(app))).not.toContain("from-the-keychain");

    expect(credentials.find((c) => c.slot === "dashscope.apiKey").cleared).toBe(true);
    expect(credentials.find((c) => c.slot === "huggingface.token").denied).toBe(true);
    // …and no credential reached the log, at any level.
    expect(core.log()).not.toContain("from-the-keychain");
    expect(core.log()).not.toContain("from-the-env-file");
  });

  test("the state lists three providers across two routes", async () => {
    const core = await startCore(["--no-realtime"], NO_CREDENTIALS);
    const app = await attach(core);
    app.send({ type: "settings.get" });
    await until(() => app.payloads("settings.state").length > 0, () => "no settings.state");

    expect(route(app, "voice").candidates.map((c: any) => c.provider)).toEqual([
      "dashscope-realtime",
    ]);
    // ADR-009's fallback order: the user's own Cloudflare first, local behind it.
    expect(route(app, "text").candidates.map((c: any) => c.provider)).toEqual([
      "cloudflare-workers-ai",
      "local-mlx",
    ]);
    expect(route(app, "text").selected).toBe("auto");
    expect(state(app)!["envFiles"]).toBeArray();
  });

  test("settings.set pins the text route; an unknown provider changes nothing", async () => {
    const core = await startCore(["--no-realtime"], NO_CREDENTIALS);
    const app = await attach(core);
    app.send({ type: "settings.get" });
    await until(() => app.payloads("settings.state").length > 0, () => "no settings.state");

    const before = app.payloads("settings.state").length;
    app.send({ type: "settings.set", payload: { route: "text", provider: "local-mlx" } });
    await until(
      () => app.payloads("settings.state").length > before,
      () => "settings.set was not answered",
    );
    expect(route(app, "text").selected).toBe("local-mlx");

    app.send({ type: "settings.set", payload: { route: "text", provider: "openai" } });
    await app.expect("error");
    expect(app.payloads("error").at(-1)!["code"]).toBe("bad_payload");
    // Still pinned to what the user actually chose.
    expect(route(app, "text").selected).toBe("local-mlx");
  });

  test("probing an unconfigured route reports what is missing, not a network error", async () => {
    const core = await startCore(["--no-realtime"], NO_CREDENTIALS);
    const app = await attach(core);

    app.send({ type: "settings.probe", payload: { route: "text", timeoutMs: 8000 } });
    await until(
      () => app.payloads("settings.probeResult").length > 0,
      () => `no probeResult\n${core.log()}`,
      20_000,
    );
    const results = app.payloads("settings.probeResult").at(-1)!["results"] as any[];
    const cloudflare = results.find((r) => r.provider === "cloudflare-workers-ai");
    expect(cloudflare.status).toBe("unconfigured");
    expect(cloudflare.missing).toEqual(["cloudflare.accountId", "cloudflare.apiToken"]);
    // The capability block is readable before anything works, which is what
    // lets the window draw a row for a provider that is not configured yet.
    expect(cloudflare.capabilities.vision).toBe(true);
  });

  test("credentials.updated is followed by a request for exactly those slots", async () => {
    const core = await startCore(["--no-realtime"], NO_CREDENTIALS);
    const app = await attach(core);
    await app.expect("credentials.request");

    app.send({
      type: "credentials.updated",
      payload: { slots: ["cloudflare.apiToken"] },
    } as unknown as ControlBody);
    await until(
      () => app.seen("credentials.request").length > 1,
      () => "no second credentials.request",
    );
    const second = app.payloads("credentials.request").at(-1)!;
    expect(second["slots"]).toEqual(["cloudflare.apiToken"]);
    // The slot names are the loggable half of §3.10.
    expect(core.log()).toContain("credentials.updated: cloudflare.apiToken");
  });
});
