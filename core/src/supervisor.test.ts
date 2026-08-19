import { describe, expect, test } from "bun:test";
import { startParentWatchdog } from "./supervisor.ts";

/**
 * The failure this guards: akari.app is SIGKILLed, no `applicationWillTerminate`
 * runs, the core is reparented to launchd and keeps a paid Realtime session and
 * an unowned socket alive forever.
 */
describe("parent watchdog", () => {
  test("fires when the parent goes away and the core is reparented", async () => {
    const reasons: string[] = [];
    let ppid = 4242;
    startParentWatchdog({
      supervised: true,
      intervalMs: 5,
      readPpid: () => ppid,
      onOrphaned: (reason) => reasons.push(reason),
    });

    await Bun.sleep(20);
    expect(reasons).toEqual([]);

    ppid = 1; // launchd adopted us
    await Bun.sleep(40);
    expect(reasons).toHaveLength(1);
    expect(reasons[0]).toContain("4242");

    // Only once, however long it keeps polling.
    await Bun.sleep(30);
    expect(reasons).toHaveLength(1);
  });

  test("fires for any reparent, not just to pid 1", async () => {
    const reasons: string[] = [];
    let ppid = 500;
    startParentWatchdog({
      supervised: true,
      intervalMs: 5,
      readPpid: () => ppid,
      onOrphaned: (reason) => reasons.push(reason),
    });
    ppid = 501;
    await Bun.sleep(40);
    expect(reasons).toHaveLength(1);
  });

  test("a core that is already an orphan at startup shuts down too", async () => {
    const reasons: string[] = [];
    startParentWatchdog({
      supervised: true,
      intervalMs: 5,
      readPpid: () => 1,
      onOrphaned: (reason) => reasons.push(reason),
    });
    await Bun.sleep(20);
    expect(reasons).toHaveLength(1);
    expect(reasons[0]).toContain("before startup finished");
  });

  test("make run-core is unaffected: without AKARI_SUPERVISED nothing fires", async () => {
    const reasons: string[] = [];
    let ppid = 4242;
    startParentWatchdog({
      supervised: false,
      intervalMs: 5,
      readPpid: () => ppid,
      onOrphaned: (reason) => reasons.push(reason),
    });
    ppid = 1;
    await Bun.sleep(40);
    expect(reasons).toEqual([]);
  });

  test("AKARI_SUPERVISED=1 is what turns it on", async () => {
    const reasons: string[] = [];
    let ppid = 4242;
    const previous = Bun.env.AKARI_SUPERVISED;
    Bun.env.AKARI_SUPERVISED = "1";
    try {
      startParentWatchdog({
        intervalMs: 5,
        readPpid: () => ppid,
        onOrphaned: (reason) => reasons.push(reason),
      });
      ppid = 1;
      await Bun.sleep(40);
      expect(reasons).toHaveLength(1);
    } finally {
      if (previous === undefined) delete Bun.env.AKARI_SUPERVISED;
      else Bun.env.AKARI_SUPERVISED = previous;
    }
  });

  test("stop() disarms it", async () => {
    const reasons: string[] = [];
    let ppid = 4242;
    const stop = startParentWatchdog({
      supervised: true,
      intervalMs: 5,
      readPpid: () => ppid,
      onOrphaned: (reason) => reasons.push(reason),
    });
    stop();
    ppid = 1;
    await Bun.sleep(40);
    expect(reasons).toEqual([]);
  });

  test("an unreadable ppid disables the watchdog instead of shutting down", async () => {
    const reasons: string[] = [];
    const logs: string[] = [];
    startParentWatchdog({
      supervised: true,
      intervalMs: 5,
      readPpid: () => null,
      onOrphaned: (reason) => reasons.push(reason),
      log: (_level, message) => logs.push(message),
    });
    await Bun.sleep(20);
    expect(reasons).toEqual([]);
    expect(logs.join("\n")).toContain("getppid is unavailable");
  });
});
