-- Boot: the handler is installed at load, the saved table is adopted, an error
-- becomes a problem, the slash command and the window work.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local ns = loadAddon()
eq(WoW.handler, ns.Capture.handler, "our handler is installed")
eq(ns.Capture.state.mode, "native", "native mode without a collector")
eq(type(BugsyDB), "table", "the saved table exists")
eq(BugsyDB.session, 1, "first session")
check(BugsyDB.sourceId:match("^%x+$") and #BugsyDB.sourceId == 16, "a 16-hex source id")

WoW.stack = stackAt("TestAddon", "Core.lua", 42)
WoW.raise("Interface/AddOns/TestAddon/Core.lua:42: attempt to index a nil value")
eq(#problems(ns), 0, "nothing is stored inside the handler")
drain()
local list = problems(ns)
eq(#list, 1, "the drain made one problem")
local p = list[1]
eq(p.count, 1, "counted once")
eq(p.kind, "error", "an error")
eq(p.attribution.suspect.addon, "TestAddon", "TestAddon appears involved")
eq(p.addons[1].name, "TestAddon", "its addon is recorded")
check(p.addons[1].versions["1.2.3"] == 1, "with its version")
eq(p.first[1].stackOrigin, "error", "the stack came from the error level")
eq(WoW.stackCalls[1].level, WoW.callHeight - (WoW.errorHeight - 1), "Blizzard's stack formula")
eq(p.first[1].locals.unavailable, true, "locals are off by default")

-- The quiet notice
check(chatHas("caught a new problem"), "one chat line for the new problem")

-- Slash and window
SlashCmdList.BUGSY("")
local f = ns.UI.frame()
check(f and f:IsShown(), "/bugsy opens the window")
check(f.detail.tech.edit._text:find("attempt to index a nil value", 1, true), "the details show the error")
SlashCmdList.BUGSY("status")
check(chatHas("catching errors itself"), "status says native")
SlashCmdList.BUGSY("locals on")
eq(BugsyDB.settings.locals, true, "locals can be turned on")
SlashCmdList.BUGSY("report")
check(ns.ReportUI.frame():IsShown() and ns.UI.state.view == "report", "/bugsy report opens the manual report, in the window")
eq(ns.UI.state.draft.addon, nil, "with no addon chosen for the player")

-- The release gate's persistence check reads these through Diagnostics (#33).
WoW.reset()
local gns = loadAddon()
WoW.raise("Interface/AddOns/TestAddon/Core.lua:7: gate kept")
WoW.raise("Interface/AddOns/TestAddon/Core.lua:8: gate muted")
drain()
local gd = gns.Bugsy.Diagnostics("gate muted")
eq(gd.session, BugsyDB.session, "Diagnostics: the session")
eq(gd.muted, nil, "not muted yet")
for _, q in ipairs(problems(gns)) do if q.title:find("gate muted", 1, true) then gns.Store.SetMuted(q.id, true) end end
eq(gns.Bugsy.Diagnostics("gate muted").muted, true, "Diagnostics: muted")
eq(gns.Bugsy.Diagnostics("gate kept").inPrevious, nil, "not in the previous session yet")
local gsaved = BugsyDB
WoW.reset()
gns = loadAddon({ db = gsaved })
eq(gns.Bugsy.Diagnostics("gate kept").inPrevious, true, "Diagnostics: in the previous session's list")
eq(gns.Bugsy.Diagnostics("gate muted").muted, true, "still muted")

-- B-18 (#33): Blizzard's displays of what Bugsy records are hidden at load; Bugsy keeps them.
WoW.reset()
loadAddon()
eq(BugsyDB.settings.hidePopups, true, "hiding Blizzard's popups is on by default")
eq(WoW.routed.ADDON_ACTION_FORBIDDEN, nil, "the blocked-action popup's route is unregistered")
eq(WoW.routed.ADDON_ACTION_BLOCKED, nil, "and the 'Interface action failed' message's")
eq(WoW.routed.TRADE_REQUEST, true, "nothing else of the router's")
check(not ScriptErrorsFrame:IsEventRegistered("LUA_WARNING"), "the Lua warning window no longer gets warnings")
drain()
SlashCmdList.BUGSY("status")
check(chatHas("are hidden; Bugsy records them"), "/bugsy status says they're hidden")
check(chatHas("GameEvent:ADDON_ACTION_FORBIDDEN") and chatHas("ScriptErrorsFrame:LUA_WARNING"), "and what was unregistered")
SlashCmdList.BUGSY("popups show")
eq(BugsyDB.settings.hidePopups, false, "/bugsy popups show turns it off")
check(chatHas("shown from the next session"), "from the next session")
-- Off: the next session leaves Blizzard's displays alone.
local saved = BugsyDB
WoW.reset()
loadAddon({ db = saved })
eq(WoW.routed.ADDON_ACTION_FORBIDDEN, true, "off: Blizzard's popup is left")
check(ScriptErrorsFrame:IsEventRegistered("LUA_WARNING"), "and its warning window")
SlashCmdList.BUGSY("popups hide")
eq(BugsyDB.settings.hidePopups, true, "/bugsy popups hide turns it back on")
-- No router (another client): nothing breaks, and status says it couldn't.
saved = BugsyDB
WoW.reset()
GameEvent = nil
loadAddon({ db = saved })
eq(saved.settings.hidePopups, true, "still on")
SlashCmdList.BUGSY("status")
check(chatHas("ScriptErrorsFrame:LUA_WARNING") and not chatHas("GameEvent:"), "without the router, only the warning window is hidden")

done("test_boot")
