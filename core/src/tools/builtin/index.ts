import type { ClipboardHost, SpeechHost, ToolDefinition } from "../types.ts";
import { clipboardReadTool } from "./clipboard-read.ts";
import { openAppTool } from "./open-app.ts";
import { speakTool } from "./speak.ts";

export { clipboardReadTool } from "./clipboard-read.ts";
export { openAppTool } from "./open-app.ts";
export { speakTool } from "./speak.ts";

export interface BuiltinToolDeps {
  /**
   * Speech output. `speak` is only registered when this is supplied — better a
   * missing tool than one the model calls into a void.
   */
  speech?: SpeechHost;
  /**
   * Clipboard access through the app. Without it `clipboard_read` falls back to
   * `pbpaste`, which cannot see the concealed/transient markers a password
   * manager sets — so that path is registered as 🔴 RED instead of 🟢 GREEN.
   */
  clipboard?: ClipboardHost;
}

/**
 * The tools that exist today — the samples that exercise the framework.
 * `clipboard_read` is 🟢 GREEN only when a `ClipboardHost` is supplied; on the
 * `pbpaste` fallback it registers as 🔴 RED (see clipboard-read.ts).
 *
 * Still to come (ADR-002): 🟢 read_selection, calendar_read, search;
 * 🟡 write_file (workspace only), create_event, run_shortcut;
 * 🔴 run_shell, delete, writes outside the workspace, sending mail.
 */
export function createBuiltinTools(deps: BuiltinToolDeps = {}): ToolDefinition[] {
  const tools: ToolDefinition[] = [
    clipboardReadTool(deps.clipboard),
    openAppTool(),
  ];
  if (deps.speech) tools.unshift(speakTool(deps.speech));
  return tools;
}
