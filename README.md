# Bugsy

A bug catcher for **World of Warcraft: Forever** that turns Lua errors into problems you can
understand and reports an author can act on.

> **Status: in development.** Not released yet. The design and the plan are in [docs/](docs/).

## What it does

- **Catches** Lua errors, warnings and blocked actions, quietly: one chat line when a problem first
  shows up in a session, never a window in combat.
- **Groups** them into problems: how many times, first and last seen, the versions involved, and
  the different call paths that reached the same faulting line.
- **Says who seems involved, and how sure it is**: what WoW named, which addons are in the stack,
  and Bugsy's own reading, kept apart.
- **Prepares a report**: what you were doing, what happened, what you expected, a preview of
  everything included, where to report it when the addon says, and the text in Markdown or JSON to
  copy. Bugsy never sends anything anywhere.
- **Report a problem** that showed no error at all (an empty tab, a failed sync), with the context
  the addon's author chose to record.

## Using it

`/bugsy` (or the minimap's addon menu) opens the window. `/bugsy report` reports a problem with no
error. `/bugsy locals on` captures local variables with new errors (off by default: they can contain
names and messages). `/bugsy status` says how Bugsy is catching errors. A new problem plays a short
sound and prints one chat line (at most one every 10 s, held during combat). `/bugsy sound` lists
the six sounds and `/bugsy sound 1-6` picks one; `/bugsy sound off` and `/bugsy notices off` turn
them off.

Bugsy replaces your error collector and its viewer: use it instead of them. If another error
collector is still running (on its own or embedded in another addon), Bugsy reads errors from it
instead and says what that costs.

## Privacy

Everything stays on your computer. A report replaces your own character and realm names; it cannot
remove other players' names that an error message may contain, and the preview shows you everything
before you copy it.

## For developers

[docs/DESIGN.md](docs/DESIGN.md) is the architecture, [docs/REPORT-SCHEMA.md](docs/REPORT-SCHEMA.md)
the report format, [docs/LIBRARY.md](docs/LIBRARY.md) the planned author library, and
[docs/FOREVER-PROBE.md](docs/FOREVER-PROBE.md) what is verified and what is still to be measured
in game. Tests: `pwsh tests\run.ps1`.

MIT licensed.
