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
eq(obj.icon, "Interface\\Icons\\Spell_Nature_InsectSwarm", "the placeholder icon (the TOC's too)")
eq(WoW.ldbi.registered.Bugsy, BugsyDB.minimap, "LibDBIcon keeps BugsyDB.minimap itself")
local button = WoW.ldbi.buttons.Bugsy
check(button:IsShown(), "shown by default")

-- The TOC's icon in the addon list is the same placeholder.
local toc = io.open("!Bugsy.toc"):read("*a")
check(toc:find("## IconTexture: Interface\\Icons\\Spell_Nature_InsectSwarm", 1, true), "the TOC's IconTexture")
for _, f in ipairs({ "AddonCompartmentFunc: Bugsy_OnAddonCompartmentClick",
    "AddonCompartmentFuncOnEnter: Bugsy_OnAddonCompartmentEnter",
    "AddonCompartmentFuncOnLeave: Bugsy_OnAddonCompartmentLeave" }) do
    check(toc:find(f, 1, true), "the TOC names " .. f)
end
-- The libraries load after Capture.lua: its handler catches an error while they load.
local capAt, libAt = toc:find("Capture.lua", 1, true), toc:find("Libs\\LibStub", 1, true)
check(capAt and libAt and capAt < libAt, "the libraries load after Capture.lua")

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

-- No libraries: no button, nothing thrown, the slash command says so.
WoW.reset()
LibStub = nil
local ns3 = loadAddon()
eq(ns3.Minimap.Available(), false, "no libraries: no button")
WoW.lines = {}
ns3.Bugsy.Slash("minimap on")
check(chatHas("couldn't be made"), "/bugsy minimap on says there is none this session")
eq(BugsyDB.minimap.hide, false, "the choice is still saved")

-- The name taken by another addon: no button, nothing thrown.
WoW.reset()
WoW.ldb.objects.Bugsy = { type = "launcher" }
local ns4 = loadAddon()
eq(ns4.Minimap.Available(), false, "the name taken: no button")
eq(WoW.ldbi.registered.Bugsy, nil, "nothing registered with LibDBIcon")

-- Stack evidence (#13's R5): the embedded libraries are not Bugsy's own.
local Sig, Attr = ns4.Signature, ns4.Attribution
local own = "[Interface/AddOns/!Bugsy/UI.lua]:12: in function <Interface/AddOns/!Bugsy/UI.lua:10>"
local libLine = "[Interface/AddOns/!Bugsy/Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua]:88: in function <Interface/AddOns/!Bugsy/Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua:80>"
local other = "[Interface/AddOns/TestAddon/Core.lua]:10: in function <Interface/AddOns/TestAddon/Core.lua:5>"
check(Sig.isOwnFrame(own), "a Bugsy file is Bugsy's own")
check(not Sig.isOwnFrame(libLine), "a library in Bugsy's Libs/ is not")
local l1 = Sig.lines(own .. "\n" .. other)
eq(l1[1], other, "Bugsy's leading frames are still skipped (unchanged)")
local l2 = Sig.lines(libLine .. "\n" .. other)
eq(l2[1], libLine, "an embedded library's frame keeps its place")
eq(Sig.where(l2), "!Bugsy/Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua:88", "and is the problem's location")
eq(Sig.ALGO, "g1", "the algorithm stays g1 (the recorded exception)")
-- Existing groupings unchanged: a stack without Libs/ groups exactly as before.
local before = { Sig.compute("error", "boom", own .. "\n" .. other) }
local again = { Sig.compute("error", "boom", other) }
eq(before[2], again[2], "a Bugsy frame on top still doesn't change the grouping")

local a1 = Attr.attribute({ kind = "error", message = "x", stack = libLine })
eq(a1.suspect and a1.suspect.library, "LibDBIcon-1.0", "only library frames: the library is named")
eq(a1.suspect and a1.suspect.addon, "!Bugsy", "with its host, Bugsy")
eq(a1.suspect and a1.suspect.confidence, "low", "at low confidence")
local a2 = Attr.attribute({ kind = "error", message = "x", stack = libLine .. "\n" .. other })
eq(a2.suspect and a2.suspect.addon, "TestAddon", "an addon frame under the library is the suspect")
local a3 = Attr.attribute({ kind = "error", message = "x", stack = own })
eq(a3.suspect, nil, "Bugsy's own frames alone suspect nothing (unchanged)")

done("test_minimap")
