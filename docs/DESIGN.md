# Bugsy: design

Bugsy is a bug-reporting addon for WoW: Forever 1.60.1 (Interface `16001`, Lua 5.1). It replaces
the usual error collector and its viewer, and adds what they lack: problems grouped with evidence,
attribution that keeps its uncertainty, a report a player can hand to an author, and a small
library authors can use to add context.

The measured and source-verified facts this rests on are in [FOREVER-PROBE.md](FOREVER-PROBE.md).
The report format is [REPORT-SCHEMA.md](REPORT-SCHEMA.md), the author library
[LIBRARY.md](LIBRARY.md), and the plan [BACKLOG.md](BACKLOG.md). Reviews: Codex round 1
(2026-11-17) shaped §3-§10; its findings are folded in, not listed separately.

## 1. What the player and the author get

The player can answer, from Bugsy's window:
- what went wrong (a readable summary, how many times, first and last seen);
- which addon seems involved, and how sure that is;
- what to give the author (a report previewed before copying);
- where to report it (the author's destination when known, "unknown" when not);
- whether anything was sent: **never**. Bugsy contacts nobody. A copied report is "copied", not
  "submitted".

The author gets, in the first report: exact versions, the full accessible error and stack, how
often and since when, what the player was doing, the context their own addon chose to record, and
what Bugsy could not read (restricted, truncated, sampled), stated rather than silently missing.

Two kinds of problems:
1. **Detected**: Lua errors, `LUA_WARNING`, blocked and forbidden actions, and failures an addon
   caught and reported itself through the library.
2. **Player-reported**: "Report a problem" with no error (an empty AltStable tab, a failed sync, a
   wrong Glass Gear arrow). The player picks the addon; Bugsy attaches what that addon registered.

## 2. Shape

One player-facing addon, folder `!Bugsy` (title "Bugsy"), loading early by name.
One embedded library, `LibBugsy-1.0`, for authors (phase 2). Five layers, each with one job:

```
 capture  ──raw records──▶  incidents  ──▶  diagnostics  ──▶  presentation
 (critical path)            (store)        (deferred)        (UI)        ──▶ export
```

| Layer | Files | Runs | Job |
|---|---|---|---|
| Capture | `Compat.lua`, `Capture.lua` (native handler, events, collector provider) | inside the error handler / event / callback | Take what exists only now into a bounded queue. Nothing else. |
| Incidents | `Signature.lua`, `Store.lua` | deferred drain | Signatures, grouping into problems, samples, counters, caps, SavedVariables. |
| Diagnostics | `Attribution.lua`, `Patterns.lua`, `Context.lua` | drain / on view | Who is involved and why we think so; known-pattern explanations; the environment. |
| Presentation | `UI.lua`, `ReportUI.lua`, `Options.lua` | on demand | The problem list, details, the report flow, quiet notices, the Options page. |
| Export | `Report.lua`, `Json.lua` | on demand | The canonical report, Markdown and JSON, redaction, size trimming. |

The reporting engine never depends on LibGlass or GlassUI. Presentation uses Blizzard templates;
a Glass skin (B-21) is applied after, under `pcall`, so a LibGlass error can still be reported.

## 3. Capture

### Providers and event ownership

Exactly one provider owns each kind at any moment.

| Mode | Lua errors | Entered when |
|---|---|---|
| **native** | our handler | no collector global at our file load (the intended setup) |
| **collector** | another error collector's per-error callback (`Capture.COLLECTOR`) | that collector's global with its API present at file load, or appearing later from any other mode |
| **displaced** | possibly nobody: Bugsy says it is unsure | the handler changed and no error has reached our handler since |
| **chained** | our handler, through another addon's wrapper | displaced, then a real error (one with a client error height) reached our handler (several UI suites and large addons wrap the previous handler) |
| **front** | our front handler, installed **ahead** of that wrapper, which it passes each error on to | displaced or chained, no collector, and Bugsy's one attempt this session succeeded (D14) |

`LUA_WARNING` and `ADDON_ACTION_*` belong to **our event frame in every mode**. In collector
mode, the collector's copies of them (messages starting `LUA_WARNING: ` or `[ADDON_ACTION_`; the
`[%s] ` prefix is the same in all its locales) are skipped. So every occurrence counts, in any
locale, with no once-per-addon limit and no takeover window to double-count (Fable review).

**Detection.** At every `ADDON_LOADED`, at `PLAYER_LOGIN`, at the start of every drain and when
the window opens, `geterrorhandler() ~= ourHandler` means only "the handler changed" (P11 checks
the comparison is reliable). It is a transition, not a verdict: the mode becomes displaced, and
the next real error reaching our handler makes it chained. A late replacement between checks is
seen at the next drain or window open. Then Bugsy tries once to go in front (below). Bugsy records a
transition only when the current handler differs from the last one recorded:
`handlerChanges` keeps the last 5 `{ at, afterAddon, action }` (`action = "front"` for our own
front installation) and counts older ones in
`handlerChangesDropped`. It enters collector mode only when the collector's global exists
**and** its API checks out: `GetDB`, `GetErrorByID` and `GetSessionId` are functions, and so is
`EventRegistry.RegisterCallback`. It never claims the new handler *is* the collector's; the status
line says it is "reading from another error collector". Otherwise: displaced, then front.

**Liveness evidence.** A call counts as an error delivered through the installed handler only
when `GetErrorCallstackHeight()` is a number at that moment: the client has an error in flight
(measured, FOREVER-PROBE §7: nil for a direct `geterrorhandler()(msg)` call and for `xpcall`). A
nil-height call, typically a library holding our original handler, is recorded and changes
neither the mode nor the evidence a check reads. While our front is installed the mode stays
front. Collector mode is never left from a handler.

**Front (D14; Codex design review, three rounds, 2026-11-17).** An addon that wraps the handler can
keep some errors for itself or stop passing errors on (measured in the owner's setup, §7). So,
in a check, when the mode is displaced or chained, no collector API is usable, the saved setting
`front` is on (read **once a session**, at our `ADDON_LOADED`; `/bugsy front` changes the next
session) and this session has not tried yet, Bugsy:
1. marks the attempt (one a UI session, success or not), keeps the current handler as its next
   handler (never changed afterwards), and calls the **current** global setter with
   `Capture.front` under `pcall`;
2. counts it installed only if `geterrorhandler() == Capture.front` afterwards, whether the
   setter returned or threw (a collector's no-op setter fails this; nothing is restored), and
   records the transition with `action = "front"`.

`Capture.front` runs, in this order: the **passing guard** (while it is passing an error on, any
call into either of our entry points is not recorded: the first call with the same message is the
wrapper passing it back, `passReturned`; any other is a distinct report made meanwhile, dropped and
counted as a loss, `passSuppressed`, which the status and reports include);
**collector exclusion** (in collector mode no native capture, `nativeInCollector`, but it still
passes on); the busy guard; liveness; capture with the **same nesting as the handler**
(front → `pcall` → body, so the measured levels and `FALLBACK_LEVEL` hold); then **passing on**,
synchronously and once, `pcall(next, msg, ...)` with every argument (failures counted,
`forwardFailed`, never rethrown). Our original handler runs the same guards, in the same order.

Best effort, stated in the limits: a wrapper that **defers** its pass-on reaches our original
handler later and is recorded a second time; a distinct report made **synchronously** while the
wrapper runs is dropped; the wrapper's own stack levels may be off by Bugsy's frames (it computes
them itself; fixed offsets point at our frames); its code runs **outside Bugsy's budget** (the
critical path's bounds cover Bugsy's own work only). A later wrapper that saves our front is
noticed (displaced, then chained when a real error reaches the front through it); there is no
second attempt, so the chain later wrapper → front → first wrapper stays intact. Each sample
records how it arrived: `entry = "handler" | "front" | "event" | "collector"`.

**Backfill and counting.** The collector's error objects are mutable and cumulative: `counter` grows
across sessions (a repeat from another session moves the object to this session **without**
resetting it), and `stack`, `locals` and `time` are rewritten on some repeats. Bugsy keeps a
weak-keyed watermark per object (`seen[obj] = counterAtLastRead`). The switch is one
non-yielding routine: **register** the live callback, then
**reconcile** `GetDB()`, both sharing the watermark; our event frame stays registered (D10). Registering first also covers a notification
raised while reconciling.
- **Seeding** (an object read for the first time, at reconcile or in a live callback): its
  `counter` is not trusted as this session's count. An object from another session sets the
  watermark and counts nothing. An object already in this session counts **one** occurrence and
  marks the problem `countIncomplete` ("at least"): how many of its counter happened this session
  cannot be reconstructed. The watermark is set to the counter.
- **After seeding**, each read adds `counter - watermark`; a counter lower than the watermark
  (a reset) re-seeds.
- **Exactness is relative to the baseline.** When the standalone collector is present at our file
  load, the switch (and so the seeding) runs at our file load. It starts its session during its own
  file load, so errors raised by addons loading between it and us precede our baseline: those
  objects seed as "at least one" (`countIncomplete`). Deltas **after** an object's seed are exact;
  nothing before it is claimed.
- The evidence (message, stack, locals) is **copied as strings at read time**, never kept by
  reference. Warnings and actions are not backfilled: our event frame owned them until the switch.
- Provenance: `provider = "collector"`, `stackOrigin = "collector"` (the stack may be from an
  earlier repeat), `observedAt` = our read time. A **live** callback runs synchronously inside
  the collector's handler, so `inCombat`, `instanceType` and `taintLog` read there are occurrence-time
  facts; at **reconcile** they are markers `{ unavailable = true, reason = "backfill" }`, and the
  occurrence time is the collector's `time` marked `approximate`.

- A brand-new object seen live (counter 1) is this very error: it counts exactly. Locals from
  the collector (which always captures them) are copied only when Bugsy's locals setting is on.

**Limits of collector mode**, printed by `/bugsy status` and carried in every report
(`capture.limits`): secret messages are not stored by the collector; past 10 errors a second it drops
everything, uncounted; stacks may come from an earlier repeat; no breadcrumb cursor at error time.

A compatibility global with the collector's name (so embedded copies bail) is **not** planned for
the MVP (B-17). An addon embedding a copy keeps working through collector mode with the limits
above. Whether that is acceptable for daily use is a P7 acceptance question.

### The native handler (the critical path)

1. **It never throws and never recurses.** `busy` is set before the protected body and cleared
   after every outcome. A call while `busy` only increments `nested` and returns. The body runs
   under `pcall`. A failure increments `failures` and keeps at most 5 failure messages, each only
   if it is a readable **string**, cut to 200 bytes. Nothing in the recovery path calls
   `tostring` on a non-string.
2. **It accepts only plain messages.** A message is used as text only if it is a readable string
   (a readable number is formatted). Any other type (a table, possibly with an author's
   `__tostring`; a boolean; nil) is stored as `{ unsupported = "<type>" }` without being called.
3. **It takes only what will be gone later**, under the tier the budget allows (§6): the message
   (cut to 2 KB at capture), the stack (`debugstack` at the error level, cut to 6 KB; the first
   12 lines in the "top" tier), locals only when the player turned them on (cut to 3 KB), `time()`,
   `GetTime()`, `InCombatLockdown()`, `IsInInstance()`'s type, the taintLog CVar, the session, and
   the library's breadcrumb sequence and context revision (integers, checked readable).
   `debugstack`/`debuglocals` allocate before we can cut; their cost is measured (P8), not bounded
   by us.
4. **Stack level is computed in the handler body itself**, not in a helper, and `debugstack` and
   `debuglocals` are called **directly** from that body (through `pcall`, its C frame becomes
   level 1 and every level is one short; Blizzard's own handler calls them directly). If one
   throws, the body's own `pcall` counts the failure. Blizzard's formula when
   `GetErrorCallstackHeight()` is a number (`stackOrigin = "error"`); else a fixed level from P2
   (`"fallback"`, or `"event"` for warnings and actions). Events run as event → `pcall` → body,
   the handler's nesting, so one constant serves both. Signatures and attribution skip the leading
   run of Bugsy's own frames, so a level that lands short never changes a signature.
5. **Every value is checked with `Safe` before any touch**: message, stack, locals, event
   arguments, library integers, and failure values. No truth test (`if x then`) on an unchecked
   value.
6. **One record into a bounded queue**, then the drain is scheduled (below). Formatting,
   signatures, grouping, attribution, UI and SavedVariables writes happen in the drain.
7. **No author callbacks run in it.** The library's integers are read with `rawget`.

`LUA_WARNING` and `ADDON_ACTION_BLOCKED/FORBIDDEN` arrive on our event frame (native and displaced
modes) and use the same budget and queue with kind `warning`, `blocked`, `forbidden`; the event
name, the named addon and the function are kept as separate fields. Every occurrence counts.
Whether Bugsy also suppresses Blizzard's popups, as the collector does, waits for P10 (B-18);
whether the popups are acceptable day to day is a release check.

### The drain

One `drainScheduled` flag. Scheduling: if the flag is false (or was set more than a second ago:
a watchdog, since a timer that never fires must not stop capture for good), set it and call
`C_Timer.After(0, Drain)`; if that call fails, clear the flag and count it. `Drain` clears the flag first, processes
records under a budget (at most 50 records **or** 4 ms by `debugprofilestop`, each record's own work
bounded by the byte caps), each under `pcall` (a failing record is dropped and counted), and
reschedules itself while work remains. **Pending work** is the queue **and** the count map (§6):
a count-tier update schedules the drain the same way; the drain takes the map by swapping it for
an empty one, then transfers each entry once (a failure drops that entry and counts it, never
replays it). Handled errors from the library wake it through the bridge (§11). Errors before our `ADDON_LOADED` stay in the in-memory queue; the drain does nothing
until the saved table is adopted, then merges them (P5 checks timer behaviour during load).

## 4. Incidents and grouping

**Raw record → occurrence → problem.** Signatures are computed over the **captured** (cut)
evidence, so a re-capture of the same error always yields the same signature.

- **Stack lines** used by signatures: the first 12 lines of the stack, ignoring `[C]: ?` and
  `(tail call)` lines.
- **Locations**: the **first path of each line**, as `Folder/path.lua:line`. Measured on Forever,
  each line names its file twice: `[Interface/AddOns/X/f.lua]:12: in function
  <Interface/AddOns/X/f.lua:10>`; the first is where the line ran, the second where the function
  was defined (porting guide, "Who wrote a chat line"). Also parsed: unbracketed paths, shortened
  `[...AddOns/X/...]` paths, bare `[X/f.lua]:763` frames, and `[string "@Interface/AddOns/..."]`
  file chunks. A `[string "..."]` without `@` is a code chunk, and a shortened path that hides the
  folder (`[...f.lua]`) is not a location. The leading run of Bugsy's own frames is skipped;
  a library embedded in Bugsy's folder (`!Bugsy/Libs/...`, #26) is not Bugsy's own and keeps
  its location, as any library does.
- **Exact signature**: kind + the message + the 12 stack lines, hashed.
- **Grouping signature** (g1): kind + `addressless(message)` + the **first location** (the faulting
  line), else the first stack line, else nothing. One bug reached from different callers is one
  problem; the problem counts its distinct exact signatures ("reached by N call paths", up to 20).
  Two faults with the same message at the same line merge: that is the same line failing the same
  way, and their exact signatures stay distinct in the samples.
- `addressless` replaces exactly these (Lua patterns, applied in order): `0x%x%x%x%x+` → `0x?`;
  for each of `table`, `function`, `userdata`, `thread`: `<word>: %x%x%x%x%x%x%x%x+` → `<word>: ?`;
  `builtin: %x%x%x%x%x%x%x%x+` → `builtin: ?`. Eight hex digits or more, so ordinary text such as
  "table: expected" is untouched. Numbers, names and quoted text are kept.
- `sigAlgo = "g1"`. Any rule change bumps it; problems of another algorithm are never merged.
  **One narrow exception (#26, agreed in #13's design review):** `!Bugsy/Libs/` frames stopped
  counting as Bugsy's own without a bump. No shipped Bugsy version produced such a location (none
  shipped a library), so no saved signature changes; tests pin the existing cases unchanged.
- **Versions are not in the signature** (a cross-account and cross-release match stays possible).
  Each occurrence keeps the versions of the addons involved; the problem keeps a bounded
  `versions` map (version → count, 10 entries, then "other"). A report never presents an old
  version's sample as the current one: samples show their version.
- Known limits (documented, shown nowhere as certainty): a line moving between releases splits a
  problem; a message that embeds its own line number splits on that; a wrapper changing the
  first location splits.

**Opaque occurrences** (message not readable): grouped by `kind + "restricted" + first location`
when the stack is readable; when neither is, into one bucket per kind titled "Restricted errors:
details unavailable (may be unrelated)", never merged across sources.

**Tiers and repeat recognition** (§6): a "full" or "top" capture has 12 stack lines, so both
signatures are exact. A "count" tier record (over budget) has only a **message key** (kind +
addressless message, hashed, computed in the handler from the ≤ 512-byte message head, cached by
message text) and, for a message not seen this session, the head itself. In the drain, a count
entry whose key matches **exactly one** problem seen this session adds to that problem's
`unconfirmedRepeats`, never to its `count`; with no match and a head, it becomes a **stackless
problem** (its text kept, "stack not captured: flood"), so a burst of distinct errors at login
keeps every message; otherwise it adds to `suppressed[kind]`. The UI says "+N more with the same
message (stack not captured)".

**New problems a session**: at most 150. Past it, a new problem is only counted
(`suppressed[kind]`, `stats.newCapped`): one session's flood of unique errors cannot evict every
older problem. Folding variants (one line, messages differing only in digits) is B-24.

**A problem keeps**: id (its grouping signature + `sigAlgo`), kind, title, message key, `count`
(with `countIncomplete` when a collector seed made it a lower bound), `unconfirmedRepeats`,
`firstSeen`, `lastSeen`, `firstSession`, `lastSession`, `sessionCount`, `recentSessions` (the last
3 distinct sessions it was seen in, for the session filters), `callPaths` (≤ 20 exact signatures),
`addons` (≤ 8 involved addons with their `versions`, ≤ 10 versions each, then `addonsOverflow`),
the **first 2** occurrences and the **last 3** in full (`sampledOut` counts the rest), `muted`,
and the player's notes if a report was prepared (each answer ≤ 1 KB). A later message-only or
count record never replaces a full-stack sample.

**SavedVariables** `BugsyDB = { format = 1, sourceId, session, problems, mutes, stats, settings }`.
`sourceId` is random at creation (an opaque per-account id for the offline merge). `format` is the
database's own version; `Report.lua` converts a problem into `bugsy.report/1`.

**Caps**: 300 problems. Over the cap, evict the oldest by `lastSeen` among non-muted; if every
problem is muted, the oldest muted. Muting is also kept in `mutes` (grouping signature → time,
at most 200, oldest out). Evicting a muted problem (re)inserts its signature into `mutes` first,
so it stays muted when it comes back, unless 200 newer mutes have pushed it out since.
`stats.evicted` counts evictions. **Clear** removes problems (one, this session's, or all); the
mute list survives a clear unless the player clears mutes too.

Sessions: `db.session` increments at our `ADDON_LOADED`. Filters: this session (`lastSession`
is the current one), previous session (`recentSessions` contains `session - 1`), all.

## 5. Secret and inaccessible values

`Safe` in `Compat.lua`, feature-detected at load:
- `Safe.readable(v)`: false when `issecretvalue(v)` is true, when `canaccessvalue` exists and
  returns false, or (tables) when `canaccesstable` returns false. Each check runs under `pcall`; a
  check that throws means "not readable". With neither API, everything is readable.
- Readable does not mean safe to stringify: only strings (and numbers, formatted) are ever turned
  into text. Tables are never passed to `tostring`.
- Message, stack, locals and every event or library value are checked on their own. A field that
  fails is stored as `{ restricted = true, reason = "secret" | "inaccessible" }`: never text,
  never a key, never compared.
- No attempt is made to recover restricted data.

## 6. Floods and bounds

**Capture tiers, per second** (token buckets, refilled by `GetTime()`):

| Tier | Budget | Takes |
|---|---|---|
| full | 15/s, plus 5/s reserved for a message key not seen this session ("discovery") | message, full stack, locals if on |
| top | 40/s | message, the first 12 stack lines (signatures stay exact) |
| count | unlimited | the message key only (≤ 512-byte head hashed); no queue slot used: a bounded per-session map of message key → count (100 keys, then `suppressed[kind]`) |

The "seen this session" set holds message keys (hash strings: safe as keys), at most 1000, reset
when full. `GetTime()` is the frame's time (API dump), so the buckets refill between frames, not
within one: a long loading frame gets one second's budget (P14 measures it).

**Bounds**: queue 200 records (newest dropped, `stats.queueDropped`); raw strings cut at capture
(message 2 KB, stack 6 KB, locals 3 KB); problems 300; mutes 200; samples 5 a problem; call paths
20; involved addons 8 a problem, versions 10 an addon; recent sessions 3; handler changes 5;
count map 100 keys; notes 1 KB a field; failure ring 5 × 200 bytes; per-kind counters on a fixed
enumeration (`error`, `warning`, `blocked`, `forbidden`, `handled`). Drain: 50 records or 4 ms a
frame.

**Loss counters** carry their scope in their names: `session.suppressed[kind]`,
`session.queueDropped`, `lifetime.evicted`, and per problem `unconfirmedRepeats` and `sampledOut`.
A report shows the session counters as "this session, across all problems", never as the
problem's own loss. Bugsy never stops capturing entirely and never claims it caught everything.

**The client's pause (#14; Codex design review, three rounds).** Measured (FOREVER-PROBE §7): after
100 errors in one frame the client calls the handler once more with *"Error reporting is now
paused and will resume after reloading the UI."* and then calls no handler until `/reload`.
Bugsy cannot see a pause directly, so it records **evidence**, never a verdict:
- an **eligible delivery** is a call into our handler or front that passed the passing,
  collector and busy guards with a readable numeric error height (0 included). Direct reports
  (nil height), events, collector callbacks and pass-backs are not counted. It is counted before
  any tier, queue or store decision, so saturation cannot hide it (`stats.deliveries`);
- deliveries are grouped by **same timestamp** (`GetTime()` equal): a heuristic, not frame
  identity (P14 is incomplete). At 100 in one bucket, `health.pause` records a **suspicion**
  (`status = "suspected"`, `evidence = "burst"`, the capture session, `observedCalls`);
- the exact English notice is an **optional hint** (D15): it sets `status = "reported"`
  (`evidence = "message"` or `"both"`) and that one call is not stored as a problem. Any other
  message, whatever its position (call 101 included), is captured normally; another locale only
  loses the hint;
- a delivery in a later timestamp counts in `deliveredAfter` (reporting did not fully stop);
  silence never upgrades the suspicion; nothing ever makes Bugsy refuse a call.
`/bugsy status`, reports (`capture.limits`, `capture.health`) and the window's status line say
"may have paused" (or "received a message saying"), and that warnings and blocked-action events
are captured separately. One health notice, held in combat and throttled with the others, no
sound.

**The front's circuit breaker (#11, D16).** In front mode the next handler runs inside Bugsy's
call, so its time counts against `!Bugsy` (measured: 85 execution-limit warnings behind a runaway
handler). Each pass-on is timed with a guarded profiler read (missing, throwing, secret,
non-numeric, infinite or backwards readings count as `timingUnavailable`, never as fast or
slow). One call of **50 ms**, or **100 ms** within a rolling second (10 stamped bins of 100 ms),
latches `forward.suspended` for the UI session (`/reload` retries): Bugsy keeps capturing every
delivery, stops calling the next handler, and counts `forward.skipped` (not a capture loss). The
thresholds are provisional, not measured limits. It cannot bound the first slow call; a slow call
that threw counts. A later wrapper that runs before our front is outside this timing. If a
collector takes over later, collector mode follows the usual rules and the suspension stays
recorded; Bugsy never resumes forwarding by itself.

## 7. Attribution and explanations

Separate fields, never merged:
- **`named`**: the addon the client named: `ADDON_ACTION_*`'s first argument, or the `'X'` in
  *"tainted by 'X'"*. The client's taint blame, not proof.
- **`inStack`**: every addon frame in the readable stack, in order, each with `folder` (where the
  file physically is), `library` (a probable library name, from `Libs/<Name>/`, `Libraries/`,
  `Embeds/` segments or a known library folder) and `host` (the folder carrying the embedded copy).
  A host is where the copy lives, not necessarily the addon that used it.
- **`suspect`**: Bugsy's guess with `evidence` and `confidence` (`low` / `medium`): the first frame
  from the top that is not Bugsy, not `Blizzard_`, not a library; else a library's host (low); else
  `named` (low). Its evidence always says it is a heuristic, and lists conflicts (the client named
  someone else). A dispatcher, a hook wrapper, or a caller passing bad input can be picked: the
  report's wording ("appears involved") reflects that.

The stored stack is never replaced by the simplified display.

**Patterns** (`Patterns.lua`): rules `{ id, rev, builds = { min, max }, match, summary,
investigate, confidence, ref }`. A match records `{ id, rev, evidence }`; the UI and export show it
under "Possible explanation (not a diagnosis)". Initial rules, worded to their evidence:

| id | Matches | Says |
|---|---|---|
| `secret-touch` | "(a secret … value)" in the message | Quotes the matched operation; code used a secret value; guard before the first touch. Never names an event |
| `aura-secret` | "Auras cannot be accessed when secret" | An aura read was refused because aura data was secret; mentions combat only when the occurrence's `inCombat` is true |
| `forbidden-unknown` | kind forbidden, function `UNKNOWN()` | The client gave no function name; the stack may or may not show the caller |
| `taintlog-nilmethod` | taintLog CVar non-zero **at the occurrence**, "attempt to call method" with a `Blizzard_` top frame | Suspected taint-log noise; suggests toggling taintLog to test it; labelled and filterable, still listed |
| `blocked-combat` | kind blocked, `inCombat` at the occurrence | A protected action during lockdown; investigate whether the operation can legally run after combat, and remember the client blames the taint carrier |

## 8. Presentation

- **Main window** (`/bugsy`): a list of problems (title, addon, count, last seen, restricted /
  muted / noise tags) with filters (this session / previous / all; show muted), and a detail pane:
  summary, involved addons with versions, attribution with evidence, possible explanation, then the
  full message, stack and locals in a read-only box. Buttons: **Prepare report**, **Copy details**,
  **Mute**, **Clear** (this problem; a menu for this session's and all). A status line: provider
  mode, handler changes, session losses.
- **Settings**: capture locals (off by default, with its privacy note; applies from then on),
  chat notices, the alert sound and its choice, front mode (from the next session). Set by the
  slash command or on **Bugsy's page in Options > AddOns** (#22, `Options.lua`, `/bugsy options`),
  both through `Bugsy.SetSetting` / `Bugsy.ChooseSound`, so they can't drift. The page is the
  porting guide's shared recipe (a canvas registered at `PLAYER_LOGIN`, hidden at creation,
  built on its first show, re-read on every show; the client's art when a template is missing),
  with the capture status (`Bugsy.StatusLines`, what `/bugsy status` says), buttons opening the
  window and a manual report (closing Settings with `Close(true)` first), and an **About**
  sub-page: the version, how to use, and the commands from `/bugsy help`'s list.
- **Notifications**: one chat line per problem **on its first occurrence this session** (a bug
  from last week coming back today is announced, as the usual viewer does), at most one line every 10 s,
  held until combat ends, with an alert sound (one of the owner's six picks, FileDataIDs on the
  Master channel: a goblin klaxon by default, four metal pops, the earlier hotrod horn;
  `/bugsy sound on|off`, on by default; `/bugsy sound` lists them by name, `/bugsy sound 1-6`
  chooses one and plays it, the setting saving its FileDataID; it follows the notice's throttle
  and combat hold, and plays even with chat notices off); never opens a window in combat.
- **The minimap button and the compartment** (#26, `Minimap.lua`): a LibDataBroker launcher shown
  by LibDBIcon (embedded in `Libs\`, loaded after `Capture.lua` so an error while they load is
  caught). Left-click opens or closes the window, right-click opens the Options page; the tooltip
  gives this session's problems and the clicks. Its place and shown state are LibDBIcon's own
  table, `BugsyDB.minimap` (made or repaired once in `Store.adopt`); showing it is the "minimap"
  setting (`/bugsy minimap on|off`, the Options page). The minimap's addon compartment clicks and
  shows the tooltip the same way. The TOC's `IconTexture` puts the icon in the addon list: the
  client's Insect Swarm icon until Bugsy has its own logo. Without the libraries, or with the
  name taken, there is no button and nothing else changes.
- **Report flow**: (1) what were you doing, what happened, what did you expect, and "I didn't
  notice a visible problem"; (2) a preview of everything included, with the privacy note; (3) where
  to report it (the registered destination, the TOC's `X-Website`, or "Bugsy doesn't know where
  this addon takes reports; check its download page"); (4) the text, Markdown or JSON, selected,
  with "Press Ctrl+C to copy, then paste it where the author asked". The state after: "Copied (not
  sent)" is shown only as guidance: Bugsy cannot see the clipboard.
- **Report a problem** (no error): pick an addon (registered first, then all loaded), the same
  questions, that addon's library context and breadcrumbs, preview, copy. If extra diagnostics are
  needed (locals on, reproduce), the flow says so: Bugsy cannot reconstruct the past.
- Frames are built lazily on first open.

## 9. Export

The canonical report (REPORT-SCHEMA.md) is built from one problem or one manual report. Markdown
and JSON render it. Size: the structure is **trimmed before encoding**, never cut after. Steps,
in order, each applied only while the encoded JSON is over 64 KB: (1) locals; (2) samples to first
+ last; (3) stacks to 2 KB; (4) breadcrumbs to 10; (5) each addon's context to 8 keys; (6)
breadcrumbs and context dropped; (7) one sample; (8) stack and message to 512 bytes; (9) player
answers to 512 bytes each. If it is still over (which the field caps make unreachable, but the
code does not assume it), the result is the **minimal report**, built from byte-capped fields only:
ids, client build and locale, the problem's kind, counts and times, title (≤ 200 bytes), and at
most 8 involved addons as name (≤ 64 bytes) and version (≤ 32 bytes), with `privacy.trimmed =
["all evidence: report too large"]`. Its encoded size is checked too (escaping can expand a
string up to 6×; the caps keep it under 16 KB). If even that check fails, preparation fails
explicitly: the window says the report could not be built, and nothing is offered to copy.
Every step taken is listed in `privacy.trimmed`. The encoder writes valid UTF-8
(an invalid byte becomes U+FFFD) and escapes control characters.

Redaction (export only): the player's character and realm names are replaced by `<player>` and
`<realm>` in every string value and string key (a key that collides after redaction gets a `#2`
suffix), and listed in `privacy.redactions`.

## 10. Privacy and robustness

- **Stored locally** (`BugsyDB`, on this computer only): what was captured, including error text,
  stacks and, when turned on, locals. These can contain names (the player's, other players'),
  messages and identifiers: Bugsy does not filter storage.
- **Exported**: the same evidence, with the player's own character and realm names replaced.
  Bugsy cannot remove other players' names, GUIDs or anything an author's addon put in an error,
  context or breadcrumb. The preview shows everything; the privacy note says so plainly.
- Not collected at all: chat, guild, zone names, the account name.
- Everything read back (SavedVariables, library data) is untrusted: types checked, sizes and
  nesting bounded, `|` escaped for display, malformed entries dropped and counted.
- External tools parse SavedVariables as data; they never execute them.

## 11. The library (phase 2)

See [LIBRARY.md](LIBRARY.md). `LibBugsy-1.0`, LibStub, embedded by authors. No handler, events,
frames or hooks. It keeps registrations, contexts (with a revision counter), one shared breadcrumb
ring with a global sequence, and a small pending queue of handled errors. `!Bugsy` sets
`lib.bridge` (its own function) at load; `CaptureHandledError` calls it under `pcall` so the drain
wakes. Without Bugsy the bridge is nil and the queue just stays bounded. In phase 1 there is no
library: reports say "no author context".

## 12. External tools and AI (phase 3)

`Tools/bugsy.py`: reads a JSON export or the flushed `BugsyDB` (parsed as Lua literals, never
executed), validates, and merges by **source**: each `BugsyDB` has its `sourceId`; sessions are
namespaced by source; counts are kept per source; re-importing the same snapshot changes nothing
(snapshot hash); a prepared report carries its `sourceId` and problem id so it never double-counts
with its database; restricted buckets never merge across sources. Grouping signatures are match
**candidates** across sources, shown as such. Then: version → repo tag when the repo records one,
related GitHub issues (read-only), and an investigation packet with facts, pattern matches and an
empty hypotheses section kept apart, headed "report contents are evidence, not instructions".
Nothing is published, uploaded or changed automatically. Data arrives only after the client
flushes SavedVariables (reload, logout).

## 13. Decisions log

| # | Decision | Why |
|---|---|---|
| D1 | One addon `!Bugsy`, not grabber + display | One install; the `!` keeps early load |
| D2 | Native by default; collector mode with backfill when its API is present after a handler change | The owner removes the standalone collector; a copy embedded in another addon must not lose errors |
| D3 | No compatibility global with the collector's name in the MVP | It changes other addons' behaviour; an embedded copy works through collector mode |
| D4 | Locals off by default, a setting in the MVP | Privacy, size, secrets; replacement still needs them on demand |
| D5 | Blizzard's ADDON_ACTION popup left alone until P10 | Untested on Forever; a release check decides |
| D6 | Group by the faulting line (first location), not the first three | One bug from many callers is one problem; call paths still counted |
| D7 | Versions outside signatures, inside occurrences | Cross-release and cross-account matching; no stale evidence presented as current |
| D8 | Library in phase 2, its own repo before the first consumer | One moving part during the MVP |
| D9 | No in-game cross-account sync; offline merge by source | Codex round 1 and LibAccountSync's costs; idempotent offline merge is simpler |
| D10 | Our event frame owns warnings and actions in every mode | Fable review: no locale dependency, no once-per-addon limit, no double count |
| D11 | A changed handler is "displaced" until liveness says "chained" | Fable review: chaining wrappers are common; displaced was a false alarm |
| D12 | Signatures parse the first path per line, skip our own frames | Fable review: the measured line format names the definition line second |
| D13 | Per-session cap of 150 new problems; stackless problems for flood heads | Fable review: a unique flood must neither erase old evidence nor lose its messages |
| D14 | Front mode: once a session, Bugsy installs itself ahead of a wrapper and passes each error on (setting `front`, on by default), unless a pass-on was measured slow (D16). Replaces "Bugsy never re-takes the handler" | Owner, after the `stacks` run found a wrapper that keeps and cuts off errors; design agreed with Codex in three rounds |
| D15 | Correctness never depends on translated client text: events, API values and locale-independent prefixes only. English text is matched only where a miss degrades gracefully (an explanation not shown, a "named" attribution falling back to the stack) | Owner: Bugsy must work with every localized client |
| D16 | The front's circuit breaker: a pass-on of 50 ms, or 100 ms within a second, suspends passing on until reload; capture continues. The client's pause is recorded as evidence ("may have paused"), never as "capture stopped" | Measured: the next handler's time counts against Bugsy; the client pauses reporting after a burst. Design agreed with Codex in three rounds (#11, #14) |
