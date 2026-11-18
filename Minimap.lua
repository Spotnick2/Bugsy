-- Minimap.lua: the minimap button and the addon compartment (#26). Left-click opens or
-- closes the window, right-click opens the settings. The button is a LibDataBroker
-- launcher shown by LibDBIcon (Libs\, copied from Glass MiniMap Bar, as Gnomesweeper's),
-- which gives dragging around the ring, round and square minimaps, and lets every
-- button collector pick it up. Its place and shown state are LibDBIcon's own table,
-- BugsyDB.minimap (Store.adopt makes it once). Showing it is the "minimap" setting
-- (Bugsy.SetSetting: /bugsy minimap, the Options page).
--
-- The libraries load after Capture.lua, so an error while they load is caught; nothing
-- here runs on the capture path. Without them, or with the name taken: no button, and
-- nothing else breaks.

local ADDON, ns = ...
local G = ns.G
local MM = {}
ns.Minimap = MM

MM.NAME = "Bugsy"
MM.ICON = "Interface\\Icons\\Spell_Nature_InsectSwarm"   -- until Bugsy has its own logo (#26)
local registered = false

local function lib(name)
    local stub = G("LibStub")
    if not stub then return nil end
    local ok, l = pcall(stub, name, true)
    return ok and l or nil
end

-- Whether there is a button this session.
function MM.Available() return registered end

-- One click, from the minimap button or the compartment (each passes something first:
-- the button, or the addon's name; then the mouse button).
function MM.Click(_, button)
    if button == "RightButton" then
        if not (ns.Options and ns.Options.Open()) then
            ns.Bugsy.say("the settings are in the game's Options > AddOns > Bugsy.")
        end
    elseif ns.UI then
        ns.UI.Toggle()
    end
end

-- The tooltip: this session's problems, then what each click does.
local function tooltip(tip, drag)
    tip:AddLine("Bugsy")
    local db = ns.Store.db()
    if db then
        local n = #ns.Store.List("session")
        tip:AddLine(n == 1 and "1 problem this session" or (n .. " problems this session"), 1, 1, 1)
    end
    tip:AddLine("Left-click: open or close the window", 0.75, 0.78, 0.85)
    tip:AddLine("Right-click: settings", 0.75, 0.78, 0.85)
    if drag then tip:AddLine("Drag: move around the minimap", 0.75, 0.78, 0.85) end
end
MM.tooltip = tooltip

-- The TOC's AddonCompartmentFunc*: globals, as the compartment finds them by name.
_G.Bugsy_OnAddonCompartmentClick = MM.Click
function _G.Bugsy_OnAddonCompartmentEnter(_, row)
    local tip = G("GameTooltip")
    if not tip then return end
    tip:SetOwner(row, "ANCHOR_LEFT")
    tooltip(tip, false)
    tip:Show()
end
function _G.Bugsy_OnAddonCompartmentLeave()
    local tip = G("GameTooltip")
    if tip then tip:Hide() end
end

local launcher = {
    type = "launcher",
    label = MM.NAME,
    icon = MM.ICON,
    OnClick = MM.Click,
    OnTooltipShow = function(tip) tooltip(tip, true) end,
}

-- Show or hide it to match the setting (Bugsy.SetSetting). LibDBIcon's own Show and
-- Hide never write the saved table; the setting already did.
function MM.Apply()
    if not registered then return end
    local icon = lib("LibDBIcon-1.0")
    local db = ns.Store.db()
    if not (icon and db) then return end
    if db.minimap.hide then pcall(icon.Hide, icon, MM.NAME) else pcall(icon.Show, icon, MM.NAME) end
end

local function register()
    if registered then return end
    local db = ns.Store.db()
    local ldb, icon = lib("LibDataBroker-1.1"), lib("LibDBIcon-1.0")
    if not (db and ldb and icon) then return end
    -- NewDataObject answers nil when the name is taken; Register would then error.
    local ok, obj = pcall(ldb.NewDataObject, ldb, MM.NAME, launcher)
    if not (ok and obj) then return end
    registered = pcall(icon.Register, icon, MM.NAME, obj, db.minimap) and true or false
end

local reg = G("CreateFrame")("Frame")
reg:RegisterEvent("PLAYER_LOGIN")
reg:SetScript("OnEvent", function() register() end)

ns._test = ns._test or {}
ns._test.Minimap = { launcher = launcher, registered = function() return registered end }
