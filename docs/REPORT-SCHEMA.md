# Bugsy report schema, version 1

`schema = "bugsy.report/1"`. A report is one problem (or one player-reported problem) with its
evidence. The canonical form is a Lua table inside the addon; JSON is its exact rendering, and
Markdown a human rendering of the same fields. A consumer must ignore unknown fields; a change that
removes or redefines a field bumps the schema number. The SavedVariables database has its own
`format` (DESIGN §4) and is converted into this schema; it is not itself a report.

Conventions:
- Times are Unix seconds (`time()`) from the player's clock. `uptime` is `GetTime()`.
- A field Bugsy could not read is a **marker** instead of its value:
  `{ "restricted": true, "reason": "secret" | "inaccessible" }`,
  `{ "unavailable": true, "reason": "<why>" }` (not captured: locals off, tier, provider), or
  `{ "unsupported": "<type>" }` (the message was not a string or number).
- A cut string: `{ "text": "...", "truncated": true, "originalLength": 9123 }` (cut on a UTF-8
  boundary). An uncut string is a plain string.
- Facts, pattern explanations and player observations are separate top-level sections.
- A list field (`[ ... ]` below) is always a JSON array, `[]` when empty; a map (`{ [k] = v }`)
  is always an object, `{}` when empty.

## Fields

```
schema            "bugsy.report/1"
reportId          "BGY-<8 hex>-<4 hex>", random per prepared report
createdAt
generator         { addon = "Bugsy", version, sigAlgo = "g1", dbFormat = 1 }
source            { sourceId, problemId }  -- opaque; lets tools match a report to its database

client            { flavor ("forever"), version ("1.60.1"), build ("70959"), interface (16001),
                    locale, projectId }
                  -- observed when the report is prepared; each occurrence has its own build

capture           { mode ("native" | "collector" | "displaced" | "chained" | "front"),
                                     -- at preparation time; it does not describe older samples
                                     -- (each occurrence's `entry` says how it arrived)
                    handlerChanges = [ { at, afterAddon, action ("front" | absent) } ],
                    handlerChangesDropped,                           -- last 5
                    limits = [ "<text>" ],                           -- what the mode cannot do
                    localsEnabled,
                    session = { suppressed = { [kind] = n }, queueDropped,     -- this session,
                                passSuppressed,   -- front: distinct reports dropped while passing on
                                forwardFailed },  -- front: the next handler failed
                                                                     -- all problems together
                    lifetime = { evicted },
                    health = { pause = { status ("suspected" | "reported"),   -- #14: evidence,
                                         evidence ("burst" | "message" | "both"),   -- never a verdict
                                         at, session,      -- the capture session it was seen in
                                         observedCalls, deliveredAfter, noticeSeen } } | absent,
                    forward = { suspended (bool), reason ("call" | "window"), at,  -- front mode (#11)
                                elapsedMs, windowMs, thresholdMs,
                                skipped,             -- errors not passed on (not a capture loss)
                                timingUnavailable } | absent }
                  -- the minimal report keeps capture = { mode, health, forward } as bounded scalars

problem           { id, kind ("error" | "warning" | "blocked" | "forbidden" | "handled" | "manual"),
                    title, count, countIncomplete (bool: count is a lower bound),
                    unconfirmedRepeats, firstSeen, lastSeen, firstSession, lastSession,
                    sessionCount, recentSessions = [n, ≤ 3],
                    callPaths (n: distinct call paths kept, ≤ 20),
                    callPathsMore (bool: more distinct paths were seen than kept),
                    versions = { [addon] = { [ver] = n } },     -- ≤ 8 addons × 10 versions
                    addonsOverflow,
                    groupSignature, messageKey, muted, restricted, noise (bool),
                    sampledOut,                       -- occurrences counted but not kept
                    addon }                           -- manual reports: the addon the player picked

occurrences       [ {                                 -- the first 2 and the last 3 kept
                    at, atApproximate (bool), uptime, session, build,
                    provider ("native" | "collector" | "library"),
                    entry ("handler" | "front" | "event" | "collector"),  -- how it reached Bugsy
                    tier ("full" | "top"), stackOrigin ("error" | "fallback" | "report-site" |
                         "supplied" | "collector" | "none"),
                    observedAt,                       -- when Bugsy read it (differs in collector mode)
                    inCombat, instanceType, taintLog,  -- at capture; markers on a backfill
                    message, stack, locals,           -- string | cut | marker
                    exactSignature,
                    event = { name, addon, func } | nil,          -- ADDON_ACTION_* / LUA_WARNING
                    handled = { reporter, operation } | nil,      -- library CaptureHandledError
                    versions = { [addon] = version },             -- the involved addons, at drain
                    breadcrumbs = { frozenAt ("error" | "drain"), fromSeq, toSeq, lost (n),
                                    items = [ { seq, at, addon, text, data } ] } | marker,
                    context = { observed ("drain"), changedSinceError (bool),
                                values = { [addon] = { [key] = scalar } } } | marker
                  } ]

attribution       { named = { addon, source ("ADDON_ACTION" | "taint-message") } | null,
                    inStack = [ { folder, library, host } ],
                    suspect = { addon, library, confidence ("low" | "medium"),
                                evidence = [ "<text>" ] } | null }

addons            [ { name, title, version, release, commit, loaded, registered } ]
                  -- `release`/`commit` only when the author registered them; never inferred

destination       { known, url, instructions, source ("library" | "toc") }

player            { doing, happened, expected, noVisibleProblem, steps }   -- typed, ≤ 1 KB each

explanations      [ { id, rev, builds = { min, max }, confidence, summary, investigate, ref,
                      evidence = [ "<text>" ], noise } ]                 -- NOT facts

privacy           { redactions = [ "player-name", "realm-name" ], localsIncluded,
                    trimmed = [ "<step>" ],          -- what was dropped to fit 64 KB
                    note }
```

**Manual reports** (`kind = "manual"`): no signatures (`groupSignature`, `messageKey` absent),
`count = 1`, `occurrences` holds one entry with no message or stack (markers `unavailable`) and the
picked addon's context and breadcrumbs; `problem.addon` is the picked addon.

## Signatures (`sigAlgo = "g1"`)

DESIGN §4 is the rule; in short:
- Hash: two 32-bit rolling hashes (`h = (h * 33 + byte) % 2^32` from 5381, and
  `h = (h * 65599 + byte) % 2^32` from 0) as 16 hex digits.
- Computed over the captured (cut) message and the first 12 stack lines, `[C]` and tail-call
  lines skipped.
- `exactSignature = H(kind \n message \n lines)`;
  `groupSignature = H(kind \n addressless(message) \n firstLocation)`;
  `messageKey = H(kind \n addressless(head512(message)))`.
- Restricted message, readable stack: `H(kind \n "restricted" \n firstLocation)`. Both restricted:
  `H(kind \n "restricted-bucket")`.

## Markdown rendering

```
## Bugsy report BGY-1a2b3c4d-9f00
**GlassMail** · error · 14 times · first 2026-11-16 21:04, last 2026-11-17 18:22
Client Forever 1.60.1 (70959), enUS · captured natively · locals off

### What the player saw
- Doing: ...
- Happened: ...
- Expected: ...

### Error (first occurrence, build 70959, 2026-11-16 21:04 UTC)
Captured with GlassMail 1.0.0, LibGlass-1.0 3
    <message>
    <stack>

### Involved (Bugsy's reading, not a verdict)
- Named by WoW: none
- In the stack: GlassMail; LibGlass-1.0 (library, copy in GlassMail)
- Appears involved: GlassMail (medium: first addon frame from the top)
- Installed when this report was prepared: GlassMail 1.0.1

### Context and breadcrumbs (GlassMail, read when Bugsy processed the error)
...

### Possible explanation (not a diagnosis)
- secret-touch r1 (high): ...

### Not included
- locals (off) · 9 occurrences counted but not kept · your character and realm names replaced
```

Examples: [examples/](examples/), generated by `tests/test_report.lua` and compared on every run.
