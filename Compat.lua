-- Compat.lua: the one route to client APIs (read with rawget, so the tests'
-- strict stubs see a missing API as nil), and Safe: the accessibility checks every
-- other file uses before touching a value that came from the client or another
-- addon (DESIGN.md §5).

local ADDON, ns = ...
local G = function(name) return rawget(_G, name) end
ns.G = G
ns.ADDON = ADDON

-- Safe -----------------------------------------------------------------------

local Safe = {}
ns.Safe = Safe

local issecretvalue = G("issecretvalue")
local canaccessvalue = G("canaccessvalue")
local canaccesstable = G("canaccesstable")
Safe.hasSecretAPI = issecretvalue ~= nil or canaccessvalue ~= nil

-- True when v may be read, compared, measured, concatenated or used as a key.
-- Every check is itself guarded: a check that throws counts as "not readable".
function Safe.readable(v)
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, v)
        if not ok or secret then return false end
    end
    if canaccessvalue then
        local ok, can = pcall(canaccessvalue, v)
        if not ok or not can then return false end
    end
    if canaccesstable and type(v) == "table" then
        local ok, can = pcall(canaccesstable, v)
        if not ok or not can then return false end
    end
    return true
end

-- Why v is not readable, for the marker. Only called once readable() said no.
function Safe.reason(v)
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, v)
        if ok and secret then return "secret" end
    end
    return "inaccessible"
end

function Safe.marker(v)
    return { restricted = true, reason = Safe.reason(v) }
end

function Safe.isMarker(v)
    return type(v) == "table" and (v.restricted == true or v.unavailable == true)
end

-- A readable string, or nil. Numbers become strings; anything else is nil.
function Safe.string(v)
    if not Safe.readable(v) then return nil end
    local t = type(v)
    if t == "string" then return v end
    if t == "number" then return tostring(v) end
    return nil
end

-- A string cut to max bytes, as REPORT-SCHEMA's cut form; plain when it fits.
-- The cut never splits a UTF-8 sequence.
function Safe.cut(s, max)
    if #s <= max then return s end
    local stop = max
    while stop > 0 do
        local c = s:byte(stop + 1)
        if not c or c < 0x80 or c >= 0xc0 then break end
        stop = stop - 1
    end
    return { text = s:sub(1, stop), truncated = true, originalLength = #s }
end

-- Text of a stored field: a plain string, the cut form's text, or nil.
function Safe.text(v)
    if type(v) == "string" then return v end
    if type(v) == "table" and type(v.text) == "string" then return v.text end
    return nil
end

-- Client ---------------------------------------------------------------------

local API = {}
ns.API = API

function API.Now() local f = G("time"); return f and f() or 0 end
function API.Uptime() local f = G("GetTime"); return f and f() or 0 end
function API.InCombat() local f = G("InCombatLockdown"); return f and f() == true or false end
function API.ProfileMs() local f = G("debugprofilestop"); return f and f() or 0 end
-- The profiler timer for decisions (#11): a readable, finite number, or nil when it
-- is missing, throws or returns anything else. Never calls debugprofilestart (shared).
function API.ProfileTime()
    local f = G("debugprofilestop")
    if not f then return nil end
    local ok, v = pcall(f)
    if not ok or not Safe.readable(v) or type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
        return nil
    end
    return v
end

function API.After(seconds, fn)
    local timer = G("C_Timer")
    if timer and timer.After then timer.After(seconds, fn); return true end
    return false
end

function API.Build()
    local f = G("GetBuildInfo")
    if not f then return {} end
    local version, build, date, interface = f()
    return { version = version, build = build, date = date, interface = interface }
end

function API.Locale() local f = G("GetLocale"); return f and f() or "enUS" end

function API.InstanceType()
    local f = G("IsInInstance")
    if not f then return nil end
    local _, kind = f()
    return Safe.string(kind)
end

function API.CVar(name)
    local c = G("C_CVar")
    if c and c.GetCVar then
        local ok, v = pcall(c.GetCVar, name)
        if ok then return Safe.string(v) end
    end
    return nil
end

local function addOns() return G("C_AddOns") end

function API.AddOnMetadata(name, field)
    local A = addOns()
    if not (A and A.GetAddOnMetadata) then return nil end
    local ok, v = pcall(A.GetAddOnMetadata, name, field)
    if ok then return Safe.string(v) end
    return nil
end

function API.AddOnLoaded(name)
    local A = addOns()
    if not (A and A.IsAddOnLoaded) then return false end
    local ok, _, loaded = pcall(A.IsAddOnLoaded, name)
    return ok and loaded == true
end

-- Every installed addon: { name, title, loaded }.
-- The interface version an addon's TOC was made for (#28: "out of date" after a patch
-- day), or nil. A number from the client, never text (D15).
function API.AddOnInterface(name)
    local A = addOns()
    if not (A and A.GetAddOnInterfaceVersion) then return nil end
    local ok, v = pcall(A.GetAddOnInterfaceVersion, name)
    if ok and Safe.readable(v) and type(v) == "number" and v > 0 then return v end
    return nil
end

function API.AddOnList()
    local A = addOns()
    local out = {}
    if not (A and A.GetNumAddOns and A.GetAddOnInfo) then return out end
    local okN, n = pcall(A.GetNumAddOns)
    if not okN or type(n) ~= "number" then return out end
    for i = 1, n do
        local ok, name, title = pcall(A.GetAddOnInfo, i)
        name = ok and Safe.string(name)
        if name then
            out[#out + 1] = { name = name, title = Safe.string(title) or name, loaded = API.AddOnLoaded(name) }
        end
    end
    return out
end

function API.PlayerName()
    local f = G("UnitName")
    if not f then return nil end
    local ok, name, realm = pcall(f, "player")
    if not ok then return nil end
    name, realm = Safe.string(name), Safe.string(realm)
    if not realm or realm == "" then
        local gr = G("GetRealmName")
        if gr then local ok2, r = pcall(gr); realm = ok2 and Safe.string(r) or nil end
    end
    return name, realm
end

ns._test = ns._test or {}
ns._test.Safe, ns._test.API = Safe, API
