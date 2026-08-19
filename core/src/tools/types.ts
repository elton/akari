import type {
  ConfirmDecision,
  RiskLevel,
  ToolConfirmRequestPayload,
  ToolUndoablePayload,
} from "../protocol.ts";
import type { ChatMessage } from "../providers/types.ts";

/**
 * Tool types shared by the registry, the executor and the built-in tools.
 * The four-level risk model itself is ADR-002; `RiskLevel` lives in
 * protocol.ts because the app sees it on confirmation cards.
 */

/** What a tool is told about the call site. */
export interface ToolContext {
  /**
   * True when untrusted content (screenshot OCR, web page text, file or
   * clipboard contents) has entered the conversation. Screenshots are the front
   * door for prompt injection: any text on screen can impersonate an
   * instruction. When this is set, every mutating tool is escalated to `red`
   * regardless of its declared level (spec.md §4.4).
   */
  untrustedContext: boolean;
  /** Conversation so far, for tools that need it. */
  messages: ChatMessage[];
  signal?: AbortSignal;
}

export interface ToolResult {
  ok: boolean;
  /** Fed back to the model. */
  content: string;
  /** Present when the tool can be reversed inside the yellow undo window. */
  undo?: () => Promise<void>;
  /**
   * Set when `content` carries text from outside the user — clipboard, page,
   * file, OCR. The executor turns this into session-wide taint, so every later
   * mutating call goes through the confirmation gate.
   */
  untrusted?: boolean;
}

export interface ToolDefinition {
  /** Model-callable identifier: lowercase, `[a-z][a-z0-9_]*`. */
  name: string;
  description: string;
  /** JSON Schema for the arguments object; must be `type: "object"`. */
  parameters: Record<string, unknown>;
  risk: RiskLevel;
  /** True if the tool mutates anything outside the process. */
  mutating: boolean;
  /**
   * True if the tool pulls private data into the conversation — clipboard,
   * selected text, file contents, a screenshot, the calendar.
   *
   * ADR-002 grades tools by how much damage they can do; prompt injection is
   * mostly after something else — the data. "Read the clipboard, then search
   * for it" destroys confidentiality without mutating a thing, so the two
   * dimensions below are graded separately from `mutating` and escalate on
   * their own (registry.effectiveRisk).
   */
  readsSensitive?: boolean;
  /** True if the tool sends anything off this machine — search, mail, messages. */
  exfiltrates?: boolean;
  /** Card title shown for yellow/red, e.g. "运行 shell 命令". */
  confirmTitle?: string;
  /** The exact command/path to display verbatim on a red card. */
  describe?: (args: Record<string, unknown>) => string;
  /** Second line on the card: why she wants to do this, in plain language. */
  detail?: (args: Record<string, unknown>) => string;
  /**
   * Shell-class capability. Such a tool is refused outright — not escalated to
   * a card — once untrusted content is in the conversation, because "shell
   * 能力与外部内容处理不放在同一上下文" (spec.md §4.4) is a separation rule, and
   * a confirmation card cannot restore a separation that has already collapsed.
   */
  isolateFromUntrusted?: boolean;
  /** Red card timeout in ms; 0 waits forever. Default 30_000. */
  confirmTimeoutMs?: number;
  /** Yellow undo window in ms. Default 1500 (ADR-002). */
  undoMs?: number;
  run: (
    args: Record<string, unknown>,
    context: ToolContext,
  ) => Promise<ToolResult>;
}

/**
 * The half of the app bridge the tool layer needs. `Bridge` (bridge.ts)
 * satisfies this structurally — the executor takes the narrow port so it can be
 * driven by a fake in tests and so tools never reach for the socket directly.
 */
export interface ToolHost {
  /** Show the RED confirmation card and wait for the user. */
  requestConfirm(payload: ToolConfirmRequestPayload): Promise<ConfirmDecision>;
  /** Show the YELLOW undo toast; resolves true if the user undid it. */
  notifyUndoable(payload: ToolUndoablePayload): Promise<boolean>;
}

/** What the app hands back for one clipboard read. */
export interface ClipboardReadResult {
  /** The text flavour of the pasteboard, or null when it holds no text. */
  text: string | null;
  /**
   * True when the pasteboard carries `org.nspasteboard.ConcealedType` or
   * `org.nspasteboard.TransientType` — the convention password managers use to
   * say "this is a secret, do not archive it". `pbpaste` cannot see those
   * types, only AppKit can, which is why this port exists at all.
   */
  concealed: boolean;
}

/**
 * Clipboard access, provided by the app (NSPasteboard) over the socket.
 *
 * Deliberately a port rather than a `pbpaste` call: the concealed/transient
 * markers a password manager sets are invisible to the CLI, so a core-side read
 * cannot tell a copied URL from a copied master password.
 */
export interface ClipboardHost {
  readText(signal?: AbortSignal): Promise<ClipboardReadResult>;
}

/**
 * Speech output for the `speak` tool. Deliberately not part of ToolHost: the
 * wire protocol has no "speak this text" message, so whoever assembles the core
 * decides whether this goes through a TTS provider plus `audio.begin`, or
 * through a Realtime `response.create`.
 */
export interface SpeechHost {
  speak(text: string, signal?: AbortSignal): Promise<void>;
}
