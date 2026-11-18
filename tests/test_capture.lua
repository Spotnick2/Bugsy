-- Capture: the critical path (DESIGN §3, §5, §6).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local ns = loadAddon()
local C = ns.Capture
local S = C.state
ns.Store.MAX_NEW_PER_SESSION = math.huge   -- the per-session cap has its own test (test_store)

local function reset()
    drain()
    ns.Store.sessionNew = 0
    ns.Store.Clear("all", true)
    for _, b in pairs(C.buckets) do b.tokens, b.at = b.rate, nil end
    S.seen, S.seenN = {}, 0
    for k in pairs(S.stats.suppressed) do S.stats.suppressed[k] = 0 end
    S.stats.queueDropped, S.stats.drainFailed = 0, 0
    S.failures, S.nested = 0, 0
    WoW.stack = stackAt("TestAddon", "Core.lua", 10)
end

-- Recursion: a call while busy only counts.
reset()
S.busy = true
WoW.raise("nested error")
S.busy = false
eq(S.nested, 1, "a nested call is counted")
eq(C.pending(), 0, "and records nothing")

-- debugstack is called directly (a pcall around it would shift the level by one);
-- if it throws, the body's pcall counts the failure and nothing escapes.
reset()
local real = debugstack
_G.debugstack = function() error("debugstack exploded") end
local ok = pcall(WoW.raise, "error with a broken debugstack")
_G.debugstack = real
check(ok, "the handler did not throw")
eq(S.busy, false, "busy cleared after the failure")
eq(S.failures, 1, "the failure is counted")
WoW.stackCalls = {}
WoW.raise("an ordinary error")
eq(WoW.stackCalls[1].level, WoW.callHeight - (WoW.errorHeight - 1), "the level is the formula's, unshifted")
-- An error in a file's main chunk while it loads: error height 0 (measured, P5).
WoW.stackCalls = {}
local savedEh = WoW.errorHeight
WoW.errorHeight = 0
WoW.raise("an error at file scope")
eq(WoW.stackCalls[1].level, WoW.callHeight, "height 0 counts as 1: the chunk's own line, not one past the stack")
WoW.errorHeight = savedEh

-- A body that throws: counted, its readable string message kept (cut), busy cleared.
reset()
local realTier = C.tier
C.tier = function() error(string.rep("x", 500)) end
WoW.raise("will fail in the body")
C.tier = realTier
eq(S.failures, 1, "the failure is counted")
eq(#S.failureLog[#S.failureLog], 200, "its message is cut to 200 bytes")
eq(S.busy, false, "busy cleared")
WoW.raise("next error after a failure")
drain()
eq(#problems(ns), 1, "the next error is captured")

-- Unsupported messages: a table with __tostring is never called.
reset()
local called = false
local t = setmetatable({}, { __tostring = function() called = true; return "boom" end })
WoW.raise(t)
WoW.raise(true)
drain()
check(not called, "__tostring was never called")
local titles = {}
for _, p in ipairs(problems(ns)) do titles[#titles + 1] = p.title end
table.sort(titles)
eq(titles[1], "<unsupported message: boolean>", "a boolean message is labelled")
eq(titles[2], "<unsupported message: table>", "a table message is labelled")

-- Secrets: message, stack and locals become markers, each on its own.
reset()
ns.Store.db().settings.locals = true
WoW.locals = WoW.Secret("locals")
WoW.raise(WoW.Secret("message"))
drain()
local p = problems(ns)[1]
eq(p.restricted, true, "a secret message makes a restricted problem")
eq(p.first[1].message.restricted, true, "the message is a marker")
eq(p.first[1].message.reason, "secret", "marked secret")
eq(p.first[1].locals.restricted, true, "secret locals are a marker")
check(type(p.first[1].stack) == "string", "a readable stack is still kept")
check(p.title:find("Restricted message at TestAddon/Core.lua:10", 1, true), "grouped by the stack's location")
WoW.stack = WoW.Secret("stack")
WoW.raise(WoW.Secret("message 2"))
WoW.raise(WoW.Secret("message 3"))
drain()
local bucket
for _, q in ipairs(problems(ns)) do if q.bucket then bucket = q end end
check(bucket and bucket.count == 2, "both-restricted errors share the per-kind bucket")
check(bucket.title:find("may be unrelated", 1, true), "and the bucket says they may be unrelated")
ns.Store.db().settings.locals = false
WoW.locals = "x = 1"

-- Tiers: 15 full + 5 discovery for new messages, 40 top, then count only.
reset()
for i = 1, 70 do WoW.raise("same message") end
drain()
p = problems(ns)[1]
eq(#problems(ns), 1, "one problem")
eq(p.count, 15 + 40, "15 full, then 40 top (the message is no longer new, so no discovery)")
eq(p.unconfirmedRepeats, 70 - 55, "the rest are unconfirmed repeats")
local tops = 0
for _, s in ipairs(p.last) do if s.tier == "top" then tops = tops + 1 end end
check(tops <= 2, "a top sample never pushes out the last full one")
local topCall
for _, c in ipairs(WoW.stackCalls) do if c.top then topCall = c end end
eq(topCall.top, 12, "the top tier asks debugstack for 12 lines")

-- Discovery: a new message still gets a full capture after the full budget is spent.
reset()
for i = 1, 15 do WoW.raise("flood " .. 1) end
WoW.raise("brand new")
drain()
local newP
for _, q in ipairs(problems(ns)) do if q.title == "brand new" then newP = q end end
eq(newP.first[1].tier, "full", "the new message got a full capture from the discovery budget")

-- Queue bound: without a sink, at most 200 wait.
reset()
local sink = C.sink
C.sink = nil
for i = 1, 260 do
    for _, b in pairs(C.buckets) do b.tokens = b.rate end
    WoW.raise("queued " .. i)
end
eq(C.pending(), 200, "200 records wait")
eq(S.stats.queueDropped, 60, "the rest are counted as dropped")
C.sink = sink
C.schedule()
-- the drain takes 50 a pass, and reschedules
WoW.advance(0)
eq(C.pending(), 0, "every record drained across passes")
eq(#problems(ns), 200, "200 problems")

-- A failing record is dropped and counted; the rest still drain.
reset()
local realRecord = ns.Store.record
local n = 0
C.sink = { record = function(r) n = n + 1; if n == 2 then error("store broke") end; return realRecord(r) end,
    count = ns.Store.count }
for i = 1, 3 do WoW.raise("record " .. i) end
drain()
eq(S.stats.drainFailed, 1, "one failed record counted")
eq(#problems(ns), 2, "the other two stored")
C.sink = sink

-- Count map: delivered exactly once, also when an entry fails.
reset()
for _, b in pairs(C.buckets) do b.tokens = 0; b.at = WoW.now end
WoW.raise("counted a")
WoW.raise("counted a")
WoW.raise("counted b")
local _, keys = C.pending()
eq(keys, 2, "two message keys pending")
local deliveries = 0
C.sink = { record = sink.record, count = function(kind, key, num)
    deliveries = deliveries + 1
    if deliveries == 1 then error("count failed") end
    return sink.count(kind, key, num)
end }
drain()
drain()
eq(deliveries, 2, "each entry delivered once, the failed one not replayed")
_, keys = C.pending()
eq(keys, 0, "the map is empty")
C.sink = sink

-- Events: blocked/forbidden keep their fields apart; every occurrence counts.
reset()
WoW.fire("ADDON_ACTION_FORBIDDEN", "OtherAddon", "UNKNOWN()")
WoW.fire("ADDON_ACTION_FORBIDDEN", "OtherAddon", "UNKNOWN()")
WoW.fire("LUA_WARNING", "a warning")
drain()
local forbidden, warning
for _, q in ipairs(problems(ns)) do
    if q.kind == "forbidden" then forbidden = q elseif q.kind == "warning" then warning = q end
end
eq(forbidden.count, 2, "every forbidden action counts")
check(warning ~= nil, "a warning is recorded with Blizzard's warning window hidden (B-18)")
eq(WoW.routed.ADDON_ACTION_FORBIDDEN, nil, "and with Blizzard's popup route unregistered")
eq(forbidden.first[1].event.addon, "OtherAddon", "the named addon is kept")
eq(forbidden.first[1].event.func, "UNKNOWN()", "the function is kept")
eq(forbidden.first[1].stackOrigin, "event", "an event's stack is marked")
eq(forbidden.attribution.named.addon, "OtherAddon", "the client's naming is attribution's 'named'")
eq(warning.title, "a warning", "a warning is its own problem")

-- Errors before ADDON_LOADED wait, then drain into the store.
WoW.reset()
local early = loadAddon({ before = function(n2)
    n2.Capture.state.settings = { locals = false }
    WoW.stack = stackAt("TestAddon", "Early.lua", 3)
    WoW.raise("an error during loading")
end })
drain()
local ep = early.Store.List("all", true)
eq(#ep, 1, "the loading-time error reached the store")
eq(ep[1].first[1].session, BugsyDB.session, "in the current session")

-- Displacement: another handler replaces ours, without a collector API. Front mode
-- (putting Bugsy ahead of it) has its own tests (test_front); off here.
early.Capture.state.frontEnabled = false
local other = function() end
WoW.handler = other
early.Capture.check("SomeAddon")
eq(early.Capture.state.mode, "displaced", "displaced, not native")
eq(early.Capture.state.changes[#early.Capture.state.changes].afterAddon, "SomeAddon", "the change is recorded with the addon")
early.Capture.check("SomeOtherAddon")
eq(#early.Capture.state.changes, 1, "an unchanged displacement is not recorded again")
eq(WoW.handler, other, "Bugsy never re-takes the handler")
check(early.Capture.limits()[1]:find("may not see", 1, true), "displaced is stated as uncertain")

-- A chaining wrapper (some UI suites and addons install one): the
-- next error still reaches us, so the mode becomes "chained", not blind.
local ours = early.Capture.handler
WoW.handler = function(msg) return ours(msg) end
early.Capture.check("Wrapper")
WoW.raise("through the wrapper")
eq(early.Capture.state.mode, "chained", "errors arriving through a wrapper: chained")
early.Capture.drain()
local through
for _, q in ipairs(early.Store.List("all", true)) do if q.title == "through the wrapper" then through = q end end
check(through, "and the error is recorded")

-- The other order (Codex round 5): a wrapper installed, its first error arrives
-- BEFORE any check notices the change. The check must then say chained.
WoW.handler = ours
early.Capture.state.mode = "native"
early.Capture.state.lastHandler = ours
local wrapper2 = function(msg) return ours(msg) end
WoW.handler = wrapper2
WoW.raise("first error through a fresh wrapper")
early.Capture.check("drain")
eq(early.Capture.state.mode, "chained", "the check keeps the liveness already observed")

-- From displaced, the collector's API appearing later is used.
WoW.handler = function() end
early.Capture.check("Another")
eq(early.Capture.state.mode, "displaced", "displaced again")
rawset(_G, COLLECTOR.global, { GetDB = function() return {} end, GetErrorByID = function() end, GetSessionId = function() return 1 end })
early.Capture.check("HostAddon")
eq(early.Capture.state.mode, "collector", "displaced -> collector when its API appears")
rawset(_G, COLLECTOR.global, nil)

-- seterrorhandler made a no-op before we load: the first change is recorded too.
WoW.reset()
local realSet = seterrorhandler
seterrorhandler = function() end
local noop = loadAddon()
seterrorhandler = realSet
eq(noop.Capture.state.mode, "displaced", "no-op setter: displaced from the start")
eq(#noop.Capture.state.changes, 1, "and that first change is recorded")

-- Floods of DISTINCT messages past the budget keep their text (stackless problems).
WoW.reset()
local fl = loadAddon()
for i = 1, 100 do WoW.raise("distinct flood message " .. i) end
drain()
local kept, stackless = 0, 0
for _, q in ipairs(fl.Store.List("all", true)) do
    kept = kept + 1
    if q.first[1].stackOrigin == "none" then stackless = stackless + 1 end
end
eq(kept, 100, "every distinct message keeps its text")
eq(stackless, 100 - 60, "those past the budget as stackless problems")

-- The scheduling watchdog: a timer that never fires does not stop the drain for good.
local FS = fl.Capture.state
FS.scheduled, FS.scheduledAt = true, WoW.now
WoW.timers = {}                 -- the scheduled timer vanished
WoW.now = WoW.now + 2
for _, b in pairs(fl.Capture.buckets) do b.tokens = b.rate end
WoW.raise("after a lost timer")
drain()
local found
for _, q in ipairs(fl.Store.List("all", true)) do if q.title == "after a lost timer" then found = q end end
check(found, "a stale flag is re-armed by the next error")

-- A FULL queue with a lost timer: a dropped record must still reach the watchdog.
local sinkSaved = fl.Capture.sink
fl.Capture.sink = nil
for i = 1, 200 do
    for _, b in pairs(fl.Capture.buckets) do b.tokens = b.rate end
    WoW.raise("fill " .. i)
end
eq(fl.Capture.pending(), 200, "the queue is full")
fl.Capture.sink = sinkSaved
FS.scheduled, FS.scheduledAt = true, WoW.now
WoW.timers = {}                 -- the pending drain is lost
WoW.now = WoW.now + 2
for _, b in pairs(fl.Capture.buckets) do b.tokens = b.rate end
WoW.raise("dropped, but it re-arms")
drain()
eq(fl.Capture.pending(), 0, "the full queue drained after a dropped record re-armed the watchdog")

done("test_capture")
