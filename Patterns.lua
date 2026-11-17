-- Patterns.lua: known-pattern explanations (DESIGN.md §7). Each rule says what it
-- matched and how sure it is; the UI and the report show matches under "Possible
-- explanation", apart from the facts. A rule never names a cause its evidence
-- doesn't show (a secret boolean is not "UNIT_AURA").

local _, ns = ...
local Patterns = {}
ns.Patterns = Patterns

local GUIDE = "References/Docs/PORTING-TBC-TO-FOREVER.md"

-- builds: the client builds the rule was checked on (inclusive); max = nil means
-- "until a newer build shows otherwise", and the report states the range.
Patterns.RULES = {
    {
        id = "secret-touch", rev = 1, builds = { min = 69913 }, confidence = "high",
        match = function(o)
            local m = o.message
            if type(m) ~= "string" then return nil end
            local what = m:match("%((a secret [%a ]-value)%)") or m:match("(secret %a+ value)")
            if not what then return nil end
            local op = m:match("attempt to ([^%(]-) %(") or m:match("attempt to (.-) on ")
            local ev = { "message mentions " .. what }
            if op then ev[#ev + 1] = "operation refused: " .. op end
            return ev
        end,
        summary = "Code used a secret value in an operation the client refused (the message names it).",
        investigate = "Find the first touch of that value in the stack's top frame; check it with "
            .. "issecretvalue() before any comparison, test or arithmetic, inside the same guard.",
        ref = GUIDE .. " (secret values)",
    },
    {
        id = "aura-secret", rev = 1, builds = { min = 69913 }, confidence = "high",
        match = function(o)
            if type(o.message) == "string" and o.message:find("Auras cannot be accessed when secret", 1, true) then
                return { "message: Auras cannot be accessed when secret" }
            end
        end,
        summary = "An aura read was refused because the aura data was secret to this code.",
        summaryInCombat = "An aura read was refused because the aura data was secret to this code; "
            .. "this occurrence was in combat, when aura data has been measured to go secret.",
        investigate = "Check how the addon reads auras when they are secret; the porting guide "
            .. "describes caching readable data and showing an unknown state.",
        ref = GUIDE .. " (auras)",
    },
    {
        id = "forbidden-unknown", rev = 1, builds = { min = 69977 }, confidence = "medium",
        match = function(o)
            if o.kind == "forbidden" and o.actionFunction == "UNKNOWN()" then
                return { "ADDON_ACTION_FORBIDDEN with function UNKNOWN()" }
            end
        end,
        summary = "The client forbade an action and gave no function name (UNKNOWN()).",
        investigate = "A stack, when one was captured, may show the caller; otherwise look for "
            .. "protected calls in the named addon (targeting, raid markers, combat-log registration "
            .. "have been measured to do this).",
        ref = GUIDE .. " (targeting, marking, the combat log)",
    },
    {
        id = "taintlog-nilmethod", rev = 1, builds = { min = 70450 }, confidence = "low",
        match = function(o)
            if not (o.taintLog and o.taintLog ~= "0") then return nil end
            if type(o.message) ~= "string" or not o.message:find("attempt to call method", 1, true) then return nil end
            if type(o.stack) == "string" and o.stack:match("^[^\n]*Blizzard_") then
                return { "taintLog CVar is " .. o.taintLog, "nil method call at the top of Blizzard code" }
            end
        end,
        summary = "Possibly noise from the taint log: with taintLog on, Blizzard code has been measured "
            .. "calling nil methods on methods addons hooked.",
        investigate = "Turn taintLog off (/console taintLog 0), reload, and see whether this still happens.",
        ref = GUIDE .. " (the taint log makes Blizzard's code call nil methods)",
        noise = true,
    },
    {
        id = "blocked-combat", rev = 1, builds = { min = 69913 }, confidence = "medium",
        match = function(o)
            if o.kind == "blocked" and o.inCombat then return { "ADDON_ACTION_BLOCKED during combat lockdown" } end
        end,
        summary = "A protected action was attempted during combat lockdown.",
        investigate = "Check whether the operation can legally run after combat (PLAYER_REGEN_ENABLED) "
            .. "or needs a secure path. The client blames the addon whose taint the call path carries, "
            .. "which may not be the one that made the call.",
        ref = GUIDE .. " (protected frames in combat)",
    },
}

-- Every rule that matches an occurrence, for the given client build (number).
-- o: { kind, message, stack, inCombat, actionFunction, taintLog }
function Patterns.match(o, build)
    local out = {}
    for _, r in ipairs(Patterns.RULES) do
        local inRange = not build or ((not r.builds.min or build >= r.builds.min)
            and (not r.builds.max or build <= r.builds.max))
        if inRange then
            local ok, evidence = pcall(r.match, o)
            if ok and evidence then
                local summary = (o.inCombat and r.summaryInCombat) or r.summary
                out[#out + 1] = { id = r.id, rev = r.rev, confidence = r.confidence, summary = summary,
                    investigate = r.investigate, ref = r.ref, evidence = evidence, noise = r.noise or nil,
                    builds = { min = r.builds.min, max = r.builds.max } }
            end
        end
    end
    return out
end

ns._test = ns._test or {}
ns._test.Patterns = Patterns
