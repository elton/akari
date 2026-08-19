import type { Providers } from "./types.ts";

export type * from "./types.ts";

export type ProviderMode = "cloud" | "local";

export interface ProviderConfig {
  mode: ProviderMode;
  dashscopeApiKey?: string;
  dashscopeBaseUrl?: string;
  chatModel?: string;
  localModel?: string;
  localQuant?: string;
}

/**
 * Build the provider set for a mode. The switch between cloud and local is a
 * config value, never a code path in business logic (ADR-003).
 */
export function createProviders(_config: ProviderConfig): Providers {
  throw new Error("createProviders not implemented yet");
}
