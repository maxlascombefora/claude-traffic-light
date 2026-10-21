# Orphaned Sessions: hide by Ghostty tty, never by cwd

Ghostty can close a tab while the `claude` process in it keeps running. The process is still
alive (with the same start time), so `isLive` ([ADR 0003](./0003-hook-driven-detection.md))
keeps the Session, and it stays in the Sessions Menu and can drive the Light. Nothing can show
that Session to me, so it is an **Orphaned Session**. Verified on a real machine: Ghostty 1.3.1
still held the tab's pty through `/usr/bin/login`, the `claude` process and its MCP child were
alive, and Ghostty's AppleScript listed no terminal for it.

The overlay hides an Orphaned Session when **its process runs under Ghostty, and its tty is
not the tty of any open Ghostty terminal**. It only hides. It does not delete the session file
or stop the process; `pruneDead` removes the file when the process exits.

## Match key: tty, which Ghostty doesn't ship yet

The Session's tty comes from its pid (`kinfo_proc.e_tdev`), so the Reporter needs no change.
The open terminals' ttys come from Ghostty's AppleScript `tty` property on `terminal`. That
property is on GitHub `main` (`macos/Ghostty.sdef`, code `Gtty`, value like `/dev/ttys016`) but
**not in 1.3.1**, the release installed when this was written. Until a release ships it, this
feature does nothing.

The overlay reads `Ghostty.app/Contents/Resources/Ghostty.sdef` before it sends any Apple Event,
and skips the query when `Gtty` is missing. So an older Ghostty never shows the Automation
permission prompt for a query that can't work.

## Rejected: match by working directory

Ghostty 1.3.1 already exposes `working directory`, and click-to-focus uses it
([ADR 0005](./0005-click-to-focus-ghostty.md)). It is not safe here. The hook records Claude's
current directory, but Ghostty reports the shell's directory. They differ whenever Claude moves
into a `.claude/worktrees/...` checkout, which is common. A cwd match would then hide a live
Session that may need me. For focus, a wrong cwd match does nothing; here it hides a Session.

## Every doubt keeps the Session

Hiding a live Session is worse than showing a closed one, so `dropOrphans` keeps a Session
when:

- there is no snapshot (Ghostty not running, no `tty` property, script failed, permission
  denied);
- the record has no pid or no `pidStart`;
- the process started at or after the snapshot (its terminal may not be in the list yet);
- the process does not descend from `ghostty` (another terminal app, VS Code, etc.);
- its tty can't be read.

## Cost

One Apple Event every ~5s, on a background queue, with the title warm
([ADR 0004](./0004-session-titles-from-transcript.md)). *Refresh Sessions* runs one at once.
The per-Session checks in the 1s poll are a few `sysctl` reads.

## Update 2026-10-21: the Claude Code daemon pty, and one record per terminal

Claude Code 2.1.306 runs a Session through a daemon. The `claude` process in the terminal
window (tty `/dev/ttys001`) spawns `claude daemon run` (no tty), which spawns
`claude bg-pty-host` (no tty), which spawns `claude bg-spare` on `/dev/ttys002`, a pty the
daemon created. After a session restart the hooks run inside that spare process, so the record
carries its pid and its tty. Ghostty lists only the window's tty, never the daemon's pty. The
old rule compared the process's own tty with the snapshot and dropped the live Session as an
Orphaned Session.

The match key is now the **terminal tty of the process chain**: `terminalTTY` walks from the
record's pid up the parent chain (hop cap 32, stop at launchd) and returns the first tty that an
open Ghostty terminal has. `dropOrphans` keeps a Session when that walk finds a tty. A real
orphan still drops: after Ghostty closes the tab, no process in the chain sits on an open
terminal. Every doubt in the list above still keeps the Session; "its tty can't be read" means
the process's own tty.

The same restart leaves a second problem. The window process keeps its pre-restart record,
stuck on the last Status it reported, because every later hook reports under the new session
id. That stale record then drives the Light. `collapseSameTerminal` groups the live records by
their terminal tty and keeps only the record with the newest `updated_at` per terminal. The
newest record on a terminal is the Session the user sees in that window. Records with no
resolvable terminal pass through untouched. The overlay runs it right after `dropOrphans`,
before Mutes. The Reporter stays stateless ([ADR 0003](./0003-hook-driven-detection.md)).
