--[[
    EngineCameraController (LocalScript)
    -------------------------------------
    Updated Version:
    - Reconfigured Boot pipeline to use the updated ToolRegistry
    - Resolves targets within Workspace.Engines via '.GetEngineInstance()'
    - Retains cinematic transitions, input sinking, and bounding-box orbit logic
]]

local Players            = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local player  = Players.LocalPlayer
local camera  = Workspace.CurrentCamera
local Modules = ReplicatedStorage:WaitForChild("Modules")

local EngineContext    = require(Modules:WaitForChild("EngineContext"))
local CharacterManager = require(Modules:WaitForChild("CharacterManager"))
local ToolRegistry     = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolRegistry"))

-- ── Config ────────────────────────────────────────────────────────────────────

local BIRDS_EYE_PITCH    = 75
local BIRDS_EYE_DISTANCE = 14
local BIRDS_EYE_TWEEN    = 0.7
local BIRDS_EYE_PAUSE    = 0.6
local TILT_DOWN_PITCH    = 20
local TILT_DOWN_DISTANCE = 8
local TILT_DOWN_TWEEN    = 0.9

local MIN_DISTANCE       = 2
local MAX_DISTANCE       = 20
local ZOOM_SPEED         = 1.2
local ZOOM_DAMP          = 8
local ORBIT_SENSITIVITY  = 0.35

local VERTICAL_MIN    = -75
local VERTICAL_MAX    = 80
local SOFT_ZONE       = 15
local SOFT_MIN_FACTOR = 0.08

local PAN_SENSITIVITY = 0.06  
local PAN_DAMP        = 6     
local PAN_BOX_HALF    = Vector3.new(6, 3, 6)  

local EXIT_KEY = Enum.KeyCode.E

-- ── State ─────────────────────────────────────────────────────────────────────

local active        = false
local dragging      = false
local panning      = false
local orbitYaw      = 0
local orbitPitch    = BIRDS_EYE_PITCH
local orbitDistance = BIRDS_EYE_DISTANCE
local zoomTarget    = TILT_DOWN_DISTANCE
local engineCenter  = Vector3.new()  
local pivotOffset   = Vector3.new()  
local pivotTarget   = Vector3.new()  
local activePrompt  = nil
local entryTween    = nil

local renderConnection = nil
local inputBeganConn   = nil
local inputEndedConn   = nil
local inputChangedConn = nil

local exitEngineView

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getEnginePivot(engine)
	if engine.PrimaryPart then
		return engine.PrimaryPart.CFrame
	end
	local cf, _ = engine:GetBoundingBox()
	return cf
end

local function getPivotPosition()
	return engineCenter + pivotOffset
end

local function orbitCFrame()
	local yawRad   = math.rad(orbitYaw)
	local pitchRad = math.rad(orbitPitch)
	local x = orbitDistance * math.cos(pitchRad) * math.sin(yawRad)
	local y = orbitDistance * math.sin(pitchRad)
	local z = orbitDistance * math.cos(pitchRad) * math.cos(yawRad)
	local pivot = getPivotPosition()
	return CFrame.lookAt(
		pivot + Vector3.new(x, y, z),
		pivot
	)
end

local function softResistance(currentPitch, delta)
	local factor = 1
	if delta > 0 then
		local dist = VERTICAL_MAX - currentPitch
		if dist < SOFT_ZONE then
			factor = SOFT_MIN_FACTOR + (1 - SOFT_MIN_FACTOR) * (dist / SOFT_ZONE)
		end
	elseif delta < 0 then
		local dist = currentPitch - VERTICAL_MIN
		if dist < SOFT_ZONE then
			factor = SOFT_MIN_FACTOR + (1 - SOFT_MIN_FACTOR) * (dist / SOFT_ZONE)
		end
	end
	return math.clamp(factor, SOFT_MIN_FACTOR, 1)
end

-- ── Pan ───────────────────────────────────────────────────────────────────────

local function applyPan(deltaX, deltaY)
	local camCFrame = camera.CFrame
	local right     = camCFrame.RightVector
	local up        = camCFrame.UpVector

	right = Vector3.new(right.X, 0, right.Z)
	if right.Magnitude > 0.01 then
		right = right.Unit
	end

	local panDelta = (-right * deltaX + up * deltaY) * PAN_SENSITIVITY
	local newTarget = pivotTarget + panDelta

	pivotTarget = Vector3.new(
		math.clamp(newTarget.X, -PAN_BOX_HALF.X, PAN_BOX_HALF.X),
		math.clamp(newTarget.Y, -PAN_BOX_HALF.Y, PAN_BOX_HALF.Y),
		math.clamp(newTarget.Z, -PAN_BOX_HALF.Z, PAN_BOX_HALF.Z)
	)
end

-- ── Orbit loop ────────────────────────────────────────────────────────────────

local function startOrbitLoop()
	if renderConnection then renderConnection:Disconnect() end
	renderConnection = RunService.RenderStepped:Connect(function(dt)
		if not active then return end

		local keyPanX = 0
		local keyPanZ = 0
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then keyPanZ = keyPanZ + 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then keyPanZ = keyPanZ - 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then keyPanX = keyPanX - 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then keyPanX = keyPanX + 1 end

		if keyPanX ~= 0 or keyPanZ ~= 0 then
			local yawRad = math.rad(orbitYaw)
			local forward = Vector3.new(-math.sin(yawRad), 0, -math.cos(yawRad))
			local right   = Vector3.new(math.cos(yawRad),  0, -math.sin(yawRad))

			local keyDelta = (right * keyPanX + forward * keyPanZ) * PAN_SENSITIVITY * 60 * dt
			local newTarget = pivotTarget + keyDelta

			pivotTarget = Vector3.new(
				math.clamp(newTarget.X, -PAN_BOX_HALF.X, PAN_BOX_HALF.X),
				math.clamp(newTarget.Y, -PAN_BOX_HALF.Y, PAN_BOX_HALF.Y),
				math.clamp(newTarget.Z, -PAN_BOX_HALF.Z, PAN_BOX_HALF.Z)
			)
		end

		orbitDistance = orbitDistance + (zoomTarget - orbitDistance) * math.clamp(dt * ZOOM_DAMP, 0, 1)
		pivotOffset = pivotOffset + (pivotTarget - pivotOffset) * math.clamp(dt * PAN_DAMP, 0, 1)

		camera.CFrame = orbitCFrame()
	end)
end

local function stopOrbitLoop()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

-- ── Orbit input ───────────────────────────────────────────────────────────────

local function disconnectOrbitInput()
	if inputBeganConn   then inputBeganConn:Disconnect()   inputBeganConn   = nil end
	if inputEndedConn   then inputEndedConn:Disconnect()   inputEndedConn   = nil end
	if inputChangedConn then inputChangedConn:Disconnect() inputChangedConn = nil end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	dragging = false
	panning  = false
end

local function connectOrbitInput()
	inputBeganConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			dragging = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
		if input.UserInputType == Enum.UserInputType.MouseButton3 then
			panning = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end)

	inputEndedConn = UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			dragging = false
			if not panning then UserInputService.MouseBehavior = Enum.MouseBehavior.Default end
		end
		if input.UserInputType == Enum.UserInputType.MouseButton3 then
			panning = false
			if not dragging then UserInputService.MouseBehavior = Enum.MouseBehavior.Default end
		end
	end)

	inputChangedConn = UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			if panning then
				applyPan(input.Delta.X, input.Delta.Y)
			elseif dragging then
				local pitchDelta = input.Delta.Y * ORBIT_SENSITIVITY
				local resistance = softResistance(orbitPitch, pitchDelta)
				orbitYaw   = orbitYaw - input.Delta.X * ORBIT_SENSITIVITY
				orbitPitch = math.clamp(orbitPitch + pitchDelta * resistance, VERTICAL_MIN, VERTICAL_MAX)
			end
		end

		if input.UserInputType == Enum.UserInputType.MouseWheel then
			zoomTarget = math.clamp(zoomTarget - input.Position.Z * ZOOM_SPEED, MIN_DISTANCE, MAX_DISTANCE)
		end
	end)
end

-- ── E key ─────────────────────────────────────────────────────────────────────

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == EXIT_KEY and active then
		exitEngineView()
	end
end)

-- ── Orbit tween ───────────────────────────────────────────────────────────────

local function tweenOrbitTo(targetPitch, targetDistance, duration, onComplete)
	local startPitch    = orbitPitch
	local startDistance = orbitDistance
	local elapsed       = 0
	local cancelled     = false
	local conn          = nil

	conn = RunService.RenderStepped:Connect(function(dt)
		if cancelled then return end
		elapsed = elapsed + dt
		local t = math.clamp(elapsed / duration, 0, 1)
		local ease = t < 0.5 and 2 * t * t or 1 - (-2 * t + 2)^2 / 2

		orbitPitch    = startPitch    + (targetPitch    - startPitch)    * ease
		orbitDistance = startDistance + (targetDistance - startDistance) * ease
		zoomTarget    = orbitDistance

		if t >= 1 then
			cancelled = true
			if conn then conn:Disconnect() conn = nil end
			if onComplete then onComplete() end
		end
	end)

	return function()
		cancelled = true
		if conn then conn:Disconnect() conn = nil end
	end
end

-- ── Enter / Exit ──────────────────────────────────────────────────────────────

exitEngineView = function()
	if not active then return end
	active = false

	if entryTween then
		entryTween()
		entryTween = nil
	end

	stopOrbitLoop()
	disconnectOrbitInput()

	camera.CameraType = Enum.CameraType.Custom
	UserInputService.MouseIconEnabled = true

	if activePrompt then activePrompt.Enabled = true end

	local char = player.Character
	if char then CharacterManager.Show(char) end

	ContextActionService:UnbindAction("SinkMovement")
	EngineContext.SetInEngineView(false)
end

local function enterEngineView(engine, prompt)
	if active then return end

	local char = player.Character
	if not char then return end

	active        = true
	activePrompt  = prompt
	pivotOffset   = Vector3.new()  
	pivotTarget   = Vector3.new()  

	local engineCF = getEnginePivot(engine)
	engineCenter   = engineCF.Position

	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp then
		local toEngine = engineCenter - hrp.Position
		toEngine = Vector3.new(toEngine.X, 0, toEngine.Z)
		if toEngine.Magnitude > 0.01 then
			toEngine = toEngine.Unit
			orbitYaw = math.deg(math.atan2(toEngine.X, toEngine.Z)) + 180
		else
			orbitYaw = 0
		end
	else
		orbitYaw = 0
	end

	orbitPitch    = 15
	orbitDistance = TILT_DOWN_DISTANCE
	zoomTarget    = BIRDS_EYE_DISTANCE

	prompt.Enabled = false
	CharacterManager.Hide(char)

	local function sinkInput() return Enum.ContextActionResult.Sink end
	ContextActionService:BindAction("SinkMovement", sinkInput, false,
		Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space
	)

	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseIconEnabled = true
	camera.CFrame = orbitCFrame()

	startOrbitLoop()

	entryTween = tweenOrbitTo(
		BIRDS_EYE_PITCH,
		BIRDS_EYE_DISTANCE,
		BIRDS_EYE_TWEEN,
		function()
			if not active then return end
			entryTween = nil
			task.delay(BIRDS_EYE_PAUSE, function()
				if not active then return end
				entryTween = tweenOrbitTo(
					TILT_DOWN_PITCH,
					TILT_DOWN_DISTANCE,
					TILT_DOWN_TWEEN,
					function()
						if not active then return end
						entryTween = nil
						zoomTarget = TILT_DOWN_DISTANCE
						connectOrbitInput()
						EngineContext.Init(engine)
						EngineContext.SetInEngineView(true)
					end
				)
			end)
		end
	)
end

-- ── ProximityPrompt wiring ────────────────────────────────────────────────────

local function wirePrompt(engine)
	local trigger = engine:WaitForChild("EngineTrigger", 10)
	if not trigger then return end

	local prompt = trigger:FindFirstChildWhichIsA("ProximityPrompt") or trigger:WaitForChild("ProximityPrompt", 5)
	if not prompt then return end

	prompt.Triggered:Connect(function()
		-- Verify that this engine model is currently visible before allowing entry
		local primary = engine.PrimaryPart or engine:FindFirstChildWhichIsA("BasePart", true)
		if primary and primary.LocalTransparencyModifier < 0.5 then
			if not active then
				enterEngineView(engine, prompt)
			end
		end
	end)
end

-- ── Registry Mapped Folder Boot ───────────────────────────────────────────────

local wiredNames = {}
for _, zoneId in ipairs(ToolRegistry.GetAllZoneIds()) do
	local partName = ToolRegistry.GetPartNameForZone(zoneId)
	if partName and not wiredNames[partName] then
		wiredNames[partName] = true

		task.spawn(function()
			-- Pull instance specifically from Workspace.Engines layout rule
			local engine = ToolRegistry.GetEngineInstance(zoneId, 10)
			if not engine then
				warn("[EngineCameraController] Registered engine not found inside folder structure:", partName)
				return
			end
			wirePrompt(engine)
		end)
	end
end