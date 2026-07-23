# Session Titles read from Claude Code's transcript (a scoped exception to hook-only)

The Sessions Menu labels each Session with a **Session Title** read from Claude Code's own
conversation transcript — the `aiTitle` field in `~/.claude/projects/<munged-cwd>/<session_id>.jsonl`
— falling back to the Session's working-directory basename, then a `session_id` suffix, when
the title is missing or unreadable.

This **deliberately carves an exception into [ADR 0003](./0003-hook-driven-detection.md)**,
which states the Status source is hooks only: *"no scraping terminals, no polling Claude
internals."* The transcript is an undocumented, unstable format; Claude Code could rename
`aiTitle`, relocate the file, or change the cwd→dirname munging in any release and silently
break our labels.

We accept it because a `session_id` UUID is unusable as a human label and the cwd basename is
weak (collides when two Sessions share a repo), while `aiTitle` is a genuinely good summary.
The coupling is contained:

- **Labels only, never Status.** The Light stays 100% hook-driven. The transcript is read
  solely to name rows in the Sessions Menu; a parse failure degrades to the cwd basename and
  the Light is unaffected.
- **Read off the main thread, into a cache.** Transcripts can be large, so reads run on a
  background queue and the Sessions Menu serves labels from an in-memory cache — it never
  blocks the right-click on disk. The cache is warmed at launch and on a slow cadence (~5s),
  well below the 1s status poll, so there is no per-frame cost. A not-yet-cached Session shows
  its cwd basename immediately and upgrades on the next open.
- **Located by glob** (`~/.claude/projects/*/<session_id>.jsonl`) rather than reverse-engineering
  the cwd→dirname munging, which is the most fragile part of the scheme.

**Surprising, so recorded:** ADR 0003 forbids reading Claude internals; this permits it for
one narrow, non-load-bearing purpose (a display label) with a hard fallback. Rejected
alternatives: cwd basename only (stays strict, but poor labels and same-repo collisions);
`last-prompt` instead of `aiTitle` (more "live" but noisier and just as coupled). The line we
hold: **the moment this coupling would affect Status or the Light, it is out of bounds** —
Status remains hook-only.
