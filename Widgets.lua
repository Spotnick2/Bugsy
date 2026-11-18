-- Widgets.lua: the window's controls in the session's look (#28). Each is built through
-- Theme's surfaces while the window is built; after that, a state (hover, pressed,
-- selected, disabled) only recolours our own textures and text, never a LibGlass call.
-- Methods we add are lower-case-led or Bugsy-specific names (setLabel, setActive...) so
-- none can collide with the client's widget methods.
--
-- Every text that comes from an error or an addon goes through UI.escape before it is
-- shown (a "|" never becomes markup). Labels written here are ours.

local ADDON, ns = ...
local G, L = ns.G, ns.L
local Theme = ns.Theme
local W = {}
ns.Widgets = W

W.MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
W.HAT = W.MEDIA .. "Hat"
W.ICON = W.MEDIA .. "Icon"
W.DOT = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"   -- a round mask, tinted

local function create(...) return G("CreateFrame")(...) end

-- A font string in `font`, coloured by palette key.
function W.Text(parent, font, colorKey, justify, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH(justify or "LEFT")
    Theme.TextColor(fs, colorKey or "text")
    return fs
end

-- One line, cut with "..." rather than wrapped or overflowing its parent.
function W.Line(parent, font, colorKey, justify)
    local fs = W.Text(parent, font, colorKey, justify)
    fs:SetWordWrap(false)
    fs:SetMaxLines(1)
    return fs
end

function W.Hat(parent, size)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture(W.HAT)
    t:SetSize(size, size)
    return t
end

------------------------------------------------------------
-- Buttons and tabs
------------------------------------------------------------

local function paintState(b)
    local C = Theme.C
    local c
    if b.bugsySelected then c = C.selected
    elseif b.bugsyPressed then c = C.pressed
    elseif b.bugsyHover then c = C.hover end
    if b.state then
        if c then b.state:SetColorTexture(c[1], c[2], c[3], c[4] or 1) else b.state:SetColorTexture(0, 0, 0, 0) end
    end
    if b.label then
        local key = b.bugsyKind == "primary" and "heading" or (b.bugsySelected and "heading" or (b.bugsyKind == "quiet" and "link" or "text"))
        if b.bugsyKind == "primary" and Theme.Effective() == "glass" then key = "heading" end
        Theme.TextColor(b.label, key)
    end
end

-- kind: "primary" | "secondary" | "quiet" (text only, for links such as "< Problems").
function W.Button(parent, text, opts)
    opts = opts or {}
    local kind = opts.kind or "secondary"
    local b = create("Button", nil, parent)
    b:SetSize(opts.width or 110, opts.height or 24)
    b.bugsyKind = kind
    if kind ~= "quiet" then Theme.Control(b, kind == "primary" and "primary" or "control") end
    b.label = W.Line(b, opts.font or (kind == "primary" and "GameFontNormal" or "GameFontHighlight"), "text", "CENTER")
    b.label:SetPoint("LEFT", 6, 0)
    b.label:SetPoint("RIGHT", -6, 0)
    b.label:SetText(text)
    b:SetScript("OnEnter", function(self)
        self.bugsyHover = true; paintState(self)
        if self.tooltip then
            local tip = G("GameTooltip")
            if tip then tip:SetOwner(self, "ANCHOR_TOP"); tip:AddLine(self.tooltip, 1, 1, 1, true); tip:Show() end
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.bugsyHover, self.bugsyPressed = false, false; paintState(self)
        local tip = G("GameTooltip"); if tip and self.tooltip then tip:Hide() end
    end)
    b:SetScript("OnMouseDown", function(self) self.bugsyPressed = true; paintState(self) end)
    b:SetScript("OnMouseUp", function(self) self.bugsyPressed = false; paintState(self) end)
    b:SetScript("OnHide", function(self) self.bugsyHover, self.bugsyPressed = false, false; paintState(self) end)
    if opts.onClick then b:SetScript("OnClick", function(self, mouse) opts.onClick(self, mouse) end) end
    function b.setLabel(self, t) self.label:SetText(t) end
    function b.setActive(self, on)
        if on then self:Enable(); self:SetAlpha(1) else self:Disable(); self:SetAlpha(0.45) end
    end
    function b.setSelected(self, on) self.bugsySelected = on and true or false; paintState(self) end
    b.tooltip = opts.tooltip
    paintState(b)
    return b
end

-- A row of tabs; onSelect(key). tabs:select(key).
function W.Tabs(parent, items, onSelect, width)
    local box = create("Frame", nil, parent)
    box.buttons = {}
    local w = width or 110
    for i, it in ipairs(items) do
        local b = W.Button(box, it.label, { width = w, height = 24, onClick = function() onSelect(it.key) end })
        b:SetPoint("LEFT", box, "LEFT", (i - 1) * (w + 6), 0)
        b.key = it.key
        box.buttons[i] = b
    end
    box:SetSize(#items * w + (#items - 1) * 6, 24)
    function box.select(self, key)
        for _, b in ipairs(self.buttons) do b:setSelected(b.key == key) end
    end
    return box
end

------------------------------------------------------------
-- Badges and pills
------------------------------------------------------------

function W.Badge(parent)
    local f = create("Frame", nil, parent)
    f:SetSize(26, 16)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    Theme.Paint(bg, "badge")
    f.text = W.Text(f, "GameFontHighlightSmall", "badgeText", "CENTER")
    f.text:SetPoint("CENTER", 0, 0)
    function f.setCount(self, n)
        local s = n > 999 and "999+" or tostring(n)
        self.text:SetText(s)
        self:SetWidth(math.max(22, #s * 7 + 10))
    end
    return f
end

-- A small label on a tinted ground ("Cause unconfirmed", "Out of date", "Muted").
function W.Pill(parent, colorKey)
    local f = create("Frame", nil, parent)
    f:SetHeight(18)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints(f)
    Theme.Paint(f.bg, "pill")
    f.text = W.Text(f, "GameFontNormalSmall", colorKey or "pillText", "CENTER")
    f.text:SetPoint("CENTER", 0, 0)
    function f.setLabel(self, t, key)
        self.text:SetText(t)
        if key then Theme.TextColor(self.text, key) end
        self:SetWidth((self.text:GetStringWidth() or 60) + 16)
    end
    return f
end

------------------------------------------------------------
-- Scrolling
------------------------------------------------------------

-- A scroll frame and its child; the bar shows only when there is something to scroll.
-- The child is 10 px wide until the scroll frame's first size change gives it its width,
-- so text measured before that never wraps: onWidth (optional) lays it out again (#36).
function W.Scroll(parent, onWidth)
    local scroll = create("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    local child = create("Frame", nil, scroll)
    child:SetSize(10, 10)
    scroll:SetScrollChild(child)
    if scroll.ScrollBar then
        scroll:HookScript("OnScrollRangeChanged", function(self, _, yrange)
            self.ScrollBar:SetShown((yrange or self:GetVerticalScrollRange() or 0) > 0)
        end)
        scroll.ScrollBar:Hide()
    end
    Theme.ScrollBar(scroll)
    scroll:SetScript("OnSizeChanged", function(self, w)
        if type(w) == "number" and w > 0 and w ~= child:GetWidth() then
            child:SetWidth(w)
            if onWidth then onWidth(w) end
        end
    end)
    scroll.child = child
    return scroll, child
end

-- Read-only, selectable text in a scroll frame (technical details, the report). A typed
-- change puts the text back; Escape lets go of the keyboard.
function W.ReadOnly(parent)
    local holder = create("Frame", nil, parent)
    Theme.Pane(holder)
    -- The edit box is the scroll child itself: a multi-line edit box grows with its text,
    -- so the scroll range follows it (the old window's text box, measured in game).
    local scroll = create("ScrollFrame", nil, holder, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)
    if scroll.ScrollBar then
        scroll:HookScript("OnScrollRangeChanged", function(self, _, yrange)
            self.ScrollBar:SetShown((yrange or self:GetVerticalScrollRange() or 0) > 0)
        end)
        scroll.ScrollBar:Hide()
    end
    Theme.ScrollBar(scroll)
    local edit = create("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetMaxLetters(0)
    edit:SetWidth(300)
    scroll:SetScrollChild(edit)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self.fixed then self:SetText(self.fixed); self:HighlightText() end
    end)
    scroll:SetScript("OnSizeChanged", function(_, w)
        if type(w) == "number" and w > 0 then edit:SetWidth(w) end
    end)
    holder.scroll, holder.edit = scroll, edit
    function holder.setFixed(self, text)
        self.edit.fixed = text or ""
        self.edit:SetText(text or "")
        self.edit:SetCursorPosition(0)
    end
    function holder.selectAll(self)
        self.edit:SetFocus()
        self.edit:HighlightText()
    end
    return holder
end

------------------------------------------------------------
-- Fields
------------------------------------------------------------

-- An input on its own surface. opts: multiline, placeholder, maxLetters, onChange(text).
-- field:getValue() / field:setValue(text) (setValue never calls onChange).
function W.Field(parent, opts)
    opts = opts or {}
    local f = create("Frame", nil, parent)
    f:SetHeight(opts.multiline and (opts.height or 64) or 26)
    Theme.Control(f, "control")
    local edit
    if opts.multiline then
        local scroll = create("ScrollFrame", nil, f)
        scroll:SetPoint("TOPLEFT", 6, -5)
        scroll:SetPoint("BOTTOMRIGHT", -6, 5)
        edit = create("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        scroll:SetScrollChild(edit)
        scroll:SetScript("OnSizeChanged", function(_, w) if type(w) == "number" and w > 0 then edit:SetWidth(w) end end)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            local max = self:GetVerticalScrollRange() or 0
            local v = math.max(0, math.min(max, (self:GetVerticalScroll() or 0) - delta * 14))
            self:SetVerticalScroll(v)
        end)
        -- keep the caret in view while typing
        edit:SetScript("OnCursorChanged", function(_, _, y, _, h)
            if type(y) ~= "number" or type(h) ~= "number" then return end
            local top, height = scroll:GetVerticalScroll() or 0, scroll:GetHeight() or 0
            y = -y
            if y < top then scroll:SetVerticalScroll(y)
            elseif y + h > top + height then scroll:SetVerticalScroll(y + h - height) end
        end)
        f.scroll = scroll
    else
        edit = create("EditBox", nil, f)
        edit:SetPoint("TOPLEFT", 8, 0)
        edit:SetPoint("BOTTOMRIGHT", -8, 0)
        edit:SetScript("OnEnterPressed", function(self)
            if opts.onEnter then opts.onEnter(self:GetText()) end
            self:ClearFocus()
        end)
    end
    edit:SetAutoFocus(false)
    edit:SetFontObject(opts.font or "ChatFontNormal")
    edit:SetMaxLetters(opts.maxLetters or 0)
    edit:SetTextColor(Theme.C.fieldText[1], Theme.C.fieldText[2], Theme.C.fieldText[3])
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.placeholder = W.Text(f, "GameFontDisable", "faint")
    f.placeholder:SetPoint("TOPLEFT", 9, opts.multiline and -6 or -6)
    f.placeholder:SetPoint("RIGHT", -8, 0)
    f.placeholder:SetText(opts.placeholder or "")
    local function updatePlaceholder()
        local t = edit:GetText()
        f.placeholder:SetShown((t == nil or t == "") and not f.focused)
    end
    edit:SetScript("OnEditFocusGained", function() f.focused = true; updatePlaceholder() end)
    edit:SetScript("OnEditFocusLost", function() f.focused = false; updatePlaceholder() end)
    edit:SetScript("OnTextChanged", function(self, userInput)
        updatePlaceholder()
        if userInput and opts.onChange then opts.onChange(self:GetText()) end
    end)
    f:EnableMouse(true)
    f:SetScript("OnMouseDown", function() edit:SetFocus() end)
    f.edit = edit
    function f.getValue(self)
        local t = self.edit:GetText()
        return (type(t) == "string" and t ~= "") and t or nil
    end
    function f.setValue(self, text)
        self.edit:SetText(text or "")
        updatePlaceholder()
    end
    updatePlaceholder()
    return f
end

-- Tab and Shift+Tab through fields in order, around (as Blizzard's EditBox_OnTabPressed).
function W.ChainTab(fields)
    local boxes = {}
    for _, f in ipairs(fields) do boxes[#boxes + 1] = f.edit or f end
    for i, box in ipairs(boxes) do
        box.nextBox = boxes[i % #boxes + 1]
        box.previousBox = boxes[(i - 2) % #boxes + 1]
        box:SetScript("OnTabPressed", function(self)
            local shift = G("IsShiftKeyDown")
            local to = (shift and shift()) and self.previousBox or self.nextBox
            if to and to:IsVisible() then to:SetFocus() end
        end)
    end
end

-- A check box with a label; onChange(checked).
function W.Check(parent, text, onChange)
    local cb = create("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    if cb.text == nil then
        cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
    end
    cb.label = W.Text(parent, "GameFontHighlightSmall", "text")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.label:SetText(text)
    cb:SetScript("OnClick", function(self) if onChange then onChange(self:GetChecked() and true or false) end end)
    return cb
end

------------------------------------------------------------
-- A collapsible section: a header row and a body below it
------------------------------------------------------------

function W.Section(parent, title, onToggle)
    local s = create("Frame", nil, parent)
    s.header = W.Button(s, "", { height = 26, onClick = function()
        s.open = not s.open
        s:refreshHeader()
        if onToggle then onToggle(s.open) end
    end })
    s.header:SetPoint("TOPLEFT")
    s.header:SetPoint("TOPRIGHT")
    s.header.label:ClearAllPoints()
    s.header.label:SetPoint("LEFT", 26, 0)
    s.header.label:SetPoint("RIGHT", -8, 0)
    s.header.label:SetJustifyH("LEFT")
    s.chevron = s.header:CreateTexture(nil, "OVERLAY")
    s.chevron:SetSize(14, 14)
    s.chevron:SetPoint("LEFT", 8, 0)
    s.body = create("Frame", nil, s)
    s.body:SetPoint("TOPLEFT", s.header, "BOTTOMLEFT", 0, -4)
    s.body:SetPoint("TOPRIGHT", s.header, "BOTTOMRIGHT", 0, -4)
    s.title = title
    -- The section always has a height: anchored by TOPLEFT and RIGHT (the right *middle*)
    -- without one, the client derives it from those two points and the section lands in
    -- the wrong place (#31, seen in game: Describe's details over its other controls).
    s:SetHeight(26)
    function s.refreshHeader(self)
        self.header:setLabel(self.title)
        self.chevron:SetTexture(self.open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
        self.body:SetShown(self.open)
        self:SetHeight(self:height())
    end
    s.body:SetScript("OnSizeChanged", function() s:SetHeight(s:height()) end)
    function s.setTitle(self, t) self.title = t; self:refreshHeader() end
    function s.setOpen(self, on) self.open = on and true or false; self:refreshHeader() end
    -- The section's height: the header, and the body when open.
    function s.height(self) return 26 + (self.open and (4 + (self.body:GetHeight() or 0)) or 0) end
    s:refreshHeader()
    return s
end

------------------------------------------------------------
-- Menus: one shared popup; an outside click closes it
------------------------------------------------------------

local menu, catcher

local function closeMenu()
    if menu then menu:Hide() end
    if catcher then catcher:Hide() end
end
W.CloseMenu = closeMenu

-- items: { text, onClick, disabled, checked, note } ; a false item is a separator.
function W.Menu(anchor, items, width)
    if not menu then
        catcher = create("Button", nil, G("UIParent"))
        catcher:SetAllPoints(G("UIParent"))
        catcher:SetFrameStrata("FULLSCREEN_DIALOG")
        catcher:RegisterForClicks("AnyUp")
        catcher:SetScript("OnClick", closeMenu)
        menu = create("Frame", nil, G("UIParent"))
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:SetFrameLevel((catcher:GetFrameLevel() or 1) + 10)
        menu:SetClampedToScreen(true)
        menu:EnableMouse(true)
        local bg = menu:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(menu)
        bg:SetColorTexture(0.06, 0.06, 0.07, 0.97)
        menu.bg = bg
        menu.edgeTex = Theme.edges(menu, { 0.6, 0.55, 0.45, 0.9 })
        menu.rows = {}
        menu:SetScript("OnHide", function() if catcher then catcher:Hide() end end)
    end
    for _, r in ipairs(menu.rows) do r:Hide() end
    width = width or 200
    local y = -4
    local n = 0
    for _, it in ipairs(items) do
        n = n + 1
        local r = menu.rows[n]
        if not r then
            r = create("Button", nil, menu)
            r:SetHeight(22)
            r.hl = r:CreateTexture(nil, "HIGHLIGHT")
            r.hl:SetAllPoints(r)
            r.hl:SetColorTexture(1, 1, 1, 0.08)
            r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            r.text:SetPoint("LEFT", 22, 0)
            r.text:SetPoint("RIGHT", -8, 0)
            r.text:SetJustifyH("LEFT")
            r.text:SetWordWrap(false)
            r.check = r:CreateTexture(nil, "OVERLAY")
            r.check:SetSize(14, 14)
            r.check:SetPoint("LEFT", 5, 0)
            r.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            menu.rows[n] = r
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", menu, "TOPLEFT", 2, y)
        r:SetPoint("RIGHT", menu, "RIGHT", -2, 0)
        if it then
            r.text:SetText(it.text)
            r.check:SetShown(it.checked == true)
            if it.disabled then r:Disable(); r.text:SetTextColor(0.5, 0.5, 0.5) else r:Enable(); r.text:SetTextColor(0.95, 0.93, 0.88) end
            r:SetScript("OnClick", function() closeMenu(); if it.onClick then it.onClick() end end)
            r:SetScript("OnEnter", function(self)
                if it.note then
                    local tip = G("GameTooltip")
                    if tip then tip:SetOwner(self, "ANCHOR_RIGHT"); tip:AddLine(it.note, 1, 1, 1, true); tip:Show() end
                end
            end)
            r:SetScript("OnLeave", function() local tip = G("GameTooltip"); if tip and it.note then tip:Hide() end end)
            r:SetHeight(22)
            r:Show()
            y = y - 22
        else
            r.text:SetText("")
            r.check:Hide()
            r:Disable()
            r:SetHeight(6)
            r:Show()
            y = y - 6
        end
    end
    menu:SetSize(width, -y + 4)
    menu:ClearAllPoints()
    menu:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
    catcher:Show()
    menu:Show()
    menu.items = items
    return menu
end

function W.MenuFrame() return menu end
