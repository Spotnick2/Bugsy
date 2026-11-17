# Validation: what is proven, and what is not yet

State of the first vertical slice (2026-11-17, build 70959). Two kinds of evidence, never mixed:
**automated** checks run offline against WowTestKit's mock (pinned commit `38fb0fc`, build data
70959), and **in-game** checks, which are the only proof of taint, stack levels, secrets and client
behaviour. In game, `stacks`, `secrets`, `combat`, `front`, `frontown`, `early`, `throw`, `coexist`, `popups`, `floods` and `copy` have run: every procedure (build 70959, results in FOREVER-PROBE §7); the rest have not.

## Automated (`pwsh tests\run.ps1`: 9 files, all passing)

| File | What it proves | Count |
|---|---|---|
| `test_boot.lua` | Load order, the handler installed at load, the saved table adopted, an error drained into a problem with attribution and version, the slash commands, the window opening | 23 |
| `test_capture.lua` | Recursion guard; a throwing body or `debugstack` never escapes and `busy` resets; unsupported messages (a table's `__tostring` is never called); secret message, stack and locals become markers, each on its own; the restricted bucket; tiers (15 full, 40 top, then count) and the discovery budget; the 200-record queue bound; the drain across passes; a failing record dropped and counted; count-map entries delivered once, without replay; events with their fields; errors before `ADDON_LOADED`; displaced, chained (a wrapper), displaced → collector; a no-op setter at load; distinct flood messages kept as stackless problems; the scheduling watchdog | 64 |
| `test_store.lua` | Distinct messages stay distinct; addresses merge; ordinary text untouched; top and full captures agree; frame lines in the **measured Forever shapes** (bracketed first path, named functions, shortened and bare frames, file vs code chunks); one bug from three callers is one problem; our own leading frames never change a signature; first-2/last-3 samples; the 300 cap with 10 000 unique errors; all-muted eviction re-inserting the mute; the previous-session filter ({1,2,4} vs {1,3,4}); count-tier routing; clearing; malformed saved tables; the per-session cap; past 20 call paths, distinct paths counted (not occurrences) with a "more" flag; a kept problem with damaged nested fields (call paths, sessions, addons, samples, attribution) rebuilt so the window, a repeat and a report still work | 82 |
| `test_collector.lua` | A stand-in modelled on the common error collector's source: a previous session's counter counts nothing at seed; a current one counts "at least one"; live repeats count exactly once; evidence copied, not referenced; a reset re-seeds; our event frame owns warnings and actions (a French copy skipped too); a new live error is exact; locals follow Bugsy's setting; a copy embedded in another addon taking over after native capture, with backfill; an unusable collector global ignored; Capture and the stub naming the same collector API | 39 |
| `test_report.lua` | JSON parsed by a strict RFC 8259 parser; control characters, `|` and invalid UTF-8; the player's name and realm replaced in values **and keys** (collision suffix); trimming a far-oversized report under 64 KB in the documented order; the minimal report when nothing else fits; a manual report; **no string in the addon claims a report was sent or submitted**; `docs/examples/` current; empty schema lists encoded as `[]`, maps as `{}`; each Markdown occurrence names the versions it was captured with, the installed ones labelled apart (an upgrade after capture) | 967 |
| `test_fixtures.lua` | The real stacks from `stacks` (P13): each one's first location, attribution to the probe alone, a key-binding chunk and C frames not locations, the measured `[tail call]` spelling, and one problem whether an error arrives directly or through a tail-calling wrapper; the real `secrets` messages (secret-boolean wording, the aura error) matched by their patterns and attribution, the aura title without its `Lua Taint:` line, `UNKNOWN ERROR` grouped per location | 32 |
| `test_front.lua` | Front mode (D14), the Codex design review's cases: Bugsy goes in front of a wrapper installed after it, records the transition as its own, records each error once and passes it on once (tail and non-tail, arguments with trailing nils), records errors the wrapper keeps or stops passing on; a failed capture still passes on; a throwing wrapper is counted and the guards clear; reports made while passing are dropped and counted; a deferred pass-on is recorded twice (documented); a no-op setter, a setter that installs then throws, one that throws first; exactly one attempt; a later wrapper saving the front keeps the chain; a collector after the front: neither entry point records or leaves collector mode, the front still passes on; a nil-height direct call changes no mode, now or at the next check; the setting read once a session; status, limits, `/bugsy status`, Diagnostics | 75 |
| `test_health.lua` | #14 and #11 (D16), the Codex design review's cases: 99/100/101 deliveries in one timestamp; call 101 captured normally; silence never certainty; `deliveredAfter`; the exact notice as a hint (not a problem), a translated, spoofed or secret one classifying nothing; direct reports, height 0 and events; detection with no tiers, a full queue, no count map and no store; one coalesced health notice, held in combat, no sound; `/bugsy status` and the status line. The breaker: 49/50 ms, the rolling window (99/132 ms) and expiry, slow and fast throws, untrustworthy timers (throwing, secret, non-numeric, infinite, backwards), a shared-timer reset between calls or within a call clears the window and a future-stamped bin never counts, one trip, skipped not counted as loss, a reload starts fresh; full, minimal and manual reports carry both snapshots and Markdown shows them | 100 |
| `test_ui.lua` | Notices held in combat and sent after; a problem's first occurrence in a new session announced again, not twice in one session; `|` escaped in the list and details; mute, copy guidance, clear all with confirmation, filters, the empty list, the status line; the report flow (answers, preview, destination, JSON, copy guidance), Report a problem; every widget method called exists in build 70959 (`Kit.checkMethods`) | 97 |

**Mutation checks** (each behaviour broken on purpose, a test went red): the recursion guard, the
bracketed frame parser, collector-mode locals honouring the setting, redaction, the scheduling watchdog,
the mute re-insertion on eviction, the exact count for a new live collector error, the action-copy prefix, scheduling after a dropped push; and for the Codex PR review: the saved-problem
repair (as a whole, attribution, evidence), the call-path count, empty arrays, captured versions, the
version-free heading; and for front mode: the passing guard, collector exclusion, the nil-height
liveness rule, front kept by its own installation, the one-attempt rule and its marking, success
by identity, the session snapshot of the setting, the forwarded arguments, clearing the passing
guard; and for #14/#11: nil-height deliveries counted, the 100 boundary, a loose notice match, the
notice stored as a problem, `deliveredAfter`, the handler skipping the observation, a backwards
timer accepted, the call threshold, bins that never expire, no suspension, the passing guard left
set, an unvalidated timer, a minimal report without capture, Markdown hiding the suspension, no
health notice. (The collector return inside liveness is a second safeguard: both entry points return
before it, so breaking it alone changes nothing.)

What the mock cannot prove: that the client's stack levels match the formula and fallback, that
`issecretvalue`/`canaccessvalue` behave as modelled, that nothing taints, that timers fire from a
handler, what `debugstack` really returns, and how fast anything is.

## In game (BugsyProbe, `/fp steps bugsy <name>`)

Deployed with `pwsh Tools\deploy.ps1 -Probe`. Disable any other error collector and its viewer first (one makes
`seterrorhandler` a no-op, which blocks the probe's measuring handler).

| Procedure | Answers | Release gate |
|---|---|---|
| `stacks` | **Done, 70959: passed.** P2 formula exact where `GetErrorCallstackHeight` is set, fallback 4 confirmed, a tail-calling wrapper harmless; P11 identity works; P13 fixtures in `test_fixtures`. P14 within a frame left to `floods` | yes |
| `secrets` | **Done, 70959.** P1: three tainted errors in combat; message, stack and locals all readable, the two checks agree; new secret-boolean wording matched; a table error arrives as `UNKNOWN ERROR`. A secret *message* was not produced: those markers stay unmeasured | yes |
| `combat` | **Done, 70959.** P6: the handler in combat writes its tables and its timer runs; no blocked action. taintLog was off: taint lines are left to `frontown` | yes |
| `early` | **Done, 70959.** P5: saved table readable at file scope; a load-time timer runs after `ADDON_LOADED`; a main-chunk error has error height 0, which emptied the stack (fixed: counts as 1). It also exposed, and the fixed probe no longer has, a client hang | yes |
| `floods` | **Done, 70959.** The client pauses error reporting after 100 errors in one frame, until `/reload` (#14); a spread flood is bounded by the 150 new-problem cap; longest frame 40 ms, no freeze; `!Bugsy` memory a few MB at most | yes |
| `throw` | **Done, 70959.** P9: a throwing handler becomes a Lua Warning (Blizzard's window, `LUA_WARNING`); no recursion; capture continues | yes |
| `front` | **Done, 70959: passed.** P7: Bugsy in front of the installed wrapper records its kept errors, locals and a direct report, and keeps capturing after the wrapper's measured cutoff (1 000) | yes |
| `frontown` | **Done, 70959: passed.** P6, P7: front installed in combat, no taint or blocked action; downstream formula levels hold; a report while passing dropped and counted; a throwing wrapper counted; a later wrapper keeps the chain | yes |
| `pause` | **Done, 70959.** #14: the client pauses at the 100th error in one frame (99 twice does not); its notice is not sent at 100 or 101; Bugsy's suspicion at exactly 100; events still captured | for D16 |
| `frontslow` | **Done, 70959.** #11: under the thresholds nothing trips; one 60 ms pass-on trips; in combat the window trips at 105 ms; capture continues | for D16 |
| `coexist` | **Done, 70959.** P7: with the collector, collector mode and errors through it; without it, the embedding addon wraps the handler and Bugsy goes front | yes |
| `popups` | **Done, 70959.** P4: the forbidden function is named (`TargetUnit()`); P10: with Blizzard's listeners unregistered, no popup. Taint of doing so not yet checked (B-18) | owner's decision |
| `copy` | **Done, 70959.** P12: Bugsy's doubled-pipe display copies back to the original exactly (`|`, colour codes, UTF-8); raw text copies what is rendered; 63 KB identical. A tab's fate is unknown | Copy details part |
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
