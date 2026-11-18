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
eq(WoW.sounds[1] and WoW.sounds[1][1], 597938, "the default sound (#19)")
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

-- A choice of sounds (#19): the owner's six, in order; a number picks one, saves its
-- FileDataID, turns the sound on and plays it as a sample.
local ids = {}
for i, s in ipairs(ns.Bugsy.SOUNDS) do ids[i] = s.id end
eq(table.concat(ids, ","), "597938,1859972,1859973,1859974,1859975,550736", "the six sounds, the default first")
ns.Bugsy.Slash("sound off")
WoW.sounds = {}
ns.Bugsy.Slash("sound 6")
eq(BugsyDB.settings.soundId, 550736, "the choice is saved as its FileDataID")
eq(BugsyDB.settings.sound, true, "choosing a sound turns it on")
eq(WoW.sounds[1] and WoW.sounds[1][1], 550736, "and plays it")
check(chatHas("is 6. Hotrod horn"), "and names it")
WoW.sounds = {}
WoW.advance(11)
WoW.raise("a fifth new problem")
drain()
eq(WoW.sounds[1] and WoW.sounds[1][1], 550736, "the alert uses the choice")
WoW.sounds = {}
ns.Bugsy.Slash("sound 7")
ns.Bugsy.Slash("sound 0")
ns.Bugsy.Slash("sound loud")
eq(#WoW.sounds, 0, "an unknown choice plays nothing")
eq(BugsyDB.settings.soundId, 550736, "and changes nothing")
check(chatHas("a number from 1 to 6"), "it says what is accepted")
WoW.lines = {}
ns.Bugsy.Slash("sound")
check(chatHas("1. Goblin klaxon"), "/bugsy sound lists the sounds by name")
check(chatHas("5. Metal pops 4"), "all of them")
check(chatHas("6%. Hotrod horn %(current%)"), "and marks the current one")
check(not chatHas("Goblin klaxon %(current%)"), "only that one")
eq(#WoW.sounds, 0, "without playing it")
BugsyDB.settings.soundId = 12345           -- a saved id no longer in the list
ns.Bugsy.Slash("sound on")
eq(WoW.sounds[1] and WoW.sounds[1][1], 597938, "an unknown saved sound falls back to the default")
ns.Bugsy.Slash("sound 1")

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

-- The window (#28): which addon, at a glance; the selected problem; search, tabs, muted;
-- empty states that never imply healthy monitoring when it isn't; Manage.
UI, ReportUI, Store = ns2.UI, ns2.ReportUI, ns2.Store
local M = ns2.Model
local function fire(btn) btn:GetScript("OnClick")(btn, "LeftButton") end
local function typeIn(field, text)
    field.edit:SetText(text)
    field.edit:GetScript("OnTextChanged")(field.edit, true)
end
local function visibleRows(f)
    local out = {}
    for _, row in ipairs(f.rows) do if row:IsShown() then out[#out + 1] = row end end
    return out
end

WoW.raise("a | pipe |cffff0000not colour|r")
drain()
UI.Toggle()
local f = UI.frame()
check(f:IsShown(), "the window opens")
eq(BugsyFrame, f, "published as BugsyFrame")
eq(UISpecialFrames[#UISpecialFrames], "BugsyFrame", "and Escape closes it, as Blizzard's panels")
eq(UI.state.view, "problems", "on the problems")
local rows = visibleRows(f)
eq(#rows, 2, "this session's two problems listed")
check(rows[1].addon:GetText():find("Test Addon", 1, true), "each row leads with the addon's own title")
local pipeRow
for _, row in ipairs(rows) do if row.summary:GetText():find("pipe", 1, true) then pipeRow = row end end
check(pipeRow and pipeRow.summary:GetText():find("||cffff0000", 1, true), "a | in a title is escaped for display")
check(pipeRow.badge.text:GetText() == "1", "a count badge")
check(pipeRow.time:GetText() ~= "", "a relative last-seen time")
fire(pipeRow)
eq(UI.state.selected, pipeRow.id, "a click selects it")
local d = f.detail
eq(d.involvedLabel:GetText(), "APPEARS INVOLVED", "the attribution's heading keeps its uncertainty")
eq(d.addon:GetText(), "Test Addon", "the addon involved")
eq(d.confidence.text:GetText(), "Cause unconfirmed", "never more certain than the evidence")
check(d.title:GetText():find("||cffff0000", 1, true), "the title escaped")
check(d.tech.edit._text:find("||cffff0000", 1, true), "and the technical details")
check(not d.sections.activity:IsShown(), "no breadcrumbs: no Recent activity (nothing invented)")
check(d.sections.tech:IsShown() and d.sections.occurrences:IsShown(), "Technical details and Occurrences sections")
check(not d.note:IsShown(), "an up-to-date addon: no out-of-date note")

-- Copy details: the technical details opened and selected for Ctrl+C.
UI.CopyDetails()
check(d.sections.tech.open, "Copy details opens the technical details")
check(d.tech.edit._highlighted, "selected")
check(d.copyHint:GetText():find("Ctrl+C", 1, true), "with the Ctrl+C hint")

-- Mute: kept, hidden by default, and the selection moves off it.
local pipeId = pipeRow.id           -- rows are reused after a refresh: keep the id
fire(f.muteBtn)
eq(Store.Get(pipeId).muted, true, "Mute mutes, keeping the evidence")
check(UI.state.selected ~= pipeId, "a hidden muted problem never stays selected")
eq(#visibleRows(f), 1, "muted problems are hidden")
check(f.mutedBtn:IsShown() and f.mutedBtn.label:GetText():find("1", 1, true), "Show muted (1), a secondary control")
fire(f.mutedBtn)
eq(#visibleRows(f), 2, "Show muted lists it again")
fire(f.mutedBtn)

-- Search: by addon, title or the error's text; the selection follows what's visible.
local other = UI.state.selected
typeIn(f.search, "nothing matches this")
eq(#visibleRows(f), 0, "no result")
eq(UI.state.selected, nil, "and nothing selected")
eq(UI.state.emptyKind, "noResults", "the no-results state")
check(f.empty:IsShown() and not f.actions:IsShown(), "the empty state replaces the detail and its actions")
eq(f.empty.title:GetText(), "No problems match your search", "says so")
fire(f.empty.action)
eq(UI.state.query, "", "Clear search")
eq(UI.state.selected, other, "the first visible problem selected again")
typeIn(f.search, "core.lua")
eq(#visibleRows(f), 1, "the error's text is searchable (the stack's file)")
typeIn(f.search, "test addon")
eq(#visibleRows(f), 1, "and the addon's title")
typeIn(f.search, "")

-- Only muted problems.
for _, p in ipairs(Store.List("session", true)) do Store.SetMuted(p.id, true) end
UI.Refresh()
eq(UI.state.emptyKind, "onlyMuted", "only muted problems: its own empty state")
fire(f.empty.action)
eq(UI.state.showMuted, true, "which offers to show them")
for _, p in ipairs(Store.List("all", true)) do Store.SetMuted(p.id, false) end
UI.state.showMuted = false

-- History: previous or all sessions.
fire(f.tabs.buttons[2])
eq(UI.state.tab, "history", "the History tab")
check(f.scopeBtn:IsShown(), "with its scope")
fire(f.scopeBtn)
eq(UI.state.scope, "previous", "previous session")
fire(f.scopeBtn)
fire(f.tabs.buttons[1])

-- Manage: clearing everything asks first.
local menu = UI.ManageMenu(f.manage)
local clearAll
for _, it in ipairs(menu.items) do if it and it.text == "Clear all problems..." then clearAll = it end end
clearAll.onClick()
check(f.confirm:IsShown(), "Clear all asks first")
eq(#Store.List("all", true) > 0, true, "nothing cleared yet")
fire(f.confirm.no)
check(not f.confirm:IsShown(), "Cancel keeps everything")
clearAll.onClick()
fire(f.confirm.yes)
eq(#Store.List("all", true), 0, "then clears")

-- The empty state: deliberate, and honest about monitoring.
eq(UI.state.emptyKind, "none", "no problems: the empty state")
eq(f.empty.title:GetText(), "No problems detected this session", "says so")
eq(f.empty.line:GetText(), "Bugsy's keeping watch.", "with a friendly line")
eq(f.empty.question:GetText(), "Something still isn't working?", "and the way to report anyway")
eq(f.statusText:GetText(), "Monitoring active", "the footer: monitoring active")
ns2.Capture.state.mode = "displaced"
UI.Refresh()
eq(UI.state.emptyKind, "interrupted", "an empty list never implies healthy monitoring")
check(f.empty.title:GetText():find("may not be catching", 1, true), "it says Bugsy may not be catching errors")
check(f.statusText:GetText():find("interrupted", 1, true), "and so does the footer")
fire(f.statusBtn)
check(f.statusPanel:IsShown(), "the details (capture mode, limits) behind the status")
fire(f.statusBtn)
ns2.Capture.state.mode = "native"

-- After a patch day: an out-of-date addon is marked, and a suggestion (never an action).
WoW.interfaces.TestAddon = 11507
WoW.raise("old addon error")
drain()
UI.Refresh()
rows = visibleRows(f)
check(rows[1].addon:GetText():find("out of date", 1, true), "the row says out of date")
eq(d.stale.text:GetText(), "Out of date", "the detail marks it")
check(d.note:IsShown() and d.note:GetText():find("turn it off in the AddOns list", 1, true), "and suggests turning it off until it's updated")
eq(#WoW.disabledAddOns, 0, "Bugsy never disables an addon itself")
WoW.interfaces.TestAddon = nil

-- One click to copy: straight to Copy & report.
local pid = UI.state.selected
fire(f.copyBtn)
eq(UI.state.view, "report", "Copy for a bug report opens the flow in the window")
local dr = UI.state.draft
eq(dr.step, 3, "at Copy & report")
local v = ReportUI.view()
check(v.pages[3]:IsShown() and not v.pages[1]:IsShown(), "that step's page")
check(v.copyText.edit._text:find("## Bugsy report", 1, true), "the Markdown report, for a GitHub issue")
check(v.destBox:IsShown() and v.destBox.edit:GetText() == "https://example.org/testaddon", "the addon's own page, from its TOC")
fire(v.formats.buttons[2])
check(v.copyText.edit._text:find("Bug report from Bugsy", 1, true), "the short version, for a CurseForge comment")
check(not v.copyText.edit._text:find("## ", 1, true), "plain text, no Markdown headings")
fire(v.formats.buttons[3])
check(v.copyText.edit._text:find('"schema"', 1, true), "JSON as the advanced format")
fire(v.right)
check(v.copyText.edit._highlighted, "Select all selects it")
check(v.copyHint:GetText():find("Ctrl+C", 1, true), "and says to press Ctrl+C")
for _, s in ipairs({ v.copyHint:GetText(), ReportUI.TEXT.copyHint, ReportUI.TEXT.selected }) do
    check(not s:lower():find("copied", 1, true) and not s:lower():find("submitted", 1, true), "never claims it was copied or sent: " .. s)
end
fire(v.left)
eq(UI.state.view, "problems", "< Problems goes back")

-- The guided flow from a captured problem: the suspect preselected, uncertainty kept.
ReportUI.OpenFor(pid)
dr = UI.state.draft
eq(dr.step, 1, "Prepare report starts at Describe")
eq(dr.addon, "TestAddon", "the addon Bugsy points at is preselected")
check(v.guess:GetText():find("cause unconfirmed", 1, true), "saying it's Bugsy's reading")
check(v.noVisible:IsShown(), "'I didn't notice a visible problem' for a captured error")
-- Tab through the three answers, Shift+Tab back, around (#24).
local function tab(field) field.edit:GetScript("OnTabPressed")(field.edit) end
for _, fl in ipairs({ v.describe, v.expected, v.steps }) do fl.edit:ClearFocus() end
v.more:setOpen(true)
tab(v.describe)
eq(v.expected.edit._focus, true, "Tab: the next answer")
v.expected.edit:ClearFocus()
WoW.shift = true
tab(v.describe)
eq(v.steps.edit._focus, true, "Shift+Tab: around to the last")
v.steps.edit:ClearFocus()
WoW.shift = false
typeIn(v.describe, "I opened the bags")
typeIn(v.expected, "The bags open")
eq(dr.description, "I opened the bags", "answers are kept in the draft")
fire(v.right)
eq(dr.step, 2, "Review report")
check(v.review.description.body:GetText():find("I opened the bags", 1, true), "the review shows the answers")
check(v.reviewText.edit._text:find("Description: I opened the bags", 1, true), "and the full report has them")
fire(v.left)
eq(dr.step, 1, "Back")
eq(v.describe.edit:GetText(), "I opened the bags", "the answers survive Back")
fire(v.right); fire(v.right)
eq(dr.step, 3, "Next twice: Copy & report")
check(v.copyText.edit._text:find("I opened the bags", 1, true), "the copy has the answers")
-- A change after the copy was shown: the copy can never be stale.
local shown = v.copyText.version
M.SetDraft(dr, "description", "I opened the bank")
check(v.copyText.version ~= dr.version, "the shown copy is now out of date")
ReportUI.SelectAll()
check(v.copyText.edit._text:find("I opened the bank", 1, true) and not v.copyText.edit._text:find("I opened the bags", 1, true),
    "Select all re-renders before selecting: never the stale text")
check(v.copyText.version ~= shown, "a new render")
-- Correcting the addon changes where to report.
M.SetDraft(dr, "addon", "OtherAddon")
UI.Refresh()
check(not v.destBox:IsShown(), "OtherAddon has no website: the unknown-destination text")
check(v.dest:GetText():find("doesn't know", 1, true), "explains where to look")
fire(v.done)
eq(UI.state.view, "problems", "Done goes back to the problems")
eq(UI.state.draft, nil, "and the draft is dropped")

-- A manual report: the player chooses; nothing is picked for them.
ReportUI.OpenManual()
dr = UI.state.draft
eq(dr.addon, nil, "no addon chosen for the player")
eq(v.picker.label:GetText(), "Choose an addon...", "the picker says to choose")
eq(v.right:IsEnabled(), false, "Review report waits for a choice")
check(not v.noVisible:IsShown(), "no 'visible problem' box for a manual report")
fire(v.picker)
check(v.pickerPanel:IsShown(), "the searchable picker opens")
typeIn(v.pickerSearch, "other")
eq(#v.pickerChoices, 1, "search narrows it")
eq(v.pickerChoices[1].name, "OtherAddon", "by name or title")
fire(v.pickerRows[1])
eq(dr.addon, "OtherAddon", "chosen explicitly")
check(not v.pickerPanel:IsShown(), "the picker closes")
eq(v.right:IsEnabled(), true, "Review report can go on")
typeIn(v.describe, "The tab is empty")
fire(v.right); fire(v.right)
check(v.copyText.edit._text:find("The tab is empty", 1, true), "the manual report has the answer")
ReportUI.Back()

-- The compartment entry and the slash help.
Bugsy_OnAddonCompartmentClick()
SlashCmdList.BUGSY("help")
check(chatHas("/bugsy report"), "help lists the commands")
check(chatHas("/bugsy sound"), "including the sound setting")
check(chatHas("/bugsy look"), "and the look")

local recorded = Kit.checkMethods({})
check(recorded >= 60, "the exercise reached the window (" .. recorded .. " recorded)")
done("test_ui")
