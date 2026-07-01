# Session detection: Claude Code hooks, latest-event-wins, liveness-pruned

Session Status is derived entirely from **Claude Code hooks**. Each session's `settings.json`
routes events to the Reporter, which writes that session's current Status (latest event wins).
The Overlay watches the sessions directory and aggregates.

## Event → Status routing

| Hook (matcher)                         | Status written |
|----------------------------------------|----------------|
| `SessionStart`                         | Idle           |
| `UserPromptSubmit` / `PreToolUse`      | Working        |
| `PostToolUse`                          | Working        |
| `Notification` (`permission_prompt`)   | Blocked        |
| `Notification` (`idle_prompt`) / `Stop`| Your Turn      |
| `SessionEnd`                           | remove file    |

The `Notification` event exposes a `notification_type` matcher (`permission_prompt`,
`idle_prompt`, …), so settings.json routes each type to the right Status with no message-text
parsing. The Reporter takes the Status as an argument and reads only `session_id` (plus a
timestamp and the Claude pid) from the hook JSON on stdin.

## Known gaps we deliberately design around

1. **No "permission answered" event.** Blocked is entered on `permission_prompt` but there is
   no hook when the prompt is answered/dismissed. Blocked is simply overwritten by the next
   event — the tool runs (`PostToolUse` → Working) or the turn ends (`Stop` → Your Turn).
2. **No idle signal.** There is no hook for a session going dormant. A finished session stays
   **Your Turn** until the next prompt or `SessionEnd` (chosen policy: *persist until closed* —
   no time-based demotion; yellow is truthful).
3. **`SessionEnd` can be missed** on crash/SIGKILL, so a dead session could linger — including
   a **stuck red**.

## Staleness pruning

Because a live session that is waiting on the user emits no hooks, inactivity cannot
distinguish "alive & waiting" from "dead." So pruning is by **process liveness**: the Reporter
records the Claude process id; the Overlay prunes a session when `kill(pid, 0)` shows the
process is gone. **Backstop:** for sessions where a plausible pid can't be resolved, fall back
to a long inactivity TTL (~12h). This never false-prunes a live waiter and reliably clears
stuck reds.

Resolving the pid is fiddly: Claude runs the hook via a short-lived shell, so the Reporter must
climb to its grandparent process (via `sysctl`/`ps`) and sanity-check it looks like Claude
before trusting it; otherwise it records no pid and the TTL backstop takes over.
