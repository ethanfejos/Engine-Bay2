-- [[ UNIFIED WORKBENCH MASTER CONTROLLER - TARGETED ANCHOR VERSION ]]
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- ── Config & State ────────────────────────────────────────────────────────────
local EXIT_KEY = Enum.KeyCode.E
local active = false
local currentTarget = nil -- This will be the "Main" part for the Prompt
local dynamicDistance = 7
local lastToggleTime = 0
local COOLDOWN = 0.5 

local isDragging = false
local partRotation = CFrame.new() 
local lastMousePos = Vector2.new(0, 0)
local ROT_SENSITIVITY = 0.5
local SWAY_INTENSITY = 1.2

local dofEffect = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function getWorkbench()
	return workspace:FindFirstChild("Workbench")
end

local function getAnchor(wb)
	-- Searches for "PartAnchor", falls back to "Main" if missing
	return wb:FindFirstChild("PartAnchor") or wb:FindFirstChild("Main")
end

-- ── Effects ───────────────────────────────────────────────────────────────────
local function toggleDOF(enabled)
	if enabled then
		if not dofEffect then
			dofEffect = Instance.new("DepthOfFieldEffect")
			dofEffect.FarIntensity = 0.8
			dofEffect.InFocusRadius = 5
			dofEffect.Parent = Lighting
		end
	else
		if dofEffect then dofEffect:Destroy(); dofEffect = nil end
	end
end

-- ── Hard Reset ────────────────────────────────────────────────────────────────
local function resetCameraToNormal()
	if not active or (tick() - lastToggleTime < COOLDOWN) then return end
	active = false
	lastToggleTime = tick()

	RunService:UnbindFromRenderStep("WorkbenchCameraLoop")
	RunService:UnbindFromRenderStep("CharacterHider")

	toggleDOF(false)
	partRotation = CFrame.new() 

	camera.CameraType = Enum.CameraType.Custom
	ContextActionService:UnbindAction("WorkbenchFreeze")

	if player.Character then
		for _, v in ipairs(player.Character:GetDescendants()) do
			if v:IsA("BasePart") or v:IsA("Decal") then v.LocalTransparencyModifier = 0 end
		end
	end

	local wb = getWorkbench()
	local prompt = wb and wb:FindFirstChild("Main") and wb.Main:FindFirstChildWhichIsA("ProximityPrompt")
	if prompt then prompt.Enabled = true end

	local event = ReplicatedStorage:FindFirstChild("WorkbenchViewChanged")
	if event then event:Fire(false) end
end

-- ── The Core Loop ─────────────────────────────────────────────────────────────
local function cameraUpdate()
	if not active or not currentTarget then return end
	camera.CameraType = Enum.CameraType.Scriptable

	local wb = getWorkbench()
	if not wb then return end

	local anchor = getAnchor(wb)
	local part = wb:FindFirstChild("PartOnBench", true)

	-- 1. Handle Drag Rotation
	if isDragging and part then
		local delta = UserInputService:GetMouseLocation() - lastMousePos
		lastMousePos = UserInputService:GetMouseLocation()
		local newRot = CFrame.Angles(0, math.rad(-delta.X * ROT_SENSITIVITY), 0) * CFrame.Angles(math.rad(-delta.Y * ROT_SENSITIVITY), 0, 0)
		partRotation = newRot * partRotation
	end

	-- 2. Position and Framing
	local focusPoint = anchor.Position
	if part then
		local size = part:GetExtentsSize().Magnitude
		dynamicDistance = math.clamp(size * 2.5, 4.5, 12)

		-- Anchor the part to the PartAnchor position
		part:PivotTo(CFrame.new(focusPoint + Vector3.new(0, 1.2, 0)) * partRotation)

		if dofEffect then
			dofEffect.FocusDistance = (camera.CFrame.Position - focusPoint).Magnitude
		end
	end

	-- 3. Camera Math (Looking at the Anchor)
	local mousePos = UserInputService:GetMouseLocation()
	local screenSize = camera.ViewportSize
	local offX = (mousePos.X / screenSize.X) - 0.5
	local offY = (mousePos.Y / screenSize.Y) - 0.5

	local targetPos = focusPoint + (Vector3.new(0, 5, 5).Unit * dynamicDistance)
	local targetCFrame = CFrame.lookAt(targetPos, focusPoint) * CFrame.Angles(math.rad(-offY * SWAY_INTENSITY), math.rad(-offX * SWAY_INTENSITY), 0)

	camera.CFrame = camera.CFrame:Lerp(targetCFrame, 0.1)
end

-- ── Initialization & Input ────────────────────────────────────────────────────
local function enterWorkbench(mainPart, prompt)
	if active or (tick() - lastToggleTime < COOLDOWN) then return end
	active = true
	lastToggleTime = tick()
	currentTarget = mainPart
	prompt.Enabled = false
	toggleDOF(true)

	ContextActionService:BindAction("WorkbenchFreeze", function() return Enum.ContextActionResult.Sink end, false, 
	Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space)

	RunService:BindToRenderStep("CharacterHider", Enum.RenderPriority.Character.Value + 1, function()
		if player.Character then
			for _, v in ipairs(player.Character:GetDescendants()) do
				if v:IsA("BasePart") or v:IsA("Decal") then v.LocalTransparencyModifier = 1 end
			end
		end
	end)

	RunService:BindToRenderStep("WorkbenchCameraLoop", Enum.RenderPriority.Camera.Value + 1, cameraUpdate)
	local event = ReplicatedStorage:FindFirstChild("WorkbenchViewChanged")
	if event then event:Fire(true) end
end

UserInputService.InputBegan:Connect(function(input, _)
	if input.KeyCode == EXIT_KEY then resetCameraToNormal() end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and active then
		isDragging = true
		lastMousePos = UserInputService:GetMouseLocation()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then isDragging = false end
end)

local function init()
	local wb = workspace:WaitForChild("Workbench", 15)
	local main = wb:WaitForChild("Main", 5)
	local prompt = main:FindFirstChildWhichIsA("ProximityPrompt") or Instance.new("ProximityPrompt", main)
	prompt.ActionText = "Repair"
	prompt.KeyboardKeyCode = EXIT_KEY
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0
	prompt.Parent = main
	prompt.Triggered:Connect(function() enterWorkbench(main, prompt) end)
end

task.spawn(init)