import { beforeEach, describe, expect, test } from "bun:test";
import type {
  ConfirmDecision,
  ToolConfirmRequestPayload,
  ToolUndoablePayload,
} from "../protocol.ts";
import { AuditLog } from "./audit.ts";
import { ToolExecutor } from "./executor.ts";
import { ToolRegistry } from "./registry.ts";
import type { ToolDefinition, ToolHost } from "./types.ts";

class FakeHost implements ToolHost {
  decision: ConfirmDecision = "approve";
  undoRequested = false;
  throwOnConfirm = false;
  readonly confirms: ToolConfirmRequestPayload[] = [];
  readonly toasts: ToolUndoablePayload[] = [];

  async requestConfirm(payload: ToolConfirmRequestPayload): Promise<ConfirmDecision> {
    if (this.throwOnConfirm) throw new Error("bridge is down");
    this.confirms.push(payload);
    return this.decision;
  }

  async notifyUndoable(payload: ToolUndoablePayload): Promise<boolean> {
    this.toasts.push(payload);
    return this.undoRequested;
  }
}

let host: FakeHost;
let registry: ToolRegistry;
let audit: AuditLog;
let executor: ToolExecutor;
let ran: string[];

function define(overrides: Partial<ToolDefinition> & { name: string }): ToolDefinition {
  return {
    description: "test tool",
    parameters: {
      type: "object",
      properties: { path: { type: "string" } },
      additionalProperties: false,
    },
    risk: "green",
    mutating: false,
    run: async () => {
      ran.push(overrides.name);
      return { ok: true, content: `${overrides.name} ok` };
    },
    ...overrides,
  };
}

beforeEach(() => {
  host = new FakeHost();
  registry = new ToolRegistry();
  audit = new AuditLog();
  executor = new ToolExecutor({ registry, host, audit });
  ran = [];
});

describe("green", () => {
  test("runs without bothering the user", async () => {
    registry.register(define({ name: "read_thing" }));
    const call = await executor.execute("read_thing", {});
    expect(call.status).toBe("ok");
    expect(call.effectiveRisk).toBe("green");
    expect(ran).toEqual(["read_thing"]);
    expect(host.confirms).toEqual([]);
    expect(host.toasts).toEqual([]);
    expect(audit.entries()[0]?.confirmed).toBe(false);
  });
});

describe("yellow", () => {
  const undoable = (name: string, undo?: () => Promise<void>) =>
    define({
      name,
      risk: "yellow",
      mutating: true,
      confirmTitle: "写入文件",
      describe: (args) => `write ${String(args["path"])}`,
      run: async () => {
        ran.push(name);
        return { ok: true, content: "written", ...(undo ? { undo } : {}) };
      },
    });

  test("runs first, then offers the 1.5s undo toast", async () => {
    registry.register(undoable("write_file"));
    const call = await executor.execute("write_file", { path: "notes.md" });
    expect(call.status).toBe("ok");
    expect(ran).toEqual(["write_file"]);
    expect(host.toasts[0]?.undoMs).toBe(1500);
    expect(host.confirms).toEqual([]);
  });

  test("reverts when the user hits undo", async () => {
    let reverted = false;
    registry.register(
      undoable("write_file", async () => {
        reverted = true;
      }),
    );
    host.undoRequested = true;
    const call = await executor.execute("write_file", { path: "notes.md" });
    expect(reverted).toBe(true);
    expect(call.status).toBe("undone");
    expect(audit.entries()[0]?.status).toBe("undone");
  });

  test("tells the model plainly when undo was asked for but is impossible", async () => {
    registry.register(undoable("write_file"));
    host.undoRequested = true;
    const call = await executor.execute("write_file", { path: "notes.md" });
    expect(call.status).toBe("error");
    expect(call.content).toContain("could not be reverted");
    expect(call.reason).toContain("no undo()");
  });
});

describe("red", () => {
  const shell = define({
    name: "run_shell",
    risk: "red",
    mutating: true,
    confirmTitle: "运行 shell 命令",
    parameters: {
      type: "object",
      properties: { command: { type: "string" } },
      required: ["command"],
      additionalProperties: false,
    },
    describe: (args) => String(args["command"]),
    run: async () => {
      ran.push("run_shell");
      return { ok: true, content: "shell ok" };
    },
  });

  test("shows the raw command verbatim and waits", async () => {
    registry.register(shell);
    const command = "rm -rf ~/Dev/akari/app/.build && echo done";
    const call = await executor.execute("run_shell", { command });
    expect(host.confirms[0]?.command).toBe(command);
    expect(host.confirms[0]?.title).toBe("运行 shell 命令");
    expect(host.confirms[0]?.timeoutMs).toBe(30_000);
    expect(call.status).toBe("ok");
    expect(call.confirmed).toBe(true);
    expect(audit.entries()[0]?.confirmed).toBe(true);
  });

  test("does not run on deny or timeout", async () => {
    registry.register(shell);
    for (const decision of ["deny", "timeout"] as ConfirmDecision[]) {
      host.decision = decision;
      const call = await executor.execute("run_shell", { command: "rm -rf /" });
      expect(call.status).toBe("denied");
      expect(call.decision).toBe(decision);
    }
    expect(ran).toEqual([]);
  });

  test("treats a broken bridge as a deny", async () => {
    registry.register(shell);
    host.throwOnConfirm = true;
    const call = await executor.execute("run_shell", { command: "whoami" });
    expect(call.status).toBe("denied");
    expect(ran).toEqual([]);
  });
});

describe("prompt injection defence", () => {
  const opener = define({
    name: "open_app",
    mutating: true,
    confirmTitle: "打开应用",
    parameters: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
      additionalProperties: false,
    },
    describe: (args) => `open -a ${String(args["name"])}`,
    run: async () => {
      ran.push("open_app");
      return { ok: true, content: "opened" };
    },
  });

  const reader = define({
    name: "read_page",
    run: async () => {
      ran.push("read_page");
      return { ok: true, content: "external text", untrusted: true };
    },
  });

  test("an untrusted message in the conversation escalates a mutating call to red", async () => {
    registry.register(opener);
    const call = await executor.execute(
      "open_app",
      { name: "Safari" },
      { messages: [{ role: "tool", content: "screenshot text", untrusted: true }] },
    );
    expect(call.declaredRisk).toBe("green");
    expect(call.effectiveRisk).toBe("red");
    expect(host.confirms).toHaveLength(1);
    expect(host.confirms[0]?.detail).toContain("外部内容");
    expect(call.status).toBe("ok");
  });

  test("an untrusted tool result taints the rest of the session", async () => {
    registry.register(opener);
    registry.register(reader);
    expect(executor.untrusted).toBe(false);
    await executor.execute("read_page", {});
    expect(executor.untrusted).toBe(true);

    // No untrusted message is passed in — the taint alone must be enough,
    // because a summarised conversation can lose the original message.
    const call = await executor.execute("open_app", { name: "Safari" });
    expect(call.effectiveRisk).toBe("red");
    expect(host.confirms).toHaveLength(1);
  });

  test("taint survives when the conversation no longer carries the message", async () => {
    registry.register(opener);
    executor.markUntrusted();
    const call = await executor.execute(
      "open_app",
      { name: "Safari" },
      { messages: [{ role: "user", content: "open safari" }] },
    );
    expect(call.effectiveRisk).toBe("red");
  });

  test("a shell-class tool is refused outright, not merely confirmed", async () => {
    registry.register(
      define({
        name: "run_shell",
        risk: "red",
        mutating: true,
        isolateFromUntrusted: true,
        describe: () => "sh -c ...",
        run: async () => {
          ran.push("run_shell");
          return { ok: true, content: "shell ok" };
        },
      }),
    );
    executor.markUntrusted();
    const call = await executor.execute("run_shell", {});
    expect(call.status).toBe("denied");
    expect(host.confirms).toEqual([]);
    expect(ran).toEqual([]);
    expect(audit.entries()[0]?.reason).toContain("isolated");
  });
});

describe("guards and audit", () => {
  test("an unknown tool is refused, not thrown", async () => {
    const call = await executor.execute("format_disk", {});
    expect(call.status).toBe("denied");
    expect(call.content).toContain("not available");
    expect(audit.entries()[0]?.declaredRisk).toBeNull();
  });

  test("bad arguments never reach the tool", async () => {
    registry.register(define({ name: "read_thing" }));
    const call = await executor.execute("read_thing", { path: 42, extra: true });
    expect(call.status).toBe("denied");
    expect(ran).toEqual([]);
    expect(call.content).toContain("Invalid arguments");
  });

  test("a throwing tool becomes an error result, not an exception", async () => {
    registry.register(
      define({
        name: "read_thing",
        run: async () => {
          throw new Error("disk on fire");
        },
      }),
    );
    const call = await executor.execute("read_thing", {});
    expect(call.status).toBe("error");
    expect(call.content).toContain("disk on fire");
  });

  test("every call is recorded with level, confirmation and redacted arguments", async () => {
    registry.register(
      define({
        name: "read_thing",
        parameters: {
          type: "object",
          properties: { api_key: { type: "string" } },
          additionalProperties: false,
        },
      }),
    );
    await executor.execute("read_thing", { api_key: "sk-do-not-log" }, { callId: "call_1" });
    const entry = audit.entries()[0];
    expect(entry?.tool).toBe("read_thing");
    expect(entry?.callId).toBe("call_1");
    expect(entry?.declaredRisk).toBe("green");
    expect(entry?.effectiveRisk).toBe("green");
    expect(entry?.untrustedContext).toBe(false);
    expect(entry?.status).toBe("ok");
    expect(typeof entry?.durationMs).toBe("number");
    expect(JSON.stringify(entry)).not.toContain("sk-do-not-log");
  });
});

describe("argument integrity", () => {
  test("arguments are frozen, so what the card showed is what ran", async () => {
    let seen: Record<string, unknown> | undefined;
    registry.register(
      define({
        name: "read_thing",
        run: async (args) => {
          seen = args;
          return { ok: true, content: "ok" };
        },
      }),
    );
    const args = { path: "notes.md" };
    await executor.execute("read_thing", args);
    // The executor now runs a sanitised *copy*, so the caller's object is no
    // longer the one that executes: swapping a value in it after the fact
    // cannot reach the tool, and the copy the tool saw is frozen.
    expect(Object.isFrozen(seen)).toBe(true);
    expect(seen).not.toBe(args);
    args["path"] = "/etc/passwd";
    expect(seen?.["path"]).toBe("notes.md");
    expect(() => {
      (seen as Record<string, unknown>)["path"] = "/etc/passwd";
    }).toThrow();
  });

  test("prototype-poisoning keys never reach the tool or the audit trail", async () => {
    // A model (or a web page talking through one) can put any key in the JSON
    // it emits. `__proto__` survives JSON.parse as an own property, and one
    // Object.assign downstream would turn it into prototype pollution.
    let seen: Record<string, unknown> | undefined;
    registry.register(
      define({
        name: "read_thing",
        parameters: {
          type: "object",
          properties: { path: { type: "string" } },
          additionalProperties: false,
        },
        run: async (args) => {
          seen = args;
          return { ok: true, content: "ok" };
        },
      }),
    );

    const call = await executor.execute(
      "read_thing",
      JSON.parse('{"path":"notes.md","__proto__":{"polluted":true},"constructor":"evil"}'),
    );

    expect(call.status).toBe("ok");
    expect(Object.keys(seen ?? {})).toEqual(["path"]);
    expect(({} as Record<string, unknown>)["polluted"]).toBeUndefined();
    expect(JSON.stringify(audit.entries()[0])).not.toContain("evil");
  });

  test("a strict schema still rejects an inherited-name property", async () => {
    // Belt to the sanitiser's braces: names that are not stripped (toString,
    // valueOf) used to pass `key in properties` and slip through.
    registry.register(define({ name: "read_thing" }));
    const call = await executor.execute(
      "read_thing",
      JSON.parse('{"path":"notes.md","toString":"evil"}'),
    );
    expect(call.status).toBe("denied");
    expect(call.content).toContain('unknown property "toString"');
  });
});

describe("audit peer", () => {
  test("records which client was attached when the call happened", async () => {
    let peer = "pid=421 uid=501 /Applications/akari.app";
    const withPeer = new ToolExecutor({
      registry,
      host,
      audit,
      peer: () => peer,
    });
    registry.register(define({ name: "read_thing" }));

    await withPeer.execute("read_thing", {});
    expect(audit.entries()[0]?.peer).toBe("pid=421 uid=501 /Applications/akari.app");

    // Read per call: the app can disconnect and another client take over.
    peer = "pid=999 uid=501 /tmp/other";
    await withPeer.execute("read_thing", {});
    expect(audit.entries()[1]?.peer).toBe("pid=999 uid=501 /tmp/other");
  });
});
