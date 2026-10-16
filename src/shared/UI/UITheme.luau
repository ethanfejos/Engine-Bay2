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

    Two looks (design "Option D"):
    - GLASS: your HUD, always on screen — rent bar, money, inventory,
      prompts, workbench buttons. Dark, see-through, rounded, never hides
      the car. UITheme.Glass(frame).
    - PAPER: things someone in the world wrote — the work order clipboard,
      Tony's and customers' notes, the receipt, the part tag. Cream paper,
      ink borders, typewriter text, red marker. UITheme.Paper(frame).
    Rule of thumb: if someone in the world wrote it, it's paper; if it's
    your HUD, it's glass.
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
	Star      = Color3.fromRGB(255, 200, 60),  -- filled reputation stars
	StarEmpty = Color3.fromRGB(30, 30, 30),    -- unfilled reputation stars (outlined in Text)

	Track     = Color3.fromRGB(40, 40, 40),    -- empty part of every bar
	Disabled  = Color3.fromRGB(70, 70, 70),    -- greyed-out buttons
	Dark      = Color3.fromRGB(20, 20, 20),    -- menus, text on light tiles

	Paper     = Color3.fromRGB(250, 250, 246), -- receipts
	Ink       = Color3.fromRGB(25, 25, 25),    -- text on paper
	InkMuted  = Color3.fromRGB(120, 120, 120), -- labels and dashes on paper

	-- Glass (HUD)
	Glass       = Color3.fromHex("101114"),  -- card background (BackgroundTransparency GLASS_ALPHA)
	GlassText   = Color3.fromHex("F2F2EE"),
	GlassMuted  = Color3.fromHex("9AA0A8"),
	GlassFaint  = Color3.fromHex("6B7079"),
	Amber       = Color3.fromHex("F2B544"),  -- money, Tony
	Done        = Color3.fromHex("3DD68C"),  -- fixed, your bay, good
	Bad         = Color3.fromHex("FF5A5A"),  -- fines, debt, can't afford
	BadText     = Color3.fromHex("FF8A8A"),  -- red text on glass
	Customer    = Color3.fromHex("6CB8FF"),

	-- Paper (the world)
	Sheet       = Color3.fromHex("F4F1E8"),  -- work orders, notes, receipt
	SheetInk    = Color3.fromHex("1E1E1C"),
	SheetMuted  = Color3.fromHex("6B675E"),
	SheetLine   = Color3.fromHex("D9D3C2"),
	Marker      = Color3.fromHex("B8452F"),  -- red marker: prices, stamps, debt
	MarkerGreen = Color3.fromHex("2F7A4A"),  -- green marker: ticks, DONE
	TonyTab     = Color3.fromHex("E9A53A"),  -- Tony's side tab on notes
	CustomerTab = Color3.fromHex("7FA7CF"),  -- a customer's side tab
	Wood        = Color3.fromHex("8A5A34"),  -- clipboard board
	Clip        = Color3.fromHex("C9CCD1"),  -- clipboard clip
	ClipEdge    = Color3.fromHex("8C9097"),
	Tag         = Color3.fromHex("D8B98A"),  -- manila part tag
	TagInk      = Color3.fromHex("8E3322"),
}

-- How see-through glass cards are.
UITheme.GLASS_ALPHA = 0.1

UITheme.Fonts = {
	Regular = Enum.Font.Gotham,
	Bold    = Enum.Font.GothamBold,
	Mono    = Enum.Font.RobotoMono,           -- numbers and key labels
}

-- Typefaces (FontFace). Builder Sans for the HUD, Roboto Mono for numbers,
-- Special Elite (typewriter) and Permanent Marker on paper.
local function face(family: string, weight: Enum.FontWeight?): Font
	return Font.new("rbxasset://fonts/families/" .. family .. ".json", weight or Enum.FontWeight.Regular)
end
UITheme.Faces = {
	Body   = face("BuilderSans", Enum.FontWeight.Medium),
	Bold   = face("BuilderSans", Enum.FontWeight.Bold),
	Heavy  = face("BuilderSans", Enum.FontWeight.ExtraBold),
	Mono   = face("RobotoMono", Enum.FontWeight.Medium),
	MonoB  = face("RobotoMono", Enum.FontWeight.Bold),
	Type   = face("SpecialElite"),                 -- typewriter, on paper
	Marker = face("PermanentMarker"),              -- handwriting, on paper
	Stamp  = face("LuckiestGuy"),                  -- rubber stamps
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

-- Adds a UIStroke (border) and returns it.
function UITheme.Stroke(parent: Instance, color: Color3, thickness: number?, transparency: number?): UIStroke
	local s           = Instance.new("UIStroke")
	s.Color           = color
	s.Thickness       = thickness or 1
	s.Transparency    = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent          = parent
	return s
end

-- Padding on all four sides (or top/bottom and left/right).
function UITheme.Pad(parent: Instance, y: number, x: number?): UIPadding
	local p         = Instance.new("UIPadding")
	p.PaddingTop    = UDim.new(0, y)
	p.PaddingBottom = UDim.new(0, y)
	p.PaddingLeft   = UDim.new(0, x or y)
	p.PaddingRight  = UDim.new(0, x or y)
	p.Parent        = parent
	return p
end

-- A vertical list layout with a gap.
function UITheme.List(parent: Instance, gap: number, horizontal: boolean?): UIListLayout
	local l         = Instance.new("UIListLayout")
	l.Padding       = UDim.new(0, gap)
	l.SortOrder     = Enum.SortOrder.LayoutOrder
	l.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	if horizontal then l.VerticalAlignment = Enum.VerticalAlignment.Center end
	l.Parent        = parent
	return l
end

-- Makes `frame` a glass card: dark, see-through, rounded, faint border.
function UITheme.Glass(frame: GuiObject, radius: UDim?)
	frame.BackgroundColor3       = UITheme.Colors.Glass
	frame.BackgroundTransparency = UITheme.GLASS_ALPHA
	frame.BorderSizePixel        = 0
	UITheme.Corner(frame, radius or UDim.new(0, 14))
	UITheme.Stroke(frame, Color3.new(1, 1, 1), 1, 0.92)
end

-- Makes `frame` a sheet of paper: cream, square, inked border.
function UITheme.Paper(frame: GuiObject, border: number?)
	frame.BackgroundColor3       = UITheme.Colors.Sheet
	frame.BackgroundTransparency = 0
	frame.BorderSizePixel        = 0
	if border ~= 0 then
		UITheme.Stroke(frame, UITheme.Colors.SheetInk, border or 2)
	end
end

-- A plain text label. Full width, height fits the text size; callers
-- change Size/Position/alignment as needed.
function UITheme.Text(parent: Instance, text: string, fontFace: Font, size: number, color: Color3): TextLabel
	local l                  = Instance.new("TextLabel")
	l.Size                   = UDim2.new(1, 0, 0, math.ceil(size * 1.3))
	l.BackgroundTransparency = 1
	l.FontFace               = fontFace
	l.Text                   = text
	l.TextSize               = size
	l.TextColor3             = color
	l.TextXAlignment         = Enum.TextXAlignment.Left
	l.TextYAlignment         = Enum.TextYAlignment.Center
	l.Parent                 = parent
	return l
end

-- "$1,240" (whole dollars; "-$16" for negatives).
function UITheme.Money(n: number): string
	local digits = tostring(math.abs(math.floor(n + 0.5)))
	local withCommas = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return (if n < 0 then "-$" else "$") .. withCommas
end

-- "#RRGGBB", for RichText <font color="...">.
function UITheme.ToHex(color: Color3): string
	return string.format("#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

return UITheme
