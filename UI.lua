-- UI.lua: the main window (DESIGN.md §8). Built on first open, plain Blizzard
-- templates, no secure frames. Every string shown goes through UI.escape so a "|"
-- in an error never becomes markup. Never opened automatically.

local ADDON, ns = ...
local G, API, Store, Capture, Safe = ns.G, ns.API, ns.Store, ns.Capture, ns.Safe
local UI = {}
ns.UI = UI

UI.ROWS = 14
local state = { filter = "session", showMuted = false, selected = nil, offset = 0, clearAllArmed = false }
UI.state = state

local FILTER_NEXT = { session = "previous", previous = "all", all = "session" }
local FILTER_LABEL = { session = "This session", previous = "Previous session", all = "All" }

-- "|" starts WoW markup; doubled, it shows as itself. (P12 measures what Ctrl+C then yields.)
function UI.escape(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("|", "||"))
end

local function fieldText(v)
    if type(v) == "string" then return v end
    if type(v) == "table" then
        if v.text then return v.text .. "\n[cut: " .. tostring(v.originalLength) .. " bytes in all]" end
        if v.restricted then return "[restricted: " .. tostring(v.reason) .. "]" end
        if v.unavailable then return "[not captured: " .. tostring(v.reason) .. "]" end
        if v.unsupported then return "[message was a " .. tostring(v.unsupported) .. ", not text]" end
    end
    return "[none]"
end
UI.fieldText = fieldText

local function when(t)
    local d = G("date")
    return (type(t) == "number" and d) and d("%Y-%m-%d %H:%M:%S", t) or "?"
end

local function addonLabel(p)
    local a = p.attribution and p.attribution.suspect
    if a then return a.addon end
    if p.attribution and p.attribution.named then return p.attribution.named.addon end
    return "?"
end

-- The plain-text details of a problem (what Copy details copies and the pane shows).
function UI.Details(p)
    local L = {}
    local function add(s) L[#L + 1] = s end
    add(p.title)
    add(("%s · %s%d time%s · first %s · last %s · %d session%s"):format(p.kind,
        p.countIncomplete and "at least " or "", p.count, p.count == 1 and "" or "s",
        when(p.firstSeen), when(p.lastSeen), p.sessionCount or 1, (p.sessionCount or 1) == 1 and "" or "s"))
    if p.unconfirmedRepeats then add(("+%d more with the same message (stack not captured)"):format(p.unconfirmedRepeats)) end
    if (p.callPathsOverflow or 0) > 0 then add(("Reached by more than %d call paths"):format(#p.callPaths))
    elseif #p.callPaths > 1 then add(("Reached by %d call paths"):format(#p.callPaths)) end
    local a = p.attribution or {}
    add("")
    add("Named by WoW: " .. (a.named and (a.named.addon .. " (" .. a.named.source .. ")") or "none"))
    local parts = {}
    for _, f in ipairs(a.inStack or {}) do
        parts[#parts + 1] = f.library and (f.library .. " (library" .. (f.host and (" in " .. f.host) or "") .. ")") or f.folder
    end
    add("In the stack: " .. (#parts > 0 and table.concat(parts, ", ") or "no addon frames"))
    if a.suspect then
        add(("Appears involved: %s (%s confidence: %s)"):format(a.suspect.addon, a.suspect.confidence,
            table.concat(a.suspect.evidence or {}, "; ")))
    end
    local vs = {}
    for _, ad in ipairs(p.addons or {}) do
        local list = {}
        for v, n in pairs(ad.versions) do list[#list + 1] = v .. (n > 1 and (" ×" .. n) or "") end
        table.sort(list)
        vs[#vs + 1] = ad.name .. " " .. table.concat(list, "/")
    end
    if #vs > 0 then add("Versions: " .. table.concat(vs, ", ")) end
    local newest = p.last[#p.last] or p.first[#p.first]
    if newest then
        local matches = ns.Patterns.match({ kind = p.kind, message = Safe.text(newest.message),
            stack = Safe.text(newest.stack), inCombat = newest.inCombat == true,
            taintLog = type(newest.taintLog) == "string" and newest.taintLog or nil,
            actionFunction = newest.event and newest.event.func }, tonumber(newest.build))
        for _, m in ipairs(matches) do
            add("")
            add(("Possible explanation (not a diagnosis) [%s r%d, %s]: %s"):format(m.id, m.rev, m.confidence, m.summary))
            add("To investigate: " .. m.investigate)
        end
    end
    local samples = {}
    for _, s in ipairs(p.first) do samples[#samples + 1] = s end
    for _, s in ipairs(p.last) do samples[#samples + 1] = s end
    for i, s in ipairs(samples) do
        add("")
        add(("--- Occurrence %d of %d kept · %s · build %s · %s%s · stack %s"):format(i, #samples, when(s.at),
            tostring(s.build), s.provider or "?", s.inCombat == true and " · in combat" or "", tostring(s.stackOrigin)))
        add(fieldText(s.message))
        add(fieldText(s.stack))
        if type(s.locals) == "string" or (type(s.locals) == "table" and s.locals.text) then
            add("Locals:")
            add(fieldText(s.locals))
        end
    end
    if (p.sampledOut or 0) > 0 then add(""); add(p.sampledOut .. " more occurrences counted but not kept.") end
    return table.concat(L, "\n")
end

function UI.StatusText()
    local mode, lost, failures = ns.Bugsy.Status()
    local s = "Bugsy is " .. mode .. "."
    if lost > 0 then s = s .. " " .. lost .. " errors this session were only counted (flood)." end
    if failures > 0 then s = s .. " " .. failures .. " internal failures." end
    local S = ns.Capture.state
    if S.health.pause then s = s .. " Error reporting may be paused: see /bugsy status." end
    if S.forward.suspended then s = s .. " Passing errors on is suspended: see /bugsy status." end
    return s
end

-- Building -----------------------------------------------------------------------

local frame

local function button(parent, text, width, onClick)
    local b = G("CreateFrame")("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end
UI.button = button

-- A read-only multi-line text box in a scroll frame. Returns scroll, edit.
function UI.textBox(parent, width, height)
    local create = G("CreateFrame")
    local scroll = create("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetSize(width, height)
    local edit = create("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(width)
    edit:SetMaxLetters(0)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- read-only: a typed change puts the text back
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self.fixed then self:SetText(self.fixed) end
    end)
    scroll:SetScrollChild(edit)
    function edit:SetFixed(text) self.fixed = text; self:SetText(text); self:SetCursorPosition(0) end
    return scroll, edit
end

local function build()
    local create = G("CreateFrame")
    frame = create("Frame", "BugsyFrame", G("UIParent"), "BasicFrameTemplateWithInset")
    frame:SetSize(820, 480)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Bugsy")

    -- filters
    local filterBtn = button(frame, FILTER_LABEL[state.filter], 130, function(self)
        state.filter = FILTER_NEXT[state.filter]
        state.offset = 0
        self:SetText(FILTER_LABEL[state.filter])
        UI.Refresh()
    end)
    filterBtn:SetPoint("TOPLEFT", 12, -30)
    local muted = create("CheckButton", nil, frame, "UICheckButtonTemplate")
    muted:SetSize(24, 24)
    muted:SetPoint("LEFT", filterBtn, "RIGHT", 6, 0)
    muted:SetScript("OnClick", function(self) state.showMuted = self:GetChecked() and true or false; UI.Refresh() end)
    local mutedLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mutedLabel:SetPoint("LEFT", muted, "RIGHT", 2, 0)
    mutedLabel:SetText("Show muted")

    -- the list
    frame.rows = {}
    for i = 1, UI.ROWS do
        local row = create("Button", nil, frame)
        row:SetSize(290, 26)
        row:SetPoint("TOPLEFT", 12, -58 - (i - 1) * 27)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", 4, -2)
        text:SetPoint("RIGHT", -4, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        local sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        sub:SetPoint("BOTTOMLEFT", 4, 2)
        sub:SetPoint("RIGHT", -4, 0)
        sub:SetJustifyH("LEFT")
        row.text, row.sub = text, sub
        row:SetScript("OnClick", function(self) state.selected = self.id; UI.Refresh() end)
        frame.rows[i] = row
    end
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        state.offset = math.max(0, state.offset - delta)
        UI.Refresh()
    end)
    frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    frame.empty:SetPoint("TOPLEFT", 16, -64)
    frame.empty:SetText("No problems here. Nice and quiet.")

    -- the details
    local scroll, edit = UI.textBox(frame, 470, 340)
    scroll:SetPoint("TOPLEFT", 318, -32)
    frame.details = edit

    -- actions
    frame.report = button(frame, "Prepare report", 120, function()
        if state.selected and ns.ReportUI then ns.ReportUI.OpenFor(state.selected) end
    end)
    frame.report:SetPoint("BOTTOMLEFT", 318, 40)
    frame.copy = button(frame, "Copy details", 110, function()
        frame.details:SetFocus()
        frame.details:HighlightText()
        frame.hint:SetText("Press Ctrl+C to copy.")
    end)
    frame.copy:SetPoint("LEFT", frame.report, "RIGHT", 6, 0)
    frame.mute = button(frame, "Mute", 80, function()
        local p = state.selected and Store.Get(state.selected)
        if p then Store.SetMuted(p.id, not p.muted) end
        UI.Refresh()
    end)
    frame.mute:SetPoint("LEFT", frame.copy, "RIGHT", 6, 0)
    frame.clear = button(frame, "Clear", 70, function()
        if state.selected then Store.Clear(state.selected); state.selected = nil end
        UI.Refresh()
    end)
    frame.clear:SetPoint("LEFT", frame.mute, "RIGHT", 6, 0)
    frame.clearAll = button(frame, "Clear all", 80, function(self)
        if state.clearAllArmed then
            state.clearAllArmed = false
            Store.Clear("all")
            state.selected = nil
            self:SetText("Clear all")
        else
            state.clearAllArmed = true
            self:SetText("Sure?")
            API.After(3, function() if state.clearAllArmed then state.clearAllArmed = false; self:SetText("Clear all") end end)
        end
        UI.Refresh()
    end)
    frame.clearAll:SetPoint("LEFT", frame.clear, "RIGHT", 6, 0)

    frame.manual = button(frame, "Report a problem", 140, function()
        if ns.ReportUI then ns.ReportUI.OpenManual() end
    end)
    frame.manual:SetPoint("BOTTOMLEFT", 12, 40)

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.hint:SetPoint("BOTTOMLEFT", 318, 66)
    frame.hint:SetText("")

    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.status:SetPoint("BOTTOMLEFT", 14, 14)
    frame.status:SetPoint("RIGHT", -14, 0)
    frame.status:SetJustifyH("LEFT")

    frame:SetScript("OnShow", function() UI.Refresh() end)
end

-- Refresh ------------------------------------------------------------------------

function UI.Refresh()
    if not (frame and frame:IsShown()) then return end
    local list = Store.List(state.filter, state.showMuted)
    local maxOffset = math.max(0, #list - UI.ROWS)
    if state.offset > maxOffset then state.offset = maxOffset end
    if not state.selected or not Store.Get(state.selected) then state.selected = list[1] and list[1].id end
    for i, row in ipairs(frame.rows) do
        local p = list[i + state.offset]
        if p then
            row.id = p.id
            local tags = (p.muted and " [muted]" or "") .. (p.restricted and " [restricted]" or "")
            row.text:SetText(UI.escape(p.title))
            row.sub:SetText(UI.escape(("%s · ×%d · %s%s"):format(addonLabel(p), p.count, when(p.lastSeen), tags)))
            if p.id == state.selected then row:LockHighlight() else row:UnlockHighlight() end
            row:Show()
        else
            row.id = nil
            row:Hide()
        end
    end
    frame.empty:SetShown(#list == 0)
    local p = state.selected and Store.Get(state.selected)
    frame.details:SetFixed(p and UI.escape(UI.Details(p)) or "")
    frame.mute:SetText(p and p.muted and "Unmute" or "Mute")
    for _, b in ipairs({ frame.report, frame.copy, frame.mute, frame.clear }) do
        if p then b:Enable() else b:Disable() end
    end
    frame.hint:SetText("")
    frame.status:SetText(UI.escape(UI.StatusText()))
end

function UI.Toggle()
    pcall(ns.Capture.check, "window")
    if not frame then build() end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

function UI.ShowProblem(id)
    if not frame then build() end
    state.selected = id
    frame:Show()
    UI.Refresh()
end

function UI.frame() return frame end

ns._test = ns._test or {}
ns._test.UI = UI
