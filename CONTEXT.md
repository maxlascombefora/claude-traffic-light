# claude-traffic-light

Ubiquitous language for the traffic-light overlay that surfaces the status of my running
Claude Code sessions. Glossary only — no implementation details.

## Language

**Session**:
One running Claude Code instance, identified by its `session_id`. The unit whose status
we track.
_Avoid_: window, tab, terminal (those are where a Session happens to be shown).

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
A Session is actively running — thinking or executing tools. In progress; does not need me.
_Avoid_: busy, running, thinking (pick one canonical term).

**Idle**:
A Session is open but dormant — not Working, not Blocked, and not currently demanding a
reply (e.g. freshly started, or long-settled). Contributes nothing to the Light.
_Avoid_: inactive, asleep.

**Aggregate Status**:
The single Status chosen across all live Sessions to drive the Light, by worst-wins
urgency: Blocked > Your Turn > Working > Idle.

**The Light**:
The on-screen indicator: three stacked lamps drawn like a real traffic light. The lamp for
the current Aggregate Status is lit; the others stay dim (all dim when nothing is lit).
_Avoid_: widget, icon, indicator, dot.

**Reporter**:
The command Claude Code invokes on each hook event to write a Session's current Status.

**Overlay**:
The always-on-top desktop window that renders the Light and watches for Status changes.
