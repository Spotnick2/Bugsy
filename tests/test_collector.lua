-- Collector mode (DESIGN §3, "Backfill and counting"): another error collector
-- holds the handler and Bugsy reads its public API. The stand-in mirrors that
-- collector's behaviour as read in its source: error objects whose counter grows
-- across sessions, a session field moved on a repeat, the per-error EventRegistry
-- callback (tableID) fired synchronously, and seterrorhandler made a no-op.
-- None of its code is used. Its public names come from the stub (COLLECTOR).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function setCollector(v) rawset(_G, COLLECTOR.global, v) end

local function standIn(session)
    local bg = { db = {}, session = session }
    function bg:GetDB() return self.db end
    function bg:GetSessionId() return self.session end
    function bg:GetErrorByID(id) for _, e in ipairs(self.db) do if tostring(e) == id then return e end end end
    -- one grab: a repeat bumps counter and moves session; a new one is stored
    function bg:Grab(message, stack)
        local obj
        for _, e in ipairs(self.db) do if e.message == message then obj = e end end
        if obj then obj.counter = obj.counter + 1; obj.session = self.session
        else
            obj = { message = message, stack = stack or stackAt("TestAddon", "Core.lua", 7), session = self.session,
                time = WoW.clock, counter = 1 }
            table.insert(self.db, obj)
        end
        EventRegistry:TriggerEvent(COLLECTOR.event, tostring(obj))
        return obj
    end
    return bg
end

-- 1. A standalone collector present at our file load (it loads first by name).
local bg = standIn(5)
table.insert(bg.db, { message = "yesterday", stack = stackAt("TestAddon", "Old.lua", 1), session = 4, time = 1, counter = 100 })
table.insert(bg.db, { message = "today before us", stack = stackAt("OtherAddon", "o.lua", 2), session = 5, time = 2, counter = 7 })
setCollector(bg)
seterrorhandler(function() end)
local realSet = seterrorhandler
seterrorhandler = function() end            -- the collector's no-op
local ns = loadAddon()
local C, Store = ns.Capture, ns.Store
eq(C.COLLECTOR.global, COLLECTOR.global, "Capture and the stub name the same global")
eq(C.COLLECTOR.event, COLLECTOR.event, "and the same event")
eq(C.state.mode, "collector", "collector mode at file load")
drain()
local function byTitle(t)
    for _, p in ipairs(Store.List("all", true)) do if p.title == t then return p end end
end
eq(byTitle("yesterday"), nil, "an object from another session counts nothing at its seed")
local today = byTitle("today before us")
eq(today.count, 1, "an object already in this session counts one")
eq(today.countIncomplete, true, "and is marked as a lower bound")
eq(today.first[1].inCombat.reason, "backfill", "backfilled facts are markers")
eq(today.first[1].atApproximate, true, "its time is approximate")
eq(today.first[1].provider, "collector", "provenance says collector")

-- Live: yesterday's object repeats today: counted once (the delta), not 101.
WoW.combat = true
bg:Grab("yesterday")
drain()
local y = byTitle("yesterday")
eq(y.count, 1, "a repeat of yesterday's error counts one, not its whole counter")
eq(y.countIncomplete, nil, "exact after the seed")
eq(y.first[1].inCombat, true, "a live read has real occurrence-time facts")
WoW.combat = false
bg:Grab("yesterday"); bg:Grab("yesterday")
drain()
eq(byTitle("yesterday").count, 3, "every live repeat counts exactly once")

-- Evidence is copied, not referenced.
local obj = bg.db[1]
obj.stack = stackAt("TestAddon", "Old.lua", 1, "REWRITTEN BY A LATER REPEAT")
check(not byTitle("yesterday").first[1].stack:find("REWRITTEN", 1, true), "a stored sample keeps the stack it had")

-- A reset counter re-seeds (counts one only if in this session).
obj.counter = 1
bg:Grab("yesterday")
drain()
eq(byTitle("yesterday").count, 4, "a reset re-seeds: one more for this session")

-- Warnings and actions: our event frame owns them in every mode; the collector's
-- copies (in any locale: the "[%s] " prefix) are skipped, so nothing doubles.
WoW.fire("LUA_WARNING", "direct warning")
WoW.fire("ADDON_ACTION_BLOCKED", "OtherAddon", "Hide()")
bg:Grab("LUA_WARNING: direct warning", "")
bg:Grab("[ADDON_ACTION_BLOCKED] L'AddOn 'OtherAddon' a tenté d'appeler la fonction protégée 'Hide()'.", "")
drain()
local w = byTitle("direct warning")
eq(w and w.kind, "warning", "the warning comes from our frame")
eq(w and w.count, 1, "and is not doubled by the collector's copy")
eq(byTitle("LUA_WARNING: direct warning"), nil, "the collector's warning copy is skipped")
local blocked, blockedN = nil, 0
for _, p in ipairs(Store.List("all", true)) do if p.kind == "blocked" then blocked = p; blockedN = blockedN + 1 end end
eq(blockedN, 1, "one blocked problem, the localised copy skipped")
local copies = 0
for _, p in ipairs(Store.List("all", true)) do
    if p.title:sub(1, 14) == "[ADDON_ACTION_" or p.title:sub(1, 13) == "LUA_WARNING: " then copies = copies + 1 end
end
eq(copies, 0, "no collector copy of a warning or action becomes a problem of any kind")
eq(blocked and blocked.first[1].event.addon, "OtherAddon", "a blocked action keeps its addon")
eq(blocked and blocked.first[1].event.func, "Hide()", "and its function")
check(#C.limits() > 0, "the mode's limits are stated")

-- A brand-new error seen live is exact, not "at least".
bg:Grab("fresh today")
drain()
eq(byTitle("fresh today").countIncomplete, nil, "a new object seen live counts exactly")

-- Locals follow Bugsy's setting even though the collector always captures them.
local withLocals = bg:Grab("has locals")
withLocals.locals = "secretPassword = 'hunter2'"
bg:Grab("has locals")
drain()
local hl = byTitle("has locals")
eq(hl.last[1] and hl.last[1].locals.reason or hl.first[#hl.first].locals.reason, "off", "locals off: not copied")
check(not tostring(hl.first[#hl.first].locals.text or ""):find("hunter2", 1, true), "the value never reaches the store")

-- 2. Native, then a copy embedded in another addon takes over later.
WoW.reset()
seterrorhandler = realSet
setCollector(nil)
EventRegistry._cb = {}
local ns2 = loadAddon()
local C2 = ns2.Capture
eq(C2.state.mode, "native", "native without a collector")
WoW.raise("native before the takeover")
drain()
local bg2 = standIn(9)
-- the embedded copy installs during its host's load, catches an error, notifies nobody yet
seterrorhandler(function() end)
setCollector(bg2)
bg2:Grab("caught in the window")
table.insert(bg2.db, { message = "LUA_WARNING: in the window", stack = "", session = 9, time = 3, counter = 1 })
WoW.fire("ADDON_LOADED", "HostAddon")
eq(C2.state.mode, "collector", "switched at the next ADDON_LOADED")
eq(C2.state.changes[#C2.state.changes].afterAddon, "HostAddon", "the change is recorded after the host")
drain()
local function byTitle2(t)
    for _, p in ipairs(ns2.Store.List("all", true)) do if p.title == t then return p end end
end
eq(byTitle2("caught in the window").count, 1, "the window's error is backfilled")
eq(byTitle2("LUA_WARNING: in the window"), nil, "warnings are not backfilled")
check(byTitle2("native before the takeover"), "the native capture is kept")
bg2:Grab("caught in the window")
drain()
eq(byTitle2("caught in the window").count, 2, "a live repeat after the switch counts once")

-- A secret locals field (locals on) becomes a marker; the occurrence is not dropped.
ns2.Store.db().settings.locals = true
local sec = bg2:Grab("secret locals")
sec.locals = WoW.Secret("collector locals")
bg2:Grab("secret locals")
drain()
local sl = byTitle2("secret locals")
eq(sl and sl.count, 2, "both occurrences recorded")
local lastSample = sl and (sl.last[#sl.last] or sl.first[#sl.first])
eq(lastSample and lastSample.locals.restricted, true, "secret locals stored as a marker")
-- A secret session id from the provider is never compared.
bg2.GetSessionId = function() return WoW.Secret("session") end
table.insert(bg2.db, { message = "odd session", stack = "", session = 9, time = 3, counter = 4 })
C2.useCollector(bg2)
drain()
eq(byTitle2("odd session"), nil, "an unreadable session id seeds without counting")
ns2.Store.db().settings.locals = false

-- 3. The API check: a collector global without its functions is not used.
WoW.reset()
EventRegistry._cb = {}
setCollector({ GetDB = "not a function" })
local ns3 = loadAddon()
eq(ns3.Capture.state.mode, "native", "an unusable collector global is ignored")
setCollector(nil)

done("test_collector")
