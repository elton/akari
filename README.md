# akari · 明かり

A desktop-resident AI companion for macOS — an animated character that lives on your
desktop, talks with you by voice or text, reads things aloud, and acts as a personal
agent that can actually operate your Mac.

Powered by Qwen.

> Status: **design complete, implementation not started.**

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

## Documents

| Document | Purpose |
| --- | --- |
| [`docs/spec.md`](./docs/spec.md) | The technical plan: architecture, stack, phased delivery, cost, risk |
| [`docs/decisions.md`](./docs/decisions.md) | ADR log — every directional decision and why, including one reversal and one erratum |
| [`docs/research/2026-08-19-tech-survey.md`](./docs/research/2026-08-19-tech-survey.md) | Technology survey, 12 parallel agents, 3 adversarial verification passes |
| `docs/research/raw-findings.json` | 246 verified hard facts, 122 gotchas across 8 topics |
| `docs/research/verification.json` | The falsification passes that corrected the survey |

## License

Not yet decided.
