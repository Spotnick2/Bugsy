# What Bugsy relies on: verified, measured, and still open

Bugsy is built on how the Forever client hands errors to addons. Every claim here is one of three
kinds, and is labelled:

- **[source]** read in code: Blizzard's UI source (`C:\Projects\WoW\wow-ui-source`, branch `forever`,
  build **70938**), the API dump (`References\Forever\api\forever-api-1.60.1.70959.md`, the newest), or
  the reference addons (other error collectors and viewers, read for their behaviour only; no code
  copied).
- **[game]** measured in game, with the build.
- **[open]** an assumption that needs a probe (BugsyProbe, `/fp bugsy`) before anything depends on it.

The UI source clone is 70938 and the newest dump is 70959. The dump lines for the functions and
events below (`GetErrorCallstackHeight`, `GetCallstackHeight`, `debugstack`, `debuglocals`,
`seterrorhandler`, `issecretvalue`, `canaccessvalue`, `LUA_WARNING`, `ADDON_ACTION_BLOCKED`) are
identical in 70938 and 70959. That is checked again when the probe runs.

## 1. Blizzard's own handler

- **[source]** `Blizzard_ScriptErrors.lua` calls `seterrorhandler(HandleLuaError)` at its load. The
  handler gets the stack with `debugstack(GetCallstackHeight() - (GetErrorCallstackHeight() - 1))`,
  and locals with `debuglocals(level, true)` (functions and userdata skipped).
- **[source]** `AddLuaErrorHandler(fn)` asserts `issecure()`. Addons cannot join Blizzard's list of
  handlers. Blizzard's frame (`ScriptErrorsFrame`) registers through it. An addon that wants errors
  replaces the handler with `seterrorhandler`, as the common error collector does. This is a constraint on *how* to
  capture, not by itself an argument for replacing the handler: the provider decision (DESIGN §3)
  rests on the coexistence facts below too.
- **[source]** Blizzard logs the formatted message only when `canaccessvalue(formattedMessage)`.
  Tainted code can throw a message that is a secret value.
- **[source]** `ScriptErrorsFrameMixin:DisplayMessageInternal` turns off duplicate matching when
  the message key `issecretvalue`. Their comment: a secret key either throws in tainted code, or,
  from untainted code, leaves the `seen` table forbidden so no tainted code can report an error
  through it again. **Any table keyed by error text must check the key first.**
- **[source]** The secret API in the dump: `issecretvalue`, `issecrettable`, `canaccessvalue`,
  `canaccesstable`, `canaccessallvalues`, `canaccesssecrets`, `scrub`, `scrubsecretvalues`,
  `secretwrap`. All `[FrameScript]`. Also `C_StringUtil.EscapeDecimalNonPrintables`,
  `GetErrorCallstackHeight() -> optional number`, `GetCallstackHeight()`.
- **[source]** `ScriptErrorsFrame` registers `LUA_WARNING` itself.
- **[open]** Whether `issecretvalue` alone is the right test for "can I read this", or
  `canaccessvalue` is needed (they differ: a value can be non-secret yet inaccessible?). Probe P1.

## 2. The common error collector (what it does on Forever)

"The collector" below is the most widely used error-collecting addon; "its viewer" is the addon
that displays what it collects. Bugsy reads the collector's public API in collector mode
(`Capture.COLLECTOR`: its global and its per-error event).

- **[source]** TOC Interface includes `16001`; `LoadSavedVariablesFirst: 1`. Owner has run it on
  Forever since beta day one **[game, owner]**.
- **[source]** Secret handling exists: a secret message (after `tostring`) is **printed to chat and
  not stored**; a secret stack is replaced by `"debugstack() returned secrets."`, secret locals by
  `"debuglocals() returned secrets."`. Checks use `issecretvalue` only.
- **[source]** Stack depth: Blizzard's formula, and `debugstack(3)` when `GetErrorCallstackHeight()`
  is nil.
- **[source]** Grouping: exact message string, found by a linear scan from the newest of up to
  500 entries. Stack and locals of a repeat are refreshed only on a new
  session or after 120 s.
- **[source]** Flood: a token bucket of `10` errors a second. Past it, **every** error is dropped
  until the bucket refills, with a chat warning every 10 s. Nothing counts what was dropped.
- **[source]** Locals: `debuglocals(level)` (functions and userdata *included*), always captured,
  no size cap.
- **[source]** `ADDON_ACTION_BLOCKED` / `ADDON_ACTION_FORBIDDEN`: recorded **once per addon name per
  session** (later ones, other functions included, are dropped). It unregisters them from
  `UIParent` and `GameEvent` (Blizzard's "interface action failed" popup), and `LUA_WARNING` from
  `ScriptErrorsFrame`. `LUA_WARNING` is stored as a "simple" error, without a stack. Its copies of
  warnings and actions start with `LUA_WARNING: ` and `[ADDON_ACTION_` in every locale.
- **[source]** It then calls the real `seterrorhandler` with its own handler and replaces the global
  `seterrorhandler` with a no-op. **After the collector loads, nobody else can install a handler.**
- **[source]** Embedding: other addons may embed a copy of the collector. The copy runs unless the
  standalone collector is enabled, and bails if the collector's global exists (a read-only proxy).
  **At least one popular Forever addon embeds it**, so removing the standalone collector can leave
  that addon's copy taking the handler, later in the load than a `!`-named addon.
- **[source]** Public surface others use: a per-error `EventRegistry` event (`tableID`) and a
  display-registered one; `GetErrorByID`, `GetDB`, `GetSessionId`, `IsPaused`, `StoreError`,
  `Reset`, `GetChatLink`; a TOC metadata field for displays. Several addons among the references
  consume it.
- **[source]** Error object: `{ message, stack, locals, session, time, counter }`; `counter` grows
  across sessions.

## 3. Its viewer

- **[source]** A display only: everything comes from the collector. Shows one error at a time with
  Next/Previous, session tabs, a text filter, sound and an optional chat line. It escapes
  non-printables (`C_StringUtil.EscapeDecimalNonPrintables`) and colours the stack.
- **[source]** No grouping beyond the collector's, no attribution, no context, no report flow. It can
  send bugs to another player over addon comms (Bugsy does not: privacy, and not a support
  channel).

## 4. Other handlers in the wild

- **[source]** Ace3 (and many libraries) report errors they caught with `geterrorhandler()(err)`:
  AceAddon, AceGUI, AceConfigDialog, AceBucket, CallbackHandler. These reach the global handler
  **without a real Lua error in progress**, so `GetErrorCallstackHeight()` is likely nil there
  **[open, P2]**.
- **[source]** Some UI suites and large addons wrap the previous handler and call it after their
  own (Bugsy's "chained" mode); one has its own error handling and listens to the collector when
  present.

## 5. Facts from the porting guide that shape attribution and explanations

- **[game, 69913]** `ADDON_ACTION_BLOCKED` is blamed on whichever addon's taint the call path
  carries; the addon at fault may appear only in the stack.
- **[game, 69977]** `ADDON_ACTION_FORBIDDEN` from `TargetUnit(name, true)` arrives as
  `(addonName, "UNKNOWN()")`.
- **[game, 70450]** With `/console taintLog 1`, Blizzard code calls nil methods on methods addons
  hooked. Those errors come from the logging. Bugsy labels them as suspected noise; it never hides
  them.
- **[game]** Secret values throw when compared or truth-tested, with messages such as
  *"attempt to perform boolean test on field 'x' (a secret boolean value)"* and
  *"attempt to perform arithmetic on a secret number value (execution tainted by 'X')"*.
- **[game]** `C_UnitAuras.GetAuraDataByIndex` in combat raises *"Auras cannot be accessed when
  secret while tainted by '<addon>'"*.

## 6. Open questions for BugsyProbe

Each becomes a `Probe:Steps` procedure or command. None of Bugsy's behaviour that depends on one
ships as "verified" until it is measured.

| # | Question | Why it matters |
|---|---|---|
| P1 | For an error from tainted code that touched a secret: are the message, `debugstack()` and `debuglocals()` each accessible, secret, or inaccessible? Do `issecretvalue` and `canaccessvalue` agree? | Which fields Bugsy can keep; the opaque bucket |
| P2 | `GetErrorCallstackHeight()` for: a plain `error()`, a runtime error, `geterrorhandler()(msg)` called directly, an error inside `pcall`/`xpcall` with our handler, an error in a `C_Timer` callback and an `OnEvent` script | The stack level formula and its fallback |
| P3 | `LUA_WARNING` payloads and frequency over a normal session | Whether to keep them in the main list |
| P4 | `ADDON_ACTION_BLOCKED` / `FORBIDDEN` payloads for common calls (a protected frame `Hide` in combat, `TargetUnit`, `SetRaidTarget`); does `function` ever carry more than `UNKNOWN()`? | Attribution of blocked actions |
| P5 | Errors before our `ADDON_LOADED`: from an addon loaded before `!Bugsy`, from our own files, from a later addon's file scope. Is `LoadSavedVariablesFirst` honoured on Forever (our SV readable at file scope)? | Early capture |
| P6 | Combat lockdown: does running our handler, writing our tables and scheduling `C_Timer.After(0)` from it raise any blocked action or taint line? | The critical path must be clean |
| P7 | Coexistence: the standalone collector loaded; only an embedded copy; neither. Which handler wins, when, and does the collector's per-error event reach us in each case? | Provider switching |
| P8 | Flood: 1 000 identical errors in one frame, and 1 000 unique ones. Frame time, memory, what survives | Budgets |
| P9 | An error inside our own handler (forced): does the client recurse, swallow, or fall back to Blizzard? | The recursion guard |
| P10 | Does unregistering `ADDON_ACTION_*` from `UIParent`/`GameEvent` and `LUA_WARNING` from `ScriptErrorsFrame` taint anything on Forever? | Whether Bugsy suppresses Blizzard's popups as the collector does |
| P11 | `geterrorhandler()` identity: after we install, does it return our function, and can we tell when someone replaced it? | Detecting a takeover |
| P12 | Clipboard and EditBox: does Ctrl+C from a read-only multi-line EditBox give back `\|` sequences, tabs, UTF-8 and a 60 KB text exactly as set? How long does `SetText` take for 64 KB? | Export fidelity |
| P15 | Localization: on a non-English client, are the client-generated texts Bugsy matches translated? `(a secret ... value, while execution tainted by 'X')`, `tainted by 'X'`, `Auras cannot be accessed when secret`, `UNKNOWN ERROR`. Lua core messages and stack lines are expected to stay English. | Only explanations and the "named" attribution depend on them (D15); correctness must not |

Added after Codex round 1:
- **P2** also measures the real structure: the handler body inside `pcall`, the level computed in
  the body, stack and locals checked separately; a library-style report site (`debugstack(2)` after
  a `pcall`); and the stack of an `ADDON_ACTION_*` / `LUA_WARNING` event handler.
- **P5/P6**: a `C_Timer.After(0)` scheduled during file loading: when does it run relative to
  `ADDON_LOADED`, is our saved table there yet, and what happens while records remain.
- **P7**: errors raised between an embedded copy's takeover and our next `ADDON_LOADED` (the
  backfill window), repeats while the collector's counter changes, duplicate warnings/actions during
  the switch. Each variant in a fresh `/reload`: the collector's no-op `seterrorhandler` makes
  restoring a handler in the same session impossible for code that did not keep the original
  setter (the probe). Bugsy never uses a cached setter: front mode (D14) calls the current one,
  so a collector's no-op setter simply makes the front attempt fail.
- **P8**: sustained floods across many frames, very large message strings, and (with Bugsy
  loaded) all-muted capacity and the quality of the first-2/last-3 samples.
- **P9**: a failure in the scheduling call and in the recovery path; `busy` resets and the next
  error is still captured.
- **P1**: also event arguments and library values, not only the diagnostic strings.

Added after the Fable review (2026-11-17):
- **P2** also raises an error through a chaining wrapper (`geterrorhandler()` captured, a wrapper
  installed that calls it) and inside an `OnEvent` script. The probe calls `debugstack` and
  `debuglocals` **directly**, as Bugsy does: through `pcall` every level would be one short.
- **P13**: the probe saves the first 12 lines of real stacks (`records[i].fixture`). They become
  the parser's test fixtures before g1 is frozen: a later `sigAlgo` bump orphans problems and mutes.
- **P14**: `GetTime()` inside one frame and during loading (each record's `time`): the token
  buckets refill by it.
- **P7** also covers a chaining wrapper, a handler replaced after login (seen at the next drain),
  and the standalone collector loading before `!Bugsy`. A non-English client is not measurable
  here; the design no longer depends on the collector's localised text.
- **Assumption made explicit**: a scheduled `C_Timer.After(0)` fires. Bugsy re-arms a flag older
  than a second anyway (watchdog), so a lost timer delays the drain, never stops it.

Limits of what can be measured:
- A native handler cannot capture an error raised **before it was installed**. P5's
  earlier-addon case establishes that boundary; it cannot show retroactive capture.
- **P3** needs an observation period (a play session with the passive listener on); no warnings
  seen is inconclusive, not "never".

## 7. Measured

Results go here with the build, and addon-agnostic ones in
`References\Docs\PORTING-TBC-TO-FOREVER.md`.

### `stacks` (P2, P11, P13; P14 in part): build 70959, 2026-11-17

The probe's measuring handler, installed alone, calls `debugstack` directly, so level 1 is the
handler. `callH` = `GetCallstackHeight()`, `errH` = `GetErrorCallstackHeight()`, both read in the
handler; "site" = the level where the error's own line is.

| Raise path | callH | errH | Formula `callH - (errH - 1)` | Site | |
|---|---|---|---|---|---|
| `error()` in a function | 5 | 2 | 4 | 4 | exact |
| runtime error | 4 | 2 | 3 | 3 | exact |
| in `OnUpdate` | 3 | 1 | 3 | 3 | exact |
| through `securecallfunction` | 7 | 4 | 4 | 4 | exact |
| in `OnEvent` (fired from a key binding) | 6 | 3 | 4 | 4 | exact |
| through a chaining wrapper that **tail-calls** the next handler | 4 | 1 | 4 | 5 | one short: level 4 is `[C]: in function 'error'` |
| `geterrorhandler()(msg)` called directly | 3 | nil | — | 2 (the caller) | fallback |
| the handler as `xpcall`'s message handler | 6 | nil | — | 3 (2 is `[C]: in function 'error'`) | fallback |
| an error inside `pcall` | — | — | — | — | the handler is never called |

- **[game, 70959]** **P2: the formula holds** wherever `GetErrorCallstackHeight()` is a number.
  It is nil for a direct `geterrorhandler()(msg)` call (the library-report case) and for `xpcall`.
  `GetCallstackHeight` and `debugstack` both count C frames (`[C]: ?`, `[C]: in function 'error'`).
- **[game, 70959]** A tail-calling wrapper leaves a `[tail call]: ?` frame that `debugstack` counts
  and `GetCallstackHeight` does not, so the formula lands one level short, on the `'error'` C frame.
  Harmless for Bugsy: leading C frames are skipped before the signature, so the problem is the same
  as without the wrapper (test_fixtures). The spelling is `[tail call]`, not Lua 5.1's `(tail call)`.
- **`FALLBACK_LEVEL = 4` is confirmed.** Bugsy calls `debugstack` from its body, which runs as
  handler → `pcall` → body: two levels deeper than the probe's handler (the body, and `pcall`'s C
  frame). A direct call's caller is probe level 2, so Bugsy level 4. For `xpcall`, Bugsy level 4 is
  the `'error'` C frame and 5 the site; the C frame is skipped. The formula path shifts by the
  same two levels on both sides (`GetCallstackHeight` is read in the body too).
- **[game, 70959]** **P11:** a handler set with `seterrorhandler` is returned by
  `geterrorhandler()` and compares equal (`settable=true`), and restoring the previous one gives it
  back (`sameAfterRestore=true`). Bugsy's change detection by identity works.
- **[game, 70959]** **P13:** the frame lines are the measured shape
  (`[Interface/AddOns/X/f.lua]:158: in function <Interface/AddOns/X/f.lua:158>`), joined by `\n`.
  A key binding's chunk appears as `[CAMERAORSELECTORMOVE]:4: in function <[string
  "CAMERAORSELECTORMOVE"]:1>`, which is not a location. The six stacks are fixtures in
  `tests/test_fixtures.lua`.
- **P14, in part:** the ten experiments ran 0.1 s apart, so `GetTime()` advanced between records
  (37489.857 → 37490.669), as expected. Its behaviour *within* one frame (the token buckets'
  question) needs the `floods` procedure.
- No Blizzard error window or chat line appeared (owner).

**Found in the owner's setup:** at the start of the run Bugsy was already **displaced** with no
collector present. An installed addon wraps the error handler after Bugsy loads when no standalone
collector is running, then passes other errors on by a tail call. Read in its source, the wrapper
also: converts the message with `tostring` before passing it on; **keeps its own errors** (those
naming it, outside its libraries) and does not pass them on; and **stops passing anything on**
after about 1 000 errors that are not its own, more than 10 s after startup. So in this setup
Bugsy runs in chained mode, cannot see that addon's own errors, and goes blind after a flood. The
`floods` procedure would trigger that limit: run it with that addon disabled, or as a deliberate
measurement of the limit. **Owner decision (2026-11-17):** Bugsy puts itself in front of such a
wrapper and passes each error on (front mode, DESIGN §3, D14). Its in-game checks are the `front`
and `frontown` procedures (P7, P6).

### `secrets` (P1): build 70959, 2026-11-17

Three errors raised by tainted code (the probe) in combat, inside a player `UNIT_AURA` handler,
each reaching the probe's measuring handler alone. Blizzard showed nothing (owner).

| Experiment | Message | Stack | Locals |
|---|---|---|---|
| truth test on a field of the `UNIT_AURA` payload | readable: `...:233: attempt to perform boolean test on local 'x' (a secret boolean value, while execution tainted by 'BugsyProbe')` | readable | readable (828 bytes) |
| `error(payload)`, a table from the payload as the message | readable: the string `UNKNOWN ERROR` | readable | readable |
| `C_UnitAuras.GetAuraDataByIndex("player", 1)` | readable: `GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted by 'BugsyProbe'` then a second line `Lua Taint: BugsyProbe` | readable | readable |

- **[game, 70959]** In all three, `issecretvalue` was false and `canaccessvalue` true for the
  message, the stack and the locals: they agree. **No secret message, stack or locals reached the
  handler** in these cases. The payload table itself was neither secret nor inaccessible; its
  field was a secret boolean.
- **[game, 70959]** The secret-boolean message has a new wording, `(a secret boolean value, while
  execution tainted by 'X')`. The `secret-touch` pattern and the "tainted by" attribution match it
  (test_fixtures).
- **[game, 70959]** An error whose value is a (payload) table arrives as the string `UNKNOWN
  ERROR`, not as the table: such errors group by their first location, one problem per place.
  Whether a plain, non-secret table also becomes `UNKNOWN ERROR` is not measured.
- **[game, 70959]** The aura error's second line, `Lua Taint: <addon>`, stays out of the title
  (the first line).
- **Still open (P1):** an error whose message *is* a secret (Blizzard's source guards for it)
  was not produced; Bugsy's markers for it remain defensive and unmeasured. Locals of code that
  touched combat data were readable here; whether `debuglocals` prints secret values inside them
  (and how) is not visible from the saved head.

### `combat` (P6): build 70959, 2026-11-17

- **[game, 70959]** An error raised by a timer in combat reached the probe's measuring handler
  (`InCombatLockdown()` true). The handler wrote its tables and scheduled a `C_Timer.After` from
  inside itself; that timer ran (1 of 1). No `ADDON_ACTION_BLOCKED` appeared afterwards (owner).
  So writing tables and scheduling the drain from the handler in combat is clean.
- **Not covered:** `taintLog` was off, so taint lines from the handler were not looked for. The
  front design's `frontown` procedure runs with `taintLog` on and covers that (and installing a
  handler in combat).

### Front mode: what the procedures check (P7, P6)

- `front` (the wrapper addon enabled, no collector, fresh reload): Bugsy is in front at the
  start; an ordinary error, one matching the wrapper's own-error filter (the word typed with
  `/fp bugsy keyword`), one with locals, and a direct report are each recorded, with the raise
  site as the first location; 1 100 errors past the wrapper's cutoff, then a marker still
  recorded (its tier noted).
- `frontown` (the wrapper addon disabled, `taintLog 1`, fresh reload): in combat, the probe
  installs its own chaining wrapper and Bugsy installs itself in front of it **in combat**; a
  real error and a direct report, with the probe's wrapper recording the error height, call
  height and stack it sees downstream (offsets documented from the result); a distinct report
  made by that wrapper while handling one is dropped (`passSuppressed` +1; the wrapper's
  normal pass-back counts as `passReturned`); a throwing wrapper is counted (`forwardFailed`) and the next error is
  still recorded; a later wrapper saving the front gets no second front and the error is recorded
  once. Afterwards the taint log (`Logs\taint.log`) is read for lines naming Bugsy or the probe.

### `front` and `frontown` (P7, P6): build 70959, 2026-11-17

Run on the front-mode branch before the `passReturned` split (`passSuppressed` then also counted
the wrapper's pass-backs). Both procedures: all checks passed.

**`front`** (the wrapper addon enabled, no collector, fresh reload):
- **[game, 70959]** Bugsy was in front at the start (`mode=front`, installed after the wrapper
  addon's load). An ordinary error, an error matching the wrapper's own-error filter, an error
  with locals (kept) and a direct report were each recorded once, `entry=front`, full tier, with
  the raise site as the first location (the direct report: its caller).
- **[game, 70959]** 1 100 identical errors over about 2 s: the wrapper passed **1 000** back
  (`passSuppressed` = 1 000 at the end, all pass-backs then) and stopped: its cutoff, measured.
  Bugsy kept capturing: 173 occurrences sampled at full or top tier, the rest counted, and a
  marker raised afterwards was recorded at full tier. That addon showed nothing (owner).

**`frontown`** (the wrapper addon disabled, `taintLog 1`, fresh reload, in combat):
- **[game, 70959]** Bugsy installed its front ahead of the probe's wrapper **in combat**, from
  the drain's check, within a second of the first error. No blocked action or "interface action
  failed" message (owner), and nothing was written to `Logs\taint.log` while `taintLog` was 1
  (Bugsy recorded the CVar as `"1"` with these errors; the file's last write predates the run).
- **[game, 70959]** **Downstream stack levels hold for real errors:** the probe's wrapper, called
  through the front, computed its level with Blizzard's formula and landed on the raise site
  (`callH` 6, `errH` 1, level 6; 4 before the front existed). The front and its `pcall` add two
  levels to both sides. For a **direct report** (no error height) a handler using a fixed level
  sees Bugsy's frames: `debugstack(2)` starts `[C]: ?`, then `!Bugsy/Capture.lua` (the front),
  then the caller: the documented offset.
- **[game, 70959]** A distinct report made by the wrapper while handling an error was not
  recorded and was counted. A wrapper that threw was counted (`forwardFailed` 1) and the next
  error was still recorded. A later wrapper saving the front: the error was recorded once,
  through the later wrapper, the front and the first wrapper; no second front; mode chained.
  Behind that later tail-calling wrapper the downstream stack started with `[C]: in function
  'error'` (the measured one-level shift).

### The `early` run hung the client (2026-11-17): a probe bug, and what it showed about front mode

- **Probe bug (fixed):** a record stored before `ADDON_LOADED` lives in the saved table already
  (`LoadSavedVariablesFirst`), and the probe's boot then appended that table to itself while
  iterating it: an endless loop (the client grew to about 7 GB and stopped responding). The
  arming flag was never saved as cleared, so every reload hung again.
- **[game, 70959] Front mode charges the next handler's time to Bugsy.** During that session Bugsy
  recorded **85** `LUA_WARNING`s `insecure scripts exceeded execution limit for addon !Bugsy`
  (location `!Bugsy/Capture.lua:-1`), and several `script ran too long` errors. The slow code was
  downstream: the wrapper addon passed each error to the probe's measuring handler, whose
  `table.remove(list, 1)` on the runaway table took seconds. Because the front calls the next
  handler from inside its own call, the client counted that time against `!Bugsy`. Open: what the
  client does to an addon past that limit (only a warning, or its scripts stop), and whether Bugsy
  should bound or stop passing on to a next handler that keeps exceeding it.
