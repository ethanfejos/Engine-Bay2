--[[
    InspectionUI (LocalScript)
    --------------------------
    - Shows billboard on hover with name only
    - Fades in name label and status label on hover
    - On inspection complete: hides status row, shows wear row,
      WearDisplay takes over bar and label
    - Tool gate: only active when InspectionTool is equipped
    - Cleans up on unequip, view exit, character reset
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player  = Players.LocalPlayer
local Modules = ReplicatedStorage:WaitForChild("Modules")
local UI      = ReplicatedStorage:WaitForChild("UI")

local InspectionState = require(Modules:WaitForChild("InspectionState"))
local EngineContext   = require(Modules:WaitForChild("EngineContext"))
local GUIBuilder      = require(UI:WaitForChild("GUIBuilder"))
local WearDisplay     = require(UI:WaitForChild("WearDisplay"))

-- ── State ─────────────────────────────────────────────────────────────────────

local currentGUI      = nil
local currentModel    = nil
local currentLabels   = nil
local wearConnection  = nil
local dwellConn       = nil
local inspectedConn   = nil
local equippedTool    = nil

local FADE_TIME = 0.25

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function wearColor(w)
	w = math.clamp(w or 100, 0, 100) / 100
	if w <= 0.5 then
		return Color3.new(1, w / 0.5, 0)
	else
		return Color3.new(1 - (w - 0.5) / 0.5, 1, 0)
	end
end

local function fadeIn(label, targetTransparency)
	TweenService:Create(label,
		TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad),
		{ TextTransparency = targetTransparency or 0 }
	):Play()
end

-- ── Cleanup ───────────────────────────────────────────────────────────────────

local function cleanup()
	if wearConnection  then wearConnection:Disconnect()  wearConnection  = nil end
	if dwellConn       then dwellConn()                  dwellConn       = nil end
	if inspectedConn   then inspectedConn()              inspectedConn   = nil end
	if currentGUI      then GUIBuilder.Destroy(currentGUI) currentGUI   = nil end
	currentModel  = nil
	currentLabels = nil
end

-- ── Show GUI ──────────────────────────────────────────────────────────────────

local function showGUI(model)
	-- Guard: don't recreate if same model already showing
	if model == currentModel and currentGUI then return end
	cleanup()
	if not model then return end

	local part = model.PrimaryPart
		or model:FindFirstChildWhichIsA("BasePart")
	if not part then return end

	local gui, labels = GUIBuilder.Create(model)
	if not gui then return end

	currentGUI    = gui
	currentModel  = model
	currentLabels = labels

	-- Fade in name and status labels
	fadeIn(labels.name,   0)
	fadeIn(labels.status, 0)

	-- If already inspected skip straight to wear display
	if InspectionState.IsInspected(model) then
		labels.statusRow.Visible = false
		labels.wearRow.Visible   = true
		labels.wear.TextTransparency = 0
		wearConnection = WearDisplay.Start(model, labels, part)
		return
	end

	-- Drive progress bar during dwell
	dwellConn = InspectionState.OnDwellProgressChanged(function(t)
		if currentModel ~= model then return end
		if not labels.barTrack then return end
		if t > 0 then
			-- Hide status, show bar only (no wear label yet)
			labels.statusRow.Visible     = false
			labels.wearRow.Visible       = true
			labels.wear.TextTransparency = 1
		else
			-- Progress reset to 0 (released) — show status again
			labels.statusRow.Visible = true
			labels.wearRow.Visible   = false
		end
		labels.barFill.Size             = UDim2.new(math.clamp(t, 0, 1), 0, 1, 0)
		labels.barFill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	end)

	-- Watch for inspection completing
	inspectedConn = InspectionState.OnInspectedChanged(
		function(changedModel, isInspected)
			if changedModel ~= model or not isInspected then return end
			if not currentLabels then return end

			-- Disconnect dwell driver
			if dwellConn then dwellConn() dwellConn = nil end

			-- Swap status for wear row
			labels.statusRow.Visible = false
			labels.wearRow.Visible   = true

			-- Fade in wear label
			fadeIn(labels.wear, 0)

			-- Hand off to WearDisplay which animates bar to wear value
			wearConnection = WearDisplay.Start(model, labels, part)
		end
	)
end

-- ── React to target changes ───────────────────────────────────────────────────

InspectionState.OnChanged(function(model)
	if equippedTool ~= "InspectionTool" then return end
	if not EngineContext.IsInEngineView() then return end
	showGUI(model)
end)

EngineContext.OnViewChanged(function(active)
	if not active then cleanup() end
end)

-- ── Tool gate ─────────────────────────────────────────────────────────────────

local function watchTools(char)
	local function check()
		local tool = char:FindFirstChildOfClass("Tool")
		equippedTool = tool and tool.Name or nil
		if equippedTool ~= "InspectionTool" then
			cleanup()
		end
	end

	char.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then check() end
	end)
	char.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then check() end
	end)
	check()
end

player.CharacterAdded:Connect(watchTools)
if player.Character then watchTools(player.Character) end

player.CharacterRemoving:Connect(cleanup)