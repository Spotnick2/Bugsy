-- Theme.lua: the look of Bugsy's window (#28; #13's design, agreed with Codex, reviewed by
-- Fable). Two looks over one layout: "forever" (native WoW art and colours) and "glass"
-- (LibGlass-1.0's reflective shell, Pearl by default).
--
-- LibGlass is BORROWED, never embedded (the owner's decision on #26): `!Bugsy` loads
-- before every other addon, so an embedded copy would become the copy the whole client
-- runs. Pearl is offered when another addon brought LibGlass r11 or newer (Glass UI always
-- does); otherwise the choice says it needs a Glass addon.
--
-- Choice: "follow" (Glass UI's suite theme, when Glass UI is loaded; every member follows
-- by default), or the own look, "forever" or "pearl" (settings.look, settings.followGlassUI).
-- Decided at PLAYER_LOGIN (every startup addon loaded) and again when the player changes it
-- in the window or the settings: the window is then rebuilt with its state kept (a suite
-- change made on Glass UI's page waits for a /reload: reported live = false).
--
-- Glass UI's contract (GlassUI docs/SUITE.md, API 1): Bugsy reports what it built every
-- time it asked, including after a normal "not following" answer (or Glass UI's card
-- would say "asked, but no report"), and again when a build fails later. `built` is only a
-- FOLLOWED preset; an own Pearl is built = nil; `declined` names the own look when
-- Bugsy's switch is off. Tint and accent are Bugsy's own in this version (`own`).
--
-- Safety: LibGlass is called only while a window is being built (Theme.Window/Pane/Control),
-- under the window's single pcall (UI.lua). After the build, states (hover, pressed,
-- selected, disabled) change only our own textures and colours, never a LibGlass call.
-- A failed build records the failure, gives up glass for the session, and the window is
-- built again in the Forever look. Nothing here runs on the capture path.

local ADDON, ns = ...
local G, Safe, L = ns.G, ns.Safe, ns.L
local Theme = {}
ns.Theme = Theme

Theme.MIN_LIBGLASS = 11
Theme.CHOICES = { "follow", "forever", "pearl" }
Theme.LABELS = { follow = L["Follow Glass UI"], forever = L["WoW Forever"], pearl = L["Pearl Glass"] }
-- Our own look's name in Glass UI's report: data for Glass UI's page, so English.
local REPORT_LABEL = { forever = "WoW Forever", pearl = "Pearl" }
Theme.FAILURES_MAX = 5

local effective = "forever"   -- what windows are built in: "forever" | "glass"
local following = false      -- the session's look comes from Glass UI's suite theme
local Glass, glassPreset, glassMinor
local glassBroken             -- a glass build failed this session: Forever from then on
local buildReason             -- why a wanted glass look wasn't built ("library-too-old", ...)
local failures = {}           -- bounded: { op, text, at }

------------------------------------------------------------
-- Palettes (one per look; Theme.C is the current one)
------------------------------------------------------------

local FOREVER = {
    text = { 0.93, 0.89, 0.80 }, heading = { 1, 0.82, 0 }, muted = { 0.64, 0.60, 0.52 },
    faint = { 0.45, 0.42, 0.36 }, accent = { 1, 0.82, 0 }, onAccent = { 0.12, 0.09, 0.02 }, link = { 0.95, 0.80, 0.45 },
    ok = { 0.30, 0.85, 0.35 }, warn = { 1, 0.72, 0.20 }, bad = { 1, 0.30, 0.25 },
    window = { 0.07, 0.065, 0.06, 0.96 }, header = { 0, 0, 0, 0.35 },
    pane = { 0, 0, 0, 0.38 }, paneEdge = { 0.38, 0.33, 0.24, 0.9 },
    control = { 0.10, 0.09, 0.08, 0.95 }, controlEdge = { 0.48, 0.41, 0.28, 1 },
    primary = { 0.42, 0.07, 0.05, 1 }, primaryEdge = { 0.92, 0.70, 0.28, 1 },
    hover = { 1, 0.85, 0.45, 0.10 }, pressed = { 0, 0, 0, 0.25 },
    selected = { 0.62, 0.45, 0.10, 0.38 }, selectedEdge = { 0.95, 0.75, 0.30, 0.9 },
    badge = { 0.50, 0.09, 0.07, 1 }, badgeText = { 1, 0.92, 0.85 },
    pill = { 0.55, 0.40, 0.08, 0.55 }, pillText = { 1, 0.86, 0.45 },
    fieldText = { 1, 1, 1 },
}

local GLASS = {
    text = { 0.94, 0.95, 0.97 }, heading = { 1, 1, 1 }, muted = { 0.70, 0.73, 0.78 },
    faint = { 0.50, 0.53, 0.58 }, accent = { 0.98, 0.80, 0.36 }, onAccent = { 0.10, 0.09, 0.06 }, link = { 0.80, 0.88, 1 },
    ok = { 0.35, 0.88, 0.45 }, warn = { 1, 0.75, 0.30 }, bad = { 1, 0.38, 0.35 },
    window = { 0.06, 0.07, 0.085, 0.90 }, header = { 1, 1, 1, 0.03 },
    pane = { 0.072, 0.082, 0.10, 0.94 }, paneEdge = { 0.85, 0.88, 0.95, 0.18 },
    control = { 0.095, 0.11, 0.135, 0.90 }, controlEdge = { 0.88, 0.91, 0.98, 0.35 },
    primary = { 0.78, 0.82, 0.92, 0.30 }, primaryEdge = { 0.96, 0.97, 1, 0.85 },
    hover = { 1, 1, 1, 0.07 }, pressed = { 0, 0, 0, 0.25 },
    selected = { 0.62, 0.68, 0.85, 0.30 }, selectedEdge = { 0.92, 0.94, 1, 0.75 },
    badge = { 0.62, 0.12, 0.12, 1 }, badgeText = { 1, 0.95, 0.95 },
    pill = { 0.80, 0.62, 0.15, 0.45 }, pillText = { 1, 0.88, 0.50 },
    fieldText = { 1, 1, 1 },
}

Theme.C = FOREVER
Theme._palettes = { forever = FOREVER, glass = GLASS }

------------------------------------------------------------
-- Glass UI's suite and the borrowed LibGlass
------------------------------------------------------------

local function settings()
    local db = ns.Store.db()
    return db and db.settings
end

-- Glass UI's suite when it speaks API 1 with the functions Bugsy needs; else nil.
function Theme.Suite()
    local gui = G("GlassUI")
    local s = type(gui) == "table" and rawget(gui, "Suite")
    if type(s) ~= "table" or rawget(s, "API") ~= 1 then return nil end
    if type(rawget(s, "Theme")) ~= "function" or type(rawget(s, "Report")) ~= "function" then return nil end
    return s
end

-- The LibGlass another addon loaded, and its MINOR; or nil and why ("absent", "library-too-old").
local function libGlass()
    local stub = G("LibStub")
    if not stub then return nil, "absent" end
    local ok, lib, minor = pcall(stub, "LibGlass-1.0", true)
    if not ok or type(lib) ~= "table" then return nil, "absent" end
    if type(minor) ~= "number" or minor < Theme.MIN_LIBGLASS then return nil, "library-too-old", minor end
    return lib, nil, minor
end

-- Pearl can be chosen: a LibGlass is loaded and no glass build failed this session.
function Theme.PearlAvailable()
    return libGlass() ~= nil and not glassBroken
end

local function newGlass(preset)
    if Glass and glassPreset == preset then return Glass end
    local lib, why, minor = libGlass()
    if not lib then return nil, why, minor end
    local ok, inst = pcall(lib.New, lib, { preset = preset })
    if not ok or type(inst) ~= "table" then
        local text = Safe.text(inst) or ""
        return nil, text:find("unknown preset", 1, true) and "library-too-old" or "build-failed", minor
    end
    for _, fn in ipairs({ "Apply", "Reflect", "SetSurfaceAlpha", "SetSurfaceTint", "SetWash", "SetEdge", "Mask" }) do
        if type(inst[fn]) ~= "function" then return nil, "library-too-old", minor end
    end
    if type(inst.SIZES) ~= "table" or type(inst.SIZES.thin_small) ~= "table" then return nil, "library-too-old", minor end
    return inst, nil, minor
end

------------------------------------------------------------
-- Deciding the look
------------------------------------------------------------

-- The player's choice: "follow" while Glass UI is here and Bugsy follows it, else the own look.
function Theme.Choice()
    local s = settings() or {}
    if Theme.Suite() and s.followGlassUI ~= false then return "follow" end
    return s.look == "pearl" and "pearl" or "forever"
end

function Theme.Effective() return effective end
function Theme.Following() return following end
function Theme.Glass() return effective == "glass" and Glass or nil end
function Theme.Failures() return failures end

-- What the window's look says, for the header and the settings: "Pearl Glass", "WoW
-- Forever", and why not glass when glass was wanted.
function Theme.Describe()
    local name = effective == "glass" and Theme.LABELS.pearl or Theme.LABELS.forever
    if following then name = name .. " " .. L["(Glass UI)"] end
    local note
    if glassBroken then note = L["The glass look failed to build, so Bugsy uses WoW Forever until /reload."]
    elseif buildReason == "absent" then note = L["Pearl Glass needs a Glass addon (Glass UI, for example): none is loaded."]
    elseif buildReason == "library-too-old" then note = L["The loaded LibGlass is too old for Pearl Glass."]
    elseif buildReason then note = L["The glass look could not be built."] end
    return name, note
end

local function report()
    local suite = Theme.Suite()
    if not suite then return end
    local s = settings() or {}
    local state = {
        api = 1, live = false,
        options = function() if ns.Options then ns.Options.Open() end end,
        built = (following and effective == "glass") and glassPreset or nil,
        minor = glassMinor,
        reason = following and effective ~= "glass" and buildReason or nil,
        look = { tint = "bugsy", accent = "bugsy" }, own = { tint = true, accent = true },
    }
    if s.followGlassUI == false then
        state.declined = REPORT_LABEL[s.look == "pearl" and "pearl" or "forever"]
    end
    pcall(suite.Report, ADDON, state)
end
Theme.ReportToSuite = report

-- Decides the look from the settings and Glass UI; reports it. Returns the effective look.
function Theme.Decide()
    local s = settings() or {}
    following, buildReason = false, nil
    local want
    local suite = Theme.Suite()
    if suite and s.followGlassUI ~= false then
        local ok, answer = pcall(suite.Theme, ADDON)
        if ok and type(answer) == "table" and type(answer.preset) == "string" then
            want, following = answer.preset, true
        end
        -- nil, "not-following" / "not-ready" / "unknown": the own look, not a failure.
    end
    if not following and s.look == "pearl" then want = "pearl" end
    effective = "forever"
    if want then
        if glassBroken then
            buildReason = "build-failed"
        else
            local inst, why, minor = newGlass(want)
            glassMinor = minor or glassMinor
            if inst then
                Glass, glassPreset, effective = inst, want, "glass"
            else
                buildReason = why
            end
        end
    end
    Theme.C = effective == "glass" and GLASS or FOREVER
    report()
    return effective
end

-- The player picks "follow", "forever" or "pearl" (the window's menu, the settings, the
-- slash command). False when refused (unknown, or Pearl with no LibGlass).
function Theme.SetChoice(choice)
    local s = settings()
    if not s then return false end
    if choice == "follow" then
        if not Theme.Suite() then return false end
        s.followGlassUI = true
    elseif choice == "forever" or choice == "pearl" then
        if choice == "pearl" and not Theme.PearlAvailable() then return false end
        s.look = choice
        s.followGlassUI = false
    else
        return false
    end
    local before = effective
    Theme.Decide()
    if ns.UI and ns.UI.Rebuild then ns.UI.Rebuild(before) end
    if ns.Options and ns.Options.Refresh then ns.Options.Refresh() end
    return true
end

-- A glass build failed (UI.lua's pcall): recorded, glass given up for the session, Glass UI
-- told. `err` is read through Safe; never stored raw.
function Theme.Fail(op, err)
    local text = Safe.text(err)
    if text and #text > 200 then text = text:sub(1, 200) end
    if #failures >= Theme.FAILURES_MAX then table.remove(failures, 1) end
    failures[#failures + 1] = { op = op, text = text or "?", at = ns.API.Now() }
    glassBroken = true
    effective = "forever"
    buildReason = "build-failed"
    Theme.C = FOREVER
    report()
end

------------------------------------------------------------
-- Surfaces (called while a window is built, under its pcall)
------------------------------------------------------------

local function color(tex, c) tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1) end

-- Four 1-pixel edges inside `frame`, coloured `c`; returns them (to recolour later).
local function edges(frame, c, layer)
    local out = {}
    for i, p in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
                         { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local e = frame:CreateTexture(nil, layer or "BORDER")
        e:SetPoint(p[1], frame, p[1])
        e:SetPoint(p[2], frame, p[2])
        if i <= 2 then e:SetHeight(1) else e:SetWidth(1) end
        color(e, c)
        out[i] = e
    end
    return out
end
Theme.edges = edges

local function hasFile(path)
    local f = G("GetFileIDFromPath")
    if not f then return false end
    local ok, id = pcall(f, path)
    return ok and id ~= nil
end

local ROCK = "Interface\\FrameGeneral\\UI-Background-Rock"

-- A window's outer shell; `header` is the height of its title band.
function Theme.Window(frame, header)
    local C = Theme.C
    if effective == "glass" then
        local g = Glass.Apply(frame, "large")
        local backing = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
        backing:SetAllPoints(frame)
        backing:AddMaskTexture(g.mask)
        -- Opaque enough that nameplates and names behind it don't read through the text
        -- (#31, seen in game at 0.55 under 0.78).
        backing:SetColorTexture(0.03, 0.03, 0.035, 0.85)
        Glass.SetSurfaceTint(g, 0.085, 0.095, 0.115, 0.86)
        Glass.SetWash(g, 0)
        Glass.SetSurfaceAlpha(g, "rim", 0.12)
        Glass.SetSurfaceAlpha(g, "dark", 0.55)
        Glass.SetSurfaceAlpha(g, "shadow", 0.18)
        Glass.SetSurfaceAlpha(g, "grain", 0)
        Glass.SetEdge(g, 0, 0, 0)
        Glass.Reflect(g, frame, header and { header = header } or nil)
        frame.glass = g
        return
    end
    -- Forever: a dark stone ground under a restrained metal border (Blizzard's dark dialog
    -- art when its template is there, else our own edges).
    local fill = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    fill:SetAllPoints(frame)
    color(fill, C.window)
    if hasFile(ROCK) then
        local rock = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
        rock:SetAllPoints(frame)
        rock:SetTexture(ROCK, "REPEAT", "REPEAT")
        rock:SetHorizTile(true)
        rock:SetVertTile(true)
        rock:SetVertexColor(0.35, 0.33, 0.30)
        rock:SetAlpha(0.55)
    end
    local create = G("CreateFrame")
    local ok, border = pcall(create, "Frame", nil, frame, "DialogBorderDarkTemplate")
    if ok and border and border.Bg ~= nil then
        border:SetAllPoints(frame)
        border.Bg:SetAlpha(0)          -- our ground shows; the template brings the metal edge
        frame.border = border
    else
        frame.border = { edges = edges(frame, C.controlEdge, "BORDER") }
    end
end

-- Pearl's scroll bar: a slim thumb on a faint track, no arrows; the client's gold arrows and
-- knob clash with glass (#31). Forever keeps the client's own, which suits it. Blizzard shows
-- the arrow buttons again on every range change, so they're made invisible and click-through
-- rather than hidden; the mouse wheel and the thumb still scroll.
function Theme.ScrollBar(scroll)
    local bar = scroll and scroll.ScrollBar
    if effective ~= "glass" or not bar then return end
    local C = Theme.C
    for _, key in ipairs({ "ScrollUpButton", "ScrollDownButton" }) do
        local b = bar[key]
        if b then b:SetAlpha(0); b:EnableMouse(false) end
    end
    if bar.ThumbTexture then
        bar.ThumbTexture:SetColorTexture(C.text[1], C.text[2], C.text[3], 0.35)
        bar.ThumbTexture:SetSize(5, 36)
    end
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(1, 1, 1, 0.06)
    track:SetWidth(3)
    track:SetPoint("TOP", bar, "TOP", 0, 0)
    track:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
    bar.glassTrack = track
end

-- A dropdown's arrow on `tex`: the client's gold scroll button in Forever; in Pearl, its
-- plain arrow icon, desaturated in the look's muted colour (#31).
function Theme.DropArrow(tex)
    if effective == "glass" then
        local c = Theme.C.muted
        tex:SetTexture("Interface\\Buttons\\SquareButtonTextures")
        tex:SetTexCoord(0.45312500, 0.64062500, 0.20312500, 0.01562500)   -- Blizzard's "DOWN"
        tex:SetDesaturated(true)
        tex:SetVertexColor(c[1], c[2], c[3])
        tex:SetSize(12, 12)
    else
        tex:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
        tex:SetSize(20, 20)
    end
end

-- A reading region on `host` (its own size), drawn behind its content.
function Theme.Pane(host)
    local C = Theme.C
    local pane = host:CreateTexture(nil, "BACKGROUND", nil, 0)
    pane:SetAllPoints(host)
    color(pane, C.pane)
    host.pane = pane
    if effective == "glass" then
        local S = Glass.SIZES.thin_small
        pane:AddMaskTexture(Glass.Mask(host, S.mask, S.maskMargin, 0, pane))
    else
        host.paneEdges = edges(host, C.paneEdge, "BACKGROUND")
    end
end

-- A control's surface (a button, a field, a tab). role: "control" | "primary".
-- Returns nothing; later states recolour host.state only (never LibGlass).
function Theme.Control(host, role)
    local C = Theme.C
    local primary = role == "primary"
    if effective == "glass" then
        local g = Glass.Apply(host, "small")
        local t = primary and C.primary or C.control
        Glass.SetSurfaceTint(g, t[1], t[2], t[3], t[4])
        Glass.SetWash(g, primary and 0.06 or 0.025)
        Glass.SetSurfaceAlpha(g, "rim", primary and 0.55 or 0.22)
        Glass.SetSurfaceAlpha(g, "dark", primary and 0.15 or 0.35)
        Glass.SetSurfaceAlpha(g, "shadow", 0.05)
        Glass.SetSurfaceAlpha(g, "grain", 0)
        Glass.SetEdge(g, 0.10, 0.015, 0.12, 3)
        host.glass = g
    else
        local fill = host:CreateTexture(nil, "BACKGROUND", nil, -1)
        fill:SetAllPoints(host)
        color(fill, primary and C.primary or C.control)
        host.fill = fill
        host.edges = edges(host, primary and C.primaryEdge or C.controlEdge, "BORDER")
    end
    -- Our own state layer (hover, pressed, selected), over the surface, under the text.
    local state = host:CreateTexture(nil, "ARTWORK", nil, -1)
    state:SetAllPoints(host)
    state:SetColorTexture(0, 0, 0, 0)
    host.state = state
end

function Theme.Paint(tex, key) local c = Theme.C[key]; if c then color(tex, c) end end
function Theme.TextColor(fs, key)
    local c = Theme.C[key] or Theme.C.text
    fs:SetTextColor(c[1], c[2], c[3])
end

Theme._test = {
    reset = function()
        effective, following, Glass, glassPreset, glassMinor, glassBroken, buildReason = "forever", false, nil, nil, nil, nil, nil
        failures = {}
        Theme.C = FOREVER
    end,
}
