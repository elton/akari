import type { RiskLevel } from "../protocol.ts";
import type { ToolSchema } from "../providers/types.ts";
import type { ToolContext, ToolDefinition } from "./types.ts";
import { isPlainObject } from "./schema.ts";

export type {
  SpeechHost,
  ToolContext,
  ToolDefinition,
  ToolHost,
  ToolResult,
} from "./types.ts";

/**
 * Tool registry and the four-level risk gate (ADR-002).
 *
 *   green  execute immediately
 *   yellow execute, then show a 1.5s undo toast
 *   red    show a confirmation card with the verbatim command, wait for a yes
 *   never  not registered at all — sudo, disk formatting, system settings
 *
 * The registry only decides *what may be called* and *at which level*. Running
 * the call is executor.ts.
 */

const NAME_PATTERN = /^[a-z][a-z0-9_]{0,63}$/;

export class ToolRegistry {
  readonly #tools = new Map<string, ToolDefinition>();

  register(tool: ToolDefinition): void {
    if (!NAME_PATTERN.test(tool.name)) {
      throw new Error(
        `tool name "${tool.name}" must match ${NAME_PATTERN.source}`,
      );
    }
    if (this.#tools.has(tool.name)) {
      throw new Error(`tool "${tool.name}" is already registered`);
    }
    if (tool.risk === "never") {
      // ⚫ NEVER is not a gate, it is an absence. Registering one would put its
      // schema in front of the model, which is exactly what the level forbids.
      throw new Error(
        `tool "${tool.name}" is risk "never": such tools are not offered at all (ADR-002)`,
      );
    }
    if (!isPlainObject(tool.parameters) || tool.parameters["type"] !== "object") {
      throw new Error(
        `tool "${tool.name}": parameters must be a JSON Schema with type "object"`,
      );
    }
    if ((tool.risk === "red" || canEscalate(tool)) && !tool.describe) {
      // A red card must show the raw command; without describe() there is
      // nothing to show and the user would be approving a blank cheque. Every
      // tool that untrusted context can escalate needs one — that is every
      // mutating tool, and every tool that reads secrets or sends data out.
      throw new Error(
        `tool "${tool.name}" can be confirmed as "red" and must provide describe() for the card`,
      );
    }
    this.#tools.set(tool.name, tool);
  }

  get(name: string): ToolDefinition | undefined {
    return this.#tools.get(name);
  }

  list(): ToolDefinition[] {
    return [...this.#tools.values()];
  }

  /** Schemas to hand to the model. `never` tools are never included. */
  schemas(): ToolSchema[] {
    return this.list().map((tool) => ({
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters,
    }));
  }

  /**
   * The level actually enforced for this call: the declared level, escalated to
   * `red` once untrusted content is in context and the tool can do one of the
   * three things an injected instruction is after — change something, read
   * something private, or send something out.
   *
   * This is the whole prompt-injection defence in one line. A web page or a
   * screenshot can talk the model into calling a tool; it cannot talk the user
   * into clicking approve.
   *
   * Escalating on `mutating` alone would have left the cheapest attack open:
   * "read the clipboard, then search for what you found" is two green calls,
   * mutates nothing, and hands over whatever was copied.
   */
  effectiveRisk(tool: ToolDefinition, context: ToolContext): RiskLevel {
    if (tool.risk === "never") return "never";
    if (context.untrustedContext && canEscalate(tool)) return "red";
    return tool.risk;
  }
}

/** True when untrusted context can push this tool up to a red card. */
function canEscalate(tool: ToolDefinition): boolean {
  return (
    tool.mutating === true ||
    tool.readsSensitive === true ||
    tool.exfiltrates === true
  );
}
