--!strict
--[[
    UITheme (ModuleScript, shared)
    ------------------------------
    The game's look in one place: colours, fonts and corner sizes used by
    every UI script (InventoryUI, RepairUI, LevelUI, InspectionUI's
    billboard via GUIBuilder, and CustomPromptManager).

    Change a value here and every screen follows. Part condition colours
    are separate, in Config/WearColors, because they're a scale (0–100%)
    rather than a style.
]]

local UITheme = {}

UITheme.Colors = {
	Text      = Color3.fromRGB(255, 255, 255), -- main text, outlines, dividers
	TextDim   = Color3.fromRGB(200, 200, 200), -- secondary text (XP numbers, "HOLD TO INSPECT")
	TextMuted = Color3.fromRGB(160, 160, 160), -- hints, placeholders, small detail lines

	Accent    = Color3.fromRGB(0, 200, 120),   -- good / selected / progress / XP
	Warning   = Color3.fromRGB(230, 150, 30),  -- replace, needs replacing
	Danger    = Color3.fromRGB(255, 70, 70),   -- refusals, clear inventory, badges
	Money     = Color3.fromRGB(255, 205, 90),

	Track     = Color3.fromRGB(40, 40, 40),    -- empty part of every bar
	Disabled  = Color3.fromRGB(70, 70, 70),    -- greyed-out buttons
	Dark      = Color3.fromRGB(20, 20, 20),    -- menus, text on light tiles
}

UITheme.Fonts = {
	Regular = Enum.Font.Gotham,
	Bold    = Enum.Font.GothamBold,
	Mono    = Enum.Font.RobotoMono,           -- numbers and key labels
}

UITheme.Radius = {
	Small = UDim.new(0, 4),
	Large = UDim.new(0, 6),
	Pill  = UDim.new(1, 0),
}

-- Adds a UICorner (Small by default) and returns it.
function UITheme.Corner(parent: Instance, radius: UDim?): UICorner
	local c        = Instance.new("UICorner")
	c.CornerRadius = radius or UITheme.Radius.Small
	c.Parent       = parent
	return c
end

-- "#RRGGBB", for RichText <font color="...">.
function UITheme.ToHex(color: Color3): string
	return string.format("#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

return UITheme
