import { describe, expect, test } from "bun:test";
import { CredentialResolver } from "../credentials.ts";
import {
  DEFAULT_TEXT_MODELS,
  TEXT_MODEL_ENV_VARS,
  TEXT_PROVIDER_IDS,
  createTextProvider,
} from "./index.ts";
import type { TextProviderId } from "./types.ts";

/**
 * The contract every text provider owes the settings window. These hold for the
 * placeholders in `cloudflare.ts` / `local.ts` and must keep holding once they
 * are real — that is the point of testing them here rather than per file.
 *
 * Nothing here needs a credential: the resolver takes its environment by
 * injection, so "no credentials anywhere" is just an empty object.
 */
const deps = (env: Record<string, string | undefined> = {}) => ({
  credentials: new CredentialResolver(env),
  env,
});

describe.each([...TEXT_PROVIDER_IDS])("%s", (id: TextProviderId) => {
  test("constructs with nothing configured, and does not throw", () => {
    // A provider that refuses to exist until it works cannot be rendered as the
    // row that tells the user what is missing.
    expect(() => createTextProvider(id, deps())).not.toThrow();
  });

  test("capabilities and model are readable before any call", () => {
    const provider = createTextProvider(id, deps());
    expect(provider.id).toBe(id);
    expect(provider.model).toBe(DEFAULT_TEXT_MODELS[id]);
    expect(provider.capabilities.contextTokens).toBeGreaterThan(0);
    expect(typeof provider.capabilities.vision).toBe("boolean");
    expect(typeof provider.capabilities.tools).toBe("boolean");
  });

  test("the model comes from the env override when one is set", () => {
    const env = { [TEXT_MODEL_ENV_VARS[id]]: "someone/else" };
    expect(createTextProvider(id, deps(env)).model).toBe("someone/else");
  });

  test("probe resolves instead of throwing, and stamps checkedAt", async () => {
    const probe = await createTextProvider(id, deps()).probe();
    expect(probe.ok).toBe(probe.status === "ok");
    expect(probe.checkedAt).toBeGreaterThan(0);
    // A probe message is shown verbatim in the settings window.
    expect(typeof probe.message === "string" || probe.message === undefined).toBe(true);
  });
});

describe("cloudflare-workers-ai", () => {
  test("names the empty slots so the UI can point at the right field", async () => {
    const probe = await createTextProvider("cloudflare-workers-ai", deps()).probe();
    expect(probe.status).toBe("unconfigured");
    expect(probe.missing).toEqual(["cloudflare.accountId", "cloudflare.apiToken"]);
  });

  test("credentials from .env alone are enough to leave `unconfigured`", async () => {
    const env = {
      CLOUDFLARE_ACCOUNT_ID: "acct-placeholder",
      CLOUDFLARE_API_TOKEN: "cf-token-placeholder",
    };
    const probe = await createTextProvider("cloudflare-workers-ai", deps(env)).probe();
    expect(probe.status).not.toBe("unconfigured");
  });
});

describe("local-mlx", () => {
  test("never reports `unconfigured` — the local path has no credential", async () => {
    const probe = await createTextProvider("local-mlx", deps()).probe();
    expect(probe.status).not.toBe("unconfigured");
    expect(probe.missing).toBeUndefined();
  });

  test("declares itself local, which is what drives the privacy badge", () => {
    expect(createTextProvider("local-mlx", deps()).capabilities.local).toBe(true);
    expect(createTextProvider("cloudflare-workers-ai", deps()).capabilities.local).toBe(false);
  });
});
