/**
 * Text provider factory (ADR-009).
 *
 * Two rules the implementations in `./cloudflare.ts` and `./local.ts` must both
 * follow, because the settings UI depends on them:
 *
 * 1. **Construction never validates and never throws.** A provider with no
 *    credentials still constructs; `probe()` is what reports
 *    `"unconfigured"`. Otherwise the settings window cannot render a row for a
 *    provider until it already works, which is backwards — the row is how the
 *    user finds out what is missing.
 * 2. **`capabilities` is readable immediately**, before any network call, so a
 *    route can be described while it is still being probed.
 */

import type { LogLevel } from "../protocol.ts";
import { createCloudflareTextProvider } from "./cloudflare.ts";
import { createLocalTextProvider } from "./local.ts";
import type { CredentialStore, TextProvider, TextProviderId } from "./types.ts";

export type * from "./types.ts";
export {
  CREDENTIAL_SLOTS,
  ProviderError,
  TEXT_PROVIDER_IDS,
  VOICE_PROVIDER_ID,
} from "./types.ts";

/** Everything a provider is allowed to reach for. */
export interface TextProviderDeps {
  /** Resolved per slot, app-then-env (see `../credentials.ts`). */
  credentials: CredentialStore;
  /**
   * Environment snapshot for non-secret settings — model ids, endpoints, weight
   * paths. Injected rather than read from `process.env` so tests can drive it.
   */
  env?: Record<string, string | undefined>;
  log?: (level: LogLevel, message: string) => void;
}

/** Model each implementation uses unless its env override says otherwise. */
export const DEFAULT_TEXT_MODELS = {
  "cloudflare-workers-ai": "@cf/qwen/qwen3.8-27b",
  "local-mlx": "orcarouter/Qwen3.8-27B-Uncensored-MLX",
} as const satisfies Record<TextProviderId, string>;

/** Env var that overrides the model per implementation. */
export const TEXT_MODEL_ENV_VARS = {
  "cloudflare-workers-ai": "CF_AI_CHAT_MODEL",
  "local-mlx": "LOCAL_MLX_MODEL",
} as const satisfies Record<TextProviderId, string>;

export function createTextProvider(
  id: TextProviderId,
  deps: TextProviderDeps,
): TextProvider {
  switch (id) {
    case "cloudflare-workers-ai":
      return createCloudflareTextProvider(deps);
    case "local-mlx":
      return createLocalTextProvider(deps);
  }
}
