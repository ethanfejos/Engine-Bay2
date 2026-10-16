--!strict
--[[
    BayRentalUI (LocalScript)
    -------------------------
    The player's side of renting a bay (BayRentalService):

    1. Tony's speech — NpcSpeech (name, text) shows a panel at the
       bottom of the screen for a few seconds.
    2. YOUR BAY — a marker floating over the bay you rent (the bay part's
       "RentedBy" attribute is your UserId), so you can always find it. It
       hides while the camera is scripted (engine view, workbench).
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")

local Shared    = ReplicatedStorage:WaitForChild("Shared")
local Remotes   = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local ZoneUtils = require(Shared:WaitForChild("Modules"):WaitForChild("ZoneUtils"))
local UITheme   = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, F      = UITheme.Colors, UITheme.Fonts

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera    = Workspace.CurrentCamera

-- ── Config ────────────────────────────────────────────────────────────────────

local SPEECH_MIN_TIME  = 3     -- seconds a line stays up, at least
local SPEECH_PER_CHAR  = 0.04  -- plus this much per character, for longer lines
local FADE             = TweenInfo.new(0.25, Enum.EasingStyle.Quad)
local MARKER_HEIGHT    = 2     -- studs above the top of the bay part

-- ── Tony's speech ─────────────────────────────────────────────────────────────

local screen          = Instance.new("ScreenGui")
screen.Name           = "BayRentalUI"
screen.ResetOnSpawn   = false
screen.Parent         = playerGui

local panel                  = Instance.new("Frame")
panel.AnchorPoint            = Vector2.new(0.5, 1)
panel.Position               = UDim2.new(0.5, 0, 1, -110)
panel.Size                   = UDim2.new(0, 520, 0, 64)
panel.BackgroundColor3       = C.Dark
panel.BackgroundTransparency = 1
panel.Visible                = false
panel.Parent                 = screen
UITheme.Corner(panel, UITheme.Radius.Large)

local nameLabel                  = Instance.new("TextLabel")
nameLabel.Position               = UDim2.new(0, 14, 0, 6)
nameLabel.Size                   = UDim2.new(1, -28, 0, 18)
nameLabel.BackgroundTransparency = 1
nameLabel.Font                   = F.Bold
nameLabel.TextSize               = 14
nameLabel.TextColor3             = C.Warning
nameLabel.TextXAlignment         = Enum.TextXAlignment.Left
nameLabel.TextTransparency       = 1
nameLabel.Parent                 = panel

local textLabel                  = Instance.new("TextLabel")
textLabel.Position               = UDim2.new(0, 14, 0, 24)
textLabel.Size                   = UDim2.new(1, -28, 1, -30)
textLabel.BackgroundTransparency = 1
textLabel.Font                   = F.Regular
textLabel.TextSize               = 15
textLabel.TextColor3             = C.Text
textLabel.TextWrapped            = true
textLabel.TextXAlignment         = Enum.TextXAlignment.Left
textLabel.TextYAlignment         = Enum.TextYAlignment.Top
textLabel.TextTransparency       = 1
textLabel.Parent                 = panel

local speechId = 0 -- so an older line's timer can't hide a newer line

local function setShown(shown: boolean)
	local t = if shown then 0 else 1
	TweenService:Create(panel, FADE, { BackgroundTransparency = if shown then 0.15 else 1 }):Play()
	TweenService:Create(nameLabel, FADE, { TextTransparency = t }):Play()
	TweenService:Create(textLabel, FADE, { TextTransparency = t }):Play()
end

Remotes.NpcSpeech.OnClientEvent:Connect(function(name: any, text: any)
	if type(name) ~= "string" or type(text) ~= "string" then return end
	speechId += 1
	local id = speechId

	nameLabel.Text = string.upper(name)
	textLabel.Text = text
	panel.Visible  = true
	setShown(true)

	task.delay(SPEECH_MIN_TIME + #text * SPEECH_PER_CHAR, function()
		if speechId ~= id then return end
		setShown(false)
		task.delay(FADE.Time, function()
			if speechId == id then panel.Visible = false end
		end)
	end)
end)

-- ── YOUR BAY marker ───────────────────────────────────────────────────────────

local markers: { [BasePart]: BillboardGui } = {}

local function makeMarker(zone: BasePart): BillboardGui
	local gui                  = Instance.new("BillboardGui")
	gui.Name                   = "YourBayMarker"
	gui.Adornee                = zone
	gui.Size                   = UDim2.new(0, 160, 0, 36)
	gui.StudsOffsetWorldSpace  = Vector3.new(0, zone.Size.Y / 2 + MARKER_HEIGHT, 0)
	gui.AlwaysOnTop            = true
	gui.LightInfluence         = 0
	gui.Parent                 = playerGui -- this client only

	local label                  = Instance.new("TextLabel")
	label.Size                   = UDim2.fromScale(1, 1)
	label.BackgroundColor3       = C.Accent
	label.BackgroundTransparency = 0.1
	label.Font                   = F.Bold
	label.Text                   = "YOUR BAY"
	label.TextSize               = 18
	label.TextColor3             = C.Dark
	label.Parent                 = gui
	UITheme.Corner(label, UITheme.Radius.Large)

	return gui
end

local function isScripted(): boolean
	return camera.CameraType == Enum.CameraType.Scriptable
end

local function refreshMarker(zone: BasePart)
	local mine = ZoneUtils.GetRenter(zone) == player.UserId
	local existing: BillboardGui? = markers[zone]
	if not mine then
		if existing then
			existing:Destroy()
			markers[zone] = nil
		end
		return
	end
	local marker = existing or makeMarker(zone)
	markers[zone] = marker
	marker.Enabled = not isScripted()
end

local function watchZone(zone: Instance)
	if not zone:IsA("BasePart") then return end
	zone:GetAttributeChangedSignal(ZoneUtils.RENTED_BY_ATTRIBUTE):Connect(function()
		refreshMarker(zone)
	end)
	refreshMarker(zone)
end

task.spawn(function()
	local zonesFolder = Workspace:WaitForChild("EngineZones")
	for _, zone in ipairs(zonesFolder:GetChildren()) do
		watchZone(zone)
	end
	zonesFolder.ChildAdded:Connect(watchZone)
	zonesFolder.ChildRemoved:Connect(function(zone)
		if zone:IsA("BasePart") and markers[zone] then
			markers[zone]:Destroy()
			markers[zone] = nil
		end
	end)
end)

camera:GetPropertyChangedSignal("CameraType"):Connect(function()
	for zone in pairs(markers) do
		refreshMarker(zone)
	end
end)
