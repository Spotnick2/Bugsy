-- Front mode (DESIGN §3, D14): Bugsy installs itself ahead of another addon's error
-- handler and passes each error on. The cases are those of the Codex design review
-- (three rounds): ordering, recovery, liveness evidence, one attempt, collector
-- exclusivity, the session snapshot.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local realSet = seterrorhandler

-- A wrapper like the one measured in the owner's setup: it saves the previous
-- handler, keeps some errors, and passes the rest on (a tail call by default).
local function installWrapper(opts)
    opts = opts or {}
    local prev = geterrorhandler()
    local W = { calls = 0, kept = 0, passed = 0, prev = prev }
    W.fn = function(msg, ...)
        W.calls = W.calls + 1
        W.nargs = select("#", ...)
        if opts.during then opts.during(msg) end
        if opts.throw then error("wrapper exploded") end
        if opts.keep and type(msg) == "string" and msg:find(opts.keep, 1, true) then W.kept = W.kept + 1; return end
        if opts.limit and W.calls > opts.limit then return end
        W.passed = W.passed + 1
        if opts.defer then
            local m = msg
            C_Timer.After(0, function() prev(m) end)
            return
        end
        if opts.nontail then
            prev(msg, ...)
            return true
        end
        return prev(msg, ...)
    end
    seterrorhandler(W.fn)
    return W
end

local function fresh(opts)
    WoW.reset()
    seterrorhandler = realSet
    local ns = loadAddon(opts)
    ns.Store.MAX_NEW_PER_SESSION = math.huge
    return ns, ns.Capture, ns.Store
end

local function count(Store, title)
    local n = 0
    for _, p in ipairs(Store.List("all", true)) do if p.title == title then n = n + p.count end end
    return n
end

local function newest(Store, title)
    for _, p in ipairs(Store.List("all", true)) do
        if p.title == title then return p.last[#p.last] or p.first[#p.first] end
    end
end

-- 1. The measured case: a wrapper installed after us, then our next check.
local ns, C, Store = fresh()
eq(C.state.frontEnabled, true, "front is on by default")
local W = installWrapper({ keep = "hostaddon" })
WoW.fire("ADDON_LOADED", "HostAddon")
eq(C.state.mode, "front", "Bugsy put itself in front of the wrapper")
eq(WoW.handler, C.front, "the installed handler is the front")
eq(C.state.nextHandler, W.fn, "and it passes on to the wrapper")
eq(C.state.changes[#C.state.changes].action, "front", "the transition is recorded as ours")
eq(C.state.changes[#C.state.changes].afterAddon, "HostAddon", "after the addon that installed the wrapper")
WoW.fire("ADDON_LOADED", "Later")
eq(#C.state.changes, 2, "our own front is not a new takeover at the next check")

WoW.raise("plain error")
drain()
eq(count(Store, "plain error"), 1, "an error is recorded once")
eq(W.calls, 1, "and the wrapper sees it once")
eq(newest(Store, "plain error").entry, "front", "the sample says it arrived through the front")
eq(C.state.passing, false, "the passing guard is cleared")
eq(C.state.busy, false, "and the busy guard")

WoW.raise("an error naming HostAddon in hostaddon/Core.lua")
drain()
eq(W.kept, 1, "the wrapper kept its own error")
eq(count(Store, "an error naming HostAddon in hostaddon/Core.lua"), 1, "Bugsy recorded it anyway")

-- Varargs, trailing nils included.
WoW.handler("with args", nil, "x", nil)
eq(W.nargs, 3, "the extra arguments are passed on, trailing nils too")
drain()

-- An idle call to our original handler (a library holding it), no error in flight.
local alive = C.state.aliveVia
WoW.errorHeight = nil
C.handler("reported by a library")
WoW.errorHeight = 3
drain()
eq(count(Store, "reported by a library"), 1, "a direct report to the original handler is recorded")
eq(C.state.mode, "front", "and changes no mode")
eq(C.state.aliveVia, alive, "nor the liveness evidence")
eq(newest(Store, "reported by a library").entry, "handler", "its sample says how it arrived")

-- 2. A non-tail wrapper: the same.
ns, C, Store = fresh()
W = installWrapper({ nontail = true })
C.check("HostAddon")
WoW.raise("non-tail")
drain()
eq(count(Store, "non-tail"), 1, "non-tail pass-on: one capture")
eq(W.calls, 1, "one downstream call")

-- 3. A wrapper that stops passing errors on (a flood cutoff): Bugsy still sees them.
ns, C, Store = fresh()
W = installWrapper({ limit = 2 })
C.check("HostAddon")
for i = 1, 5 do WoW.raise("after cutoff " .. i) end
drain()
eq(count(Store, "after cutoff 5"), 1, "an error past the wrapper's cutoff is recorded")

-- 4. Capture failure still forwards; a forward failure is counted; guards clear.
ns, C, Store = fresh()
W = installWrapper()
C.check("HostAddon")
local realStack = _G.debugstack
_G.debugstack = function() error("debugstack exploded") end
WoW.raise("capture fails")
_G.debugstack = realStack
eq(W.calls, 1, "a failed capture still passes the error on")
eq(C.state.busy, false, "busy cleared after a failed capture")
ns, C, Store = fresh()
W = installWrapper({ throw = true })
C.check("HostAddon")
WoW.raise("downstream throws")
eq(C.state.stats.forwardFailed, 1, "the wrapper's failure is counted")
eq(C.state.passing, false, "passing cleared after it")
WoW.raise("next after the throw")
drain()
eq(count(Store, "downstream throws"), 1, "the error was still recorded")
eq(count(Store, "next after the throw"), 1, "and the next one too")

-- 5. A distinct report made while the wrapper handles one: dropped and counted.
ns, C, Store = fresh()
local recursive = function(msg)
    if msg == "outer" then geterrorhandler()("inner via front"); C.handler("inner via original") end
end
W = installWrapper({ during = function(msg) recursive(msg) end })
C.check("HostAddon")
local before = C.state.stats.passSuppressed
WoW.raise("outer")
drain()
eq(count(Store, "outer"), 1, "the outer error is recorded")
eq(count(Store, "inner via front"), 0, "a report through the front while passing is dropped")
eq(count(Store, "inner via original"), 0, "and one through the original handler")
eq(C.state.stats.passSuppressed - before, 2, "the two distinct reports are counted as dropped")
eq(C.state.stats.passReturned, 1, "the wrapper's own pass-back is counted apart, as expected")
local _, lostNow = ns.Bugsy.Status()
check(lostNow >= 2, "the dropped reports are in the status's loss count")
local rep = ns.Report.ForProblem(ns.Store.List("all", true)[1])
eq(rep.capture.session.passSuppressed, 2, "and in the report")

-- 6. A wrapper that defers its pass-on: the documented duplicate.
ns, C, Store = fresh()
W = installWrapper({ defer = true })
C.check("HostAddon")
WoW.raise("deferred")
drain()
eq(count(Store, "deferred"), 2, "a deferred pass-on is recorded a second time (documented)")

-- 7. Setters: no-op, throwing after installing, throwing before; one attempt only.
ns, C, Store = fresh()
W = installWrapper()
local calls = 0
seterrorhandler = function() calls = calls + 1 end      -- a no-op setter
C.check("HostAddon")
eq(C.state.mode, "displaced", "a no-op setter: no front")
eq(C.state.nextHandler, nil, "and no next handler kept")
eq(C.state.frontTried, true, "the attempt is spent")
C.check("Again")
eq(calls, 1, "exactly one attempt a session")
seterrorhandler = realSet

ns, C, Store = fresh()
W = installWrapper()
seterrorhandler = function(f) WoW.handler = f; error("setter exploded") end
C.check("HostAddon")
seterrorhandler = realSet
eq(C.state.mode, "front", "a setter that installs, then throws: front, by identity")
eq(C.state.nextHandler, W.fn, "with its next handler intact")

ns, C, Store = fresh()
W = installWrapper()
seterrorhandler = function() error("setter exploded first") end
C.check("HostAddon")
seterrorhandler = realSet
eq(C.state.mode, "displaced", "a setter that throws before installing: unchanged")
eq(C.state.nextHandler, nil, "no next handler")

-- 8. A later wrapper capturing the front: no second attempt, the chain intact.
ns, C, Store = fresh()
W = installWrapper()
C.check("HostAddon")
local W2 = installWrapper()
eq(W2.prev, C.front, "the later wrapper saved the front")
C.check("LaterAddon")
eq(C.state.mode, "displaced", "the change is noticed")
eq(C.state.nextHandler, W.fn, "the front still passes on to the first wrapper")
WoW.raise("through both")
drain()
eq(count(Store, "through both"), 1, "recorded once")
eq(W2.calls, 1, "the later wrapper saw it")
eq(W.calls, 1, "and the first one")
eq(C.state.mode, "chained", "a real error reached the front through the later wrapper: chained")
C.check("Again")
eq(WoW.handler, W2.fn, "no second front")

-- 9. A collector appearing after the front: collector mode, no native copies.
ns, C, Store = fresh()
W = installWrapper()
C.check("HostAddon")
local bg = { db = {} }
function bg:GetDB() return self.db end
function bg:GetSessionId() return 1 end
function bg:GetErrorByID() end
rawset(_G, COLLECTOR.global, bg)
seterrorhandler(function() end)                          -- the collector's own handler
C.check("CollectorAddon")
eq(C.state.mode, "collector", "the collector's API is used")
local wCalls = W.calls
for _, h in ipairs({ 3, false }) do
    WoW.errorHeight = h or nil
    C.handler("native copy A")
    C.front("native copy B")
end
WoW.errorHeight = 3
drain()
eq(C.state.mode, "collector", "neither entry point leaves collector mode")
eq(count(Store, "native copy A") + count(Store, "native copy B"), 0, "nothing native recorded")
eq(C.state.stats.nativeInCollector, 4, "each call counted")
eq(W.calls - wCalls, 2, "the front still passes calls on")
rawset(_G, COLLECTOR.global, nil)

-- 10. The setting: persisted off, and a toggle that waits for the next session.
ns, C, Store = fresh({ db = { format = 1, settings = { front = false } } })
eq(C.state.frontEnabled, false, "a saved 'off' is read at load")
W = installWrapper()
C.check("HostAddon")
eq(C.state.mode, "displaced", "no front when off")
-- A library's direct call to our original handler (no error in flight) is not
-- evidence that the wrapper passes errors on: still displaced, now and at the next check.
WoW.errorHeight = nil
C.handler("direct while displaced")
WoW.errorHeight = 3
eq(C.state.mode, "displaced", "a nil-height call does not make it chained")
C.check("Next")
eq(C.state.mode, "displaced", "nor does the next check, from that call")
drain()
eq(count(Store, "direct while displaced"), 1, "the report itself is recorded")
WoW.raise("with front off")
eq(C.state.mode, "chained", "the wrapper passes errors on: chained")

ns, C, Store = fresh()
ns.Bugsy.Slash("front off")
eq(BugsyDB.settings.front, false, "the toggle is saved")
W = installWrapper()
C.check("HostAddon")
eq(C.state.mode, "front", "but this session still fronts (read once at load)")

-- 11. Status and limits.
check(ns.Bugsy.Status():find("ahead of another addon", 1, true), "the status says where Bugsy sits")
check(C.limits()[1]:find("passes each Lua error", 1, true), "the limits say what it does")
check(C.limits()[2]:find("not recorded", 1, true), "that a distinct report meanwhile is lost")
check(C.limits()[2]:find("twice", 1, true), "and that a deferred pass-on is recorded twice")
local changes = ns.Report.ForProblem(ns.Store.List("all", true)[1] or { first = {}, last = {}, callPaths = {} }).capture.handlerChanges
eq(changes[#changes] and changes[#changes].action, "front", "the report keeps the front transition's action")
ns.Bugsy.Slash("status")
check(chatHas("passes each Lua error"), "/bugsy status prints the limits")
local d = ns.Bugsy.Diagnostics("plain")
eq(d.mode, "front", "Diagnostics: the mode")
eq(d.fronted, true, "and that the front is installed")

done("test_front")
