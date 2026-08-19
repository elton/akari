import { describe, expect, test } from "bun:test";
import { ToolRegistry } from "./registry.ts";
import type { ToolContext, ToolDefinition } from "./types.ts";

function tool(overrides: Partial<ToolDefinition> = {}): ToolDefinition {
  return {
    name: "sample",
    description: "sample tool",
    parameters: { type: "object", properties: {}, additionalProperties: false },
    risk: "green",
    mutating: false,
    run: async () => ({ ok: true, content: "done" }),
    ...overrides,
  };
}

const clean: ToolContext = { untrustedContext: false, messages: [] };
const tainted: ToolContext = { untrustedContext: true, messages: [] };

describe("ToolRegistry.register", () => {
  test("refuses risk 'never' — those tools are absent, not gated", () => {
    expect(() => new ToolRegistry().register(tool({ risk: "never" }))).toThrow(
      /not offered at all/,
    );
  });

  test("refuses duplicates and malformed names", () => {
    const registry = new ToolRegistry();
    registry.register(tool());
    expect(() => registry.register(tool())).toThrow(/already registered/);
    expect(() => registry.register(tool({ name: "Bad Name" }))).toThrow(/must match/);
  });

  test("refuses a non-object parameter schema", () => {
    expect(() =>
      new ToolRegistry().register(tool({ parameters: { type: "string" } })),
    ).toThrow(/type "object"/);
  });

  test("refuses a mutating tool that cannot describe itself", () => {
    // Any mutating tool can be escalated to a red card, and a red card must
    // show the raw command.
    expect(() => new ToolRegistry().register(tool({ mutating: true }))).toThrow(
      /describe\(\)/,
    );
  });

  test("demands describe() from tools that read secrets or send data out too", () => {
    // Both dimensions escalate to red, so both need something to put on the card.
    expect(() =>
      new ToolRegistry().register(tool({ readsSensitive: true })),
    ).toThrow(/describe\(\)/);
    expect(() => new ToolRegistry().register(tool({ exfiltrates: true }))).toThrow(
      /describe\(\)/,
    );
  });
});

describe("ToolRegistry.schemas", () => {
  test("hands the model name, description and parameters only", () => {
    const registry = new ToolRegistry();
    registry.register(tool());
    expect(registry.schemas()).toEqual([
      {
        name: "sample",
        description: "sample tool",
        parameters: { type: "object", properties: {}, additionalProperties: false },
      },
    ]);
  });
});

describe("ToolRegistry.effectiveRisk", () => {
  const registry = new ToolRegistry();

  test("keeps the declared level in a clean context", () => {
    expect(registry.effectiveRisk(tool(), clean)).toBe("green");
    expect(
      registry.effectiveRisk(tool({ risk: "yellow", mutating: true, describe: () => "x" }), clean),
    ).toBe("yellow");
  });

  test("escalates every mutating tool to red once untrusted content is in context", () => {
    expect(
      registry.effectiveRisk(tool({ mutating: true, describe: () => "x" }), tainted),
    ).toBe("red");
    expect(
      registry.effectiveRisk(
        tool({ risk: "yellow", mutating: true, describe: () => "x" }),
        tainted,
      ),
    ).toBe("red");
  });

  test("escalates reading secrets and sending data out, not just mutation", () => {
    // The cheap injection is "read the clipboard, then search for it": two
    // read-only calls that mutate nothing and hand over everything. Grading by
    // destructiveness alone (ADR-002) leaves confidentiality unguarded.
    expect(
      registry.effectiveRisk(
        tool({ name: "clipboard_read", readsSensitive: true, describe: () => "pbpaste" }),
        tainted,
      ),
    ).toBe("red");
    expect(
      registry.effectiveRisk(
        tool({ name: "search", exfiltrates: true, describe: () => "search q" }),
        tainted,
      ),
    ).toBe("red");
  });

  test("leaves a purely local read-only tool alone", () => {
    // Nothing leaves the machine and nothing private comes in: no card.
    expect(registry.effectiveRisk(tool(), tainted)).toBe("green");
  });
});
