import { describe, expect, test } from "bun:test";
import {
  CREDENTIAL_ENV_VARS,
  CredentialResolver,
  fingerprint,
} from "./credentials.ts";

// No real credential appears in this file, and none is needed: the resolver
// takes its environment snapshot by injection.
const KEY = "sk-test-not-a-real-key";
const OTHER = "sk-test-not-a-real-key-either";

describe("precedence", () => {
  test("env alone configures the core — `make run-core` with no app", () => {
    const r = new CredentialResolver({ DASHSCOPE_API_KEY: KEY });
    expect(r.get("dashscope.apiKey")).toMatchObject({ source: "env", value: KEY });
    expect(r.value("dashscope.apiKey")).toBe(KEY);
  });

  test("the app wins over .env for the same slot", () => {
    const r = new CredentialResolver({ DASHSCOPE_API_KEY: KEY });
    r.applyFromApp([{ slot: "dashscope.apiKey", state: "set", value: OTHER }]);
    expect(r.get("dashscope.apiKey")).toMatchObject({ source: "app", value: OTHER });
  });

  test("precedence is per slot, so a half-filled keychain keeps .env working", () => {
    const r = new CredentialResolver({
      DASHSCOPE_API_KEY: KEY,
      CLOUDFLARE_API_TOKEN: "cf-token-placeholder",
    });
    r.applyFromApp([{ slot: "dashscope.apiKey", state: "set", value: OTHER }]);
    expect(r.get("dashscope.apiKey").source).toBe("app");
    expect(r.get("cloudflare.apiToken")).toMatchObject({ source: "env" });
  });

  test("an explicit clear suppresses the .env fallback", () => {
    const r = new CredentialResolver({ CLOUDFLARE_API_TOKEN: "cf-token-placeholder" });
    r.applyFromApp([{ slot: "cloudflare.apiToken", state: "cleared" }]);
    const resolved = r.get("cloudflare.apiToken");
    expect(resolved).toMatchObject({ source: "unset", cleared: true });
    expect(resolved.value).toBeUndefined();
  });

  test("`unset` is not a clear: never-configured falls back", () => {
    const r = new CredentialResolver({ CLOUDFLARE_API_TOKEN: "cf-token-placeholder" });
    r.applyFromApp([{ slot: "cloudflare.apiToken", state: "unset" }]);
    expect(r.get("cloudflare.apiToken").source).toBe("env");
  });

  test("a locked keychain falls back rather than taking voice down", () => {
    const r = new CredentialResolver({ DASHSCOPE_API_KEY: KEY });
    r.applyFromApp([{ slot: "dashscope.apiKey", state: "denied" }]);
    expect(r.get("dashscope.apiKey").source).toBe("env");
    expect(r.describe().find((d) => d.slot === "dashscope.apiKey")?.denied).toBe(true);
  });

  test("a blank `set` is treated as a clear, not stored as an empty secret", () => {
    const r = new CredentialResolver({ DASHSCOPE_API_KEY: KEY });
    r.applyFromApp([{ slot: "dashscope.apiKey", state: "set", value: "   " }]);
    expect(r.get("dashscope.apiKey")).toMatchObject({ source: "unset", cleared: true });
  });

  test("blank env values do not count as configured", () => {
    const r = new CredentialResolver({ DASHSCOPE_API_KEY: "  " });
    expect(r.get("dashscope.apiKey").source).toBe("unset");
  });

  test("slots the app did not mention are left alone", () => {
    const r = new CredentialResolver({});
    r.applyFromApp([{ slot: "cloudflare.accountId", state: "set", value: "acct-1" }]);
    r.applyFromApp([{ slot: "cloudflare.apiToken", state: "set", value: "cf-token-placeholder" }]);
    expect(r.value("cloudflare.accountId")).toBe("acct-1");
  });

  test("an unknown slot from the wire is ignored, not stored", () => {
    const r = new CredentialResolver({});
    r.applyFromApp([
      { slot: "nope.whatever" as never, state: "set", value: "x" },
    ]);
    expect(r.describe().map((d) => d.slot)).not.toContain("nope.whatever");
  });
});

describe("change reporting", () => {
  test("only the slots whose effective value moved are reported", () => {
    const r = new CredentialResolver({ DASHSCOPE_API_KEY: KEY });
    const changed = r.applyFromApp([
      // Same value the env already had: nothing downstream needs rebuilding,
      // and rebuilding would drop a live Realtime session for nothing.
      { slot: "dashscope.apiKey", state: "set", value: KEY },
      { slot: "cloudflare.accountId", state: "set", value: "acct-1" },
    ]);
    expect(changed).toEqual(["cloudflare.accountId"]);
  });

  test("clearing a slot that .env was serving counts as a change", () => {
    const r = new CredentialResolver({ CLOUDFLARE_API_TOKEN: "cf-token-placeholder" });
    expect(r.applyFromApp([{ slot: "cloudflare.apiToken", state: "cleared" }]))
      .toEqual(["cloudflare.apiToken"]);
  });

  test("the same key arriving from the keychain is not a change", () => {
    // The ordinary case right after the user pastes their key into settings:
    // .env already had it. Rebuilding here would cost a turn for nothing.
    const r = new CredentialResolver({ DASHSCOPE_API_KEY: KEY });
    expect(r.applyFromApp([{ slot: "dashscope.apiKey", state: "set", value: KEY }]))
      .toEqual([]);
    expect(r.get("dashscope.apiKey").source).toBe("app");
  });

  test("re-applying the same app value reports nothing", () => {
    const r = new CredentialResolver({});
    r.applyFromApp([{ slot: "huggingface.token", state: "set", value: "hf-x" }]);
    expect(r.applyFromApp([{ slot: "huggingface.token", state: "set", value: "hf-x" }]))
      .toEqual([]);
  });
});

describe("nothing leaks", () => {
  test("describe() carries no values", () => {
    const r = new CredentialResolver({ DASHSCOPE_API_KEY: KEY });
    r.applyFromApp([{ slot: "cloudflare.apiToken", state: "set", value: OTHER }]);
    const json = JSON.stringify(r.describe());
    expect(json).not.toContain(KEY);
    expect(json).not.toContain(OTHER);
  });

  test("log lines carry no values", () => {
    const r = new CredentialResolver({ DASHSCOPE_API_KEY: KEY });
    const lines = r.logLines().join("\n");
    expect(lines).not.toContain(KEY);
    expect(lines).toContain("credential dashscope.apiKey: env (fp ");
  });

  test("every slot names the env var it falls back to", () => {
    const r = new CredentialResolver({});
    for (const d of r.describe()) {
      expect(d.envVar).toBe(CREDENTIAL_ENV_VARS[d.slot]);
      expect(d.present).toBe(false);
      expect(d.source).toBe("unset");
    }
  });

  test("the fingerprint is short, stable and not the value", () => {
    expect(fingerprint(KEY)).toHaveLength(8);
    expect(fingerprint(KEY)).toBe(fingerprint(KEY));
    expect(fingerprint(KEY)).not.toBe(fingerprint(OTHER));
    expect(KEY).not.toContain(fingerprint(KEY));
  });
});
