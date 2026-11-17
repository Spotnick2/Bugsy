-- The windows and notices (DESIGN §8), and every widget method they call checked
-- against the pinned build (Kit.checkMethods).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local ns = loadAddon()
local UI, ReportUI, Store = ns.UI, ns.ReportUI, ns.Store

-- Notices: one line for a new problem, held in combat, throttled.
WoW.combat = true
WoW.raise("an error in combat")
drain()
check(not chatHas("caught a new problem"), "no chat line during combat")
check(not (UI.frame() and UI.frame():IsShown()), "and no window opens")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
check(chatHas("caught a new problem"), "the notice comes after combat")

-- The alert sound: with the notice, the owner's FileDataID on Master, held in combat,
-- throttled with the notice, its own setting.
eq(#WoW.sounds, 1, "one sound with the notice, after combat (none during)")
eq(WoW.sounds[1] and WoW.sounds[1][1], 550736, "the chosen sound")
eq(WoW.sounds[1] and WoW.sounds[1][2], "Master", "on the Master channel")
WoW.raise("another new problem, within the throttle")
drain()
eq(#WoW.sounds, 1, "no second sound inside the 10 s throttle")
ns.Bugsy.Slash("sound off")
eq(BugsyDB.settings.sound, false, "the setting is saved")
WoW.sounds = {}
WoW.advance(11)
WoW.raise("a third new problem")
drain()
eq(#WoW.sounds, 0, "no sound when off")
ns.Bugsy.Slash("sound on")
eq(#WoW.sounds, 1, "turning it on plays it once, as a sample")
ns.Bugsy.Slash("notices off")
WoW.sounds, WoW.lines = {}, {}
WoW.advance(11)
WoW.raise("a fourth new problem")
drain()
eq(#WoW.sounds, 1, "the sound plays with chat notices off")
check(not chatHas("caught"), "and no chat line")
ns.Bugsy.Slash("notices on")

-- A known problem's first occurrence in a new session is announced again.
WoW.reset()
local saved
local ns1 = loadAddon()
WoW.raise("a recurring bug")
drain()
saved = BugsyDB
WoW.reset()
local ns2 = loadAddon({ db = saved })
WoW.lines = {}
WoW.raise("a recurring bug")
drain()
check(chatHas("caught a new problem"), "a problem coming back in a new session gets its notice")
WoW.lines = {}
WoW.now = (WoW.now or 0) + 30
WoW.raise("a recurring bug")
drain()
check(not chatHas("caught"), "but not again in the same session")

-- The main window: list, details with | escaped, mute, clear, filters.
UI, ReportUI, Store = ns2.UI, ns2.ReportUI, ns2.Store
WoW.raise("a | pipe |cffff0000not colour|r")
drain()
UI.Toggle()
local f = UI.frame()
check(f:IsShown(), "the window opens")
local pipeRow
for _, row in ipairs(f.rows) do
    if row:IsShown() and row.text:GetText():find("pipe", 1, true) then pipeRow = row end
end
check(pipeRow and pipeRow.text:GetText():find("||cffff0000", 1, true), "a | in a title is escaped for display")
pipeRow:GetScript("OnClick")(pipeRow)
check(f.details._text:find("||cffff0000", 1, true), "and in the details")
f.mute:GetScript("OnClick")(f.mute)
eq(Store.Get(UI.state.selected).muted, true, "Mute mutes, keeping the evidence")
eq(f.mute:GetText(), "Unmute", "and the button offers Unmute")
f.copy:GetScript("OnClick")(f.copy)
eq(f.hint:GetText(), "Press Ctrl+C to copy.", "copy guidance")
f.clearAll:GetScript("OnClick")(f.clearAll)
eq(f.clearAll:GetText(), "Sure?", "clear all asks first")
f.clearAll:GetScript("OnClick")(f.clearAll)
eq(#Store.List("all", true), 0, "then clears")
UI.state.filter = "session"
local filterBtn
for _, child in ipairs(f._children or {}) do if child._template == "UIPanelButtonTemplate" and child:GetText() == "This session" then filterBtn = child end end
if filterBtn then filterBtn:GetScript("OnClick")(filterBtn) end
eq(UI.state.filter, "previous", "the filter cycles")
f:GetScript("OnMouseWheel")(f, -1)
check(f.empty:IsShown(), "an empty list says so")
check(f.status:GetText():find("Bugsy is", 1, true), "the status line")

-- The report flow.
WoW.raise("report me")
drain()
UI.state.filter = "all"
UI.Refresh()
local p = Store.List("all", true)[1]
ReportUI.OpenFor(p.id)
local rf = ReportUI.frame()
check(rf:IsShown(), "Prepare report opens the flow")
rf.doing:SetText("Looting")
rf.noProblem:SetChecked(true)
rf.previewBtn:GetScript("OnClick")(rf.previewBtn)
check(rf.preview._text:find("Looting", 1, true), "the preview shows the answers")
check(rf.destination:GetText():find("example.org", 1, true) or rf.destination:GetText():find("doesn't know", 1, true),
    "a destination or the unknown-destination text")
rf.formatBtn:GetScript("OnClick")(rf.formatBtn)
check(rf.preview._text:find('"schema"', 1, true), "JSON on request")
rf.selectBtn:GetScript("OnClick")(rf.selectBtn)
check(rf.hint:GetText():find("Bugsy has not sent anything", 1, true), "copy guidance never says sent")
ReportUI.OpenManual("OtherAddon")
check(rf.subject:GetText():find("OtherAddon", 1, true), "Report a problem picks the addon")
rf.next:GetScript("OnClick")(rf.next)
rf.prev:GetScript("OnClick")(rf.prev)
rf.happened:SetText("The tab is empty")
rf.previewBtn:GetScript("OnClick")(rf.previewBtn)
check(rf.preview._text:find("The tab is empty", 1, true), "the manual report previews")

-- The compartment entry and the slash help.
Bugsy_OnAddonCompartmentClick()
SlashCmdList.BUGSY("help")
check(chatHas("/bugsy report"), "help lists the commands")
check(chatHas("/bugsy sound"), "including the sound setting")

local recorded = Kit.checkMethods({})
check(recorded >= 40, "the exercise reached the windows (" .. recorded .. " recorded)")
done("test_ui")
