-- Reports (DESIGN §9, REPORT-SCHEMA.md): JSON validity, escaping, redaction,
-- trimming that terminates, the wording rule, and docs/examples.
-- BUGSY_WRITE_EXAMPLES=1 rewrites docs/examples instead of comparing them.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- A strict JSON parser (RFC 8259), for checking only.
local function parseJson(s)
    local i = 1
    local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
    local function fail(why) error(("json: %s at byte %d"):format(why, i), 0) end
    local value
    local function str()
        i = i + 1
        local out = {}
        while true do
            local c = s:sub(i, i)
            if c == "" then fail("unterminated string") end
            if c == '"' then i = i + 1; return table.concat(out) end
            if c:byte() < 0x20 then fail("raw control character") end
            if c == "\\" then
                local e = s:sub(i + 1, i + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if map[e] then out[#out + 1] = map[e]; i = i + 2
                elseif e == "u" then
                    local hex = s:sub(i + 2, i + 5)
                    if not hex:match("^%x%x%x%x$") then fail("bad \\u") end
                    out[#out + 1] = "\\u" .. hex; i = i + 6
                else fail("bad escape") end
            else
                out[#out + 1] = c; i = i + 1
            end
        end
    end
    function value()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            i = i + 1; ws()
            local t = {}
            if s:sub(i, i) == "}" then i = i + 1; return t end
            while true do
                ws()
                if s:sub(i, i) ~= '"' then fail("key expected") end
                local k = str(); ws()
                if s:sub(i, i) ~= ":" then fail("colon expected") end
                i = i + 1
                t[k] = value(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "}" then return t elseif d ~= "," then fail("comma expected") end
            end
        elseif c == "[" then
            i = i + 1; ws()
            local t = {}
            if s:sub(i, i) == "]" then i = i + 1; return t end
            while true do
                t[#t + 1] = value(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "]" then return t elseif d ~= "," then fail("comma expected") end
            end
        elseif c == '"' then return str()
        elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
        elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
            if not num or num == "" then fail("value expected") end
            i = i + #num
            return tonumber(num)
        end
    end
    local v = value(); ws()
    if i <= #s then fail("trailing data") end
    return v
end

local function validUtf8(s)
    local i = 1
    while i <= #s do
        local c = s:byte(i)
        local n = c < 0x80 and 0 or (c >= 0xc2 and c <= 0xdf) and 1 or (c >= 0xe0 and c <= 0xef) and 2
            or (c >= 0xf0 and c <= 0xf4) and 3 or nil
        if not n then return false end
        for k = 1, n do local d = s:byte(i + k); if not d or d < 0x80 or d > 0xbf then return false end end
        i = i + n + 1
    end
    return true
end

math.randomseed(42)
local ns = loadAddon()
local Json, Report, Store = ns.Json, ns.Report, ns.Store

-- The encoder: escaping and UTF-8.
local tricky = "quote\" back\\ nl\n tab\t bell\7 del\127 pipe| é 漢 bad\255byte trunc\226\130"
local out = Json.encode({ s = tricky, n = 1.5, i = 3, b = false, list = { 1, 2 }, nan = 0 / 0 })
local back = parseJson(out)
check(back, "the encoder's output parses strictly")
check(validUtf8(out), "and is valid UTF-8")
check(out:find("\\u0007", 1, true) and out:find("\\u007f", 1, true), "control characters escaped")
check(out:find("\\ufffd", 1, true), "an invalid byte becomes U+FFFD")
check(out:find("é", 1, true) and out:find("漢", 1, true), "valid UTF-8 is kept")
eq(back.n, 1.5, "numbers round-trip")
check(out:find('"nan":null', 1, true), "a NaN becomes null")
eq(Json.encode({ b = 1, a = 2 }), '{"a":2,"b":1}', "keys are sorted")

-- A real problem through the whole path.
WoW.playerName, WoW.realm = "Karuzo", "Morphisto"
WoW.stack = stackAt("TestAddon", "Core.lua", 42, "Interface/AddOns/TestAddon/Libs/LibGlass-1.0/LibGlass.lua:9: in function paint")
WoW.raise("Interface/AddOns/TestAddon/Core.lua:42: Karuzo's bag is nil | pipe")
WoW.advance(0)
local p = Store.List("all", true)[1]
local r = Report.ForProblem(p, { doing = "Opening mail on Karuzo-Morphisto", happened = "Nothing", expected = "The inbox" })
local md, json = Report.Render(r)
check(md and json, "rendered")
local parsed = parseJson(json)
eq(parsed.schema, "bugsy.report/1", "schema named")
check(not json:find("Karuzo", 1, true) and not md:find("Karuzo", 1, true), "the player's name never appears")
check(not json:find("Morphisto", 1, true), "nor the realm")
check(json:find("<player>", 1, true), "replaced by <player>")
eq(parsed.privacy.redactions[1], "player-name", "the redaction is listed")
eq(parsed.attribution.suspect.addon, "TestAddon", "attribution carried")
eq(parsed.destination.url, "https://example.org/testaddon", "the TOC's website is the destination")
check(md:find("Possible explanation", 1, true) == nil, "no pattern matched, no explanation section")
check(md:find("not a verdict", 1, true), "attribution is worded as a reading")
check(json:find("| pipe", 1, true), "a pipe stays literal in the exported text")
check(md:find("Captured with TestAddon 1.2.3", 1, true), "each occurrence names the versions it was captured with")
-- The client's debugstack ends with a newline: it never becomes indented blank lines (#31).
local trailing = Report.ForProblem(p)
for _, o in ipairs(trailing.occurrences) do o.stack = "[Interface/AddOns/TestAddon/Core.lua]:42: in function 'f'\n[C]: ?\n" end
local trailingMd = Report.Markdown(trailing)
check(trailingMd:find("    [C]: ?", 1, true), "the stack is there")
check(not trailingMd:find("\n    \n", 1, true), "no indented blank line after the stack's trailing newline (#31)")
-- Capture's caveats are sentences: each its own bullet, not joined into Not included (#31).
local limited = Report.ForProblem(p)
limited.capture.limits = { "First caveat.", "Second caveat." }
local limitedMd = Report.Markdown(limited)
check(limitedMd:find("### Capture limits\n- First caveat.\n- Second caveat.", 1, true), "each capture caveat is its own bullet")
check(not limitedMd:find("· First caveat", 1, true), "not joined into Not included")

-- An upgrade after the capture: the evidence keeps its version, the installed one
-- is labelled as such (Codex, PR #2).
WoW.addons[1].meta.Version = "2.0.0"
local upMd = Report.Render(Report.ForProblem(p))
check(upMd:find("Captured with TestAddon 1.2.3", 1, true), "the stack is still tied to 1.2.3")
check(upMd:find("Installed when this report was prepared: TestAddon 2.0.0", 1, true), "2.0.0 is labelled as installed now")
check(not upMd:find("**TestAddon 2.0.0**", 1, true), "the heading does not tie the evidence to 2.0.0")
-- The short text too (Codex, #30): the version the error was captured with, the build, and
-- the installed one labelled apart.
local upShort = Report.Short(Report.ForProblem(p))
check(upShort:find("Addon: TestAddon 1.2.3 (appears involved", 1, true), "the short text ties the error to 1.2.3")
check(upShort:find("Installed now: TestAddon 2.0.0", 1, true), "and labels 2.0.0 as installed now")
check(upShort:find("Error %(build %d+, "), "the error names its build")
WoW.addons[1].meta.Version = "1.2.3"
local sameShort = Report.Short(Report.ForProblem(p))
check(not sameShort:find("Installed now", 1, true), "no 'installed now' line when nothing changed")
-- A corrected addon with every text answer blank is still said (Codex, #30).
local onlyAddon = Report.Render(Report.ForProblem(p, { addon = "OtherAddon" }))
check(onlyAddon:find("The player names: OtherAddon", 1, true), "an addon-only correction is in the Markdown")
check(not Report.Render(Report.ForProblem(p, { addon = "TestAddon" })):find("What the player saw", 1, true),
    "choosing Bugsy's own suspect adds nothing")

-- Keys are redacted too, with a suffix on collision.
local keyed = { values = { ["Karuzo"] = 1, ["<player>"] = 2 } }
Report.Redact(keyed, "Karuzo", nil)
check(keyed.values["<player>"] and keyed.values["<player>#2"], "a colliding key gets #2")

-- Trimming: a report far over 64 KB fits after trimming, still valid, steps listed.
local big = Report.ForProblem(p)
big.occurrences = {}
for k = 1, 5 do
    big.occurrences[k] = { message = string.rep("m", 2048), stack = string.rep("s\n", 3000),
        locals = string.rep("l", 3072), context = { values = { A = {} } },
        breadcrumbs = { items = {} } }
    for c = 1, 40 do big.occurrences[k].context.values.A["k" .. c] = string.rep("v", 200) end
    for c = 1, 40 do big.occurrences[k].breadcrumbs.items[c] = { text = string.rep("b", 120) } end
end
local bigJson, fitted = Report.Fit(big)
check(bigJson and #bigJson <= Report.MAX_BYTES, "fitted under 64 KB (" .. tostring(bigJson and #bigJson) .. ")")
check(parseJson(bigJson), "the fitted JSON parses")
check(#fitted.privacy.trimmed > 0 and fitted.privacy.trimmed[1] == "locals", "trimmed in order, listed")

-- Something no step can trim: the minimal report.
local huge = Report.ForProblem(p)
huge.attribution.evidenceDump = string.rep("x", 200000)
local minJson, minimal = Report.Fit(huge)
check(minJson and #minJson < 16384, "the minimal report is small")
eq(minimal.privacy.trimmed[1], "all evidence: report too large", "and says why")
check(parseJson(minJson), "and parses")
huge.problem.title = string.rep("t", 100000)
local okMin = Report.Fit(huge)
check(okMin and #okMin < 16384, "a huge title is capped in the minimal report")

-- A manual report.
local m = Report.Manual("OtherAddon", { happened = "Tab empty", noVisibleProblem = false })
local mmd, mjson = Report.Render(m)
local mp = parseJson(mjson)
eq(mp.problem.kind, "manual", "kind manual")
eq(mp.problem.addon, "OtherAddon", "the picked addon")
eq(mp.destination.known, false, "no website: unknown destination")
eq(mp.problem.groupSignature, nil, "no signature")

-- Empty lists of the schema stay arrays; empty maps stay objects (Codex, PR #2).
for _, k in ipairs({ "inStack", "explanations", "redactions", "trimmed", "limits", "handlerChanges" }) do
    check(mjson:find('"' .. k .. '":[]', 1, true), "an empty " .. k .. " is []")
end
check(not mjson:find(":{}", 1, true) or mjson:find('"suppressed":{', 1, true), "maps stay objects")
eq(Json.encode({ explanations = {}, versions = {} }, { arrays = { explanations = true } }),
    '{"explanations":[],"versions":{}}', "only the named keys become arrays")

-- Wording: nothing may say a report was sent or submitted.
for _, file in ipairs(tocFiles()) do
    local f = io.open(file, "rb"); local src = f:read("*a"); f:close()
    for literal in src:gmatch('"([^"\n]*)"') do
        local l = literal:lower()
        check(not l:find("submitted") and not l:find("report sent") and not l:find("sent to the author")
            and not l:find("has been sent"), file .. ": a string claims sending: " .. literal)
    end
end

-- docs/examples: generated, compared.
local function example(name, text)
    local path = "docs/examples/" .. name
    if os.getenv("BUGSY_WRITE_EXAMPLES") == "1" then
        local f = assert(io.open(path, "wb")); f:write(text); f:close()
        return
    end
    local f = io.open(path, "rb")
    local have = f and f:read("*a")
    if f then f:close() end
    -- report ids and times differ per run: compare with them masked
    -- (and line endings: git may check the examples out with CRLF on Windows)
    local function mask(s)
        return ((s or ""):gsub("\r\n", "\n"):gsub("BGY%-%x+%-%x+", "BGY-?"):gsub('"createdAt":%d+', '"createdAt":0')
            :gsub('"sourceId":"%x+"', '"sourceId":"?"'))   -- random per database (and per C library)
    end
    eq(mask(have), mask(text), "docs/examples/" .. name .. " is current (BUGSY_WRITE_EXAMPLES=1 to regenerate)")
end
example("error-report.md", md)
example("error-report.json", json)
example("manual-report.md", mmd)
example("manual-report.json", mjson)

done("test_report")
