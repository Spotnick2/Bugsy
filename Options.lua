-- Options.lua: Bugsy's page in the game's Options > AddOns, and its About sub-page (#22).
-- The shared recipe (porting guide, "An Options page with sub-pages and an About page";
-- Gnomesweeper's and GlassUnitFrames' pages): canvas pages registered at PLAYER_LOGIN,
-- HIDDEN at creation (a frame is created shown, so the first time Settings displays it
-- no OnShow fires and the page stays blank: measured on 70205), built on the first
-- show, every value re-read on every show and after every change. Blizzard's
-- templates, with the client's own art when one is missing (a missing template
-- returns a bare frame, it doesn't throw).
--
-- Settings change only through Bugsy.SetSetting / Bugsy.ChooseSound, the functions the
-- slash command uses, so the two can't drift. No named frames, no globals.

local ADDON, ns = ...
local G = ns.G
local Options = {}
ns.Options = Options

Options.NAME = "Bugsy"
Options.TAGLINE = "Catches Lua errors, groups them into problems, and prepares a report you can give the addon's author."

local function Bugsy() return ns.Bugsy end

------------------------------------------------------------
-- Widgets
------------------------------------------------------------

local CHECK_ART = {
    normal = "Interface\\Buttons\\UI-CheckBox-Up", pushed = "Interface\\Buttons\\UI-CheckBox-Down",
    highlight = "Interface\\Buttons\\UI-CheckBox-Highlight", checked = "Interface\\Buttons\\UI-CheckBox-Check",
}
local RADIO_ART = "Interface\\Buttons\\UI-RadioButton"   -- 4 cells: normal, checked, highlight, pushed

-- A frame from a template, and whether the template really built it (`proof`, a
-- field the template makes, is there).
local function safeFrame(ftype, parent, template, proof)
    local create = G("CreateFrame")
    local ok, f = pcall(create, ftype, nil, parent, template)
    if ok and f then return f, f[proof] ~= nil end
    return create(ftype, nil, parent), false
end
Options.safeFrame = safeFrame

local function label(parent, text, template, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    if width then fs:SetWidth(width) end
    fs:SetText(text)
    return fs
end

local function checkButton(parent, radio)
    local cb, templated = safeFrame("CheckButton", parent, radio and "UIRadioButtonTemplate" or "UICheckButtonTemplate", "text")
    if not templated then
        if radio then
            cb:SetSize(16, 16)
            cb:SetNormalTexture(RADIO_ART)
            cb:GetNormalTexture():SetTexCoord(0, 0.25, 0, 1)
            cb:SetCheckedTexture(RADIO_ART)
            cb:GetCheckedTexture():SetTexCoord(0.25, 0.5, 0, 1)
            cb:SetHighlightTexture(RADIO_ART)
            cb:GetHighlightTexture():SetTexCoord(0.5, 0.75, 0, 1)
        else
            cb:SetNormalTexture(CHECK_ART.normal)
            cb:SetPushedTexture(CHECK_ART.pushed)
            cb:SetHighlightTexture(CHECK_ART.highlight)
            cb:SetCheckedTexture(CHECK_ART.checked)
        end
    end
    if not radio then cb:SetSize(24, 24) end
    return cb
end

local function pageButton(parent, text, width, onClick)
    local b, templated = safeFrame("Button", parent, "UIPanelButtonTemplate", "Text")
    b:SetSize(width, 22)
    if not templated then
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(b)
        bg:SetColorTexture(0.2, 0.2, 0.25, 0.9)
        b:SetNormalFontObject("GameFontHighlight")
    end
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- Closes Blizzard's Settings window before opening one of ours over where it was.
-- Close(true) skips going back to the Game Menu: reopening it from our call would run
-- its Esc handler and the protected SpellStopCasting() (porting guide: measured).
local function closeSettings()
    local sp = G("SettingsPanel")
    if sp and sp.IsShown and sp:IsShown() and sp.Close then pcall(sp.Close, sp, true) end
end

------------------------------------------------------------
-- The page
------------------------------------------------------------

local page = G("CreateFrame")("Frame")
page.name = Options.NAME
page:Hide()                       -- or its first show is blank (above)
local category
local refreshers = {}

-- One toggle: a check button, its label, a note under it.
local function toggle(canvas, y, key, text, note)
    local c = {}
    c.check = checkButton(canvas, false)
    c.check:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, y)
    c.check:SetScript("OnClick", function(self)
        Bugsy().SetSetting(key, self:GetChecked() and true or false)
    end)
    c.label = label(canvas, text)
    c.label:SetPoint("LEFT", c.check, "RIGHT", 4, 0)
    y = y - 24
    if note then
        c.note = label(canvas, note, "GameFontHighlightSmall", 540)
        c.note:SetPoint("TOPLEFT", canvas, "TOPLEFT", 48, y)
        y = y - 20
    end
    refreshers[#refreshers + 1] = function() c.check:SetChecked(Bugsy().Get(key) and true or false) end
    page.controls[key] = c
    return y - 6
end

local function heading(canvas, y, text)
    local fs = label(canvas, text, "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, y)
    return y - 28
end

local function buildPage()
    -- On a scroll frame's child, as Gnomesweeper's page: the text must never run off
    -- the Settings canvas. Without the template's bar, the wheel still scrolls.
    local scroll = G("CreateFrame")("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -26, 4)
    local canvas = G("CreateFrame")("Frame", nil, scroll)
    canvas:SetSize(600, 600)
    scroll:SetScrollChild(canvas)
    if scroll.ScrollBar then
        scroll:HookScript("OnScrollRangeChanged", function(self, _, yrange)
            self.ScrollBar:SetShown((yrange or self:GetVerticalScrollRange()) > 0)
        end)
    else
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            local v = math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 40))
            self:SetVerticalScroll(v)
        end)
    end
    scroll:SetScript("OnSizeChanged", function(_, w)
        if type(w) == "number" and w > 0 then canvas:SetWidth(w) end
    end)
    page.scroll, page.canvas, page.controls = scroll, canvas, {}

    local title = label(canvas, Options.NAME, "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, -16)
    local sub = label(canvas, Options.TAGLINE, "GameFontHighlightSmall", 560)
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 2, -6)

    local y = -70
    page.open = pageButton(canvas, "Open Bugsy", 140, function()
        closeSettings()
        if ns.UI then ns.UI.Show() end
    end)
    page.open:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, y)
    page.report = pageButton(canvas, "Report a problem...", 160, function()
        closeSettings()
        if ns.ReportUI then ns.ReportUI.OpenManual() end
    end)
    page.report:SetPoint("LEFT", page.open, "RIGHT", 8, 0)
    y = y - 40

    y = heading(canvas, y, "Appearance")
    page.looks = {}
    for _, key in ipairs(ns.Theme.CHOICES) do
        local rb = checkButton(canvas, true)
        rb:SetPoint("TOPLEFT", canvas, "TOPLEFT", 20, y)
        rb:SetScript("OnClick", function() ns.Theme.SetChoice(key); Options.Refresh() end)
        rb.label = label(canvas, ns.Theme.LABELS[key])
        rb.label:SetPoint("LEFT", rb, "RIGHT", 4, 0)
        rb.key = key
        page.looks[#page.looks + 1] = rb
        y = y - 22
    end
    page.lookNote = label(canvas, "", "GameFontHighlightSmall", 540)
    page.lookNote:SetPoint("TOPLEFT", canvas, "TOPLEFT", 48, y)
    y = y - 34
    refreshers[#refreshers + 1] = function()
        local T = ns.Theme
        local choice = T.Choice()
        for _, rb in ipairs(page.looks) do
            rb:SetChecked(rb.key == choice)
            local ok = (rb.key == "follow" and T.Suite() ~= nil) or (rb.key == "pearl" and T.PearlAvailable()) or rb.key == "forever"
            if ok then rb:Enable(); rb.label:SetAlpha(1) else rb:Disable(); rb.label:SetAlpha(0.45) end
        end
        local name, note = T.Describe()
        page.lookNote:SetText("Bugsy's window: " .. name .. "." .. (note and (" " .. note) or "")
            .. (T.Suite() and "" or " Follow Glass UI appears when Glass UI is loaded."))
    end

    y = heading(canvas, y, "Notifications")
    y = toggle(canvas, y, "notices", "A chat line when a new problem is caught",
        "At most one every 10 seconds, and held until combat ends.")
    y = toggle(canvas, y, "sound", "A sound when a new problem is caught",
        "It follows the chat line's timing, and plays even with the chat line off.")
    local soundLabel = label(canvas, "Sound (choosing one plays it, and turns the sound on)", "GameFontHighlightSmall")
    soundLabel:SetPoint("TOPLEFT", canvas, "TOPLEFT", 48, y)
    y = y - 20
    page.sounds = {}
    for i, s in ipairs(Bugsy().SOUNDS) do
        local rb = checkButton(canvas, true)
        rb:SetPoint("TOPLEFT", canvas, "TOPLEFT", 52, y)
        rb:SetScript("OnClick", function() Bugsy().ChooseSound(i) end)
        local fs = label(canvas, s.name)
        fs:SetPoint("LEFT", rb, "RIGHT", 4, 0)
        rb.label = fs
        page.sounds[i] = rb
        y = y - 20
    end
    refreshers[#refreshers + 1] = function()
        local current = Bugsy().SoundIndex()
        for i, rb in ipairs(page.sounds) do rb:SetChecked(i == current) end
    end
    y = y - 10

    y = heading(canvas, y, "Minimap")
    y = toggle(canvas, y, "minimap", "Show the minimap button",
        "Left-click opens Bugsy, right-click this page. Drag it around the minimap.")
    y = y - 4

    y = heading(canvas, y, "Capture")
    y = toggle(canvas, y, "locals", "Capture local variables with errors",
        "Off by default: they can contain names and messages. Applies to new errors.")
    y = toggle(canvas, y, "front", "Catch errors ahead of another addon's error handler",
        "Bugsy passes each error on to that handler. Applies from the next session (/reload).")
    y = y - 4

    y = heading(canvas, y, "Status")
    page.status = label(canvas, "", "GameFontHighlightSmall", 540)
    page.status:SetPoint("TOPLEFT", canvas, "TOPLEFT", 20, y)
    refreshers[#refreshers + 1] = function()
        page.status:SetText(table.concat(Bugsy().StatusLines(), "\n"))
    end
    canvas:SetHeight(-y + 160)          -- the status lines wrap: room for them
end

-- Re-reads every value, when the page is shown (a change from the slash command, or
-- the capture's status, is never stale on it).
function Options.Refresh()
    if not (page.built and page:IsShown()) then return end
    for _, fn in ipairs(refreshers) do fn() end
end

page:SetScript("OnShow", function(self)
    if not self.built then
        self.built = true
        buildPage()
    end
    Options.Refresh()
end)

------------------------------------------------------------
-- About (a sub-page)
------------------------------------------------------------

local about = G("CreateFrame")("Frame")
about.name = "About"
about:Hide()                      -- see `page`

Options.HOW_TO = {
    -- one whole sentence per line
    "When an addon has an error, Bugsy keeps it, with what it can tell about where it came from.",
    "The same error again counts on the same problem, so a flood of errors is one line, not hundreds.",
    "Type /bugsy (or use the minimap's addon menu) to see them, then Report to prepare a report for the addon's author.",
    "Bugsy sends nothing anywhere: you copy the report and give it to the author yourself.",
}

local function buildAbout()
    local y = -16
    local function add(fs, height, indent)
        fs:SetPoint("TOPLEFT", about, "TOPLEFT", 16 + (indent or 0), y)
        y = y - height
        return fs
    end
    about.title = add(label(about, Options.NAME, "GameFontNormalHuge"), 30)
    about.tagline = add(label(about, Options.TAGLINE, "GameFontHighlight", 600), 22, 2)
    about.version = add(label(about, ("Version %s  \194\183  for World of Warcraft: Forever  \194\183  by Spotnick")
        :format(ns.Context.version(ADDON) or "dev"), "GameFontHighlightSmall"), 30, 2)

    add(label(about, "How to use", "GameFontNormalLarge"), 24)
    for _, line in ipairs(Options.HOW_TO) do add(label(about, line, nil, 600), 20, 4) end

    y = y - 10
    add(label(about, "Commands", "GameFontNormalLarge"), 24)
    about.commands = {}
    for _, line in ipairs(Bugsy().HELP) do
        about.commands[#about.commands + 1] = add(label(about, line, "GameFontHighlightSmall", 600), 16, 4)
    end
end

about:SetScript("OnShow", function(self)
    if not self.built then
        self.built = true
        buildAbout()
    end
end)

------------------------------------------------------------
-- Registration and opening
------------------------------------------------------------

local function register()
    local S = G("Settings")
    if category or not (S and S.RegisterCanvasLayoutCategory and S.RegisterAddOnCategory) then return end
    local ok, cat = pcall(S.RegisterCanvasLayoutCategory, page, page.name)
    if not (ok and cat) then return end
    category = cat
    pcall(S.RegisterAddOnCategory, category)
    -- The sub-page, right after its page and from the same handler (registration
    -- order is the list's order).
    if S.RegisterCanvasLayoutSubcategory then
        pcall(S.RegisterCanvasLayoutSubcategory, category, about, about.name)
    end
end

-- Opens the page; false when the Settings framework can't.
function Options.Open()
    local S = G("Settings")
    if not (category and S and S.OpenToCategory and category.GetID) then return false end
    local ok, id = pcall(category.GetID, category)
    if not ok then return false end
    return pcall(S.OpenToCategory, id) and true or false
end

local reg = G("CreateFrame")("Frame")
reg:RegisterEvent("PLAYER_LOGIN")
reg:SetScript("OnEvent", function() register() end)

ns._test = ns._test or {}
ns._test.Options = { page = page, about = about, category = function() return category end }
