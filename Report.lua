-- Report.lua: the canonical report (REPORT-SCHEMA.md, bugsy.report/1), its
-- Markdown and JSON renderings, redaction of the player's own names, and size
-- trimming that always terminates (DESIGN.md §9). Facts, explanations and the
-- player's observations stay in separate sections.

local ADDON, ns = ...
local Safe, API, Json, Capture, Context, Patterns, Store =
    ns.Safe, ns.API, ns.Json, ns.Capture, ns.Context, ns.Patterns, ns.Store
local Report = {}
ns.Report = Report

Report.SCHEMA = "bugsy.report/1"
Report.MAX_BYTES = 65536
Report.MINIMAL_MAX = 16384
Report.ANSWER_MAX = 1024

local concat, format = table.concat, string.format

-- Copies ---------------------------------------------------------------------

-- A plain deep copy of saved data (depth-capped; functions and userdata dropped).
local function copy(v, depth)
    if type(v) ~= "table" then
        if type(v) == "function" or type(v) == "userdata" or type(v) == "thread" then return nil end
        return v
    end
    if (depth or 0) > 10 then return { truncated = true, reason = "depth" } end
    local out = {}
    for k, x in pairs(v) do
        if type(k) == "string" or type(k) == "number" then out[k] = copy(x, (depth or 0) + 1) end
    end
    return out
end
Report.copy = copy

local function cutText(s, max)
    if type(s) ~= "string" then return s end
    return Safe.cut(s, max)
end

local function answer(s)
    if type(s) ~= "string" or s == "" then return nil end
    return cutText(s, Report.ANSWER_MAX)
end

local function reportId()
    return "BGY-" .. Store.randomHex(8) .. "-" .. Store.randomHex(4)
end

-- Building --------------------------------------------------------------------

local function captureSection()
    local S = Capture.state
    local changes = {}
    for i, c in ipairs(S.changes) do changes[i] = { at = c.at, afterAddon = c.afterAddon } end
    local db = Store.db()
    return {
        mode = S.mode,
        handlerChanges = changes,
        handlerChangesDropped = S.changesDropped,
        limits = Capture.limits(),
        localsEnabled = S.settings.locals == true,
        session = { suppressed = copy(S.stats.suppressed), queueDropped = S.stats.queueDropped },
        lifetime = { evicted = db and db.stats.evicted or 0 },
    }
end

local function addonsSection(names)
    local out, seen = {}, {}
    for _, name in ipairs(names) do
        if not seen[name] then
            seen[name] = true
            local info = Context.addonInfo(name)
            if info then
                info.title = Context.capped(API.AddOnMetadata(name, "Title"), 64)
                out[#out + 1] = info
            end
        end
        if #out >= 8 then break end
    end
    return out
end

local function destinationFor(name)
    local url = name and Context.website(name)
    if url then return { known = true, url = url, source = "toc" } end
    return { known = false }
end

-- The pattern matches of a problem, from its newest sample.
local function explanationsFor(p, newest)
    if not newest then return {} end
    local build = tonumber(newest.build)
    local m = Safe.text(newest.message)
    local o = { kind = p.kind, message = m, stack = Safe.text(newest.stack),
        inCombat = newest.inCombat == true, taintLog = type(newest.taintLog) == "string" and newest.taintLog or nil,
        actionFunction = newest.event and newest.event.func or nil }
    return Patterns.match(o, build)
end

local function playerSection(answers)
    answers = answers or {}
    return {
        doing = answer(answers.doing), happened = answer(answers.happened), expected = answer(answers.expected),
        steps = answer(answers.steps), noVisibleProblem = answers.noVisibleProblem == true or nil,
    }
end

local function baseReport()
    local db = Store.db()
    return {
        schema = Report.SCHEMA,
        reportId = reportId(),
        createdAt = API.Now(),
        generator = { addon = "Bugsy", version = Context.version(ADDON) or "dev", sigAlgo = ns.Signature.ALGO,
            dbFormat = Store.FORMAT },
        client = Context.client(),
        capture = captureSection(),
        privacy = { redactions = {}, trimmed = {}, localsIncluded = false,
            note = "Error text, context and breadcrumbs can contain other players' names or messages; "
                .. "Bugsy only replaces your own character and realm names." },
        source = { sourceId = db and db.sourceId },
    }
end

-- A report for one stored problem.
function Report.ForProblem(p, answers)
    local r = baseReport()
    r.source.problemId = p.id
    local occurrences = {}
    for _, s in ipairs(p.first) do occurrences[#occurrences + 1] = copy(s) end
    for _, s in ipairs(p.last) do occurrences[#occurrences + 1] = copy(s) end
    local newest = occurrences[#occurrences]
    local versions = {}
    for _, a in ipairs(p.addons or {}) do versions[a.name] = copy(a.versions) end
    r.problem = {
        id = p.id, kind = p.kind, title = p.title, count = p.count, countIncomplete = p.countIncomplete,
        unconfirmedRepeats = p.unconfirmedRepeats, firstSeen = p.firstSeen, lastSeen = p.lastSeen,
        firstSession = p.firstSession, lastSession = p.lastSession, sessionCount = p.sessionCount,
        recentSessions = copy(p.recentSessions), callPaths = #p.callPaths, callPathsMore = (p.callPathsOverflow or 0) > 0 or nil,
        versions = versions, addonsOverflow = p.addonsOverflow, groupSignature = p.id,
        messageKey = p.messageKey, muted = p.muted, restricted = p.restricted, sampledOut = p.sampledOut,
    }
    r.occurrences = occurrences
    r.attribution = copy(p.attribution) or { inStack = {} }
    local names = {}
    for _, a in ipairs(p.addons or {}) do names[#names + 1] = a.name end
    r.addons = addonsSection(names)
    local suspect = r.attribution.suspect and r.attribution.suspect.addon
    r.destination = destinationFor(suspect)
    r.player = playerSection(answers)
    r.explanations = explanationsFor(p, newest)
    for _, e in ipairs(r.explanations) do if e.noise then r.problem.noise = true end end
    for _, o in ipairs(occurrences) do
        if type(o.locals) == "string" or (type(o.locals) == "table" and o.locals.text) then
            r.privacy.localsIncluded = true
        end
    end
    return r
end

-- A player-reported problem with no captured error.
function Report.Manual(addonName, answers)
    local r = baseReport()
    local name = Context.capped(addonName, Context.NAME_MAX)
    r.problem = { kind = "manual", title = "Reported by the player", count = 1, addon = name,
        firstSeen = r.createdAt, lastSeen = r.createdAt }
    r.occurrences = { {
        at = r.createdAt, session = Store.session(), build = r.client.build, provider = "player",
        inCombat = API.InCombat(),
        message = { unavailable = true, reason = "player report" },
        stack = { unavailable = true, reason = "player report" },
        locals = { unavailable = true, reason = "player report" },
    } }
    r.attribution = { named = nil, inStack = {}, suspect = nil }
    r.addons = addonsSection({ name })
    r.destination = destinationFor(name)
    r.player = playerSection(answers)
    r.explanations = {}
    return r
end

-- Redaction --------------------------------------------------------------------

local function escapePattern(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

-- Replaces the player's own character and realm names in every string value and
-- string key (a key that collides gets "#2", "#3"...). Returns the list of kinds.
function Report.Redact(r, name, realm)
    local subs = {}
    if type(name) == "string" and #name >= 2 then subs[#subs + 1] = { escapePattern(name), "<player>", "player-name" } end
    if type(realm) == "string" and #realm >= 2 then
        subs[#subs + 1] = { escapePattern(realm), "<realm>", "realm-name" }
        local squashed = realm:gsub("[%s%-']", "")
        if squashed ~= realm and #squashed >= 2 then subs[#subs + 1] = { escapePattern(squashed), "<realm>", "realm-name" } end
    end
    local used = {}
    local function fix(s)
        for _, sub in ipairs(subs) do
            local n
            s, n = s:gsub(sub[1], sub[2])
            if n > 0 then used[sub[3]] = true end
        end
        return s
    end
    local function walk(t, depth)
        if depth > 12 then return end
        local rename = {}
        for k, v in pairs(t) do
            if type(v) == "string" then t[k] = fix(v)
            elseif type(v) == "table" then walk(v, depth + 1) end
            if type(k) == "string" then
                local nk = fix(k)
                if nk ~= k then rename[#rename + 1] = { k, nk } end
            end
        end
        for _, kv in ipairs(rename) do
            local v = t[kv[1]]
            t[kv[1]] = nil
            local key, i = kv[2], 2
            while t[key] ~= nil do key = kv[2] .. "#" .. i; i = i + 1 end
            t[key] = v
        end
    end
    if #subs > 0 then walk(r, 0) end
    local list = {}
    for kind in pairs(used) do list[#list + 1] = kind end
    table.sort(list)
    r.privacy = r.privacy or {}
    r.privacy.redactions = list
    return list
end

-- Size ---------------------------------------------------------------------------

local function eachOccurrence(r, fn) for _, o in ipairs(r.occurrences or {}) do fn(o) end end
local function cutField(o, k, max)
    local t = Safe.text(o[k])
    if t and #t > max then o[k] = Safe.cut(t, max) end
end

-- Steps from DESIGN §9, applied in order while the JSON is too large.
Report.TRIM_STEPS = {
    { "locals", function(r) eachOccurrence(r, function(o)
        if type(o.locals) ~= "table" or not o.locals.unavailable then
            o.locals = { unavailable = true, reason = "trimmed" } end end) end },
    { "samples to first and last", function(r)
        local occ = r.occurrences
        if occ and #occ > 2 then r.occurrences = { occ[1], occ[#occ] } end end },
    { "stacks to 2 KB", function(r) eachOccurrence(r, function(o) cutField(o, "stack", 2048) end) end },
    { "breadcrumbs to 10", function(r) eachOccurrence(r, function(o)
        local b = o.breadcrumbs
        if type(b) == "table" and type(b.items) == "table" and #b.items > 10 then
            local keep = {}
            for i = #b.items - 9, #b.items do keep[#keep + 1] = b.items[i] end
            b.items = keep
        end end) end },
    { "context to 8 keys an addon", function(r) eachOccurrence(r, function(o)
        local c = o.context
        if type(c) == "table" and type(c.values) == "table" then
            for addon, vals in pairs(c.values) do
                if type(vals) == "table" then
                    local keys = {}
                    for k in pairs(vals) do keys[#keys + 1] = k end
                    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
                    for i = 9, #keys do vals[keys[i]] = nil end
                end
            end
        end end) end },
    { "breadcrumbs and context", function(r) eachOccurrence(r, function(o)
        o.breadcrumbs = o.breadcrumbs and { unavailable = true, reason = "trimmed" } or nil
        o.context = o.context and { unavailable = true, reason = "trimmed" } or nil end) end },
    { "one sample", function(r)
        local occ = r.occurrences
        if occ and #occ > 1 then r.occurrences = { occ[1] } end end },
    { "stack and message to 512 bytes", function(r) eachOccurrence(r, function(o)
        cutField(o, "stack", 512); cutField(o, "message", 512) end) end },
    { "player answers to 512 bytes", function(r)
        for k, v in pairs(r.player or {}) do
            local t = Safe.text(v)
            if t and #t > 512 then r.player[k] = Safe.cut(t, 512) end
        end end },
}

-- The fields REPORT-SCHEMA.md defines as lists: an empty one is still [].
Report.ARRAYS = { handlerChanges = true, limits = true, recentSessions = true, occurrences = true,
    items = true, inStack = true, evidence = true, addons = true, explanations = true,
    redactions = true, trimmed = true }

local function encode(r) return Json.encode(r, { maxBytes = Report.MAX_BYTES + 1, arrays = Report.ARRAYS }) end

-- The minimal report: byte-capped fields only.
local function minimal(r)
    local p = r.problem or {}
    local addons = {}
    for i, a in ipairs(r.addons or {}) do
        if i > 8 then break end
        addons[i] = { name = Context.capped(a.name, 64), version = Context.capped(a.version, 32) }
    end
    local function n(v) return type(v) == "number" and v or nil end
    return {
        schema = Report.SCHEMA, reportId = Context.capped(r.reportId, 24), createdAt = n(r.createdAt),
        client = { build = Context.capped(r.client and r.client.build, 16),
            locale = Context.capped(r.client and r.client.locale, 8) },
        problem = { kind = Context.capped(p.kind, 16), title = Context.capped(p.title, 200), count = n(p.count),
            firstSeen = n(p.firstSeen), lastSeen = n(p.lastSeen) },
        addons = addons,
        privacy = { trimmed = { "all evidence: report too large" } },
    }
end

-- JSON that fits Report.MAX_BYTES, trimming the structure (never the output).
-- Returns json, report (the possibly trimmed table); or nil, reason.
function Report.Fit(r)
    local out, cut = encode(r)
    if not cut and #out <= Report.MAX_BYTES then return out, r end
    r.privacy = r.privacy or {}
    r.privacy.trimmed = r.privacy.trimmed or {}
    for _, step in ipairs(Report.TRIM_STEPS) do
        step[2](r)
        r.privacy.trimmed[#r.privacy.trimmed + 1] = step[1]
        out, cut = encode(r)
        if not cut and #out <= Report.MAX_BYTES then return out, r end
    end
    local m = minimal(r)
    out, cut = Json.encode(m, { maxBytes = Report.MINIMAL_MAX + 1, arrays = Report.ARRAYS })
    if not cut and #out <= Report.MINIMAL_MAX then return out, m end
    return nil, "the report could not be built small enough"
end

-- Markdown ------------------------------------------------------------------------

local function when(t)
    if type(t) ~= "number" then return "?" end
    local d = rawget(_G, "date")
    return d and d("!%Y-%m-%d %H:%M UTC", t) or tostring(t)
end

local function fieldText(v)
    if type(v) == "string" then return v end
    if type(v) == "table" then
        if v.text then return v.text .. "\n[cut: " .. tostring(v.originalLength) .. " bytes in all]" end
        if v.restricted then return "[restricted: " .. tostring(v.reason) .. "]" end
        if v.unavailable then return "[not captured: " .. tostring(v.reason) .. "]" end
        if v.unsupported then return "[message was a " .. tostring(v.unsupported) .. ", not text]" end
    end
    return "[none]"
end

local function indent(s) return "    " .. s:gsub("\n", "\n    ") end

function Report.Markdown(r)
    local L = {}
    local function add(s) L[#L + 1] = s end
    local p, c = r.problem or {}, r.client or {}
    local first = r.addons and r.addons[1]
    -- the heading names the addon only: its installed version may not be the one the
    -- evidence came from (each occurrence says which versions it was captured with)
    local who = first and first.name or "Unknown addon"
    add("## Bugsy report " .. tostring(r.reportId))
    if p.kind == "manual" then
        add("**" .. who .. " " .. (first and first.version or "?") .. "** · reported by the player · " .. when(r.createdAt))
    else
        add(format("**%s** · %s · %s%d time%s · first %s, last %s", who, tostring(p.kind),
            p.countIncomplete and "at least " or "", p.count or 0, (p.count == 1) and "" or "s",
            when(p.firstSeen), when(p.lastSeen)))
    end
    add(format("Client Forever %s (%s), %s · captured %s · locals %s", tostring(c.version), tostring(c.build),
        tostring(c.locale), r.capture and r.capture.mode or "?",
        (r.capture and r.capture.localsEnabled) and "on" or "off"))
    add("")
    local pl = r.player or {}
    if pl.doing or pl.happened or pl.expected or pl.steps or pl.noVisibleProblem then
        add("### What the player saw")
        if pl.noVisibleProblem then add("- No visible problem noticed.") end
        if pl.doing then add("- Doing: " .. fieldText(pl.doing)) end
        if pl.happened then add("- Happened: " .. fieldText(pl.happened)) end
        if pl.expected then add("- Expected: " .. fieldText(pl.expected)) end
        if pl.steps then add("- Steps: " .. fieldText(pl.steps)) end
        add("")
    end
    local occ = r.occurrences or {}
    for i, o in ipairs(occ) do
        if i == 1 or i == #occ then
            local label = (i == 1) and "first occurrence" or "latest occurrence"
            if p.kind == "manual" then break end
            add(format("### Error (%s, build %s, %s)", label, tostring(o.build), when(o.at)))
            local then_ = {}
            for name, v in pairs(type(o.versions) == "table" and o.versions or {}) do
                if type(name) == "string" and type(v) == "string" then then_[#then_ + 1] = name .. " " .. v end
            end
            table.sort(then_)
            if #then_ > 0 then add("Captured with " .. concat(then_, ", ")) end
            add(indent(fieldText(o.message)))
            add("")
            add(indent(fieldText(o.stack)))
            if type(o.locals) == "string" or (type(o.locals) == "table" and o.locals.text) then
                add("")
                add("Locals:")
                add(indent(fieldText(o.locals)))
            end
            add("")
            if #occ == 1 then break end
        end
    end
    local a = r.attribution or {}
    add("### Involved (Bugsy's reading, not a verdict)")
    add("- Named by WoW: " .. (a.named and (a.named.addon .. " (" .. a.named.source .. ")") or "none"))
    local parts = {}
    for _, f in ipairs(a.inStack or {}) do
        if f.library then
            parts[#parts + 1] = f.library .. " (library" .. (f.host and (", copy in " .. f.host) or "") .. ")"
        else
            parts[#parts + 1] = f.folder
        end
    end
    add("- In the stack: " .. (#parts > 0 and concat(parts, "; ") or "no addon frames"))
    if a.suspect then
        add(format("- Appears involved: %s (%s: %s)", a.suspect.addon, a.suspect.confidence,
            concat(a.suspect.evidence or {}, "; ")))
    else
        add("- Appears involved: unknown")
    end
    if r.addons and #r.addons > 0 then
        local vs = {}
        for _, ad in ipairs(r.addons) do vs[#vs + 1] = ad.name .. " " .. (ad.version or "?") end
        add("- Installed when this report was prepared: " .. concat(vs, ", "))
    end
    add("")
    if r.explanations and #r.explanations > 0 then
        add("### Possible explanation (not a diagnosis)")
        for _, e in ipairs(r.explanations) do
            add(format("- %s r%d (%s): %s", e.id, e.rev, e.confidence, e.summary))
            add("  - Evidence: " .. concat(e.evidence or {}, "; "))
            add("  - To investigate: " .. e.investigate)
        end
        add("")
    end
    local nots = {}
    if not (r.capture and r.capture.localsEnabled) then nots[#nots + 1] = "locals (off)" end
    if p.sampledOut and p.sampledOut > 0 then nots[#nots + 1] = p.sampledOut .. " occurrences counted but not kept" end
    if p.unconfirmedRepeats and p.unconfirmedRepeats > 0 then
        nots[#nots + 1] = p.unconfirmedRepeats .. " more with the same message, stack not captured"
    end
    for _, t in ipairs(r.privacy and r.privacy.trimmed or {}) do nots[#nots + 1] = "trimmed: " .. t end
    for _, red in ipairs(r.privacy and r.privacy.redactions or {}) do
        nots[#nots + 1] = (red == "player-name" and "your character name" or "your realm name") .. " replaced"
    end
    for _, l in ipairs(r.capture and r.capture.limits or {}) do nots[#nots + 1] = l end
    if #nots > 0 then
        add("### Not included")
        add("- " .. concat(nots, " · "))
    end
    return concat(L, "\n")
end

-- The texts the report window offers: redacted, fitted. Returns markdown, json; or nil, reason.
function Report.Render(r)
    local name, realm = API.PlayerName()
    Report.Redact(r, name, realm)
    local json, fitted = Report.Fit(r)
    if not json then return nil, fitted end
    return Report.Markdown(fitted), json
end

ns._test = ns._test or {}
ns._test.Report = Report
