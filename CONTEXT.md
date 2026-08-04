# claude-traffic-light

Ubiquitous language for the traffic-light overlay that surfaces the status of my running
Claude Code sessions. Glossary only — no implementation details.

## Language

**Session**:
One running Claude Code instance, identified by its `session_id`. The unit whose status
we track.
_Avoid_: window, tab, terminal (those are where a Session happens to be shown).

**Session Title**:
The human-readable label for a Session, shown in the Sessions Menu. Sourced from the
title Claude Code generates for the conversation; falls back to the Session's working
directory name when unavailable. Identifies a Session to me — the `session_id` is not
readable.
_Avoid_: name, summary (summary implies the whole conversation, not a label).

**Status**:
The current state of a single Session. Exactly one of: Blocked, Your Turn, Working, Idle.

**Blocked**:
A Session is waiting on a permission/approval prompt and cannot proceed without me. The
most urgent Status.
_Avoid_: waiting, paused, stuck.

**Your Turn**:
A Session has finished its response and is awaiting my next message. Needs me, but not
urgently.
_Avoid_: done, finished, ready (ambiguous about whose move it is).

**Working**:
A Session is actively running — thinking, executing tools, or waiting on background work
(a background task or scheduled wakeup) that will resume it without me. In progress; does
not need me.
_Avoid_: busy, running, thinking (pick one canonical term).

**Idle**:
A Session is open but dormant — not Working, not Blocked, and not currently demanding a
reply (e.g. freshly started, or long-settled). Contributes nothing to the Light.
_Avoid_: inactive, asleep.

**Aggregate Status**:
The single Status chosen across all live Sessions to drive the Light, by worst-wins
urgency: Blocked > Your Turn > Working > Idle. Muted Sessions are excluded from this
computation while their Mute holds.

**Mute** (verb):
To exclude a Session from the Aggregate Status until its Status changes. State-scoped, not
time-scoped: a Mute is bound to the Status the Session held when muted, and clears the
instant the Session's Status differs from it (a later return to that same Status is a fresh
Status and nags again). Lets me set aside a Session I've seen — e.g. one that's Your Turn I
don't want to reply to yet — without quitting it or losing its next transition.
_Avoid_: snooze (implies a timer), dismiss/ignore (imply permanence), acknowledge.

**Muted Session**:
A Session whose Status currently matches its Mute, so it does not contribute to the
Aggregate Status. Still tracked, still listed in the Sessions Menu (shown struck-through);
it simply doesn't drive the Light until its Status changes.

**Sessions Menu**:
The Overlay's right-click menu listing every live Session with its current Status and Title,
from which a Session can be Muted or un-Muted. Headless (non-window) Sessions are omitted.

**The Light**:
The on-screen indicator: three stacked lamps drawn like a real traffic light. The lamp for
the current Aggregate Status is lit; the others stay dim (all dim when nothing is lit).
_Avoid_: widget, icon, indicator, dot.

**Duplicate Light**:
An additional Light on screen. Every Light shows the same Aggregate Status — Status belongs to
the Sessions, not to any one Light — but each carries its own position and Lamp Diameter, so one
can sit on each display, or several on one. There is always at least one; closing the last is
not offered.
_Avoid_: copy, clone, window, instance.

**Lamp Diameter**:
The size of one lamp, and the only dimension of the Light I can change. Everything else —
padding, corner rounding, glow — is proportional to it, so resizing is a uniform scale: the
Light looks the same at every size, only bigger or smaller. Remembered across launches.
_Avoid_: zoom, window size (the window size follows from the Lamp Diameter).

**Reporter**:
The command Claude Code invokes on each hook event to write a Session's current Status.

**Overlay**:
The always-on-top desktop window that renders the Light and watches for Status changes.
