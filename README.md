# claude-traffic-light

An always-on-top macOS overlay — a three-lamp traffic light — showing the aggregate status
of my running Claude Code sessions at a glance, so I know when a window needs me without
watching it.

| Lamp | Status | Meaning |
|------|--------|---------|
| 🔴 | Blocked | A session is waiting on a permission/approval prompt (urgent) |
| 🟡 | Your Turn | A session finished its response and is awaiting my next message |
| 🟢 | Working | A session is actively running |
| dim | Idle / none | Nothing needs me and nothing is running |

One lamp lights at a time — the highest-urgency status across all sessions
(`Blocked > Your Turn > Working`). Design rationale is in [PLAN.md](./PLAN.md),
[CONTEXT.md](./CONTEXT.md), and [docs/adr/](./docs/adr/).

## How it works

Claude Code **hooks** run a tiny `reporter` on each session event, which writes that session's
status to `~/.claude-traffic-light/sessions/<session_id>.json`. The **overlay** watches that
directory (1s poll), prunes dead sessions (process-liveness, with a 12h TTL backstop), and
lights the lamp for the aggregate status.

Only **real terminal windows** drive the Light: the reporter records whether the owning process
has a controlling terminal, and headless automation (`claude -p`, e.g. background agents) is
ignored so it never pins the Light while you work in a window.

When Ghostty closes a tab but the `claude` process in it keeps running, the overlay hides that
**Orphaned Session**: it compares each Session's tty with the ttys of the open Ghostty
terminals. This needs a Ghostty release after 1.3.1 (the AppleScript `tty` property). On older
Ghostty it does nothing. See [ADR 0006](./docs/adr/0006-orphaned-sessions-by-tty.md).

## Requirements

macOS + a Swift toolchain. Xcode Command Line Tools is enough (`xcode-select --install`);
full Xcode is not required.

## Run

**One command (build + hooks + overlay):**

```sh
scripts/run.sh              # quit leaves hooks installed (other windows keep reporting)
scripts/run.sh --teardown   # throwaway run: also uninstall hooks + clear state on quit
```

Builds the release binaries, installs the hooks (idempotent), and launches the overlay in the
foreground. On quit (right-click → *Quit*, or Ctrl-C) the overlay stops. By default the hooks
are **left installed** — they're global and harmless, and removing them would stop reporting
for your other Claude windows and freeze the Light on a stale color. Use `--teardown` for a
throwaway run that fully cleans up, or `reporter uninstall` to remove hooks explicitly. For a
persistent install that survives reboots, use the manual steps below and package the `.app`.

### Manual steps

If you'd rather run the steps individually:

**1. Build the binaries:**

```sh
swift build -c release
```

This produces `TrafficLight` (the overlay app) and `reporter` (the hook CLI + installer).

**2. Wire up the hooks** (edits `~/.claude/settings.json`):

```sh
swift run reporter install
```

This backs up your existing `settings.json` to `settings.json.ctl-backup`, merges in seven
hook entries (non-destructively — your other hooks/keys are preserved), and stages a copy of
the binary at `~/.claude-traffic-light/bin/reporter` that the hooks point at. It's idempotent
(safe to re-run). The hooks are `async` fire-and-forget and always exit 0, so they never delay
or block a tool call. `PreToolUse` is deliberately not hooked.

To remove them:

```sh
swift run reporter uninstall
```

**3. Launch the overlay.** Either package it as a real app (recommended) or run from source:

```sh
scripts/build-app.sh     # builds "Claude Traffic Light.app" → ~/Applications, indexed by Spotlight
# then launch from Spotlight: type "Claude Traffic Light"

swift run TrafficLight    # …or just run it from source (for development)
```

- No Dock icon or menu-bar item — just the floating light, on all Spaces.
- **Drag** it to reposition (position is remembered).
- **Resize** by dragging any corner, or via right-click → *Size*. Everything scales together, so
  it looks the same at any size; the corner opposite the one you drag stays put. Size is
  remembered. (No hover cursor: macOS gives cursor control to the active app, and the overlay
  never activates — that's what keeps clicking it from stealing your terminal's focus.)
- **Duplicate** from the right-click menu to put a light on another screen (or a second one on
  the same screen). With multiple displays, *Duplicate Light* becomes a per-screen submenu so the
  copy lands there directly. Each light keeps its own position and size; they all show the same
  status. *Close This Light* removes one — the last one can't be closed.
- **Right-click** for the session list (click a row to mute/un-mute), *Size* presets,
  *Reset Position*, *Duplicate Light*, *Close This Light*, and *Quit*.

Open Claude Code sessions and the light tracks them. Launch is manual by design — leave the
app open; there's no auto-start. To update the app after pulling changes, re-run
`scripts/build-app.sh`.

## Verify

```sh
swift run ctl-selftest                 # core aggregation/pruning self-test
echo '{"session_id":"x"}' | swift run reporter aggregate   # print current aggregate
```

## Environment overrides

- `CLAUDE_TRAFFIC_LIGHT_HOME` — state dir (default `~/.claude-traffic-light`)
- `CLAUDE_TRAFFIC_LIGHT_SETTINGS` — settings file the installer edits (default `~/.claude/settings.json`)

Handy for trying it against throwaway state without touching your real setup.

## Known limitations (by design)

- Claude Code has no "idle" hook, so a finished session stays **Your Turn (yellow)** until you
  prompt it again or close it (*persist until closed*).
- A crash that skips `SessionEnd` is cleared by process-liveness pruning (or the 12h TTL when a
  pid couldn't be resolved).
- Single aggregate color only — no per-session breakdown, no red escalation (sound/pulse).
  All are easy to add later.
