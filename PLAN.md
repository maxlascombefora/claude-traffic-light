# claude-traffic-light — Plan

## Problem

I run multiple Claude Code sessions at once, often with the terminal windows hidden or
on another display. I can't tell at a glance whether a session is busy working, blocked
waiting for my input/permission, or done. I want a single always-visible on-screen
indicator — a traffic light — that tells me the aggregate status of all my live Claude
sessions so I know when to go look at a window.

## Core idea

Claude Code fires **hooks** at lifecycle events (session start/end, prompt submitted,
tool about to run, notification/permission, turn finished). We install a tiny hook
command that, on each event, writes the current session's status to a small JSON file in
a shared directory. A lightweight desktop **overlay** watches that directory, aggregates
every session's status into one color, and renders a red/yellow/green traffic light that
floats on top of everything.

```
Claude Code session ──hook──▶ ~/.claude-traffic-light/sessions/<session_id>.json
Claude Code session ──hook──▶ ~/.claude-traffic-light/sessions/<session_id>.json
                                          │  (file watch)
                                          ▼
                             Overlay app  ──aggregate──▶  🔴 / 🟡 / 🟢
```

No polling of Claude internals, no scraping terminals — hooks are the supported,
event-driven source of truth.

## Components

1. **Hook reporter** — a single small script (Node or shell) invoked by Claude Code
   hooks. Reads the hook JSON from stdin (`session_id`, `cwd`, `hook_event_name`,
   `transcript_path`), maps the event to a status, and writes
   `~/.claude-traffic-light/sessions/<session_id>.json`:
   `{ session_id, cwd, status, updated_at, pid? }`.

2. **Installer** — writes the hook entries into `~/.claude/settings.json` (merging, not
   clobbering) so every Claude Code session reports automatically. Also an uninstaller.

3. **Overlay app** — always-on-top, frameless, transparent floating window showing the
   three lights. Watches the sessions dir, aggregates, re-renders. Draggable; remembers
   position. Quit/settings via a tray/menu-bar item or right-click.

4. **Aggregator** — pure logic: read all session files, drop stale ones, compute the one
   winning color by priority.

## Event → status mapping (hook reporter)

| Claude Code hook     | Status written        |
|----------------------|-----------------------|
| `SessionStart`       | `idle`                |
| `UserPromptSubmit`   | `working`             |
| `PreToolUse`         | `working`             |
| `Notification`       | `needs_input`         |
| `Stop`               | `needs_input` *(your turn — finished its response)* |
| `SessionEnd`         | remove file           |

## Color semantics (RECOMMENDED — first thing to grill)

Attention model — the more alarming the color, the more it wants me:

- 🔴 **Red** — at least one session **needs me**: blocked on a permission/approval prompt,
  or finished its turn and waiting for my reply. → go to that window.
- 🟡 **Yellow** — at least one session is **actively working** (and none need me). → wait.
- 🟢 **Green** — nothing needs me and nothing is running (all idle/ended, or none open). → relax.

**Aggregation:** worst-wins priority `needs_input (red) > working (yellow) > idle (green)`
across all live sessions.

## Open design decisions (the grilling agenda)

1. **Color meaning.** Is the attention model above right, or do you want "green = go/running,
   red = stopped/blocked" (the literal traffic-light metaphor)? Should "finished, awaiting
   reply" be the same red as "blocked on permission," or a distinct state/color?
2. **Overlay vs menu bar.** A floating traffic-light window (as asked) vs a colored dot in
   the macOS menu bar (more native, never occludes content). Or both.
3. **Single light vs per-session detail.** One aggregate light only, or also a way to see
   which/how many sessions are in each state (count badge, hover, click-to-expand list with
   cwd names)?
4. **Tech stack.** Electron (fastest, familiar web stack, heavy) vs Tauri (tiny, needs Rust)
   vs native Swift menu-bar app (tiniest/most native, Swift) vs Python menu-bar (rumps).
5. **Staleness / crash handling.** A session that crashes never fires `SessionEnd`. TTL on
   session files? Heartbeat? Check the pid is alive?
6. **Scope of "sessions."** All Claude Code sessions on this machine, or filter to specific
   projects/cwds? Only this user, only local (not SSH)?
7. **Interaction.** Draggable? Click-through when idle? Click a light to focus/raise the
   relevant terminal window (hard — needs window management)? Sound/flash on red?
8. **Reporter language & footprint.** Shell script vs Node. Startup cost matters — the hook
   runs on every tool call.
9. **Distribution.** Just runs on my Mac from source (npm start / launchd), or packaged
   `.app` + login-item autostart?
10. **Multi-display / spaces.** Which display does it live on; should it show on all Spaces?

## Rough milestones

- **M1 — spike the signal.** Hook reporter + installer; confirm the JSON files change state
  correctly as a real session runs. `tail`/log the aggregate color. No UI yet.
- **M2 — the light.** Minimal always-on-top overlay reading the aggregate, three lights.
- **M3 — robustness.** Staleness/crash handling, multi-session correctness, position memory.
- **M4 — polish.** Per-session detail, tray menu, autostart, packaging.

## Non-goals (initial)

- Not a Claude Code TUI replacement or a session manager — display only.
- Not cross-machine / not a hosted service — one Mac, local files.
- No history/analytics — current status only.
