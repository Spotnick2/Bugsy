-- BugsyProbe: how the Forever client hands errors to addons (docs/FOREVER-PROBE.md
-- section 6). A ForeverProbe module: /fp bugsy, /fp steps bugsy <name>.
--
-- It installs its own MEASURING handler for an experiment and restores the
-- previous one afterwards, so Bugsy may stay loaded. Any other error collector must
-- be disabled: one turns seterrorhandler into a no-op, and the experiments say so.
-- Nothing secret is ever saved: values are described by type, length and secrecy.

local ADDON, NS = ...
local MAX_LOG = 4000
local MAX_RECORDS = 300

local Probe = ForeverProbe:Module("BugsyProbe", { api = 1, cmd = "bugsy" })
local function say(msg) Probe:Say(msg) end
local G = function(name) return rawget(_G, name) end

-- File scope (P5): what exists before our ADDON_LOADED.
NS.fileScope = {
    svType = type(G("BugsyProbeDB")),
    handler = tostring(G("geterrorhandler") and G("geterrorhandler")()),
    bugsy = G("Bugsy") ~= nil,
    bugsyDiag = G("Bugsy") and G("Bugsy").Diagnostics and G("Bugsy").Diagnostics() or nil,
}

-- The measuring handler ------------------------------------------------------------

local rec = { records = {}, entries = 0, nested = 0, depth = 0, label = "?", light = false,
    throw = false, scheduleInHandler = false, scheduled = 0 }
NS.rec = rec

-- A value described without ever exposing a secret.
local function inspect(v)
    local d = {}
    local okT, t = pcall(type, v)
    d.type = okT and t or "?"
    local iss, can = G("issecretvalue"), G("canaccessvalue")
    -- an explicit branch: `ok and result or "error"` would turn a successful false into "error"
    if iss then
        local ok, s = pcall(iss, v)
        if ok then d.secret = s else d.secret = "error" end
    end
    if can then
        local ok, c = pcall(can, v)
        if ok then d.access = c else d.access = "error" end
    end
    -- the value is read only when every available check ran and cleared it
    local cleared = (not iss or d.secret == false) and (not can or d.access == true)
    if cleared and d.type == "string" then
        d.len = #v
        d.head = v:sub(1, 200)
    elseif cleared and d.type == "number" then
        d.value = v
    end
    return d
end
NS.inspect = inspect

local function summary(d)
    if not d then return "nil" end
    return ("%s secret=%s access=%s%s"):format(tostring(d.type), tostring(d.secret), tostring(d.access),
        d.len and (" len=" .. d.len) or "")
end

local function store(r)
    local list = rec.records
    list[#list + 1] = r
    if #list > MAX_RECORDS then table.remove(list, 1) end
    if BugsyProbeDB then BugsyProbeDB.records = list end
end

local function measure(msg)
    rec.entries = rec.entries + 1
    if rec.depth > 0 then
        rec.nested = rec.nested + 1
        if rec.nested > 3 then return end
    end
    rec.depth = rec.depth + 1
    local r = { label = rec.label, at = GetTime(), msg = inspect(msg), combat = InCombatLockdown() }
    if not rec.light then
        local ch, eh = G("GetCallstackHeight"), G("GetErrorCallstackHeight")
        r.callHeight = ch and ch()
        r.errorHeight = eh and eh()
        if type(r.callHeight) == "number" and type(r.errorHeight) == "number" then
            r.level = r.callHeight - (r.errorHeight - 1)
        end
        -- the first line of debugstack(n) for n = 1..8: which level is the error's?
        -- Called DIRECTLY, as Bugsy does: through pcall, its C frame would shift every level.
        r.lines = {}
        for n = 1, 8 do
            local d = inspect(debugstack(n, 1, 0))
            r.lines[n] = d.head and d.head:gsub("\n", "") or ("<" .. summary(d) .. ">")
        end
        if r.level then
            r.stack = inspect(debugstack(r.level))
            -- fixtures for the signature parser (P13): the first 12 lines, when readable
            if r.stack.head then
                local s = debugstack(r.level, 12, 0)
                r.fixture = type(s) == "string" and not (issecretvalue and issecretvalue(s)) and s or nil
            end
            r.locals = inspect(debuglocals(r.level, true))
            if r.locals.head then r.locals.head = r.locals.head:sub(1, 80) end
        end
        -- GetTime() inside one frame (P14): Bugsy's budgets refill by it
        r.time = GetTime()
        r.profile = debugprofilestop and debugprofilestop() or nil
    end
    if rec.scheduleInHandler then
        local ok = pcall(C_Timer.After, 0, function() rec.scheduled = rec.scheduled + 1 end)
        r.scheduleOk = ok
    end
    store(r)
    rec.depth = rec.depth - 1
    if rec.throw then error("BugsyProbe: the measuring handler throws on purpose") end
end
NS.measure = measure

local previous
local function install(label)
    rec.label = label or rec.label
    if G("geterrorhandler")() == measure then return true end
    previous = G("geterrorhandler")()
    seterrorhandler(measure)
    local ok = G("geterrorhandler")() == measure
    if not ok then say("could not install the measuring handler: seterrorhandler is a no-op (another error collector?)") end
    return ok
end
local function uninstall()
    if previous and G("geterrorhandler")() == measure then seterrorhandler(previous) end
end
NS.install, NS.uninstall = install, uninstall

local function find(label)
    local out = {}
    for _, r in ipairs(rec.records) do if r.label == label then out[#out + 1] = r end end
    return out
end

local function report(label)
    local list = find(label)
    if #list == 0 then say(label .. ": no handler call recorded"); return 0 end
    for _, r in ipairs(list) do
        say(("%s: msg[%s] callH=%s errH=%s level=%s stack[%s] locals[%s] combat=%s"):format(label, summary(r.msg),
            tostring(r.callHeight), tostring(r.errorHeight), tostring(r.level), summary(r.stack), summary(r.locals),
            tostring(r.combat)))
        if r.lines then
            for n, line in ipairs(r.lines) do say(("  debugstack(%d) = %s"):format(n, line)) end
        end
    end
    return #list
end

-- Experiments (P2): each raises an error a different way, labelled.
local function later(delay, label, fn)
    C_Timer.After(delay, function() rec.label = label; fn() end)
end

local EXPERIMENTS = {
    { "plain", function() later(0.1, "plain", function() error("BugsyProbe plain error()") end) end },
    { "runtime", function() later(0.2, "runtime", function() local t; return t.x end) end },
    { "onupdate", function()
        local f = CreateFrame("Frame")
        f:SetScript("OnUpdate", function(self)
            self:SetScript("OnUpdate", nil)
            rec.label = "onupdate"
            local n
            return n + 1
        end)
    end },
    { "direct", function() later(0.3, "direct", function() geterrorhandler()("BugsyProbe direct geterrorhandler() call") end) end },
    { "xpcall", function() later(0.4, "xpcall", function()
        xpcall(function() error("BugsyProbe inside xpcall") end, geterrorhandler())
    end) end },
    { "pcall", function() later(0.5, "pcall", function() pcall(error, "BugsyProbe inside pcall") end) end },
    { "securecall", function() later(0.6, "securecall", function()
        if securecallfunction then securecallfunction(function() error("BugsyProbe in securecallfunction") end) end
    end) end },
    { "wrapper", function() later(0.8, "wrapper", function()
        -- a chaining wrapper, as some UI suites install: does the formula still hold through it?
        local inner = geterrorhandler()
        local function wrapper(msg) return inner(msg) end
        seterrorhandler(wrapper)
        local ok = geterrorhandler() == wrapper
        C_Timer.After(0, function() rec.label = "wrapper"; error("BugsyProbe through a chaining wrapper") end)
        C_Timer.After(0.2, function() if ok then seterrorhandler(inner) end end)
    end) end },
    { "event", function() later(0.9, "event", function()
        -- an error raised inside an OnEvent script
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_TARGET_CHANGED")
        f:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            rec.label = "event"
            error("BugsyProbe error inside OnEvent")
        end)
        say("event: change your target to raise it")
    end) end },
    { "librarysite", function() later(0.7, "librarysite", function()
        local ok, err = pcall(error, "BugsyProbe handled, reported at the library site")
        if not ok then
            local s = debugstack(2)
            store({ label = "librarysite", at = GetTime(), msg = inspect(err), stack = inspect(s),
                lines = { (inspect(s).head or ""):match("^[^\n]*") } })
        end
    end) end },
}

local function runAll()
    if not install("?") then return false, "measuring handler not installed" end
    for _, e in ipairs(EXPERIMENTS) do e[2]() end
    C_Timer.After(30, uninstall)
    return true, #EXPERIMENTS .. " experiments scheduled"
end

local function experimentsDone()
    local missing = {}
    for _, e in ipairs(EXPERIMENTS) do
        if e[1] ~= "pcall" and #find(e[1]) == 0 then missing[#missing + 1] = e[1] end
    end
    return #missing == 0, "waiting for: " .. table.concat(missing, ",")
        .. ((#missing == 1 and missing[1] == "event") and " (change your target)" or "")
end

-- P1: secrets in combat. One-shot, on a player UNIT_AURA in combat.
local armed = {}
local auraFrame = CreateFrame("Frame")
auraFrame:SetScript("OnEvent", function(_, _, unit, info)
    if not InCombatLockdown() then return end
    if armed.boolean then
        armed.boolean = false
        rec.label = "secret-boolean"
        store({ label = "secret-payload", at = GetTime(), msg = inspect(info) })
        local x = info.isFullUpdate     -- reading a field of a secret table may itself throw
        if x then return end            -- the truth test throws when x is secret
        return
    end
    if armed.message then
        armed.message = false
        rec.label = "secret-message"
        error(info)                     -- a secret table as the error message
    end
    if armed.aura then
        armed.aura = false
        rec.label = "aura-read"
        local d = C_UnitAuras.GetAuraDataByIndex("player", 1)
        return d
    end
end)

local function armSecrets()
    if not install("secret") then return false, "measuring handler not installed" end
    armed.boolean, armed.message, armed.aura = true, false, false
    auraFrame:RegisterUnitEvent("UNIT_AURA", "player")
    return true, "armed: fight something; the step completes after three aura changes in combat"
end

local function secretsWait()
    if armed.boolean then return false, "waiting for an aura change in combat" end
    if not armed.messageDone then armed.message = true; armed.messageDone = true end
    if armed.message then return false, "one more aura change in combat (secret message)" end
    if not armed.auraDone then armed.aura = true; armed.auraDone = true end
    if armed.aura then return false, "one more aura change in combat (aura read)" end
    auraFrame:UnregisterAllEvents()
    uninstall()
    return true, ("boolean=%d message=%d aura=%d"):format(#find("secret-boolean"), #find("secret-message"), #find("aura-read"))
end

-- P8: floods, in light mode (counting only).
local function flood(label, n, unique)
    if not install(label) then return false, "measuring handler not installed" end
    rec.light = true
    local before = rec.entries
    local t0 = debugprofilestop()
    for i = 1, n do
        C_Timer.After(0, function()
            rec.label = label
            if unique then error("BugsyProbe flood " .. i) else error("BugsyProbe flood same") end
        end)
    end
    C_Timer.After(0.5, function()
        rec.light = false
        uninstall()
        local got = rec.entries - before
        local mem = collectgarbage and pcall(collectgarbage, "count") and collectgarbage("count") or -1
        say(("%s: %d of %d errors reached the handler; scheduling took %.1f ms; memory %.0f KB")
            :format(label, got, n, t0 and (debugprofilestop() - t0) or -1, mem))
        BugsyProbeDB.floods = BugsyProbeDB.floods or {}
        BugsyProbeDB.floods[label] = { reached = got, raised = n }
    end)
    return true, "flood scheduled"
end

-- P9: a handler that throws.
local function throwingHandler()
    if not install("throw") then return false, "measuring handler not installed" end
    rec.throw = true
    local before, nestedBefore = rec.entries, rec.nested
    C_Timer.After(0.1, function() rec.label = "throw"; error("BugsyProbe error for the throwing handler") end)
    C_Timer.After(0.6, function()
        rec.throw = false
        uninstall()
        say(("throw: handler entered %d times, nested %d"):format(rec.entries - before, rec.nested - nestedBefore))
        BugsyProbeDB.throw = { entries = rec.entries - before, nested = rec.nested - nestedBefore }
    end)
    return true, "scheduled"
end

-- P6: in combat, scheduling from inside the handler.
local function combatError()
    if not InCombatLockdown() then return false, "not in combat yet" end
    if not install("combat") then return false, "measuring handler not installed" end
    rec.scheduleInHandler = true
    local before = rec.scheduled
    C_Timer.After(0.1, function() rec.label = "combat"; error("BugsyProbe error in combat") end)
    C_Timer.After(0.6, function()
        rec.scheduleInHandler = false
        uninstall()
        say(("combat: %d timer(s) scheduled from inside the handler ran"):format(rec.scheduled - before))
    end)
    return true, "scheduled"
end

-- P11 and P7: who holds the handler, and can it be set?
local function handlerState(label)
    local get, set = G("geterrorhandler"), G("seterrorhandler")
    local h = get()
    local probe = function() end
    set(probe)
    local settable = get() == probe
    if settable then set(h) end
    local s = {
        label = label, handler = tostring(h), settable = settable, sameAfterRestore = get() == h,
        bugsy = G("Bugsy") ~= nil,
        bugsyMode = G("Bugsy") and G("Bugsy").Status and select(1, G("Bugsy").Status()) or nil,
        bugsyDiag = G("Bugsy") and G("Bugsy").Diagnostics and G("Bugsy").Diagnostics() or nil,
    }
    local diag = s.bugsyDiag or {}
    BugsyProbeDB.handlers = BugsyProbeDB.handlers or {}
    BugsyProbeDB.handlers[label] = s
    say(("handler[%s]: settable=%s collector=%s Bugsy=%s (%s)"):format(label, tostring(settable),
        tostring(diag.collector), tostring(s.bugsy), tostring(s.bugsyMode)))
    return true, s.settable and "settable" or "NOT settable"
end

-- P10: Blizzard's popup for a forbidden action, with and without its listeners.
local function forbid()
    TargetUnit("BugsyProbeNobody", true)
    return true, "TargetUnit called (forbidden)"
end
local function unregisterPopups()
    local ok1 = pcall(UIParent.UnregisterEvent, UIParent, "ADDON_ACTION_FORBIDDEN")
    local ok2 = pcall(UIParent.UnregisterEvent, UIParent, "ADDON_ACTION_BLOCKED")
    local ge = G("GameEvent")
    local ok3 = ge and ge.UnregisterInternalEvent and pcall(ge.UnregisterInternalEvent, "ADDON_ACTION_FORBIDDEN")
    return true, ("UIParent %s/%s GameEvent %s"):format(tostring(ok1), tostring(ok2), tostring(ok3))
end

-- P3: LUA_WARNING, passively for the whole session.
local warnFrame = CreateFrame("Frame")
warnFrame:SetScript("OnEvent", function(_, event, text)
    local w = BugsyProbeDB and BugsyProbeDB.warnings
    if not w then return end
    w.count = (w.count or 0) + 1
    w.samples = w.samples or {}
    if #w.samples < 30 then w.samples[#w.samples + 1] = { at = GetTime(), text = inspect(text) } end
end)
Probe:RegisterEvents(warnFrame, { "LUA_WARNING" })

-- P12: copy fidelity and large text.
local SAMPLE = "pipe|single ||double |cffff0000red|r tab\there é漢字 end"
local copyBox
local function showCopyBox(keepPaste)
    if not copyBox then
        local f = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(560, 220)
        f:SetPoint("CENTER", 0, 150)
        f:SetFrameStrata("DIALOG")
        local e = CreateFrame("EditBox", nil, f)
        e:SetMultiLine(true)
        e:SetAutoFocus(false)
        e:SetFontObject("ChatFontNormal")
        e:SetWidth(520)
        e:SetPoint("TOPLEFT", 16, -30)
        e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        f.edit = e
        local p = CreateFrame("EditBox", nil, f)
        p:SetMultiLine(true)
        p:SetAutoFocus(false)
        p:SetFontObject("ChatFontNormal")
        p:SetSize(440, 60)
        p:SetPoint("BOTTOMLEFT", 22, 16)
        p:SetMaxLetters(0)
        local bg = p:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.5)
        p:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        f.paste = p
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(80, 22)
        b:SetPoint("BOTTOMRIGHT", -14, 16)
        b:SetText("Select")
        -- what a player does: click, then Ctrl+C at once (the box keeps focus)
        b:SetScript("OnClick", function() f.edit:SetFocus(); f.edit:HighlightText() end)
        f.select = b
        copyBox = f
    end
    copyBox.edit:SetText(SAMPLE .. "\n" .. SAMPLE:gsub("|", "||"))
    if not keepPaste then copyBox.paste:SetText("") end
    copyBox:Show()
    BugsyProbeDB.copySample = { raw = SAMPLE, escaped = (SAMPLE:gsub("|", "||")) }
    return true, "shown: line 1 raw, line 2 with pipes doubled"
end

-- What came back through the clipboard, against what the box holds.
local function comparePaste()
    if not copyBox then return false, "the window was not opened" end
    local shown, got = copyBox.edit:GetText(), copyBox.paste:GetText()
    local r = { shownLength = #shown, pastedLength = #got, equal = shown == got }
    if not r.equal then
        local i = 1
        while i <= #shown and i <= #got and shown:byte(i) == got:byte(i) do i = i + 1 end
        r.firstDiff = i
        r.shownAt = shown:sub(i, i + 20)
        r.pastedAt = got:sub(i, i + 20)
    end
    r.detail = r.equal and "identical" or ("%d vs %d bytes; first difference at byte %s: shown %q, pasted %q")
        :format(#shown, #got, tostring(r.firstDiff), tostring(r.shownAt), tostring(r.pastedAt))
    r.pasted = got:sub(1, 300)
    BugsyProbeDB.copyResult = r
    say("copy: " .. r.detail)
    return r.equal, r.detail
end
local function bigText()
    if not copyBox then showCopyBox() end
    local chunk = string.rep("0123456789abcdef", 64) .. "\n"   -- 1025 bytes
    local text = string.rep(chunk, 63)
    local t0 = debugprofilestop()
    copyBox.edit:SetText(text)
    local ms = debugprofilestop() - t0
    local back = copyBox.edit:GetText()
    BugsyProbeDB.bigText = { set = #text, got = #back, same = back == text, ms = ms }
    copyBox:Hide()
    return back == text, ("%d bytes set, %d read back, %.1f ms"):format(#text, #back, ms)
end

-- Commands ------------------------------------------------------------------------------

-- Front mode (DESIGN §3, D14; P7): Bugsy installed ahead of another addon's handler.
-- Read through Bugsy.Diagnostics; the probe's own wrapper (frontown) records what a
-- downstream handler sees.
local function diag(match)
    local B = G("Bugsy")
    return (B and B.Diagnostics and B.Diagnostics(match)) or {}
end

local function frontLog(label, t)
    BugsyProbeDB.front = BugsyProbeDB.front or {}
    t.at, t.inCombat = GetTime(), InCombatLockdown()
    BugsyProbeDB.front[label] = t
    return t
end

local function frontState(label)
    local d = diag()
    frontLog(label, { mode = d.mode, fronted = d.fronted, frontTried = d.frontTried, frontEnabled = d.frontEnabled,
        handler = tostring(geterrorhandler()), passSuppressed = d.passSuppressed, forwardFailed = d.forwardFailed })
    say(("front[%s]: mode=%s fronted=%s tried=%s enabled=%s passSuppressed=%s forwardFailed=%s combat=%s"):format(label,
        tostring(d.mode), tostring(d.fronted), tostring(d.frontTried), tostring(d.frontEnabled),
        tostring(d.passSuppressed), tostring(d.forwardFailed), tostring(InCombatLockdown())))
    return d
end

-- What Bugsy recorded for problems whose title contains `match`.
local function recorded(match, label)
    local d = diag(match)
    frontLog(label, { match = match, count = d.count, where = d.where, tier = d.tier, entry = d.entry,
        hasLocals = d.hasLocals, mode = d.mode })
    say(("front[%s]: %q count=%s where=%s tier=%s entry=%s locals=%s"):format(label, match, tostring(d.count),
        tostring(d.where), tostring(d.tier), tostring(d.entry), tostring(d.hasLocals)))
    return d
end

local function raiseLater(text, delay)
    C_Timer.After(delay or 0.05, function() error(text) end)
end

local function waitRecorded(match)
    return function()
        local d = diag(match)
        return (d.count or 0) > 0, "not recorded yet: " .. match
    end
end

local function located(d)
    return d.where ~= nil and d.where:find("BugsyProbe/BugsyProbe.lua", 1, true) ~= nil
end

-- The probe's own chaining wrapper, for frontown. For every call it records the
-- error height, the call height, and the first stack lines at the formula's level
-- (debugstack called directly, as Blizzard's handler does).
local PW = { calls = {}, prev = nil, recurse = false, throw = false }
NS.PW = PW
local function probeWrapper(msg, ...)
    local eh = GetErrorCallstackHeight and GetErrorCallstackHeight()
    local ch = GetCallstackHeight and GetCallstackHeight()
    local e = { msg = type(msg) == "string" and msg:sub(1, 160) or type(msg), errH = eh, callH = ch,
        inCombat = InCombatLockdown(), at = GetTime() }
    if type(eh) == "number" and type(ch) == "number" then
        e.level = ch - (eh - 1)
        e.stack = debugstack(e.level, 3, 0)
    else
        e.stack = debugstack(2, 3, 0)
    end
    local list = PW.calls
    list[#list + 1] = e
    if #list > 60 then table.remove(list, 1) end
    BugsyProbeDB.frontWrapper = list
    if type(msg) == "string" then
        if PW.recurse and msg:find("BugsyProbe frontown outer", 1, true) then
            PW.recurse = false
            geterrorhandler()("BugsyProbe frontown inner (reported while handling)")
        end
        if PW.throw and msg:find("BugsyProbe frontown throw", 1, true) then
            PW.throw = false
            error("BugsyProbe wrapper exploded")
        end
    end
    if PW.prev then return PW.prev(msg, ...) end
end

local W2 = { calls = 0 }
local function laterWrapper(msg, ...)
    W2.calls = W2.calls + 1
    if W2.prev then return W2.prev(msg, ...) end
end

Probe:Command("keyword", function(args)
    BugsyProbeDB.keyword = (args and args ~= "") and args or nil
    say("keyword: " .. tostring(BugsyProbeDB.keyword))
end, "the word the wrapper addon's own-error filter looks for (its name), for the front procedure")

Probe:Command("state", function() handlerState("now") end, "who holds the error handler, can it be set")
Probe:Command("stacks", function() local ok, d = runAll(); say(d) end, "run the stack-level experiments (P2)")
Probe:Command("results", function(args)
    if args and args ~= "" then report(args) else
        for _, e in ipairs(EXPERIMENTS) do report(e[1]) end
        for _, l in ipairs({ "secret-boolean", "secret-message", "aura-read", "combat", "throw", "file-scope" }) do report(l) end
    end
end, "print recorded handler calls [label]")
Probe:Command("warnings", function()
    local w = BugsyProbeDB.warnings or {}
    say(("LUA_WARNING: %d this log period"):format(w.count or 0))
    for _, s in ipairs(w.samples or {}) do say("  " .. summary(s.text) .. " " .. tostring(s.text.head)) end
end, "LUA_WARNING seen so far (P3)")
Probe:Command("flood", function(args)
    local n = tonumber(args) or 1000
    flood("flood-same", n, false)
end, "1000 identical errors in one frame (P8)")
Probe:Command("floodunique", function(args) flood("flood-unique", tonumber(args) or 1000, true) end, "1000 unique errors (P8)")
Probe:Command("early", function(args)
    BugsyProbeDB.earlyArmed = args ~= "off"
    say("file-scope error test " .. (BugsyProbeDB.earlyArmed and "armed: /reload now" or "off"))
end, "arm the file-scope error test for the next reload (P5)")
Probe:Command("clear", function()
    Probe:ClearLog(); rec.records = {}; BugsyProbeDB.records = rec.records; say("log and records cleared")
end, "empty the saved log and records")

-- Procedures ------------------------------------------------------------------------------

Probe:Steps("stacks", {
    title = "Stack levels (P2, P11, P13, P14)", rev = 2,
    { text = "Every other error collector must be disabled for this (one blocks seterrorhandler). Press Run to check.", button = "Check",
      run = function() return handlerState("stacks-start") end,
      check = function() local s = BugsyProbeDB.handlers["stacks-start"]; return s and s.settable, "handler settable" end },
    { text = "Raising ten errors, each a different way. Press Run, then change your target once.", run = runAll },
    { text = "Waiting for the errors to arrive.", wait = experimentsDone, timeout = 60 },
    { text = "Printing the results to /fp.", auto = true, run = function()
        for _, e in ipairs(EXPERIMENTS) do report(e[1]) end
        return true
    end },
    { text = "Did any of this show Blizzard's own error window or a chat message?", ask = true },
})

Probe:Steps("secrets", {
    title = "Secret errors in combat (P1)", rev = 1,
    { text = "Find something to fight (a training dummy is fine). Press Run, then start the fight.", run = armSecrets },
    { text = "Fight until this completes: three aura changes on you in combat.", wait = secretsWait, timeout = 300 },
    { text = "Printing the results.", auto = true, run = function()
        report("secret-boolean"); report("secret-message"); report("aura-read"); return true
    end },
    { text = "Leave combat. Did Blizzard show anything for these errors?", ask = true },
})

Probe:Steps("combat", {
    title = "An error in combat, a timer from the handler (P6)", rev = 1,
    { text = "Start a fight, then press Run while in combat.", run = combatError },
    { text = "Waiting.", wait = function() return #find("combat") > 0, "no record yet" end, timeout = 30 },
    { text = "Leave combat. Check /fp for an ADDON_ACTION_BLOCKED line from the host after the error. Any?", ask = true },
})

-- Floods (P8), rev 3: errors go to BUGSY (no measuring handler). What it received
-- (occurrences, counted repeats, suppressed), the longest frame meanwhile, and
-- Bugsy's own memory. Measured in rev 2: after 100 errors in one burst the client
-- pauses error reporting until /reload, so each burst gets a fresh reload.
local function bugsyTotals(match)
    local d = diag(match)
    return (d.count or 0) + (d.unconfirmed or 0), (d.suppressed or 0) + (d.queueDropped or 0)
end

local function bugsyMemoryKB()
    if not (UpdateAddOnMemoryUsage and GetAddOnMemoryUsage) then return -1 end
    local ok = pcall(UpdateAddOnMemoryUsage)
    if not ok then return -1 end
    local okM, kb = pcall(GetAddOnMemoryUsage, "!Bugsy")
    return okM and kb or -1
end

local function floodBugsy(label, n, unique, spread)
    -- this run's result only: a saved one from an earlier run must not satisfy the wait
    -- (Codex, PR #12), and the run's own id keeps its errors apart from earlier runs'
    BugsyProbeDB.floods3 = BugsyProbeDB.floods3 or {}
    BugsyProbeDB.floods3[label] = nil
    local run = ("%.0f"):format(GetTime() * 1000)
    local match = (unique and "BugsyProbe flood unique " or "BugsyProbe flood same ") .. label .. " r" .. run
    local got0, lost0 = bugsyTotals(match)
    local paused0 = bugsyTotals("Error reporting is now paused")
    local mem0 = bugsyMemoryKB()
    local maxMs, frames, last = 0, 0, debugprofilestop()
    local tracker = CreateFrame("Frame")
    tracker:SetScript("OnUpdate", function()
        local now = debugprofilestop()
        local dt = now - last
        last = now
        frames = frames + 1
        if dt > maxMs then maxMs = dt end
    end)
    for i = 1, n do
        local text = unique and (match .. " #" .. i) or match
        C_Timer.After(spread and (i * spread) or 0, function() error(text, 0) end)
    end
    C_Timer.After((spread and n * spread or 0) + 3, function()
        tracker:SetScript("OnUpdate", nil)
        local got1, lost1 = bugsyTotals(match)
        local r = { raised = n, received = got1 - got0, lost = lost1 - lost0, maxFrameMs = maxMs, frames = frames,
            pauseNotice = bugsyTotals("Error reporting is now paused") - paused0,
            bugsyKB = bugsyMemoryKB(), bugsyKBBefore = mem0, mode = diag().mode }
        BugsyProbeDB.floods3 = BugsyProbeDB.floods3 or {}
        BugsyProbeDB.floods3[label] = r
        say(("%s: %d raised; Bugsy received %d (+%d counted as lost); pause notice %d; longest frame %.0f ms over %d frames; Bugsy memory %.0f -> %.0f KB")
            :format(label, n, r.received, r.lost, r.pauseNotice, maxMs, frames, mem0, r.bugsyKB))
    end)
    return true, "scheduled"
end

local function floodDone(label)
    return function()
        local r = BugsyProbeDB.floods3 and BugsyProbeDB.floods3[label]
        return r ~= nil, "running"
    end
end

Probe:Steps("floods", {
    title = "Floods (P8): what Bugsy receives, the client's pause, frame time", rev = 4,
    { text = "Errors go to Bugsy. Start from a fresh /reload. Press Run: 1000 identical errors in one frame.",
      run = function() return floodBugsy("same-frame", 1000, false, nil) end },
    { text = "Waiting (about 3 s).", wait = floodDone("same-frame"), timeout = 30 },
    { text = "Did the game freeze noticeably (more than half a second)?", ask = true },
    { text = "Reload: the game paused error reporting after that burst.", reload = true },
    { text = "Press Run: 1000 different errors in one frame.",
      run = function() return floodBugsy("unique-frame", 1000, true, nil) end },
    { text = "Waiting (about 3 s).", wait = floodDone("unique-frame"), timeout = 30 },
    { text = "Did the game freeze noticeably?", ask = true },
    { text = "Reload again.", reload = true },
    { text = "Press Run: 1000 different errors spread over 4 s.",
      run = function() return floodBugsy("unique-spread", 1000, true, 0.004) end },
    { text = "Waiting (about 7 s).", wait = floodDone("unique-spread"), timeout = 40 },
    { text = "Did the game freeze or stutter?", ask = true },
    { text = "Reload to end the procedure with error reporting on.", reload = true },
})

Probe:Steps("throw", {
    title = "A handler that throws (P9)", rev = 1,
    { text = "Press Run: the measuring handler will throw on one error.", run = throwingHandler },
    { text = "Waiting.", wait = function() return BugsyProbeDB.throw ~= nil, "running" end, timeout = 10 },
    { text = "Did Blizzard's error window or a chat line appear?", ask = true, screenshot = "throw" },
    { text = "Press Run: an ordinary error now, to check capture still works.", run = function()
        install("after-throw")
        C_Timer.After(0.1, function() rec.label = "after-throw"; error("BugsyProbe after the throw") end)
        C_Timer.After(0.6, uninstall)
        return true
    end },
    { text = "Waiting.", wait = function() return #find("after-throw") > 0, "no record yet" end, timeout = 10 },
})

Probe:Steps("early", {
    title = "Errors during loading (P5)", rev = 1,
    { text = "Arming a file-scope error for the next load. Press Run.", run = function()
        BugsyProbeDB.earlyArmed = true; return true end },
    { text = "Reload.", reload = true },
    { text = "Reading what happened at load.", auto = true, run = function()
        local fs = BugsyProbeDB.fileScopeSeen or {}
        report("file-scope")
        return true, ("SV at file scope: %s; handler installed early: %s; timer before ADDON_LOADED ran %s")
            :format(tostring(NS.fileScope.svType), tostring(fs.installed), tostring(fs.timerPhase))
    end },
})

Probe:Steps("coexist", {
    title = "Living with another error collector (P7, P11)", rev = 3,
    { text = "In the AddOns list, ENABLE the standalone error collector, its viewer, and the addon that embeds its own copy of one. Reload, then press Run to check Bugsy sees the collector.",
      run = function()
          local d = frontState("coexist-1"); handlerState("coexist-1")
          return d.mode == "collector", tostring(d.mode) end,
      check = function() local s = BugsyProbeDB.front["coexist-1"]
          return s and s.mode == "collector", "Bugsy reads from the collector (if not: it is not loaded)" end },
    { text = "Press Run: an error.", run = function() raiseLater("BugsyProbe coexist with the collector"); return true end },
    { text = "Waiting for Bugsy to record it.", wait = waitRecorded("BugsyProbe coexist with the collector"), timeout = 15,
      check = function() local d = recorded("BugsyProbe coexist with the collector", "coexist-collector")
          return d.entry == "collector", "entry " .. tostring(d.entry) end },
    { text = "In the AddOns list, DISABLE the standalone collector and its viewer; keep the addon that embeds a copy enabled. Then reload.", reload = true },
    { text = "Recording who holds the handler now.", auto = true,
      run = function() local d = frontState("coexist-2"); handlerState("coexist-2"); return true, tostring(d.mode) end },
    { text = "Press Run: an error.", run = function() raiseLater("BugsyProbe coexist with the embedded copy"); return true end },
    { text = "Waiting for Bugsy to record it.", wait = waitRecorded("BugsyProbe coexist with the embedded copy"), timeout = 15,
      check = function() local d = recorded("BugsyProbe coexist with the embedded copy", "coexist-embedded")
          return (d.count or 0) > 0, "entry " .. tostring(d.entry) .. ", mode " .. tostring(d.mode) end },
    { text = "Did anything else show (a popup, a chat line from those addons)?", ask = true },
})

Probe:Steps("popups", {
    title = "Blizzard's blocked-action popup (P4, P10)", rev = 2,
    { text = "Press Run: one forbidden call (TargetUnit). A Blizzard popup may appear.", run = forbid, screenshot = "forbidden" },
    { text = "Did a popup appear? If one did, press its Ignore button to close it, then answer.", ask = true },
    { text = "Press Run: stop Blizzard's popup listeners for this session.", run = unregisterPopups },
    { text = "Press Run: the forbidden call again.", run = forbid, screenshot = "forbidden-unregistered" },
    { text = "Did a NEW popup appear this time?", ask = true },
    { text = "Check /fp for taint lines from the host. Any new ones after the second call?", ask = true },
    { text = "Reload to restore Blizzard's listeners.", reload = true },
})

Probe:Steps("copy", {
    title = "Copying from an edit box (P12)", rev = 3,
    { text = "Press Run: a window opens with two boxes.", run = showCopyBox, screenshot = "copybox" },
    { text = "In that window: click Select, press Ctrl+C at once, click into the lower (dark) box, press Ctrl+V. Then press Next here." },
    { text = "Comparing what was pasted with what was shown.", auto = true, run = comparePaste,
      check = function() local c = BugsyProbeDB.copyResult; return c and c.equal == true, c and c.detail or "nothing pasted" end },
    { text = "Setting 63 KB of text and reading it back.", auto = true, run = bigText },
})

-- The v0.1.0 release gate (#33): B-18's taint check, and a full-exit persistence check.
local function gateLog(label, t)
    BugsyProbeDB.gate = BugsyProbeDB.gate or {}
    t.at = time()
    BugsyProbeDB.gate[label] = t
    return t
end
local FORBID = "'BugsyProbe' called TargetUnit"
local GATE = { kept = "BugsyProbe gate kept", muted = "BugsyProbe gate muted", cleared = "BugsyProbe gate cleared" }
local function gateSnapshot(label)
    local t = { taintLog = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("taintLog") }
    local d = diag()
    t.session, t.hidePopups, t.popupsHidden = d.session, d.hidePopups, d.popupsHidden
    for key, match in pairs(GATE) do
        local m = diag(match)
        t[key] = { count = m.count, muted = m.muted, inPrevious = m.inPrevious }
    end
    gateLog(label, t)
    say(("gate[%s]: session=%s taintLog=%s hidden=%s kept=%s muted=%s/%s cleared=%s"):format(label,
        tostring(t.session), tostring(t.taintLog), table.concat(t.popupsHidden or {}, ","),
        tostring(t.kept.count), tostring(t.muted.count), tostring(t.muted.muted), tostring(t.cleared.count)))
    return t
end

Probe:Steps("gate", {
    title = "Release gate: Blizzard's popups hidden (B-18) and a full exit (#33)", rev = 1,
    { text = "Type /console taintLog 1, then reload (so the taint log covers Bugsy's load).", reload = true },
    { text = "Recording Bugsy's state: the popups it hid, and taintLog.", auto = true,
      run = function() local t = gateSnapshot("start"); return true, tostring(t.taintLog) end,
      check = function() local t = BugsyProbeDB.gate.start
          return t.taintLog == "1" and t.popupsHidden ~= nil and #t.popupsHidden > 0,
              "taintLog " .. tostring(t.taintLog) .. "; hidden: " .. table.concat(t.popupsHidden or {}, ", ") end },
    { text = "Press Run: one forbidden call (TargetUnit). Blizzard's popup should NOT appear.", screenshot = "gate-forbidden",
      run = function() BugsyProbeDB.gate.forbidBase = diag(FORBID).count or 0; return forbid() end },
    { text = "Did Blizzard's \"blocked from an action\" popup appear?", ask = true },
    { text = "Waiting for Bugsy to record the forbidden action.", timeout = 15,
      wait = function() return (diag(FORBID).count or 0) > BugsyProbeDB.gate.forbidBase, "not recorded yet" end,
      check = function() local d = diag(FORBID)
          return (d.count or 0) > BugsyProbeDB.gate.forbidBase, ("count %s (was %s)"):format(tostring(d.count), tostring(BugsyProbeDB.gate.forbidBase)) end },
    { text = "Play normally for a minute: open your bags, the character pane, the spellbook, the world map and the game menu; target something, and fight one mob if you can. Then press Next." },
    { text = "Press Run: three errors for the persistence check.",
      run = function()
          raiseLater(GATE.kept, 0.05); raiseLater(GATE.muted, 0.3); raiseLater(GATE.cleared, 0.6)
          return true end },
    { text = "Waiting for Bugsy to record them.", timeout = 15,
      wait = function()
          for _, m in pairs(GATE) do if (diag(m).count or 0) == 0 then return false, "not recorded yet: " .. m end end
          return true end },
    { text = "Open /bugsy. Select \"" .. GATE.muted .. "\" and press Mute. Then select \"" .. GATE.cleared
        .. "\" and use Manage > Clear this problem. Leave \"" .. GATE.kept .. "\" alone. Then press Next." },
    { text = "Recording what Bugsy holds before the exit.", auto = true,
      run = function() gateSnapshot("before"); return true end,
      check = function() local t = BugsyProbeDB.gate.before
          return (t.kept.count or 0) > 0 and t.muted.muted == true and (t.cleared.count or 0) == 0,
              ("kept %s, muted %s, cleared %s"):format(tostring(t.kept.count), tostring(t.muted.muted), tostring(t.cleared.count)) end },
    { text = "Exit the game completely (not /reload), start it again and log in this character.", reload = "exit" },
    { text = "Comparing with what Bugsy held before the exit.", auto = true,
      run = function() gateSnapshot("after"); return true end,
      check = function()
          local b, a = BugsyProbeDB.gate.before, BugsyProbeDB.gate.after
          local ok = a.session == (b.session or 0) + 1 and a.kept.count == b.kept.count and a.kept.inPrevious == true
              and a.muted.muted == true and (a.cleared.count or 0) == 0
          return ok, ("session %s -> %s; kept %s -> %s (previous: %s); muted %s; cleared %s"):format(
              tostring(b.session), tostring(a.session), tostring(b.kept.count), tostring(a.kept.count),
              tostring(a.kept.inPrevious), tostring(a.muted.muted), tostring(a.cleared.count)) end },
    { text = "Type /console taintLog 0 to turn the taint log off again. Anything odd during this run?", ask = true },
})

-- Boot --------------------------------------------------------------------------------------

local boot = CreateFrame("Frame")
Probe:Steps("front", {
    title = "Bugsy ahead of an installed wrapper (P7, front)", rev = 1,
    { text = "Needs: the addon that installs its own error handler enabled, no standalone error collector, /bugsy front on, a fresh /reload. Press Run to record who holds the handler.",
      run = function() local d = frontState("front-start"); return d.fronted == true, tostring(d.mode) end,
      check = function() local s = BugsyProbeDB.front["front-start"]; return s and s.fronted == true, "Bugsy is in front" end },
    { text = "Press Run: an ordinary error.", run = function() raiseLater("BugsyProbe front ordinary"); return true end },
    { text = "Waiting for Bugsy to record it.", wait = waitRecorded("BugsyProbe front ordinary"), timeout = 15,
      check = function() local d = recorded("BugsyProbe front ordinary", "ordinary"); return located(d), tostring(d.where) end },
    { text = "Type /fp bugsy keyword <that addon's name> (its own-error filter looks for it), then press Run: an error naming it. That addon keeps such errors for itself and may show its own popup.",
      run = function()
          if not BugsyProbeDB.keyword then return false, "set the keyword first" end
          raiseLater("BugsyProbe front own " .. BugsyProbeDB.keyword:lower())
          return true end },
    { text = "Waiting for Bugsy to record it.", wait = waitRecorded("BugsyProbe front own"), timeout = 15,
      check = function() local d = recorded("BugsyProbe front own", "own"); return (d.count or 0) > 0, "recorded by Bugsy" end },
    { text = "Type /bugsy locals on, then press Run: an error with locals (turn them off later with /bugsy locals off).",
      run = function() raiseLater("BugsyProbe front locals"); return true end },
    { text = "Waiting.", wait = waitRecorded("BugsyProbe front locals"), timeout = 15,
      check = function() local d = recorded("BugsyProbe front locals", "locals"); return d.hasLocals == true, "locals kept" end },
    { text = "Press Run: a direct report (geterrorhandler()(msg), no error in flight).",
      run = function() geterrorhandler()("BugsyProbe front direct report"); return true end },
    { text = "Waiting.", wait = waitRecorded("BugsyProbe front direct report"), timeout = 15,
      check = function() local d = recorded("BugsyProbe front direct report", "direct"); return located(d), tostring(d.where) end },
    { text = "At least 10 s after login, press Run: 1100 errors over about 2 s (past that addon's cutoff), then a marker error.",
      run = function()
          for i = 1, 1100 do C_Timer.After(i * 0.002, function() error("BugsyProbe front flood") end) end
          raiseLater("BugsyProbe front marker after the flood", 4)
          return true, "scheduled" end },
    { text = "Waiting for the marker.", wait = waitRecorded("BugsyProbe front marker after the flood"), timeout = 30,
      check = function()
          recorded("BugsyProbe front flood", "flood")
          local d = recorded("BugsyProbe front marker after the flood", "marker")
          frontState("front-end")
          return (d.count or 0) > 0, "marker recorded, tier " .. tostring(d.tier) end },
    { text = "Did that addon show anything (a popup or a chat line) during this procedure?", ask = true },
})

Probe:Steps("frontown", {
    title = "Bugsy installing itself ahead of a wrapper in combat (P6, P7, frontown)", rev = 2,
    { text = "Needs: the addon that installs its own error handler DISABLED, no error collector, /bugsy front on, /console taintLog 1, then a fresh /reload. Press Run to check.",
      run = function() local d = frontState("own-start"); return d.mode == "native" and not d.frontTried, tostring(d.mode) end,
      check = function() local s = BugsyProbeDB.front["own-start"]
          return s and s.mode == "native" and not s.frontTried, "native, no attempt yet" end },
    { text = "Start a fight. In combat, press Run: the probe installs its own wrapper and raises an error; Bugsy should put itself in front, in combat.",
      run = function()
          if not InCombatLockdown() then return false, "not in combat yet" end
          PW.prev = geterrorhandler()
          seterrorhandler(probeWrapper)
          raiseLater("BugsyProbe frontown first")
          return true, "wrapper installed" end },
    { text = "Waiting for Bugsy to install itself.", wait = function() return diag().fronted == true, "not in front yet" end, timeout = 20,
      check = function() local d = frontState("own-installed")
          return d.fronted == true and InCombatLockdown(), "in front, in combat=" .. tostring(InCombatLockdown()) end },
    { text = "Still in combat, press Run: a real error and a direct report.",
      run = function()
          raiseLater("BugsyProbe frontown real")
          C_Timer.After(0.1, function() geterrorhandler()("BugsyProbe frontown direct") end)
          return true end },
    { text = "Waiting.", wait = function()
          local a, b = diag("BugsyProbe frontown real"), diag("BugsyProbe frontown direct")
          return (a.count or 0) > 0 and (b.count or 0) > 0, "not both recorded yet" end, timeout = 15,
      check = function()
          local a = recorded("BugsyProbe frontown real", "own-real")
          recorded("BugsyProbe frontown direct", "own-direct")
          return located(a), tostring(a.where) end },
    { text = "Press Run: an error the probe's wrapper reports again while handling it.",
      run = function() PW.recurse = true; frontState("own-before-recurse"); raiseLater("BugsyProbe frontown outer"); return true end },
    { text = "Waiting.", wait = waitRecorded("BugsyProbe frontown outer"), timeout = 15,
      check = function()
          local before = BugsyProbeDB.front["own-before-recurse"]
          local d = frontState("own-after-recurse")
          local inner = recorded("BugsyProbe frontown inner", "own-inner")
          return (inner.count or 0) == 0 and (d.passSuppressed or 0) >= (before.passSuppressed or 0) + 1,
              "inner dropped; passSuppressed " .. tostring(before.passSuppressed) .. " -> " .. tostring(d.passSuppressed) end },
    { text = "Press Run: an error during which the probe's wrapper throws, then another error.",
      run = function()
          PW.throw = true
          frontState("own-before-throw")
          raiseLater("BugsyProbe frontown throw")
          raiseLater("BugsyProbe frontown after the throw", 0.4)
          return true end },
    { text = "Waiting.", wait = waitRecorded("BugsyProbe frontown after the throw"), timeout = 15,
      check = function()
          local before = BugsyProbeDB.front["own-before-throw"]
          local d = frontState("own-after-throw")
          return (d.forwardFailed or 0) > (before.forwardFailed or 0), "forwardFailed counted, next error recorded" end },
    { text = "Press Run: a later wrapper is installed ahead of Bugsy, then an error.",
      run = function()
          W2.prev = geterrorhandler()
          seterrorhandler(laterWrapper)
          raiseLater("BugsyProbe frontown later wrapper")
          return true end },
    { text = "Waiting.", wait = waitRecorded("BugsyProbe frontown later wrapper"), timeout = 15,
      check = function()
          local d = recorded("BugsyProbe frontown later wrapper", "own-w2")
          local s = frontState("own-end")
          BugsyProbeDB.front["own-w2"].w2calls = W2.calls
          return d.count == 1 and W2.calls > 0 and geterrorhandler() == laterWrapper,
              ("once=%s w2=%d no second front=%s mode=%s"):format(tostring(d.count == 1), W2.calls,
                  tostring(geterrorhandler() == laterWrapper), tostring(s.mode)) end },
    { text = "Leave combat. Did anything show a blocked action or an \"interface action failed\" message?", ask = true },
    { text = "Reload to write the taint log and save the results (the probe's wrappers go away).", reload = true },
})

-- The client's pause (#14): bursts of 99, 100 and 101 errors in one frame, each followed
-- by a marker one second later. Counted on both sides: attempts here, deliveries in
-- Bugsy (Diagnostics), the marker's arrival, Bugsy's pause observation.
-- Scoped to this invocation (Codex, PR #17): the saved result is cleared first, the
-- marker carries the run's id and is established as a problem BEFORE the burst (so
-- Bugsy's new-problem cap cannot hide it), and its arrival is the change in its count.
local function received(match)
    local d = diag(match)
    return (d.count or 0) + (d.unconfirmed or 0)
end

-- Both marker errors come from this one line (Codex, PR #17): the grouping signature reads
-- the stack, so a seed and a later marker raised at different lines would be two problems,
-- and the later one, a new problem, would be dropped at the new-problem cap.
local function markerRaiser(marker) return function() error(marker, 0) end end

-- Before each burst: this run's marker, recorded as a problem first.
local function burstPrepare(label)
    BugsyProbeDB.pause = BugsyProbeDB.pause or {}
    BugsyProbeDB.pause[label] = nil
    BugsyProbeDB.pauseRun = BugsyProbeDB.pauseRun or {}
    local id = ("%.0f"):format(GetTime() * 1000)
    local marker = "BugsyProbe pause marker " .. label .. " r" .. id
    BugsyProbeDB.pauseRun[label] = { id = id, marker = marker }
    C_Timer.After(0, markerRaiser(marker))
    return true, "marker " .. id
end

local function burstFire(label, n)
    local run = BugsyProbeDB.pauseRun and BugsyProbeDB.pauseRun[label]
    if not run then return false, "the marker step did not run" end
    local marker = run.marker
    local before, d0 = received(marker), diag().deliveries or 0
    if before < 1 then return false, "the marker is not recorded yet: wait a second and press Run again" end
    for i = 1, n do
        C_Timer.After(0, function() error("BugsyProbe pause burst " .. label .. " r" .. run.id .. " #" .. i, 0) end)
    end
    C_Timer.After(1, markerRaiser(marker))
    C_Timer.After(2.5, function()
        local d = diag()
        local p = d.pause and d.pause.pause or {}
        local r = { attempts = n, deliveries = (d.deliveries or 0) - d0, markerReceived = received(marker) - before > 0,
            pauseStatus = p.status, evidence = p.evidence, observedCalls = p.observedCalls,
            noticeSeen = p.noticeSeen, deliveredAfter = p.deliveredAfter, mode = d.mode }
        BugsyProbeDB.pause[label] = r
        say(("pause[%s]: %d attempts, %d delivered to Bugsy, marker %s; Bugsy: %s (%s), %s calls, notice %s, %s after")
            :format(label, n, r.deliveries, r.markerReceived and "received" or "NOT received", tostring(r.pauseStatus),
                tostring(r.evidence), tostring(r.observedCalls), tostring(r.noticeSeen), tostring(r.deliveredAfter)))
    end)
    return true, "scheduled"
end

local function burstDone(label)
    return function() return BugsyProbeDB.pause and BugsyProbeDB.pause[label] ~= nil, "running" end
end

Probe:Steps("pause", {
    title = "The client's error-reporting pause (P8, #14)", rev = 3,
    { text = "From a fresh /reload. Recording this run's marker.", auto = true, run = function() return burstPrepare("99") end },
    { text = "Press Run: 99 errors in one frame, then the marker 1 s later.", run = function() return burstFire("99", 99) end },
    { text = "Waiting (about 3 s).", wait = burstDone("99"), timeout = 20 },
    { text = "Recording the next marker.", auto = true, run = function() return burstPrepare("99again") end },
    { text = "Press Run: another 99 in one frame, then the marker (is the limit per frame, or does it add up?).",
      run = function() return burstFire("99again", 99) end },
    { text = "Waiting (about 3 s).", wait = burstDone("99again"), timeout = 20 },
    { text = "Reload.", reload = true },
    { text = "Recording this run's marker.", auto = true, run = function() return burstPrepare("100") end },
    { text = "Press Run: 100 errors in one frame, then the marker.", run = function() return burstFire("100", 100) end },
    { text = "Waiting (about 3 s).", wait = burstDone("100"), timeout = 20 },
    { text = "Press Run: a forbidden call (a Blizzard popup appears: press Ignore). Are blocked actions still captured after the burst?",
      run = function()
          BugsyProbeDB.pause = BugsyProbeDB.pause or {}
          BugsyProbeDB.pause.eventAfter = nil
          local before = received("ADDON_ACTION_FORBIDDEN")
          forbid()
          C_Timer.After(1, function()
              BugsyProbeDB.pause.eventAfter = received("ADDON_ACTION_FORBIDDEN") - before
              say("pause: forbidden events recorded after the burst: " .. BugsyProbeDB.pause.eventAfter)
          end)
          return true end },
    { text = "Waiting.", wait = function() return BugsyProbeDB.pause and BugsyProbeDB.pause.eventAfter ~= nil, "running" end, timeout = 10 },
    { text = "Reload.", reload = true },
    { text = "Recording this run's marker.", auto = true, run = function() return burstPrepare("101") end },
    { text = "Press Run: 101 errors in one frame, then the marker.", run = function() return burstFire("101", 101) end },
    { text = "Waiting (about 3 s).", wait = burstDone("101"), timeout = 20 },
    { text = "Reload to end with error reporting on.", reload = true },
})

-- The front's circuit breaker (#11): a probe wrapper behind Bugsy with a finite cost
-- per call (a busy-wait of N ms on the profiler timer), never a runaway.
local SW = { cost = 0, calls = 0 }
-- each run's errors carry its id, so an earlier run's problems never satisfy a wait
local function fs(text) return "BugsyProbe frontslow " .. (SW.run or "") .. " " .. text end
local function slowWrapper(msg, ...)
    SW.calls = SW.calls + 1
    local t = debugprofilestop()
    while debugprofilestop() - t < SW.cost do end
    if SW.prev then return SW.prev(msg, ...) end
end

local function fwd(label)
    local d = diag()
    local f = d.forward or {}
    local r = { suspended = f.suspended, reason = f.reason, elapsedMs = f.elapsedMs, windowMs = f.windowMs,
        skipped = f.skipped, timingUnavailable = f.timingUnavailable, wrapperCalls = SW.calls, mode = d.mode,
        inCombat = InCombatLockdown() }
    BugsyProbeDB.frontslow = BugsyProbeDB.frontslow or {}
    BugsyProbeDB.frontslow[label] = r
    say(("frontslow[%s]: suspended=%s reason=%s elapsed=%s window=%s skipped=%s wrapperCalls=%d mode=%s combat=%s")
        :format(label, tostring(r.suspended), tostring(r.reason), tostring(r.elapsedMs), tostring(r.windowMs),
            tostring(r.skipped), SW.calls, tostring(r.mode), tostring(r.inCombat)))
    return r
end

local function installSlow(cost)
    SW.cost, SW.calls = cost, 0
    SW.prev = geterrorhandler()
    seterrorhandler(slowWrapper)
    raiseLater(fs("install"))
    return true, "wrapper installed, cost " .. cost .. " ms"
end

Probe:Steps("frontslow", {
    title = "The front's circuit breaker (#11, D16)", rev = 2,
    { text = "Needs: the addon that installs its own error handler DISABLED, no collector, /bugsy front on, a fresh /reload. Press Run to check.",
      run = function() SW.run = ("r%.0f"):format(GetTime() * 1000); local d = diag(); return d.mode == "native" and not d.frontTried, tostring(d.mode) end },
    { text = "Press Run: the probe installs a wrapper costing 20 ms per call, then an error; Bugsy goes in front of it.",
      run = function() return installSlow(20) end },
    { text = "Waiting for Bugsy in front.", wait = function() return diag().fronted == true, "not in front yet" end, timeout = 15 },
    { text = "Press Run: three errors 0.5 s apart (60 ms in total, under both thresholds).",
      run = function()
          for i = 1, 3 do C_Timer.After(i * 0.5, function() error(fs("under ") .. i, 0) end) end
          return true end },
    { text = "Waiting.", wait = function() return (diag(fs("under 3")).count or 0) > 0, "running" end, timeout = 15,
      check = function() local r = fwd("under"); return r.suspended == false, "not suspended" end },
    { text = "Press Run: one error at 60 ms (one slow call), then another error 1 s later.",
      run = function()
          SW.cost = 60
          raiseLater(fs("slow call"))
          C_Timer.After(1, function() error(fs("after the trip"), 0) end)
          return true end },
    { text = "Waiting.", wait = function() return (diag(fs("after the trip")).count or 0) > 0, "running" end, timeout = 15,
      check = function() local r = fwd("call")
          return r.suspended == true and r.reason == "call" and (r.skipped or 0) >= 1,
              ("reason %s, skipped %s, wrapper calls %d"):format(tostring(r.reason), tostring(r.skipped), SW.calls) end },
    { text = "Reload (the suspension lasts the session).", reload = true },
    { text = "Press Run to check the fresh session (native, no attempt yet).",
      run = function() SW.run = ("r%.0f"):format(GetTime() * 1000); local d = diag(); return d.mode == "native" and not d.frontTried, tostring(d.mode) end },
    { text = "Start a fight. In combat, press Run: a wrapper costing 15 ms, then ten errors 0.05 s apart (150 ms within a second).",
      run = function()
          if not InCombatLockdown() then return false, "not in combat yet" end
          installSlow(15)
          for i = 1, 10 do C_Timer.After(1 + i * 0.05, function() error(fs("window ") .. i, 0) end) end
          return true end },
    { text = "Waiting.", wait = function() return (diag(fs("window 10")).count or 0) > 0, "running" end, timeout = 20,
      check = function() local r = fwd("window")
          return r.suspended == true and r.reason == "window", ("reason %s, combat %s"):format(tostring(r.reason), tostring(r.inCombat)) end },
    { text = "Did the game hitch noticeably, or show a blocked action, during this procedure?", ask = true },
    { text = "Reload to end.", reload = true },
})

Probe:RegisterEvents(boot, { "ADDON_LOADED" })
boot:SetScript("OnEvent", function(_, _, name)
    if name ~= ADDON then return end
    Probe:Ready()
    if type(BugsyProbeDB) ~= "table" then BugsyProbeDB = {} end
    if type(BugsyProbeDB.log) ~= "table" then BugsyProbeDB.log = {} end
    Probe:UseLog(BugsyProbeDB.log, MAX_LOG)
    BugsyProbeDB.warnings = { count = 0, samples = {} }
    -- A record stored before ADDON_LOADED (the early test) already lives in the saved
    -- table (store() binds it: LoadSavedVariablesFirst). Appending a table to itself
    -- while iterating it never ends: it hung the client (P5 run, 2026-11-17).
    if type(BugsyProbeDB.records) == "table" and BugsyProbeDB.records ~= rec.records then
        local saved, mine = BugsyProbeDB.records, rec.records
        for i = 1, #mine do saved[#saved + 1] = mine[i] end
        while #saved > MAX_RECORDS do table.remove(saved, 1) end
        rec.records = saved
    elseif type(BugsyProbeDB.records) == "table" then
        while #rec.records > MAX_RECORDS do table.remove(rec.records, 1) end
    else
        BugsyProbeDB.records = rec.records
    end
    BugsyProbeDB.fileScope = NS.fileScope
    if NS.early then BugsyProbeDB.fileScopeSeen = NS.early end
    BugsyProbeDB.loads = (BugsyProbeDB.loads or 0) + 1
    say("loaded (" .. BugsyProbeDB.loads .. " loads). /fp bugsy for the commands, /fp steps for the procedures")
end)

NS._test = { Probe = Probe, rec = rec }
