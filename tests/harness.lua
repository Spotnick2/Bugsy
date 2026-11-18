-- harness.lua: the addon loader and Bugsy's test helpers. dofile it after
-- wow_stubs.lua. check / eq / done are WowTestKit's.

TOC = "!Bugsy.toc"
ADDON_NAME = "!Bugsy"

function tocFiles() return Kit.tocFiles(TOC) end

-- Load the addon the way the client does: every TOC file with (name, ns), the
-- saved table, then ADDON_LOADED and PLAYER_LOGIN. opts.db: the saved table.
-- opts.before(ns): runs after the files, before ADDON_LOADED (errors during load).
function loadAddon(opts)
    opts = opts or {}
    local ns = {}
    for _, file in ipairs(tocFiles()) do
        assert(loadfile((file:gsub("\\", "/"))))(ADDON_NAME, ns)
    end
    if opts.before then opts.before(ns) end
    BugsyDB = opts.db
    WoW.fire("ADDON_LOADED", ADDON_NAME)
    if opts.login ~= false then WoW.fire("PLAYER_LOGIN") end
    return ns
end

-- Run the pending timers (the drain is C_Timer.After(0)), repeatedly.
function drain(rounds)
    for _ = 1, rounds or 3 do WoW.advance(0) end
end

function chatHas(pattern)
    for _, line in ipairs(WoW.lines) do if line:find(pattern) then return true end end
    return false
end

-- A stack whose first frame is file:line of an addon.
function stackAt(addon, file, line, more)
    -- the measured Forever shape: the first path is where the line ran, the second where the
    -- function was defined (porting guide, "Who wrote a chat line")
    local s = ("[Interface/AddOns/%s/%s]:%d: in function <Interface/AddOns/%s/%s:%d>"):format(addon, file, line, addon, file, line - 1)
    if more then s = s .. "\n" .. more end
    return s .. "\n[C]: ?"
end

function problems(ns) return ns.Store.List("all", true) end
