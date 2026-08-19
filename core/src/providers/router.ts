/**
 * Fallback routing for the `text` route (ADR-009).
 *
 * The ADR's table has three rows, but `docs/protocol.md` §3.9 is explicit that
 * the third one is not a route the user picks: it is where the `text` route
 * falls to. That lives here — the candidate order plus `selected: "auto"`.
 *
 * Four decisions worth reading before changing anything:
 *
 * 1. **Falling back is an `auto` behaviour.** Pin the route to a provider and it
 *    stays pinned: a user who chose the local model to keep a screenshot off the
 *    network is not helped by quietly sending it to Cloudflare because the model
 *    was slow to load. Pinned failures surface as errors, with the reason on the
 *    provider's row.
 *
 * 2. **No provider switch once bytes have been yielded.** A mid-stream failover
 *    would splice half of one answer onto the beginning of another. Fallback is
 *    only considered while the turn has produced nothing.
 *
 * 3. **Degrading is reported, never silent.** Every change of `selected`,
 *    `active` or any candidate's `status` fires `onChange` with the full
 *    `RouteState`, which is what `settings.state` carries — *and* a change of
 *    who is serving fires `onNotice`, which is the only message the protocol
 *    has for "put this in front of the user" (docs/protocol.md §3.8). The
 *    settings window alone was not enough: `auto` is the default, and a user
 *    who never opens that window would never learn that the answer came from
 *    the local model instead of their Cloudflare account.
 *
 * 4. **`active` is who *did* serve, not who is next in line.** These come apart
 *    exactly when it matters. A first network failure falls through and the
 *    answer is produced locally, but the cloud provider has not hit the
 *    failure threshold yet, so "who is next" still says Cloudflare — the user
 *    would be told their words went to the cloud on the one turn they did not.
 *    Same again when a cooldown lapses: the demoted provider becomes eligible
 *    while its row still reads `unreachable`, and the window would claim to be
 *    using something it is simultaneously reporting as down. So `active` is the
 *    last provider that actually produced a turn, and it only moves when
 *    another one actually produces one. `activeProvider()` is the other
 *    question — who a request would be *tried* on — and stays separate.
 *
 * 5. **Recovery is lazy, not a background poller.** A demoted provider carries a
 *    `demotedUntil`; once it passes, the provider is preferred again on the very
 *    next request. Nothing gets stuck at the bottom of the list, and the core
 *    does not sit there pinging a paid endpoint while the user is away. The cost
 *    is that one request after each cooldown pays the failure latency again,
 *    which is also what tells us the path is still down — bounded by
 *    `attemptTimeoutMs`, because "pays the failure latency" used to mean the
 *    system TCP timeout on a network that accepts a connection and then never
 *    answers (a captive portal, a half-dead VPN).
 */

import type { LogLevel, ProviderHealth, RouteState } from "../protocol.ts";
import { AUTO_PROVIDER } from "../protocol.ts";
import {
  ProviderError,
  type ChatChunk,
  type ChatRequest,
  type ProviderProbe,
  type ProviderStatus,
  type TextProvider,
} from "./types.ts";

export interface RouterConfig {
  /** Consecutive failures before a provider is skipped. Sticky statuses (see
   *  `STICKY_FAILURES`) skip it on the first one. */
  failureThreshold: number;
  /** First cooldown; it doubles on each further demotion. */
  cooldownMs: number;
  maxCooldownMs: number;
  /** Default for `probe()`; `docs/protocol.md` §3.9 sets 10000 and forbids 0. */
  probeTimeoutMs: number;
  /**
   * How long one attempt may go without producing a chunk before it is given
   * up on and counted as `unreachable`. 0 disables it.
   *
   * Not a cap on the whole turn: a long answer is not a failure, and the local
   * runtime streams at ~25 tok/s, so any wall-clock budget over a turn would
   * eventually shoot a working generation. What it bounds is *silence* —
   * nothing at all coming back — which is the shape a hung network has.
   *
   * Only applied to providers with `capabilities.local === false`. The local
   * runtime's slow path is loading 22.8 GB of weights (measured 12.1 s to the
   * first token cold), which is neither a network fault nor something falling
   * through would fix — it is the bottom of the list.
   */
  attemptTimeoutMs: number;
}

export const DEFAULT_ROUTER_CONFIG: RouterConfig = {
  failureThreshold: 2,
  cooldownMs: 60_000,
  maxCooldownMs: 15 * 60_000,
  probeTimeoutMs: 10_000,
  // Cloudflare answered a probe in 1191 ms and streamed a first token in
  // 410 ms on this account, so 15 s is roughly 12x the measured worst case and
  // still turns a 75 s system TCP timeout into a wait the user sits through.
  attemptTimeoutMs: 15_000,
};

export interface RouterOptions {
  /** Candidates in fallback order — index 0 is what `auto` prefers. */
  providers: TextProvider[];
  /** Fired with the new `RouteState` whenever the snapshot changes. */
  onChange?: (state: RouteState) => void;
  /**
   * One line to put in front of the user, for `ui.notice` (docs/protocol.md
   * §3.8). Fired only when the provider actually serving the route changes,
   * and only under `auto` — a pinned route does not fall back, so there is
   * nothing to announce. Chinese, one line, never a credential.
   */
  onNotice?: (level: LogLevel, text: string) => void;
  now?: () => number;
  log?: (level: LogLevel, message: string) => void;
  config?: Partial<RouterConfig>;
}

/**
 * Failures that will still be there in a second, so there is no point spending
 * a second request to find out: an expired allowance, a token without the right
 * permission, weights that are not on disk.
 */
const STICKY_FAILURES: ReadonlySet<ProviderStatus> = new Set<ProviderStatus>([
  "quota_exhausted",
  "unauthorized",
  "model_missing",
]);

/**
 * Statuses that mean "this provider is the problem". `error` is deliberately
 * absent: it is the status a provider throws when it cannot diagnose itself
 * (`types.ts` asks for `ProviderError` precisely so a broken request is
 * distinguishable from a broken provider), and blaming the provider for it
 * would send a malformed request down the whole candidate list.
 */
function isProviderFault(status: ProviderStatus): boolean {
  return status !== "error" && status !== "unknown";
}

/**
 * Statuses that do not contradict "this one is serving the route".
 *
 * Deliberately not `!isProviderFault(...)`: that predicate answers a question
 * about an *error's* status and never sees `ok`. This one answers a question
 * about a row in the settings window, where showing "当前在用：Cloudflare" next
 * to a red "连不上" on the same provider is the bug it exists to prevent.
 * `starting` is excluded for the same reason — a runtime still loading weights
 * is not serving anything yet.
 */
function looksUsable(status: ProviderStatus): boolean {
  return status === "ok" || status === "unknown";
}

/** What the user calls each provider. Ids are for the wire, not for a notice. */
const PROVIDER_LABELS: Readonly<Record<string, string>> = {
  "cloudflare-workers-ai": "Cloudflare",
  "local-mlx": "本地模型",
};

function providerLabel(id: string): string {
  return PROVIDER_LABELS[id] ?? id;
}

const CJK_HEAD = /^[㐀-鿿]/;
const CJK_TAIL = /[㐀-鿿]$/;
const LATIN_HEAD = /^[A-Za-z0-9]/;
const LATIN_TAIL = /[A-Za-z0-9]$/;

/**
 * Glue a sentence together, putting a space on every Latin/CJK boundary.
 *
 * "Cloudflare连不上" is the string a plain template literal produces, and it is
 * not how the rest of this codebase writes a user-facing line ("Cloudflare 拒绝
 * 了这对凭据"). Full-width punctuation is deliberately not CJK here, so
 * "…（内容不再上云）" does not gain a space it should not have.
 */
function joined(parts: string[]): string {
  return parts.reduce((text, part) => {
    if (text === "" || part === "") return text + part;
    const gap =
      (LATIN_TAIL.test(text) && CJK_HEAD.test(part)) ||
      (CJK_TAIL.test(text) && LATIN_HEAD.test(part));
    return gap ? `${text} ${part}` : text + part;
  }, "");
}

/** Half a sentence, for the notice. The long form is on the provider's row. */
function reasonText(status: ProviderStatus): string {
  switch (status) {
    case "unreachable":
      return "连不上";
    case "quota_exhausted":
      return "额度用尽";
    case "unauthorized":
      return "凭据被拒";
    case "unconfigured":
      return "还没配好";
    case "model_missing":
      return "模型不可用";
    case "starting":
      return "还在启动";
    default:
      return "出问题了";
  }
}

/** Race token for `#budgeted`; a chunk can be anything, a symbol cannot. */
const STALLED = Symbol("stalled");

interface Entry {
  provider: TextProvider;
  health: ProviderHealth;
  consecutiveFailures: number;
  demotions: number;
  /** Epoch ms until which this provider is skipped. */
  demotedUntil: number;
}

export class TextRouter {
  readonly #entries: Entry[];
  readonly #config: RouterConfig;
  readonly #now: () => number;
  readonly #log: (level: LogLevel, message: string) => void;
  readonly #onChange: (state: RouteState) => void;
  readonly #onNotice: (level: LogLevel, text: string) => void;
  /** The last candidate that actually produced a turn. See rule 4. */
  #active: Entry | undefined;
  #selected: string = AUTO_PROVIDER;
  #signature = "";
  #recoveryTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(options: RouterOptions) {
    this.#config = { ...DEFAULT_ROUTER_CONFIG, ...options.config };
    this.#now = options.now ?? (() => Date.now());
    this.#log = options.log ?? (() => {});
    this.#onChange = options.onChange ?? (() => {});
    this.#onNotice = options.onNotice ?? (() => {});
    this.#entries = options.providers.map((provider) => ({
      provider,
      health: {
        provider: provider.id,
        status: "unknown",
        model: provider.model,
        capabilities: provider.capabilities,
        checkedAt: 0,
      },
      consecutiveFailures: 0,
      demotions: 0,
      demotedUntil: 0,
    }));
    this.#signature = this.#snapshotSignature();
  }

  // --- state ---------------------------------------------------------------

  /** Exactly the `RouteState` that goes into `settings.state`. */
  state(): RouteState {
    return {
      route: "text",
      selected: this.#selected,
      active: this.#serving()?.provider.id ?? null,
      candidates: this.#entries.map((entry) => ({ ...entry.health })),
    };
  }

  /**
   * What a request would be *tried* on right now, or `undefined` if nothing.
   *
   * Not the same question as `state().active` (rule 4): a provider whose
   * cooldown just lapsed is tried again — that retry is how we find out the
   * path is back — while the window keeps reporting whoever last succeeded.
   */
  activeProvider(): TextProvider | undefined {
    return this.#preferred()?.provider;
  }

  /**
   * Apply `settings.set`. Returns false for a provider this route does not
   * have — the caller answers `error{code:"bad_payload"}` and **nothing here
   * changed**, which is what §3.9 requires.
   */
  select(provider: string): boolean {
    if (provider !== AUTO_PROVIDER && !this.#entries.some((e) => e.provider.id === provider)) {
      return false;
    }
    if (provider === this.#selected) return true;
    this.#selected = provider;
    this.#log("info", `text route: selected ${provider}`);
    // Pinning one provider is also the user saying the others may let go of
    // whatever they are holding — for the local runtime that is ~22.8 GB.
    for (const entry of this.#entries) {
      if (this.#candidates().includes(entry)) continue;
      void entry.provider.close?.().catch(() => {});
    }
    this.#emitIfChanged();
    return true;
  }

  /**
   * Forget every cooldown, because the reason for them may have just gone away.
   *
   * Called when credentials change (ADR-009 §八). Without it a provider demoted
   * for `unauthorized` or `unconfigured` keeps being skipped for up to fifteen
   * minutes after the user fixes the very thing that demoted it — the settings
   * window would say "可用" while requests still went to the fallback, which is
   * the worst of both: the user believes they fixed it and cannot see that they
   * did not.
   *
   * Statuses are left alone: they are the last *observed* truth, and the next
   * probe or request replaces them.
   */
  resetDemotions(): void {
    for (const entry of this.#entries) {
      entry.consecutiveFailures = 0;
      entry.demotions = 0;
      entry.demotedUntil = 0;
    }
    this.#emitIfChanged();
  }

  // --- requests ------------------------------------------------------------

  /**
   * Stream a reply from the first candidate that can produce one.
   *
   * Throws the last `ProviderError` when every candidate is out, so the caller
   * still sees a diagnosed failure rather than a generic one.
   */
  async *chat(request: ChatRequest): AsyncIterable<ChatChunk> {
    const attempts = this.#attemptOrder();
    if (attempts.length === 0) {
      throw new ProviderError("router", "unconfigured", "这一路没有可用的推理服务。");
    }

    let last: unknown;
    /** Set once this turn has already told the user it changed provider. */
    let announced = false;
    for (const [index, entry] of attempts.entries()) {
      const previous = this.#active;
      let produced = false;
      try {
        for await (const chunk of this.#attempt(entry, request)) {
          produced = true;
          yield chunk;
        }
        this.#recordSuccess(entry);
        this.#emitIfChanged();
        // Rule 3/4: `active` just moved, and moving it is the whole point of
        // the fallback, so the user hears about it once — here, not from a
        // window they may never open. `previous === undefined` is the first
        // turn of the process, which is not a change of anything.
        if (!announced && previous && previous !== entry) {
          const order = this.#candidates();
          if (order.indexOf(entry) > order.indexOf(previous)) {
            this.#announceDegrade(previous, entry, previous.health.status);
          } else {
            this.#announceRecovery(entry);
          }
        }
        return;
      } catch (error) {
        last = error;
        const status = error instanceof ProviderError ? error.status : "error";
        if (error instanceof ProviderError) this.#recordFailure(entry, error);
        this.#emitIfChanged();

        const isLast = index === attempts.length - 1;
        // Rule 2: once the user has seen text, this turn belongs to whoever
        // started it.
        if (produced || isLast || !isProviderFault(status)) throw error;
        const next = attempts[index + 1]!;
        this.#log(
          "warn",
          `text route: ${entry.provider.id} failed (${status}), falling through to ${next.provider.id}`,
        );
        // Announced here rather than after the fallback succeeds: the local
        // runtime takes 12.1 s to the first token cold, and the point of the
        // line is to explain that wait while it is happening. If `next` is
        // already the one serving, nothing changed and there is nothing to say
        // — which is what keeps a lapsed cooldown from re-announcing the same
        // degradation every 60 s / 2 min / 4 min.
        if (this.#active !== next) {
          this.#announceDegrade(entry, next, status);
          announced = true;
        }
      }
    }
    throw last;
  }

  /**
   * One candidate's stream, with `attemptTimeoutMs` between chunks.
   *
   * Local providers are handed through untouched — see the field's doc for why
   * the budget is a network measure. A budget of 0 disables it entirely.
   */
  #attempt(entry: Entry, request: ChatRequest): AsyncIterable<ChatChunk> {
    const budget = this.#config.attemptTimeoutMs;
    if (budget <= 0 || entry.provider.capabilities.local) return entry.provider.chat(request);
    return this.#budgeted(entry, request, budget);
  }

  /**
   * Give up on a provider that has gone quiet, and make the failure diagnosable.
   *
   * `fetch` against a network that accepts the connection and then answers
   * nothing — a captive portal, a VPN that is half up — hangs until the system
   * TCP timeout, about 75 s on this machine. That is the exact case the local
   * fallback exists for, and without this it was the case where the fallback
   * took the longest to arrive.
   *
   * The deadline is per chunk, not per turn, so a long answer is never cut off;
   * and the abort is raised on our own controller so the provider's socket is
   * closed rather than left to finish into nothing. The `ProviderError` is
   * built here rather than waited for, because a provider is entitled to treat
   * an abort as an ordinary barge-in and end its stream quietly — which would
   * otherwise read as a successful empty turn.
   */
  async *#budgeted(
    entry: Entry,
    request: ChatRequest,
    budget: number,
  ): AsyncGenerator<ChatChunk> {
    const deadline = new AbortController();
    const signal = request.signal
      ? AbortSignal.any([request.signal, deadline.signal])
      : deadline.signal;
    const iterator = entry.provider.chat({ ...request, signal })[Symbol.asyncIterator]();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      for (;;) {
        const next = iterator.next();
        // Whichever side loses the race is still a live promise; without this
        // a provider that rejects just after the deadline takes the process
        // down with an unhandled rejection.
        next.catch(() => {});
        const stalled = new Promise<typeof STALLED>((resolve) => {
          timer = setTimeout(() => {
            deadline.abort();
            resolve(STALLED);
          }, budget);
          timer.unref?.();
        });
        const step = await Promise.race([next, stalled]);
        clearTimeout(timer);
        if (step === STALLED) {
          throw new ProviderError(
            entry.provider.id,
            "unreachable",
            `${providerLabel(entry.provider.id)} ${Math.round(budget / 1000)} 秒内没有任何回应，当作连不上。`,
          );
        }
        if (step.done) return;
        yield step.value;
      }
    } finally {
      clearTimeout(timer);
      deadline.abort();
      void iterator.return?.().catch(() => {});
    }
  }

  // --- notices -------------------------------------------------------------

  /**
   * Falling back is an `auto` behaviour (rule 1), so only `auto` announces one.
   * A pinned route that fails says so as an error, and a user who just pinned a
   * provider does not need to be told the route changed — they changed it.
   */
  #announceDegrade(from: Entry, to: Entry, status: ProviderStatus) {
    if (this.#selected !== AUTO_PROVIDER) return;
    this.#onNotice(
      "warn",
      joined([
        providerLabel(from.provider.id),
        reasonText(status),
        "，已自动切到",
        providerLabel(to.provider.id),
        to.provider.capabilities.local ? "（内容不再上云）" : "",
        "。",
      ]),
    );
  }

  #announceRecovery(to: Entry) {
    if (this.#selected !== AUTO_PROVIDER) return;
    this.#onNotice(
      "info",
      joined([
        providerLabel(to.provider.id),
        "恢复了，之后的文本对话走",
        to.provider.capabilities.local ? "本地" : "云端",
        "。",
      ]),
    );
  }

  // --- probing -------------------------------------------------------------

  /** Probe every candidate (or just one), and fold the result into the state. */
  async probe(providerId?: string, timeoutMs?: number): Promise<ProviderHealth[]> {
    const budget = timeoutMs && timeoutMs > 0 ? timeoutMs : this.#config.probeTimeoutMs;
    const targets = providerId
      ? this.#entries.filter((entry) => entry.provider.id === providerId)
      : this.#entries;

    const results = await Promise.all(
      targets.map(async (entry) => {
        const started = this.#now();
        const probe = await this.#withTimeout(entry, budget);
        // Built from the probe, never merged over the previous one. Merging
        // kept fields the new probe deliberately omitted — a `quota` from the
        // last successful call survived onto an `unconfigured` result, so the
        // settings window showed a neuron count for a token that had just been
        // deleted. Anything the probe does not say is now unsaid.
        entry.health = {
          provider: entry.provider.id,
          status: probe.status,
          checkedAt: probe.checkedAt || this.#now(),
          model: probe.model ?? entry.provider.model,
          capabilities: entry.provider.capabilities,
          ...(probe.message === undefined ? {} : { message: probe.message }),
          ...(probe.missing === undefined ? {} : { missing: probe.missing }),
          ...(probe.quota === undefined ? {} : { quota: probe.quota }),
          latencyMs: probe.latencyMs ?? this.#now() - started,
        };
        if (probe.ok) {
          entry.consecutiveFailures = 0;
          entry.demotions = 0;
          entry.demotedUntil = 0;
        } else {
          this.#demote(entry, probe.status, probe.quota?.resetsAt);
        }
        return { ...entry.health };
      }),
    );

    this.#emitIfChanged();
    return results;
  }

  async close(): Promise<void> {
    if (this.#recoveryTimer) clearTimeout(this.#recoveryTimer);
    this.#recoveryTimer = undefined;
    await Promise.all(this.#entries.map((entry) => entry.provider.close?.().catch(() => {})));
  }

  // --- internals -----------------------------------------------------------

  /** Candidates the current selection allows, in fallback order. */
  #candidates(): Entry[] {
    if (this.#selected === AUTO_PROVIDER) return this.#entries;
    return this.#entries.filter((entry) => entry.provider.id === this.#selected);
  }

  #eligible(entry: Entry): boolean {
    return entry.demotedUntil <= this.#now();
  }

  #preferred(): Entry | undefined {
    const candidates = this.#candidates();
    return candidates.find((entry) => this.#eligible(entry)) ?? candidates[0];
  }

  /**
   * Who `RouteState.active` names: the one that last actually produced a turn.
   *
   * It sticks until someone else produces one, with two ways out. It is dropped
   * when the current selection no longer allows it (the user pinned the other
   * provider), and when its own row stops being something we would claim to be
   * using — the settings window must not say "当前在用：Cloudflare" above a
   * Cloudflare row that reads `unreachable`.
   *
   * Before anything has been served, and after either of those, this falls back
   * to the best *believable* candidate: eligible and not known to be broken.
   * `undefined` from here is `active: null` on the wire, which §3.9 defines as
   * "一条路全挂" — and that is the honest answer when nothing has served and
   * everything we know about is down.
   */
  #serving(): Entry | undefined {
    const candidates = this.#candidates();
    const last = this.#active;
    if (last && candidates.includes(last) && looksUsable(last.health.status)) return last;
    return candidates.find((entry) => this.#eligible(entry) && looksUsable(entry.health.status));
  }

  /**
   * Who to try, in order. When everything is demoted the whole list is tried
   * anyway: a router that refuses to talk to anyone because both providers
   * failed once is worse than one that pays a timeout.
   */
  #attemptOrder(): Entry[] {
    const candidates = this.#candidates();
    const eligible = candidates.filter((entry) => this.#eligible(entry));
    return eligible.length > 0 ? eligible : candidates;
  }

  async #withTimeout(entry: Entry, budget: number): Promise<ProviderProbe> {
    const started = this.#now();
    const timeout = new Promise<ProviderProbe>((resolve) => {
      const timer = setTimeout(
        () =>
          resolve({
            status: "unreachable",
            ok: false,
            message: "探测超时。",
            model: entry.provider.model,
            checkedAt: started,
          }),
        budget,
      );
      timer.unref?.();
    });
    try {
      return await Promise.race([
        entry.provider.probe(AbortSignal.timeout(budget)),
        timeout,
      ]);
    } catch (error) {
      // `probe()` is documented never to throw; a provider that does anyway is
      // not allowed to take the settings window down with it.
      this.#log("warn", `text route: ${entry.provider.id} probe threw: ${String(error)}`);
      return {
        status: "error",
        ok: false,
        message: "探测失败。",
        model: entry.provider.model,
        checkedAt: started,
      };
    }
  }

  #recordSuccess(entry: Entry) {
    // Only reached from `chat()`: a probe proves a provider answers, not that
    // it served the user anything, and rule 4 makes that distinction the whole
    // meaning of `active`.
    this.#active = entry;
    entry.consecutiveFailures = 0;
    entry.demotions = 0;
    entry.demotedUntil = 0;
    entry.health = {
      ...entry.health,
      status: "ok",
      checkedAt: this.#now(),
      capabilities: entry.provider.capabilities,
    };
    delete entry.health.message;
    delete entry.health.missing;
  }

  #recordFailure(entry: Entry, error: ProviderError) {
    entry.health = {
      ...entry.health,
      status: error.status,
      message: error.message,
      checkedAt: this.#now(),
      capabilities: entry.provider.capabilities,
    };
    delete entry.health.missing;
    // The number came from a credential that has since been removed or
    // rejected, so it is no longer a fact about anything the user can spend.
    if (error.status === "unconfigured" || error.status === "unauthorized") {
      delete entry.health.quota;
    }
    if (isProviderFault(error.status)) this.#demote(entry, error.status);
  }

  #demote(entry: Entry, status: ProviderStatus, resetsAt?: number) {
    if (!isProviderFault(status)) return;
    entry.consecutiveFailures += 1;
    const enough =
      STICKY_FAILURES.has(status) || entry.consecutiveFailures >= this.#config.failureThreshold;
    if (!enough) return;

    entry.demotions += 1;
    const backoff = Math.min(
      this.#config.cooldownMs * 2 ** (entry.demotions - 1),
      this.#config.maxCooldownMs,
    );
    // An allowance that names its own reset beats any backoff we could guess.
    const until =
      status === "quota_exhausted" && resetsAt && resetsAt > this.#now()
        ? resetsAt
        : this.#now() + backoff;
    entry.demotedUntil = Math.max(entry.demotedUntil, until);
    this.#log(
      "warn",
      `text route: ${entry.provider.id} demoted for ${until - this.#now()}ms (${status})`,
    );
    this.#scheduleRecoveryNotice();
  }

  /**
   * Push one `settings.state` when the earliest cooldown expires. Without it the
   * settings window would keep showing the fallback until the next request, and
   * "we are back on Cloudflare" would arrive later than it happened.
   */
  #scheduleRecoveryNotice() {
    if (this.#recoveryTimer) clearTimeout(this.#recoveryTimer);
    const next = this.#entries
      .map((entry) => entry.demotedUntil)
      .filter((until) => until > this.#now())
      .sort((a, b) => a - b)[0];
    if (next === undefined) return;
    this.#recoveryTimer = setTimeout(
      () => {
        this.#recoveryTimer = undefined;
        this.#emitIfChanged();
        this.#scheduleRecoveryNotice();
      },
      Math.max(0, next - this.#now()) + 1,
    );
    this.#recoveryTimer.unref?.();
  }

  #snapshotSignature(): string {
    const state = this.state();
    return [
      state.selected,
      state.active ?? "-",
      ...state.candidates.map((c) => `${c.provider}:${c.status}`),
    ].join("|");
  }

  #emitIfChanged() {
    const signature = this.#snapshotSignature();
    if (signature === this.#signature) return;
    this.#signature = signature;
    this.#onChange(this.state());
  }
}
