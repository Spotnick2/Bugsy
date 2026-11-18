-- Minimap.lua: the minimap button and the addon compartment (#26). Left-click opens or
-- closes the window, right-click opens the settings.
--
-- Bugsy embeds no library (owner, #26): `!Bugsy` loads before every other addon, so an
-- embedded copy would become the copy the whole client runs (LibStub keeps the first of
-- equal versions), and other addons' library errors and taint would point at Bugsy. So,
-- at PLAYER_LOGIN (every startup addon loaded):
--   - LibDataBroker-1.1 and LibDBIcon-1.0 loaded by another addon: a launcher shown by
--     LibDBIcon (button collectors pick it up);
--   - otherwise Bugsy's own small button on the minimap's ring, the same look (the
--     client's border, background and highlight, by FileDataID) and the same saved
--     fields, so a later session with LibDBIcon keeps its place.
-- Its place and shown state are BugsyDB.minimap ({ hide, minimapPos }: LibDBIcon's own
-- table shape), made or repaired once in Store.adopt and never replaced (LibDBIcon keeps a
-- reference to it). Showing it is the "minimap" setting (Bugsy.SetSetting: /bugsy minimap,
-- the Options page). Nothing here runs on the capture path.

local ADDON, ns = ...
local G = ns.G
local MM = {}
ns.Minimap = MM

MM.NAME = "Bugsy"
MM.ICON = "Interface\\Icons\\Spell_Nature_InsectSwarm"   -- until Bugsy has its own logo (#26)
MM.DEFAULT_POS = 225                                     -- degrees, LibDBIcon's default
MM.RADIUS = 5                                            -- past the minimap's edge, LibDBIcon's
local kind                                               -- "libdbicon" | "own" | nil
local own                                                -- Bugsy's own button

local function lib(name)
    local stub = G("LibStub")
    if not stub then return nil end
    local ok, l = pcall(stub, name, true)
    return ok and type(l) == "table" and l or nil
end

-- Whether there is a button this session, and which.
function MM.Available() return kind ~= nil end
function MM.Kind() return kind end

-- One click, from the button or the compartment (each passes something first: the
-- button, or the addon's name; then the mouse button).
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
    if ns.Store.db() then
        local n = #ns.Store.List("session")
        tip:AddLine(n == 1 and "1 problem this session" or (n .. " problems this session"), 1, 1, 1)
    end
    tip:AddLine("Left-click: open or close the window", 0.75, 0.78, 0.85)
    tip:AddLine("Right-click: settings", 0.75, 0.78, 0.85)
    if drag then tip:AddLine("Drag: move around the minimap", 0.75, 0.78, 0.85) end
end
MM.tooltip = tooltip

local function showTip(owner, drag)
    local tip = G("GameTooltip")
    if not tip then return end
    tip:SetOwner(owner, "ANCHOR_LEFT")
    tooltip(tip, drag)
    tip:Show()
end
local function hideTip()
    local tip = G("GameTooltip")
    if tip then tip:Hide() end
end

-- The TOC's AddonCompartmentFunc*: globals, as the compartment finds them by name.
_G.Bugsy_OnAddonCompartmentClick = MM.Click
function _G.Bugsy_OnAddonCompartmentEnter(_, row) showTip(row, false) end
function _G.Bugsy_OnAddonCompartmentLeave() hideTip() end

------------------------------------------------------------
-- Bugsy's own button (no LibDBIcon loaded)
------------------------------------------------------------

-- On the ring at `deg` degrees (0 = right, counter-clockwise), as LibDBIcon places a
-- button on a round minimap.
function MM.Place(deg)
    local mm = G("Minimap")
    if not (own and mm) then return end
    local rad = math.rad(deg or MM.DEFAULT_POS)
    local w = (mm:GetWidth() or 140) / 2 + MM.RADIUS
    local h = (mm:GetHeight() or 140) / 2 + MM.RADIUS
    own:ClearAllPoints()
    own:SetPoint("CENTER", mm, "CENTER", math.cos(rad) * w, math.sin(rad) * h)
end

-- The angle of the cursor around the minimap's centre, in degrees (0..360).
function MM.CursorAngle()
    local mm = G("Minimap")
    local cursor = G("GetCursorPosition")
    if not (mm and cursor) then return nil end
    local mx, my = mm:GetCenter()
    local px, py = cursor()
    local scale = mm:GetEffectiveScale()
    if not (mx and my and px and py and scale and scale > 0) then return nil end
    return math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
end

local function dragUpdate()
    local deg = MM.CursorAngle()
    if not deg then return end
    local db = ns.Store.db()
    if db then db.minimap.minimapPos = deg end
    MM.Place(deg)
end

local function makeOwn(db)
    local mm = G("Minimap")
    if not mm then return false end
    local b = G("CreateFrame")("Button", "Bugsy_MinimapButton", mm)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture(136477)                       -- UI-Minimap-ZoomButton-Highlight
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(136467)                               -- UI-Minimap-Background
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(MM.ICON)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture(136430)                           -- MiniMap-TrackingBorder
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)
    b.icon, b.border, b.background = icon, border, bg
    b:SetScript("OnClick", function(self, mouse) MM.Click(self, mouse) end)
    b:SetScript("OnEnter", function(self) showTip(self, true) end)
    b:SetScript("OnLeave", hideTip)
    b:SetScript("OnDragStart", function(self)
        hideTip()
        self:SetScript("OnUpdate", dragUpdate)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    own = b
    MM.Place(db.minimap.minimapPos)
    if db.minimap.hide then b:Hide() end
    return true
end

------------------------------------------------------------
-- LibDBIcon (another addon loaded it)
------------------------------------------------------------

local launcher = {
    type = "launcher",
    label = MM.NAME,
    icon = MM.ICON,
    OnClick = MM.Click,
    OnTooltipShow = function(tip) tooltip(tip, true) end,
}

local function useLibDBIcon(db)
    local ldb, icon = lib("LibDataBroker-1.1"), lib("LibDBIcon-1.0")
    if not (ldb and icon) then return false end
    -- NewDataObject answers nil when the name is taken; Register would then error.
    local ok, obj = pcall(ldb.NewDataObject, ldb, MM.NAME, launcher)
    if not (ok and obj) then return false end
    return pcall(icon.Register, icon, MM.NAME, obj, db.minimap) and true or false
end

-- Show or hide it to match the setting (Bugsy.SetSetting). LibDBIcon's own Show and
-- Hide never write the saved table; the setting already did.
function MM.Apply()
    local db = ns.Store.db()
    if not db then return end
    if kind == "libdbicon" then
        local icon = lib("LibDBIcon-1.0")
        if icon then
            if db.minimap.hide then pcall(icon.Hide, icon, MM.NAME) else pcall(icon.Show, icon, MM.NAME) end
        end
    elseif kind == "own" then
        own:SetShown(not db.minimap.hide)
    end
end

local function register()
    if kind then return end
    local db = ns.Store.db()
    if not db then return end
    if useLibDBIcon(db) then kind = "libdbicon"
    elseif makeOwn(db) then kind = "own" end
end

local reg = G("CreateFrame")("Frame")
reg:RegisterEvent("PLAYER_LOGIN")
reg:SetScript("OnEvent", function() register() end)

ns._test = ns._test or {}
ns._test.Minimap = { launcher = launcher, own = function() return own end }
