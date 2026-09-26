--[[
    LevelCurve (ModuleScript)
    -------------------------
    Single source of truth for the XP → level curve. Both LevelService
    (server, authoritative) and LevelUI (client, display only) require
    this so they always agree on what a given XP total means.

    Curve: XP required to go from `level` to `level + 1` grows by 15%
    each level, starting at 100. Feels fast early, slows down later —
    tune BASE_XP / GROWTH if the pacing needs adjusting.
]]

local LevelCurve = {}

local BASE_XP = 100
local GROWTH  = 1.15

-- XP required to go from `level` to `level + 1`.
function LevelCurve.XpForLevel(level)
	return math.floor(BASE_XP * (GROWTH ^ (level - 1)))
end

-- Given a total XP amount, returns:
--   level          - current level (starts at 1)
--   xpIntoLevel    - XP earned since reaching `level`
--   xpForNextLevel - XP needed in total to reach `level + 1`
function LevelCurve.GetLevelInfo(totalXp)
	local level     = 1
	local remaining = totalXp

	while remaining >= LevelCurve.XpForLevel(level) do
		remaining = remaining - LevelCurve.XpForLevel(level)
		level = level + 1
	end

	return level, remaining, LevelCurve.XpForLevel(level)
end

return LevelCurve
