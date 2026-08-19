import type { ConfirmDecision, RiskLevel } from "../protocol.ts";
import type { ChatMessage } from "../providers/types.ts";
import {
  AuditLog,
  redact,
  type AuditEntry,
  type InvocationStatus,
} from "./audit.ts";
import type { ToolRegistry } from "./registry.ts";
import { sanitizeToolArgs, validateArgs } from "./schema.ts";
import type { ToolContext, ToolDefinition, ToolHost, ToolResult } from "./types.ts";
import { hasUntrustedContent } from "./untrusted.ts";

/**
 * Runs one tool call through the gate that its effective risk level demands
 * (ADR-002), then records what happened.
 *
 *   green  → run
 *   yellow → run, then a 1.5s undo toast (protocol.md §3.5: the toast says the
 *            tool has already run, so the tool has to run first)
 *   red    → confirmation card showing the verbatim command, then run only on
 *            an explicit approve
 *
 * Untrusted content in the conversation is sticky for the rest of the session:
 * once a screenshot or a clipboard read has landed, every mutating call is red,
 * and shell-class tools are refused outright. Taint is held here rather than
 * derived from the message list because long conversations get summarised and
 * truncated (Realtime cuts audio context at 80 turns), and a defence that a
 * summary can erase is not a defence.
 */

export const DEFAULT_CONFIRM_TIMEOUT_MS = 30_000;
export const DEFAULT_UNDO_MS = 1_500;

export interface ToolExecutorOptions {
  registry: ToolRegistry;
  host: ToolHost;
  audit?: AuditLog;
  /**
   * Who was connected when the call happened, e.g. "pid=421 uid=501
   * /Applications/akari.app". Read per call, not once: the app can disconnect
   * and a different client can take its place while the core stays up. Reading
   * an approval out of the audit file is only worth something if it says which
   * client obtained it.
   */
  peer?: () => string | undefined;
}

export interface InvokeOptions {
  /** Conversation so far; scanned for untrusted messages. */
  messages?: ChatMessage[];
  /** Model-side call id, recorded in the audit trail. */
  callId?: string;
  signal?: AbortSignal;
}

export interface Invocation {
  tool: string;
  status: InvocationStatus;
  /** The string to hand back to the model. Always populated. */
  content: string;
  declaredRisk: RiskLevel | null;
  effectiveRisk: RiskLevel | null;
  untrustedContext: boolean;
  confirmed: boolean;
  decision?: ConfirmDecision;
  reason?: string;
  durationMs: number;
}

export class ToolExecutor {
  readonly #registry: ToolRegistry;
  readonly #host: ToolHost;
  readonly #audit: AuditLog;
  readonly #peer: (() => string | undefined) | undefined;
  #tainted = false;
  #requestSeq = 0;

  constructor(options: ToolExecutorOptions) {
    this.#registry = options.registry;
    this.#host = options.host;
    this.#audit = options.audit ?? new AuditLog();
    this.#peer = options.peer;
  }

  get audit(): AuditLog {
    return this.#audit;
  }

  /** True once untrusted content has entered this session. Never resets. */
  get untrusted(): boolean {
    return this.#tainted;
  }

  /**
   * Mark the session as having seen external content. Call this from anywhere
   * that feeds the model something it did not get from the user — a screenshot,
   * page text, a file read.
   */
  markUntrusted(): void {
    this.#tainted = true;
  }

  async execute(
    name: string,
    rawArgs: Record<string, unknown>,
    options: InvokeOptions = {},
  ): Promise<Invocation> {
    const startedAt = Date.now();
    // What the card showed is what runs: strip the prototype-poisoning keys,
    // then freeze the arguments before they are validated, described on a
    // confirmation card, and finally executed, so nothing holding a reference
    // can swap them out while the user reads.
    const args = deepFreeze(sanitizeToolArgs(rawArgs));
    const messages = options.messages ?? [];
    if (hasUntrustedContent(messages)) this.#tainted = true;

    const context: ToolContext = {
      untrustedContext: this.#tainted,
      messages,
      ...(options.signal ? { signal: options.signal } : {}),
    };

    const tool = this.#registry.get(name);
    if (!tool) {
      return this.#finish(
        {
          tool: name,
          status: "denied",
          content: `Tool "${name}" is not available.`,
          declaredRisk: null,
          effectiveRisk: null,
          untrustedContext: context.untrustedContext,
          confirmed: false,
          reason: "unknown tool",
        },
        args,
        options.callId,
        startedAt,
      );
    }

    const risk = this.#registry.effectiveRisk(tool, context);
    const base = {
      tool: tool.name,
      declaredRisk: tool.risk,
      effectiveRisk: risk,
      untrustedContext: context.untrustedContext,
    };

    const validation = validateArgs(tool.parameters, args);
    if (!validation.ok) {
      return this.#finish(
        {
          ...base,
          status: "denied",
          content: `Invalid arguments for "${tool.name}": ${validation.errors.join("; ")}`,
          confirmed: false,
          reason: "invalid arguments",
        },
        args,
        options.callId,
        startedAt,
      );
    }

    // Context isolation, not escalation: a shell-class tool and external
    // content must not share a context at all (spec.md §4.4).
    if (tool.isolateFromUntrusted && context.untrustedContext) {
      return this.#finish(
        {
          ...base,
          status: "denied",
          content:
            `"${tool.name}" is unavailable in this conversation: it cannot run once ` +
            `external content has been read. Start a fresh session to use it.`,
          confirmed: false,
          reason: "shell capability isolated from untrusted context",
        },
        args,
        options.callId,
        startedAt,
      );
    }

    let confirmed = false;
    let decision: ConfirmDecision | undefined;

    if (risk === "red") {
      decision = await this.#confirm(tool, args, context);
      confirmed = decision === "approve";
      if (!confirmed) {
        return this.#finish(
          {
            ...base,
            status: "denied",
            content: `The user did not approve "${tool.name}" (${decision}).`,
            confirmed: false,
            decision,
            reason: `confirmation ${decision}`,
          },
          args,
          options.callId,
          startedAt,
        );
      }
    }

    let result: ToolResult;
    try {
      result = await tool.run(args, context);
    } catch (error) {
      return this.#finish(
        {
          ...base,
          status: "error",
          content: `"${tool.name}" failed: ${messageOf(error)}`,
          confirmed,
          ...(decision ? { decision } : {}),
          reason: messageOf(error),
        },
        args,
        options.callId,
        startedAt,
      );
    }

    if (result.untrusted) this.#tainted = true;

    let status: InvocationStatus = result.ok ? "ok" : "error";
    let content = result.content;
    let reason: string | undefined;

    if (risk === "yellow" && result.ok) {
      const undone = await this.#offerUndo(tool, result);
      if (undone.requested && undone.reverted) {
        status = "undone";
        content = `The user undid "${tool.name}"; the change was reverted.`;
      } else if (undone.requested) {
        status = "error";
        reason = undone.error ?? "tool is not reversible";
        content =
          `The user asked to undo "${tool.name}", but it could not be reverted ` +
          `(${reason}). The change stands — tell the user.`;
      }
    }

    return this.#finish(
      {
        ...base,
        status,
        content,
        confirmed,
        ...(decision ? { decision } : {}),
        ...(reason ? { reason } : {}),
      },
      args,
      options.callId,
      startedAt,
    );
  }

  async #confirm(
    tool: ToolDefinition,
    args: Record<string, unknown>,
    context: ToolContext,
  ): Promise<ConfirmDecision> {
    const escalated = context.untrustedContext && tool.risk !== "red";
    const detail = tool.detail?.(args);
    try {
      const decision = await this.#host.requestConfirm({
        requestId: `c-${++this.#requestSeq}`,
        tool: tool.name,
        risk: "red",
        title: tool.confirmTitle ?? tool.name,
        ...(detail || escalated
          ? {
              detail: [
                detail,
                escalated
                  ? "这次对话读取过外部内容，所以这一步需要你确认。"
                  : undefined,
              ]
                .filter(Boolean)
                .join("\n"),
            }
          : {}),
        // Verbatim, never trimmed or prettified (protocol.md §3.5).
        ...(tool.describe ? { command: tool.describe(args) } : {}),
        timeoutMs: tool.confirmTimeoutMs ?? DEFAULT_CONFIRM_TIMEOUT_MS,
      });
      // Anything that is not a literal approve is a deny (protocol.md §3.5).
      return decision === "approve" ? "approve" : decision;
    } catch {
      // A dead bridge is a deny: never run a red tool because the card failed.
      return "deny";
    }
  }

  async #offerUndo(
    tool: ToolDefinition,
    result: ToolResult,
  ): Promise<{ requested: boolean; reverted: boolean; error?: string }> {
    let requested = false;
    try {
      requested = await this.#host.notifyUndoable({
        requestId: `u-${++this.#requestSeq}`,
        tool: tool.name,
        title: tool.confirmTitle ?? tool.name,
        undoMs: tool.undoMs ?? DEFAULT_UNDO_MS,
      });
    } catch {
      // No toast shown means no undo requested; the tool has already run.
      return { requested: false, reverted: false };
    }
    if (!requested) return { requested: false, reverted: false };
    if (!result.undo) {
      return {
        requested: true,
        reverted: false,
        error: "tool provided no undo()",
      };
    }
    try {
      await result.undo();
      return { requested: true, reverted: true };
    } catch (error) {
      return { requested: true, reverted: false, error: messageOf(error) };
    }
  }

  #finish(
    partial: Omit<Invocation, "durationMs">,
    args: Record<string, unknown>,
    callId: string | undefined,
    startedAt: number,
  ): Invocation {
    const invocation: Invocation = {
      ...partial,
      durationMs: Date.now() - startedAt,
    };
    // Never let bookkeeping break the call it is recording.
    let peer: string | undefined;
    try {
      peer = this.#peer?.();
    } catch {
      peer = undefined;
    }
    const entry: AuditEntry = {
      ts: startedAt,
      time: new Date(startedAt).toISOString(),
      tool: invocation.tool,
      ...(callId ? { callId } : {}),
      args: redact(args),
      ...(peer ? { peer } : {}),
      declaredRisk: invocation.declaredRisk,
      effectiveRisk: invocation.effectiveRisk,
      untrustedContext: invocation.untrustedContext,
      confirmed: invocation.confirmed,
      ...(invocation.decision ? { decision: invocation.decision } : {}),
      status: invocation.status,
      ...(invocation.reason ? { reason: invocation.reason } : {}),
      durationMs: invocation.durationMs,
    };
    this.#audit.record(entry);
    return invocation;
  }
}

function deepFreeze<T>(value: T): T {
  if (value === null || typeof value !== "object" || Object.isFrozen(value)) {
    return value;
  }
  for (const entry of Object.values(value)) deepFreeze(entry);
  return Object.freeze(value);
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
