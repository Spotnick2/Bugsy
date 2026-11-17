-- Store.lua: incidents (DESIGN.md §4). Turns drained records into problems in
-- BugsyDB: signatures, grouping, samples, call paths, versions, sessions, mutes,
-- caps and eviction, clearing. Runs only in the drain or on the player's request.

local ADDON, ns = ...
local Safe, API, Sig, Capture, Attr, Context = ns.Safe, ns.API, ns.Signature, ns.Capture, ns.Attribution, ns.Context
local Store = {}
ns.Store = Store

Store.FORMAT = 1
Store.MAX_PROBLEMS = 300
Store.MAX_MUTES = 200
Store.FIRST, Store.LAST = 2, 3
Store.CALL_PATHS = 20
Store.ADDONS, Store.VERSIONS = 8, 10
Store.RECENT_SESSIONS = 3
Store.TITLE_MAX = 200
-- New problems a session may create; past it, a new one is only counted, so one
-- session's flood of unique errors cannot evict every older problem.
Store.MAX_NEW_PER_SESSION = 150

local db
local listeners = {}

function Store.db() return db end
function Store.session() return db and db.session end

function Store.OnChange(fn) listeners[#listeners + 1] = fn end
local function changed(what, problem)
    for _, fn in ipairs(listeners) do pcall(fn, what, problem) end
end

-- Loading -------------------------------------------------------------------

local function randomHex(n)
    local out = {}
    for i = 1, n do out[i] = string.format("%x", math.random(0, 15)) end
    return table.concat(out)
end
Store.randomHex = randomHex

local function isCount(v) return type(v) == "number" and v == v and v >= 0 and v < 2 ^ 53 end

-- A problem read back from disk is untrusted: keep it only if its shape holds,
-- then rebuild every nested field a caller relies on (Codex, PR #2).
local function validProblem(id, p)
    return type(id) == "string" and #id <= 40 and type(p) == "table" and p.id == id
        and type(p.kind) == "string" and isCount(p.count) and type(p.title) == "string"
        and isCount(p.firstSeen) and isCount(p.lastSeen) and isCount(p.lastSession)
end

local function isStr(v, max) return type(v) == "string" and (max == nil or #v <= max) end
local function optStr(v, max) return v == nil or isStr(v, max) end

-- A list rebuilt from its array part: each entry through fn (nil drops it), at
-- most max entries (the first ones, or the last ones with fromEnd).
local function cleanList(list, max, fn, fromEnd)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, v in ipairs(list) do
        local c = fn(v)
        if c ~= nil then out[#out + 1] = c end
    end
    while #out > max do table.remove(out, fromEnd and 1 or #out) end
    return out
end

local function str(v) return isStr(v, 512) and v or nil end

-- Stored evidence (message, stack, locals): a string, a cut string or a marker.
local function cleanEvidence(v)
    if type(v) == "string" then return v end
    if type(v) == "table" and optStr(v.text) and optStr(v.reason, 200) then return v end
    return { unavailable = true, reason = "damaged" }
end

local function cleanSample(s)
    if type(s) ~= "table" then return nil end
    for _, k in ipairs({ "provider", "tier", "stackOrigin", "exactSignature", "entry" }) do
        if not optStr(s[k], 64) then s[k] = nil end
    end
    if s.build ~= nil and type(s.build) ~= "number" and not isStr(s.build, 16) then s.build = nil end
    if s.at ~= nil and not isCount(s.at) then s.at = nil end
    s.message, s.stack, s.locals = cleanEvidence(s.message), cleanEvidence(s.stack), cleanEvidence(s.locals)
    local e = s.event
    if e ~= nil and (type(e) ~= "table" or not optStr(e.name, 64) or not optStr(e.addon, 200) or not optStr(e.func, 200)) then
        s.event = nil
    end
    local versions = {}
    if type(s.versions) == "table" then
        for name, v in pairs(s.versions) do
            if isStr(name, 64) and isStr(v, 32) then versions[name] = v end
        end
    end
    s.versions = versions
    return s
end

local function cleanAddon(a)
    if type(a) ~= "table" or not isStr(a.name, 64) then return nil end
    local versions, n = {}, 0
    if type(a.versions) == "table" then
        for v, count in pairs(a.versions) do
            if isStr(v, 32) and isCount(count) and (v == "other" or n < Store.VERSIONS) then
                versions[v] = count
                if v ~= "other" then n = n + 1 end
            end
        end
    end
    return { name = a.name, versions = versions, versionCount = n }
end

local function cleanAttribution(a)
    if type(a) ~= "table" then return nil end
    local named, suspect = a.named, a.suspect
    if named ~= nil and (type(named) ~= "table" or not isStr(named.addon, 200) or not isStr(named.source, 64)) then
        return nil
    end
    if suspect ~= nil then
        if type(suspect) ~= "table" or not isStr(suspect.addon, 200) or not isStr(suspect.confidence, 16)
            or not optStr(suspect.library, 200) then
            return nil
        end
        suspect.evidence = cleanList(suspect.evidence, 10, str)
    end
    a.inStack = cleanList(a.inStack, 20, function(f)
        if type(f) == "table" and isStr(f.folder, 200) and optStr(f.library, 200) and optStr(f.host, 200) then return f end
    end)
    return a
end

local function optCount(v) return isCount(v) and v or nil end

local function repairProblem(p)
    if #p.title > Store.TITLE_MAX then p.title = p.title:sub(1, Store.TITLE_MAX) end
    if not optStr(p.sigAlgo, 8) then p.sigAlgo = nil end
    if not optStr(p.messageKey, 40) then p.messageKey = nil end
    p.firstSession = optCount(p.firstSession) or p.lastSession
    p.sessionCount = optCount(p.sessionCount) or 1
    p.sampledOut = optCount(p.sampledOut) or 0
    p.unconfirmedRepeats = optCount(p.unconfirmedRepeats)
    p.callPathsOverflow = optCount(p.callPathsOverflow)
    p.addonsOverflow = optCount(p.addonsOverflow)
    for _, k in ipairs({ "countIncomplete", "restricted", "bucket", "muted", "noise" }) do
        p[k] = p[k] == true or nil
    end
    p.recentSessions = cleanList(p.recentSessions, Store.RECENT_SESSIONS, optCount, true)
    p.callPaths = cleanList(p.callPaths, Store.CALL_PATHS, function(v) return isStr(v, 64) and v or nil end)
    p.addons = cleanList(p.addons, Store.ADDONS, cleanAddon)
    p.first = cleanList(p.first, Store.FIRST, cleanSample)
    p.last = cleanList(p.last, Store.LAST, cleanSample, true)
    p.attribution = cleanAttribution(p.attribution)
end
Store._repair = repairProblem

function Store.adopt(saved)
    local fresh = type(saved) ~= "table" or saved.format ~= Store.FORMAT
    if fresh then saved = { format = Store.FORMAT } end
    saved.stats = type(saved.stats) == "table" and saved.stats or {}
    for _, k in ipairs({ "evicted", "dropped" }) do
        if not isCount(saved.stats[k]) then saved.stats[k] = 0 end
    end
    if type(saved.sourceId) ~= "string" or not saved.sourceId:match("^%x+$") or #saved.sourceId ~= 16 then
        saved.sourceId = randomHex(16)
    end
    if not isCount(saved.session) then saved.session = 0 end
    saved.session = saved.session + 1
    if type(saved.settings) ~= "table" then saved.settings = {} end
    saved.settings.locals = saved.settings.locals == true
    saved.settings.notices = saved.settings.notices ~= false
    saved.settings.sound = saved.settings.sound ~= false
    -- the chosen alert sound's FileDataID (#19); Bugsy.lua maps an unknown one to the default
    if type(saved.settings.soundId) ~= "number" then saved.settings.soundId = nil end
    saved.settings.front = saved.settings.front ~= false

    local problems = type(saved.problems) == "table" and saved.problems or {}
    local kept, n = {}, 0
    for id, p in pairs(problems) do
        if validProblem(id, p) and pcall(repairProblem, p) then kept[id] = p; n = n + 1
        else saved.stats.dropped = saved.stats.dropped + 1 end
    end
    saved.problems = kept
    saved.problemCount = n

    local mutes, m = {}, 0
    if type(saved.mutes) == "table" then
        for id, at in pairs(saved.mutes) do
            if type(id) == "string" and #id <= 40 and isCount(at) and m < Store.MAX_MUTES then
                mutes[id] = at; m = m + 1
            end
        end
    end
    saved.mutes, saved.muteCount = mutes, m
    saved.stats.newCapped = isCount(saved.stats.newCapped) and saved.stats.newCapped or 0
    Store.sessionNew = 0
    db = saved
    return db
end

-- Mutes ---------------------------------------------------------------------

local function addMute(id, at)
    if not db.mutes[id] then
        if db.muteCount >= Store.MAX_MUTES then
            local oldest, oldestAt
            for k, t in pairs(db.mutes) do
                if not oldestAt or t < oldestAt then oldest, oldestAt = k, t end
            end
            if oldest then db.mutes[oldest] = nil; db.muteCount = db.muteCount - 1 end
        end
        db.muteCount = db.muteCount + 1
    end
    db.mutes[id] = at or API.Now()
end

function Store.SetMuted(id, on)
    local p = db and db.problems[id]
    if not p then return false end
    p.muted = on and true or nil
    if on then addMute(id)
    elseif db.mutes[id] then db.mutes[id] = nil; db.muteCount = db.muteCount - 1 end
    changed("mute", p)
    return true
end

-- Eviction -------------------------------------------------------------------

local function remove(id)
    if db.problems[id] then db.problems[id] = nil; db.problemCount = db.problemCount - 1 end
end

local function evictOne()
    local victim, victimSeen, mutedVictim, mutedSeen
    for id, p in pairs(db.problems) do
        if p.muted then
            if not mutedSeen or p.lastSeen < mutedSeen then mutedVictim, mutedSeen = id, p.lastSeen end
        elseif not victimSeen or p.lastSeen < victimSeen then
            victim, victimSeen = id, p.lastSeen
        end
    end
    if not victim and mutedVictim then
        addMute(mutedVictim)       -- it stays muted when it comes back
        victim = mutedVictim
    end
    if victim then
        remove(victim)
        db.stats.evicted = db.stats.evicted + 1
    end
end

-- Recording -------------------------------------------------------------------

local function firstLine(s)
    local line = s:match("^[^\n]*") or s
    if #line > Store.TITLE_MAX then line = line:sub(1, Store.TITLE_MAX) end
    return line
end

local function noteSession(p, session)
    if p.lastSession ~= session then
        p.sessionCount = (p.sessionCount or 0) + 1
        p.lastSession = session
    end
    local recent = p.recentSessions
    if recent[#recent] ~= session then
        recent[#recent + 1] = session
        if #recent > Store.RECENT_SESSIONS then table.remove(recent, 1) end
    end
end

local function noteCallPath(p, exact)
    for _, e in ipairs(p.callPaths) do if e == exact then return end end
    if #p.callPaths < Store.CALL_PATHS then p.callPaths[#p.callPaths + 1] = exact
    else p.callPathsOverflow = (p.callPathsOverflow or 0) + 1 end   -- occurrences on paths not kept, not paths
end

-- The involved addons of one occurrence, and their versions, into the problem.
local function noteAddons(p, names)
    local versions = {}
    for _, name in ipairs(names) do
        local info = Context.addonInfo(name)
        if info then
            versions[info.name] = info.version or "unknown"
            local entry
            for _, a in ipairs(p.addons) do if a.name == info.name then entry = a; break end end
            if not entry then
                if #p.addons < Store.ADDONS then
                    entry = { name = info.name, versions = {}, versionCount = 0 }
                    p.addons[#p.addons + 1] = entry
                else
                    p.addonsOverflow = (p.addonsOverflow or 0) + 1
                end
            end
            if entry then
                local v = info.version or "unknown"
                if entry.versions[v] then entry.versions[v] = entry.versions[v] + 1
                elseif entry.versionCount < Store.VERSIONS then
                    entry.versions[v] = 1; entry.versionCount = entry.versionCount + 1
                else
                    entry.versions.other = (entry.versions.other or 0) + 1
                end
            end
        end
    end
    return versions
end

-- Add a sample: the first FIRST kept forever, the last LAST as a ring in which a
-- weaker sample (top or count tier) evicts the oldest weaker one first, so full-stack evidence survives.
local function noteSample(p, occ)
    if #p.first < Store.FIRST then p.first[#p.first + 1] = occ; return end
    local last = p.last
    if #last < Store.LAST then last[#last + 1] = occ; return end
    local victim = 1
    if occ.tier ~= "full" then
        for i, s in ipairs(last) do if s.tier ~= "full" then victim = i; break end end
    end
    table.remove(last, victim)
    last[#last + 1] = occ
    p.sampledOut = (p.sampledOut or 0) + 1
end

-- The names involved in an occurrence: the suspect, the stack's addons, the named one.
local function involvedNames(attr)
    local names, seen = {}, {}
    local function add(n)
        if n and n ~= "" and not seen[n] and not n:match("^Blizzard_") then seen[n] = true; names[#names + 1] = n end
    end
    if attr.suspect then add(attr.suspect.addon) end
    for _, f in ipairs(attr.inStack) do add(f.host or f.folder) end
    if attr.named then add(attr.named.addon) end
    return names
end

-- One drained record (Capture's shape) into its problem.
function Store.record(rec)
    if not db then return end
    local kind = rec.kind
    local text = type(rec.message) == "string" and rec.message or Safe.text(rec.message)
    if not text and type(rec.message) == "table" and rec.message.unsupported then
        text = "<unsupported message: " .. tostring(rec.message.unsupported) .. ">"
    end
    local stackText = Safe.text(rec.stack)
    local exact, group, bucket = Sig.compute(kind, text, stackText)
    local session = db.session
    local now = API.Now()
    local count = isCount(rec.count) and rec.count or 1

    local attr = Attr.attribute({ kind = kind, message = text, stack = stackText,
        actionAddon = rec.event and rec.event.addon or nil })

    local p = db.problems[group]
    local isNew = not p
    if isNew then
        if Store.sessionNew >= Store.MAX_NEW_PER_SESSION then
            local s = Capture.state.stats.suppressed
            s[kind] = (s[kind] or 0) + count
            db.stats.newCapped = db.stats.newCapped + 1
            return
        end
        Store.sessionNew = Store.sessionNew + 1
        if db.problemCount >= Store.MAX_PROBLEMS then evictOne() end
        local title
        if text then title = firstLine(text)
        elseif bucket then title = "Restricted errors: details unavailable (may be unrelated)"
        else title = "Restricted message at " .. (Sig.where(Sig.lines(stackText)) or "?") end
        p = { id = group, sigAlgo = Sig.ALGO, kind = kind, title = title, messageKey = rec.key,
            restricted = text == nil or nil, bucket = bucket or nil,
            count = 0, firstSeen = rec.at or now, lastSeen = rec.at or now,
            firstSession = session, lastSession = session, sessionCount = 1, recentSessions = {},
            callPaths = {}, addons = {}, first = {}, last = {}, sampledOut = 0,
            muted = db.mutes[group] and true or nil }
        db.problems[group] = p
        db.problemCount = db.problemCount + 1
    end
    local firstThisSession = isNew or p.lastSession ~= session
    p.count = p.count + count
    if rec.countIncomplete then p.countIncomplete = true end
    local at = rec.at or now
    if at > p.lastSeen then p.lastSeen = at end
    if at < p.firstSeen then p.firstSeen = at end
    noteSession(p, session)
    noteCallPath(p, exact)
    local versions = noteAddons(p, involvedNames(attr))
    p.attribution = attr                    -- the latest reading; samples keep the evidence

    local occ = { at = at, atApproximate = rec.atApproximate, uptime = rec.uptime, session = session,
        build = Context.client().build, provider = rec.provider, tier = rec.tier, entry = rec.entry,
        stackOrigin = rec.stackOrigin, observedAt = rec.observedAt or now,
        inCombat = rec.inCombat, instanceType = rec.instanceType, taintLog = rec.taintLog,
        message = rec.message, stack = rec.stack, locals = rec.locals, exactSignature = exact,
        event = rec.event, handled = rec.handled, versions = versions, count = count }
    noteSample(p, occ)
    if count > 1 then p.sampledOut = (p.sampledOut or 0) + count - 1 end
    -- "new" = new to this session: a known problem coming back gets its notice too
    changed(firstThisSession and "new" or "update", p)
end

-- A count-tier entry: unconfirmed repeats of the one problem with this message key
-- seen this session. With no such problem and a message head (a message not seen
-- this session, past the capture budget), a stackless problem keeps its text.
-- Otherwise (two or more candidates, or no head) this session's suppressed counter.
function Store.count(kind, key, n, head)
    if not db then return end
    local match, matches = nil, 0
    for _, p in pairs(db.problems) do
        if p.messageKey == key and p.kind == kind and p.lastSession == db.session then
            match, matches = p, matches + 1
            if matches > 1 then break end
        end
    end
    if matches == 1 then
        match.unconfirmedRepeats = (match.unconfirmedRepeats or 0) + n
        changed("update", match)
    elseif matches == 0 and type(head) == "string" then
        Store.record({ kind = kind, tier = "count", provider = "native", stackOrigin = "none",
            message = head, stack = { unavailable = true, reason = "flood: over the capture budget" },
            locals = { unavailable = true, reason = "flood" }, key = key, count = n, at = API.Now() })
    else
        local s = Capture.state.stats.suppressed
        s[kind] = (s[kind] or 0) + n
    end
end

-- Queries and clearing ------------------------------------------------------------

-- filter: "session" | "previous" | "all"; showMuted: bool. Newest first.
function Store.List(filter, showMuted)
    local out = {}
    if not db then return out end
    local session = db.session
    for _, p in pairs(db.problems) do
        local inFilter = filter == "all" or (filter == "session" and p.lastSession == session)
        if filter == "previous" then
            for _, s in ipairs(p.recentSessions) do if s == session - 1 then inFilter = true; break end end
        end
        if inFilter and (showMuted or not p.muted) then out[#out + 1] = p end
    end
    table.sort(out, function(a, b)
        if a.lastSeen ~= b.lastSeen then return a.lastSeen > b.lastSeen end
        return a.id < b.id
    end)
    return out
end

function Store.Get(id) return db and db.problems[id] end

-- what: a problem id, "session" (problems seen this session) or "all".
function Store.Clear(what, alsoMutes)
    if not db then return 0 end
    local n = 0
    if what == "all" or what == "session" then
        local ids = {}
        for id, p in pairs(db.problems) do
            if what == "all" or p.lastSession == db.session then ids[#ids + 1] = id end
        end
        for _, id in ipairs(ids) do remove(id); n = n + 1 end
    elseif db.problems[what] then
        remove(what); n = 1
    end
    if alsoMutes then db.mutes, db.muteCount = {}, 0 end
    changed("clear")
    return n
end

ns._test = ns._test or {}
ns._test.Store = Store
