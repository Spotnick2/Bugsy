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
local function showCopyBox()
    if not copyBox then
        local f = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(520, 120)
        f:SetPoint("CENTER", 0, 150)
        local e = CreateFrame("EditBox", nil, f)
        e:SetMultiLine(true)
        e:SetAutoFocus(false)
        e:SetFontObject("ChatFontNormal")
        e:SetWidth(480)
        e:SetPoint("TOPLEFT", 16, -30)
        f.edit = e
        copyBox = f
    end
    copyBox.edit:SetText(SAMPLE .. "\n" .. SAMPLE:gsub("|", "||"))
    copyBox:Show()
    copyBox.edit:SetFocus()
    copyBox.edit:HighlightText()
    BugsyProbeDB.copySample = { raw = SAMPLE, escaped = (SAMPLE:gsub("|", "||")) }
    return true, "shown: line 1 raw, line 2 with pipes doubled"
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

Probe:Steps("floods", {
    title = "Floods (P8)", rev = 1,
    { text = "1000 identical errors in one frame. The game may stutter. Press Run.", run = function() return flood("flood-same", 1000, false) end },
    { text = "Waiting.", wait = function() return BugsyProbeDB.floods and BugsyProbeDB.floods["flood-same"], "running" end, timeout = 20 },
    { text = "Did the game freeze noticeably (more than half a second)?", ask = true },
    { text = "1000 unique errors. Press Run.", run = function() return flood("flood-unique", 1000, true) end },
    { text = "Waiting.", wait = function() return BugsyProbeDB.floods and BugsyProbeDB.floods["flood-unique"], "running" end, timeout = 20 },
    { text = "Did the game freeze noticeably?", ask = true },
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
    title = "Living with another error collector (P7, P11)", rev = 2,
    { text = "Is a standalone error collector enabled right now?", ask = true },
    { text = "Recording who holds the handler.", auto = true, run = function() return handlerState("coexist-1") end },
    { text = "In the AddOns list: disable the standalone error collector and its viewer. Keep any addon that embeds its own copy of one enabled. Then reload.", reload = true },
    { text = "Recording who holds the handler now.", auto = true, run = function() return handlerState("coexist-2") end },
    { text = "Press Run to raise an error, then open /bugsy: is it listed?", run = function()
        C_Timer.After(0.1, function() error("BugsyProbe coexistence error") end); return true end },
    { text = "Is the error listed in Bugsy's window?", ask = true },
    { text = "Is an addon that embeds its own error collector installed and enabled?", ask = true },
})

Probe:Steps("popups", {
    title = "Blizzard's blocked-action popup (P4, P10)", rev = 1,
    { text = "Press Run: one forbidden call (TargetUnit). A Blizzard popup may appear.", run = forbid, screenshot = "forbidden" },
    { text = "Did a popup appear?", ask = true },
    { text = "Press Run: stop Blizzard's popup listeners for this session.", run = unregisterPopups },
    { text = "Press Run: the forbidden call again.", run = forbid, screenshot = "forbidden-unregistered" },
    { text = "Did a popup appear this time?", ask = true },
    { text = "Check /fp for taint lines from the host. Any new ones after the second call?", ask = true },
    { text = "Reload to restore Blizzard's listeners.", reload = true },
})

Probe:Steps("copy", {
    title = "Copying from an edit box (P12)", rev = 1,
    { text = "A box shows two lines and selects them. Press Run.", run = showCopyBox, screenshot = "copybox" },
    { text = "Press Ctrl+C, click into this Note box, Ctrl+V, then Enter. Then press Next.", },
    { text = "Setting 63 KB of text and reading it back.", auto = true, run = bigText },
})

-- Boot --------------------------------------------------------------------------------------

local boot = CreateFrame("Frame")
Probe:RegisterEvents(boot, { "ADDON_LOADED" })
boot:SetScript("OnEvent", function(_, _, name)
    if name ~= ADDON then return end
    Probe:Ready()
    if type(BugsyProbeDB) ~= "table" then BugsyProbeDB = {} end
    if type(BugsyProbeDB.log) ~= "table" then BugsyProbeDB.log = {} end
    Probe:UseLog(BugsyProbeDB.log, MAX_LOG)
    BugsyProbeDB.warnings = { count = 0, samples = {} }
    if type(BugsyProbeDB.records) == "table" then
        for _, r in ipairs(rec.records) do BugsyProbeDB.records[#BugsyProbeDB.records + 1] = r end
        rec.records = BugsyProbeDB.records
    else
        BugsyProbeDB.records = rec.records
    end
    BugsyProbeDB.fileScope = NS.fileScope
    if NS.early then BugsyProbeDB.fileScopeSeen = NS.early end
    BugsyProbeDB.loads = (BugsyProbeDB.loads or 0) + 1
    say("loaded (" .. BugsyProbeDB.loads .. " loads). /fp bugsy for the commands, /fp steps for the procedures")
end)

NS._test = { Probe = Probe, rec = rec }
