--!strict
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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player  = Players.LocalPlayer
local Modules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local UI      = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UI")

local InspectionState = require(Modules:WaitForChild("InspectionState"))
local EngineContext   = require(Modules:WaitForChild("EngineContext"))
local GUIBuilder      = require(UI:WaitForChild("GUIBuilder"))
local WearDisplay     = require(UI:WaitForChild("WearDisplay"))
local UITheme         = require(UI:WaitForChild("UITheme"))

-- ── State ─────────────────────────────────────────────────────────────────────

local currentGUI: BillboardGui?                = nil
local currentModel: Model?                    = nil
local currentLabels: GUIBuilder.Labels?       = nil
local wearConnection: RBXScriptConnection?    = nil
local dwellConn: (() -> ())?                  = nil -- unsubscribe
local inspectedConn: (() -> ())?              = nil -- unsubscribe
local equippedTool: string?                   = nil

local FADE_TIME = 0.25

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function fadeIn(label: TextLabel, targetTransparency: number?)
	TweenService:Create(label,
		TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad),
		{ TextTransparency = targetTransparency or 0 }
	):Play()
end

-- ── Cleanup ───────────────────────────────────────────────────────────────────

local function cleanup()
	local wear, dwell, inspected, gui = wearConnection, dwellConn, inspectedConn, currentGUI
	wearConnection, dwellConn, inspectedConn, currentGUI = nil, nil, nil, nil
	if wear      then wear:Disconnect() end
	if dwell     then dwell() end
	if inspected then inspected() end
	if gui       then GUIBuilder.Destroy(gui) end
	currentModel  = nil
	currentLabels = nil
end

-- ── Show GUI ──────────────────────────────────────────────────────────────────

local function showGUI(target: Instance?)
	-- Guard: don't recreate if same model already showing
	if target == currentModel and currentGUI then return end
	cleanup()
	if not target or not target:IsA("Model") then return end
	local model: Model = target

	local part: BasePart? = model.PrimaryPart
		or model:FindFirstChildWhichIsA("BasePart")
	if not part then return end

	local gui, labels = GUIBuilder.Create(model)
	if not gui or not labels then return end

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
		labels.barFill.BackgroundColor3 = UITheme.Colors.Text
	end)

	-- Watch for inspection completing
	inspectedConn = InspectionState.OnInspectedChanged(
		function(changedModel, isInspected)
			if changedModel ~= model or not isInspected then return end
			if not currentLabels then return end

			-- Disconnect dwell driver
			local dwell = dwellConn
		if dwell then dwell(); dwellConn = nil end

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

local function watchTools(char: Model)
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