-- Model.lua: what the window shows, as plain functions over the store and the report
-- builder (#28), so the rules are tested without frames:
--   - which problems a tab, a search and the muted switch leave visible, and a selection
--     that never stays on a hidden problem;
--   - the addon a problem points at, honestly ("Unknown source"), and whether that addon
--     was made for an older client (out of date after a patch day);
--   - the capture's health in plain words, and which empty state applies;
--   - the addon picker's choices;
--   - the report draft: answers kept across steps, and a rendered report that is never
--     stale (any change bumps the draft's version; copying always renders the current one).

local ADDON, ns = ...
local G, API, Safe, L = ns.G, ns.API, ns.Safe, ns.L
local M = {}
ns.Model = M

------------------------------------------------------------
-- A problem's addon
------------------------------------------------------------

-- The addon a problem points at: name, how ("suspect" | "named"), confidence; or nil.
function M.AddonOf(p)
    local a = p and p.attribution
    if a and a.suspect and a.suspect.addon then return a.suspect.addon, "suspect", a.suspect.confidence end
    if a and a.named and a.named.addon then return a.named.addon, "named" end
    return nil
end

-- An addon's friendly title (its TOC Title, colour codes and textures removed), else its name.
function M.Title(name)
    if not name then return nil end
    local t = API.AddOnMetadata(name, "Title")
    if type(t) ~= "string" or t == "" then return name end
    t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    t = t:gsub("^%s+", ""):gsub("%s+$", "")
    return t ~= "" and t or name
end

function M.AddonLabel(p)
    local name = M.AddonOf(p)
    return name and M.Title(name) or L["Unknown source"]
end

-- An addon's own icon from its TOC (IconTexture: a path or a file ID), or nil.
function M.Icon(name)
    if not name then return nil end
    local v = API.AddOnMetadata(name, "IconTexture")
    if type(v) ~= "string" or v == "" then return nil end
    return tonumber(v) or v
end

-- Made for another client: "old" (an older interface: out of date after a patch day),
-- "other" (a different one), or nil (current, or unknown). Numbers only (D15).
function M.Staleness(name)
    if not name then return nil end
    local iface = API.AddOnInterface(name)
    local client = API.Build().interface
    if type(iface) ~= "number" or type(client) ~= "number" or iface == client then return nil end
    return iface < client and "old" or "other", iface, client
end

------------------------------------------------------------
-- Time
------------------------------------------------------------

function M.Ago(t, now)
    now = now or API.Now()
    if type(t) ~= "number" or type(now) ~= "number" then return "" end
    local d = now - t
    if d < 45 then return L["just now"] end
    if d < 3600 then return (L["%d min ago"]):format(math.max(1, math.floor(d / 60 + 0.5))) end
    if d < 86400 then return (L["%d h ago"]):format(math.floor(d / 3600 + 0.5)) end
    local days = math.floor(d / 86400 + 0.5)
    if days < 2 then return L["yesterday"] end
    if days < 14 then return (L["%d days ago"]):format(days) end
    local date = G("date")
    return date and date("%Y-%m-%d", t) or ""
end

------------------------------------------------------------
-- The list
------------------------------------------------------------

-- The searchable text of a problem: its addon (name and title), title, and the newest
-- sample's message and stack (readable text only).
local function haystack(p)
    local parts = { p.title or "" }
    local name = M.AddonOf(p)
    if name then parts[#parts + 1] = name; parts[#parts + 1] = M.Title(name) end
    local newest = p.last and p.last[#p.last] or (p.first and p.first[#p.first])
    if newest then
        parts[#parts + 1] = Safe.text(newest.message) or ""
        parts[#parts + 1] = Safe.text(newest.stack) or ""
    end
    return table.concat(parts, "\n"):lower()
end

function M.Matches(p, query)
    if type(query) ~= "string" or query:match("^%s*$") then return true end
    return haystack(p):find(query:lower():match("^%s*(.-)%s*$"), 1, true) ~= nil
end

-- tab: "session" | "history"; scope (history): "all" | "previous".
-- Returns the visible list and { total (in the tab, muted included), muted (hidden by the
-- muted switch), searched (true when a query narrowed it) }.
function M.Visible(tab, scope, query, showMuted)
    local filter = tab == "history" and (scope == "previous" and "previous" or "all") or "session"
    local all = ns.Store.List(filter, true)
    local out, mutedHidden = {}, 0
    for _, p in ipairs(all) do
        if p.muted and not showMuted then
            mutedHidden = mutedHidden + 1
        elseif M.Matches(p, query) then
            out[#out + 1] = p
        end
    end
    local searched = type(query) == "string" and not query:match("^%s*$")
    return out, { total = #all, muted = mutedHidden, searched = searched }
end

-- The selection after a change: kept when still visible, else the first visible, else none.
function M.KeepSelection(list, selected)
    for _, p in ipairs(list) do if p.id == selected then return selected end end
    return list[1] and list[1].id or nil
end

-- How many problems an addon has in the store (this session, and in all).
function M.AddonCounts(name)
    local session, all = 0, 0
    if not name then return 0, 0 end
    local s = ns.Store.session()
    for _, p in ipairs(ns.Store.List("all", true)) do
        if M.AddonOf(p) == name then
            all = all + 1
            if p.lastSession == s then session = session + 1 end
        end
    end
    return session, all
end

------------------------------------------------------------
-- Health and empty states
------------------------------------------------------------

-- { level = "ok" | "warn" | "bad", text (one line), lines (the details) }.
function M.Health()
    local B, S = ns.Bugsy, ns.Capture.state
    local lines = {}
    if not ns.Store.db() then
        return { level = "bad", text = L["Bugsy isn't recording: its saved data couldn't be read."], lines = lines }
    end
    local _, lost, failures = B.Status()
    lines = B.StatusLines()
    if S.mode == "displaced" then
        return { level = "bad", text = L["Monitoring interrupted: another addon replaced the error handler."], lines = lines }
    end
    if S.health and S.health.pause then
        return { level = "bad", text = L["The game may have paused error reporting until /reload."], lines = lines }
    end
    local notes = {}
    if lost > 0 then notes[#notes + 1] = (L["%d errors only counted (a flood)"]):format(lost) end
    if failures > 0 then notes[#notes + 1] = (L["%d internal failures"]):format(failures) end
    if S.forward and S.forward.suspended then notes[#notes + 1] = L["passing errors on is suspended"] end
    if #notes > 0 then
        return { level = "warn", text = L["Monitoring active, with limits: "] .. table.concat(notes, ", "), lines = lines }
    end
    return { level = "ok", text = L["Monitoring active"], lines = lines }
end

-- Which empty state the list shows, or nil when it has problems.
-- "interrupted" first: an empty list must never look like healthy monitoring.
function M.EmptyKind(list, info, health)
    if #list > 0 then return nil end
    if health and health.level == "bad" then return "interrupted" end
    if info.searched and info.total > 0 then return "noResults" end
    if info.muted > 0 and info.muted == info.total then return "onlyMuted" end
    return "none"
end

------------------------------------------------------------
-- The addon picker
------------------------------------------------------------

-- Installed addons a player could report: loaded ones, plus `include` (a captured
-- problem's addon, loaded or not); Bugsy and Blizzard's own left out. Sorted by title.
function M.AddonChoices(include)
    local out, seen = {}, {}
    for _, a in ipairs(API.AddOnList()) do
        if (a.loaded or a.name == include) and a.name ~= ADDON and not a.name:match("^Blizzard_") then
            seen[a.name] = true
            out[#out + 1] = { name = a.name, title = M.Title(a.name), version = ns.Context.version(a.name), loaded = a.loaded }
        end
    end
    if include and not seen[include] and include ~= ADDON then
        out[#out + 1] = { name = include, title = M.Title(include), version = ns.Context.version(include), loaded = false }
    end
    table.sort(out, function(x, y) return x.title:lower() < y.title:lower() end)
    return out
end

function M.SearchAddons(list, query)
    if type(query) ~= "string" or query:match("^%s*$") then return list end
    local q = query:lower():match("^%s*(.-)%s*$")
    local out = {}
    for _, a in ipairs(list) do
        if a.title:lower():find(q, 1, true) or a.name:lower():find(q, 1, true) then out[#out + 1] = a end
    end
    return out
end

------------------------------------------------------------
-- The report draft
------------------------------------------------------------

M.DRAFT_KEYS = { addon = true, description = true, expected = true, steps = true, noVisible = true }

-- mode: "problem" | "manual". For a problem, the addon Bugsy points at is preselected
-- (guess = true), never for a manual report (the player chooses).
function M.NewDraft(mode, problemId)
    local d = { mode = mode, problemId = problemId, step = 1, version = 0, format = "markdown" }
    if mode == "problem" then
        local p = ns.Store.Get(problemId)
        local name, how, confidence = M.AddonOf(p)
        d.addon, d.guess, d.guessHow, d.guessConfidence = name, name ~= nil, how, confidence
    end
    return d
end

-- Changes one answer; any change makes the rendered report stale.
function M.SetDraft(d, key, value)
    if not M.DRAFT_KEYS[key] then return false end
    if value == "" then value = nil end
    if d[key] == value then return true end
    d[key] = value
    if key == "addon" then d.guess = false end
    d.version = d.version + 1
    d.rendered = nil
    return true
end

-- The report for the draft as it is now: rendered once per version. Returns the rendered
-- table { version, markdown, json, short, destination, title, error }.
function M.Render(d)
    if d.rendered and d.rendered.version == d.version then return d.rendered end
    local answers = {
        description = d.description, expected = d.expected, steps = d.steps,
        noVisibleProblem = (d.mode == "problem" and d.noVisible) or nil, addon = d.addon,
    }
    local r
    if d.mode == "problem" then
        local p = ns.Store.Get(d.problemId)
        if not p then
            d.rendered = { version = d.version, error = L["This problem was cleared."] }
            return d.rendered
        end
        r = ns.Report.ForProblem(p, answers)
    else
        r = ns.Report.Manual(d.addon, answers)
    end
    local md, json = ns.Report.Render(r)
    local out = { version = d.version, destination = r.destination or { known = false },
        localsIncluded = r.privacy and r.privacy.localsIncluded, redactions = r.privacy and r.privacy.redactions }
    if not md then
        out.error = L["This report could not be built small enough to copy. Try the problem's technical details instead."]
    else
        out.markdown, out.json, out.short = md, json, ns.Report.Short(r)
    end
    d.rendered = out
    return out
end

-- The text to copy in `format` ("markdown" | "short" | "json"), always for the current answers.
function M.CopyText(d, format)
    local out = M.Render(d)
    if out.error then return nil, out.error end
    return out[format or d.format] or out.markdown
end
