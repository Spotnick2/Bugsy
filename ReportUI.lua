-- ReportUI.lua: the report flow (DESIGN.md §8). Questions, a preview of exactly
-- what will be copied, where to report it, and copy guidance. Bugsy sends nothing:
-- no wording here may say a report was sent or submitted (a test checks).

local ADDON, ns = ...
local G, API, Store, Report, Context, UI = ns.G, ns.API, ns.Store, ns.Report, ns.Context, ns.UI
local ReportUI = {}
ns.ReportUI = ReportUI

ReportUI.TEXT = {
    privacy = "Everything below is what will be copied. Error text, context and breadcrumbs can contain "
        .. "other players' names or messages; only your own character and realm names are replaced.",
    copyHint = "Press Ctrl+C to copy, then paste it where the author asked. Bugsy has not sent anything: "
        .. "it never contacts anyone.",
    unknownDestination = "Bugsy doesn't know where this addon takes reports. Check its download page "
        .. "(CurseForge, Wago or its website).",
    noProblem = "Choose the addon that misbehaved, answer what you can, then press Preview.",
    tooLarge = "This report could not be built small enough to copy. Try Copy details in the main window.",
}

local state = { mode = nil, problemId = nil, addon = nil, format = "markdown", addons = nil, index = 1,
    markdown = nil, json = nil }
ReportUI.state = state

local frame

-- Loaded addons for "Report a problem", Bugsy and Blizzard's own left out.
local function addonChoices()
    local out = {}
    for _, a in ipairs(API.AddOnList()) do
        if a.loaded and a.name ~= ADDON and not a.name:match("^Blizzard_") then out[#out + 1] = a.name end
    end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

local function answers()
    local function val(box)
        local t = box:GetText()
        return type(t) == "string" and t ~= "" and t or nil
    end
    return {
        doing = val(frame.doing), happened = val(frame.happened), expected = val(frame.expected),
        steps = val(frame.steps), noVisibleProblem = frame.noProblem:GetChecked() and true or false,
    }
end

-- Build, redact and fit the report; fill the preview.
function ReportUI.Preview()
    local r
    if state.mode == "problem" then
        local p = Store.Get(state.problemId)
        if not p then return end
        r = Report.ForProblem(p, answers())
    else
        r = Report.Manual(state.addon, answers())
    end
    local md, json = Report.Render(r)
    if not md then
        state.markdown, state.json = nil, nil
        frame.preview:SetFixed(ReportUI.TEXT.tooLarge)
        frame.destination:SetText("")
        return
    end
    state.markdown, state.json = md, json
    local d = r.destination or {}
    frame.destination:SetText(UI.escape(d.known and ("Report it at: " .. d.url) or ReportUI.TEXT.unknownDestination))
    ReportUI.ShowFormat()
end

function ReportUI.ShowFormat()
    local text = state.format == "json" and state.json or state.markdown
    frame.preview:SetFixed(text and UI.escape(text) or "")
    frame.formatBtn:SetText(state.format == "json" and "Show Markdown" or "Show JSON")
    frame.hint:SetText("")
end

local function labeled(parent, label, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(label)
    local box = G("CreateFrame")("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(400, 20)
    box:SetPoint("TOPLEFT", 200, y + 4)
    box:SetAutoFocus(false)
    box:SetMaxLetters(Report.ANSWER_MAX)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return box
end

local function build()
    local create = G("CreateFrame")
    frame = create("Frame", "BugsyReportFrame", G("UIParent"), "BasicFrameTemplateWithInset")
    frame:SetSize(640, 560)
    frame:SetPoint("CENTER", 40, -20)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)

    frame.subject = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.subject:SetPoint("TOPLEFT", 16, -32)
    frame.subject:SetPoint("RIGHT", -90, 0)
    frame.subject:SetJustifyH("LEFT")
    frame.prev = UI.button(frame, "<", 26, function() ReportUI.Cycle(-1) end)
    frame.prev:SetPoint("TOPRIGHT", -50, -28)
    frame.next = UI.button(frame, ">", 26, function() ReportUI.Cycle(1) end)
    frame.next:SetPoint("LEFT", frame.prev, "RIGHT", 2, 0)

    frame.doing = labeled(frame, "What were you doing?", -60)
    frame.happened = labeled(frame, "What happened?", -86)
    frame.expected = labeled(frame, "What did you expect?", -112)
    frame.steps = labeled(frame, "Steps to make it happen (optional)", -138)
    -- Tab to the next answer, Shift+Tab to the previous, around the four (#24), as
    -- Blizzard's own input boxes chain (InputBoxTemplates.lua, EditBox_OnTabPressed).
    local answers = { frame.doing, frame.happened, frame.expected, frame.steps }
    for i, box in ipairs(answers) do
        box.nextBox = answers[i % #answers + 1]
        box.previousBox = answers[(i - 2) % #answers + 1]
        box:SetScript("OnTabPressed", function(self)
            local shift = G("IsShiftKeyDown")
            local back = shift and shift()
            local to = back and self.previousBox or self.nextBox
            if to then to:SetFocus() end
        end)
    end
    frame.noProblem = create("CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.noProblem:SetSize(24, 24)
    frame.noProblem:SetPoint("TOPLEFT", 14, -160)
    local npLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    npLabel:SetPoint("LEFT", frame.noProblem, "RIGHT", 2, 0)
    npLabel:SetText("I didn't notice a visible problem")

    frame.previewBtn = UI.button(frame, "Preview", 90, function() ReportUI.Preview() end)
    frame.previewBtn:SetPoint("TOPRIGHT", -16, -162)

    local privacy = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    privacy:SetPoint("TOPLEFT", 16, -192)
    privacy:SetPoint("RIGHT", -16, 0)
    privacy:SetJustifyH("LEFT")
    privacy:SetText(ReportUI.TEXT.privacy)

    local scroll, edit = UI.textBox(frame, 590, 250)
    scroll:SetPoint("TOPLEFT", 16, -222)
    frame.preview = edit

    frame.destination = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.destination:SetPoint("BOTTOMLEFT", 16, 66)
    frame.destination:SetPoint("RIGHT", -16, 0)
    frame.destination:SetJustifyH("LEFT")

    frame.formatBtn = UI.button(frame, "Show JSON", 120, function()
        state.format = state.format == "json" and "markdown" or "json"
        ReportUI.ShowFormat()
    end)
    frame.formatBtn:SetPoint("BOTTOMLEFT", 16, 36)
    frame.selectBtn = UI.button(frame, "Select all", 100, function()
        if not (state.markdown or state.json) then return end
        frame.preview:SetFocus()
        frame.preview:HighlightText()
        frame.hint:SetText(ReportUI.TEXT.copyHint)
    end)
    frame.selectBtn:SetPoint("LEFT", frame.formatBtn, "RIGHT", 6, 0)
    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.hint:SetPoint("BOTTOMLEFT", 16, 14)
    frame.hint:SetPoint("RIGHT", -16, 0)
    frame.hint:SetJustifyH("LEFT")
end

local function reset()
    for _, box in ipairs({ frame.doing, frame.happened, frame.expected, frame.steps }) do box:SetText("") end
    frame.noProblem:SetChecked(false)
    frame.preview:SetFixed("")
    frame.destination:SetText("")
    frame.hint:SetText("")
    state.markdown, state.json, state.format = nil, nil, "markdown"
    frame.formatBtn:SetText("Show JSON")
end

function ReportUI.OpenFor(problemId)
    local p = Store.Get(problemId)
    if not p then return end
    if not frame then build() end
    reset()
    state.mode, state.problemId = "problem", problemId
    frame.title:SetText("Prepare a report")
    frame.subject:SetText(UI.escape(p.title))
    frame.prev:Hide(); frame.next:Hide()
    frame:Show()
end

function ReportUI.OpenManual(addon)
    if not frame then build() end
    reset()
    state.mode, state.problemId = "manual", nil
    state.addons = addonChoices()
    state.index = 1
    if addon then
        for i, n in ipairs(state.addons) do if n == addon then state.index = i end end
    end
    state.addon = state.addons[state.index]
    frame.title:SetText("Report a problem")
    frame.subject:SetText(UI.escape("Addon: " .. (state.addon or "none loaded")))
    frame.prev:Show(); frame.next:Show()
    frame.hint:SetText(ReportUI.TEXT.noProblem)
    frame:Show()
end

function ReportUI.Cycle(step)
    local n = state.addons and #state.addons or 0
    if n == 0 then return end
    state.index = (state.index - 1 + step) % n + 1
    state.addon = state.addons[state.index]
    frame.subject:SetText(UI.escape("Addon: " .. state.addon))
    frame.preview:SetFixed("")
    state.markdown, state.json = nil, nil
end

function ReportUI.frame() return frame end

ns._test = ns._test or {}
ns._test.ReportUI = ReportUI
