--[[
    WearColors (ModuleScript, shared)
    ---------------------------------
    The one colour scale for part condition, so every highlight, label and
    bar shows the same colour for the same wear value.

    Wear runs 0–100, where 100 = perfect condition.
    Gradient: 0 = red, 50 = yellow, 100 = green.
]]

local WearColors = {}

function WearColors.Gradient(wear)
	local w = math.clamp(wear or 100, 0, 100) / 100
	if w <= 0.5 then
		return Color3.new(1, w / 0.5, 0)
	end
	return Color3.new(1 - (w - 0.5) / 0.5, 1, 0)
end

return WearColors
