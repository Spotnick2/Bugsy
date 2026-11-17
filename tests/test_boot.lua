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
check(f.details._text:find("attempt to index a nil value", 1, true), "the details show the error")
SlashCmdList.BUGSY("status")
check(chatHas("catching errors itself"), "status says native")
SlashCmdList.BUGSY("locals on")
eq(BugsyDB.settings.locals, true, "locals can be turned on")
SlashCmdList.BUGSY("report")
check(ns.ReportUI.frame():IsShown(), "/bugsy report opens the manual report")

done("test_boot")
