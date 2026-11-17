-- Bugsy.lua: boot, quiet notices and the slash command. Loaded last; the handler
-- is already installed (end of Capture.lua), so an error in any file after it is
-- caught.

local ADDON, ns = ...
local G, API, Capture, Store = ns.G, ns.API, ns.Capture, ns.Store
local Bugsy = {}
ns.Bugsy = Bugsy
_G.Bugsy = Bugsy          -- the one global: the slash command, the compartment, a later library bridge

Bugsy.NOTICE_EVERY = 10   -- seconds between chat notices
-- The alert sound for a new problem (the owner's pick): a FileDataID, played on the
-- Master channel. FileDataIDs play on Forever; built-in file paths are refused
-- (References\Docs\PORTING-TBC-TO-FOREVER.md, PlaySoundFile).
Bugsy.SOUND, Bugsy.SOUND_CHANNEL = 550736, "Master"

local function say(msg)
    local f = G("DEFAULT_CHAT_FRAME")
    if f and f.AddMessage then
        -- "|" in a problem title must not become markup
        f:AddMessage("|cff9ec9ffBugsy|r: " .. msg)
    end
end
Bugsy.say = say

local function alertSound(db)
    if not db.settings.sound then return end
    local play = G("PlaySoundFile")
    if play then pcall(play, Bugsy.SOUND, Bugsy.SOUND_CHANNEL) end
end

-- Notices: one line and one sound per new problem, at most one every NOTICE_EVERY
-- seconds, held in combat. The chat line and the sound have their own settings.
local pendingNew, lastNotice = 0, -1e9
local function flushNotices()
    if pendingNew == 0 or API.InCombat() then return end
    local db = Store.db()
    if not (db and (db.settings.notices or db.settings.sound)) then pendingNew = 0; return end
    local now = API.Uptime()
    if now - lastNotice < Bugsy.NOTICE_EVERY then
        API.After(Bugsy.NOTICE_EVERY - (now - lastNotice), flushNotices)
        return
    end
    lastNotice = now
    local n = pendingNew
    pendingNew = 0
    if db.settings.notices then
        say(n == 1 and "caught a new problem. Type /bugsy to see it."
            or (n .. " new problems. Type /bugsy to see them."))
    end
    alertSound(db)
end
Bugsy.flushNotices = flushNotices

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
            -- read once a session (Codex, front design): /bugsy front changes the next session
            Capture.state.frontEnabled = db.settings.front ~= false
            Capture.sink = { record = Store.record, count = Store.count }
            Capture.schedule()
        else
            Capture.check(name)
        end
    elseif event == "PLAYER_LOGIN" then
        Capture.check("PLAYER_LOGIN")
        Capture.schedule()
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
        queueDropped = S.stats.queueDropped, suppressed = 0 }
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
        if newest then
            d.where = ns.Signature.where(ns.Signature.lines(type(newest.stack) == "string" and newest.stack or nil))
            d.tier, d.entry = newest.tier, newest.entry
            d.hasLocals = type(newest.locals) == "string" or (type(newest.locals) == "table" and newest.locals.text ~= nil)
        end
    end
    return d
end

local function setting(key, arg)
    local db = Store.db()
    if not db then return end
    if arg == "on" then db.settings[key] = true elseif arg == "off" then db.settings[key] = false end
    return db.settings[key]
end

local HELP = {
    "/bugsy - open the window",
    "/bugsy report - report a problem that showed no error",
    "/bugsy locals on|off - capture local variables with errors (may contain names; off by default)",
    "/bugsy notices on|off - a chat line when a new problem is caught",
    "/bugsy sound on|off - a sound when a new problem is caught",
    "/bugsy status - how Bugsy is catching errors",
    "/bugsy front on|off - catch errors ahead of another addon's error handler (on by default; from the next session)",
}

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
        local on = setting("sound", arg)
        say("the sound for a new problem is " .. (on and "on." or "off."))
        if on and arg == "on" then alertSound(Store.db()) end
    elseif cmd == "front" then
        local on = setting("front", arg)
        say("catching errors ahead of another addon's handler is " .. ((on ~= false) and "on" or "off")
            .. (((arg == "on" or arg == "off") and " from the next session (/reload).") or "."))
    elseif cmd == "status" then
        local mode, lost, failures, pending = Bugsy.Status()
        say(mode .. "; " .. lost .. " not fully captured this session; " .. failures
            .. " internal failures; " .. pending .. " waiting.")
        for _, l in ipairs(Capture.limits()) do say(l) end
    else
        for _, line in ipairs(HELP) do say(line) end
    end
end

_G.SLASH_BUGSY1 = "/bugsy"
local slash = G("SlashCmdList")
if slash then slash.BUGSY = Bugsy.Slash end

-- The minimap's addon compartment (TOC: AddonCompartmentFunc).
function _G.Bugsy_OnAddonCompartmentClick()
    if ns.UI then ns.UI.Toggle() end
end

ns._test = ns._test or {}
ns._test.Bugsy = Bugsy
