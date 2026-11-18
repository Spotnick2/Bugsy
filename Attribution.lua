-- Attribution.lua: who is involved in an occurrence, and how we know (DESIGN.md §7).
-- Three answers kept apart: what the client NAMED, which addons are IN THE STACK,
-- and Bugsy's SUSPECT with its evidence and confidence. A stack participant or a
-- taint name is evidence, never proof of the cause.

local ADDON, ns = ...
local Attr = {}
ns.Attribution = Attr

-- Folders that are libraries even without a Libs/ segment (standalone installs).
Attr.KNOWN_LIBRARIES = {
    ["Ace3"] = true, ["LibStub"] = true, ["CallbackHandler-1.0"] = true,
    ["LibSharedMedia-3.0"] = true, ["LibDataBroker-1.1"] = true, ["LibDBIcon-1.0"] = true,
}

local function isBlizzard(folder) return folder:match("^Blizzard_") ~= nil end

-- Each addon frame of a stack, in order, top first:
-- { folder (where the file physically is), library (a probable library name, or nil),
--   host (the folder carrying an embedded copy, or nil) }.
-- A host is where the copy lives, not necessarily the addon that used it.
-- Consecutive frames in the same folder+library collapse into one entry.
function Attr.frames(stack)
    local out = {}
    if type(stack) ~= "string" then return out end
    local last
    for line in stack:gmatch("[^\n]+") do
        -- the first path of the line (Signature's parser: the same rules for both)
        local rest = ns.Signature.parseFrame(line)
        local folder = rest and rest:match("^([^/]+)/")
        if folder then
            local lib = rest:match("^[^/]+/[Ll]ibs?/([^/]+)/") or rest:match("^[^/]+/[Ll]ibraries/([^/]+)/")
                or rest:match("^[^/]+/[Ee]mbeds?/([^/]+)/")
            local entry
            if lib then
                entry = { folder = folder, library = lib, host = folder }
            elseif Attr.KNOWN_LIBRARIES[folder] or folder:match("^Lib") then
                entry = { folder = folder, library = folder }
            else
                entry = { folder = folder }
            end
            entry.isLibrary = entry.library ~= nil
            do
                local key = entry.folder .. "|" .. (entry.library or "")
                if key ~= last then
                    out[#out + 1] = entry
                    last = key
                end
            end
        end
    end
    return out
end

-- The addon the client named, from a taint message ("tainted by 'X'"), or nil.
function Attr.namedFromMessage(message)
    if type(message) ~= "string" then return nil end
    local name = message:match("tainted by '([^']+)'")
    if name then return { addon = name, source = "taint-message" } end
    return nil
end

-- occ: { kind, message (string|nil), stack (string|nil), actionAddon (string|nil) }
-- Returns { named, inStack, suspect }.
function Attr.attribute(occ)
    local named
    if occ.actionAddon then
        named = { addon = occ.actionAddon, source = "ADDON_ACTION" }
    else
        named = Attr.namedFromMessage(occ.message)
    end

    local frames = Attr.frames(occ.stack)
    local inStack = {}
    for _, f in ipairs(frames) do
        inStack[#inStack + 1] = { folder = f.folder, library = f.library, host = f.host }
    end

    -- First choice: the first non-Bugsy, non-Blizzard, non-library frame from the
    -- top. Fallback: the host of the first embedded library copy (low).
    local suspect, libraryHost
    for _, f in ipairs(frames) do
        if f.folder ~= ADDON and not isBlizzard(f.folder) then
            if not f.isLibrary then
                suspect = { addon = f.folder, confidence = "medium",
                    evidence = { "heuristic: first addon frame from the top of the stack" } }
                break
            elseif f.host and not libraryHost then
                libraryHost = f
            end
        end
    end
    if not suspect and libraryHost then
        suspect = { addon = libraryHost.host, library = libraryHost.library, confidence = "low",
            evidence = { "heuristic: only library frames; " .. libraryHost.library .. "'s copy lives in "
                .. libraryHost.host .. ", which may not be the addon that used it" } }
    end
    if not suspect and named then
        suspect = { addon = named.addon, confidence = "low",
            evidence = { "named by the client (" .. named.source .. "); no addon frame in the stack" } }
    end
    if suspect and named and suspect.addon ~= named.addon then
        suspect.evidence[#suspect.evidence + 1] = "the client named " .. named.addon .. " instead"
    end

    return { named = named, inStack = inStack, suspect = suspect }
end

ns._test = ns._test or {}
ns._test.Attribution = Attr
