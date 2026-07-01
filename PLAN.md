# claude-traffic-light — Plan

## Problem

I run multiple Claude Code sessions at once, often with the terminal windows hidden or on
another display. I can't tell at a glance whether a session is busy working, waiting on me,
or blocked on a permission prompt. I want a single always-visible on-screen traffic light
that shows the aggregate status of all my live Claude sessions so I know when to go look at a
window.

Glossary of terms (Session, Status, Blocked/Your Turn/Working/Idle, Aggregate Status, Light,
Reporter, Overlay) lives in [CONTEXT.md](./CONTEXT.md). Decisions are recorded in
[docs/adr/](./docs/adr/).

## Architecture

```
Claude Code session ──hook──▶ reporter <status> ──▶ ~/.claude-traffic-light/sessions/<session_id>.json
Claude Code session ──hook──▶ reporter <status> ──▶ ~/.claude-traffic-light/sessions/<session_id>.json
                                                              │  (FSEvents watch + periodic sweep)
                                                              ▼
                                                   Overlay (aggregate + prune) ──▶  🔴 / 🟡 / 🟢
```

Hooks are the supported, event-driven source of truth — no scraping terminals, no polling
Claude internals. The Reporter is stateless: each hook just writes the session's current
Status (latest event wins). The Overlay reads every session file, prunes dead sessions, and
lights the lamp for the worst-wins Aggregate Status.

## Status model (decided)

Per [ADR 0001](./docs/adr/0001-color-model.md) — the **split** model:

| Status      | Lamp        | Meaning                                             |
|-------------|-------------|-----------------------------------------------------|
| Blocked     | 🔴 red      | Waiting on a permission/approval prompt (urgent)    |
| Your Turn   | 🟡 yellow   | Finished its response, awaiting my next message     |
| Working     | 🟢 green    | Actively running (thinking / executing tools)       |
| Idle / none | all dim     | Freshly started with no prompt yet, or no sessions  |

- **Aggregate:** worst-wins priority `Blocked > Your Turn > Working > Idle`. One lamp lit.
- **Single color only** — no counts, no per-session list. (Masking the lower states is
  accepted; it's a glanceable indicator.)
- **Static** — no pulse, no sound, no notification on red. Solid color change only.
- **Persist until closed** — a finished session stays Your Turn (yellow) until the next
  prompt or `SessionEnd`; no time-based demotion. Yellow is truthful.

## Detection (decided)

Per [ADR 0003](./docs/adr/0003-hook-driven-detection.md). Event → Status routing, via
matchers in `~/.claude/settings.json`:

| Hook (matcher)                          | Status         |
|-----------------------------------------|----------------|
| `SessionStart`                          | Idle           |
| `UserPromptSubmit` / `PreToolUse` / `PostToolUse` | Working |
| `Notification` (`permission_prompt`)    | Blocked        |
| `Notification` (`idle_prompt`) / `Stop` | Your Turn      |
| `SessionEnd`                            | remove file    |

Known gaps we design around: no "permission answered" event (Blocked is overwritten by the
next event); no idle hook (hence persist-until-closed); `SessionEnd` can be missed on a crash.

**Staleness pruning:** liveness first — the Reporter records the Claude process id and the
Overlay prunes when `kill(pid, 0)` shows it's gone. Backstop — a ~12h inactivity TTL only for
sessions where a plausible pid couldn't be resolved. Never false-prunes a live waiter; clears
stuck reds.

## Components

1. **Reporter** — a small Swift CLI (`reporter <status>`), same SwiftPM package as the app.
   Invoked by every hook. Reads `session_id` + records the Claude pid (grandparent of the
   hook process, sanity-checked) + a timestamp from the hook JSON on stdin; writes/removes
   `~/.claude-traffic-light/sessions/<session_id>.json`. Compiled → ~5–10ms cold start.

2. **Installer** — writes the hook entries into `~/.claude/settings.json` (merge,
   non-destructive) so every session reports, plus an uninstaller that removes them. Likely a
   `reporter install` / `reporter uninstall` subcommand.

3. **Overlay** — native Swift/SwiftUI app. Borderless, non-activating, always-on-top floating
   panel; `LSUIElement` (no Dock icon, no menu-bar item). Renders the three-lamp traffic
   light. Draggable and remembers its position; joins all Spaces. Right-click menu: Quit,
   Reset position. Watches the sessions dir (FSEvents/DispatchSource) and runs a periodic
   sweep (~5–10s) for liveness/TTL pruning. **Manual launch** (build the `.app`, open it).

4. **Aggregator** — pure logic shared by the Overlay: read session files, prune dead ones,
   compute the worst-wins Aggregate Status, map to the lit lamp.

## Scope

All Claude Code sessions for this user on this Mac (global hooks in `~/.claude/settings.json`).
No per-project filtering — the point is to see everything at once. Local only; not
cross-machine.

## Milestones

- **M1 — signal.** Reporter + Installer. Verify the per-session JSON files transition through
  Blocked / Working / Your Turn / Idle correctly as a real session runs; log the computed
  Aggregate Status to stdout. No UI yet.
- **M2 — the light.** Minimal always-on-top three-lamp panel reading the aggregate. Draggable
  + position memory.
- **M3 — robustness.** Liveness + TTL pruning, multi-session correctness, non-activating /
  all-Spaces polish, right-click menu.
- **M4 — packaging.** `.app` build + install/README docs.

## Non-goals (initial)

- Not a Claude Code TUI replacement or session manager — display only.
- Not cross-machine / not a hosted service — one Mac, local files.
- No history/analytics — current status only.
- No auto-start, no counts/per-session list, no red escalation (pulse/sound/notification).
  All are easy to add later if wanted.

## Deferred micro-decisions (sensible defaults, easily changed)

Exact lamp colors/size, window default position, sweep interval, the status-dir path, and
whether the installer is a CLI subcommand vs a shell script — settle these during M1/M2.
