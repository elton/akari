import type { ToolDefinition } from "../types.ts";
import { runProcess } from "./process.ts";

/**
 * 🟢 GREEN — launch or focus an application.
 *
 * Mutating is true even though the level is green: launching something is an
 * act on the machine, so once untrusted content is in the conversation this
 * escalates to a confirmation card like every other mutating tool.
 */
export function openAppTool(): ToolDefinition {
  return {
    name: "open_app",
    description:
      "Launch an application, or bring it to the front if it is already " +
      "running. Give either its display name or its bundle id, not both.",
    parameters: {
      type: "object",
      properties: {
        name: {
          type: "string",
          minLength: 1,
          maxLength: 128,
          description: 'Display name, e.g. "Safari" or "Visual Studio Code".',
        },
        bundleId: {
          type: "string",
          minLength: 1,
          maxLength: 256,
          pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*$",
          description: 'Bundle identifier, e.g. "com.apple.Safari".',
        },
      },
      additionalProperties: false,
    },
    risk: "green",
    mutating: true,
    confirmTitle: "打开应用",
    describe: (args) =>
      typeof args["bundleId"] === "string"
        ? `open -b ${String(args["bundleId"])}`
        : `open -a ${String(args["name"] ?? "")}`,
    async run(args, context) {
      const name = args["name"];
      const bundleId = args["bundleId"];
      const hasName = typeof name === "string";
      const hasBundleId = typeof bundleId === "string";
      if (hasName === hasBundleId) {
        return {
          ok: false,
          content: "Give exactly one of `name` or `bundleId`.",
        };
      }

      const argv = hasBundleId
        ? ["/usr/bin/open", "-b", bundleId as string]
        : ["/usr/bin/open", "-a", name as string];

      const result = await runProcess(argv, {
        timeoutMs: 15_000,
        ...(context.signal ? { signal: context.signal } : {}),
      });
      if (result.timedOut) {
        return { ok: false, content: "`open` timed out after 15s." };
      }
      if (result.code !== 0) {
        // `open` says "Unable to find application named 'Xcodee'" here.
        const detail = (result.stderr || result.stdout).trim();
        return {
          ok: false,
          content: `Could not open it (exit ${result.code}): ${detail}`,
        };
      }
      return {
        ok: true,
        content: `Opened ${(bundleId ?? name) as string}.`,
      };
    },
  };
}
