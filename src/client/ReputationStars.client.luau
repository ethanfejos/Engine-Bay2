--!strict
--[[
    ReputationStars (LocalScript)
    -----------------------------
    Five stars above every player's head (yours included) showing their
    reputation. Each client draws them for everyone, so they cost the server
    nothing and use the shared UITheme.

    Reads the "Reputation" number attribute on each Player, 0–5. Decimals
    fill a star partly (3.4 = three full stars and 40% of the fourth), so
    reputation can creep up gradually. No attribute (or not a number) = 0,
    all five empty. ReputationService (server) owns the value: it sets the
    attribute from the save when you join and every time it changes.

    Your own stars hide while the camera is scripted (engine view and the
    workbench), since your character is hidden then too.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UI"):WaitForChild("UITheme"))
local C       = UITheme.Colors

local localPlayer = Players.LocalPlayer
local camera      = Workspace.CurrentCamera

-- ── Config ────────────────────────────────────────────────────────────────────

local ATTRIBUTE    = "Reputation"
local STAR_COUNT   = 5
local STAR_GLYPH   = "★"
local SIZE         = UDim2.new(3.5, 0, 0.7, 0)  -- in studs, so it shrinks with distance like the head
local OFFSET       = Vector3.new(0, 2.4, 0)     -- studs above the head (clears the name)
local MAX_DISTANCE = 60                         -- studs from the camera before they're hidden
local GUI_NAME     = "ReputationStars"

-- ── State ─────────────────────────────────────────────────────────────────────

type Stars = {
	gui: BillboardGui,
	fills: { UIGradient }, -- one per star, on the gold layer
}

local starsByPlayer: { [Player]: Stars } = {}

-- ── Value ─────────────────────────────────────────────────────────────────────

local function getReputation(player: Player): number
	local value = player:GetAttribute(ATTRIBUTE)
	if type(value) ~= "number" or value ~= value then -- missing, wrong type or NaN
		return 0
	end
	return math.clamp(value, 0, STAR_COUNT)
end

-- Shows `fraction` (0–1) of a star's gold layer, from the left, by making
-- the rest of it transparent with a hard edge.
local function setStarFill(gradient: UIGradient, fraction: number)
	local label = gradient.Parent :: TextLabel
	if fraction <= 0.001 then
		label.Visible = false
		return
	end
	label.Visible = true
	if fraction >= 0.999 then
		gradient.Transparency = NumberSequence.new(0)
		return
	end
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(fraction, 0),
		NumberSequenceKeypoint.new(fraction + 0.001, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function refresh(player: Player)
	local stars = starsByPlayer[player]
	if not stars then return end
	local reputation = getReputation(player)
	for i, gradient in ipairs(stars.fills) do
		setStarFill(gradient, math.clamp(reputation - (i - 1), 0, 1))
	end
end

-- ── Building ──────────────────────────────────────────────────────────────────

local function starLabel(parent: Instance, color: Color3, zIndex: number): TextLabel
	local label                  = Instance.new("TextLabel")
	label.Size                   = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font                   = UITheme.Fonts.Bold
	label.Text                   = STAR_GLYPH
	label.TextScaled             = true
	label.TextColor3             = color
	label.ZIndex                 = zIndex
	label.Parent                 = parent
	return label
end

local function build(head: BasePart): Stars
	local gui            = Instance.new("BillboardGui")
	gui.Name             = GUI_NAME
	gui.Adornee          = head
	gui.Size             = SIZE
	gui.StudsOffset      = OFFSET
	gui.MaxDistance      = MAX_DISTANCE
	gui.LightInfluence   = 0

	local row                  = Instance.new("Frame")
	row.Size                   = UDim2.fromScale(1, 1)
	row.BackgroundTransparency = 1
	row.Parent                 = gui

	local layout               = Instance.new("UIListLayout")
	layout.FillDirection       = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder           = Enum.SortOrder.LayoutOrder
	layout.Parent              = row

	local fills: { UIGradient } = {}
	for i = 1, STAR_COUNT do
		local slot                  = Instance.new("Frame")
		slot.Name                   = "Star" .. i
		slot.Size                   = UDim2.fromScale(1 / STAR_COUNT, 1)
		slot.BackgroundTransparency = 1
		slot.LayoutOrder            = i
		slot.Parent                 = row

		-- Empty star: dark, with a light outline so it reads on any background.
		local empty = starLabel(slot, C.StarEmpty, 1)
		empty.TextTransparency = 0.25
		local stroke        = Instance.new("UIStroke")
		stroke.Color        = C.Text
		stroke.Transparency = 0.35
		stroke.Thickness    = 1
		stroke.Parent       = empty

		-- Gold layer on top, revealed left-to-right by its gradient.
		local filled   = starLabel(slot, C.Star, 2)
		local gradient = Instance.new("UIGradient")
		gradient.Parent = filled
		fills[i] = gradient
	end

	return { gui = gui, fills = fills }
end

-- Your own stars hide while the camera is scripted (engine view, workbench).
local function updateOwnVisibility()
	local own = starsByPlayer[localPlayer]
	if own then
		own.gui.Enabled = camera.CameraType ~= Enum.CameraType.Scriptable
	end
end

local function onCharacterAdded(player: Player, character: Model)
	local head = character:WaitForChild("Head", 10)
	if not head or not head:IsA("BasePart") or character.Parent == nil then return end

	local old = starsByPlayer[player]
	if old then old.gui:Destroy() end

	local stars = build(head)
	stars.gui.Parent = head -- goes away with the character
	starsByPlayer[player] = stars
	refresh(player)
	if player == localPlayer then
		updateOwnVisibility()
	end
end

local function onPlayerAdded(player: Player)
	player:GetAttributeChangedSignal(ATTRIBUTE):Connect(function()
		refresh(player)
	end)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	local character = player.Character
	if character then
		task.spawn(onCharacterAdded, player, character)
	end
end

-- ── Start ─────────────────────────────────────────────────────────────────────

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	local stars = starsByPlayer[player]
	if stars then stars.gui:Destroy() end
	starsByPlayer[player] = nil
end)

camera:GetPropertyChangedSignal("CameraType"):Connect(updateOwnVisibility)
