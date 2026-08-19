import { describe, expect, test } from "bun:test";
import type { Socket } from "bun";
import { realpathSync } from "node:fs";
import { copyFile, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { darwinAvailable, livePpid } from "./darwin.ts";
import {
  allowAnyPeer,
  defaultAllowedPeerPaths,
  describePeer,
  executablePathPolicy,
  identifyPeer,
  peerPolicyFromEnv,
  type PeerIdentity,
} from "./peer.ts";

/** Connect to ourselves over a real unix socket and read the kernel's answer. */
async function selfPeer(): Promise<PeerIdentity | null> {
  const dir = await mkdtemp(join(tmpdir(), "akari-peer-"));
  const path = join(dir, "p.sock");
  try {
    const { promise, resolve } = Promise.withResolvers<PeerIdentity | null>();
    const listener = Bun.listen<undefined>({
      unix: path,
      socket: {
        open: (socket: Socket<undefined>) => {
          const fd = (socket as unknown as { fd: number }).fd;
          resolve(identifyPeer(fd));
          socket.end();
        },
        data: () => {},
        close: () => {},
        error: () => {},
      },
    });
    const client = await Bun.connect<undefined>({
      unix: path,
      socket: { data: () => {}, open: () => {}, close: () => {}, error: () => {} },
    });
    const peer = await promise;
    client.end();
    listener.stop(true);
    return peer;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

describe("peer identity", () => {
  test("the kernel reports the connecting process, not the listener's guess", async () => {
    expect(darwinAvailable).toBe(true);
    const peer = await selfPeer();
    expect(peer).not.toBeNull();
    // Client and server are this same test process.
    expect(peer!.pid).toBe(process.pid);
    expect(peer!.uid).toBe(process.getuid!());
    expect(peer!.executablePath.length).toBeGreaterThan(0);
    // Captured for the code-signing tier that is not built yet.
    expect(peer!.auditToken?.byteLength).toBe(32);
  });

  test("describePeer is loggable and carries no secrets", async () => {
    const peer = await selfPeer();
    expect(describePeer(peer)).toContain(`pid=${process.pid}`);
    expect(describePeer(null)).toBe("peer=<unidentified>");
  });
});

describe("executable path policy", () => {
  const peer = (over: Partial<PeerIdentity> = {}): PeerIdentity => ({
    pid: 4242,
    uid: process.getuid!(),
    executablePath: "/Applications/akari.app/Contents/MacOS/akari",
    auditToken: null,
    ...over,
  });

  test("accepts an allow-listed executable", () => {
    const policy = executablePathPolicy(["/Applications/akari.app/Contents/MacOS/akari"]);
    expect(policy.check(peer()).allowed).toBe(true);
  });

  test("refuses anything else — this is the P0 case", () => {
    const policy = executablePathPolicy(["/Applications/akari.app/Contents/MacOS/akari"]);
    const verdict = policy.check(peer({ executablePath: "/usr/bin/nc" }));
    expect(verdict.allowed).toBe(false);
    expect(verdict.reason).toContain("/usr/bin/nc");
  });

  test("fails closed when the peer cannot be identified", () => {
    const policy = executablePathPolicy(["/Applications/akari.app/Contents/MacOS/akari"]);
    expect(policy.check(null).allowed).toBe(false);
  });

  test("fails closed on an empty allow-list", () => {
    expect(executablePathPolicy([]).check(peer()).allowed).toBe(false);
  });

  test("refuses another user even if the path matches", () => {
    const policy = executablePathPolicy(["/Applications/akari.app/Contents/MacOS/akari"]);
    const verdict = policy.check(peer({ uid: process.getuid!() + 1 }));
    expect(verdict.allowed).toBe(false);
    expect(verdict.reason).toContain("not this user");
  });

  test("a pid with no readable executable is refused", () => {
    const policy = executablePathPolicy(["/Applications/akari.app/Contents/MacOS/akari"]);
    expect(policy.check(peer({ executablePath: "" })).allowed).toBe(false);
  });

  test("resolves symlinks, so SwiftPM's .build/debug matches", () => {
    // process.execPath is real; realpath on both sides has to agree with it.
    const policy = executablePathPolicy([process.execPath]);
    expect(policy.check(peer({ executablePath: process.execPath })).allowed).toBe(true);
  });

  test("the tier says out loud that it is not code signing", () => {
    expect(executablePathPolicy(["/x"]).describe).toContain("NOT isolation");
  });
});

describe("policy selection", () => {
  test("path is the default and the allow-list points at real akari.app locations", () => {
    const policy = peerPolicyFromEnv({});
    expect(policy.tier).toBe("path");
    expect(defaultAllowedPeerPaths()).toContain("/Applications/akari.app/Contents/MacOS/akari");
    expect(defaultAllowedPeerPaths().some((p) => p.endsWith("/app/.build/debug/akari"))).toBe(true);
  });

  test("AKARI_PEER_ALLOW replaces the list", () => {
    const policy = peerPolicyFromEnv({ AKARI_PEER_ALLOW: "/one/akari:/two/akari" });
    expect(
      policy.check({ pid: 1, uid: process.getuid!(), executablePath: "/two/akari", auditToken: null })
        .allowed,
    ).toBe(true);
    expect(
      policy.check({ pid: 1, uid: process.getuid!(), executablePath: "/three/akari", auditToken: null })
        .allowed,
    ).toBe(false);
  });

  test("off is available but explicit", () => {
    expect(peerPolicyFromEnv({ AKARI_PEER_POLICY: "off" }).tier).toBe("off");
    expect(allowAnyPeer().check(null).allowed).toBe(true);
  });

  test("codesign refuses to start rather than pretending to verify", () => {
    expect(() => peerPolicyFromEnv({ AKARI_PEER_POLICY: "codesign" })).toThrow(
      /not implemented/,
    );
  });

  test("an unknown tier is an error, never a silent downgrade", () => {
    expect(() => peerPolicyFromEnv({ AKARI_PEER_POLICY: "yolo" })).toThrow(/not a known tier/);
  });

  /**
   * A release build only ever runs `<bundle>/Contents/Resources/core`, so the
   * allow-list has to name the app inside that same bundle. Derived from
   * `import.meta.dir`, which means it can only be checked by importing the
   * module from a bundle-shaped directory.
   */
  test("a bundled core allows the app it is bundled inside", async () => {
    const created = await mkdtemp(join(tmpdir(), "akari-bundle-"));
    // /var is a symlink to /private/var; the module resolves its own path.
    const dir = realpathSync(created);
    try {
      const src = join(dir, "akari.app", "Contents", "Resources", "core", "src");
      await mkdir(src, { recursive: true });
      for (const file of ["peer.ts", "darwin.ts"]) {
        await copyFile(join(import.meta.dir, file), join(src, file));
      }
      const bundled = (await import(join(src, "peer.ts"))) as {
        defaultAllowedPeerPaths: () => string[];
      };
      expect(bundled.defaultAllowedPeerPaths()).toContain(
        join(dir, "akari.app", "Contents", "MacOS", "akari"),
      );
    } finally {
      await rm(created, { recursive: true, force: true });
    }
  });

  test("a core in a checkout gains no bundle entry", () => {
    // `<repo>/core/src/../../..` is the directory above the repo; nothing there
    // may be treated as an app just because the walk lands on it.
    expect(defaultAllowedPeerPaths().every((p) => !p.endsWith("/MacOS/01-PWR"))).toBe(true);
    expect(defaultAllowedPeerPaths()).toHaveLength(5);
  });
});

describe("livePpid", () => {
  test("reads the current parent, unlike the frozen process.ppid", () => {
    expect(livePpid()).toBe(process.ppid);
  });
});
