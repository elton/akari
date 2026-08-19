import { mkdir, open } from "node:fs/promises";
import { dirname } from "node:path";
import type { ConfirmDecision, RiskLevel } from "../protocol.ts";

/**
 * Audit trail for tool calls: when, which tool, what arguments, which level it
 * ran at, whether a human confirmed it, and how it ended.
 *
 * Every call is recorded — including the ones that were refused — because the
 * refusals are what you read after something goes wrong.
 */

export type InvocationStatus =
  /** Ran and returned ok. */
  | "ok"
  /** Ran and reported a failure, or threw. */
  | "error"
  /** Never ran: unknown tool, bad arguments, denied, or context-isolated. */
  | "denied"
  /** Ran, then the user hit undo inside the yellow window. */
  | "undone";

export interface AuditEntry {
  /** Unix epoch milliseconds. */
  ts: number;
  /** Same instant as ISO-8601, so the JSONL file is readable by eye. */
  time: string;
  tool: string;
  /** Model-side call id, when the provider supplied one. */
  callId?: string;
  /**
   * Which client was attached to the socket at call time (pid / uid / path).
   * "The user approved it" is only evidence if the record also says which
   * process was showing the card.
   */
  peer?: string;
  /** Arguments after redaction — never the raw object. */
  args: unknown;
  /** Level declared on the tool; null when the tool is unknown. */
  declaredRisk: RiskLevel | null;
  /** Level actually enforced, after untrusted-context escalation. */
  effectiveRisk: RiskLevel | null;
  /** Was untrusted content in the conversation at call time. */
  untrustedContext: boolean;
  /** True only when a human approved this specific call. */
  confirmed: boolean;
  decision?: ConfirmDecision;
  status: InvocationStatus;
  /** Why it was refused / how it failed. Never carries tool output. */
  reason?: string;
  durationMs: number;
}

export type AuditSink = (entry: AuditEntry) => void;

export interface AuditLogOptions {
  /** How many entries to keep in memory for the menu bar / debugging. */
  capacity?: number;
  sinks?: AuditSink[];
}

export class AuditLog {
  readonly #capacity: number;
  readonly #entries: AuditEntry[] = [];
  readonly #sinks: AuditSink[];

  constructor(options: AuditLogOptions = {}) {
    this.#capacity = options.capacity ?? 500;
    this.#sinks = options.sinks ?? [];
  }

  record(entry: AuditEntry): void {
    this.#entries.push(entry);
    if (this.#entries.length > this.#capacity) {
      this.#entries.splice(0, this.#entries.length - this.#capacity);
    }
    for (const sink of this.#sinks) {
      try {
        sink(entry);
      } catch {
        // A broken sink must never take down a tool call.
      }
    }
  }

  /** Newest last. */
  entries(): readonly AuditEntry[] {
    return this.#entries;
  }

  clear(): void {
    this.#entries.length = 0;
  }
}

/**
 * Append entries as JSON Lines. Writes are chained so the file keeps call
 * order, and failures are swallowed: losing the audit file must not fail the
 * call it was recording.
 *
 * The file holds tool arguments — paths, message bodies, whatever the model
 * passed — so it is created 0600 under a 0700 directory, and an existing file
 * is tightened to 0600 on open. The default 0644 would leave every command
 * akari was asked to run readable by any process on the machine.
 */
export function jsonlFileSink(
  path: string,
  onError?: (error: unknown) => void,
): AuditSink {
  const opened = mkdir(dirname(path), { recursive: true, mode: 0o700 })
    .then(() => open(path, "a", 0o600))
    .then(async (handle) => {
      // `mode` on open only applies when the file is created.
      await handle.chmod(0o600);
      return handle;
    });
  // The sink may be built and never written to; keep an unopened file from
  // surfacing as an unhandled rejection. Write failures still reach onError.
  opened.catch(() => undefined);

  let queue: Promise<unknown> = Promise.resolve();
  return (entry) => {
    queue = queue
      .then(() => opened)
      .then((handle) => handle.appendFile(`${JSON.stringify(entry)}\n`, "utf8"))
      .catch((error: unknown) => onError?.(error));
  };
}

const SECRET_KEY = /(key|token|secret|password|passwd|credential|authorization|cookie)/i;
const REDACTED = "[redacted]";
const MAX_STRING = 200;
const MAX_ARRAY = 20;
const MAX_DEPTH = 4;

/**
 * Strip credentials and cap size before anything is written to disk.
 *
 * The .env of this project holds a DashScope key; a tool argument such as
 * `{ env: { DASHSCOPE_API_KEY: "sk-..." } }` would otherwise land in the audit
 * file in clear text.
 */
export function redact(value: unknown, depth = 0): unknown {
  if (typeof value === "string") {
    return value.length > MAX_STRING
      ? `${value.slice(0, MAX_STRING)}…(+${value.length - MAX_STRING} chars)`
      : value;
  }
  if (value === null || typeof value !== "object") return value;
  if (depth >= MAX_DEPTH) return "[deep]";

  if (Array.isArray(value)) {
    const head = value.slice(0, MAX_ARRAY).map((v) => redact(v, depth + 1));
    return value.length > MAX_ARRAY
      ? [...head, `…(+${value.length - MAX_ARRAY} items)`]
      : head;
  }

  const out: Record<string, unknown> = {};
  for (const [key, entry] of Object.entries(value)) {
    out[key] = SECRET_KEY.test(key) ? REDACTED : redact(entry, depth + 1);
  }
  return out;
}
