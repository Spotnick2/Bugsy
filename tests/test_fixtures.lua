-- Real Forever stacks (P13): captured by BugsyProbe's `stacks` procedure on build
-- 70959 (2026-11-17), the probe's measuring handler at level 1, the stack from the
-- level Blizzard's formula gives. They pin the parser before g1 is frozen.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local ns = loadAddon()
local Sig, Attr = ns.Signature, ns.Attribution

local P = "Interface/AddOns/BugsyProbe/BugsyProbe.lua"
local function frame(ran, defined) return ("[%s]:%d: in function <%s:%d>"):format(P, ran, P, defined) end

local FIXTURES = {
    -- error("...") in a function: the formula lands on the error's line
    plain = { stack = frame(158, 158) .. "\n" .. frame(154, 154) .. "\n", where = 158 },
    -- a runtime error (no 'error' C frame)
    runtime = { stack = frame(159, 159) .. "\n" .. frame(154, 154) .. "\n", where = 159 },
    -- inside an OnUpdate script
    onupdate = { stack = frame(166, 162) .. "\n", where = 166 },
    -- through securecallfunction: a C frame between two frames of the same file
    securecall = { stack = frame(175, 175) .. "\n[C]: in function 'securecallfunction'\n" .. frame(175, 174)
        .. "\n" .. frame(154, 154) .. "\n", where = 175 },
    -- through a chaining wrapper that tail-calls the next handler: the formula is one
    -- level short and the stack starts at the 'error' C frame
    wrapper = { stack = "[C]: in function 'error'\n" .. frame(183, 183) .. "\n", where = 183 },
    -- inside OnEvent, the event fired from a key binding: a C frame and a binding chunk
    event = { stack = frame(193, 190) .. "\n[C]: in function 'CameraOrSelectOrMoveStop'\n"
        .. '[CAMERAORSELECTORMOVE]:4: in function <[string "CAMERAORSELECTORMOVE"]:1>\n', where = 193 },
}

for name, f in pairs(FIXTURES) do
    local lines = Sig.lines(f.stack)
    eq(Sig.where(lines), "BugsyProbe/BugsyProbe.lua:" .. f.where, name .. ": the first location is where the error ran")
    local a = Attr.attribute({ kind = "error", message = P .. ":" .. f.where .. ": boom", stack = f.stack })
    eq(a.suspect and a.suspect.addon, "BugsyProbe", name .. ": the probe appears involved")
    for _, fr in ipairs(a.inStack) do
        check(fr.folder == "BugsyProbe", name .. ": only the probe is in the stack, not " .. tostring(fr.folder))
    end
end

-- The binding chunk and C frames are not locations.
eq(Sig.parseFrame('[CAMERAORSELECTORMOVE]:4: in function <[string "CAMERAORSELECTORMOVE"]:1>'), nil,
    "a key-binding chunk is not a location")
eq(Sig.parseFrame("[C]: in function 'securecallfunction'"), nil, "a C frame is not")
eq(#Sig.lines("[tail call]: ?\n[C]: ?\n" .. frame(1, 1)), 1, "the measured '[tail call]' form is skipped")

-- One error, raised directly and through the tail-calling wrapper: one problem.
local _, gDirect = Sig.compute("error", P .. ":183: boom", frame(183, 183) .. "\n")
local _, gWrapped = Sig.compute("error", P .. ":183: boom", FIXTURES.wrapper.stack)
eq(gDirect, gWrapped, "the wrapper's extra C frame does not split the problem")

-- Real messages from `secrets` (P1, combat, build 70959): readable strings, not secrets.
local Patterns = ns.Patterns
local SECRET_BOOL = P .. ":233: attempt to perform boolean test on local 'x' (a secret boolean value, while execution tainted by 'BugsyProbe')"
local AURA = "GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted by 'BugsyProbe'\nLua Taint: BugsyProbe"
local function ids(o)
    local out = {}
    for _, m in ipairs(Patterns.match(o, 70959)) do out[m.id] = m end
    return out
end
local sb = ids({ kind = "error", message = SECRET_BOOL, stack = frame(233, 226) .. "\n", inCombat = true })
check(sb["secret-touch"], "the 'while execution tainted' wording matches secret-touch")
check(sb["secret-touch"] and table.concat(sb["secret-touch"].evidence, "; "):find("boolean test", 1, true),
    "and quotes the operation in its evidence")
local au = ids({ kind = "error", message = AURA, stack = frame(244, 226) .. "\n", inCombat = true })
check(au["aura-secret"], "the aura message matches aura-secret")
eq(Attr.attribute({ kind = "error", message = SECRET_BOOL, stack = frame(233, 226) .. "\n" }).named.addon,
    "BugsyProbe", "the client names the tainting addon")
eq(Attr.attribute({ kind = "error", message = AURA, stack = frame(244, 226) .. "\n" }).named.addon,
    "BugsyProbe", "in the aura message too")
local _, title = nil, nil
ns.Store.record({ kind = "error", tier = "full", provider = "native", stackOrigin = "error", message = AURA,
    stack = frame(244, 226) .. "\n", at = WoW.clock, key = Sig.messageKey("error", AURA) })
for _, p in ipairs(ns.Store.List("all", true)) do if p.title:find("GetAuraDataByIndex", 1, true) then title = p.title end end
eq(title, "GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted by 'BugsyProbe'",
    "the title is the first line, without the 'Lua Taint:' line")
-- error() given a secret table arrives as the string "UNKNOWN ERROR": one problem per location.
local _, gU1 = Sig.compute("error", "UNKNOWN ERROR", frame(239, 226) .. "\n")
local _, gU2 = Sig.compute("error", "UNKNOWN ERROR", frame(300, 226) .. "\n")
check(gU1 ~= gU2, "UNKNOWN ERROR from two places stays two problems")

done("test_fixtures")
