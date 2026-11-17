# LibBugsy-1.0: the author library (contract, v1, phase 2)

An optional library an addon embeds to give Bugsy better reports. It works the same whether Bugsy
is installed or not: without Bugsy, calls are cheap and keep only small bounded buffers.

```lua
local Bugsy = LibStub("LibBugsy-1.0", true)
if Bugsy then Bugsy:RegisterAddon("GlassMail", { support = { url = "https://..." } }) end
```

## Rules the library keeps

- **No handler, no events, no frames, no hooks.** Only `!Bugsy` captures errors. Any number of
  embedded copies can load; LibStub keeps one table and the newest copy's functions
  (`References\Docs\EMBEDDED-LIBRARIES.md` §5: state reused in place, call-time dispatch,
  `lib.ready = MINOR` on the last line). An upgrade keeps the ring, the sequence number, the
  contexts and the pending queue: the sequence is never reset or reused.
- **Every call is safe anywhere**, combat included. It never errors on bad input: it ignores the
  call and counts it in `lib.rejected`. It never calls the author's code: input tables are read
  with `rawget`/`next` only (no metamethods), only scalars are kept.
- **Values are copied when recorded**: context and breadcrumb strings cut to 200 bytes (a handled
  error's message to 2 KB and its stack to 6 KB, the caught-error limits), finite numbers, booleans. Other
  types, secrets (checked with `issecretvalue` / `canaccessvalue`) and non-finite numbers become a
  `"<refused: type>"` marker. Later changes to the author's tables change nothing.
- **Bounded**: 64 registered addons; names and keys ≤ 64 bytes; 32 context keys an addon; one
  shared breadcrumb ring of 200 entries; 20 pending handled errors; 10 handled errors a second an
  addon.
- **Not ready** (a newer copy failed half-way, `lib.ready ~= MINOR`): every call is a counted
  no-op and returns false.
- The author chooses every field. The library reads nothing by itself.

## The API (v1)

| Call | Does |
|---|---|
| `RegisterAddon(name, info)` | `name`: the addon's folder. `info = { version?, release?, commit?, support = { url?, instructions? } }`. `version` defaults to the TOC's `Version`. `release`/`commit` only as the author states them. Registering again updates the fields given. |
| `SetContext(name, key, value)` | One diagnostic value (`nil` removes it). Each call bumps the addon's context revision. |
| `AddBreadcrumb(name, text, data?)` | One step: `text` ≤ 120 bytes, `data` an optional flat table of ≤ 6 scalars. For actions and state changes, not per frame. |
| `CaptureHandledError(name, err, info?)` | A failure the addon caught. `err`: the message (a string). `info = { stack?, operation? }`. Without `stack`, the library takes `debugstack(2)` (`stackOrigin = "report-site"`: where it was reported, not where it failed); with one, `"supplied"`. To give the failing stack, capture it in an `xpcall` handler before the stack unwinds and pass it. Queued as kind `handled`; wakes Bugsy through its bridge. |
| `ReportProblem(name)` | Opens Bugsy's "Report a problem" for this addon. `true` if Bugsy opened it, `false` if not installed. |
| `IsActive()` | `true` when Bugsy is loaded and has set its bridge. |

Deferred (not v1): `BeginOperation` / `EndOperation` (a breadcrumb with an `op` field does it
until a consumer needs more), severity, attachments.

## What Bugsy does with it

- **At an error**, the handler reads the ring's current sequence and each addon's context revision
  (integers, `rawget`). **At the drain**, it keeps the breadcrumbs with `seq ≤` that sequence: the
  last 20 of the involved addons, plus the last 5 of anyone. If entries up to that sequence were
  already overwritten (more than 200 newer ones in between), `lost` says how many and `fromSeq`
  where the kept range starts. Breadcrumbs are best-effort history, and the report says so.
- **Context is read at the drain** (`observed = "drain"`); if an addon's revision moved since the
  error, `changedSinceError = true`.
- `!Bugsy` sets `lib.bridge` at load. `CaptureHandledError` calls it under `pcall` (Bugsy's code,
  never an author's) so the drain is scheduled; Bugsy also drains the pending queue whenever its
  window opens.
- Handled errors use the same tiers, grouping and bounds as caught errors.

## Examples

```lua
-- Glass Mail: one run of Open All
Bugsy:SetContext("GlassMail", "inboxCount", n)
Bugsy:AddBreadcrumb("GlassMail", "openall start", { mails = n, filter = filter })
local stack
local ok, err = xpcall(Ops.Step, function(e) stack = debugstack(2); return e end)
if not ok then Bugsy:CaptureHandledError("GlassMail", err, { operation = "openall", stack = stack }) end

-- AltStable: a sync
Bugsy:SetContext("AltStable", "protocol", 3)
Bugsy:AddBreadcrumb("AltStable", "sync validate", { outcome = "rejected", records = 41 })
```
