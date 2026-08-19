/**
 * Who is allowed to connect to the core's unix socket.
 *
 * ## Why this exists
 *
 * The socket is the whole trust boundary. Whoever holds the other end receives
 * the RED confirmation cards of ADR-002 and answers them, and can push audio
 * frames that drive the model into calling tools. Without a check on the peer,
 * "wait for a human to nod" degrades to "wait for any local process to send
 * `approve`", and the confirmation gate stops meaning anything.
 *
 * ## What this actually buys — read this before trusting it
 *
 * The `path` tier below is a **speed bump, not isolation**:
 *
 *   - A pid is not an identity. The peer can exit between connect(2) and the
 *     `proc_pidpath` lookup here, and the kernel may hand that number to
 *     something else. The window is small, not zero.
 *   - A path is not an identity either. Anything that can write to the
 *     allow-listed path — which, for the dev-tree entries, is any process
 *     running as this user — can put its own binary there and be trusted.
 *   - It stops an unprivileged, *unprepared* local process from impersonating
 *     akari.app. It does not stop a local attacker who is trying.
 *
 * The check that would be real is `SecCodeCopyGuestWithAttributes` on the
 * peer's audit token followed by `SecCodeCheckValidity` against a designated
 * requirement — the running process's code signature, not a path. That needs an
 * Apple Developer Team ID, which this project does not have yet, so it is a
 * declared tier (`codesign`) that refuses to start rather than a silent
 * downgrade. `PeerIdentity.auditToken` is already captured for it.
 */

import { realpathSync } from "node:fs";
import { basename, dirname, extname, resolve } from "node:path";
import { darwinAvailable, peerCredentials, type PeerCredentials } from "./darwin.ts";

export type PeerIdentity = PeerCredentials;

export type PeerPolicyTier = "off" | "path" | "codesign";

export interface PeerVerdict {
  allowed: boolean;
  /** Why. Logged on refusal; never sent to the peer. */
  reason: string;
}

export interface PeerPolicy {
  readonly tier: PeerPolicyTier;
  /** One line for the startup log, honest about what the tier proves. */
  readonly describe: string;
  /** `null` means the kernel would not tell us who the peer is. */
  check(peer: PeerIdentity | null): PeerVerdict;
}

/** Kernel-reported identity of the peer on `fd`, or null if it is unavailable. */
export function identifyPeer(fd: number): PeerIdentity | null {
  return peerCredentials(fd);
}

/** Human-readable peer for the audit line. Safe to log: no credentials. */
export function describePeer(peer: PeerIdentity | null): string {
  if (!peer) return "peer=<unidentified>";
  return `peer pid=${peer.pid} uid=${peer.uid} exe=${peer.executablePath || "<unknown>"}`;
}

/**
 * No check at all. Only for `AKARI_PEER_POLICY=off` and for tests that are
 * exercising something other than the peer check.
 */
export function allowAnyPeer(): PeerPolicy {
  return {
    tier: "off",
    describe: "off — ANY local process may connect and answer confirmation cards",
    check: () => ({ allowed: true, reason: "policy off" }),
  };
}

/**
 * Accept a peer whose executable path is on `allowed` and whose uid matches
 * this process. Paths are compared after `realpath`, so the symlinked
 * `.build/debug` that SwiftPM produces resolves to the same entry.
 */
export function executablePathPolicy(allowed: readonly string[]): PeerPolicy {
  return {
    tier: "path",
    describe:
      `path — peer executable must be one of ${allowed.length} allow-listed paths. ` +
      "This raises the bar; it is NOT isolation (pids are reused, paths can be replaced). " +
      "Code-signature verification is not enabled: no Team ID yet.",
    check(peer) {
      if (!darwinAvailable) {
        return { allowed: false, reason: "libSystem is unavailable, so the peer cannot be identified" };
      }
      if (!peer) {
        return { allowed: false, reason: "the kernel would not report the peer's identity" };
      }
      const self = process.getuid?.();
      if (self !== undefined && peer.uid !== self) {
        return { allowed: false, reason: `peer uid ${peer.uid} is not this user (${self})` };
      }
      if (allowed.length === 0) {
        return { allowed: false, reason: "no allowed executables are configured" };
      }
      if (!peer.executablePath) {
        return { allowed: false, reason: `pid ${peer.pid} has no readable executable path` };
      }
      // Resolved per connection, not once at construction: the app binary may
      // not exist yet when the core starts, and `.build/debug` is a symlink
      // SwiftPM repoints on every build.
      const accepted = new Set<string>();
      for (const entry of allowed) {
        accepted.add(entry);
        accepted.add(canonicalize(entry));
      }
      if (
        !accepted.has(peer.executablePath) &&
        !accepted.has(canonicalize(peer.executablePath))
      ) {
        return { allowed: false, reason: `${peer.executablePath} is not an allow-listed akari.app` };
      }
      return { allowed: true, reason: "executable path is allow-listed" };
    },
  };
}

/**
 * The tier that would actually be worth trusting. Not implemented: it needs a
 * Developer ID / Team ID this project does not have, and a half-version of it
 * (shelling out to `codesign` against the on-disk path) would verify a file
 * rather than the running process — the same TOCTOU hole as the path tier,
 * wearing a better name. Refusing to start is the honest answer.
 */
export function codeSignaturePolicy(teamId: string | undefined): PeerPolicy {
  throw new Error(
    "AKARI_PEER_POLICY=codesign is declared but not implemented: it needs " +
      "SecCodeCopyGuestWithAttributes/SecCodeCheckValidity over the peer's audit token " +
      `and an Apple Developer Team ID (AKARI_PEER_TEAM_ID${teamId ? ` = ${teamId}` : " is unset"}). ` +
      "Use AKARI_PEER_POLICY=path until the app is signed.",
  );
}

/** Repo root, from `<repo>/core/src/peer.ts`. Mirrors how index.ts finds `.env`. */
function repoRoot(): string {
  return resolve(import.meta.dir, "..", "..");
}

/**
 * The app that ships *with this core*, when this core is the copy inside a
 * bundle (`<bundle>/Contents/Resources/core`, which is the only core a release
 * build will run — CoreProcess.resolveCoreDirectory).
 *
 * Without this entry the allow-list is derived from `repoRoot()`, which for a
 * bundled core resolves to `<bundle>/Contents` and produces paths that cannot
 * exist. A bundle anywhere other than /Applications then refuses its own app —
 * including `make app-bundle && open build/akari.app`, the flow the README
 * tells you to use for anything permission-shaped.
 *
 * It is not a widening: the executable named here is a file inside the same
 * bundle as this very source file, so anyone who could plant it could equally
 * well have edited the core it is being checked by.
 */
function siblingBundleApp(): string | null {
  // <bundle>/Contents/Resources/core/src -> <bundle>/Contents
  const contents = resolve(import.meta.dir, "..", "..", "..");
  if (basename(contents) !== "Contents") return null;
  const bundle = dirname(contents);
  if (extname(bundle) !== ".app") return null;
  return `${contents}/MacOS/${basename(bundle, ".app")}`;
}

/**
 * Where a real akari.app lives: the installed bundle, the app this core is
 * bundled inside (if any), the `make app-bundle` output, and the two SwiftPM
 * binaries `make run-app` produces.
 */
export function defaultAllowedPeerPaths(): string[] {
  const root = repoRoot();
  const home = Bun.env.HOME ?? "";
  const sibling = siblingBundleApp();
  return [
    "/Applications/akari.app/Contents/MacOS/akari",
    ...(home ? [`${home}/Applications/akari.app/Contents/MacOS/akari`] : []),
    ...(sibling ? [sibling] : []),
    `${root}/build/akari.app/Contents/MacOS/akari`,
    `${root}/app/.build/debug/akari`,
    `${root}/app/.build/release/akari`,
  ];
}

/**
 * `AKARI_PEER_POLICY` picks the tier (`path` is the default), `AKARI_PEER_ALLOW`
 * replaces the allow-list with a colon-separated list of absolute paths.
 * An unknown value throws rather than falling back to something weaker.
 */
export function peerPolicyFromEnv(env: Record<string, string | undefined> = Bun.env): PeerPolicy {
  const tier = (env.AKARI_PEER_POLICY ?? "path").trim();
  switch (tier) {
    case "off":
      return allowAnyPeer();
    case "path": {
      const override = (env.AKARI_PEER_ALLOW ?? "")
        .split(":")
        .map((entry) => entry.trim())
        .filter((entry) => entry.length > 0);
      return executablePathPolicy(override.length > 0 ? override : defaultAllowedPeerPaths());
    }
    case "codesign":
      return codeSignaturePolicy(env.AKARI_PEER_TEAM_ID);
    default:
      throw new Error(
        `AKARI_PEER_POLICY=${tier} is not a known tier (off | path | codesign)`,
      );
  }
}

function canonicalize(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    // Not built / not installed yet. Keep the literal so the entry still
    // matches once it exists — the next connect() re-resolves it anyway.
    return path;
  }
}
