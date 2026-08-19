/**
 * Credential resolution (ADR-009, docs/protocol.md §八).
 *
 * Two sources, and both stay:
 *
 *   app  — the user's Keychain, pushed over the socket by akari.app
 *   env  — `process.env`, which the core fills from `.env` at startup
 *
 * Precedence is **per slot, app first**. Per slot rather than per source so a
 * half-filled Keychain cannot blank out a `.env` that works; app first because
 * the settings window is where the user just typed, and a value that loses to a
 * file they forgot about is the worst kind of bug to report.
 *
 * `.env` alone is a complete configuration: `make run-core` with no app must
 * keep working, and that is exactly the case where nothing ever provides an
 * `app` value.
 *
 * Nothing in this module logs a value. `describe()` exists so callers have
 * something loggable that is not the secret.
 */

import { createHash } from "node:crypto";
import {
  CREDENTIAL_SLOTS,
  type CredentialSlot,
  type CredentialSource,
  type CredentialStore,
  type ResolvedCredential,
} from "./providers/types.ts";

/** Environment variable each slot falls back to. Mirrors `.env.example`. */
export const CREDENTIAL_ENV_VARS: Record<CredentialSlot, string> = {
  "dashscope.apiKey": "DASHSCOPE_API_KEY",
  "cloudflare.accountId": "CLOUDFLARE_ACCOUNT_ID",
  "cloudflare.apiToken": "CLOUDFLARE_API_TOKEN",
  "huggingface.token": "HF_TOKEN",
};

/**
 * What the app reported for a slot in `credentials.provide`.
 *
 * `cleared` and `unset` differ and the difference is load-bearing: the user who
 * deletes a token in the settings window means "stop using it", and falling
 * back to a stale `.env` behind their back would keep billing the old account.
 * `unset` (never configured here) does fall back.
 *
 * `denied` is the Keychain refusing to unlock. It falls back like `unset` —
 * a locked Keychain should not take voice down when `.env` has a key — but is
 * reported separately so the UI can say why the field looks empty.
 */
export type AppCredentialState = "set" | "cleared" | "unset" | "denied";

export interface AppCredential {
  slot: CredentialSlot;
  state: AppCredentialState;
  /** Present only when `state === "set"`. */
  value?: string;
}

/** Loggable, showable summary of one slot. Carries no secret. */
export interface CredentialDescription {
  slot: CredentialSlot;
  source: CredentialSource;
  present: boolean;
  fingerprint?: string;
  /** The app explicitly cleared it; the `.env` fallback is suppressed. */
  cleared?: boolean;
  /** The app could not read the Keychain. */
  denied?: boolean;
  /** Variable the `env` fallback reads, so the UI can name it. */
  envVar: string;
}

/**
 * Short, non-reversible id of a value: first 8 hex of its SHA-256.
 *
 * Enough to answer "did this change?" and "are both sides holding the same
 * thing?" in a log line. 32 bits of a hash over a high-entropy API key is not a
 * usable oracle; a truncated *prefix of the key itself* would be, which is why
 * this module offers no masking helper. The app holds the plaintext and can
 * mask it for its own field if it wants to.
 */
export function fingerprint(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex").slice(0, 8);
}

function isBlank(value: string | undefined): boolean {
  return value === undefined || value.trim().length === 0;
}

/**
 * Holds the app-provided half and resolves it against an environment snapshot.
 *
 * The env snapshot is injected rather than read from `process.env` so tests can
 * run the precedence rules without touching the real environment or needing a
 * real credential.
 */
export class CredentialResolver implements CredentialStore {
  readonly #env: Record<string, string | undefined>;
  readonly #app = new Map<CredentialSlot, AppCredential>();

  constructor(env: Record<string, string | undefined> = process.env) {
    this.#env = env;
  }

  /**
   * Apply a `credentials.provide` payload.
   *
   * Returns the slots whose effective value changed, so the caller can rebuild
   * only the providers that care — swapping the DashScope key means renewing a
   * live Realtime session, and doing that for an unrelated Cloudflare edit
   * would cost the user a turn for nothing.
   *
   * Slots the app did not mention are left alone. A disconnect does **not**
   * clear them: reverting to `.env` mid-session would silently move billing to
   * another account and drop the voice session with it.
   */
  applyFromApp(values: readonly AppCredential[]): CredentialSlot[] {
    const changed: CredentialSlot[] = [];
    for (const incoming of values) {
      if (!CREDENTIAL_SLOTS.includes(incoming.slot)) continue;
      const before = this.get(incoming.slot);
      const normalised: AppCredential =
        incoming.state === "set" && isBlank(incoming.value)
          ? // A "set" with nothing in it is a bug on the sending side; treat it
            // as the clear it looks like rather than storing an empty secret.
            { slot: incoming.slot, state: "cleared" }
          : incoming.state === "set"
            ? { slot: incoming.slot, state: "set", value: incoming.value }
            : { slot: incoming.slot, state: incoming.state };
      this.#app.set(incoming.slot, normalised);
      const after = this.get(incoming.slot);
      // Compared by fingerprint, not by source: `.env` and the Keychain holding
      // the same key is the ordinary case after a user copies their key into
      // the settings window, and rebuilding there would drop a live Realtime
      // session to arrive at exactly the same session.
      if (before.fingerprint !== after.fingerprint) changed.push(incoming.slot);
    }
    return changed;
  }

  get(slot: CredentialSlot): ResolvedCredential {
    const app = this.#app.get(slot);
    if (app?.state === "set" && !isBlank(app.value)) {
      const value = app.value as string;
      return { slot, source: "app", value, fingerprint: fingerprint(value) };
    }
    if (app?.state === "cleared") {
      return { slot, source: "unset", cleared: true };
    }
    const fromEnv = this.#env[CREDENTIAL_ENV_VARS[slot]];
    if (!isBlank(fromEnv)) {
      const value = (fromEnv as string).trim();
      return { slot, source: "env", value, fingerprint: fingerprint(value) };
    }
    return { slot, source: "unset" };
  }

  value(slot: CredentialSlot): string | undefined {
    return this.get(slot).value;
  }

  /** Every slot, without values. This is what may be logged and sent. */
  describe(): CredentialDescription[] {
    return CREDENTIAL_SLOTS.map((slot) => {
      const resolved = this.get(slot);
      const denied = this.#app.get(slot)?.state === "denied";
      return {
        slot,
        source: resolved.source,
        present: resolved.value !== undefined,
        ...(resolved.fingerprint ? { fingerprint: resolved.fingerprint } : {}),
        ...(resolved.cleared ? { cleared: true } : {}),
        ...(denied ? { denied: true } : {}),
        envVar: CREDENTIAL_ENV_VARS[slot],
      };
    });
  }

  /** One line per slot, for the startup log. Says which source won. */
  logLines(): string[] {
    return this.describe().map((d) => {
      if (d.source === "unset") {
        const why = d.cleared ? "cleared in settings" : d.denied ? "keychain locked" : "not configured";
        return `credential ${d.slot}: unset (${why}; env fallback ${d.envVar})`;
      }
      return `credential ${d.slot}: ${d.source} (fp ${d.fingerprint})`;
    });
  }
}
