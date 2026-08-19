/**
 * Tool layer: registry, four-level risk gate, execution, audit trail (ADR-002).
 *
 *   const registry = createRegistry({ speech });
 *   const executor = new ToolExecutor({ registry, host: bridge });
 *   const call = await executor.execute(name, args, { messages });
 *   // call.content goes back to the model, whatever happened.
 */

import { createBuiltinTools, type BuiltinToolDeps } from "./builtin/index.ts";
import { ToolRegistry } from "./registry.ts";
import type { ToolDefinition } from "./types.ts";

export { AuditLog, jsonlFileSink, redact } from "./audit.ts";
export type { AuditEntry, AuditSink, InvocationStatus } from "./audit.ts";
export {
  DEFAULT_CONFIRM_TIMEOUT_MS,
  DEFAULT_UNDO_MS,
  ToolExecutor,
} from "./executor.ts";
export type {
  Invocation,
  InvokeOptions,
  ToolExecutorOptions,
} from "./executor.ts";
export { ToolRegistry } from "./registry.ts";
export { sanitizeToolArgs, validateArgs } from "./schema.ts";
export type { ValidationResult } from "./schema.ts";
export type {
  ClipboardHost,
  ClipboardReadResult,
  SpeechHost,
  ToolContext,
  ToolDefinition,
  ToolHost,
  ToolResult,
} from "./types.ts";
export { hasUntrustedContent, wrapUntrusted } from "./untrusted.ts";
export { createBuiltinTools } from "./builtin/index.ts";
export type { BuiltinToolDeps } from "./builtin/index.ts";

export interface CreateRegistryOptions extends BuiltinToolDeps {
  /** Registered after the built-ins. */
  extra?: ToolDefinition[];
}

/** A registry holding the built-in tools. */
export function createRegistry(options: CreateRegistryOptions = {}): ToolRegistry {
  const registry = new ToolRegistry();
  const { extra, ...deps } = options;
  for (const tool of createBuiltinTools(deps)) registry.register(tool);
  for (const tool of extra ?? []) registry.register(tool);
  return registry;
}
