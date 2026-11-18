-- wow_stubs.lua: Bugsy's WoW: Forever mock for Lua 5.1 unit tests.
-- dofile("tests/wow_stubs.lua") FIRST in every test; drive it through WoW.
--
-- The mechanics are WowTestKit's (tests/kit.lua loads the commit and build that
-- tests/kit.pin names). This file adds the client APIs Bugsy touches: the error
-- handler and stack functions, add-on metadata, the chat frame, EventRegistry.
-- Each is in the 70959 dump; behaviour is modelled on Blizzard's source where it
-- matters (Blizzard_ScriptErrors.lua for the stack formula).

dofile("tests/kit.lua")
local Methods = WoW.Methods
local newWidget = WoW.newWidget

local function resetBugsy()
    WoW.cvars = { taintLog = "0" }
    WoW.handler = nil
    WoW.stack = "[Interface/AddOns/TestAddon/Core.lua]:10: in function <Interface/AddOns/TestAddon/Core.lua:5>\n[C]: ?"
    WoW.locals = "self = <table>\nx = 1"
    WoW.errorHeight = 3
    WoW.sounds = {}
    WoW.callHeight = 10
    WoW.stackCalls = {}
    WoW.instance = "none"
    WoW.clock = 1763400000
    WoW.ms = 0
    WoW.addons = {
        { name = "TestAddon", title = "Test Addon", loaded = true, meta = { Version = "1.2.3", ["X-Website"] = "https://example.org/testaddon" } },
        { name = "OtherAddon", title = "Other Addon", loaded = true, meta = { Version = "0.9" } },
        { name = "!Bugsy", title = "Bugsy", loaded = true, meta = { Version = "dev" } },
    }
    WoW.playerName, WoW.realm = "Karuzo", "Morphisto"
    WoW.lines = {}
end
table.insert(WoW.onReset, resetBugsy)
resetBugsy()

-- Templates (only what the code reads back).
WoW.templates.UIPanelScrollFrameTemplate = function(w) w.ScrollBar = newWidget("Slider", w) end
-- The fields the Options page checks to know a template really built its button (#22).
WoW.templates.UICheckButtonTemplate = function(w) w.text = newWidget("FontString", w) end
WoW.templates.UIRadioButtonTemplate = function(w) w.text = newWidget("FontString", w) end
WoW.templates.UIPanelButtonTemplate = function(w) w.Text = newWidget("FontString", w) end

-- Widget methods the core lacks.
-- A button's state textures: Set<State>Texture(file) makes the texture Get<State>Texture
-- returns, as the client does (the Options page's fallback art sets coordinates on it).
for _, state in ipairs({ "Normal", "Pushed", "Highlight", "Checked", "Disabled" }) do
    Methods["Set" .. state .. "Texture"] = function(b, file)
        b["_" .. state] = b["_" .. state] or newWidget("Texture", b)
        b["_" .. state]._file = file
    end
    Methods["Get" .. state .. "Texture"] = function(b) return b["_" .. state] end
end
function Methods.HighlightText(e) e._highlighted = true end
function Methods.SetFocus(e) e._focus = true end
function Methods.ClearFocus(e) e._focus = false end
function Methods.LockHighlight(b) b._locked = true end
function Methods.UnlockHighlight(b) b._locked = false end
function Methods.AddMessage(f, text) table.insert(WoW.lines, text) end
function Methods.SetScrollChild(s, c) s._child = c end

-- Client functions ------------------------------------------------------------------

SlashCmdList = {}
WOW_PROJECT_ID = 21
function date(fmt, t) return os.date(fmt, t or WoW.clock) end
function time() return WoW.clock end
function GetBuildInfo() return "1.60.1", "70959", "Nov 13 2026", 16001 end
function UnitName(unit) if unit == "player" then return WoW.playerName, nil end end
function GetRealmName() return WoW.realm end
function IsInInstance() return WoW.instance ~= "none", WoW.instance end
function debugprofilestop() return WoW.ms end
C_CVar = { GetCVar = function(name) return WoW.cvars[name] end }

-- Secret checks: the kit's proxies are the secrets; everything else is accessible.
function canaccessvalue(v) return not issecretvalue(v) end
function canaccesstable(t) return not issecretvalue(t) end

-- The error handler, as the client keeps it.
function seterrorhandler(fn) WoW.handler = fn end
function geterrorhandler() return WoW.handler end
function GetCallstackHeight() return WoW.callHeight end
function GetErrorCallstackHeight() return WoW.errorHeight end
-- Sounds played, in order: { id, channel }.
function PlaySoundFile(id, channel) WoW.sounds[#WoW.sounds + 1] = { id, channel }; return true, 1 end
function debugstack(level, top, bottom)
    table.insert(WoW.stackCalls, { level = level, top = top, bottom = bottom })
    local s = WoW.stack
    if top and type(s) == "string" then
        local out, n = {}, 0
        for line in s:gmatch("[^\n]+") do
            n = n + 1
            if n > top then break end
            out[#out + 1] = line
        end
        s = table.concat(out, "\n")
    end
    return s
end
function debuglocals(level) return WoW.locals end

-- Raise an error the way the client does: call the installed handler.
function WoW.raise(msg) if WoW.handler then return WoW.handler(msg) end end

local function addon(nameOrIndex)
    if type(nameOrIndex) == "number" then return WoW.addons[nameOrIndex] end
    for _, a in ipairs(WoW.addons) do if a.name == nameOrIndex then return a end end
end
C_AddOns = {
    GetAddOnMetadata = function(name, field) local a = addon(name); return a and a.meta[field] end,
    IsAddOnLoaded = function(name) local a = addon(name); return a and a.loaded or false, a and a.loaded or false end,
    GetNumAddOns = function() return #WoW.addons end,
    GetAddOnInfo = function(i)
        local a = addon(i)
        if a then return a.name, a.title, "", true, nil, "INSECURE" end
    end,
}

DEFAULT_CHAT_FRAME = newWidget("ScrollingMessageFrame", UIParent, "ChatFrame1")

-- EventRegistry: callbacks by event, called synchronously.
EventRegistry = { _cb = {} }
function EventRegistry:RegisterCallback(event, fn, owner)
    self._cb[event] = self._cb[event] or {}
    table.insert(self._cb[event], { fn = fn, owner = owner })
end
function EventRegistry:TriggerEvent(event, ...)
    for _, c in ipairs(self._cb[event] or {}) do c.fn(c.owner, ...) end
end

-- Retail's Settings framework, Options > AddOns (#22), recorded in WoW.settings; Blizzard's
-- Settings window, hidden until opened. Both in the 70959 dump.
local function resetSettings()
    WoW.settings = { canvas = {}, addons = {}, subs = {} }
    SettingsPanel = newWidget("Frame", UIParent, "SettingsPanel")
    SettingsPanel:Hide()
    function SettingsPanel:Close(skipTransition) WoW.settings.closedWith = skipTransition; self:Hide() end
    Settings = {
        RegisterCanvasLayoutCategory = function(frame, name)
            local cat = { frame = frame, name = name, GetID = function() return "cat:" .. name end }
            WoW.settings.canvas[#WoW.settings.canvas + 1] = cat
            return cat
        end,
        RegisterAddOnCategory = function(cat) WoW.settings.addons[#WoW.settings.addons + 1] = cat end,
        OpenToCategory = function(id) WoW.settings.opened = id; SettingsPanel:Show() end,
        RegisterCanvasLayoutSubcategory = function(parent, frame, name)
            local cat = { parent = parent, frame = frame, name = name }
            WoW.settings.subs[#WoW.settings.subs + 1] = cat
            return cat
        end,
    }
end
table.insert(WoW.onReset, resetSettings)
resetSettings()

-- Another addon's LibDataBroker-1.1 and LibDBIcon-1.0 (#26: Bugsy borrows them, never
-- embeds them): LibStub hands out recording fakes (as Gnomesweeper's stub, modelled on
-- LibDBIcon MINOR 56: Show/Hide only show or hide the button, never the saved table).
-- WoW.ldb.objects, WoW.ldbi.registered / .buttons. `LibStub = nil`: no addon brought them.
function WoW.newLDB()
    local lib = { objects = {} }
    function lib:NewDataObject(name, obj)
        if self.objects[name] then return nil end          -- the name taken
        self.objects[name] = obj
        return obj
    end
    return lib
end
function WoW.newLDBI()
    local lib = { registered = {}, buttons = {} }
    function lib:Register(name, obj, db)
        local b = newWidget("Button", UIParent, "LibDBIcon10_" .. name)
        b._scripts.OnClick = function(self, mouse) obj.OnClick(self, mouse) end
        b.dataObject, b.db = obj, db
        if db.hide then b:Hide() end
        self.registered[name], self.buttons[name] = db, b
    end
    function lib:Show(name) self.buttons[name]:Show() end
    function lib:Hide(name) self.buttons[name]:Hide() end
    return lib
end
local function resetLibs()
    WoW.ldb, WoW.ldbi = WoW.newLDB(), WoW.newLDBI()
    LibStub = setmetatable({}, { __call = function(_, major, silent)
        if major == "LibDataBroker-1.1" then return WoW.ldb end
        if major == "LibDBIcon-1.0" then return WoW.ldbi end
        if not silent then error("Cannot find a library instance of " .. tostring(major)) end
    end })
    -- The client's minimap (in the dump), for Bugsy's own button: its centre in UI units
    -- and its effective scale, which the kit doesn't model.
    Minimap = newWidget("Minimap", UIParent, "Minimap")
    Minimap:SetSize(140, 140)
    function Minimap:GetCenter() return 1000, 600 end
    function Minimap:GetEffectiveScale() return WoW.minimapScale or 1 end
    WoW.minimapScale = 1
    GameTooltip = newWidget("GameTooltip", UIParent, "GameTooltip")
    GameTooltip._lines = {}
    function GameTooltip:AddLine(text) self._lines[#self._lines + 1] = text end
end
table.insert(WoW.onReset, resetLibs)
resetLibs()

-- The other error collector's public names (Capture.COLLECTOR must match; test_collector checks).
COLLECTOR = { global = "BugGrabber", event = "BugGrabber.BugGrabbed" }

Kit.strict({ "BugsyDB", "Bugsy", COLLECTOR.global, "SLASH_BUGSY1", "Bugsy_OnAddonCompartmentClick", "Bugsy_OnAddonCompartmentEnter", "Bugsy_OnAddonCompartmentLeave", "Settings", "SettingsPanel", "LibStub", "GameTooltip", "Minimap" })
