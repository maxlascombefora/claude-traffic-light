# Click-to-focus: jump to the oldest matching Session, via Ghostty AppleScript (Ghostty-only)

Clicking a Light (a plain click, not a drag) finds the **oldest live, unmuted Session whose
Status matches the Light's current aggregate color**, and brings its terminal window to the
front. Clicking again — after that Session is dealt with and its Status changes — advances to
the next-oldest Session in that same color, for free: no state to track beyond what's already
there. This applies uniformly to every color, including Working and Idle ("which one's running?
click and see") — there is no color-conditional carve-out.

**Scope: Ghostty only, v1.** No Terminal.app/iTerm2/tmux/VS Code support. The mechanism below is
specific to Ghostty's scripting dictionary; other terminals would need an entirely different
mechanism (tmux in particular has no OS-level "window" to focus at all) and are deferred until
there's a reason to support them.

## Mechanism: match by cwd, disambiguate by title, focus via AppleScript

Ghostty ≥ 1.3 exposes a `terminal` class over AppleScript with a `focus` command. GitHub's `main`
branch sdef (`macos/Ghostty.sdef`) additionally shows `pid` and `tty` properties on that class —
which would have been an ideal, unambiguous match key against the pid the Reporter already
resolves (`resolveClaudeProcess()`, [ADR 0003](./0003-hook-driven-detection.md)). **They aren't
actually shipped yet.** Pulling the sdef out of the installed app itself
(`Ghostty.app/Contents/Resources/Ghostty.sdef`, the source AppleScript actually compiles against —
`main` on GitHub is ahead of the release) shows `terminal` currently has only `id`, `name` (title),
and `working directory`. Trusting the repo instead of the shipped binary would have shipped a
silently-broken feature; this was only caught by testing against the real app.

That leaves `working directory` as the only usable correlator, which is exactly the `cwd` the
Reporter already captures — still no new data needed — but a `cwd`, unlike a pid, **is not
unique**: verified live, two terminals already shared one cwd on a real machine (this project's
own directory, one tab mid-session, one running a shell script). Picking `item 1` of an ambiguous
match risks focusing an unrelated tab that happens to share the directory — worse than doing
nothing.

The disambiguator: Claude Code sets its own terminal title to its Session Title, the same
`aiTitle` text the Sessions Menu already reads from the transcript and caches
([ADR 0004](./0004-session-titles-from-transcript.md)) — confirmed live (`name` of the terminal
was `"⠐ Add click-to-open Claude tab from traffic light"`, a spinner glyph plus exactly the
transcript's `aiTitle`). So: enumerate `terminals`, filter to `working directory` = the Session's
`cwd`; if that's exactly one, focus it; if more than one, narrow to the one whose `name` contains
the cached Session Title; if it's still not exactly one, do nothing. No new data source — this
reuses the title cache `AppDelegate` already warms for the menu.

**Should Ghostty ship `pid`/`tty`** in a future release, matching should move to pid — it fully
removes this ambiguity class instead of mitigating it. Until then, this is a best-effort narrowing,
not a guarantee.

The AppleScript surface overall is a **preview feature** per Ghostty's own 1.3 release notes,
which warn of breaking changes in 1.4. We accept that risk: focus is best-effort UI sugar, never
load-bearing for Status, and a version bump that breaks the sdef degrades to a silent no-op (see
Failure mode below), not a malfunction.

## Selection: oldest by `changed_at`, filtered to focusable and unmuted

`SessionRecord.updatedAt` is touched on *every* hook event, including repeated same-status events
(`PostToolUse` fires on every tool call while Working) — so it can't answer "how long has this
Session been in its current Status." The Reporter now reads the existing record before writing,
and sets a new `changed_at` only when `status` actually differs from the previous value, carrying
it forward otherwise. Candidates for a click are filtered before picking the oldest `changed_at`:

- **A non-empty `cwd`.** A Session with no recorded cwd can never be matched to a Ghostty terminal.
  If selection picked by age alone, an unfocusable Session would permanently block the queue —
  every click would keep re-selecting it instead of reaching focusable Sessions of the same color
  sitting right behind it.
- **Unmuted, using the post-Mute `contributing` set** (`AppDelegate.refresh()`), not the raw
  `liveRecords`. The aggregate color is already computed post-Mute; searching the raw set for the
  click target would let a muted Session still get jumped to whenever another, unmuted Session
  happened to share its color — defeating the reason it was muted in the first place. Mute means
  "leave me alone about this one," consistently, everywhere — not just in the color shown.

## Click vs. drag, and failure mode

`LampView`'s `mouseDown`/`mouseDragged`/`mouseUp` didn't previously distinguish a click from a
drag — `mouseUp` always just persisted position. It now does: total movement under a small
threshold (~3-4pt, absorbing hand tremor without misreading an intentional drag) fires the focus
action instead of a move.

The AppleScript call runs off the main thread — an Apple Event can block for a while, and the
*first* one blocks on the OS's own "TrafficLight wants to control Ghostty" permission dialog, which
would otherwise freeze every Light (one process, one run loop) until answered. Any failure —
no match, Ghostty not running, an older Ghostty without this sdef, permission denied, a changed
1.4 API — is swallowed silently. This matches the Reporter's own standing rule: never disrupt the
session, never surface an error dialog for best-effort behavior.

## The Sessions Menu gains Focus per row

Each row in the right-click Sessions Menu becomes a submenu with two items, **Focus** and
**Mute**, replacing the single click-to-mute row. This reuses the existing submenu pattern already
in this menu (*Size*, *Duplicate Light*) rather than introducing a custom NSMenuItem view or an
Option-key alternate-item trick — both considered and rejected as more complexity than a small
utility menu warrants.

## Surprising, so recorded

`CONTEXT.md` says explicitly not to treat Session as a synonym for "window, tab, terminal" — the
glossary is deliberately terminal-agnostic. This feature crosses that line on purpose: a Session
now has an externally-focusable terminal identity, for exactly one terminal app. We accept it
because the coupling is narrow and additive — Status stays 100% hook-driven and terminal-agnostic
(ADR 0003 is untouched), matching/focusing is purely a UI action layered on top, and it degrades
to doing nothing (not to a wrong or misleading Status) if Ghostty is absent, unsupported, or
changes its API. The line we hold: **the moment this coupling would affect Status or the Light's
color, it is out of bounds** — same boundary ADR 0004 draws around Session Titles.

Rejected alternatives: matching by pid (preferred in principle — unique, no ambiguity — but not
available in the shipped Ghostty AppleScript API; revisit if that changes); guessing `item 1` on
an ambiguous cwd match instead of narrowing by title or giving up (rejected — a wrong guess lands
on an unrelated tab, which is worse and more confusing than doing nothing); scoping click-to-focus
to only the "needs you" colors, red/yellow (rejected — uniform behavior across every color is
simpler and was the explicit ask: "we do have a thing running, which one is it? click and see").
