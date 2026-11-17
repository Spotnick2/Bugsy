-- Signatures and the store (DESIGN §4): grouping, samples, caps, mutes, sessions.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local ns = loadAddon()
local Sig, Store, C = ns.Signature, ns.Store, ns.Capture
Store.MAX_NEW_PER_SESSION = math.huge   -- the cap has its own test at the end

local function rec(message, stack, extra)
    local r = { kind = "error", tier = "full", provider = "native", stackOrigin = "error",
        message = message, stack = stack or stackAt("TestAddon", "Core.lua", 10), at = WoW.clock,
        key = message and Sig.messageKey("error", message) }
    for k, v in pairs(extra or {}) do r[k] = v end
    Store.record(r)
end
local function byTitle(t)
    for _, p in ipairs(Store.List("all", true)) do if p.title == t then return p end end
end

-- Signatures ---------------------------------------------------------------------
local _, g1 = Sig.compute("error", "attempt to index field 'x' (a nil value) at 3", "A/a.lua:1: x")
local _, g2 = Sig.compute("error", "attempt to index field 'x' (a nil value) at 4", "A/a.lua:1: x")
check(g1 ~= g2, "messages differing only in a number stay distinct")
local _, a1 = Sig.compute("error", "bad table: 0000021A3F2B0C10", stackAt("A", "a.lua", 1))
local _, a2 = Sig.compute("error", "bad table: 00000F00BA4D1234", stackAt("A", "a.lua", 1))
eq(a1, a2, "the same error at two table addresses merges")
eq(Sig.addressless("table: expected"), "table: expected", "ordinary text is not normalised")
eq(Sig.addressless("at 0x7ffd1234abcd"), "at 0x?", "a 0x address is")
local full = stackAt("A", "a.lua", 1, "Interface/AddOns/A/b.lua:20: in function x")
local top = {}
for line in full:gmatch("[^\n]+") do top[#top + 1] = line end
local e1, s1 = Sig.compute("error", "m", full)
local e2, s2 = Sig.compute("error", "m", table.concat(top, "\n", 1, math.min(#top, 12)))
eq(e1, e2, "a top capture and a full one give the same exact signature")
eq(s1, s2, "and the same group")
eq(Sig.location('[string "@Interface/AddOns/A/x.lua"]:7: in main chunk'), "A/x.lua:7", "a file chunk is a location")
eq(Sig.location('[string "return 1 +"]:1: unexpected symbol'), nil, "a code chunk is not")
eq(Sig.location("[C]: in function 'error'"), nil, "a C frame is not")
eq(#Sig.lines("[C]: ?\n(tail call): ?\nA/a.lua:1: x"), 1, "C and tail-call lines are skipped")

-- One bug from three callers is one problem with three call paths.
for i = 1, 3 do
    rec("Interface/AddOns/TestAddon/Util.lua:5: boom",
        stackAt("TestAddon", "Util.lua", 5, ("Interface/AddOns/Caller%d/c.lua:%d: in function f"):format(i, i)))
end
local p = byTitle("Interface/AddOns/TestAddon/Util.lua:5: boom")
eq(p.count, 3, "three occurrences, one problem")
eq(#p.callPaths, 3, "three call paths")

-- Past 20 call paths: the report gives the distinct paths kept and says there are
-- more, never the occurrences on the unkept ones (Codex, PR #2).
local boom = "Interface/AddOns/TestAddon/Util.lua:5: boom"
for i = 4, 21 do rec(boom, stackAt("TestAddon", "Util.lua", 5, ("Interface/AddOns/Caller%d/c.lua:%d: in function f"):format(i, i))) end
for _ = 1, 50 do rec(boom, stackAt("TestAddon", "Util.lua", 5, "Interface/AddOns/Caller21/c.lua:21: in function f")) end
p = byTitle(boom)
eq(#p.callPaths, 20, "twenty call paths kept")
local rp = ns.Report.ForProblem(p).problem
eq(rp.callPaths, 20, "the report counts distinct paths kept, not occurrences")
eq(rp.callPathsMore, true, "and says more were seen")
check(ns.UI.Details(p):find("more than 20 call paths", 1, true), "the details say so too")

-- Samples: first 2 kept, last 3 a ring, the rest counted.
Store.Clear("all")
for i = 1, 9 do WoW.clock = WoW.clock + 1; rec("sampled", nil, { uptime = i }) end
p = byTitle("sampled")
eq(#p.first, 2, "two first samples")
eq(#p.last, 3, "three last samples")
eq(p.first[1].uptime, 1, "the first is the first")
eq(p.last[3].uptime, 9, "the last is the latest")
eq(p.sampledOut, 4, "four counted, not kept")

-- Cap and eviction: 10 000 unique errors keep 300, evictions counted.
Store.Clear("all")
local db = Store.db()
db.stats.evicted = 0
for i = 1, 10000 do WoW.clock = WoW.clock + 1; rec("unique " .. i) end
eq(db.problemCount, 300, "the store stays at its cap")
eq(db.stats.evicted, 9700, "every eviction is counted")
check(byTitle("unique 10000") and not byTitle("unique 9700"), "the oldest went first")

-- All muted: the oldest muted goes, its mute is kept, and it comes back muted.
Store.Clear("all", true)
for i = 1, 300 do WoW.clock = WoW.clock + 1; rec("muted " .. i) end
-- mute oldest first, each a second later: "muted 1" holds the oldest mute, so 299 newer ones
-- push it out of the 200-entry list and only the eviction can put it back
for i = 1, 300 do WoW.clock = WoW.clock + 1; Store.SetMuted(byTitle("muted " .. i).id, true) end
check(not db.mutes[byTitle("muted 1").id], "muted 1 has left the mute list before the eviction")
local oldestId = byTitle("muted 1").id
WoW.clock = WoW.clock + 1
rec("newcomer")
check(not byTitle("muted 1"), "the oldest muted problem was evicted")
check(db.mutes[oldestId], "its signature is still in the mute list")
check(db.muteCount <= Store.MAX_MUTES, "the mute list stays bounded")
WoW.clock = WoW.clock + 1
rec("muted 1")
eq(byTitle("muted 1").muted, true, "it comes back muted")

-- Sessions: {1,2,4} and {1,3,4}; in session 4 only the second was in the previous one.
Store.Clear("all", true)
local function inSessions(title, sessions)
    for _, s in ipairs(sessions) do db.session = s; rec(title) end
end
inSessions("A", { 1, 2, 4 })
inSessions("B", { 1, 3, 4 })
db.session = 4
local prev = Store.List("previous", true)
eq(#prev, 1, "one problem in the previous session")
eq(prev[1].title, "B", "the one seen in session 3")
eq(#Store.List("session", true), 2, "both in this session")
eq(byTitle("A").sessionCount, 3, "sessions counted")
check(#byTitle("A").recentSessions <= 3, "recent sessions bounded")

-- Count-tier: one match this session gets unconfirmed repeats; none or two go to suppressed.
Store.Clear("all", true)
rec("counted")
Store.count("error", Sig.messageKey("error", "counted"), 5)
eq(byTitle("counted").unconfirmedRepeats, 5, "unconfirmed repeats on the one match")
eq(byTitle("counted").count, 1, "never added to the count")
local before = C.state.stats.suppressed.error
Store.count("error", Sig.messageKey("error", "nothing like it"), 3)
eq(C.state.stats.suppressed.error, before + 3, "no match: suppressed")

-- Clearing.
eq(Store.Clear(byTitle("counted").id), 1, "one problem cleared")
eq(#Store.List("all", true), 0, "nothing left")

-- A malformed saved table loads; the bad parts are dropped and counted.
WoW.reset()
local bad = {
    format = 1, session = 7, sourceId = "zz", settings = "nope",
    problems = { good = nil, ["x"] = { id = "x" }, [5] = {}, y = "string" },
    mutes = { a = "no", b = 5 },
}
local ns2 = loadAddon({ db = bad })
local d2 = ns2.Store.db()
eq(d2.session, 8, "the session moves on")
eq(d2.stats.dropped, 3, "three malformed problems dropped")
eq(d2.problemCount, 0, "none kept")
check(#d2.sourceId == 16, "a bad source id is replaced")
eq(d2.settings.locals, false, "settings rebuilt")
eq(d2.muteCount, 1, "one valid mute kept")
WoW.reset()
local ns3 = loadAddon({ db = "garbage" })
eq(ns3.Store.db().format, 1, "a non-table saved value starts fresh")

-- A kept problem with damaged nested fields is rebuilt, so the window, a repeat
-- and a report all still work (Codex, PR #2).
local damagedMsg = "Interface/AddOns/TestAddon/Core.lua:9: damaged later"
local function damagedRec(S)
    S.record({ kind = "error", tier = "full", provider = "native", stackOrigin = "error", message = damagedMsg,
        stack = stackAt("TestAddon", "Core.lua", 9), at = WoW.clock, key = ns3.Signature.messageKey("error", damagedMsg) })
end
damagedRec(ns3.Store)
local saved = BugsyDB
local did = next(saved.problems)
local dp = saved.problems[did]
dp.callPaths = nil
dp.recentSessions = "x"
dp.addons = { { name = 5 }, { name = "TestAddon", versions = { ["1.2.3"] = "many", ["1.2.4"] = 2 } } }
dp.first = { 42, dp.first[1] }
dp.first[2].provider = {}
dp.first[2].message = { text = {} }
dp.first[2].versions = { TestAddon = {} }
dp.last = "nope"
dp.attribution = { suspect = { addon = {} } }
dp.sessionCount = -1
WoW.reset()
local ns5 = loadAddon({ db = saved })
local q = ns5.Store.Get(did)
check(q, "a problem with damaged nested fields is kept")
eq(#q.callPaths, 0, "missing call paths rebuilt empty")
eq(#q.recentSessions, 0, "a non-table session list rebuilt")
eq(#q.addons, 1, "an addon entry without a name dropped")
eq(q.addons[1].versions["1.2.3"], nil, "a version with a non-number count dropped")
eq(q.addons[1].versionCount, 1, "the version count recomputed")
eq(#q.first, 1, "a sample that is not a table dropped")
eq(q.first[1].provider, nil, "a non-string provider dropped")
eq(q.first[1].message.reason, "damaged", "a damaged message becomes a marker")
eq(next(q.first[1].versions), nil, "a non-string captured version dropped")
eq(#q.last, 0, "a non-table ring rebuilt")
eq(q.attribution, nil, "a damaged attribution dropped (the next occurrence reads it again)")
eq(q.sessionCount, 1, "a bad session count reset")
local okD, details = pcall(ns5.UI.Details, q)
check(okD, "the window shows it: " .. tostring(not okD and details or ""))
damagedRec(ns5.Store)
eq(q.count, 2, "a repeat records")
eq(#q.callPaths, 1, "with its call path")
check(q.attribution and q.attribution.suspect, "and a fresh attribution")
local okR, md = pcall(ns5.Report.Render, ns5.Report.ForProblem(q))
check(okR and md, "and a report renders: " .. tostring(not okR and md or ""))

-- Frame lines in the shapes measured on Forever (Fable review, finding 1) -----------------
local P = ns3.Signature
local function loc(line) return P.location(line) end
eq(loc("[Interface/AddOns/X/f.lua]:12: in function <Interface/AddOns/X/f.lua:10>"), "X/f.lua:12",
    "the first path: where the line ran, not where the function was defined")
eq(loc("[Interface/AddOns/X/f.lua]:12: in function 'DoThing'"), "X/f.lua:12", "a named function")
eq(loc("[Priestly/Libs/LibGroupBuffs-1.0/UI.lua]:172: in function <...UI.lua:170>"),
    "Priestly/Libs/LibGroupBuffs-1.0/UI.lua:172", "a path without Interface/AddOns, a shortened second path")
eq(loc("[Priestly/Libs/LibGroupBuffs-1.0/UI.lua]:763"), "Priestly/Libs/LibGroupBuffs-1.0/UI.lua:763", "a bare frame")
eq(loc("Interface/AddOns/X/f.lua:12: in function <Interface/AddOns/X/f.lua:10>"), "X/f.lua:12", "unbracketed")
eq(loc("[...ce/AddOns/X/f.lua]:5: in function x"), "X/f.lua:5", "a shortened path that still shows AddOns/")
eq(loc("[...f.lua]:5: in function x"), nil, "a shortened path that hides the folder is not a location")
eq(loc('[string "@Interface/AddOns/A/x.lua"]:7: in main chunk'), "A/x.lua:7", "a file chunk")
eq(loc('[string "return 1 +"]:1: in main chunk'), nil, "a code chunk is not")

-- One bug in a named function reached from three callers: ONE problem.
local S4 = ns3.Store
S4.MAX_NEW_PER_SESSION = math.huge
for i = 1, 3 do
    S4.record({ kind = "error", tier = "full", provider = "native", stackOrigin = "error", at = WoW.clock,
        message = "Interface/AddOns/X/f.lua:12: attempt to call a nil value",
        stack = "[Interface/AddOns/X/f.lua]:12: in function 'DoThing'\n"
            .. ("[Interface/AddOns/Caller%d/c.lua]:%d: in function <Interface/AddOns/Caller%d/c.lua:%d>"):format(i, 20 + i, i, 10 + i) })
end
local three = 0
for _, q in ipairs(S4.List("all", true)) do if q.title:find("attempt to call a nil value", 1, true) then three = three + 1 end end
eq(three, 1, "three callers, one problem")

-- Our own leading frames never change a signature.
local plain = "[Interface/AddOns/X/f.lua]:12: in function 'DoThing'\n[C]: ?"
local withOwn = "[Interface/AddOns/!Bugsy/Capture.lua]:250: in function <Interface/AddOns/!Bugsy/Capture.lua:240>\n"
    .. "[C]: in function 'pcall'\n" .. plain
local ea, ga = P.compute("error", "m", plain)
local eb, gb = P.compute("error", "m", withOwn)
eq(ea, eb, "a leading run of Bugsy frames is skipped (exact)")
eq(ga, gb, "and the group")
local suspect = ns3.Attribution.attribute({ kind = "error", message = "m", stack = withOwn }).suspect
eq(suspect.addon, "X", "attribution skips Bugsy too")

-- The per-session cap on new problems.
S4.Clear("all", true)
S4.MAX_NEW_PER_SESSION = 5
S4.sessionNew = 0
for i = 1, 8 do S4.record({ kind = "error", tier = "full", message = "capped " .. i, stack = plain, at = WoW.clock }) end
eq(#S4.List("all", true), 5, "at most 5 new problems this session")
eq(S4.db().stats.newCapped, 3, "the rest counted as capped")
S4.record({ kind = "error", tier = "full", message = "capped 1", stack = plain, at = WoW.clock })
-- Exactly +1 (the pause probe's marker relies on it, Codex PR #17): a repeat past the cap
-- is counted on its problem, not refused as a new one.
local function countOf(msg)
    for _, p in ipairs(S4.List("all", true)) do if p.title == msg then return p.count + 0 end end
end
eq(countOf("capped 1"), 2, "an existing problem still counts past the cap")
eq(S4.db().stats.newCapped, 3, "and the repeat is not counted as capped")

done("test_store")
