# Validation: what is proven, and what is not yet

State of the first vertical slice (2026-11-17, build 70959). Two kinds of evidence, never mixed:
**automated** checks run offline against WowTestKit's mock (pinned commit `38fb0fc`, build data
70959), and **in-game** checks, which are the only proof of taint, stack levels, secrets and client
behaviour. None of the in-game checks has run yet.

## Automated (`pwsh tests\run.ps1`: 6 files, all passing)

| File | What it proves | Count |
|---|---|---|
| `test_boot.lua` | Load order, the handler installed at load, the saved table adopted, an error drained into a problem with attribution and version, the slash commands, the window opening | 23 |
| `test_capture.lua` | Recursion guard; a throwing body or `debugstack` never escapes and `busy` resets; unsupported messages (a table's `__tostring` is never called); secret message, stack and locals become markers, each on its own; the restricted bucket; tiers (15 full, 40 top, then count) and the discovery budget; the 200-record queue bound; the drain across passes; a failing record dropped and counted; count-map entries delivered once, without replay; events with their fields; errors before `ADDON_LOADED`; displaced, chained (a wrapper), displaced → collector; a no-op setter at load; distinct flood messages kept as stackless problems; the scheduling watchdog | 63 |
| `test_store.lua` | Distinct messages stay distinct; addresses merge; ordinary text untouched; top and full captures agree; frame lines in the **measured Forever shapes** (bracketed first path, named functions, shortened and bare frames, file vs code chunks); one bug from three callers is one problem; our own leading frames never change a signature; first-2/last-3 samples; the 300 cap with 10 000 unique errors; all-muted eviction re-inserting the mute; the previous-session filter ({1,2,4} vs {1,3,4}); count-tier routing; clearing; malformed saved tables; the per-session cap; past 20 call paths, distinct paths counted (not occurrences) with a "more" flag; a kept problem with damaged nested fields (call paths, sessions, addons, samples, attribution) rebuilt so the window, a repeat and a report still work | 82 |
| `test_collector.lua` | A stand-in modelled on the common error collector's source: a previous session's counter counts nothing at seed; a current one counts "at least one"; live repeats count exactly once; evidence copied, not referenced; a reset re-seeds; our event frame owns warnings and actions (a French copy skipped too); a new live error is exact; locals follow Bugsy's setting; a copy embedded in another addon taking over after native capture, with backfill; an unusable collector global ignored; Capture and the stub naming the same collector API | 39 |
| `test_report.lua` | JSON parsed by a strict RFC 8259 parser; control characters, `|` and invalid UTF-8; the player's name and realm replaced in values **and keys** (collision suffix); trimming a far-oversized report under 64 KB in the documented order; the minimal report when nothing else fits; a manual report; **no string in the addon claims a report was sent or submitted**; `docs/examples/` current; empty schema lists encoded as `[]`, maps as `{}`; each Markdown occurrence names the versions it was captured with, the installed ones labelled apart (an upgrade after capture) | 967 |
| `test_ui.lua` | Notices held in combat and sent after; a problem's first occurrence in a new session announced again, not twice in one session; `|` escaped in the list and details; mute, copy guidance, clear all with confirmation, filters, the empty list, the status line; the report flow (answers, preview, destination, JSON, copy guidance), Report a problem; every widget method called exists in build 70959 (`Kit.checkMethods`) | 87 |

**Mutation checks** (each behaviour broken on purpose, a test went red): the recursion guard, the
bracketed frame parser, collector-mode locals honouring the setting, redaction, the scheduling watchdog,
the mute re-insertion on eviction, the exact count for a new live collector error, the action-copy prefix, scheduling after a dropped push; and for the Codex PR review: the saved-problem
repair (as a whole, attribution, evidence), the call-path count, empty arrays, captured versions, the
version-free heading.

What the mock cannot prove: that the client's stack levels match the formula and fallback, that
`issecretvalue`/`canaccessvalue` behave as modelled, that nothing taints, that timers fire from a
handler, what `debugstack` really returns, and how fast anything is.

## In game (BugsyProbe, `/fp steps bugsy <name>`): all still to run

Deployed with `pwsh Tools\deploy.ps1 -Probe`. Disable any other error collector and its viewer first (one makes
`seterrorhandler` a no-op, which blocks the probe's measuring handler).

| Procedure | Answers | Release gate |
|---|---|---|
| `stacks` | P2 (ten raise paths, the wrapper and `OnEvent` included), P11, P13 (stack fixtures), P14 (`GetTime` in a frame) | yes |
| `secrets` | P1: secret message, stack, locals in combat | yes |
| `combat` | P6: an error in combat, a timer scheduled from the handler | yes |
| `early` | P5: errors during loading, `LoadSavedVariablesFirst`, a timer during load | yes |
| `floods` | P8: 1 000 identical and 1 000 unique errors | yes |
| `throw` | P9: a handler that throws | yes |
| `coexist` | P7: with the standalone collector, without, with a copy embedded in another addon | yes |
| `popups` | P4, P10: forbidden-action payloads, Blizzard's popup | owner's decision |
| `copy` | P12: Ctrl+C fidelity of `|`, tabs, UTF-8; 63 KB in an edit box | Copy details part |
| (passive) | P3: `LUA_WARNING` over a play session (`/fp bugsy warnings`) | payloads only |

Plus the save/reload check of the release gate (BACKLOG): evidence, mute and clear state, session
rollover and the previous-session filter across a full client exit.

## Reviews

- Codex (gpt-6-astra): design rounds 1-4 to consensus. Round 5, on the changes below and their
  code, found 5 more (an off-by-one in the collector's action prefix that a weak test missed,
  liveness lost when a wrapper's first error precedes the check, a full queue never reaching the
  watchdog, two compares before a readability check, a stale design line); each fixed with a
  mutation-checked test. Round 6: consensus.
- Fable: an independent review after consensus found 8 issues, all accepted: the measured frame
  format (the most serious; the synthetic tests had used the wrong shape), stack levels through
  `pcall`, collector-mode locals and counts, chaining wrappers, flood text loss, eviction by a
  unique flood, notices for recurring problems, and probe gaps. Each fix has a test above.
- Codex review of the first PR (five P2): saved problems with damaged nested fields, captured
  versions missing from Markdown, empty lists encoded as objects, overflow occurrences counted as
  call paths, and the probe turning a successful `false` from `issecretvalue`/`canaccessvalue`
  into "error" (fixed with an explicit branch; the probe reads a value only when every check ran
  and cleared it; no unit test, the probe runs only in game).
