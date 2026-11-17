-- Json.lua: a small, strict JSON encoder for reports (REPORT-SCHEMA.md).
-- Deterministic (object keys sorted), bounded (depth and total size), and always
-- valid UTF-8: invalid bytes become U+FFFD. It never calls tostring on a value it
-- has not type-checked, and refuses anything that is not plain data.

local _, ns = ...
local Json = {}
ns.Json = Json

local MAX_DEPTH = 8
local MAX_BYTES = 65536

local byte, char, format, concat, sort = string.byte, string.char, string.format, table.concat, table.sort
local floor, huge = math.floor, math.huge

local ESC = { [34] = '\\"', [92] = "\\\\", [8] = "\\b", [12] = "\\f", [10] = "\\n", [13] = "\\r", [9] = "\\t" }

-- One string as a JSON literal. Control characters escaped; UTF-8 validated byte
-- by byte (overlongs and surrogates refused), each bad byte replaced by U+FFFD.
local function quote(s)
    local out, n, i, len = { '"' }, 1, 1, #s
    while i <= len do
        local c = byte(s, i)
        if c < 0x20 or c == 0x7f then
            n = n + 1; out[n] = ESC[c] or format("\\u%04x", c); i = i + 1
        elseif ESC[c] then
            n = n + 1; out[n] = ESC[c]; i = i + 1
        elseif c < 0x80 then
            -- a run of plain ASCII in one piece
            local j = i
            while j <= len do
                local d = byte(s, j)
                if d < 0x20 or d >= 0x7f or d == 34 or d == 92 then break end
                j = j + 1
            end
            n = n + 1; out[n] = s:sub(i, j - 1); i = j
        else
            local need, min
            if c >= 0xc2 and c <= 0xdf then need, min = 1, 0x80
            elseif c >= 0xe0 and c <= 0xef then need, min = 2, 0x800
            elseif c >= 0xf0 and c <= 0xf4 then need, min = 3, 0x10000
            end
            local ok = need ~= nil and i + need <= len
            local cp
            if ok then
                cp = c % (2 ^ (6 - need))
                for k = 1, need do
                    local d = byte(s, i + k)
                    if d < 0x80 or d > 0xbf then ok = false; break end
                    cp = cp * 64 + (d - 0x80)
                end
            end
            if ok and (cp < min or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) then ok = false end
            if ok then
                n = n + 1; out[n] = s:sub(i, i + need); i = i + need + 1
            else
                n = n + 1; out[n] = "\\ufffd"; i = i + 1
            end
        end
    end
    n = n + 1; out[n] = '"'
    return concat(out)
end
Json.quote = quote

local function isArray(t)
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k ~= floor(k) then return false end
        count = count + 1
    end
    for i = 1, count do if t[i] == nil then return false end end
    return true, count
end

local function number(v)
    if v ~= v or v == huge or v == -huge then return "null" end
    if v == floor(v) and v > -1e15 and v < 1e15 then return format("%d", v) end
    return format("%.14g", v)
end

-- Encode a value. opts.readable: a value it says is not readable becomes a
-- restricted marker without being touched. opts.arrays: { [key] = true } for the
-- keys whose value is a list, so an empty one is [] (an empty table is {} elsewhere).
function Json.encode(value, opts)
    opts = opts or {}
    local maxDepth, maxBytes = opts.maxDepth or MAX_DEPTH, opts.maxBytes or MAX_BYTES
    local readable = opts.readable or (ns.Safe and ns.Safe.readable) or function() return true end
    local buf, n, size, cut = {}, 0, 0, false

    local function emit(s)
        if cut then return end
        if size + #s > maxBytes then cut = true; return end
        n = n + 1; buf[n] = s; size = size + #s
    end

    local arrays = opts.arrays or {}
    local encodeValue
    function encodeValue(v, depth, key)
        if not readable(v) then emit('{"restricted":true,"reason":"secret"}'); return end
        local t = type(v)
        if t == "nil" then emit("null")
        elseif t == "boolean" then emit(v and "true" or "false")
        elseif t == "number" then emit(number(v))
        elseif t == "string" then emit(quote(v))
        elseif t == "table" then
            if depth >= maxDepth then emit('{"truncated":true,"reason":"depth"}'); return end
            local arr, count = isArray(v)
            if arr and (count > 0 or arrays[key]) then
                emit("[")
                for i = 1, count do
                    if i > 1 then emit(",") end
                    encodeValue(v[i], depth + 1)
                end
                emit("]")
            else
                local keys = {}
                for k in pairs(v) do
                    if type(k) == "string" and readable(k) then keys[#keys + 1] = k end
                end
                sort(keys)
                emit("{")
                for i, k in ipairs(keys) do
                    if i > 1 then emit(",") end
                    emit(quote(k)); emit(":")
                    encodeValue(v[k], depth + 1, k)
                end
                emit("}")
            end
        else
            emit(quote("<" .. t .. ">"))
        end
    end

    encodeValue(value, 0)
    local out = concat(buf)
    return out, cut
end

ns._test = ns._test or {}
ns._test.Json = Json
