/**
 * The handful of libSystem calls the core needs and Bun does not expose.
 *
 * macOS only. Everything here degrades to `null` when `dlopen` fails, so the
 * callers can decide whether that is fatal (peer verification: yes) or merely
 * a lost feature (the parent watchdog: no).
 */

import { dlopen, FFIType, ptr } from "bun:ffi";

/** `SOL_LOCAL` from <sys/un.h>. */
const SOL_LOCAL = 0;
/** `LOCAL_PEERCRED` — struct xucred for the process that called connect(2). */
const LOCAL_PEERCRED = 0x001;
/** `LOCAL_PEERPID` — pid of the process that called connect(2). */
const LOCAL_PEERPID = 0x002;
/** `LOCAL_PEERTOKEN` — audit_token_t of the peer; the input SecCode wants. */
const LOCAL_PEERTOKEN = 0x006;
/** `XUCRED_VERSION` from <sys/ucred.h>. */
const XUCRED_VERSION = 0;
/** sizeof(struct xucred): version, uid, ngroups (+pad), 16 gids. */
const XUCRED_SIZE = 76;
/** sizeof(audit_token_t) — 8 uint32. */
const AUDIT_TOKEN_SIZE = 32;
/** `PROC_PIDPATHINFO_MAXSIZE` from <libproc.h>. */
const PROC_PIDPATHINFO_MAXSIZE = 4096;

const symbols = (() => {
  try {
    return dlopen("/usr/lib/libSystem.B.dylib", {
      getsockopt: {
        args: [FFIType.i32, FFIType.i32, FFIType.i32, FFIType.ptr, FFIType.ptr],
        returns: FFIType.i32,
      },
      getppid: { args: [], returns: FFIType.i32 },
      proc_pidpath: {
        args: [FFIType.i32, FFIType.ptr, FFIType.u32],
        returns: FFIType.i32,
      },
    }).symbols;
  } catch {
    return null;
  }
})();

/** False on anything that is not macOS, or when FFI is unavailable. */
export const darwinAvailable = symbols !== null;

export interface PeerCredentials {
  /** pid of the process that called connect(2) at the time it connected. */
  pid: number;
  /** Effective uid of that process, straight from the kernel. */
  uid: number;
  /** Absolute path of the peer's executable, or "" when it could not be read. */
  executablePath: string;
  /**
   * The peer's `audit_token_t`, the argument `SecCodeCopyGuestWithAttributes`
   * takes. Captured now so the code-signing tier is a drop-in later; nothing
   * reads it yet.
   */
  auditToken: Uint8Array | null;
}

/**
 * Kernel-reported identity of whoever is on the other end of `fd`.
 *
 * The uid is authoritative — the kernel recorded it at connect(2) time and it
 * cannot be spoofed. The pid is authoritative for the same instant, but a pid
 * is not a stable identity: it can be recycled, and the executable it points at
 * can be swapped between the connect and this lookup. See `peer.ts`.
 */
export function peerCredentials(fd: number): PeerCredentials | null {
  if (!symbols) return null;

  const pidOut = new Int32Array(1);
  const pidLen = new Uint32Array([4]);
  if (symbols.getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, ptr(pidOut), ptr(pidLen)) !== 0) {
    return null;
  }
  const pid = pidOut[0]!;

  const cred = new Uint8Array(XUCRED_SIZE);
  const credLen = new Uint32Array([XUCRED_SIZE]);
  if (symbols.getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, ptr(cred), ptr(credLen)) !== 0) {
    return null;
  }
  const view = new DataView(cred.buffer);
  // arm64/x86_64 are little-endian; struct xucred is native byte order.
  if (view.getUint32(0, true) !== XUCRED_VERSION) return null;
  const uid = view.getUint32(4, true);

  const token = new Uint8Array(AUDIT_TOKEN_SIZE);
  const tokenLen = new Uint32Array([AUDIT_TOKEN_SIZE]);
  const gotToken =
    symbols.getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, ptr(token), ptr(tokenLen)) === 0 &&
    tokenLen[0] === AUDIT_TOKEN_SIZE;

  return {
    pid,
    uid,
    executablePath: executablePathOf(pid),
    auditToken: gotToken ? token : null,
  };
}

/** `proc_pidpath(2)`. Empty string when the process is gone or unreadable. */
export function executablePathOf(pid: number): string {
  if (!symbols) return "";
  const buffer = new Uint8Array(PROC_PIDPATHINFO_MAXSIZE);
  const length = symbols.proc_pidpath(pid, ptr(buffer), PROC_PIDPATHINFO_MAXSIZE);
  if (length <= 0) return "";
  return new TextDecoder().decode(buffer.subarray(0, length));
}

/**
 * The *current* parent pid. `process.ppid` in Bun is a plain value captured at
 * startup, so it keeps reporting the original parent after a reparent — which
 * is exactly the event the watchdog exists to notice.
 */
export function livePpid(): number | null {
  if (!symbols) return null;
  return symbols.getppid();
}
