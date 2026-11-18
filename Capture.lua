-- Capture.lua: the critical path (DESIGN.md §3, §5, §6). The native error handler,
-- the event frame, the collector provider, the bounded queue and the drain.
--
-- The handler never throws and never recurses. It checks every value with Safe
-- before touching it, takes only what will be gone later, within its tier's
-- budget, and leaves everything else to the drain. The incidents layer plugs in
-- as Capture.sink at our ADDON_LOADED; until then records wait in the queue.

local ADDON, ns = ...
local G, Safe, API, Sig = ns.G, ns.Safe, ns.API, ns.Signature
local Capture = {}
ns.Capture = Capture

local type, pcall, rawget, next, tostring = type, pcall, rawget, next, tostring
local min = math.min

Capture.KINDS = { "error", "warning", "blocked", "forbidden", "handled" }
Capture.LIMIT = { message = 2048, stack = 6144, locals = 3072, failure = 200 }
Capture.QUEUE_MAX = 200
Capture.COUNT_KEYS = 100
Capture.SEEN_MAX = 1000
Capture.FAILURES_KEPT = 5
Capture.CHANGES_KEPT = 5
Capture.DRAIN_RECORDS, Capture.DRAIN_MS = 50, 4
-- Stack level when GetErrorCallstackHeight() is nil (a direct geterrorhandler()(msg)
-- call, an event, xpcall). Counted from the body, which runs inside the handler's pcall.
-- Measured (P2, build 70959, FOREVER-PROBE §7): the caller of a direct call is at 4;
-- for xpcall, 4 is the 'error' C frame (skipped) and 5 the site. Reports say "fallback".
Capture.FALLBACK_LEVEL = 4
-- The other error collector's public names (DESIGN §3, "collector mode"): the
-- global it publishes and the EventRegistry event it fires for each error.
-- Interoperability only: Bugsy reads its public API and uses none of its code.
Capture.COLLECTOR = { global = "BugGrabber", event = "BugGrabber.BugGrabbed" }
-- Capture health (#14, DESIGN §6): the client pauses error reporting after a burst
-- (measured: 100 errors in one frame, FOREVER-PROBE §7). Bugsy counts eligible
-- deliveries per "same timestamp" and records a suspicion at BURST_LIMIT; the
-- English notice is only an optional hint (D15): another locale changes nothing else.
Capture.BURST_LIMIT = 100
Capture.PAUSE_NOTICE_EN = "Error reporting is now paused and will resume after reloading the UI."
-- The front's circuit breaker (#11, D16): provisional thresholds, not measured limits.
Capture.FRONT_SLOW_CALL_MS = 50
Capture.FRONT_SLOW_WINDOW_MS = 100
Capture.BIN_MS, Capture.BINS = 100, 10     -- a rolling ~1 s window of stamped bins

-- State ----------------------------------------------------------------------

local S = {
    mode = "native",          -- "native" | "collector" | "displaced" | "chained" | "front"
    busy = false, nested = 0, failures = 0, failureLog = {},
    queue = {}, head = 1, tail = 0,
    counts = {}, countKeys = 0,
    seen = {}, seenN = 0,
    scheduled = false,
    changes = {}, changesDropped = 0, lastHandler = false,   -- false: nothing recorded yet (a handler can be nil)
    water = setmetatable({}, { __mode = "k" }),
    settings = { locals = false },
    stats = { suppressed = {}, queueDropped = 0, drainFailed = 0, scheduleFailed = 0, countDropped = 0,
        passSuppressed = 0, passReturned = 0, forwardFailed = 0, nativeInCollector = 0, deliveries = 0 },
    burst = { t = nil, n = 0 },     -- eligible deliveries in the current same-timestamp bucket
    health = { pause = nil },       -- the pause observation (#14), never a reason to refuse a call
    forward = { suspended = false, skipped = 0, timingUnavailable = 0, bins = {}, stamps = {} },
    session = nil,                  -- the store's session, set at our ADDON_LOADED
    passing = false,
    frontEnabled = nil,       -- set once a session from the saved setting (Bugsy.lua); nil: never front
    frontTried = false,       -- one attempt a UI session
    nextHandler = nil,        -- the handler front passes on to; never changed after the attempt
}
for _, k in ipairs(Capture.KINDS) do S.stats.suppressed[k] = 0 end
Capture.state = S

local function bucket(rate) return { rate = rate, tokens = rate } end
local B = { full = bucket(15), discovery = bucket(5), top = bucket(40) }
Capture.buckets = B

local function take(b, now)
    if b.at then b.tokens = min(b.rate, b.tokens + (now - b.at) * b.rate) end
    b.at = now
    if b.tokens >= 1 then b.tokens = b.tokens - 1; return true end
    return false
end

-- Failure recording: never stringifies anything but a readable string.
local function fail(err)
    S.failures = S.failures + 1
    if type(err) == "string" and Safe.readable(err) then
        local log = S.failureLog
        log[#log + 1] = err:sub(1, Capture.LIMIT.failure)
        if #log > Capture.FAILURES_KEPT then table.remove(log, 1) end
    end
end
Capture.fail = fail

-- A message as stored text: a readable string (or number), cut; else a marker.
-- Returns stored (string | cut | marker), text (the string the signatures use, or nil).
local function messageOf(msg)
    if not Safe.readable(msg) then return Safe.marker(msg), nil end
    local t = type(msg)
    local s
    if t == "string" then s = msg
    elseif t == "number" then s = tostring(msg)
    else return { unsupported = t }, nil end
    local stored = Safe.cut(s, Capture.LIMIT.message)
    return stored, Safe.text(stored)
end

-- A diagnostic string (stack, locals) as stored: cut string, or a marker.
local function diagnosticOf(v, limit)
    if not Safe.readable(v) then return Safe.marker(v) end
    if type(v) ~= "string" then return { unavailable = true, reason = "not a string" } end
    return Safe.cut(v, limit)
end

-- Queue and drain ----------------------------------------------------------------

function Capture.pending()
    return S.tail - S.head + 1, S.countKeys
end

local function push(rec)
    if S.tail - S.head + 1 >= Capture.QUEUE_MAX then
        S.stats.queueDropped = S.stats.queueDropped + 1
        return false
    end
    S.tail = S.tail + 1
    S.queue[S.tail] = rec
    return true
end

-- A watchdog: a timer that never fired (for whatever reason) must not stop the
-- drain for good. A flag older than a second is re-armed by the next schedule.
function Capture.schedule()
    if S.scheduled and API.Uptime() - (S.scheduledAt or 0) <= 1 then return end
    S.scheduled = true
    S.scheduledAt = API.Uptime()
    local ok, scheduled = pcall(API.After, 0, Capture.drain)
    if not ok or not scheduled then
        S.scheduled = false
        S.stats.scheduleFailed = S.stats.scheduleFailed + 1
    end
end

-- The sink (Store) gets each record, then each count entry once the queue is empty.
function Capture.drain()
    S.scheduled = false
    pcall(Capture.check, "drain")
    local sink = Capture.sink
    if not sink then return end
    local start, n = API.ProfileMs(), 0
    while S.head <= S.tail do
        local rec = S.queue[S.head]
        S.queue[S.head] = nil
        S.head = S.head + 1
        local ok, err = pcall(sink.record, rec)
        if not ok then S.stats.drainFailed = S.stats.drainFailed + 1; fail(err) end
        n = n + 1
        if n >= Capture.DRAIN_RECORDS or API.ProfileMs() - start >= Capture.DRAIN_MS then break end
    end
    if S.head > S.tail then
        S.head, S.tail = 1, 0
        if S.countKeys > 0 then
            -- swap first: each entry is transferred once, a failure drops it, never replays it
            local map = S.counts
            S.counts, S.countKeys = {}, 0
            for key, e in next, map do
                local ok, err = pcall(sink.count, e.kind, key, e.n, e.head)
                if not ok then S.stats.drainFailed = S.stats.drainFailed + 1; fail(err) end
            end
        end
    end
    if S.head <= S.tail or S.countKeys > 0 then Capture.schedule() end
end

-- Tiers ----------------------------------------------------------------------------

local function remember(key)
    if not key or S.seen[key] then return end
    if S.seenN >= Capture.SEEN_MAX then S.seen, S.seenN = {}, 0 end
    S.seen[key] = true
    S.seenN = S.seenN + 1
end

function Capture.tier(key, now)
    if take(B.full, now) then return "full" end
    if key and not S.seen[key] and take(B.discovery, now) then return "full" end
    if take(B.top, now) then return "top" end
    if key then return "count" end
    return "suppressed"
end

-- A count-tier occurrence. For a message not seen this session the entry keeps
-- the message head (≤ 512 bytes), so a flood of distinct errors still leaves
-- their text: the drain makes a stackless problem of it.
local function count(kind, key, text)
    local e = S.counts[key]
    if not e then
        if S.countKeys >= Capture.COUNT_KEYS then
            S.stats.suppressed[kind] = S.stats.suppressed[kind] + 1
            return
        end
        e = { kind = kind, n = 0, head = (not S.seen[key] and text) and text:sub(1, Sig.KEY_HEAD) or nil }
        S.counts[key] = e
        S.countKeys = S.countKeys + 1
    end
    e.n = e.n + 1
    Capture.schedule()
end

-- Occurrence-time facts, each read guarded.
local function facts(rec)
    rec.at = API.Now()
    rec.inCombat = API.InCombat()
    local ok, kind = pcall(API.InstanceType)
    rec.instanceType = ok and kind or nil
    local okT, tl = pcall(API.CVar, "taintLog")
    rec.taintLog = okT and tl or nil
end

-- The native handler ----------------------------------------------------------------

-- Message keys by message text: a repeated message is hashed once (bounded).
local keyCache, keyCacheN = {}, 0
local function messageKey(kind, text)
    local cacheKey = kind .. "\0" .. text
    local k = keyCache[cacheKey]
    if k then return k end
    k = Sig.messageKey(kind, text)
    if keyCacheN >= 200 then keyCache, keyCacheN = {}, 0 end
    keyCache[cacheKey] = k
    keyCacheN = keyCacheN + 1
    return k
end

-- Runs inside a pcall: handler → pcall → body, and event → pcall → body, the
-- same nesting on both paths. The stack level is computed HERE, and debugstack /
-- debuglocals are called DIRECTLY from here: through pcall, its C frame would be
-- level 1 and every level one short (Blizzard's own handler calls them directly).
-- If one of them throws, the body's pcall counts the failure.
local function body(kind, msg, event, entry)
    local now = API.Uptime()
    local stored, text = messageOf(msg)
    local key = text and messageKey(kind, text) or nil
    local tier = Capture.tier(key, now)
    if tier == "count" then count(kind, key, text); return end
    if tier == "suppressed" then S.stats.suppressed[kind] = S.stats.suppressed[kind] + 1; return end
    remember(key)

    local level, origin
    local errHeight = G("GetErrorCallstackHeight")
    local height = G("GetCallstackHeight")
    local eh = errHeight and errHeight() or nil
    if not event and type(eh) == "number" and Safe.readable(eh) and height then
        -- An error in a file's main chunk, while it loads, has an error height of 0
        -- (measured, P5, 70959): the formula then lands one past the stack, which is
        -- empty. Height 1 lands on the chunk's line.
        if eh < 1 then eh = 1 end
        level = height() - (eh - 1)
        origin = "error"
    else
        level = Capture.FALLBACK_LEVEL
        origin = event and "event" or "fallback"
    end

    local rec = { kind = kind, tier = tier, provider = "native", stackOrigin = origin,
        entry = entry or (event and "event") or "handler",
        message = stored, uptime = now, key = key, event = event }
    local debugstack = G("debugstack")
    if debugstack then
        local s
        if tier == "top" then s = debugstack(level, Sig.LINES, 0) else s = debugstack(level) end
        rec.stack = diagnosticOf(s, Capture.LIMIT.stack)
    else
        rec.stack = { unavailable = true, reason = "no debugstack" }
    end
    local debuglocals = G("debuglocals")
    if tier == "full" and S.settings.locals and debuglocals and not event then
        rec.locals = diagnosticOf(debuglocals(level, true), Capture.LIMIT.locals)
    else
        rec.locals = { unavailable = true, reason = S.settings.locals and tier or "off" }
    end
    facts(rec)
    push(rec)
    Capture.schedule()          -- even when the queue was full: pending work must reach the watchdog
end
Capture._body = body

-- Liveness (DESIGN §3): remember which handler was installed when a real error
-- reached us. Only a call made while the client has an error in flight
-- (GetErrorCallstackHeight() a number; nil for a direct geterrorhandler()(msg)
-- call, measured in FOREVER-PROBE §7) is evidence that the installed handler passed
-- it on. A nil-height call records the error and changes nothing here. Collector
-- mode is never left from here.
local function liveness()
    if S.mode == "collector" then return end
    local eh = G("GetErrorCallstackHeight")
    local h = eh and eh()
    if type(h) ~= "number" or not Safe.readable(h) then return end
    local get = G("geterrorhandler")
    local current = get and get()
    if current == Capture.front then return end            -- our front is installed: mode stays
    S.aliveVia = current
    if current ~= Capture.handler and (S.mode == "displaced" or S.mode == "native" or S.mode == "front") then
        S.mode = "chained"
    end
end

-- A call into Bugsy while the front passes an error on. The first call with that
-- same message is the next handler passing it back (expected: passReturned); any
-- other is a distinct report made meanwhile, dropped (passSuppressed, a loss the
-- status and reports state). An unreadable message cannot be compared: its first
-- re-entry counts as the return.
local function whilePassing(msg)
    local same = true
    if Safe.readable(msg) and Safe.readable(S.passingMsg) then same = rawequal(msg, S.passingMsg) end
    if same and not S.passReturnedOnce then
        S.passReturnedOnce = true
        S.stats.passReturned = S.stats.passReturned + 1
    else
        S.stats.passSuppressed = S.stats.passSuppressed + 1
    end
end

-- Our original handler. Order (Codex, front design): the passing guard, collector
-- exclusion, the busy guard, liveness, capture.
-- A health observation changed: Bugsy.lua sets this to queue one notice (cheap; never chat here).
local function healthChanged()
    if Capture.onHealth then
        local ok, err = pcall(Capture.onHealth)
        if not ok then fail(err) end
    end
end

-- One eligible delivery (#14): a call that passed the guards, with a readable numeric
-- error height (0 included; nil = a direct report, not counted). Counted before any
-- tier, queue or store decision. Returns true when the message is the client's pause
-- notice (English, exact): that one is a health observation, not a problem.
local function observeDelivery(msg)
    local eh = G("GetErrorCallstackHeight")
    local h = eh and eh()
    if type(h) ~= "number" or not Safe.readable(h) then return false end
    S.stats.deliveries = S.stats.deliveries + 1
    local now = API.Uptime()
    local b = S.burst
    if b.t == now then b.n = b.n + 1 else b.t, b.n = now, 1 end
    local isNotice = type(msg) == "string" and Safe.readable(msg) and msg == Capture.PAUSE_NOTICE_EN
    local p = S.health.pause
    if p and not isNotice and now ~= p.bucket then p.deliveredAfter = p.deliveredAfter + 1 end
    if b.n >= Capture.BURST_LIMIT or isNotice then
        if not p then
            p = { status = "suspected", evidence = "burst", at = API.Now(), session = S.session,
                observedCalls = 0, deliveredAfter = 0, noticeSeen = 0, bucket = now }
            S.health.pause = p
            healthChanged()
        end
        if b.n >= Capture.BURST_LIMIT and now == p.bucket and b.n > p.observedCalls then p.observedCalls = b.n end
    end
    if isNotice then
        p.noticeSeen = p.noticeSeen + 1
        if p.status ~= "reported" then
            p.status = "reported"
            p.evidence = (p.observedCalls >= Capture.BURST_LIMIT) and "both" or "message"
            healthChanged()
        end
        return true
    end
    return false
end
local function delivered(msg)
    local ok, notice = pcall(observeDelivery, msg)
    if not ok then fail(notice); return false end
    return notice
end

function Capture.handler(msg)
    if S.passing then whilePassing(msg); return end
    if S.mode == "collector" then S.stats.nativeInCollector = S.stats.nativeInCollector + 1; return end
    if S.busy then S.nested = S.nested + 1; return end
    liveness()
    if delivered(msg) then return end
    S.busy = true
    local ok, err = pcall(body, "error", msg)
    S.busy = false
    if not ok then fail(err) end
end

-- The front handler: installed ahead of another addon's handler (DESIGN §3, D14).
-- It captures (front -> pcall -> body: the same nesting as Capture.handler, so the
-- measured levels hold), then passes the call on, synchronously and once, to the
-- handler it replaced. Best effort: a distinct report made synchronously while that
-- handler runs is dropped and counted (passSuppressed); a handler that defers its
-- pass-on reaches Capture.handler later and is recorded again. The next handler runs
-- outside Bugsy's budget; its failures are counted, never rethrown.
function Capture.front(msg, ...)
    if S.passing then whilePassing(msg); return end
    if S.mode == "collector" then
        S.stats.nativeInCollector = S.stats.nativeInCollector + 1
    elseif S.busy then
        S.nested = S.nested + 1
    else
        liveness()
        if not delivered(msg) then
            S.busy = true
            local ok, err = pcall(body, "error", msg, nil, "front")
            S.busy = false
            if not ok then fail(err) end
        end
    end
    local nextH = S.nextHandler
    if not nextH then return end
    local F = S.forward
    if F.suspended then F.skipped = F.skipped + 1; return end
    local t0 = API.ProfileTime()
    S.passing, S.passingMsg, S.passReturnedOnce = true, msg, false
    local okF, errF = pcall(nextH, msg, ...)
    S.passing, S.passingMsg = false, nil          -- first, before anything that can fail
    if not okF then S.stats.forwardFailed = S.stats.forwardFailed + 1; fail(errF) end
    local okA, errA = pcall(Capture._accountForward, t0)
    if not okA then fail(errA) end
end

-- The circuit breaker (#11, D16): time each pass-on (slow calls that threw included);
-- one call at FRONT_SLOW_CALL_MS, or FRONT_SLOW_WINDOW_MS within the rolling window
-- (BINS stamped bins of BIN_MS), latches the suspension for this UI session. It
-- cannot bound the first slow call; it stops the next ones. Timing that is missing,
-- unreadable or backwards is counted, never taken as fast or slow.
-- The profiler timer is shared: another addon can reset it (debugprofilestart), so a
-- reading earlier than the last one is a discontinuity, within a call or between
-- calls. Then the window's history is meaningless and is discarded (Codex, PR #17);
-- a bin stamped "in the future" never counts either.
local function clearBins(F)
    for k = 1, Capture.BINS do F.stamps[k], F.bins[k] = nil, nil end
end

function Capture._accountForward(t0)
    local F = S.forward
    local t1 = API.ProfileTime()
    if t0 and F.lastT and t0 < F.lastT then clearBins(F) end          -- reset between calls
    if not t0 or not t1 or t1 < t0 then
        F.timingUnavailable = F.timingUnavailable + 1
        if t0 and t1 then clearBins(F) end                           -- reset within the call
        F.lastT = t1
        return
    end
    F.lastT = t1
    local elapsed = t1 - t0
    local bin = math.floor(t1 / Capture.BIN_MS)
    local i = bin % Capture.BINS + 1
    if F.stamps[i] ~= bin then F.stamps[i], F.bins[i] = bin, 0 end
    F.bins[i] = F.bins[i] + elapsed
    local window = 0
    for k = 1, Capture.BINS do
        local stamp = F.stamps[k]
        local age = stamp and (bin - stamp)
        if age and age >= 0 and age < Capture.BINS then window = window + F.bins[k] end
    end
    local reason
    if elapsed >= Capture.FRONT_SLOW_CALL_MS then reason = "call"
    elseif window >= Capture.FRONT_SLOW_WINDOW_MS then reason = "window" end
    if reason and not F.suspended then
        F.suspended, F.reason, F.at = true, reason, API.Now()
        F.elapsedMs, F.windowMs = elapsed, window
        F.thresholdMs = (reason == "call") and Capture.FRONT_SLOW_CALL_MS or Capture.FRONT_SLOW_WINDOW_MS
        healthChanged()
    end
end

-- Events: LUA_WARNING and ADDON_ACTION_*, owned by our frame in EVERY mode (the
-- collector reader skips its copies of them): every occurrence counts, in any
-- locale, with no takeover window to double-count.
local EVENTS = {
    LUA_WARNING = "warning",
    ADDON_ACTION_BLOCKED = "blocked",
    ADDON_ACTION_FORBIDDEN = "forbidden",
}

local function readableString(v)
    if Safe.readable(v) and type(v) == "string" then return v:sub(1, 200) end
    return nil
end

local function onEvent(_, event, a1, a2)
    local kind = EVENTS[event]
    if not kind then return end
    if S.busy then S.nested = S.nested + 1; return end
    -- The message is built here, then body runs as event → pcall → body: the
    -- handler's nesting, so one fallback level serves both (P2 measures it).
    local ev = { name = event }
    local msg
    if kind == "warning" then
        msg = a1
    else
        ev.addon, ev.func = readableString(a1), readableString(a2)
        msg = event .. ": " .. (ev.addon and ("'" .. ev.addon .. "'") or "<restricted addon>")
            .. " called " .. (ev.func or "<restricted function>")
    end
    S.busy = true
    local ok, err = pcall(body, kind, msg, ev)
    S.busy = false
    if not ok then fail(err) end
end

local frame
local function setEvents(on)
    if not frame then
        local create = G("CreateFrame")
        if not create then return end
        frame = create("Frame")
        frame:SetScript("OnEvent", onEvent)
    end
    for event in next, EVENTS do
        if on then pcall(frame.RegisterEvent, frame, event) else pcall(frame.UnregisterEvent, frame, event) end
    end
end

-- The collector provider ------------------------------------------------------------
-- Only Lua errors are read from the collector: its copies of warnings and blocked
-- actions (messages starting "LUA_WARNING: " or "[ADDON_ACTION_", the "[%s] "
-- prefix being the same in every locale) are skipped, since our event frame owns them.

function Capture.collectorUsable()
    local bg = rawget(_G, Capture.COLLECTOR.global)
    local reg = rawget(_G, "EventRegistry")
    if type(bg) ~= "table" or type(reg) ~= "table" then return nil end
    local ok = pcall(function()
        assert(type(bg.GetDB) == "function" and type(bg.GetErrorByID) == "function"
            and type(bg.GetSessionId) == "function" and type(reg.RegisterCallback) == "function")
    end)
    return ok and bg or nil
end

local function numberField(obj, k)
    local v = rawget(obj, k)
    if Safe.readable(v) and type(v) == "number" then return v end
    return nil
end

local function isEventCopy(text)
    return text ~= nil and (text:sub(1, 13) == "LUA_WARNING: " or text:sub(1, 14) == "[ADDON_ACTION_")
end
Capture.isEventCopy = isEventCopy

-- Read one of the collector's error objects. live: inside its handler (occurrence-time
-- facts are real); else a reconcile (facts are markers). Evidence copied as strings now.
function Capture.readCollector(bg, obj, live)
    if type(obj) ~= "table" or not Safe.readable(obj) then return end
    local counter = numberField(obj, "counter")
    if not counter then return end
    local stored, text = messageOf(rawget(obj, "message"))
    local okS, cur = pcall(bg.GetSessionId, bg)
    local session = numberField(obj, "session")
    local w = S.water[obj]
    local add, incomplete = 0, false
    if w == nil or counter < w then
        -- a seed: the counter is not this session's count, except for a brand-new
        -- object seen live (counter 1: this very error)
        if live and counter == 1 then add = 1
        elseif okS and session ~= nil and type(cur) == "number" and Safe.readable(cur) and session == cur then
            add, incomplete = 1, true
        end
    else
        add = counter - w
    end
    S.water[obj] = counter
    if add <= 0 or isEventCopy(text) then return end

    local rawLocals = rawget(obj, "locals")
    local locals
    if not S.settings.locals then
        locals = { unavailable = true, reason = "off" }
    elseif not Safe.readable(rawLocals) then        -- checked before any comparison
        locals = Safe.marker(rawLocals)
    elseif rawLocals == nil then
        locals = { unavailable = true, reason = "collector" }
    else
        locals = diagnosticOf(rawLocals, Capture.LIMIT.locals)
    end
    local rec = { kind = "error", tier = "full", provider = "collector", stackOrigin = "collector", entry = "collector",
        message = stored, key = text and messageKey("error", text) or nil,
        stack = diagnosticOf(rawget(obj, "stack"), Capture.LIMIT.stack), locals = locals,
        count = add, countIncomplete = incomplete or nil, uptime = API.Uptime() }
    if live then
        facts(rec)
    else
        local m = { unavailable = true, reason = "backfill" }
        rec.inCombat, rec.instanceType, rec.taintLog = m, m, m
        rec.at = numberField(obj, "time") or API.Now()
        rec.atApproximate = true
    end
    rec.observedAt = API.Now()
    push(rec)
    Capture.schedule()          -- even when the queue was full: pending work must reach the watchdog
end

local function onCollected(_, tableID)
    if S.mode ~= "collector" then return end
    if S.busy then S.nested = S.nested + 1; return end
    local bg = Capture.collectorUsable()
    if not bg or not Safe.readable(tableID) or type(tableID) ~= "string" then return end
    S.busy = true
    local ok, err = pcall(function()
        Capture.readCollector(bg, bg:GetErrorByID(tableID), true)
    end)
    S.busy = false
    if not ok then fail(err) end
end

-- The switch: one routine, no yield. Register the live callback, then reconcile
-- the database through the shared watermark. Our event frame stays registered.
function Capture.useCollector(bg)
    S.mode = "collector"
    if not S.subscribed then
        rawget(_G, "EventRegistry"):RegisterCallback(Capture.COLLECTOR.event, onCollected, Capture)
        S.subscribed = true
    end
    local ok, db = pcall(bg.GetDB, bg)
    if ok and type(db) == "table" and Safe.readable(db) then
        for i = 1, #db do
            local okR, err = pcall(Capture.readCollector, bg, rawget(db, i), false)
            if not okR then fail(err) end
        end
    end
end

-- Install and watch -----------------------------------------------------------------

-- Records a transition: only when the current handler differs from the last one recorded.
local function noteChange(afterAddon, action)
    local current = G("geterrorhandler") and G("geterrorhandler")()
    if current == S.lastHandler then return end
    S.lastHandler = current
    local list = S.changes
    list[#list + 1] = { at = API.Now(), afterAddon = afterAddon, action = action }
    if #list > Capture.CHANGES_KEPT then
        table.remove(list, 1)
        S.changesDropped = S.changesDropped + 1
    end
end

-- At our file load. Our event frame is registered in every mode.
function Capture.install()
    setEvents(true)
    local bg = Capture.collectorUsable()
    if bg then
        Capture.useCollector(bg)
        return S.mode
    end
    local set, get = G("seterrorhandler"), G("geterrorhandler")
    if set then pcall(set, Capture.handler) end
    if (get and get()) == Capture.handler then
        S.lastHandler = Capture.handler
    else
        S.mode = "displaced"       -- seterrorhandler did nothing: someone made it a no-op
        noteChange(ADDON)
    end
    return S.mode
end

-- One attempt a UI session to install the front handler ahead of `current` (DESIGN
-- §3, D14). The attempt is marked first; success is defined only by the verified
-- identity afterwards, whether the setter returned or threw. The current global
-- setter is used (a collector's no-op setter makes it fail; nothing is restored).
local function tryFront(current, afterAddon)
    if S.frontTried or S.frontEnabled ~= true then return end
    if type(current) ~= "function" or current == Capture.handler or current == Capture.front then return end
    S.frontTried = true
    local set, get = G("seterrorhandler"), G("geterrorhandler")
    if not set or not get then return end
    S.nextHandler = current
    pcall(set, Capture.front)
    local okG, now = pcall(get)
    if okG and now == Capture.front then
        S.mode = "front"
        noteChange(afterAddon, "front")
    else
        S.nextHandler = nil
    end
end
Capture._tryFront = tryFront

-- At every ADDON_LOADED, at PLAYER_LOGIN, in every drain and when the window opens.
-- A changed handler is a transition, not a verdict: "displaced" until a real error
-- still reaches our handler ("chained", see liveness), and the collector's API, when
-- it appears, is used from any of these modes. Otherwise Bugsy tries, once, to put
-- its front handler ahead of the new one (D14; the passing-on keeps that addon
-- working). It never takes the handler back without passing errors on.
function Capture.check(afterAddon)
    if S.mode == "collector" then return S.mode end
    local get = G("geterrorhandler")
    local current = get and get()
    if current ~= Capture.handler and current ~= Capture.front and current ~= S.lastHandler then
        noteChange(afterAddon)
        -- an error already reached us through this very handler: chained, not displaced
        S.mode = (S.aliveVia == current) and "chained" or "displaced"
    end
    if S.mode ~= "native" and S.mode ~= "front" then
        local bg = Capture.collectorUsable()
        if bg then
            Capture.useCollector(bg)
        elseif S.mode == "displaced" or S.mode == "chained" then
            tryFront(current, afterAddon)
        end
    end
    return S.mode
end

-- Snapshots for reports (bounded scalars only; copies, not the live state).
function Capture.healthSnapshot()
    local p = S.health.pause
    if not p then return nil end
    return { pause = { status = p.status, evidence = p.evidence, at = p.at, session = p.session,
        observedCalls = p.observedCalls, deliveredAfter = p.deliveredAfter, noticeSeen = p.noticeSeen } }
end

function Capture.forwardSnapshot()
    local F = S.forward
    if not S.nextHandler and not F.suspended then return nil end
    return { suspended = F.suspended, reason = F.reason, at = F.at, elapsedMs = F.elapsedMs,
        windowMs = F.windowMs, thresholdMs = F.thresholdMs, skipped = F.skipped,
        timingUnavailable = F.timingUnavailable }
end

-- The mode's own limits; Capture.limits adds the health observations.
local function modeLimits()
    if S.mode == "collector" then
        return {
            "Lua errors come from another error collector: it does not store errors whose message is secret.",
            "That collector drops every error past 10 a second, uncounted.",
            "Stacks may come from an earlier repeat of the error.",
        }
    elseif S.mode == "displaced" then
        return { "Another addon replaced the error handler, and no error has reached Bugsy since: "
            .. "Bugsy may not see Lua errors this session." }
    elseif S.mode == "chained" then
        return { "Another addon's error handler passes errors on to Bugsy; stacks may start in its frames.",
            "That addon may keep some errors for itself, or stop passing errors on after a flood." }
    elseif S.mode == "front" then
        return { "Bugsy captures each Lua error first, then passes it on to another addon's error handler.",
            "An error that handler raises while handling one is counted as dropped; one it passes on later "
            .. "is recorded twice.",
            "That handler's stacks may include Bugsy's frames." }
    end
    return {}
end

-- Blizzard's own displays of what Bugsy records (B-18, #33): the blocked-action popup
-- (ADDON_ACTION_FORBIDDEN) and the "Interface action failed" message (ADDON_ACTION_BLOCKED),
-- which on Forever go through Blizzard_Game's router (GameEvent, registered while it loads,
-- before any addon), and the Lua warning window (LUA_WARNING on ScriptErrorsFrame). UIParent
-- doesn't register them on Forever; it's checked anyway. Bugsy's own event frame keeps
-- recording all three. The router's handlers are its own locals and can't be put back from
-- outside, so this runs once at load when the setting is on, and turning it off takes
-- effect from the next session. Returns what was unregistered, as "<frame>:<event>".
Capture.POPUP_EVENTS = { "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED" }
function Capture.SuppressPopups()
    local done = S.popupsHidden or {}
    local function note(what)
        for _, d in ipairs(done) do if d == what then return end end
        done[#done + 1] = what
    end
    local router = G("GameEvent")
    local unregister = type(router) == "table" and rawget(router, "UnregisterInternalEvent")
    if type(unregister) == "function" then
        for _, ev in ipairs(Capture.POPUP_EVENTS) do
            if pcall(unregister, ev) then note("GameEvent:" .. ev) end
        end
    end
    local frames = {
        { name = "UIParent", events = Capture.POPUP_EVENTS },
        { name = "ScriptErrorsFrame", events = { "LUA_WARNING" } },
    }
    for _, f in ipairs(frames) do
        local frame = G(f.name)
        if type(frame) == "table" and type(frame.IsEventRegistered) == "function" then
            for _, ev in ipairs(f.events) do
                local ok, on = pcall(frame.IsEventRegistered, frame, ev)
                if ok and on == true and pcall(frame.UnregisterEvent, frame, ev) then note(f.name .. ":" .. ev) end
            end
        end
    end
    S.popupsHidden = done
    return done
end

-- What the status line, /bugsy status and reports say: the mode's limits, then the
-- health observations (#14, #11), whatever the mode.
function Capture.limits()
    local out = modeLimits()
    local p = S.health.pause
    if p then
        if p.status == "reported" then
            out[#out + 1] = "Bugsy received a message saying Lua error reporting is paused until reload."
        else
            out[#out + 1] = "A large error burst was observed. The game may have paused Lua error reporting; "
                .. "Bugsy cannot verify whether more errors are being delivered. Reload to reset reporting."
        end
        if p.deliveredAfter > 0 then
            out[#out + 1] = ("Bugsy has received %d errors since, so reporting did not fully stop."):format(p.deliveredAfter)
        end
        out[#out + 1] = "Warnings and blocked-action events are captured separately."
    end
    if S.forward.suspended then
        out[#out + 1] = "Bugsy stopped passing errors to the handler it replaced after a slow call. Bugsy still "
            .. "captures the errors it receives; that handler no longer gets them from Bugsy. Reload to retry."
    end
    return out
end

ns._test = ns._test or {}
ns._test.Capture = Capture

-- Installed as soon as this file has loaded: an error in any later file of ours,
-- or of an addon loading after us, is caught.
Capture.install()
