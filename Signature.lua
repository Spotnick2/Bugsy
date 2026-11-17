-- Signature.lua: exact and grouping signatures, and the message key (DESIGN.md §4,
-- REPORT-SCHEMA.md "Signatures"). Pure functions over strings the caller has
-- already checked are readable. ALGO names the rules: any change bumps it, and
-- problems of another algorithm are never merged with these.

local _, ns = ...
local Sig = {}
ns.Signature = Sig

Sig.ALGO = "g1"
Sig.LINES = 12          -- stack lines that signatures read (the "top" tier captures exactly these)
Sig.KEY_HEAD = 512      -- message bytes in the message key

local byte, format, gsub, concat = string.byte, string.format, string.gsub, table.concat
local TWO32 = 4294967296
local own   -- forward: Sig.lines uses it, defined with the frame parser below

-- Two independent 32-bit rolling hashes, as 16 hex digits. Arithmetic only (no bit
-- library); exact in doubles: 4294967295 * 65599 + 255 < 2^53.
function Sig.hash(s)
    local a, b = 5381, 0
    for i = 1, #s do
        local c = byte(s, i)
        a = (a * 33 + c) % TWO32
        b = (b * 65599 + c) % TWO32
    end
    return format("%08x%08x", a, b)
end

local HEX8 = "%x%x%x%x%x%x%x%x+"

-- Memory addresses and object identities only, eight hex digits or more (four
-- after 0x), so ordinary text ("table: expected") is untouched. Numbers, names
-- and quoted text are kept: they are often the difference between two bugs.
function Sig.addressless(msg)
    msg = gsub(msg, "0x%x%x%x%x+", "0x?")
    msg = gsub(msg, "builtin: " .. HEX8, "builtin: ?")
    for _, word in ipairs({ "table", "function", "userdata", "thread" }) do
        msg = gsub(msg, word .. ": " .. HEX8, word .. ": ?")
    end
    return msg
end

local function skipped(line)
    return line:match("^%s*%[C%]") ~= nil or line:find("(tail call)", 1, true) ~= nil
        or line:find("[tail call]", 1, true) ~= nil
end

-- The stack lines signatures read: the first LINES raw lines (what the "top" tier
-- captures, so a top and a full capture of one error agree), then [C] and
-- tail-call lines dropped.
-- The leading run of Bugsy's own frames is dropped first (a stack level that
-- lands one frame short must not change the signature).
function Sig.lines(stack)
    local out = {}
    if type(stack) ~= "string" then return out end
    local raw, leading = 0, true
    for line in stack:gmatch("[^\n]+") do
        raw = raw + 1
        if raw > Sig.LINES then break end
        if leading and (own(line) or skipped(line)) then
            -- still in our own frames, or the C frames between them
        else
            leading = false
            if not skipped(line) then out[#out + 1] = line end
        end
    end
    return out
end

-- The FIRST path of a frame line, as "Folder/sub/file.lua" (relative to AddOns),
-- and its line number; nil for a C frame, a tail call or a code chunk.
-- Measured on Forever (porting guide, "Who wrote a chat line"): each line names
-- its file twice, `[Interface/AddOns/X/f.lua]:12: in function <Interface/AddOns/X/f.lua:10>`;
-- the first is where the line ran, the second where the function was defined.
-- Also handled: the unbracketed `Interface/AddOns/X/f.lua:12:`, a file chunk
-- `[string "@Interface/AddOns/X/f.lua"]:12:`, and shortened `...AddOns/X/...` paths.
-- A path with no AddOns/ segment keeps its own first segment as the folder,
-- unless it was shortened ("..."), which hides the folder.
function Sig.parseFrame(line)
    if type(line) ~= "string" then return nil end
    local norm = gsub(line, "\\", "/")
    local path, ln = norm:match("^%s*%[([^%]]+)%]:(%d+)")
    if path then
        local chunk = path:match('^string "(.*)"$')
        if chunk then
            if chunk:sub(1, 1) ~= "@" then return nil end
            path = chunk:sub(2)
        end
    else
        path, ln = norm:match("^%s*([^%s:%[%]<>\"]+%.%a+):(%d+)")
    end
    if not path then return nil end
    local rel = path:match("[Aa]dd[Oo]ns/(.+)$")
    if not rel then
        if path:find("^%.%.%.") or not path:find("/", 1, true) then return nil end
        rel = path:gsub("^[Ii]nterface/", "")
    end
    return rel, tonumber(ln)
end

-- "Folder/path.lua:123" for a file frame, or nil.
function Sig.location(line)
    local rel, ln = Sig.parseFrame(line)
    if rel then return rel .. ":" .. ln end
    return nil
end

local OWN = (select(1, ...))   -- our folder name ("!Bugsy")
own = function(line)
    local rel = Sig.parseFrame(line)
    return rel ~= nil and OWN ~= nil and rel:sub(1, #OWN + 1) == OWN .. "/"
end
Sig.isOwnFrame = own

-- The first location among the signature lines, else the first line, else "".
function Sig.where(lines)
    for _, line in ipairs(lines) do
        local loc = Sig.location(line)
        if loc then return loc end
    end
    return lines[1] or ""
end

-- The message key: kind and the address-free head of the message.
function Sig.messageKey(kind, message)
    return Sig.hash(kind .. "\n" .. Sig.addressless(message:sub(1, Sig.KEY_HEAD)))
end

-- kind: a fixed kind; message, stack: readable strings, or nil when restricted or
-- not captured. Returns exact, group, restrictedBucket (bool).
function Sig.compute(kind, message, stack)
    local lines = Sig.lines(stack)
    local where = Sig.where(lines)
    if message then
        return Sig.hash(kind .. "\n" .. message .. "\n" .. concat(lines, "\n")),
            Sig.hash(kind .. "\n" .. Sig.addressless(message) .. "\n" .. where), false
    elseif #lines > 0 then
        return Sig.hash(kind .. "\nrestricted\n" .. concat(lines, "\n")),
            Sig.hash(kind .. "\nrestricted\n" .. where), false
    end
    local bucket = Sig.hash(kind .. "\nrestricted-bucket")
    return bucket, bucket, true
end

ns._test = ns._test or {}
ns._test.Signature = Sig
