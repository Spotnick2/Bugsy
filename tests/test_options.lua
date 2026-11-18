-- The Options > AddOns page and its About sub-page (#22): registration, the blank-first-
-- show rule, the controls going through the same functions as the slash command, values
-- re-read on every show, the template fallback, /bugsy options, no Settings framework.
-- Every widget method called is checked against the pinned build (Kit.checkMethods).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local ns = loadAddon()
local T = ns._test.Options
local page, about = T.page, T.about

-- Registered at PLAYER_LOGIN: the page in AddOns, its About right after, under it.
eq(#WoW.settings.canvas, 1, "one page registered")
eq(WoW.settings.canvas[1].frame, page, "the page")
eq(WoW.settings.canvas[1].name, "Bugsy", "named Bugsy")
eq(WoW.settings.addons[1], WoW.settings.canvas[1], "in Options > AddOns")
eq(#WoW.settings.subs, 1, "one sub-page")
eq(WoW.settings.subs[1].parent, WoW.settings.canvas[1], "under Bugsy's page")
eq(WoW.settings.subs[1].frame, about, "the About page")
eq(WoW.settings.subs[1].name, "About", "named About")
WoW.fire("PLAYER_LOGIN")
eq(#WoW.settings.canvas, 1, "a second login registers nothing more")

-- Hidden at creation, so the first show runs OnShow and builds it (a frame created
-- shown would stay blank the first time Settings displays it: measured).
check(not page:IsShown(), "the page is hidden until Settings shows it")
check(not about:IsShown(), "and so is About")
check(not page.built, "nothing built before the first show")

-- /bugsy options opens it.
SlashCmdList.BUGSY("options")
eq(WoW.settings.opened, "cat:Bugsy", "/bugsy options opens Bugsy's page")
page:Show()                                   -- what Settings does
check(page.built, "built on its first show")
local c = page.controls

-- Values shown as saved: the defaults.
eq(c.notices.check:GetChecked(), true, "chat line on")
eq(c.sound.check:GetChecked(), true, "sound on")
eq(c.locals.check:GetChecked(), false, "locals off")
eq(c.front.check:GetChecked(), true, "front on")
eq(#page.sounds, 6, "the six sounds")
eq(page.sounds[1]:GetChecked(), true, "the default sound marked")
for i = 2, 6 do eq(page.sounds[i]:GetChecked(), false, "only it (" .. i .. ")") end
eq(page.sounds[6].label:GetText(), "Hotrod horn", "each by name")
check(page.status:GetText():find("catching errors itself", 1, true), "the status: how Bugsy catches errors")

-- A click goes through Bugsy's setting functions.
WoW.sounds = {}
c.locals.check:SetChecked(true)
c.locals.check:GetScript("OnClick")(c.locals.check)
eq(BugsyDB.settings.locals, true, "locals turned on from the page")
c.notices.check:SetChecked(false)
c.notices.check:GetScript("OnClick")(c.notices.check)
eq(BugsyDB.settings.notices, false, "the chat line turned off")
c.sound.check:SetChecked(false)
c.sound.check:GetScript("OnClick")(c.sound.check)
eq(BugsyDB.settings.sound, false, "the sound turned off")
eq(#WoW.sounds, 0, "turning it off plays nothing")
page.sounds[3]:GetScript("OnClick")(page.sounds[3])
eq(BugsyDB.settings.soundId, 1859973, "a sound chosen on the page is saved by its FileDataID")
eq(BugsyDB.settings.sound, true, "and turns the sound on")
eq(WoW.sounds[1] and WoW.sounds[1][1], 1859973, "and plays it")
eq(c.sound.check:GetChecked(), true, "the page shows the sound on at once")
eq(page.sounds[3]:GetChecked(), true, "and the new choice marked")
eq(page.sounds[1]:GetChecked(), false, "the old one not")
c.front.check:SetChecked(false)
c.front.check:GetScript("OnClick")(c.front.check)
eq(BugsyDB.settings.front, false, "front turned off (from the next session)")
eq(ns.Capture.state.frontEnabled, true, "this session's choice stands")

-- A change from the slash command shows on the page (shown: at once; hidden: next show).
ns.Bugsy.Slash("locals off")
eq(c.locals.check:GetChecked(), false, "a slash change shows on the open page")
page:Hide()
ns.Bugsy.Slash("sound 5")
ns.Bugsy.Slash("notices on")
page:Show()
eq(page.sounds[5]:GetChecked(), true, "re-read on the next show: the sound")
eq(c.notices.check:GetChecked(), true, "and the chat line")

-- The shared setter refuses what it doesn't know.
eq(ns.Bugsy.SetSetting("nonsense", true), false, "an unknown setting refused")
eq(ns.Bugsy.SetSetting("locals", "yes"), false, "a non-boolean refused")
eq(ns.Bugsy.ChooseSound(9), false, "an unknown sound refused")
eq(BugsyDB.settings.nonsense, nil, "nothing saved")

-- The buttons close Settings first (Close(true): no Game Menu, porting guide), then open
-- the window.
SettingsPanel:Show()
page.open:GetScript("OnClick")(page.open)
eq(WoW.settings.closedWith, true, "Open Bugsy closes Settings with Close(true)")
check(ns.UI.frame() and ns.UI.frame():IsShown(), "and opens the window")
page.open:GetScript("OnClick")(page.open)
check(ns.UI.frame():IsShown(), "a second click leaves it open (never a toggle)")
ns.UI.frame():Hide()
SettingsPanel:Show()
WoW.settings.closedWith = nil
page.report:GetScript("OnClick")(page.report)
eq(WoW.settings.closedWith, true, "Report a problem closes Settings too")

-- About: version, how to use, the commands from /bugsy help's list.
about:Show()
check(about.built, "About built on its first show")
check(about.version:GetText():find("Version dev", 1, true), "an unpackaged copy says dev")
eq(#about.commands, #ns.Bugsy.HELP, "every command of /bugsy help")
eq(about.commands[1]:GetText(), ns.Bugsy.HELP[1], "the same text")
WoW.lines = {}
SlashCmdList.BUGSY("help")
check(chatHas("/bugsy options"), "help lists /bugsy options")

-- The version: a packaged copy shows its own (the token check never matches a real one).
WoW.addons[3].meta.Version = "0.1.0"
eq(ns.Context.version("!Bugsy"), "0.1.0", "a packaged version shows as itself")
WoW.addons[3].meta.Version = "@project-version@"
eq(ns.Context.version("!Bugsy"), "dev", "the packager's token shows as dev")

local recorded = Kit.checkMethods({})
check(recorded >= 20, "the exercise reached the pages (" .. recorded .. " recorded)")

-- Without the Settings framework: nothing registered, nothing thrown, /bugsy options
-- says where the settings would be.
WoW.reset()
Settings = nil
local ns2 = loadAddon()
eq(ns2._test.Options.category(), nil, "no Settings: no page registered")
WoW.lines = {}
ns2.Bugsy.Slash("options")
check(chatHas("Options > AddOns > Bugsy"), "/bugsy options says where they are")

-- A missing template: the client's own art instead (a missing template returns a bare frame).
WoW.reset()
WoW.templates.UICheckButtonTemplate = function() end
WoW.templates.UIRadioButtonTemplate = function() end
local ns3 = loadAddon()
local p3 = ns3._test.Options.page
p3:Show()
check(p3.built, "the page builds without the templates")
eq(p3.controls.notices.check:GetNormalTexture() ~= nil, true, "a check button from the client's art")
eq(p3.sounds[1]:GetNormalTexture() ~= nil, true, "and a radio button")
eq(p3.controls.notices.check:GetChecked(), true, "still showing the value")

done("test_options")
