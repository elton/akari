# akari · 明かり

A desktop-resident AI companion for macOS — an animated character that lives on your
desktop, talks with you by voice or text, reads things aloud, and acts as a personal
agent that can actually operate your Mac.

Powered by Qwen.

> Status: **P0 skeleton runs end to end, now with the security review applied.** A
> synthesized utterance pushed in over the socket comes back as spoken audio in
> 437ms, and function calling works. Two review passes (correctness + security)
> found 27 issues; every P2-and-above one is fixed — see
> [the hardening record](./docs/decisions.md#p0-骨架的安全加固). What that
> record is careful about is worth repeating here: the socket is checked from
> both ends, but neither check is isolation until this project has a signing
> identity — and the app→core half is the weaker of the two. See
> [Status](#status) for what is verified and what is not.

## Why the name

明かり (*akari*) — a light left on. That is what this is: something quietly lit on your
desktop, keeping you company and illuminating whatever you are working on.

## Design at a glance

| Layer | Choice | Why |
| --- | --- | --- |
| Avatar | Pre-rendered AI video loops, HEVC-with-alpha | No realtime photoreal avatar runs on Apple Silicon in 2026 |
| Window | `NSWindow.level = desktopIconWindow - 1` | Sits above wallpaper, below desktop icons. Zero entitlements |
| Voice | `qwen3.5-omni-flash-realtime` over WebSocket | Measured 473ms to first audio packet; server-side VAD and barge-in |
| Brain | `qwen3.7-flash` (cloud) / `Qwen3.8-27B-MLX` 6-bit (local) | Provider abstraction, each swappable independently |
| Control | Accessibility API + Shortcuts + shell, four-tier risk gating | GUI agents are ~86% accurate — one misstep every 7 actions |
| Shell | Swift/AppKit host + TypeScript core over a Unix socket | Business logic stays in TS; Swift is a thin system-glue layer |

Distribution is Developer ID + notarization. **Not** the Mac App Store — sandboxed apps
cannot read other applications' UI via the Accessibility API, and "read my selected text"
depends on exactly that.

## Build and run

Requires macOS 26, Swift 6.2+, and [Bun](https://bun.sh) 1.3+.

```bash
cp .env.example .env       # then fill in DASHSCOPE_API_KEY
make build                 # swift build + bun install
make check                 # swift build + swift test + tsc --noEmit + bun test
make run                   # starts the core, then the app
```

`make run` starts `akari-core` first (it owns the socket) and then the app. To run
the two halves separately — the usual thing while developing one side:

```bash
make run-core              # bun run core/src/index.ts
make run-app               # swift run akari
```

The app also starts a core by itself if nothing answers within two seconds, so
`make run-app` alone is enough for a normal launch. It looks for `bun` in
`$AKARI_BUN`, `~/.bun/bin`, `/opt/homebrew/bin` and `/usr/local/bin` — a GUI
process inherits almost no `PATH`.

To exercise the socket without touching the Realtime API (no key, no quota):

```bash
bun run core/src/index.ts --no-realtime
```

### Running it as a real .app

```bash
make app-bundle            # -> build/akari.app
open build/akari.app
```

Use the bundle for anything permission-shaped. A bare binary launched from a
terminal inherits the terminal's TCC grants, so `AXIsProcessTrusted()` returns
true and the microphone prompt never appears — the "responsible process" trap in
spec.md §4.4. The bundle sets `LSUIElement`, so akari lives in the menu bar and
not in the Dock.

The bundle carries its own copy of the core (`Contents/Resources/core`) and a
release build will run **only** that copy — never a `core/` directory it finds
lying next to the .app. It does **not** carry `.env`, because a distributable
bundle has no business holding a credential, so for voice in a bundled run put
the key where the core also looks:

```bash
mkdir -p ~/Library/Application\ Support/akari
cp .env ~/Library/Application\ Support/akari/.env   # 0600 is a good idea
```

Without it the core still starts, still serves the socket and still animates her
— it says `voice is unavailable` in its log, names every path it searched, and
the menu bar says so too.

### Configuration

| Variable | Meaning |
| --- | --- |
| `DASHSCOPE_API_KEY` | Required for voice. Read from the repo-root `.env`, then `~/Library/Application Support/akari/.env`; never logged |
| `AKARI_SOCKET` | Unix socket path. Must be under 104 bytes (macOS `sun_path`). The core reads it always; **the app reads it in DEBUG builds only** — see below |
| `AKARI_ASSETS_DIR` | Where `<state>.mov` lives. Defaults to the bundle, then `<repo>/assets/akari` |
| `AKARI_LOG_LEVEL` | `debug` \| `info` \| `warn` \| `error` |
| `AKARI_BUN` | Path to `bun`, when the app cannot find it |
| `AKARI_PEER_POLICY` | Who may connect to the socket: `path` (default) \| `off` \| `codesign`. See below |
| `AKARI_PEER_ALLOW` | Colon-separated absolute paths that replace the built-in akari.app allow-list |
| `AKARI_SUPERVISED` | `1` when the app spawned the core; the core then exits if that parent dies |
| `AKARI_AUDIT_LOG` | Where the tool audit trail is appended. Defaults to `audit.jsonl` beside the socket; created 0600 |

#### Socket trust boundary — where it actually stands

The Unix socket is the whole trust boundary, and it has **two** ends. Whoever holds
the core's end gets the RED confirmation cards of ADR-002 and answers them, and can
push audio that drives the model into calling tools. Whoever holds the app's end
gets the microphone uplink and the answer to `clipboard.read.request` — the read
that lives on the app side precisely because only the app can see the
`org.nspasteboard.ConcealedType` marker a password manager sets.

Both directions are checked, and **they are checked to different strengths**. Read
both rows before assuming either one covers you:

| Direction | What is verified | Stops | Does not stop |
| --- | --- | --- | --- |
| core → app | kernel-reported uid and `proc_pidpath` executable against an akari.app allow-list, per connection | another user; an unprepared local process; a non-admin cannot rewrite the binary inside `/Applications/akari.app` | your own uid overwriting a dev-tree path; pid reuse in the window before the lookup |
| app → core | `lstat` on the socket and its directory: owner is you, socket 0600, directory 0700, neither a symlink, and the socket really is a socket. Shipped builds also ignore `AKARI_SOCKET` | another user's socket; a socket in a world-writable directory (`/tmp` and friends); redirecting a shipped app with an environment variable | **a process already running as you** — it can unlink the real socket and bind its own with the same 0600 in the same 0700 directory, and no `stat` can tell them apart |

The app deliberately does *not* read `LOCAL_PEERPID` back off the connection the way
the core does. `NWConnection` exposes no file descriptor, so it would mean
hand-rolling the socket and its backpressure on the realtime audio path — and the
answer would be worth little anyway: the core is a script, so its executable is
`bun`, which lives in user-writable prefixes and will run any file you hand it.

The core's own check is the one with tiers:

| Tier | Status | What it proves |
| --- | --- | --- |
| `off` | available, logs an error on every start | nothing; any local process can drive akari |
| `path` | **current default** | the peer's uid is this user and its executable is one of the known akari.app paths, per `LOCAL_PEERCRED` / `LOCAL_PEERPID` + `proc_pidpath` |
| `codesign` | **declared, not implemented — refuses to start** | would verify the running process's code signature (`SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` over the peer's audit token) |

`path` is a speed bump, not isolation. A pid can be recycled between the connect
and the lookup, and anything that can write to an allow-listed path — for the
dev-tree entries, any process running as you — can put its own binary there. It
stops an unprepared local process from impersonating akari.app; it does not stop
a local attacker who is trying. Closing that needs an Apple Developer Team ID,
which this project does not have yet, so `codesign` throws rather than quietly
degrading. The startup log always names the active tier.

The socket is created 0600 inside a 0700 directory, forced with `chmod` and
verified by `stat` — `mkdir`/`bind` modes are masked by umask, and on a machine
with `umask 002`/`000` the defaults land group- or world-writable. A directory
this user cannot lock down (`/private/var/tmp` and friends) stops startup instead
of listening on a socket anyone could unlink and re-bind. The app checks the same
invariant from its side before every connection attempt, and backs off instead of
connecting when it does not hold.

Hold **⌥Space** to talk. The menu bar item has a toggle for when that chord is
already taken by something else.

## Status

### Verified by running it

| What | Evidence |
| --- | --- |
| Voice round trip | A `say`-synthesized question fed in over the socket → ASR transcript correct → reply audio back. Re-run after the hardening: `audio.begin` 437ms after `ptt.up`, 2.56s of 24kHz PCM, peak 29439, and `audio.done` put her back to `idle` |
| Avatar state machine | `greeting → listening → thinking → talking → idle` over a real turn, driven entirely by the core |
| Realtime session | Live WebSocket to `qwen3.5-omni-flash-realtime`, handshake 555ms, `server_vad=true` confirmed by the server |
| Desktop window level | The real app's two windows at `-2147483604` on both 5K displays, exact 2560x1440 geometry — above the Dock's wallpaper (`-2147483624`), below Finder's icons (`-2147483603`). Dumped from a separate process with `CGWindowListCopyWindowInfo` |
| app ↔ core handshake | The real Swift binary against the real Bun core over a Unix socket |
| Wire protocol | 24 frames covering every message type encoded in TypeScript, decoded in Swift, re-encoded, and compared byte-for-byte |
| Peer check | An unlisted process gets `unauthorized` and is hung up on before it learns anything; it cannot approve a RED card it never sees. The real `app/.build/debug/akari` (a SwiftPM symlink) resolves onto the allow-list |
| Clipboard port | Live, with the model driving it: "读一下剪贴板" → core asked the app → the app reported the pasteboard as concealed → she said the content was skipped. `pbpaste` was never spawned |
| Audit trail | Written 0600 beside the socket; each entry names the tool, the effective risk, whether a human confirmed it, and the pid/uid/path of the client that was attached |
| Orphan watchdog | The parent was SIGKILLed with the core running under `AKARI_SUPERVISED=1`; the core noticed the reparent and shut itself down within 5s |
| Core assembly | `core/src/index.test.ts` spawns the real entry point and drives it over a real socket — socket and audit modes, the peer audit line, an abandoned turn returning to `idle`, a missing key costing the voice but not the socket, `app.quit`, unknown-type tolerance |
| Test suite | `make check`: `swift build` (zero warnings) + 38 `swift test` + `tsc --noEmit` + 154 `bun test` |

### Compiles and is wired, but not yet exercised

- **Microphone capture.** `AVAudioEngine` capture, the ⌥Space Carbon hotkey, and the
  TCC prompt. Everything downstream of it is proven with synthesized audio instead.
- **Speaker playback.** `AVAudioPlayerNode` rendering of the downlink PCM, and the
  `audio.end` → drain → `audio.done` pairing.
- **The avatar on screen.** The windows are provably in the right layer, but nothing
  has watched a clip play there.
- **Confirmation cards and undo toasts.** The panels build and the core-side gate is
  tested against a fake app; no human has clicked one.
- **Power saving.** Occlusion sampling and pausing on lock/sleep.
- **The real pasteboard.** The concealment decision is unit-tested against
  synthetic type lists, and the socket round trip is tested end to end — but
  nothing has yet asked the actual `NSPasteboard.general` what a real password
  manager wrote to it.
- **`ui.notice` on screen.** The core sends it and the app routes it to the menu
  bar status line; nobody has watched that line change.

These need a GUI session and a person — the automated runs above drive the core
with a stand-in app, which is exactly what cannot prove the app's own UI. See
[Manual checks](#manual-checks).

### Not built yet

- Only two tools exist (`clipboard_read`, `open_app`). The Accessibility, Shortcuts
  and shell tools from ADR-002 are not written, so nothing has ever reached the RED
  confirmation gate in anger — the gate itself is tested, but only against a fake app.
- The `codesign` peer tier throws on purpose. Real peer isolation waits on an Apple
  Developer Team ID; until then both socket checks are speed bumps, and the app's
  check of the core does not stop a process running as you (see above).
- `createProviders()` throws. The local MLX path (ADR-003) is an interface only.
- Only `listening.mov` exists. Every other state falls back to it with a warning.
- No memory, no persona persistence across restarts, no settings UI — the menu's
  "设置…" opens the repo folder, because `.env` is the configuration.

## Manual checks

Unlock the machine, then:

1. `make app-bundle && open build/akari.app` — the menu bar icon appears, nothing
   in the Dock. For voice, copy `.env` to `~/Library/Application Support/akari/.env`
   first (see [Running it as a real .app](#running-it-as-a-real-app)). The core's log
   should say `AUDIT peer accepted` with the bundle's own binary path — if it says
   `peer refused`, the app and the core disagree about who the app is, and that is a
   bug, not a configuration problem.
2. macOS should ask for the microphone **at launch**, not on the first ⌥Space —
   the prompt was moved so that no async step sits on the push-to-talk path.
   Then hold **⌥Space**. Speak, release.
   Expect her to answer out loud, and the menu bar icon to walk through
   waveform → ellipsis → speech bubble → moon.
3. Watch the avatar: does she appear on both displays, below the desktop icons and
   above the wallpaper, with no opaque rectangle around her (that would mean the
   clip lost its alpha channel — re-encode with `tools/matte`).
4. Drag a window over her, then `log stream --predicate 'subsystem == "me.eltonzheng.akari"'`
   — the occluded display should stop decoding.
5. Lock the screen and unlock it. Both windows must survive and resume.
6. Close the lid / unplug a display and reconnect it. This is the
   `isReleasedWhenClosed` crash path; 28 stress rounds passed in RISK-2, but not
   with the real app.
7. `.stationary` retest (RISK-2 left this open): the 98% window scale it caused was
   measured on a locked machine and has to be re-checked unlocked before the flag
   can be ruled out for good.
8. Tap ⌥Space and let go immediately. She must go back to sleep, and the menu bar
   must say why ("按得太短了…") — not sit on the thinking icon.
9. Copy a password out of 1Password or Bitwarden, then ask her to read the clipboard.
   She must say the content was marked secret and skipped, and must not read it out.
10. Force-quit akari (Activity Monitor → Force Quit, i.e. SIGKILL) while it is running
   and `ps aux | grep akari-core`. Within ~5s no core should be left behind.

## Documents

| Document | Purpose |
| --- | --- |
| [`docs/spec.md`](./docs/spec.md) | The technical plan: architecture, stack, phased delivery, cost, risk |
| [`docs/protocol.md`](./docs/protocol.md) | The app ↔ core wire contract. Authoritative: change it first, then both mirrors in the same commit |
| [`docs/avatar-states.md`](./docs/avatar-states.md) | The state machine and the exact parameters each clip is produced with |
| [`docs/decisions.md`](./docs/decisions.md) | ADR log — every directional decision and why, including one reversal and one erratum |
| [`docs/research/2026-08-19-tech-survey.md`](./docs/research/2026-08-19-tech-survey.md) | Technology survey, 12 parallel agents, 3 adversarial verification passes |
| `docs/research/raw-findings.json` | 246 verified hard facts, 122 gotchas across 8 topics |
| `docs/research/verification.json` | The falsification passes that corrected the survey |

## License

Not yet decided.
