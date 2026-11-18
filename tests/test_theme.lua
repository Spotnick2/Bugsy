-- The window's looks (#28; #13's design): WoW Forever and Pearl Glass over one layout,
-- LibGlass borrowed (never embedded), Glass UI's suite theme followed by default; a failed
-- glass build falls back to Forever and is reported; LibGlass is called only while a
-- window is built; a look change keeps the selection, the draft and the step.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function fire(btn) btn:GetScript("OnClick")(btn, "LeftButton") end
local function last() return WoW.suiteReports[#WoW.suiteReports].state end

-- No Glass addon loaded: Forever, Pearl offered but not available.
local ns = loadAddon()
local T, UI = ns.Theme, ns.UI
eq(T.Effective(), "forever", "no LibGlass: the Forever look")
eq(T.Choice(), "forever", "the own look by default")
eq(T.PearlAvailable(), false, "Pearl needs a loaded LibGlass")
eq(T.SetChoice("pearl"), false, "so choosing it is refused")
eq(BugsyDB.settings.look, nil, "and nothing saved")
eq(T.SetChoice("follow"), false, "no Glass UI: nothing to follow")
UI.Show()
local menu = UI.LookMenu(UI.frame().lookBtn)
eq(#menu.items, 2, "the look menu: WoW Forever and Pearl Glass (no Glass UI)")
eq(menu.items[2].disabled, true, "Pearl Glass greyed")
check(menu.items[2].note:find("Glass addon", 1, true), "saying it needs a Glass addon")
ns.Widgets.CloseMenu()
eq(WoW.glassCalls, 0, "LibGlass never called")

-- A LibGlass another addon brought (r12): Pearl on demand, the window rebuilt, its state kept.
WoW.reset()
WoW.newLibGlass(12)
ns = loadAddon()
T, UI = ns.Theme, ns.UI
WoW.raise("a problem to keep selected")
drain()
WoW.raise("another one")
drain()
UI.Show()
local id = ns.Store.List("session", true)[2].id
UI.state.selected = id
ns.ReportUI.OpenFor(id)
local d = UI.state.draft
ns.Model.SetDraft(d, "description", "kept across a look change")
ns.ReportUI.Go(2)
local before = UI.frame()
eq(T.PearlAvailable(), true, "a loaded LibGlass r12: Pearl available")
eq(T.SetChoice("pearl"), true, "Pearl chosen")
eq(BugsyDB.settings.look, "pearl", "saved")
eq(T.Effective(), "glass", "the glass look")
local after = UI.frame()
check(after ~= before, "the window was rebuilt")
check(not before:IsShown() and after:IsShown(), "in place of the old one, still open")
eq(BugsyFrame, after, "the published alias follows it")
eq(UI.state.view, "report", "the view kept")
eq(UI.state.draft, d, "the draft kept")
eq(d.step, 2, "the step kept")
check(ns.ReportUI.view().review.description.body:GetText():find("kept across a look change", 1, true), "the answers kept")
ns.ReportUI.Go(1)
eq(ns.ReportUI.view().describe.edit:GetText(), "kept across a look change", "and shown in the rebuilt field")
ns.ReportUI.Back()
eq(UI.state.selected, id, "the selection kept")
check(after.glass ~= nil, "the window wears the glass shell")
-- Pearl's scroll bars and the picker's arrow are glass, not the client's gold art (#31).
local rv = ns.ReportUI.view()
local bar = rv.describeScroll.ScrollBar
eq(bar.ScrollUpButton:GetAlpha(), 0, "Pearl: the scroll bar's arrows are invisible")
check(not bar.ScrollDownButton:IsMouseEnabled(), "and click-through (Blizzard shows them again on a range change)")
check(bar.ThumbTexture._color ~= nil and bar.glassTrack ~= nil, "a slim colour thumb on a track")
eq(rv.pickerArrow._file, "Interface\\Buttons\\SquareButtonTextures", "the picker's plain arrow")
-- After the build, states never call LibGlass (Fable's review: no library on refresh).
local calls = WoW.glassCalls
check(calls > 0, "LibGlass was used to build")
UI.Refresh()
local b = after.copyBtn
b:GetScript("OnEnter")(b); b:GetScript("OnMouseDown")(b); b:GetScript("OnMouseUp")(b); b:GetScript("OnLeave")(b)
fire(after.tabs.buttons[2]); fire(after.tabs.buttons[1])
eq(WoW.glassCalls, calls, "refreshing, hovering, pressing and selecting never call LibGlass")
-- A search survives a look change, shown in the rebuilt field (Codex, #30).
UI.state.query = "another"
UI.Refresh()
-- Back to Forever.
eq(T.SetChoice("forever"), true, "Forever chosen")
eq(UI.frame().search.edit:GetText(), "another", "the rebuilt search field shows the kept search")
check(not UI.frame().search.placeholder:IsShown(), "not its placeholder")
UI.state.query = ""
UI.frame().search:setValue("")
UI.Refresh()
eq(T.Effective(), "forever", "the Forever look")
local fv = ns.ReportUI.view()
eq(fv.describeScroll.ScrollBar.ScrollUpButton:GetAlpha(), 1, "Forever keeps the client's scroll bar")
eq(fv.describeScroll.ScrollBar.glassTrack, nil, "with no glass track")
eq(fv.pickerArrow._file, "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up", "and its gold arrow")
eq(UI.state.selected, id, "the selection kept again")

-- An older LibGlass (below r11): Pearl not available.
WoW.reset()
WoW.newLibGlass(10)
ns = loadAddon()
eq(ns.Theme.PearlAvailable(), false, "LibGlass r10: too old for Pearl")
BugsyDB.settings.look = "pearl"
ns.Theme.Decide()
eq(ns.Theme.Effective(), "forever", "a saved Pearl falls back to Forever")
check(select(2, ns.Theme.Describe()):find("too old", 1, true), "and says why")

-- A glass build that fails: recorded, the window built in Forever, usable.
WoW.reset()
WoW.newLibGlass(12)
WoW.glassFail = "Reflect"
ns = loadAddon({ db = { format = 1, settings = { look = "pearl" } } })
eq(ns.Theme.Effective(), "glass", "Pearl decided at login")
ns.UI.Show()
local f = ns.UI.frame()
check(f and f:IsShown(), "the window still opens")
eq(f.look, "forever", "built in the Forever look")
eq(ns.Theme.Effective(), "forever", "glass given up for the session")
eq(#ns.Theme.Failures(), 1, "the failure recorded")
check(ns.Theme.Failures()[1].text:find("Reflect failed", 1, true), "with its error text")
eq(ns.Theme.PearlAvailable(), false, "Pearl no longer offered this session")
fire(f.statusBtn)
check(f.statusPanel.text:GetText():find("Look failure", 1, true), "the status details show it")
WoW.glassFail = nil

-- Glass UI: followed by default; every time Bugsy asks, it reports.
WoW.reset()
WoW.newLibGlass(12)
WoW.newSuite()
ns = loadAddon()
T = ns.Theme
eq(WoW.suiteAsked, 1, "asked once at login")
eq(T.Choice(), "follow", "following Glass UI by default")
eq(T.Effective(), "glass", "its preset built")
eq(#WoW.suiteReports, 1, "reported")
local r = last()
eq(WoW.suiteReports[1].addon, "!Bugsy", "under the folder name")
eq(r.api, 1, "API 1")
eq(r.built, "pearl", "the followed preset")
eq(r.live, false, "not live: a suite change waits for /reload")
eq(type(r.options), "function", "an opener for Bugsy's settings")
eq(r.own.tint and r.own.accent, true, "tint and accent are Bugsy's own (named, not claimed)")
eq(r.declined, nil, "not declined")
-- Glass UI's switch off for Bugsy: nil, "not-following" is normal, not a failure.
WoW.suiteAnswer = "not-following"
BugsyDB.settings.look = "pearl"
T.Decide()
eq(T.Effective(), "glass", "the own Pearl applies")
eq(T.Following(), false, "not following")
r = last()
eq(r.built, nil, "an own Pearl is not a followed build")
eq(r.reason, nil, "no failure reason")
eq(#WoW.suiteReports, 2, "still reported (Glass UI's card would otherwise say no report)")
-- Bugsy's own switch off: declined, with the own look's name.
WoW.suiteAnswer = { name = "pearl", preset = "pearl" }
eq(T.SetChoice("forever"), true, "the own Forever look chosen")
eq(BugsyDB.settings.followGlassUI, false, "follow off")
r = last()
eq(r.declined, "WoW Forever", "reported as declined, by name")
eq(r.built, nil, "nothing followed")
eq(T.SetChoice("follow"), true, "following again")
eq(last().built, "pearl", "the preset again")
-- The suite's preset can't be built (no LibGlass loaded): Forever, with the reason.
WoW.reset()
WoW.newSuite()
ns = loadAddon()
T = ns.Theme
eq(T.Effective(), "forever", "no LibGlass: Forever")
eq(last().reason, "absent", "reported with its reason")
eq(last().built, nil, "nothing built")
-- A late failure while following re-reports.
WoW.reset()
WoW.newLibGlass(12)
WoW.newSuite()
ns = loadAddon()
T = ns.Theme
eq(last().built, "pearl", "following at login")
WoW.glassFail = "Apply"
ns.UI.Show()
eq(ns.UI.frame().look, "forever", "a failing Apply: the window in Forever")
r = last()
eq(r.built, nil, "Glass UI told it wasn't built after all")
eq(r.reason, "build-failed", "and why")
WoW.glassFail = nil

-- Junk look settings read as the defaults.
WoW.reset()
ns = loadAddon({ db = { format = 1, settings = { look = "neon", followGlassUI = "maybe" },
    window = { left = "x", top = 10, w = 0 / 0 } } })
eq(BugsyDB.settings.look, nil, "an unknown look dropped")
eq(BugsyDB.settings.followGlassUI, nil, "a junk follow switch dropped")
eq(BugsyDB.window.left, nil, "a junk window place dropped")
eq(BugsyDB.window.top, 10, "a good one kept")
eq(BugsyDB.window.w, nil, "NaN dropped")

-- /bugsy look.
WoW.lines = {}
ns.Bugsy.Slash("look pearl")
check(chatHas("needs a Glass addon"), "/bugsy look pearl explains why not")
ns.Bugsy.Slash("look")
check(chatHas("the window's look is WoW Forever"), "/bugsy look names the look")

done("test_theme")
