// Regression: a second core must not delete a live core's socket.
//
// Found by an independent (Codex) review after three rounds of self-review had missed it.
// Our own verification did observe the symptom but filed it P3 as a developer
// inconvenience; it is not. The stranded core keeps its metered Realtime session open and
// can never be reached again, while every client attaches to the newcomer.

import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Bridge } from "./bridge.ts";

const dirs: string[] = [];
const bridges: Bridge[] = [];

function socketPath(): string {
  const dir = mkdtempSync(join(tmpdir(), "akari-takeover-"));
  dirs.push(dir);
  return join(dir, "core.sock");
}

afterEach(async () => {
  for (const b of bridges.splice(0)) await b.close().catch(() => {});
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

test("a second core refuses to take over a socket that is still being served", async () => {
  const path = socketPath();

  const first = new Bridge({ socketPath: path });
  bridges.push(first);
  await first.listen();

  const second = new Bridge({ socketPath: path });
  bridges.push(second);

  await expect(second.listen()).rejects.toThrow(/already serving/i);

  // And the first one is untouched: still listening, still reachable.
  const probe = await Bun.connect({
    unix: path,
    socket: { data() {}, open() {}, close() {}, error() {} },
  });
  expect(probe).toBeDefined();
  probe.end();
});

test("a stale socket left by a crashed core is still cleared", async () => {
  const path = socketPath();

  // Bind and then abandon the inode without unlinking, exactly as a SIGKILL would.
  const orphan = new Bridge({ socketPath: path });
  await orphan.listen();
  await orphan.close({ unlinkSocket: false }).catch(() => orphan.close());

  const fresh = new Bridge({ socketPath: path });
  bridges.push(fresh);
  await fresh.listen(); // must not throw — nothing is serving that inode any more
});
