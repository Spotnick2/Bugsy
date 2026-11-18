# Changelog

## v0.1.0

The first release: Bugsy replaces your error collector and its viewer.

- **Catches** Lua errors, warnings and blocked actions from the moment it loads, quietly: one chat
  line and a short sound when a new problem shows up (at most one every 10 s, held during combat).
  It never opens a window by itself.
- **Groups** them into problems: how many times, first and last seen, the versions involved, the
  different call paths that reached the same line.
- **Shows which addon appears involved**, with its icon, and how sure Bugsy is ("cause
  unconfirmed"), keeping what WoW named, the addons in the stack and Bugsy's own reading apart.
- **After a patch day**, an addon made for an older version of the game is marked out of date,
  with a suggestion to turn it off in the AddOns list until it's updated. Bugsy never turns
  anything off itself.
- **Copy for a bug report**: the diagnostics ready to paste, in Markdown for a GitHub issue, as a
  short text for a CurseForge comment, or as JSON. Your character and realm names are replaced.
  Nothing is ever sent anywhere.
- **Prepare report** and **Report a problem** (one that showed no error): a guided report in three
  steps, Describe, Review and Copy, with a searchable addon picker.
- **Search**, This session and History, mute and clear; a "monitoring" status that says when
  capture is interrupted or limited.
- Blizzard's popup for a blocked action, its "Interface action failed" message and its Lua
  warning window are hidden: Bugsy records them instead (`/bugsy popups show` brings them back).
- **Works alongside** another error handler: Bugsy catches errors first and passes them on, or
  reads them from the usual error collector if it's still enabled, and says what that costs.
- Two looks, **WoW Forever** and **Pearl Glass** (with a Glass addon loaded; it follows Glass UI's
  look); a minimap button; Bugsy's page in Options > AddOns; six alert sounds.
