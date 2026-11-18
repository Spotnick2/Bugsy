-- ReportUI.lua: the report flow, inside Bugsy's window (#28; DESIGN §8). Three steps:
-- 1 Describe, 2 Review, 3 Copy & report, with "< Problems" to go back. "Copy for a bug
-- report" opens straight at step 3 (the owner: a convenient paste for a GitHub issue or a
-- CurseForge comment matters most); "Prepare report" and "Report a problem" start at 1.
--
-- The answers live in the draft (Model.NewDraft), never only in the fields, so Back,
-- Next and a look change keep them. Every change bumps the draft's version, and the text
-- shown or copied always comes from Model.Render for the current version: a stale
-- preview can't be copied. Bugsy sends nothing: no wording here may say a report was
-- sent or submitted, or that anything was copied (a test checks).

local ADDON, ns = ...
local G, API, Store, Report, L = ns.G, ns.API, ns.Store, ns.Report, ns.L
local Theme, W, M = ns.Theme, ns.Widgets, ns.Model
local ReportUI = {}
ns.ReportUI = ReportUI

ReportUI.TEXT = {
    privacy = L["Bugsy replaces your own character and realm names. Error text and context can still contain other players' names or messages: look before you paste."],
    unknownDestination = L["Bugsy doesn't know where this addon takes reports. Look on its download page (CurseForge, Wago) or its website for an issue tracker or comments."],
    -- The bottom bar already says nothing is sent (#31: seen twice in game).
    copyHint = L["Select all, then press Ctrl+C, and paste it where the author asked."],
    selected = L["Selected: press Ctrl+C now, then paste it into the issue or comment."],
}
ReportUI.FORMATS = {
    { key = "markdown", label = L["GitHub (Markdown)"] },
    { key = "short", label = L["CurseForge comment"] },
    { key = "json", label = L["JSON (advanced)"] },
}

local UI = function() return ns.UI end
local function state() return ns.UI.state end
local function draft() return state().draft end

local view          -- this window's report view (rebuilt with the window)

------------------------------------------------------------
-- Opening and moving between steps
------------------------------------------------------------

local function open(d)
    local s = state()
    s.draft = d
    s.view = "report"
    ns.UI.Show()
end

function ReportUI.OpenFor(problemId)
    if not Store.Get(problemId) then return end
    open(M.NewDraft("problem", problemId))
end

-- Straight to Copy & report: the diagnostics without questions.
function ReportUI.OpenCopy(problemId)
    if not Store.Get(problemId) then return end
    local d = M.NewDraft("problem", problemId)
    d.step, d.direct = 3, true
    open(d)
end

-- A problem with no captured error. `addon`, when a caller passes one, is an explicit
-- choice; otherwise the picker starts on "Choose an addon..." (never the first listed).
function ReportUI.OpenManual(addon)
    local d = M.NewDraft("manual")
    if type(addon) == "string" then M.SetDraft(d, "addon", addon) end
    open(d)
end

function ReportUI.Back()
    local s = state()
    s.view, s.draft = "problems", nil
    ns.UI.Refresh()
end

function ReportUI.Go(step)
    local d = draft()
    if not d then return end
    if step >= 2 and d.mode == "manual" and not d.addon then step = 1 end
    d.step = step
    ns.UI.Refresh()
end

------------------------------------------------------------
-- Building (with the window)
------------------------------------------------------------

local function label(parent, text, font, key)
    local fs = W.Text(parent, font or "GameFontNormal", key or "heading")
    fs:SetText(text)
    return fs
end

local function buildPicker(v, parent)
    v.picker = W.Button(parent, "", { height = 28, onClick = function()
        v.pickerPanel:SetShown(not v.pickerPanel:IsShown())
        if v.pickerPanel:IsShown() then
            v.pickerSearch:setValue("")
            ReportUI.RefreshPicker()
            v.pickerSearch.edit:SetFocus()
        end
    end })
    v.picker.label:ClearAllPoints()
    v.picker.label:SetPoint("LEFT", 30, 0)
    v.picker.label:SetPoint("RIGHT", -28, 0)
    v.picker.label:SetJustifyH("LEFT")
    local glass = v.picker:CreateTexture(nil, "OVERLAY")
    glass:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    glass:SetSize(14, 14)
    glass:SetPoint("LEFT", 10, 0)
    local arrow = v.picker:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
    arrow:SetSize(20, 20)
    arrow:SetPoint("RIGHT", -4, 0)

    local panel = G("CreateFrame")("Frame", nil, v)
    panel:SetPoint("TOPLEFT", v.picker, "BOTTOMLEFT", 0, -2)
    panel:SetPoint("TOPRIGHT", v.picker, "BOTTOMRIGHT", 0, -2)
    panel:SetHeight(230)
    panel:SetFrameLevel((v:GetFrameLevel() or 1) + 30)
    panel:EnableMouse(true)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(panel)
    bg:SetColorTexture(0.05, 0.05, 0.06, 0.98)
    Theme.edges(panel, Theme.C.controlEdge)
    v.pickerSearch = W.Field(panel, { placeholder = L["Type to search your installed addons"],
        onChange = function() ReportUI.RefreshPicker() end })
    v.pickerSearch:SetPoint("TOPLEFT", 6, -6)
    v.pickerSearch:SetPoint("TOPRIGHT", -6, -6)
    v.pickerScroll, v.pickerChild = W.Scroll(panel)
    v.pickerScroll:SetPoint("TOPLEFT", v.pickerSearch, "BOTTOMLEFT", 0, -6)
    v.pickerScroll:SetPoint("BOTTOMRIGHT", -24, 6)
    v.pickerRows = {}
    v.pickerNone = W.Text(panel, "GameFontHighlightSmall", "muted")
    v.pickerNone:SetPoint("TOPLEFT", v.pickerScroll, "TOPLEFT", 6, -6)
    v.pickerNone:SetText(L["No installed addon matches."])
    panel:Hide()
    v.pickerPanel = panel
end

function ReportUI.RefreshPicker()
    local v, d = view, draft()
    if not (v and d) then return end
    local include = d.mode == "problem" and d.addon or nil
    local list = M.SearchAddons(M.AddonChoices(include), v.pickerSearch.edit:GetText())
    v.pickerChoices = list
    for i, a in ipairs(list) do
        local row = v.pickerRows[i]
        if not row then
            row = G("CreateFrame")("Button", nil, v.pickerChild)
            row:SetHeight(22)
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(row)
            hl:SetColorTexture(1, 1, 1, 0.08)
            row.title = W.Line(row, "GameFontHighlight", "text")
            row.title:SetPoint("LEFT", 6, 0)
            row.version = W.Line(row, "GameFontHighlightSmall", "muted", "RIGHT")
            row.version:SetPoint("RIGHT", -6, 0)
            row.title:SetPoint("RIGHT", row.version, "LEFT", -8, 0)
            row:SetScript("OnClick", function(self)
                local dd = draft()
                if dd then M.SetDraft(dd, "addon", self.name) end
                v.pickerPanel:Hide()
                ns.UI.Refresh()
            end)
            v.pickerRows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", v.pickerChild, "TOPLEFT", 0, -(i - 1) * 22)
        row:SetPoint("RIGHT", v.pickerChild, "RIGHT", 0, 0)
        row.name = a.name
        row.title:SetText(ns.UI.escape(a.title))
        row.version:SetText(ns.UI.escape((a.version or "") .. (a.loaded and "" or (" " .. L["(not loaded)"]))))
        row:Show()
    end
    for i = #list + 1, #v.pickerRows do v.pickerRows[i]:Hide() end
    v.pickerChild:SetHeight(math.max(1, #list * 22))
    v.pickerNone:SetShown(#list == 0)
end

local function buildDescribe(v, page)
    v.addonLabel = label(page, L["Which addon?"])
    v.addonLabel:SetPoint("TOPLEFT", 0, 0)
    buildPicker(v, page)
    v.picker:SetPoint("TOPLEFT", v.addonLabel, "BOTTOMLEFT", 0, -6)
    v.picker:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    v.guess = W.Text(page, "GameFontHighlightSmall", "muted")
    v.guess:SetPoint("TOPLEFT", v.picker, "BOTTOMLEFT", 4, -4)
    v.guess:SetPoint("RIGHT", page, "RIGHT", 0, 0)

    v.describeLabel = label(page, L["Describe the problem"])
    v.describeLabel:SetPoint("TOPLEFT", v.guess, "BOTTOMLEFT", -4, -12)
    v.describe = W.Field(page, { multiline = true, height = 72, maxLetters = Report.ANSWER_MAX,
        onChange = function(t) local d = draft(); if d then M.SetDraft(d, "description", t) end end })
    v.describe:SetPoint("TOPLEFT", v.describeLabel, "BOTTOMLEFT", 0, -6)
    v.describe:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    v.describeHelp = W.Text(page, "GameFontHighlightSmall", "muted")
    v.describeHelp:SetPoint("TOPLEFT", v.describe, "BOTTOMLEFT", 4, -4)
    v.describeHelp:SetText(L["What were you doing, and what happened?"])

    v.more = W.Section(page, L["Additional details (optional)"], function() ns.UI.Refresh() end)
    v.more:SetPoint("TOPLEFT", v.describeHelp, "BOTTOMLEFT", -4, -10)
    v.more:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    v.more.body:SetHeight(96)
    local half = G("CreateFrame")("Frame", nil, v.more.body)
    half:SetPoint("TOPLEFT", 8, -2)
    half:SetPoint("BOTTOMRIGHT", v.more.body, "BOTTOM", -6, 0)
    local half2 = G("CreateFrame")("Frame", nil, v.more.body)
    half2:SetPoint("TOPLEFT", v.more.body, "TOP", 6, -2)
    half2:SetPoint("BOTTOMRIGHT", -8, 0)
    local l1 = label(half, L["What did you expect?"], "GameFontHighlight", "text")
    l1:SetPoint("TOPLEFT", 0, 0)
    v.expected = W.Field(half, { multiline = true, height = 62, maxLetters = Report.ANSWER_MAX,
        onChange = function(t) local d = draft(); if d then M.SetDraft(d, "expected", t) end end })
    v.expected:SetPoint("TOPLEFT", l1, "BOTTOMLEFT", 0, -4)
    v.expected:SetPoint("RIGHT", half, "RIGHT", 0, 0)
    local l2 = label(half2, L["Steps to reproduce"], "GameFontHighlight", "text")
    l2:SetPoint("TOPLEFT", 0, 0)
    v.steps = W.Field(half2, { multiline = true, height = 62, maxLetters = Report.ANSWER_MAX,
        onChange = function(t) local d = draft(); if d then M.SetDraft(d, "steps", t) end end })
    v.steps:SetPoint("TOPLEFT", l2, "BOTTOMLEFT", 0, -4)
    v.steps:SetPoint("RIGHT", half2, "RIGHT", 0, 0)
    W.ChainTab({ v.describe, v.expected, v.steps })

    v.noVisible = W.Check(page, L["I didn't notice a visible problem"], function(on)
        local d = draft(); if d then M.SetDraft(d, "noVisible", on or nil) end
    end)
    v.info = W.Text(page, "GameFontHighlightSmall", "text")
    v.info:SetPoint("RIGHT", page, "RIGHT", 0, 0)
end

local function buildReview(v, page)
    v.reviewScroll, v.reviewChild = W.Scroll(page)
    v.reviewScroll:SetPoint("TOPLEFT")
    v.reviewScroll:SetPoint("BOTTOMRIGHT", -22, 0)
    local c = v.reviewChild
    v.review = {}
    for _, key in ipairs({ "addon", "description", "attached", "environment", "destination", "privacy" }) do
        local head = W.Line(c, "GameFontNormal", "heading")
        local body = W.Text(c, "GameFontHighlightSmall", "text")
        v.review[key] = { head = head, body = body }
    end
    v.reviewFull = W.Section(c, L["The full report"], function() ns.UI.Refresh() end)
    v.reviewText = W.ReadOnly(v.reviewFull.body)
    v.reviewText:SetAllPoints(v.reviewFull.body)
    v.reviewFull.body:SetHeight(200)
end

local function buildCopy(v, page)
    v.ready = label(page, L["Ready to copy"], "GameFontNormalLarge", "heading")
    v.ready:SetPoint("TOPLEFT", 0, 0)
    v.dest = W.Text(page, "GameFontHighlight", "text")
    v.dest:SetPoint("TOPLEFT", v.ready, "BOTTOMLEFT", 0, -8)
    v.dest:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    v.destBox = W.Field(page, {})                -- the address, selectable to copy
    v.destBox:SetPoint("TOPLEFT", v.dest, "BOTTOMLEFT", 0, -6)
    v.destBox:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    v.destBox.edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    v.destBox.edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self.fixed then self:SetText(self.fixed); self:HighlightText() end
    end)
    v.formats = W.Tabs(page, ReportUI.FORMATS, function(key)
        local d = draft(); if d then d.format = key end
        ns.UI.Refresh()
    end, 150)
    v.copyText = W.ReadOnly(page)
    v.copyText:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    v.copyHint = W.Text(page, "GameFontHighlightSmall", "muted")
    v.copyHint:SetPoint("RIGHT", page, "RIGHT", 0, 0)
end

local function buildSteps(v, top)
    v.stepBtns = {}
    local names = { L["Describe"], L["Review"], L["Copy & report"] }
    local holder = G("CreateFrame")("Frame", nil, v)
    holder:SetSize(420, 26)
    holder:SetPoint("TOP", top, "BOTTOM", 0, -8)
    for i, name in ipairs(names) do
        local b = G("CreateFrame")("Button", nil, holder)
        b:SetSize(130, 26)
        b:SetPoint("LEFT", (i - 1) * 145, 0)
        b.circle = b:CreateTexture(nil, "ARTWORK")
        b.circle:SetTexture(W.DOT)
        b.circle:SetSize(22, 22)
        b.circle:SetPoint("LEFT", 0, 0)
        b.num = W.Text(b, "GameFontNormal", "heading", "CENTER")
        b.num:SetPoint("CENTER", b.circle, "CENTER", 0, 0)
        b.num:SetText(tostring(i))
        b.text = W.Line(b, "GameFontHighlight", "text")
        b.text:SetPoint("LEFT", b.circle, "RIGHT", 6, 0)
        b.text:SetText(name)
        b:SetScript("OnClick", function() ReportUI.Go(i) end)
        v.stepBtns[i] = b
    end
end

function ReportUI.Build(f, body)
    local v = G("CreateFrame")("Frame", nil, body)
    v:SetAllPoints(body)
    v:Hide()
    f.views.report = v
    view = v
    v.back = W.Button(v, L["< Problems"], { kind = "quiet", width = 100, height = 24, onClick = ReportUI.Back })
    v.back:SetPoint("TOPLEFT", 12, -8)
    v.title = W.Text(v, "GameFontNormalLarge", "heading", "CENTER")
    v.title:SetPoint("TOP", 0, -10)
    v.subtitle = W.Text(v, "GameFontHighlightSmall", "muted", "CENTER")
    v.subtitle:SetPoint("TOP", v.title, "BOTTOM", 0, -4)
    buildSteps(v, v.subtitle)

    local content = G("CreateFrame")("Frame", nil, v)
    content:SetPoint("TOPLEFT", 24, -92)
    content:SetPoint("BOTTOMRIGHT", -24, 46)
    v.pages = {}
    for i = 1, 3 do
        local page = G("CreateFrame")("Frame", nil, content)
        page:SetAllPoints(content)
        v.pages[i] = page
    end
    -- Describe scrolls: with its details open it is taller than the smallest window (Codex, #30).
    v.describeScroll, v.describeChild = W.Scroll(v.pages[1])
    v.describeScroll:SetPoint("TOPLEFT")
    v.describeScroll:SetPoint("BOTTOMRIGHT", -22, 0)
    buildDescribe(v, v.describeChild)
    buildReview(v, v.pages[2])
    buildCopy(v, v.pages[3])

    -- The bottom bar: back or cancel, a reminder, the next action.
    v.left = W.Button(v, L["Cancel"], { width = 110, height = 28, onClick = function()
        local d = draft()
        if d and d.step > 1 and not (d.direct and d.step == 3) then ReportUI.Go(d.step - 1) else ReportUI.Back() end
    end })
    v.left:SetPoint("BOTTOMLEFT", 24, 10)
    v.nothing = W.Text(v, "GameFontHighlightSmall", "muted", "CENTER")
    v.nothing:SetPoint("BOTTOM", 0, 18)
    v.nothing:SetText(L["Nothing is sent automatically."])
    v.right = W.Button(v, "", { kind = "primary", width = 170, height = 28, onClick = function()
        local d = draft()
        if not d then return end
        if d.step < 3 then ReportUI.Go(d.step + 1)
        else ReportUI.SelectAll() end
    end })
    v.right:SetPoint("BOTTOMRIGHT", -24, 10)
    v.done = W.Button(v, L["Done"], { width = 90, height = 28, onClick = ReportUI.Back })
    v.done:SetPoint("RIGHT", v.right, "LEFT", -8, 0)
end

------------------------------------------------------------
-- Refreshing
------------------------------------------------------------

local function textHeight(fs, fallback)
    local h = fs.GetStringHeight and fs:GetStringHeight()
    return (type(h) == "number" and h > 0) and h or (fallback or 14)
end

local function addonText(name)
    if not name then return nil end
    local version = ns.Context.version(name)
    return ns.UI.escape(M.Title(name) .. (version and ("  " .. version) or ""))
end

local function heightOf(region, fallback)
    local h
    if region.GetStringHeight then h = region:GetStringHeight() else h = region:GetHeight() end
    return (type(h) == "number" and h > 0) and h or fallback
end

local function refreshDescribe(v, d)
    local p = d.mode == "problem" and Store.Get(d.problemId)
    v.picker:setLabel(addonText(d.addon) or L["Choose an addon..."])
    Theme.TextColor(v.picker.label, d.addon and "text" or "faint")
    if d.mode == "manual" then
        v.guess:SetText(L["Type to search your installed addons."])
    elseif d.guess and d.addon then
        v.guess:SetText(d.guessHow == "named"
            and L["The game named this addon; that doesn't prove it caused the problem. Change it if you know better."]
            or L["Bugsy's reading: this addon appears involved (cause unconfirmed). Change it if you know better."])
    elseif d.addon then
        v.guess:SetText(L["Your choice."])
    else
        v.guess:SetText(L["Bugsy couldn't tell which addon was involved. Choose it if you know."])
    end
    -- Fields show the draft (a rebuilt window starts empty); never overwrite while typing.
    for key, field in pairs({ description = v.describe, expected = v.expected, steps = v.steps }) do
        if not field.focused and (field.edit:GetText() or "") ~= (d[key] or "") then field:setValue(d[key]) end
    end
    v.more:setOpen(v.more.open or (d.expected ~= nil or d.steps ~= nil))
    local y = v.more:height()
    v.noVisible:ClearAllPoints()
    v.noVisible:SetPoint("TOPLEFT", v.more, "TOPLEFT", 0, -y - 8)
    v.noVisible:SetShown(p ~= nil and p ~= false)
    v.noVisible.label:SetShown(v.noVisible:IsShown())
    v.noVisible:SetChecked(d.noVisible == true)
    v.info:ClearAllPoints()
    v.info:SetPoint("TOPLEFT", v.more, "TOPLEFT", 0, -y - (v.noVisible:IsShown() and 38 or 12))
    v.info:SetText(d.mode == "problem"
        and L["The error's technical details are added automatically. You can review everything before copying."]
        or L["Your game and addon versions are added automatically. You can review everything before copying."])
    -- The scroll child's size: the width of the scroll frame, the height of everything above.
    local w = v.describeScroll:GetWidth()
    if type(w) == "number" and w > 0 then v.describeChild:SetWidth(w) end
    v.describeChild:SetHeight(heightOf(v.addonLabel, 14) + 6 + heightOf(v.picker, 26) + 4 + heightOf(v.guess, 24)
        + 12 + heightOf(v.describeLabel, 14) + 6 + heightOf(v.describe, 72) + 4 + heightOf(v.describeHelp, 12)
        + 10 + y + (v.noVisible:IsShown() and 38 or 12) + heightOf(v.info, 28) + 8)
end

local function refreshReview(v, d)
    local out = M.Render(d)
    local p = d.mode == "problem" and Store.Get(d.problemId) or nil
    local R = v.review
    local client = ns.Context.client()
    R.addon.head:SetText(L["Addon"])
    R.addon.body:SetText(addonText(d.addon) and (addonText(d.addon) .. "  ("
        .. (d.guess and L["Bugsy's reading, cause unconfirmed"] or L["your choice"]) .. ")") or L["Not chosen"])
    R.description.head:SetText(L["What you saw"])
    local said = {}
    if d.noVisible and p then said[#said + 1] = L["No visible problem noticed."] end
    if d.description then said[#said + 1] = ns.UI.escape(d.description) end
    if d.expected then said[#said + 1] = L["Expected: "] .. ns.UI.escape(d.expected) end
    if d.steps then said[#said + 1] = L["Steps: "] .. ns.UI.escape(d.steps) end
    R.description.body:SetText(#said > 0 and table.concat(said, "\n") or L["Nothing written (optional)."])
    R.attached.head:SetText(L["Attached"])
    R.attached.body:SetText(p and (L["The error \"%s\" (%d occurrences): its message, stack and Bugsy's reading."]):format(ns.UI.escape(p.title), p.count)
        or L["No error: a report from you, with your game and addon versions."])
    R.environment.head:SetText(L["Versions and environment"])
    R.environment.body:SetText(ns.UI.escape(("WoW Forever %s (%s), %s"):format(tostring(client.version), tostring(client.build), tostring(client.locale))))
    R.destination.head:SetText(L["Where to report it"])
    local dest = out.destination or {}
    R.destination.body:SetText(dest.known and ns.UI.escape(dest.url) or ReportUI.TEXT.unknownDestination)
    R.privacy.head:SetText(L["Privacy"])
    R.privacy.body:SetText(ReportUI.TEXT.privacy .. (out.localsIncluded and ("\n" .. L["It includes local variables (the setting is on)."]) or ""))
    local y = 0
    for _, key in ipairs({ "addon", "description", "attached", "environment", "destination", "privacy" }) do
        local r = R[key]
        r.head:ClearAllPoints(); r.head:SetPoint("TOPLEFT", v.reviewChild, "TOPLEFT", 0, -y); r.head:SetPoint("RIGHT", v.reviewChild, "RIGHT", 0, 0)
        y = y + 18
        r.body:ClearAllPoints(); r.body:SetPoint("TOPLEFT", v.reviewChild, "TOPLEFT", 8, -y); r.body:SetPoint("RIGHT", v.reviewChild, "RIGHT", -8, 0)
        y = y + textHeight(r.body) + 12
    end
    v.reviewFull:ClearAllPoints()
    v.reviewFull:SetPoint("TOPLEFT", v.reviewChild, "TOPLEFT", 0, -y)
    v.reviewFull:SetPoint("RIGHT", v.reviewChild, "RIGHT", 0, 0)
    v.reviewFull:SetHeight(v.reviewFull:height())
    v.reviewText:setFixed(out.error or ns.UI.escape(out.markdown or ""))
    v.reviewChild:SetHeight(y + v.reviewFull:height() + 10)
end

local function refreshCopy(v, d)
    local out = M.Render(d)
    local dest = out.destination or {}
    if dest.known then
        v.dest:SetText(L["Where to report it (from the addon's own page):"])
        v.destBox.edit.fixed = dest.url
        v.destBox:setValue(dest.url)
        v.destBox:Show()
    else
        v.dest:SetText(ReportUI.TEXT.unknownDestination)
        v.destBox:Hide()
    end
    v.formats:ClearAllPoints()
    v.formats:SetPoint("TOPLEFT", v.destBox:IsShown() and v.destBox or v.dest, "BOTTOMLEFT", 0, -12)
    v.formats:select(d.format)
    local text, err = M.CopyText(d, d.format)
    v.copyText:ClearAllPoints()
    v.copyText:SetPoint("TOPLEFT", v.formats, "BOTTOMLEFT", 0, -8)
    v.copyText:SetPoint("BOTTOMRIGHT", v.pages[3], "BOTTOMRIGHT", 0, 24)
    v.copyText:setFixed(text and ns.UI.escape(text) or (err or ""))
    v.copyText.version = d.version          -- what the box holds (a test reads it)
    v.copyHint:ClearAllPoints()
    v.copyHint:SetPoint("TOPLEFT", v.copyText, "BOTTOMLEFT", 2, -6)
    if not v.hintSelected then v.copyHint:SetText(ReportUI.TEXT.copyHint) end
end

-- Selects the whole report for Ctrl+C, re-rendered first if anything changed.
function ReportUI.SelectAll()
    local v, d = view, draft()
    if not (v and d and d.step == 3) then return end
    if v.copyText.version ~= d.version then refreshCopy(v, d) end
    if not M.CopyText(d, d.format) then return end
    v.copyText:selectAll()
    v.hintSelected = true
    v.copyHint:SetText(ReportUI.TEXT.selected)
end

function ReportUI.Refresh()
    local v, d = view, draft()
    if not v then return end
    if not d then ReportUI.Back(); return end
    local p = d.mode == "problem" and Store.Get(d.problemId)
    if d.mode == "problem" and not p then ReportUI.Back(); return end
    v.title:SetText(d.mode == "manual" and L["Report a problem"] or (d.direct and d.step == 3 and L["Copy for a bug report"] or L["Prepare a report"]))
    v.subtitle:SetText(d.mode == "manual" and L["Tell the author what isn't working."]
        or ns.UI.escape(p and p.title or ""))
    for i, page in ipairs(v.pages) do page:SetShown(i == d.step) end
    if d.step ~= 1 then v.pickerPanel:Hide() end
    if d.step ~= 3 then v.hintSelected = false end
    local C = Theme.C
    for i, b in ipairs(v.stepBtns) do
        local c = i == d.step and C.accent or C.faint
        b.circle:SetVertexColor(c[1], c[2], c[3], i == d.step and 0.9 or 0.5)
        Theme.TextColor(b.num, i == d.step and "onAccent" or "heading")   -- readable on the accent (#31)
        Theme.TextColor(b.text, i == d.step and "heading" or "muted")
    end
    if d.step == 1 then
        refreshDescribe(v, d)
        v.right:setLabel(L["Review report"])
        v.right:setActive(d.mode == "problem" or d.addon ~= nil)
        v.left:setLabel(L["Cancel"])
    elseif d.step == 2 then
        refreshReview(v, d)
        v.right:setLabel(L["Continue to copy"])
        v.right:setActive(true)
        v.left:setLabel(L["< Back"])
    else
        refreshCopy(v, d)
        v.right:setLabel(L["Select all"])
        v.right:setActive(M.CopyText(d, d.format) ~= nil)
        v.left:setLabel(L["< Back"])
    end
    -- Opened straight at Copy, the top's "< Problems" is the way back: no second one (#31).
    v.left:SetShown(not (d.direct and d.step == 3))
    v.done:SetShown(d.step == 3)
end

function ReportUI.frame() return ns.UI.frame() end
function ReportUI.view() return view end

ns._test = ns._test or {}
ns._test.ReportUI = ReportUI
