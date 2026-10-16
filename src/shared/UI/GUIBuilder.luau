--!strict
--[[
    GUIBuilder (ModuleScript)
    -------------------------
    Clean minimal HUD-style billboard.
    - Fully transparent background
    - White accent colours
    - No text stroke
    - Gotham font throughout (colours and fonts from UITheme)
]]

local TweenService = game:GetService("TweenService")

local UITheme = require(script.Parent:WaitForChild("UITheme"))
local F       = UITheme.Fonts

export type Labels = {
	name: TextLabel,
	status: TextLabel,
	wear: TextLabel,
	barTrack: Frame,
	barFill: Frame,
	wearRow: Frame,
	statusRow: Frame,
	all: { TextLabel },
}

local GUIBuilder = {}

-- How long the billboard takes to fade out when it's destroyed.
local FADE_OUT = TweenInfo.new(0.2, Enum.EasingStyle.Quad)

-- Billboard colours, from the shared theme. The bar fill starts white;
-- WearDisplay recolours it by condition once the part is inspected.
local C = {
	White   = UITheme.Colors.Text,
	Dim     = UITheme.Colors.TextDim,
	BarBG   = UITheme.Colors.Track,
	BarFill = UITheme.Colors.Text,
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local corner = UITheme.Corner

local function label(name: string, text: string, size: number, color: Color3, parent: Instance): TextLabel
	local l = Instance.new("TextLabel")
	l.Name                   = name
	l.Text                   = text
	l.TextSize               = size
	l.TextColor3             = color
	l.Font                   = F.Regular
	l.BackgroundTransparency = 1
	l.TextTransparency       = 1
	l.TextXAlignment         = Enum.TextXAlignment.Center
	l.TextYAlignment         = Enum.TextYAlignment.Center
	l.Size                   = UDim2.new(1, 0, 1, 0)
	l.Parent                 = parent
	return l
end

-- ── Create ────────────────────────────────────────────────────────────────────

function GUIBuilder.Create(model: Model): (BillboardGui?, Labels?)
	local part: BasePart? = model.PrimaryPart
		or model:FindFirstChildWhichIsA("BasePart")
	if not part then return nil, nil end

	-- Root
	local gui                 = Instance.new("BillboardGui")
	gui.Name                  = "InspectionGUI"
	gui.Adornee               = part
	gui.AlwaysOnTop           = true
	gui.Active                = true
	gui.Size                  = UDim2.new(0, 220, 0, 72)
	gui.StudsOffset           = Vector3.new(0, part.Size.Y / 2 + 0.4, 0)
	gui.LightInfluence        = 0
	gui.ClipsDescendants      = false
	gui.Parent                = part

	-- Background panel — fully transparent
	local bg                  = Instance.new("Frame")
	bg.Name                   = "BG"
	bg.Size                   = UDim2.new(1, 0, 1, 0)
	bg.BackgroundTransparency = 1
	bg.BorderSizePixel        = 0
	bg.Parent                 = gui
	corner(bg, UITheme.Radius.Large)

	-- Invisible hit area
	local hit                 = Instance.new("TextButton")
	hit.Name                  = "HitArea"
	hit.Size                  = UDim2.new(1, 0, 1, 0)
	hit.BackgroundTransparency = 1
	hit.Text                  = ""
	hit.ZIndex                = 10
	hit.Parent                = bg

	-- Part name
	local nameFrame           = Instance.new("Frame")
	nameFrame.Name            = "NameRow"
	nameFrame.Size            = UDim2.new(1, -16, 0, 26)
	nameFrame.Position        = UDim2.new(0, 8, 0, 6)
	nameFrame.BackgroundTransparency = 1
	nameFrame.Parent          = bg

	local nameLabel = label(
		"NameLabel",
		model.Name:upper(),
		15,
		C.White,
		nameFrame
	)
	nameLabel.TextXAlignment  = Enum.TextXAlignment.Left
	nameLabel.Font            = F.Bold

	-- Divider
	local divider             = Instance.new("Frame")
	divider.Name              = "Divider"
	divider.Size              = UDim2.new(1, -16, 0, 1)
	divider.Position          = UDim2.new(0, 8, 0, 34)
	divider.BackgroundColor3  = C.White
	divider.BackgroundTransparency = 0.7
	divider.BorderSizePixel   = 0
	divider.Parent            = bg

	-- Status row
	local statusFrame         = Instance.new("Frame")
	statusFrame.Name          = "StatusRow"
	statusFrame.Size          = UDim2.new(1, -16, 0, 22)
	statusFrame.Position      = UDim2.new(0, 8, 0, 40)
	statusFrame.BackgroundTransparency = 1
	statusFrame.Parent        = bg

	local statusLabel = label(
		"StatusLabel",
		"HOLD TO INSPECT",
		15,
		C.Dim,
		statusFrame
	)
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- Wear row (hidden until inspected)
	local wearRow             = Instance.new("Frame")
	wearRow.Name              = "WearRow"
	wearRow.Size              = UDim2.new(1, -16, 0, 22)
	wearRow.Position          = UDim2.new(0, 8, 0, 40)
	wearRow.BackgroundTransparency = 1
	wearRow.Visible           = false
	wearRow.Parent            = bg

	-- Wear text label
	local wearLabel           = Instance.new("TextLabel")
	wearLabel.Name            = "WearLabel"
	wearLabel.Size            = UDim2.new(0, 60, 1, 0)
	wearLabel.Position        = UDim2.new(0, 0, 0, 0)
	wearLabel.BackgroundTransparency = 1
	wearLabel.Font            = F.Bold
	wearLabel.TextSize        = 11
	wearLabel.TextColor3      = C.White
	wearLabel.TextXAlignment  = Enum.TextXAlignment.Left
	wearLabel.TextYAlignment  = Enum.TextYAlignment.Center
	wearLabel.Text            = "WEAR"
	wearLabel.TextTransparency = 1
	wearLabel.Parent          = wearRow

	-- Bar track
	local barTrack            = Instance.new("Frame")
	barTrack.Name             = "BarTrack"
	barTrack.Size             = UDim2.new(1, -68, 0, 6)
	barTrack.Position         = UDim2.new(0, 64, 0.5, -3)
	barTrack.BackgroundColor3 = C.BarBG
	barTrack.BackgroundTransparency = 0.3
	barTrack.BorderSizePixel  = 0
	barTrack.Parent           = wearRow
	corner(barTrack, UITheme.Radius.Pill)

	-- Bar fill
	local barFill             = Instance.new("Frame")
	barFill.Name              = "BarFill"
	barFill.Size              = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3  = C.BarFill
	barFill.BorderSizePixel   = 0
	barFill.Parent            = barTrack
	corner(barFill, UITheme.Radius.Pill)

	local labels: Labels = {
		name      = nameLabel,
		status    = statusLabel,
		wear      = wearLabel,
		barTrack  = barTrack,
		barFill   = barFill,
		wearRow   = wearRow,
		statusRow = statusFrame,
		all       = { nameLabel, statusLabel },
	}

	return gui, labels
end

-- ── Destroy ───────────────────────────────────────────────────────────────────

-- Fades the billboard out in place, then destroys it. Text and any visible
-- frames (divider, wear bar) fade together, so the label stays over its part
-- while it fades. Replaces the old FadeManager, which moved labels into a
-- disabled ScreenGui where they were never rendered.
--
-- Callers must stop anything that writes to these labels every frame (e.g.
-- WearDisplay's RenderStepped) BEFORE calling this, or it will fight the
-- fade. InspectionUI's cleanup() already does.
function GUIBuilder.Destroy(gui: BillboardGui?)
	if not gui then return end
	for _, desc in ipairs(gui:GetDescendants()) do
		if desc:IsA("TextLabel") or desc:IsA("TextButton") then
			TweenService:Create(desc, FADE_OUT, { TextTransparency = 1 }):Play()
		end
		if desc:IsA("GuiObject") and desc.BackgroundTransparency < 1 then
			TweenService:Create(desc, FADE_OUT, { BackgroundTransparency = 1 }):Play()
		end
	end
	task.delay(FADE_OUT.Time, function()
		gui:Destroy()
	end)
end

return GUIBuilder