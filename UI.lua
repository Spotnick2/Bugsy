-- UI.lua: Bugsy's window (#28; DESIGN §8). What matters most (the owner): seeing at a glance
-- which addon is causing problems, and copying the diagnostics in one click for a GitHub
-- issue or a CurseForge comment. Two columns: the problems (a third), the selected one
-- (two thirds); a compact header and a status footer. The report flow (ReportUI.lua) opens
-- in the same window, with a way back.
--
-- Built on first open, never automatically; no secure frames. The whole build runs under
-- one pcall on a hidden root that is published only when it succeeded (#13's R1): a glass
-- build that fails is recorded (Theme.Fail) and the window is built again in the Forever
-- look. The window's state (view, tab, search, selection, draft) lives in UI.state, not in
-- widgets, so a rebuild (a look change) keeps it.
--
-- Every string from an error or an addon goes through UI.escape ("|" never becomes markup).

local ADDON, ns = ...
local G, API, Store, Capture, Safe, L = ns.G, ns.API, ns.Store, ns.Capture, ns.Safe, ns.L
local Theme, W, M = ns.Theme, ns.Widgets, ns.Model
local UI = {}
ns.UI = UI

UI.MIN_W, UI.MIN_H = 760, 460
UI.DEFAULT_W, UI.DEFAULT_H = 900, 560
UI.HEADER, UI.FOOTER = 48, 30
UI.ROW_H = 46
UI.NAME = "BugsyFrame"

local state = {
    view = "problems", tab = "session", scope = "all", query = "", showMuted = false,
    selected = nil, open = { activity = true, tech = false, occurrences = false },
    statusOpen = false, confirmClear = false, draft = nil,
}
UI.state = state

------------------------------------------------------------
-- Text helpers (kept: other files and tests use them)
------------------------------------------------------------

-- "|" starts WoW markup; doubled, it shows as itself. (P12: Ctrl+C copies it back exactly.)
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
UI.when = when

-- The plain-text details of a problem: the Technical details section, and what
-- "Copy details" selects.
function UI.Details(p)
    local out = {}
    local function add(s) out[#out + 1] = s end
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
    return table.concat(out, "\n")
end

-- The pattern matches for a problem's newest sample (possible explanations, never a verdict).
function UI.Explanations(p)
    local newest = p.last[#p.last] or p.first[#p.first]
    if not newest then return {} end
    return ns.Patterns.match({ kind = p.kind, message = Safe.text(newest.message),
        stack = Safe.text(newest.stack), inCombat = newest.inCombat == true,
        taintLog = type(newest.taintLog) == "string" and newest.taintLog or nil,
        actionFunction = newest.event and newest.event.func }, tonumber(newest.build))
end

-- The one-line status (kept for the slash command's callers and tests).
function UI.StatusText()
    local h = M.Health()
    return h.text
end

------------------------------------------------------------
-- Building
------------------------------------------------------------

local frame          -- the published window
local building       -- the root under construction (never shown before it's complete)

local function saveGeometry(f)
    local db = Store.db()
    if not (db and f) then return end
    local left, top, w, h = f:GetLeft(), f:GetTop(), f:GetWidth(), f:GetHeight()
    if type(left) == "number" and type(top) == "number" then
        db.window = { left = math.floor(left + 0.5), top = math.floor(top + 0.5),
            w = type(w) == "number" and math.floor(w + 0.5) or nil, h = type(h) == "number" and math.floor(h + 0.5) or nil }
    end
end

local function placeWindow(f)
    local db = Store.db()
    local g = db and db.window
    local w = g and g.w and math.max(UI.MIN_W, g.w) or UI.DEFAULT_W
    local h = g and g.h and math.max(UI.MIN_H, g.h) or UI.DEFAULT_H
    f:SetSize(w, h)
    f:ClearAllPoints()
    if g and g.left and g.top then
        f:SetPoint("TOPLEFT", G("UIParent"), "BOTTOMLEFT", g.left, g.top)
    else
        f:SetPoint("CENTER")
    end
end

-- The left column's width: about a third, within bounds.
local function listWidth(f)
    local w = f:GetWidth() or UI.DEFAULT_W
    return math.max(250, math.min(360, math.floor(w * 0.34)))
end

local refreshProblems, refreshFooter, layoutDetail

local function buildHeader(f)
    local C = Theme.C
    local head = G("CreateFrame")("Frame", nil, f)
    head:SetPoint("TOPLEFT", 0, 0)
    head:SetPoint("TOPRIGHT", 0, 0)
    head:SetHeight(UI.HEADER)
    head:EnableMouse(true)
    head:RegisterForDrag("LeftButton")
    head:SetScript("OnDragStart", function() f:StartMoving() end)
    head:SetScript("OnDragStop", function() f:StopMovingOrSizing(); saveGeometry(f) end)
    local band = head:CreateTexture(nil, "BACKGROUND", nil, 1)
    band:SetAllPoints(head)
    Theme.Paint(band, "header")
    f.hat = W.Hat(head, 36)
    f.hat:SetPoint("LEFT", 12, -1)
    f.title = W.Text(head, "GameFontNormalHuge", "heading")
    f.title:SetPoint("LEFT", f.hat, "RIGHT", 8, 0)
    f.title:SetText("Bugsy")
    local sep = head:CreateTexture(nil, "ARTWORK")
    sep:SetSize(1, 20)
    sep:SetPoint("LEFT", f.title, "RIGHT", 12, 0)
    Theme.Paint(sep, "paneEdge")
    f.subtitle = W.Text(head, "GameFontHighlight", "muted")
    f.subtitle:SetPoint("LEFT", sep, "RIGHT", 12, 0)
    f.subtitle:SetText(L["Addon Bug Reporter"])

    f.closeBtn = W.Button(head, "X", { width = 28, height = 26, onClick = function() f:Hide() end, tooltip = L["Close"] })
    f.closeBtn:SetPoint("RIGHT", -10, 0)
    f.gear = W.Button(head, "", { width = 28, height = 26, tooltip = L["Settings"], onClick = function()
        if not (ns.Options and ns.Options.Open()) then ns.Bugsy.say(L["the settings are in the game's Options > AddOns > Bugsy."]) end
    end })
    f.gear:SetPoint("RIGHT", f.closeBtn, "LEFT", -6, 0)
    local cog = f.gear:CreateTexture(nil, "OVERLAY")
    cog:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    cog:SetSize(16, 16)
    cog:SetPoint("CENTER")
    f.lookBtn = W.Button(head, "", { width = 150, height = 26, tooltip = L["The window's look"], onClick = function(self)
        UI.LookMenu(self)
    end })
    f.lookBtn:SetPoint("RIGHT", f.gear, "LEFT", -8, 0)
    f.head = head
end

-- The look menu: Follow Glass UI (when it's here), WoW Forever, Pearl Glass.
function UI.LookMenu(anchor)
    local choice = Theme.Choice()
    local items = {}
    if Theme.Suite() then
        items[#items + 1] = { text = Theme.LABELS.follow, checked = choice == "follow",
            onClick = function() Theme.SetChoice("follow") end, note = L["Use Glass UI's suite theme."] }
    end
    items[#items + 1] = { text = Theme.LABELS.forever, checked = choice == "forever",
        onClick = function() Theme.SetChoice("forever") end }
    local pearlOk = Theme.PearlAvailable()
    items[#items + 1] = { text = Theme.LABELS.pearl, checked = choice == "pearl", disabled = not pearlOk,
        onClick = function() Theme.SetChoice("pearl") end,
        note = (not pearlOk) and L["Pearl Glass needs a Glass addon (Glass UI, for example) loaded."] or nil }
    return W.Menu(anchor, items, 190)
end

local function buildFooter(f)
    local foot = G("CreateFrame")("Frame", nil, f)
    foot:SetPoint("BOTTOMLEFT", 0, 0)
    foot:SetPoint("BOTTOMRIGHT", 0, 0)
    foot:SetHeight(UI.FOOTER)
    local band = foot:CreateTexture(nil, "BACKGROUND", nil, 1)
    band:SetAllPoints(foot)
    Theme.Paint(band, "header")
    f.statusBtn = G("CreateFrame")("Button", nil, foot)
    f.statusBtn:SetPoint("LEFT", 12, 0)
    f.statusBtn:SetPoint("RIGHT", foot, "RIGHT", -150, 0)
    f.statusBtn:SetHeight(UI.FOOTER)
    f.dot = f.statusBtn:CreateTexture(nil, "ARTWORK")
    f.dot:SetTexture(W.DOT)
    f.dot:SetSize(10, 10)
    f.dot:SetPoint("LEFT", 0, 0)
    f.statusText = W.Line(f.statusBtn, "GameFontHighlightSmall", "text")
    f.statusText:SetPoint("LEFT", f.dot, "RIGHT", 8, 0)
    f.statusText:SetPoint("RIGHT", 0, 0)
    f.statusBtn:SetScript("OnClick", function() state.statusOpen = not state.statusOpen; refreshFooter() end)
    f.manage = W.Button(foot, L["Manage"], { kind = "quiet", width = 110, height = 22, onClick = function(self) UI.ManageMenu(self) end })
    f.manage:SetPoint("RIGHT", -12, 0)

    -- The status details, above the footer (capture mode, limits, look failures).
    f.statusPanel = G("CreateFrame")("Frame", nil, f)
    f.statusPanel:SetPoint("BOTTOMLEFT", foot, "TOPLEFT", 10, 4)
    f.statusPanel:SetPoint("BOTTOMRIGHT", foot, "TOPRIGHT", -10, 4)
    f.statusPanel:SetHeight(120)
    f.statusPanel:SetFrameLevel((f:GetFrameLevel() or 1) + 40)
    local bg = f.statusPanel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f.statusPanel)
    bg:SetColorTexture(0.04, 0.04, 0.05, 0.97)
    Theme.edges(f.statusPanel, Theme.C.paneEdge)
    f.statusPanel.text = W.Text(f.statusPanel, "GameFontHighlightSmall", "text")
    f.statusPanel.text:SetPoint("TOPLEFT", 10, -8)
    f.statusPanel.text:SetPoint("RIGHT", -10, 0)
    f.statusPanel:Hide()

    -- Clearing everything asks first, in the footer.
    f.confirm = G("CreateFrame")("Frame", nil, foot)
    f.confirm:SetAllPoints(foot)
    f.confirm:SetFrameLevel((foot:GetFrameLevel() or 1) + 5)
    local cbg = f.confirm:CreateTexture(nil, "BACKGROUND")
    cbg:SetAllPoints(f.confirm)
    cbg:SetColorTexture(0.25, 0.04, 0.03, 0.95)
    f.confirm.text = W.Line(f.confirm, "GameFontHighlightSmall", "text")
    f.confirm.text:SetPoint("LEFT", 12, 0)
    f.confirm.yes = W.Button(f.confirm, L["Clear all"], { width = 90, height = 22, onClick = function()
        state.confirmClear = false
        Store.Clear("all")
        state.selected = nil
        UI.Refresh()
    end })
    f.confirm.no = W.Button(f.confirm, L["Cancel"], { width = 80, height = 22, onClick = function()
        state.confirmClear = false; refreshFooter()
    end })
    f.confirm.no:SetPoint("RIGHT", -12, 0)
    f.confirm.yes:SetPoint("RIGHT", f.confirm.no, "LEFT", -8, 0)
    f.confirm.text:SetPoint("RIGHT", f.confirm.yes, "LEFT", -10, 0)
    f.confirm:Hide()
    f.foot = foot
end

-- Manage: clearing, and the less frequent actions.
function UI.ManageMenu(anchor)
    local p = state.selected and Store.Get(state.selected)
    local items = {
        { text = L["Clear this problem"], disabled = not p, onClick = function()
            if p then Store.Clear(p.id); state.selected = nil; UI.Refresh() end
        end },
        { text = L["Clear this session's problems"], onClick = function()
            Store.Clear("session"); state.selected = nil; UI.Refresh()
        end },
        { text = L["Clear all problems..."], onClick = function()
            state.confirmClear = true; refreshFooter()
        end, note = L["Every stored problem and its history. Asks first."] },
        false,
        { text = L["Report a problem"], onClick = function() if ns.ReportUI then ns.ReportUI.OpenManual() end end },
        { text = L["Settings"], onClick = function() if ns.Options then ns.Options.Open() end end },
    }
    return W.Menu(anchor, items, 230)
end

local function setRowSelected(row, on, muted)
    local C = Theme.C
    if on then
        row.bg:SetColorTexture(C.selected[1], C.selected[2], C.selected[3], C.selected[4])
        for _, e in ipairs(row.edge) do e:SetColorTexture(C.selectedEdge[1], C.selectedEdge[2], C.selectedEdge[3], C.selectedEdge[4]) end
    else
        row.bg:SetColorTexture(0, 0, 0, 0)
        for _, e in ipairs(row.edge) do e:SetColorTexture(0, 0, 0, 0) end
    end
    row:SetAlpha(muted and 0.55 or 1)
end

local function makeRow(f, parent)
    local row = G("CreateFrame")("Button", nil, parent)
    row:SetHeight(UI.ROW_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    row.edge = Theme.edges(row, { 0, 0, 0, 0 }, "BORDER")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    local hc = Theme.C.hover
    hl:SetColorTexture(hc[1], hc[2], hc[3], hc[4])
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(28, 28)
    row.icon:SetPoint("LEFT", 8, 0)
    row.addon = W.Line(row, "GameFontNormal", "heading")
    row.addon:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 2)
    row.badge = W.Badge(row)
    row.badge:SetPoint("TOPRIGHT", -8, -6)
    row.addon:SetPoint("RIGHT", row.badge, "LEFT", -6, 0)
    row.time = W.Line(row, "GameFontHighlightSmall", "muted", "RIGHT")
    row.time:SetPoint("BOTTOMRIGHT", -8, 7)
    row.summary = W.Line(row, "GameFontHighlightSmall", "text")
    row.summary:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, -1)
    row.summary:SetPoint("RIGHT", row.time, "LEFT", -6, 0)
    row:SetScript("OnClick", function(self) state.selected = self.id; UI.Refresh() end)
    return row
end

local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function buildProblems(f, body)
    local view = G("CreateFrame")("Frame", nil, body)
    view:SetAllPoints(body)
    f.views.problems = view

    local left = G("CreateFrame")("Frame", nil, view)
    left:SetPoint("TOPLEFT", 10, -8)
    left:SetPoint("BOTTOMLEFT", 10, 8)
    left:SetWidth(listWidth(f))
    f.left = left
    f.tabs = W.Tabs(left, { { key = "session", label = L["This session"] }, { key = "history", label = L["History"] } },
        function(key) state.tab = key; UI.Refresh() end, 118)
    f.tabs:SetPoint("TOPLEFT", 0, 0)
    f.search = W.Field(left, { placeholder = L["Search problems..."], onChange = function(text)
        state.query = text or ""; UI.Refresh()
    end })
    -- A rebuilt window (a look change) keeps the filter, so it shows it too (Codex, #30).
    if state.query and state.query ~= "" then f.search:setValue(state.query) end
    f.search:SetPoint("TOPLEFT", f.tabs, "BOTTOMLEFT", 0, -8)
    f.search:SetPoint("RIGHT", left, "RIGHT", 0, 0)
    f.count = W.Line(left, "GameFontNormalSmall", "heading")
    f.count:SetPoint("TOPLEFT", f.search, "BOTTOMLEFT", 2, -10)
    f.mutedBtn = W.Button(left, "", { kind = "quiet", width = 120, height = 18, font = "GameFontHighlightSmall",
        onClick = function() state.showMuted = not state.showMuted; UI.Refresh() end })
    f.mutedBtn:SetPoint("TOPRIGHT", f.search, "BOTTOMRIGHT", 0, -6)
    f.scopeBtn = W.Button(left, "", { kind = "quiet", width = 120, height = 18, font = "GameFontHighlightSmall",
        onClick = function() state.scope = state.scope == "previous" and "all" or "previous"; UI.Refresh() end })
    f.scopeBtn:SetPoint("RIGHT", f.mutedBtn, "LEFT", -4, 0)
    f.reportBtn = W.Button(left, L["Report a problem"], { height = 26, onClick = function()
        if ns.ReportUI then ns.ReportUI.OpenManual() end
    end, tooltip = L["Something isn't working, but no error was caught."] })
    f.reportBtn:SetPoint("BOTTOMLEFT", 0, 0)
    f.reportBtn:SetPoint("BOTTOMRIGHT", 0, 0)
    local listHolder = G("CreateFrame")("Frame", nil, left)
    listHolder:SetPoint("TOPLEFT", f.count, "BOTTOMLEFT", -2, -8)
    listHolder:SetPoint("BOTTOMRIGHT", f.reportBtn, "TOPRIGHT", 0, 8)
    f.listScroll, f.listChild = W.Scroll(listHolder)
    f.listScroll:SetPoint("TOPLEFT")
    f.listScroll:SetPoint("BOTTOMRIGHT", -20, 0)
    f.rows = {}
    f.listEmpty = W.Text(listHolder, "GameFontHighlightSmall", "muted")
    f.listEmpty:SetPoint("TOPLEFT", 6, -6)
    f.listEmpty:SetPoint("RIGHT", -6, 0)

    -- The selected problem.
    local right = G("CreateFrame")("Frame", nil, view)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 12, 0)
    right:SetPoint("BOTTOMRIGHT", -10, 8)
    f.right = right
    local divider = view:CreateTexture(nil, "ARTWORK")
    divider:SetWidth(1)
    divider:SetPoint("TOP", left, "TOPRIGHT", 6, 0)
    divider:SetPoint("BOTTOM", left, "BOTTOMRIGHT", 6, 0)
    Theme.Paint(divider, "paneEdge")

    f.actions = G("CreateFrame")("Frame", nil, right)
    f.actions:SetPoint("BOTTOMLEFT")
    f.actions:SetPoint("BOTTOMRIGHT")
    f.actions:SetHeight(28)
    f.copyBtn = W.Button(f.actions, L["Copy for a bug report"], { kind = "primary", width = 190, height = 28,
        tooltip = L["The diagnostics, ready to paste in a GitHub issue or a CurseForge comment."],
        onClick = function() if state.selected and ns.ReportUI then ns.ReportUI.OpenCopy(state.selected) end end })
    f.copyBtn:SetPoint("LEFT", 0, 0)
    f.describeBtn = W.Button(f.actions, L["Prepare report"], { width = 130, height = 28,
        tooltip = L["Add what you were doing, then copy it all."],
        onClick = function() if state.selected and ns.ReportUI then ns.ReportUI.OpenFor(state.selected) end end })
    f.describeBtn:SetPoint("LEFT", f.copyBtn, "RIGHT", 8, 0)
    f.muteBtn = W.Button(f.actions, L["Mute"], { width = 80, height = 28, onClick = function()
        local p = state.selected and Store.Get(state.selected)
        if p then Store.SetMuted(p.id, not p.muted) end
        UI.Refresh()
    end, tooltip = L["Stop counting it as new: no chat line, no sound."] })
    f.muteBtn:SetPoint("LEFT", f.describeBtn, "RIGHT", 8, 0)
    f.moreBtn = W.Button(f.actions, "...", { width = 36, height = 28, tooltip = L["More"], onClick = function(self)
        W.Menu(self, {
            { text = L["Copy details"], onClick = function() UI.CopyDetails() end },
            { text = L["Clear this problem"], onClick = function()
                if state.selected then Store.Clear(state.selected); state.selected = nil; UI.Refresh() end
            end },
        }, 180)
    end })
    f.moreBtn:SetPoint("LEFT", f.muteBtn, "RIGHT", 8, 0)

    f.detailHolder = G("CreateFrame")("Frame", nil, right)
    f.detailHolder:SetPoint("TOPLEFT")
    f.detailHolder:SetPoint("BOTTOMRIGHT", f.actions, "TOPRIGHT", 0, 8)
    f.detailScroll, f.detail = W.Scroll(f.detailHolder)
    f.detailScroll:SetPoint("TOPLEFT")
    f.detailScroll:SetPoint("BOTTOMRIGHT", -22, 0)
    local d = f.detail
    d.involvedLabel = W.Line(d, "GameFontNormalSmall", "accent")
    d.icon = d:CreateTexture(nil, "ARTWORK")
    d.icon:SetSize(24, 24)
    d.addon = W.Line(d, "GameFontNormalLarge", "heading")
    d.stale = W.Pill(d, "pillText")
    d.mutedPill = W.Pill(d, "muted")
    d.title = W.Text(d, "GameFontHighlightLarge", "text")
    d.title:SetMaxLines(3)
    d.meta = W.Text(d, "GameFontHighlightSmall", "muted")
    d.confidence = W.Pill(d, "pillText")
    d.note = W.Text(d, "GameFontHighlightSmall", "warn")
    d.explain = W.Text(d, "GameFontHighlightSmall", "text")
    d.sections = {}
    d.sections.activity = W.Section(d, L["Recent activity"], function(open) state.open.activity = open; layoutDetail() end)
    d.activityText = W.Text(d.sections.activity.body, "GameFontHighlightSmall", "text")
    d.activityText:SetPoint("TOPLEFT", 10, -2)
    d.activityText:SetPoint("RIGHT", -10, 0)
    d.sections.tech = W.Section(d, L["Technical details"], function(open) state.open.tech = open; layoutDetail() end)
    d.tech = W.ReadOnly(d.sections.tech.body)
    d.tech:SetPoint("TOPLEFT")
    d.tech:SetPoint("TOPRIGHT")
    d.tech:SetHeight(220)
    d.sections.tech.body:SetHeight(224)
    d.copyHint = W.Text(d, "GameFontHighlightSmall", "accent")
    d.sections.occurrences = W.Section(d, L["Occurrences"], function(open) state.open.occurrences = open; layoutDetail() end)
    d.occText = W.Text(d.sections.occurrences.body, "GameFontHighlightSmall", "text")
    d.occText:SetPoint("TOPLEFT", 10, -2)
    d.occText:SetPoint("RIGHT", -10, 0)

    -- The empty state, over the selected problem's column.
    local empty = G("CreateFrame")("Frame", nil, right)
    empty:SetAllPoints(right)
    empty.hat = W.Hat(empty, 96)
    empty.hat:SetPoint("TOP", 0, -50)
    empty.title = W.Text(empty, "GameFontNormalLarge", "heading", "CENTER")
    empty.title:SetPoint("TOP", empty.hat, "BOTTOM", 0, -14)
    empty.title:SetWidth(420)
    empty.line = W.Text(empty, "GameFontHighlight", "muted", "CENTER")
    empty.line:SetPoint("TOP", empty.title, "BOTTOM", 0, -8)
    empty.line:SetWidth(420)
    empty.question = W.Text(empty, "GameFontHighlightSmall", "text", "CENTER")
    empty.question:SetPoint("TOP", empty.line, "BOTTOM", 0, -26)
    empty.action = W.Button(empty, L["Report a problem"], { kind = "primary", width = 180, height = 28, onClick = function()
        if empty.onAction then empty.onAction() end
    end })
    empty.action:SetPoint("TOP", empty.question, "BOTTOM", 0, -10)
    f.empty = empty
end

local function buildWindow()
    local create = G("CreateFrame")
    local f = create("Frame", nil, G("UIParent"))
    f:Hide()
    building = f
    f:SetFrameStrata("DIALOG")          -- over unit frames and bars (#31, seen in game at HIGH)
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetResizable(true)
    pcall(f.SetResizeBounds, f, UI.MIN_W, UI.MIN_H)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    placeWindow(f)
    Theme.Window(f, UI.HEADER)
    f.views = {}
    buildHeader(f)
    buildFooter(f)
    local body = create("Frame", nil, f)
    body:SetPoint("TOPLEFT", f.head, "BOTTOMLEFT", 0, 0)
    body:SetPoint("BOTTOMRIGHT", f.foot, "TOPRIGHT", 0, 0)
    f.body = body
    buildProblems(f, body)
    if ns.ReportUI then ns.ReportUI.Build(f, body) end
    -- Resizing from the corner.
    local grip = create("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing(); saveGeometry(f); UI.Refresh() end)
    f.grip = grip
    f:SetScript("OnSizeChanged", function(self)
        if self.left then self.left:SetWidth(listWidth(self)) end
        if self:IsShown() and layoutDetail then layoutDetail() end
    end)
    f:SetScript("OnShow", function() UI.Refresh() end)
    f:SetScript("OnHide", function() W.CloseMenu(); state.statusOpen = false; state.confirmClear = false end)
    f.look = Theme.Effective()
    building = nil
    return f
end

local specialAdded
local function publish(f)
    frame = f
    _G[UI.NAME] = f                                  -- a published alias (#13's R1), for Escape and /fstack
    local special = G("UISpecialFrames")
    if type(special) == "table" and not specialAdded then
        specialAdded = true
        table.insert(special, UI.NAME)               -- Escape closes it, as Blizzard's panels
    end
end

-- Builds the window in the session's look; a failed glass build is recorded and the
-- window is built once more in the Forever look.
function UI.Build()
    local look = Theme.Effective()
    local ok, f = pcall(buildWindow)
    if not ok then
        if building then building:Hide(); building = nil end
        if look ~= "glass" then error(f, 0) end      -- a Forever build failing is a bug: Bugsy catches it
        Theme.Fail("window", f)
        ok, f = pcall(buildWindow)
        if not ok then
            if building then building:Hide(); building = nil end
            error(f, 0)
        end
    end
    publish(f)
    return f
end

-- After a look change: the window again, its state kept, shown if it was.
function UI.Rebuild()
    if not frame then return end
    local was = frame:IsShown()
    saveGeometry(frame)
    W.CloseMenu()
    frame:Hide()
    frame = nil
    UI.Build()
    if was then frame:Show() end
end

------------------------------------------------------------
-- Refreshing
------------------------------------------------------------

local function sizeOf(fs, fallback)
    local h = fs.GetStringHeight and fs:GetStringHeight()
    return (type(h) == "number" and h > 0) and h or (fallback or 14)
end

local function rowFor(f, i)
    local row = f.rows[i]
    if not row then
        row = makeRow(f, f.listChild)
        f.rows[i] = row
    end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", f.listChild, "TOPLEFT", 0, -(i - 1) * (UI.ROW_H + 2))
    row:SetPoint("RIGHT", f.listChild, "RIGHT", 0, 0)
    return row
end

local EMPTY = {
    none = { L["No problems detected this session"], L["Bugsy's keeping watch."] },
    noneHistory = { L["No problems recorded"], L["Bugsy's keeping watch."] },
    noResults = { L["No problems match your search"], L["Try another addon name or a word from the error."] },
    onlyMuted = { L["Only muted problems here"], L["Muted problems are hidden. Show them to look again."] },
    interrupted = { L["Bugsy may not be catching errors"], "" },
}

local function refreshEmpty(f, kind, health)
    local e = f.empty
    local key = (kind == "none" and state.tab == "history") and "noneHistory" or kind
    e.title:SetText(EMPTY[key][1])
    e.line:SetText(kind == "interrupted" and UI.escape(health.text) or EMPTY[key][2])
    if kind == "none" or kind == "interrupted" then
        e.question:SetText(L["Something still isn't working?"])
        e.action:setLabel(L["Report a problem"])
        e.onAction = function() if ns.ReportUI then ns.ReportUI.OpenManual() end end
    elseif kind == "noResults" then
        e.question:SetText("")
        e.action:setLabel(L["Clear search"])
        e.onAction = function() state.query = ""; f.search:setValue(""); UI.Refresh() end
    else
        e.question:SetText("")
        e.action:setLabel(L["Show muted"])
        e.onAction = function() state.showMuted = true; UI.Refresh() end
    end
    Theme.TextColor(e.title, kind == "interrupted" and "warn" or "heading")
end

-- Lays the selected problem's column out top to bottom (wrapped texts, open sections).
function layoutDetail()
    local f = frame
    if not (f and f.detail) then return end
    local d = f.detail
    local y = -2
    local function place(el, h, x)
        el:ClearAllPoints()
        el:SetPoint("TOPLEFT", d, "TOPLEFT", x or 0, y)
        el:SetPoint("RIGHT", d, "RIGHT", -4, 0)
        y = y - h
    end
    d.involvedLabel:ClearAllPoints()
    d.involvedLabel:SetPoint("TOPLEFT", d, "TOPLEFT", 0, y)
    y = y - 16
    d.icon:ClearAllPoints()
    d.icon:SetPoint("TOPLEFT", d, "TOPLEFT", 0, y)
    d.addon:ClearAllPoints()
    d.addon:SetPoint("LEFT", d.icon, "RIGHT", 8, 0)
    d.stale:ClearAllPoints()
    d.stale:SetPoint("LEFT", d.addon, "RIGHT", 10, 0)
    d.mutedPill:ClearAllPoints()
    d.mutedPill:SetPoint("LEFT", d.stale:IsShown() and d.stale or d.addon, "RIGHT", 6, 0)
    y = y - 30
    place(d.title, sizeOf(d.title, 18) + 6)
    place(d.meta, sizeOf(d.meta) + 8)
    d.confidence:ClearAllPoints()
    if d.confidence:IsShown() then
        d.confidence:SetPoint("TOPLEFT", d, "TOPLEFT", 0, y)
        y = y - 26
    end
    if d.note:IsShown() then place(d.note, sizeOf(d.note) + 8) end
    if d.explain:IsShown() then place(d.explain, sizeOf(d.explain) + 10) end
    for _, key in ipairs({ "activity", "tech", "occurrences" }) do
        local s = d.sections[key]
        if s:IsShown() then
            if key == "activity" then s.body:SetHeight(sizeOf(d.activityText) + 6) end
            if key == "occurrences" then s.body:SetHeight(sizeOf(d.occText) + 6) end
            place(s, s:height())
            s:SetHeight(s:height())
            y = y - 6
            if key == "tech" and d.copyHint:IsShown() then place(d.copyHint, sizeOf(d.copyHint) + 6) end
        end
    end
    d:SetHeight(-y + 10)
end

local function refreshDetail(f, p)
    local d = f.detail
    local name, how, confidence = M.AddonOf(p)
    d.involvedLabel:SetText(how == "named" and L["NAMED BY WOW"] or (name and L["APPEARS INVOLVED"] or L["SOURCE UNKNOWN"]))
    d.icon:SetTexture(M.Icon(name) or DEFAULT_ICON)
    d.addon:SetText(UI.escape(name and M.Title(name) or L["Unknown source"]))
    local stale, iface, client = M.Staleness(name)
    if stale then
        d.stale:setLabel(stale == "old" and L["Out of date"] or L["Made for another version"], "warn")
        d.stale:Show()
    else
        d.stale:Hide()
    end
    if p.muted then d.mutedPill:setLabel(L["Muted"], "muted"); d.mutedPill:Show() else d.mutedPill:Hide() end
    d.title:SetText(UI.escape(p.title))
    local sessionCount, allCount = M.AddonCounts(name)
    local meta = (p.countIncomplete and L["at least %d occurrences"] or (p.count == 1 and L["%d occurrence"] or L["%d occurrences"])):format(p.count)
        .. "  ·  " .. (L["last seen %s"]):format(M.Ago(p.lastSeen))
    if (p.sessionCount or 1) > 1 then meta = meta .. "  ·  " .. (L["in %d sessions"]):format(p.sessionCount) end
    if name and allCount > 1 then meta = meta .. "\n" .. (L["%s has %d problems stored (%d this session)."]):format(UI.escape(M.Title(name)), allCount, sessionCount) end
    d.meta:SetText(meta)
    -- Confidence, never more certain than the evidence.
    if how == "suspect" then
        d.confidence:setLabel(confidence == "high" and L["Likely involved"] or L["Cause unconfirmed"], "pillText")
        d.confidence:Show()
    elseif how == "named" then
        d.confidence:setLabel(L["Named by the game; cause unconfirmed"], "pillText")
        d.confidence:Show()
    else
        d.confidence:Hide()
    end
    -- After a patch day: a suggestion, never an action taken for the player.
    if stale == "old" then
        d.note:SetText((L["%s was made for an older version of the game (interface %d; this client is %d). If it keeps failing, you could turn it off in the AddOns list (Esc > AddOns) until its author updates it."])
            :format(UI.escape(M.Title(name)), iface, client))
        d.note:Show()
    elseif stale == "other" then
        d.note:SetText((L["%s was made for another version of the game (interface %d; this client is %d)."])
            :format(UI.escape(M.Title(name)), iface, client))
        d.note:Show()
    else
        d.note:Hide()
    end
    local ex = UI.Explanations(p)
    if #ex > 0 then
        local lines = {}
        for _, m in ipairs(ex) do lines[#lines + 1] = L["Possible explanation (not a diagnosis): "] .. UI.escape(m.summary) end
        d.explain:SetText(table.concat(lines, "\n"))
        d.explain:Show()
    else
        d.explain:Hide()
    end
    -- Recent activity: only what an author's breadcrumbs recorded; never invented.
    local newest = p.last[#p.last] or p.first[#p.first]
    local crumbs = newest and type(newest.breadcrumbs) == "table" and newest.breadcrumbs or nil
    if crumbs and #crumbs > 0 then
        local lines = {}
        for i = math.max(1, #crumbs - 9), #crumbs do
            local c = crumbs[i]
            local text = type(c) == "table" and (Safe.text(c.text) or Safe.text(c.message)) or Safe.text(c)
            if text then lines[#lines + 1] = UI.escape(text) .. ((type(c) == "table" and type(c.at) == "number") and ("  |cff999999" .. M.Ago(c.at) .. "|r") or "") end
        end
        d.activityText:SetText(table.concat(lines, "\n"))
        d.sections.activity:Show()
        d.sections.activity:setOpen(state.open.activity)
    else
        d.sections.activity:Hide()
    end
    d.tech:setFixed(UI.escape(UI.Details(p)))
    d.copyHint:SetShown(state.copyHintFor == p.id)
    d.sections.tech:setOpen(state.open.tech)
    local samples = {}
    for _, s in ipairs(p.first) do samples[#samples + 1] = s end
    for _, s in ipairs(p.last) do samples[#samples + 1] = s end
    local occ = {}
    for i = #samples, 1, -1 do
        local s = samples[i]
        occ[#occ + 1] = ("%s  ·  %s%s"):format(when(s.at), (L["session %s"]):format(tostring(s.session or "?")),
            s.inCombat == true and ("  ·  " .. L["in combat"]) or "")
    end
    if (p.sampledOut or 0) > 0 then occ[#occ + 1] = (L["%d more counted but not kept"]):format(p.sampledOut) end
    d.occText:SetText(table.concat(occ, "\n"))
    d.sections.occurrences:setTitle((L["Occurrences (%d)"]):format(p.count))
    d.sections.occurrences:setOpen(state.open.occurrences)
    f.muteBtn:setLabel(p.muted and L["Unmute"] or L["Mute"])
    layoutDetail()
end

function refreshProblems()
    local f = frame
    local health = M.Health()
    local list, info = M.Visible(state.tab, state.scope, state.query, state.showMuted)
    state.selected = M.KeepSelection(list, state.selected)
    f.tabs:select(state.tab)
    f.count:SetText(#list == 1 and L["1 problem"] or (L["%d problems"]):format(#list))
    f.mutedBtn:setLabel(state.showMuted and L["Hide muted"] or (L["Show muted (%d)"]):format(info.muted))
    f.mutedBtn:SetShown(state.showMuted or info.muted > 0)
    f.scopeBtn:setLabel(state.scope == "previous" and L["Previous session"] or L["All sessions"])
    f.scopeBtn:SetShown(state.tab == "history")
    for i, p in ipairs(list) do
        local row = rowFor(f, i)
        row.id = p.id
        local name = M.AddonOf(p)
        row.icon:SetTexture(M.Icon(name) or DEFAULT_ICON)
        local label = UI.escape(name and M.Title(name) or L["Unknown source"])
        if M.Staleness(name) == "old" then label = label .. "  |cffffb84d" .. L["out of date"] .. "|r" end
        row.addon:SetText(label)
        row.summary:SetText(UI.escape(p.title))
        row.badge:setCount(p.count)
        row.time:SetText((p.muted and (L["muted"] .. " · ") or "") .. M.Ago(p.lastSeen))
        setRowSelected(row, p.id == state.selected, p.muted)
        row:Show()
    end
    for i = #list + 1, #f.rows do f.rows[i]:Hide(); f.rows[i].id = nil end
    f.listChild:SetHeight(math.max(1, #list * (UI.ROW_H + 2)))
    local kind = M.EmptyKind(list, info, health)
    state.emptyKind = kind
    f.listEmpty:SetShown(kind ~= nil)
    if kind then
        f.listEmpty:SetText(kind == "noResults" and L["Nothing matches."] or (kind == "onlyMuted" and L["Only muted problems."] or ""))
        refreshEmpty(f, kind, health)
        f.empty:Show()
        f.detailHolder:Hide()
        f.actions:Hide()
    else
        f.empty:Hide()
        f.detailHolder:Show()
        f.actions:Show()
        local p = Store.Get(state.selected)
        if p then refreshDetail(f, p) end
    end
end

function refreshFooter()
    local f = frame
    if not f then return end
    local h = M.Health()
    local C = Theme.C
    local c = h.level == "ok" and C.ok or (h.level == "warn" and C.warn or C.bad)
    f.dot:SetVertexColor(c[1], c[2], c[3])
    f.statusText:SetText(UI.escape(h.text))
    if state.statusOpen then
        local lines = {}
        for _, l in ipairs(h.lines) do lines[#lines + 1] = UI.escape(l) end
        local look, note = Theme.Describe()
        lines[#lines + 1] = L["Look: "] .. look .. (note and (" - " .. note) or "")
        for _, fl in ipairs(Theme.Failures()) do lines[#lines + 1] = L["Look failure: "] .. UI.escape(fl.text) end
        f.statusPanel.text:SetText(table.concat(lines, "\n"))
        f.statusPanel:SetHeight(sizeOf(f.statusPanel.text, 60) + 18)
        f.statusPanel:Show()
    else
        f.statusPanel:Hide()
    end
    if state.confirmClear then
        local n = #Store.List("all", true)
        f.confirm.text:SetText((L["Clear all %d stored problems and their history?"]):format(n))
        f.confirm:Show()
    else
        f.confirm:Hide()
    end
    local look = Theme.Describe()
    f.lookBtn:setLabel(look)
end

function UI.Refresh()
    if not (frame and frame:IsShown()) then return end
    for name, v in pairs(frame.views) do v:SetShown(name == state.view) end
    if state.view == "problems" then
        refreshProblems()
    elseif ns.ReportUI then
        ns.ReportUI.Refresh()
    end
    refreshFooter()
end

-- Opens the technical details, selected for Ctrl+C.
function UI.CopyDetails()
    local f = frame
    if not (f and state.selected) then return end
    state.open.tech = true
    state.copyHintFor = state.selected
    f.detail.sections.tech:setOpen(true)
    f.detail.copyHint:SetText(L["Selected: press Ctrl+C to copy."])
    f.detail.copyHint:Show()
    layoutDetail()
    f.detail.tech:selectAll()
end

function UI.ShowView(name)
    state.view = name
    if frame then UI.Refresh() end
end

------------------------------------------------------------
-- Opening
------------------------------------------------------------

local function ensure()
    pcall(Capture.check, "window")
    if not frame then UI.Build() end
end

function UI.Toggle()
    ensure()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- Shown, never toggled (the Options page's "Open Bugsy", #22).
function UI.Show()
    ensure()
    frame:Show()
    UI.Refresh()
end

function UI.ShowProblem(id)
    ensure()
    state.view, state.selected = "problems", id
    frame:Show()
    UI.Refresh()
end

function UI.frame() return frame end

ns._test = ns._test or {}
ns._test.UI = UI
