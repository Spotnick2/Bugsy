-- Context.lua: the environment a report states (client, addon identities), each
-- string byte-capped. Read when asked, never inside the error handler.

local ADDON, ns = ...
local Safe, API = ns.Safe, ns.API
local Context = {}
ns.Context = Context

Context.NAME_MAX, Context.VERSION_MAX = 64, 32

local function capped(s, max)
    s = Safe.string(s)
    if not s then return nil end
    if #s > max then s = s:sub(1, max) end
    return s
end
Context.capped = capped

function Context.client()
    local b = API.Build()
    local G = ns.G
    return {
        flavor = "forever",
        version = capped(b.version, 16),
        build = capped(b.build, 16),
        interface = type(b.interface) == "number" and b.interface or nil,
        locale = capped(API.Locale(), 8),
        projectId = type(G("WOW_PROJECT_ID")) == "number" and G("WOW_PROJECT_ID") or nil,
    }
end

-- An addon's version from its TOC, capped; nil when unknown.
function Context.version(name)
    local v = API.AddOnMetadata(name, "Version")
    -- An "@" means the packager's token is still there (an unpackaged copy). Never the
    -- whole token in Lua: the packager replaces it here too, which made a packaged
    -- Bugsy report its own version as "dev" (porting guide, the About page; #22).
    if v and v:find("@", 1, true) then v = "dev" end
    return capped(v, Context.VERSION_MAX)
end

-- What an addon's TOC says about where to report: X-Website, else nil.
function Context.website(name)
    local url = API.AddOnMetadata(name, "X-Website")
    url = capped(url, 200)
    if url and url:match("^https?://") then return url end
    return nil
end

function Context.addonInfo(name)
    name = capped(name, Context.NAME_MAX)
    if not name then return nil end
    return { name = name, version = Context.version(name), loaded = API.AddOnLoaded(name) }
end

ns._test = ns._test or {}
ns._test.Context = Context
