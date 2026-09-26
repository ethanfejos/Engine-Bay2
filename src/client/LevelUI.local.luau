--[[
    LevelUI (LocalScript)
    ---------------------
    Always-visible level + XP bar in the bottom-left corner, plus a
    level-up popup banner. Purely a display — all XP math and awarding
    happens server-side in LevelService; this just renders what it's told.

    - XpUpdated  (server -> client): updates the bar/label, tweened
    - LeveledUp  (server -> client): triggers the popup + a pulse on the
      level label
    - Fires RequestXp on join to get the current values immediately,
      same pattern InventoryUI uses for RequestInventory.
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remoteFolder    = ReplicatedStorage:WaitForChild("RemoteEvents")
local xpUpdatedEvent  = remoteFolder:WaitForChild("XpUpdated")
local leveledUpEvent  = remoteFolder:WaitForChild("LeveledUp")
local requestXpEvent  = remoteFolder:WaitForChild("RequestXp")

-- ── Palette (matches GUIBuilder's white/Gotham HUD style) ───────────────────────

local WHITE   = Color3.fromRGB(255, 255, 255)
local DIM     = Color3.fromRGB(200, 200, 200)
local BAR_BG  = Color3.fromRGB(40, 40, 40)
local GREEN   = Color3.fromRGB(0, 200, 120) -- matches RepairUI's accent

-- ── Build GUI ─────────────────────────────────────────────────────────────────

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LevelUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = false
screenGui.Parent = playerGui

local container = Instance.new("Frame")
container.Name = "LevelContainer"
container.AnchorPoint = Vector2.new(0, 1)
container.Position = UDim2.new(0, 24, 1, -24)
container.Size = UDim2.new(0, 220, 0, 46)
container.BackgroundTransparency = 1
container.Parent = screenGui

local levelLabel = Instance.new("TextLabel")
levelLabel.Name = "LevelLabel"
levelLabel.BackgroundTransparency = 1
levelLabel.Size = UDim2.new(1, 0, 0, 20)
levelLabel.Position = UDim2.new(0, 0, 0, 0)
levelLabel.Font = Enum.Font.GothamBold
levelLabel.TextSize = 16
levelLabel.TextColor3 = WHITE
levelLabel.TextXAlignment = Enum.TextXAlignment.Left
levelLabel.Text = "LEVEL 1"
levelLabel.Parent = container

local xpLabel = Instance.new("TextLabel")
xpLabel.Name = "XpLabel"
xpLabel.BackgroundTransparency = 1
xpLabel.Size = UDim2.new(1, 0, 0, 20)
xpLabel.Position = UDim2.new(0, 0, 0, 0)
xpLabel.Font = Enum.Font.Gotham
xpLabel.TextSize = 12
xpLabel.TextColor3 = DIM
xpLabel.TextXAlignment = Enum.TextXAlignment.Right
xpLabel.Text = "0 / 100 XP"
xpLabel.Parent = container

local track = Instance.new("Frame")
track.Name = "Track"
track.BackgroundColor3 = BAR_BG
track.BorderSizePixel = 0
track.Size = UDim2.new(1, 0, 0, 10)
track.Position = UDim2.new(0, 0, 0, 26)
track.Parent = container
Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.BackgroundColor3 = GREEN
fill.BorderSizePixel = 0
fill.Size = UDim2.new(0, 0, 1, 0)
fill.Parent = track
Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

-- ── Level-up popup ────────────────────────────────────────────────────────────

local popup = Instance.new("TextLabel")
popup.Name = "LevelUpPopup"
popup.AnchorPoint = Vector2.new(0.5, 0.5)
popup.Position = UDim2.new(0.5, 0, 0.35, 0)
popup.Size = UDim2.new(0, 400, 0, 60)
popup.BackgroundTransparency = 1
popup.Font = Enum.Font.GothamBold
popup.TextSize = 36
popup.TextColor3 = GREEN
popup.TextTransparency = 1
popup.Text = ""
popup.Parent = screenGui

local function showLevelUpPopup(newLevel)
	popup.Text = "LEVEL UP! — LVL " .. newLevel
	popup.TextTransparency = 1
	popup.Position = UDim2.new(0.5, 0, 0.4, 0)

	local fadeIn = TweenService:Create(popup, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 0,
		Position = UDim2.new(0.5, 0, 0.35, 0),
	})
	fadeIn:Play()
	fadeIn.Completed:Wait()

	task.wait(1.2)

	local fadeOut = TweenService:Create(popup, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		Position = UDim2.new(0.5, 0, 0.3, 0),
	})
	fadeOut:Play()
end

-- Quick color pulse on the level label itself, so the bar area also reacts
-- even if the player's looking away from the popup.
local function pulseLevelLabel()
	local original = levelLabel.TextColor3
	TweenService:Create(levelLabel, TweenInfo.new(0.12), { TextColor3 = GREEN }):Play()
	task.delay(0.12, function()
		TweenService:Create(levelLabel, TweenInfo.new(0.4), { TextColor3 = original }):Play()
	end)
end

-- ── Event handlers ────────────────────────────────────────────────────────────

xpUpdatedEvent.OnClientEvent:Connect(function(totalXp, level, xpIntoLevel, xpForNextLevel)
	levelLabel.Text = "LEVEL " .. level
	xpLabel.Text = xpIntoLevel .. " / " .. xpForNextLevel .. " XP"

	local progress = xpForNextLevel > 0 and math.clamp(xpIntoLevel / xpForNextLevel, 0, 1) or 0
	TweenService:Create(fill, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(progress, 0, 1, 0),
	}):Play()
end)

leveledUpEvent.OnClientEvent:Connect(function(newLevel)
	pulseLevelLabel()
	task.spawn(showLevelUpPopup, newLevel)
end)

-- ── Initial sync ──────────────────────────────────────────────────────────────

requestXpEvent:FireServer()
