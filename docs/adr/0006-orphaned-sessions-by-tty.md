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
