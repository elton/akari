/**
 * Parent watchdog.
 *
 * When akari.app spawns the core and is then SIGKILLed (or crashes), no
 * `applicationWillTerminate` runs, nothing sends `app.quit`, and the core is
 * reparented to launchd. Left alone it keeps a paid Realtime session open and
 * keeps listening on the socket with nobody who owns it — which turns the
 * peer-impersonation problem in `peer.ts` from "race the real app for the
 * connection" into "connect whenever you like".
 *
 * `AKARI_SUPERVISED=1` is what the app sets when it spawns the core. Without
 * it the watchdog stays off, so `make run-core` in a terminal is unaffected.
 */

import { livePpid } from "./darwin.ts";
import type { LogLevel } from "./protocol.ts";

export interface ParentWatchdogOptions {
  /** Called once, when the supervising parent is gone. Should shut down. */
  onOrphaned: (reason: string) => void;
  /** Defaults to `AKARI_SUPERVISED === "1"`. */
  supervised?: boolean;
  /** Poll period. 5s: fast enough to stop billing, cheap enough to ignore. */
  intervalMs?: number;
  /** Test seam. Defaults to the real `getppid(2)`. */
  readPpid?: () => number | null;
  log?: (level: LogLevel, message: string) => void;
}

/** Returns a stop function; calling it is always safe, even when inactive. */
export function startParentWatchdog(options: ParentWatchdogOptions): () => void {
  const log = options.log ?? (() => {});
  const readPpid = options.readPpid ?? livePpid;
  const supervised = options.supervised ?? Bun.env.AKARI_SUPERVISED === "1";

  if (!supervised) {
    log("info", "parent watchdog off (AKARI_SUPERVISED is not 1); the core outlives its shell");
    return () => {};
  }

  const initial = readPpid();
  if (initial === null) {
    log("warn", "parent watchdog off: getppid is unavailable, so an orphaned core will keep running");
    return () => {};
  }

  let fired = false;
  let stop: () => void = () => {};
  const fire = (reason: string): void => {
    if (fired) return;
    fired = true;
    stop();
    log("warn", `supervising parent gone: ${reason}`);
    options.onOrphaned(reason);
  };

  // Already an orphan: the parent died between spawn and this call.
  if (initial === 1) {
    // Deferred so the caller can finish wiring up before shutdown runs.
    const immediate = setTimeout(() => fire("reparented to launchd before startup finished"), 0);
    stop = () => clearTimeout(immediate);
    return () => stop();
  }

  const timer = setInterval(() => {
    const current = readPpid();
    if (current === null || current === initial) return;
    fire(`parent ${initial} exited (now reparented to ${current})`);
  }, options.intervalMs ?? 5_000);
  // The socket keeps the process alive; this timer must not do it on its own.
  timer.unref?.();
  stop = () => clearInterval(timer);

  log("info", `parent watchdog on: shutting down if pid ${initial} goes away`);
  return () => stop();
}
