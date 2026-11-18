-- Bugsy.lua: boot, quiet notices and the slash command. Loaded last; the handler
-- is already installed (end of Capture.lua), so an error in any file after it is
-- caught.

local ADDON, ns = ...
local G, API, Capture, Store = ns.G, ns.API, ns.Capture, ns.Store
local Bugsy = {}
ns.Bugsy = Bugsy
_G.Bugsy = Bugsy          -- the one global: the slash command, the compartment, a later library bridge

Bugsy.NOTICE_EVERY = 10   -- seconds between chat notices
-- The alert sounds for a new problem (the owner's picks, #19): FileDataIDs, played on the
-- Master channel. FileDataIDs play on Forever; built-in file paths are refused
-- (References\Docs\PORTING-TBC-TO-FOREVER.md, PlaySoundFile). The first is the default;
-- the setting saves the FileDataID, so reordering this list never changes a choice.
-- The client's sound names are in the comments; the names shown are ours.
Bugsy.SOUNDS = {
    { id = 597938,  name = "Goblin klaxon" },   -- EVENT_THIntro_GoblinKlaxon_Loop
    { id = 1859972, name = "Metal pops 1" },    -- FX_Goblin_MetalPops01
    { id = 1859973, name = "Metal pops 2" },    -- FX_Goblin_MetalPops02
    { id = 1859974, name = "Metal pops 3" },    -- FX_Goblin_MetalPops03
    { id = 1859975, name = "Metal pops 4" },    -- FX_Goblin_MetalPops04
    { id = 550736,  name = "Hotrod horn" },     -- GoblinHotrod_Horn
}
Bugsy.SOUND_CHANNEL = "Master"

local function say(msg)
    local f = G("DEFAULT_CHAT_FRAME")
    if f and f.AddMessage then
        -- "|" in a problem title must not become markup
        f:AddMessage("|cff9ec9ffBugsy|r: " .. msg)
    end
end
Bugsy.say = say

-- The chosen sound's place in the list; an unknown saved one falls back to the default.
local function soundIndex(db)
    local id = db and db.settings.soundId
    for i, s in ipairs(Bugsy.SOUNDS) do if s.id == id then return i end end
    return 1
end

local function playSound(db)
    local play = G("PlaySoundFile")
    if play then pcall(play, Bugsy.SOUNDS[soundIndex(db)].id, Bugsy.SOUND_CHANNEL) end
end

local function alertSound(db)
    if db.settings.sound then playSound(db) end
end

-- Capture-health lines (#14, #11), each said once per state; the full wording is in
-- Capture.limits (/bugsy status, reports).
local announced = {}
local function healthLines()
    local S, out = Capture.state, {}
    local p = S.health.pause
    if p and announced.pause ~= p.status then
        announced.pause = p.status
        out[#out + 1] = (p.status == "reported")
            and "the game says Lua error reporting is paused until you /reload. See /bugsy status."
            or "a large burst of errors: the game may have paused Lua error reporting. /reload resets it; see /bugsy status."
    end
    if S.forward.suspended and not announced.forward then
        announced.forward = true
        out[#out + 1] = "stopped passing errors to another addon's error handler after it was slow. See /bugsy status."
    end
    return out
end

-- Notices: one line and one sound per new problem, and one line per capture-health
-- change; at most one flush every NOTICE_EVERY seconds, held in combat. The chat
-- lines and the sound have their own settings; health lines never play the sound.
local pendingNew, pendingHealth, lastNotice = 0, false, -1e9
local function flushNotices()
    if (pendingNew == 0 and not pendingHealth) or API.InCombat() then return end
    local db = Store.db()
    if not db then return end
    local now = API.Uptime()
    if now - lastNotice < Bugsy.NOTICE_EVERY then
        API.After(Bugsy.NOTICE_EVERY - (now - lastNotice), flushNotices)
        return
    end
    lastNotice = now
    if pendingHealth then
        pendingHealth = false
        local lines = healthLines()
        if db.settings.notices then for _, l in ipairs(lines) do say(l) end end
    end
    local n = pendingNew
    pendingNew = 0
    if n > 0 then
        if db.settings.notices then
            say(n == 1 and "caught a new problem. Type /bugsy to see it."
                or (n .. " new problems. Type /bugsy to see them."))
        end
        alertSound(db)
    end
end
Bugsy.flushNotices = flushNotices

-- Called from inside the handler when a health observation changes: queue only.
Capture.onHealth = function()
    pendingHealth = true
    API.After(0, flushNotices)
end

Store.OnChange(function(what, p)
    if what == "new" and not (p and p.muted) then
        pendingNew = pendingNew + 1
        flushNotices()
    end
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end)

-- Boot -------------------------------------------------------------------------------

local boot = G("CreateFrame")("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_REGEN_ENABLED")
boot:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name == ADDON then
            local db = Store.adopt(rawget(_G, "BugsyDB"))
            _G.BugsyDB = db
            Capture.state.settings = db.settings
            Capture.state.session = db.session
            -- read once a session (Codex, front design): /bugsy front changes the next session
            Capture.state.frontEnabled = db.settings.front ~= false
            -- Blizzard's popups for what Bugsy records (B-18): hidden from this load, read once
            -- a session like front (they can't be put back without a reload).
            Capture.state.hidePopups = db.settings.hidePopups ~= false
            if Capture.state.hidePopups then pcall(Capture.SuppressPopups) end
            Capture.sink = { record = Store.record, count = Store.count }
            Capture.schedule()
        else
            -- Blizzard's warning window, should it load after Bugsy.
            if name == "Blizzard_ScriptErrorsFrame" and Capture.state.hidePopups then pcall(Capture.SuppressPopups) end
            Capture.check(name)
        end
    elseif event == "PLAYER_LOGIN" then
        Capture.check("PLAYER_LOGIN")
        Capture.schedule()
        -- The window's look, after capture is settled; never on the capture path, and a
        -- failure here leaves the Forever look (Theme reads nil as Forever).
        if ns.Theme then pcall(ns.Theme.Decide) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        flushNotices()
    end
end)

-- Slash command -----------------------------------------------------------------------

function Bugsy.Status()
    local S = Capture.state
    local mode = ({ native = "catching errors itself", collector = "reading from another error collector",
        displaced = "unsure: another addon replaced the error handler and no error has reached Bugsy since",
        chained = "receiving errors through another addon's handler",
        front = "catching errors ahead of another addon's handler, and passing them on to it" })[S.mode] or S.mode
    local queued, counts = Capture.pending()
    local lost = 0
    for _, n in pairs(S.stats.suppressed) do lost = lost + n end
    return mode, lost + S.stats.queueDropped + S.stats.passSuppressed, S.failures, queued + counts
end

-- For BugsyProbe: the raw capture mode, whether the other collector's API is present,
-- the front handler's state and counters, and (with `match`) the problems whose title
-- contains that text: how many occurrences, and the newest sample's first location,
-- tier, entry and whether it has locals.
function Bugsy.Diagnostics(match)
    local S = Capture.state
    local d = { mode = S.mode, collector = Capture.collectorUsable() ~= nil, frontTried = S.frontTried,
        frontEnabled = S.frontEnabled, fronted = G("geterrorhandler") and G("geterrorhandler")() == Capture.front,
        passSuppressed = S.stats.passSuppressed, passReturned = S.stats.passReturned,
        forwardFailed = S.stats.forwardFailed,
        nativeInCollector = S.stats.nativeInCollector, failures = S.failures,
        deliveries = S.stats.deliveries, pause = Capture.healthSnapshot(), forward = Capture.forwardSnapshot(),
        queueDropped = S.stats.queueDropped, suppressed = 0,
        -- the release gate's checks (#33): Blizzard's popups hidden, and what persists
        hidePopups = S.hidePopups, popupsHidden = S.popupsHidden, session = Store.db() and Store.db().session }
    for _, n in pairs(S.stats.suppressed) do d.suppressed = d.suppressed + n end
    if type(match) == "string" and match ~= "" then
        local count, unconfirmed, newest = 0, 0, nil
        for _, p in ipairs(Store.List("all", true)) do
            if p.title:find(match, 1, true) then
                count = count + p.count
                unconfirmed = unconfirmed + (p.unconfirmedRepeats or 0)
                local s = p.last[#p.last] or p.first[#p.first]
                if s and (not newest or (s.at or 0) >= (newest.at or 0)) then newest = s end
            end
        end
        d.count, d.unconfirmed = count, unconfirmed
        -- muted, and in the previous session's list (the persistence check, #33)
        for _, p in ipairs(Store.List("all", true)) do
            if p.title:find(match, 1, true) and p.muted then d.muted = true end
        end
        for _, p in ipairs(Store.List("previous", true)) do
            if p.title:find(match, 1, true) then d.inPrevious = true end
        end
        if newest then
            d.where = ns.Signature.where(ns.Signature.lines(type(newest.stack) == "string" and newest.stack or nil))
            d.tier, d.entry = newest.tier, newest.entry
            d.hasLocals = type(newest.locals) == "string" or (type(newest.locals) == "table" and newest.locals.text ~= nil)
        end
    end
    return d
end

-- The settings (#22): one place they change, for the slash command and the Options page,
-- so the two can't drift. Each is a boolean in BugsyDB.settings; the sound's choice is
-- ChooseSound. Turning the sound on plays it, as a sample. False when refused.
Bugsy.TOGGLES = { locals = true, notices = true, sound = true, front = true, hidePopups = true }

local function settingsChanged()
    if ns.Options and ns.Options.Refresh then ns.Options.Refresh() end
end

-- "minimap" (#26) is LibDBIcon's own table, BugsyDB.minimap.hide, not a setting.
function Bugsy.Get(key)
    local db = Store.db()
    if not db then return nil end
    if key == "minimap" then return db.minimap.hide ~= true end
    return db.settings[key]
end

function Bugsy.SetSetting(key, on)
    local db = Store.db()
    if not (db and (Bugsy.TOGGLES[key] or key == "minimap") and type(on) == "boolean") then return false end
    if key == "minimap" then
        db.minimap.hide = not on
        if ns.Minimap then ns.Minimap.Apply() end
    else
        db.settings[key] = on
    end
    if key == "sound" and on then playSound(db) end
    settingsChanged()
    return true
end

-- The n-th sound: saved as its FileDataID, the sound turned on, and played.
function Bugsy.ChooseSound(n)
    local db = Store.db()
    if not (db and type(n) == "number" and Bugsy.SOUNDS[n]) then return false end
    db.settings.soundId, db.settings.sound = Bugsy.SOUNDS[n].id, true
    playSound(db)
    settingsChanged()
    return true
end

function Bugsy.SoundIndex() return soundIndex(Store.db()) end

local function setting(key, arg)
    if arg == "on" or arg == "off" then Bugsy.SetSetting(key, arg == "on") end
    return Bugsy.Get(key)
end

-- What /bugsy status says, and the Options page shows (#22).
function Bugsy.StatusLines()
    local mode, lost, failures, pending = Bugsy.Status()
    local lines = { mode .. "; " .. lost .. " not fully captured this session; " .. failures
        .. " internal failures; " .. pending .. " waiting." }
    for _, l in ipairs(Capture.limits()) do lines[#lines + 1] = l end
    local hidden = Capture.state.popupsHidden
    if hidden and #hidden > 0 then
        lines[#lines + 1] = "Blizzard's popups for blocked actions and its Lua warning window are hidden; "
            .. "Bugsy records them (" .. table.concat(hidden, ", ") .. ")."
    elseif Capture.state.hidePopups then
        lines[#lines + 1] = "Blizzard's popups couldn't be hidden on this client: they show as well."
    end
    return lines
end

-- /bugsy help, and the About page's commands (#22): one list.
local HELP = {
    "/bugsy - open the window",
    "/bugsy report - report a problem that showed no error",
    "/bugsy locals on|off - capture local variables with errors (may contain names; off by default)",
    "/bugsy notices on|off - a chat line when a new problem is caught",
    "/bugsy sound on|off - a sound when a new problem is caught",
    "/bugsy sound 1-6 - choose that sound (plays it); /bugsy sound lists them",
    "/bugsy status - how Bugsy is catching errors",
    "/bugsy options - open Bugsy's page in Options > AddOns",
    "/bugsy minimap on|off - the minimap button",
    "/bugsy look forever|pearl|follow - the window's look (follow: Glass UI's)",
    "/bugsy front on|off - catch errors ahead of another addon's error handler (on by default; from the next session)",
    "/bugsy popups hide|show - Blizzard's popups for blocked actions and Lua warnings, which Bugsy records (hidden by default; from the next session)",
}
Bugsy.HELP = HELP

function Bugsy.Slash(msg)
    msg = type(msg) == "string" and msg:lower():match("^%s*(.-)%s*$") or ""
    local cmd, arg = msg:match("^(%S*)%s*(.*)$")
    if cmd == "" or cmd == "show" then
        if ns.UI then ns.UI.Toggle() end
    elseif cmd == "report" then
        if ns.ReportUI then ns.ReportUI.OpenManual() end
    elseif cmd == "locals" then
        local on = setting("locals", arg)
        say("locals are " .. (on and "captured with new errors. They can contain names and messages." or "not captured."))
    elseif cmd == "notices" then
        local on = setting("notices", arg)
        say("chat notices are " .. (on and "on." or "off."))
    elseif cmd == "sound" then
        local db, n = Store.db(), tonumber(arg)
        if not db then return end
        if n and Bugsy.ChooseSound(n) then
            say(("the sound for a new problem is %d. %s."):format(n, Bugsy.SOUNDS[n].name))
        elseif arg == "on" or arg == "off" then
            local on = setting("sound", arg)
            local i = soundIndex(db)
            say(("the sound for a new problem is %s (%d. %s)."):format(on and "on" or "off", i, Bugsy.SOUNDS[i].name))
        elseif arg == "" then
            local i = soundIndex(db)
            say(("the sound for a new problem is %s. /bugsy sound <number> chooses one (and plays it):")
                :format(db.settings.sound and "on" or "off"))
            for k, s in ipairs(Bugsy.SOUNDS) do
                say(("  %d. %s%s"):format(k, s.name, k == i and " (current)" or ""))
            end
        else
            say(("/bugsy sound on|off, or a number from 1 to %d."):format(#Bugsy.SOUNDS))
        end
    elseif cmd == "front" then
        local on = setting("front", arg)
        say("catching errors ahead of another addon's handler is " .. ((on ~= false) and "on" or "off")
            .. (((arg == "on" or arg == "off") and " from the next session (/reload).") or "."))
    elseif cmd == "popups" then
        local onOff = (arg == "hide" and "on") or (arg == "show" and "off") or ""
        local on = setting("hidePopups", onOff)
        say("Blizzard's popups for blocked actions and Lua warnings are " .. ((on ~= false) and "hidden" or "shown")
            .. ((onOff ~= "" and " from the next session (/reload).") or ". /bugsy popups hide or show."))
    elseif cmd == "status" then
        for _, l in ipairs(Bugsy.StatusLines()) do say(l) end
    elseif cmd == "look" then
        local T = ns.Theme
        if arg == "forever" or arg == "pearl" or arg == "follow" then
            if not T.SetChoice(arg) then
                say(arg == "follow" and "Glass UI isn't loaded, so there is no suite look to follow."
                    or "Pearl Glass needs a Glass addon (Glass UI, for example) loaded.")
            end
        elseif arg ~= "" then
            say("/bugsy look forever, pearl or follow.")
        end
        local name, note = T.Describe()
        say("the window's look is " .. name .. "." .. (note and (" " .. note) or ""))
    elseif cmd == "minimap" then
        local on = setting("minimap", arg)
        say("the minimap button is " .. (on and "shown." or "hidden.")
            .. ((on and ns.Minimap and not ns.Minimap.Available()) and " (It couldn't be made this session.)" or ""))
    elseif cmd == "options" or cmd == "settings" or cmd == "config" then
        if not (ns.Options and ns.Options.Open()) then
            say("the settings are in the game's Options > AddOns > Bugsy.")
        end
    else
        for _, line in ipairs(HELP) do say(line) end
    end
end

_G.SLASH_BUGSY1 = "/bugsy"
local slash = G("SlashCmdList")
if slash then slash.BUGSY = Bugsy.Slash end

ns._test = ns._test or {}
ns._test.Bugsy = Bugsy
