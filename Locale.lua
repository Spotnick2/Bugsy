-- Locale.lua: the player-facing strings' table (#28). Keyed by the English text itself,
-- so a string with no translation reads back as itself: English needs no table, and a
-- missing translation shows English, never nil (Gnomesweeper's mechanism). Text built
-- from parts is one format string (L["%d problems"]), so a language can reorder it.
-- Saved values, slash commands, report contents and client text Bugsy matches never go
-- through it (D15: correctness never depends on translated text).

local _, ns = ...
ns.L = setmetatable({}, { __index = function(_, k) return k end })
