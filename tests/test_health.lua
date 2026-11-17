-- Capture health (#14) and the front's circuit breaker (#11): DESIGN §6, D16. The
-- cases follow the Codex design review (three rounds).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local realSet = seterrorhandler
local NOTICE = "Error reporting is now paused and will resume after reloading the UI."

local function fresh(opts)
    WoW.reset()
    seterrorhandler = realSet
    local ns = loadAddon(opts)
    ns.Store.MAX_NEW_PER_SESSION = math.huge
    return ns, ns.Capture, ns.Store
end

local function count(Store, title)
    local n = 0
    for _, p in ipairs(Store.List("all", true)) do
        if p.title == title then n = n + p.count + (p.unconfirmedRepeats or 0) end
    end
    return n
end

local function burst(n, text)
    for i = 1, n do WoW.raise(text or ("burst error " .. i)) end
end

-- #14 ---------------------------------------------------------------------------------

-- 99 eligible deliveries in one timestamp: nothing; the 100th: a suspicion.
local ns, C, Store = fresh()
burst(99)
eq(C.state.health.pause, nil, "99 deliveries in one timestamp: no suspicion")
eq(C.state.stats.deliveries, 99, "each eligible delivery counted")
WoW.raise("the hundredth")
local p = C.state.health.pause
check(p, "the 100th records a suspicion")
eq(p and p.status, "suspected", "suspected, not paused")
eq(p and p.evidence, "burst", "on burst evidence")
eq(p and p.session, BugsyDB.session, "it names the capture session")
WoW.raise("call 101, an ordinary error")
eq(p.observedCalls, 101, "the calls in that bucket are counted")
drain()
eq(count(Store, "call 101, an ordinary error"), 1, "call 101 is captured normally: not discarded by position")
check(C.limits()[1]:find("may have paused", 1, true), "the limits say 'may'")
local joined = table.concat(C.limits(), " ")
check(not joined:find("capture stopped", 1, true), "never 'capture stopped'")
check(joined:find("captured separately", 1, true), "events are said to be captured separately")

-- Silence never upgrades it; a later delivery contradicts a complete pause.
WoW.advance(30)
eq(p.status, "suspected", "silence does not make it certain")
WoW.raise("later error")
eq(p.deliveredAfter, 1, "a delivery in a later timestamp is counted against the pause")
eq(C.state.health.pause, p, "and does not clear the observation")
check(table.concat(C.limits(), " "):find("received 1 errors since", 1, true), "the limits say so")
drain()
eq(count(Store, "later error"), 1, "and it is captured: Bugsy never refuses a call")

-- The English notice: a hint, not stored as a problem; anything else stays a problem.
ns, C, Store = fresh()
WoW.raise(NOTICE)
p = C.state.health.pause
eq(p and p.status, "reported", "the exact notice reports a pause message")
eq(p and p.evidence, "message", "on message evidence")
drain()
eq(count(Store, NOTICE), 0, "the notice is not a problem")
check(C.limits()[1]:find("received a message", 1, true), "worded as a received message")
ns, C, Store = fresh()
burst(100)
WoW.raise(NOTICE)
eq(C.state.health.pause.evidence, "both", "burst and message: both")
ns, C, Store = fresh()
local translated = "La notification des erreurs est en pause jusqu'au rechargement de l'interface."
WoW.raise(translated)
eq(C.state.health.pause, nil, "a translated notice classifies nothing")
drain()
eq(count(Store, translated), 1, "and is captured normally (D15)")
WoW.raise(NOTICE .. " ")
eq(C.state.health.pause, nil, "a near-match (spoof) is not the notice")
WoW.raise(WoW.Secret(NOTICE))
eq(C.state.health.pause, nil, "a secret message is never compared")

-- What is not an eligible delivery.
ns, C, Store = fresh()
WoW.errorHeight = nil
burst(150, "direct report")
eq(C.state.stats.deliveries, 0, "direct reports (nil height) are not counted")
eq(C.state.health.pause, nil, "and raise no suspicion")
WoW.errorHeight = 0
WoW.raise("file scope")
eq(C.state.stats.deliveries, 1, "an error height of 0 is a delivery")
WoW.errorHeight = 3
for i = 1, 150 do WoW.fire("LUA_WARNING", "warning " .. i) end
eq(C.state.stats.deliveries, 1, "events are not deliveries")

-- Detection survives a saturated capture path: no tiers left, a full queue, no store.
ns, C, Store = fresh({ before = function(n2) n2.Capture.QUEUE_MAX = 1 end })
C.buckets.full.tokens, C.buckets.top.tokens, C.buckets.discovery.tokens = 0, 0, 0
C.COUNT_KEYS = 0
C.sink = nil
burst(100)
check(C.state.health.pause, "the suspicion is recorded even with nothing captured")

-- One health notice, coalesced, held in combat, with the notices setting; no sound.
ns, C, Store = fresh()
WoW.raise("same")                     -- known before the burst: no new-problem notice in it
drain()
WoW.advance(11)
WoW.lines, WoW.sounds = {}, {}
WoW.combat = true
burst(100, "same")
WoW.raise(NOTICE)
drain()
check(not chatHas("paused"), "no health line in combat")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
drain()
local lines = 0
for _, l in ipairs(WoW.lines) do if l:find("paused", 1, true) then lines = lines + 1 end end
eq(lines, 1, "one health line after combat, coalesced")
for _, s in ipairs(WoW.sounds) do check(false, "a health line never plays the sound") end
ns.Bugsy.Slash("status")
check(chatHas("received a message saying"), "/bugsy status shows it")
check(ns.UI.StatusText():find("may be paused", 1, true), "the window's status line points to it")

-- #11 ---------------------------------------------------------------------------------

local function frontWith(cost, throwIt)
    local ns2, C2, S2 = fresh()
    local W = { calls = 0 }
    local prev = geterrorhandler()
    W.fn = function(msg, ...)
        W.calls = W.calls + 1
        WoW.ms = WoW.ms + (type(cost) == "function" and cost(W.calls) or cost)
        if throwIt then error("slow and throwing") end
        return prev(msg, ...)
    end
    seterrorhandler(W.fn)
    C2.check("HostAddon")
    eq(C2.state.mode, "front", "front installed")
    return ns2, C2, S2, W
end

-- One call below, at and above FRONT_SLOW_CALL_MS.
local _, C2, S2, W = frontWith(49)
WoW.raise("fast enough")
eq(C2.state.forward.suspended, false, "49 ms: not tripped")
_, C2, S2, W = frontWith(50)
WoW.raise("at the threshold")
eq(C2.state.forward.suspended, true, "50 ms: tripped")
eq(C2.state.forward.reason, "call", "by one call")
eq(C2.state.passing, false, "the passing guard is cleared")
WoW.raise("after the trip")
eq(W.calls, 1, "no further outgoing call")
eq(C2.state.forward.skipped, 1, "the skipped one is counted")
drain()
eq(count(S2, "after the trip"), 1, "and still captured")
eq(select(2, _G.Bugsy.Status()), 0, "skipped pass-ons are not capture loss")
check(table.concat(C2.limits(), " "):find("stopped passing errors", 1, true), "the limits say so")
eq(C2.state.mode, "front", "the mode stays front")

-- A slow call that throws still trips; a fast throw does not.
_, C2, S2, W = frontWith(60, true)
WoW.raise("slow throw")
eq(C2.state.forward.suspended, true, "a slow call that threw trips")
eq(C2.state.stats.forwardFailed, 1, "and its failure is counted")
_, C2, S2, W = frontWith(1, true)
WoW.raise("fast throw")
eq(C2.state.forward.suspended, false, "a fast throw does not trip")

-- The rolling window: 99 ms in it does not trip, 100 ms does; idle time expires bins.
_, C2, S2, W = frontWith(33)
WoW.raise("a"); WoW.raise("b"); WoW.raise("c")
eq(C2.state.forward.suspended, false, "99 ms within the window: not tripped")
WoW.raise("d")
eq(C2.state.forward.suspended, true, "132 ms within the window: tripped")
eq(C2.state.forward.reason, "window", "by the window")
_, C2, S2, W = frontWith(40)
WoW.raise("e"); WoW.raise("f")
WoW.ms = WoW.ms + 2000                        -- idle: the bins expire
WoW.raise("g")
eq(C2.state.forward.suspended, false, "older bins expire: 40 ms now, not 120")

-- A reset of the shared profiler timer (another addon's debugprofilestart): old bins
-- must not count (Codex, PR #17).
-- The resets land in the SAME bin as the old costs, so only clearing saves it.
_, C2, S2, W = frontWith(20)
WoW.ms = 100
WoW.raise("h"); WoW.raise("i")                -- 40 ms in bin 1 (100-140)
WoW.ms = 105                                  -- reset between calls
WoW.raise("j"); WoW.raise("j2"); WoW.raise("j3")   -- 60 ms more in bin 1
eq(C2.state.forward.suspended, false, "a reset between calls clears the window: 60 ms, not 100")
_, C2, S2, W = frontWith(function(n) if n == 3 then return 110 - WoW.ms end return 20 end)   -- call 3: the timer goes back to 110
WoW.ms = 100
WoW.raise("k"); WoW.raise("l")                -- 40 ms in bin 1
WoW.raise("m")                                -- the timer resets during this pass-on
check(C2.state.forward.timingUnavailable >= 1, "a reset within a call is unavailable timing")
WoW.raise("n"); WoW.raise("n2"); WoW.raise("n3")   -- 60 ms more in bin 1
eq(C2.state.forward.suspended, false, "and clears the window: 60 ms, not 100")
-- A bin stamped "in the future" never counts (a second safeguard: the clears above
-- already discard such bins, so this is tested on the state directly).
_, C2 = frontWith(0)
C2.state.forward.stamps[5], C2.state.forward.bins[5] = 999994, 500   -- slot 5, not the one bin 0 uses
WoW.ms = 0
WoW.raise("o")
eq(C2.state.forward.suspended, false, "a future-stamped bin is not counted")

-- Timing that cannot be trusted: missing, throwing, secret, non-numeric, infinite, backwards.
local function badTimer(label, fn)
    local _, C3 = frontWith(0)
    local real = _G.debugprofilestop
    _G.debugprofilestop = fn
    WoW.raise("with a bad timer: " .. label)
    _G.debugprofilestop = real
    eq(C3.state.forward.suspended, false, label .. ": never taken as slow")
    check(C3.state.forward.timingUnavailable >= 1, label .. ": counted as unavailable")
    eq(C3.state.passing, false, label .. ": the guard is cleared")
end
badTimer("throwing", function() error("no timer") end)
badTimer("secret", function() return WoW.Secret(5) end)
badTimer("not a number", function() return "5" end)
badTimer("infinite", function() return math.huge end)
local tick = 1000
badTimer("backwards", function() tick = tick - 500; return tick end)

-- Exactly one trip; a reload is a fresh state.
_, C2, S2, W = frontWith(80)
WoW.raise("one");
local at = C2.state.forward.at
WoW.raise("two")
eq(C2.state.forward.at, at, "exactly one trip")
local ns4, C4 = fresh()
eq(C4.state.forward.suspended, false, "a reload starts fresh")

-- Reports: full and minimal carry both snapshots; Markdown shows both; snapshots are copies.
local ns5, C5, S5, W5 = frontWith(70)
burst(100, "report burst")
WoW.raise("report burst")
drain()
local prob = S5.List("all", true)[1]
local r = ns5.Report.ForProblem(prob)
eq(r.capture.forward.suspended, true, "the report carries the suspension")
eq(r.capture.health.pause.status, "suspected", "and the pause observation")
C5.state.health.pause.deliveredAfter = 999
eq(r.capture.health.pause.deliveredAfter, 0, "a snapshot, not the live state")
local huge = ns5.Report.ForProblem(prob)
huge.attribution.evidenceDump = string.rep("x", 200000)
local mjson, minimal = ns5.Report.Fit(huge)
check(minimal.privacy.trimmed[1]:find("too large", 1, true), "forced to the minimal report")
eq(minimal.capture.forward.suspended, true, "the minimal report keeps the suspension")
eq(minimal.capture.health.pause.status, "suspected", "and the pause observation")
check(mjson:find('"forward"', 1, true) and mjson:find('"health"', 1, true), "in its JSON")
local md = ns5.Report.Markdown(minimal)
check(md:find("Capture health:", 1, true), "minimal Markdown shows the pause")
check(md:find("Forwarding: suspended", 1, true), "and the suspension")
local manual = ns5.Report.Manual("OtherAddon", {})
eq(manual.capture.health.pause.status, "suspected", "manual reports carry it too")

done("test_health")
