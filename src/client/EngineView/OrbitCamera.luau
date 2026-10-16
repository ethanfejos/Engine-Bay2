--!strict
--[[
    OrbitCamera (ModuleScript, client)
    ----------------------------------
    The engine-view camera: a cinematic entry (bird's-eye, pause, tilt
    down), then an orbit around the engine the player controls:
    - right-drag   orbit (soft resistance near the top/bottom limits)
    - middle-drag  pan
    - W A S D      pan
    - mouse wheel  zoom

        OrbitCamera.Start(engineCenter, startYaw, onSettled)
        OrbitCamera.Stop()

    onSettled runs once the entry animation finishes and the controls are
    live. Stop() can be called at any point, including mid-entry.

    Used by EngineCameraController. Moved here unchanged from it; the
    numbers below are the same as before the split.
]]

local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")

local camera = Workspace.CurrentCamera

-- ── Config ────────────────────────────────────────────────────────────────────

local BIRDS_EYE_PITCH    = 75
local BIRDS_EYE_DISTANCE = 14
local BIRDS_EYE_TWEEN    = 0.7
local BIRDS_EYE_PAUSE    = 0.6
local TILT_DOWN_PITCH    = 20
local TILT_DOWN_DISTANCE = 8
local TILT_DOWN_TWEEN    = 0.9
local ENTRY_START_PITCH  = 15

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

-- ── State ─────────────────────────────────────────────────────────────────────

local running       = false
local dragging      = false
local panning       = false
local orbitYaw      = 0
local orbitPitch    = BIRDS_EYE_PITCH
local orbitDistance = BIRDS_EYE_DISTANCE
local zoomTarget    = TILT_DOWN_DISTANCE
local engineCenter  = Vector3.new()
local pivotOffset   = Vector3.new()
local pivotTarget   = Vector3.new()
local entryTween: (() -> ())? = nil -- cancels the running entry tween

local renderConnection: RBXScriptConnection? = nil
local inputConnections: { RBXScriptConnection } = {}

-- ── Maths ─────────────────────────────────────────────────────────────────────

local function clampToPanBox(v: Vector3): Vector3
	return Vector3.new(
		math.clamp(v.X, -PAN_BOX_HALF.X, PAN_BOX_HALF.X),
		math.clamp(v.Y, -PAN_BOX_HALF.Y, PAN_BOX_HALF.Y),
		math.clamp(v.Z, -PAN_BOX_HALF.Z, PAN_BOX_HALF.Z)
	)
end

local function orbitCFrame(): CFrame
	local yawRad   = math.rad(orbitYaw)
	local pitchRad = math.rad(orbitPitch)
	local x = orbitDistance * math.cos(pitchRad) * math.sin(yawRad)
	local y = orbitDistance * math.sin(pitchRad)
	local z = orbitDistance * math.cos(pitchRad) * math.cos(yawRad)
	local pivot = engineCenter + pivotOffset
	return CFrame.lookAt(pivot + Vector3.new(x, y, z), pivot)
end

local function softResistance(currentPitch: number, delta: number): number
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

local function applyPan(deltaX: number, deltaY: number)
	local camCFrame = camera.CFrame
	local right     = camCFrame.RightVector
	local up        = camCFrame.UpVector

	right = Vector3.new(right.X, 0, right.Z)
	if right.Magnitude > 0.01 then
		right = right.Unit
	end

	pivotTarget = clampToPanBox(pivotTarget + (-right * deltaX + up * deltaY) * PAN_SENSITIVITY)
end

-- ── Render loop ───────────────────────────────────────────────────────────────

local function startLoop()
	local old = renderConnection
	if old then old:Disconnect() end
	renderConnection = RunService.RenderStepped:Connect(function(dt: number)
		if not running then return end

		local keyPanX = 0
		local keyPanZ = 0
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then keyPanZ += 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then keyPanZ -= 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then keyPanX -= 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then keyPanX += 1 end

		if keyPanX ~= 0 or keyPanZ ~= 0 then
			local yawRad  = math.rad(orbitYaw)
			local forward = Vector3.new(-math.sin(yawRad), 0, -math.cos(yawRad))
			local right   = Vector3.new(math.cos(yawRad), 0, -math.sin(yawRad))
			pivotTarget = clampToPanBox(pivotTarget
				+ (right * keyPanX + forward * keyPanZ) * PAN_SENSITIVITY * 60 * dt)
		end

		orbitDistance += (zoomTarget - orbitDistance) * math.clamp(dt * ZOOM_DAMP, 0, 1)
		pivotOffset   += (pivotTarget - pivotOffset) * math.clamp(dt * PAN_DAMP, 0, 1)

		camera.CFrame = orbitCFrame()
	end)
end

local function stopLoop()
	local conn = renderConnection
	if conn then
		conn:Disconnect()
		renderConnection = nil
	end
end

-- ── Player input ──────────────────────────────────────────────────────────────

local function disconnectInput()
	for _, conn in ipairs(inputConnections) do
		conn:Disconnect()
	end
	table.clear(inputConnections)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	dragging = false
	panning  = false
end

local function connectInput()
	disconnectInput()

	table.insert(inputConnections, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			dragging = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
		if input.UserInputType == Enum.UserInputType.MouseButton3 then
			panning = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end))

	table.insert(inputConnections, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			dragging = false
			if not panning then UserInputService.MouseBehavior = Enum.MouseBehavior.Default end
		end
		if input.UserInputType == Enum.UserInputType.MouseButton3 then
			panning = false
			if not dragging then UserInputService.MouseBehavior = Enum.MouseBehavior.Default end
		end
	end))

	table.insert(inputConnections, UserInputService.InputChanged:Connect(function(input: InputObject)
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
	end))
end

-- ── Entry animation ───────────────────────────────────────────────────────────

-- Eases pitch and distance to a target over `duration`. Returns a cancel
-- function.
local function tweenOrbitTo(targetPitch: number, targetDistance: number, duration: number, onComplete: (() -> ())?): () -> ()
	local startPitch    = orbitPitch
	local startDistance = orbitDistance
	local elapsed       = 0
	local cancelled     = false
	local conn: RBXScriptConnection? = nil

	conn = RunService.RenderStepped:Connect(function(dt: number)
		if cancelled then return end
		elapsed += dt
		local t    = math.clamp(elapsed / duration, 0, 1)
		local ease = t < 0.5 and 2 * t * t or 1 - (-2 * t + 2) ^ 2 / 2

		orbitPitch    = startPitch    + (targetPitch    - startPitch)    * ease
		orbitDistance = startDistance + (targetDistance - startDistance) * ease
		zoomTarget    = orbitDistance

		if t >= 1 then
			cancelled = true
			local c = conn
			if c then c:Disconnect(); conn = nil end
			if onComplete then onComplete() end
		end
	end)

	return function()
		cancelled = true
		local c = conn
		if c then c:Disconnect(); conn = nil end
	end
end

-- ── Public ────────────────────────────────────────────────────────────────────

local OrbitCamera = {}

function OrbitCamera.Start(center: Vector3, startYaw: number, onSettled: (() -> ())?)
	OrbitCamera.Stop()
	running = true

	engineCenter  = center
	pivotOffset   = Vector3.new()
	pivotTarget   = Vector3.new()
	orbitYaw      = startYaw
	orbitPitch    = ENTRY_START_PITCH
	orbitDistance = TILT_DOWN_DISTANCE
	zoomTarget    = BIRDS_EYE_DISTANCE

	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseIconEnabled = true
	camera.CFrame = orbitCFrame()

	startLoop()

	-- Bird's-eye, short pause, then tilt down — then hand over control.
	entryTween = tweenOrbitTo(BIRDS_EYE_PITCH, BIRDS_EYE_DISTANCE, BIRDS_EYE_TWEEN, function()
		if not running then return end
		entryTween = nil
		task.delay(BIRDS_EYE_PAUSE, function()
			if not running then return end
			entryTween = tweenOrbitTo(TILT_DOWN_PITCH, TILT_DOWN_DISTANCE, TILT_DOWN_TWEEN, function()
				if not running then return end
				entryTween = nil
				zoomTarget = TILT_DOWN_DISTANCE
				connectInput()
				if onSettled then onSettled() end
			end)
		end)
	end)
end

function OrbitCamera.Stop()
	if not running then return end
	running = false

	local cancelEntry = entryTween
	if cancelEntry then
		cancelEntry()
		entryTween = nil
	end
	stopLoop()
	disconnectInput()

	camera.CameraType = Enum.CameraType.Custom
	UserInputService.MouseIconEnabled = true
end

function OrbitCamera.IsRunning(): boolean
	return running
end

return OrbitCamera
