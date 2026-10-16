--!strict
--[[
    WorkbenchCameraController (LocalScript)
    ---------------------------------------
    The workbench view: press the bench's prompt (E) to enter, E again to
    leave.

    While in bench view:
    - the camera frames the bench's PartAnchor (or Main) with a slight sway
      that follows the mouse, plus depth of field
    - the player's character is hidden and can't move
    - left-drag on empty space rotates the part on the bench (drags that
      start on UI, like the REPAIR button, are ignored)

    Fires ClientSignals.WorkbenchViewChanged (true on enter, false on
    leave), which RepairUI listens to.

    Workspace setup it expects: Workspace.Workbench with a BasePart "Main"
    (holds the prompt) and optionally a BasePart "PartAnchor" (where the part
    sits; Main is used if missing).
]]

local Players              = game:GetService("Players")
local UserInputService     = game:GetService("UserInputService")
local RunService           = game:GetService("RunService")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local Lighting             = game:GetService("Lighting")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- ── Config ────────────────────────────────────────────────────────────────────

local EXIT_KEY        = Enum.KeyCode.E
local ENTRY_GUARD     = 0.3  -- seconds after entering before E can exit (same key as the prompt)
local PART_HEIGHT     = 1.2  -- studs above the anchor the part sits at (RepairUI uses the same)
local ROT_SENSITIVITY = 0.5  -- degrees per pixel of drag
local SWAY_INTENSITY  = 1.2  -- degrees of camera sway at the screen edge
local CAMERA_LERP     = 0.1

local ClientSignals = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ClientSignals"))
local viewChanged   = ClientSignals.WorkbenchViewChanged -- RepairUI listens

-- ── State ─────────────────────────────────────────────────────────────────────

local active          = false
local enteredAt       = 0
local bench: Instance?                = nil -- Workspace.Workbench
local benchPrompt: ProximityPrompt?   = nil
local dynamicDistance = 7
local isDragging      = false
local partRotation    = CFrame.new()
local lastMousePos    = Vector2.zero
local dofEffect: DepthOfFieldEffect?  = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getAnchor(): BasePart?
	local anchor = bench and (bench:FindFirstChild("PartAnchor") or bench:FindFirstChild("Main"))
	if anchor and anchor:IsA("BasePart") then
		return anchor
	end
	return nil
end

local function setDepthOfField(enabled: boolean)
	if enabled and not dofEffect then
		local dof         = Instance.new("DepthOfFieldEffect")
		dof.FarIntensity  = 0.8
		dof.InFocusRadius = 5
		dof.Parent        = Lighting
		dofEffect         = dof
	elseif not enabled and dofEffect then
		dofEffect:Destroy()
		dofEffect = nil
	end
end

local function setCharacterHidden(hidden: boolean)
	local char = player.Character
	if not char then return end
	for _, v in ipairs(char:GetDescendants()) do
		if v:IsA("BasePart") or v:IsA("Decal") then
			v.LocalTransparencyModifier = hidden and 1 or 0
		end
	end
end

-- ── Camera loop ───────────────────────────────────────────────────────────────

local function cameraUpdate()
	if not active then return end
	local anchor = getAnchor()
	local wb     = bench
	if not anchor or not wb then return end
	camera.CameraType = Enum.CameraType.Scriptable

	local focusPoint = anchor.Position
	local found = wb:FindFirstChild("PartOnBench", true)
	local part  = if found and found:IsA("Model") then found else nil

	-- Drag to rotate the part
	if isDragging and part then
		local mousePos = UserInputService:GetMouseLocation()
		local delta    = mousePos - lastMousePos
		lastMousePos   = mousePos
		partRotation = CFrame.Angles(0, math.rad(-delta.X * ROT_SENSITIVITY), 0)
			* CFrame.Angles(math.rad(-delta.Y * ROT_SENSITIVITY), 0, 0)
			* partRotation
	end

	-- Hold the part on the anchor and frame the camera to its size
	if part then
		dynamicDistance = math.clamp(part:GetExtentsSize().Magnitude * 2.5, 4.5, 12)
		part:PivotTo(CFrame.new(focusPoint + Vector3.new(0, PART_HEIGHT, 0)) * partRotation)
		if dofEffect then
			dofEffect.FocusDistance = (camera.CFrame.Position - focusPoint).Magnitude
		end
	end

	-- Slight sway toward the mouse
	local mousePos   = UserInputService:GetMouseLocation()
	local screenSize = camera.ViewportSize
	local offX = (mousePos.X / screenSize.X) - 0.5
	local offY = (mousePos.Y / screenSize.Y) - 0.5

	local targetPos    = focusPoint + Vector3.new(0, 5, 5).Unit * dynamicDistance
	local targetCFrame = CFrame.lookAt(targetPos, focusPoint)
		* CFrame.Angles(math.rad(-offY * SWAY_INTENSITY), math.rad(-offX * SWAY_INTENSITY), 0)

	camera.CFrame = camera.CFrame:Lerp(targetCFrame, CAMERA_LERP)
end

-- ── Enter / exit ──────────────────────────────────────────────────────────────

local function exitBench()
	if not active then return end
	active     = false
	isDragging = false

	RunService:UnbindFromRenderStep("WorkbenchCameraLoop")
	RunService:UnbindFromRenderStep("WorkbenchCharacterHider")
	ContextActionService:UnbindAction("WorkbenchFreeze")

	setDepthOfField(false)
	setCharacterHidden(false)
	partRotation      = CFrame.new()
	camera.CameraType = Enum.CameraType.Custom

	if benchPrompt then benchPrompt.Enabled = true end
	viewChanged:Fire(false)
end

local function enterBench()
	if active or not getAnchor() then return end
	active    = true
	enteredAt = os.clock()

	if benchPrompt then benchPrompt.Enabled = false end
	setDepthOfField(true)

	ContextActionService:BindAction("WorkbenchFreeze", function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space)

	-- Hidden every frame because Roblox's own camera scripts also write
	-- LocalTransparencyModifier.
	RunService:BindToRenderStep("WorkbenchCharacterHider", Enum.RenderPriority.Character.Value + 1, function()
		setCharacterHidden(true)
	end)
	RunService:BindToRenderStep("WorkbenchCameraLoop", Enum.RenderPriority.Camera.Value + 1, cameraUpdate)

	viewChanged:Fire(true)
end

-- ── Input ─────────────────────────────────────────────────────────────────────
-- `processed` is true when UI already used the input — typing in the
-- inventory search box, or clicking the REPAIR / REPLACE buttons — so those
-- never exit the bench or start rotating the part.

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not active then return end

	if input.KeyCode == EXIT_KEY and os.clock() - enteredAt >= ENTRY_GUARD then
		exitBench()
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		isDragging   = true
		lastMousePos = UserInputService:GetMouseLocation()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		isDragging = false
	end
end)

-- Respawning or leaving mid-view never leaves the camera stuck.
player.CharacterRemoving:Connect(exitBench)

-- ── Setup ─────────────────────────────────────────────────────────────────────

task.spawn(function()
	bench = workspace:WaitForChild("Workbench", 15)
	local main = bench and bench:WaitForChild("Main", 5)
	if not main then
		warn("[WorkbenchCameraController] Workspace.Workbench.Main not found — workbench disabled")
		return
	end

	local prompt: ProximityPrompt
	local existing = main:FindFirstChildWhichIsA("ProximityPrompt")
	if existing and existing:IsA("ProximityPrompt") then
		prompt = existing
	else
		prompt        = Instance.new("ProximityPrompt")
		prompt.Parent = main
	end
	prompt.ActionText          = "Repair"
	prompt.KeyboardKeyCode     = EXIT_KEY
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration        = 0
	prompt.Triggered:Connect(enterBench)
	benchPrompt = prompt
end)
