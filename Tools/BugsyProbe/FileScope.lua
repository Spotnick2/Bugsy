-- FileScope.lua (P5): with the early test armed, install the measuring handler at
-- file scope, schedule a timer to see when it runs, then raise an error here.
-- LoadSavedVariablesFirst decides whether BugsyProbeDB is readable at this point.

local _, NS = ...
local db = rawget(_G, "BugsyProbeDB")
if type(db) ~= "table" or not db.earlyArmed then return end
db.earlyArmed = false

NS.early = { installed = NS.install("file-scope"), timerPhase = "not run" }
local loaded = false
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, _, name) if name == "BugsyProbe" then loaded = true end end)
C_Timer.After(0, function()
    NS.early.timerPhase = loaded and "after ADDON_LOADED" or "before ADDON_LOADED"
    NS.uninstall()
end)
error("BugsyProbe file-scope error (P5)")
