-- The minimap button and the addon compartment (#26): registration on the fakes, both
-- clicks, the tooltips, the setting (/bugsy minimap, the Options page), a button saved
-- hidden, a damaged table, no libraries, a name already taken. And the embedded
-- libraries' stack evidence (#13's R5): a !Bugsy/Libs/ frame keeps its location and its
-- library identity; Bugsy's own frames are skipped as before.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local ns = loadAddon()
local MM = ns.Minimap

-- Registered at PLAYER_LOGIN, on LibDBIcon's own saved table.
check(MM.Available(), "the button is made at login")
local obj = WoW.ldb.objects.Bugsy
check(obj ~= nil, "a LibDataBroker launcher named Bugsy")
eq(obj.type, "launcher", "of type launcher")
eq(obj.icon, "Interface\\AddOns\\!Bugsy\\Media\\Icon", "the hat icon (the TOC's too)")
eq(WoW.ldbi.registered.Bugsy, BugsyDB.minimap, "LibDBIcon keeps BugsyDB.minimap itself")
local button = WoW.ldbi.buttons.Bugsy
check(button:IsShown(), "shown by default")

-- The TOC's icon in the addon list is the same placeholder.
local toc = io.open("!Bugsy.toc"):read("*a")
check(toc:find("## IconTexture: Interface\\AddOns\\!Bugsy\\Media\\Icon", 1, true), "the TOC's IconTexture")
for _, f in ipairs({ "AddonCompartmentFunc: Bugsy_OnAddonCompartmentClick",
    "AddonCompartmentFuncOnEnter: Bugsy_OnAddonCompartmentEnter",
    "AddonCompartmentFuncOnLeave: Bugsy_OnAddonCompartmentLeave" }) do
    check(toc:find(f, 1, true), "the TOC names " .. f)
end
-- No embedded library (#26): the TOC loads no Libs\ file; the button borrows them.
check(not toc:find("Libs\\", 1, true), "Bugsy embeds no library")
eq(MM.Kind(), "libdbicon", "with another addon's LibDBIcon: its launcher")

-- Clicks: left toggles the window, right opens the settings.
obj.OnClick(button, "LeftButton")
check(ns.UI.frame() and ns.UI.frame():IsShown(), "left-click opens the window")
obj.OnClick(button, "LeftButton")
check(not ns.UI.frame():IsShown(), "and closes it")
obj.OnClick(button, "RightButton")
eq(WoW.settings.opened, "cat:Bugsy", "right-click opens the Options page")

-- The tooltip: the session's problems and the clicks (dragging on the button only).
WoW.raise("a problem for the tooltip")
drain()
obj.OnTooltipShow(GameTooltip)
local lines = table.concat(GameTooltip._lines, "\n")
check(lines:find("^Bugsy"), "the tooltip names Bugsy")
check(lines:find("1 problem this session", 1, true), "this session's problems")
check(lines:find("Left-click: open or close the window", 1, true), "what left-click does")
check(lines:find("Right-click: settings", 1, true), "what right-click does")
check(lines:find("Drag", 1, true), "dragging, on the button")

-- The compartment: the same clicks and tooltip, no dragging.
WoW.settings.opened = nil
Bugsy_OnAddonCompartmentClick("!Bugsy", "RightButton")
eq(WoW.settings.opened, "cat:Bugsy", "the compartment's right-click opens the settings")
Bugsy_OnAddonCompartmentClick("!Bugsy", "LeftButton")
check(ns.UI.frame():IsShown(), "its left-click opens the window")
ns.UI.frame():Hide()
GameTooltip._lines = {}
Bugsy_OnAddonCompartmentEnter("!Bugsy", UIParent)
check(GameTooltip:IsShown(), "hovering shows the tooltip")
check(not table.concat(GameTooltip._lines, "\n"):find("Drag", 1, true), "without the drag line")
Bugsy_OnAddonCompartmentLeave()
check(not GameTooltip:IsShown(), "leaving hides it")

-- The setting: /bugsy minimap and the Options page, saved in LibDBIcon's table.
ns.Bugsy.Slash("minimap off")
eq(BugsyDB.minimap.hide, true, "/bugsy minimap off saves hide")
check(not button:IsShown(), "and hides the button")
check(chatHas("the minimap button is hidden"), "and says so")
local page = ns._test.Options.page
page:Show()
eq(page.controls.minimap.check:GetChecked(), false, "the page shows it hidden")
page.controls.minimap.check:SetChecked(true)
page.controls.minimap.check:GetScript("OnClick")(page.controls.minimap.check)
eq(BugsyDB.minimap.hide, false, "the page shows it again")
check(button:IsShown(), "the button is back")
page:Hide()

local recorded = Kit.checkMethods({})
check(recorded >= 10, "widget methods checked (" .. recorded .. " recorded)")

-- Saved hidden: stays hidden after a reload; a damaged table is repaired, never kept.
WoW.reset()
local ns2 = loadAddon({ db = { format = 1, minimap = { hide = true, minimapPos = 200 } } })
check(not WoW.ldbi.buttons.Bugsy:IsShown(), "a button saved hidden stays hidden")
eq(BugsyDB.minimap.minimapPos, 200, "its place kept")
eq(ns2.Bugsy.Get("minimap"), false, "the setting reads hidden")
WoW.reset()
loadAddon({ db = { format = 1, minimap = "junk" } })
eq(type(BugsyDB.minimap), "table", "a damaged table is replaced")
WoW.reset()
loadAddon({ db = { format = 1, minimap = { hide = "yes", minimapPos = "far" } } })
eq(BugsyDB.minimap.hide, nil, "a junk hide dropped")
eq(BugsyDB.minimap.minimapPos, nil, "a junk place dropped")
check(WoW.ldbi.buttons.Bugsy:IsShown(), "shown, the default")

-- No addon brought LibDBIcon: Bugsy's own button on the minimap's ring.
WoW.reset()
LibStub = nil
local ns3 = loadAddon()
eq(ns3.Minimap.Kind(), "own", "no LibDBIcon: Bugsy's own button")
local own = ns3._test.Minimap.own()
check(own ~= nil, "made at login")
eq(own:GetParent(), Minimap, "on the minimap")
check(own:IsShown(), "shown by default")
eq(own.icon._file, "Interface\\AddOns\\!Bugsy\\Media\\Icon", "the same icon")
eq(own.border._file, 136430, "the client's tracking border, as other minimap buttons")
local p = own._points[1]
eq(p[1], "CENTER", "placed by its centre")
eq(p[2], Minimap, "on the minimap's centre")
check(math.abs(p[4] - math.cos(math.rad(225)) * 75) < 0.01 and math.abs(p[5] - math.sin(math.rad(225)) * 75) < 0.01,
    "at LibDBIcon's default 225 degrees, just past the edge")

-- Its clicks and tooltip.
own:GetScript("OnClick")(own, "LeftButton")
check(ns3.UI.frame() and ns3.UI.frame():IsShown(), "left-click opens the window")
ns3.UI.frame():Hide()
own:GetScript("OnClick")(own, "RightButton")
eq(WoW.settings.opened, "cat:Bugsy", "right-click opens the settings")
GameTooltip._lines = {}
own:GetScript("OnEnter")(own)
check(table.concat(GameTooltip._lines, "\n"):find("Drag", 1, true), "its tooltip says it can be dragged")
own:GetScript("OnLeave")(own)

-- Dragging: around the ring, following the cursor, saved in minimapPos.
own:GetScript("OnDragStart")(own)
WoW.cursorX, WoW.cursorY = 1000, 700          -- straight above the centre (1000, 600)
own:GetScript("OnUpdate")(own, 0.02)
check(math.abs(BugsyDB.minimap.minimapPos - 90) < 0.01, "dragged to the top: 90 degrees")
p = own._points[1]
check(math.abs(p[4]) < 0.01 and math.abs(p[5] - 75) < 0.01, "and drawn there")
WoW.minimapScale = 2                           -- a scaled minimap: cursor pixels / scale
WoW.cursorX, WoW.cursorY = 1800, 1200          -- (900, 600) in its units: straight left
own:GetScript("OnUpdate")(own, 0.02)
check(math.abs(BugsyDB.minimap.minimapPos - 180) < 0.01, "the minimap's scale is taken into account")
own:GetScript("OnDragStop")(own)
eq(own:GetScript("OnUpdate"), nil, "dropping it stops following the cursor")

-- The setting hides and shows it.
ns3.Bugsy.Slash("minimap off")
check(not own:IsShown(), "/bugsy minimap off hides it")
ns3.Bugsy.Slash("minimap on")
check(own:IsShown(), "and on shows it")

-- Saved hidden, at a place: a reload keeps both.
WoW.reset()
LibStub = nil
local ns5 = loadAddon({ db = { format = 1, minimap = { hide = true, minimapPos = 0 } } })
local own5 = ns5._test.Minimap.own()
check(not own5:IsShown(), "a button saved hidden stays hidden")
check(math.abs(own5._points[1][4] - 75) < 0.01 and math.abs(own5._points[1][5]) < 0.01, "at its saved place")

-- The name taken in LibDataBroker by another addon: Bugsy's own button instead.
WoW.reset()
WoW.ldb.objects.Bugsy = { type = "launcher" }
local ns4 = loadAddon()
eq(ns4.Minimap.Kind(), "own", "the name taken: Bugsy's own button")
eq(WoW.ldbi.registered.Bugsy, nil, "nothing registered with LibDBIcon")

-- No minimap at all: no button, nothing thrown, the slash command says so.
WoW.reset()
LibStub = nil
Minimap = nil
local ns6 = loadAddon()
eq(ns6.Minimap.Available(), false, "no minimap: no button")
WoW.lines = {}
ns6.Bugsy.Slash("minimap on")
check(chatHas("couldn't be made"), "/bugsy minimap on says there is none this session")

done("test_minimap")
