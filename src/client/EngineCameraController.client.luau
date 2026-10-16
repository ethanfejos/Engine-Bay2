--!strict
--[[
    EngineCameraController (LocalScript)
    -------------------------------------
    Entering and leaving engine view. The work is split into three modules
    in the EngineView folder next to this script:

    - EnginePrompts  finds engines and wires their "enter engine bay" prompt
    - OrbitCamera    the entry animation and the orbit/pan/zoom camera
    - BodyFade       fades body panels between the camera and the engine

    This script ties them together:
    - enter: hide the character, block movement keys, start the camera and
      the fade, then switch EngineContext into engine view once the camera
      has settled (that's what turns on part hover, tools and ghosts)
    - leave (E, or the engine being removed): undo all of it
]]

local Players              = game:GetService("Players")
local UserInputService     = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local Workspace            = game:GetService("Workspace")

local player = Players.LocalPlayer

local Modules          = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local EngineContext    = require(Modules:WaitForChild("EngineContext"))
local CharacterManager = require(Modules:WaitForChild("CharacterManager"))
local Log              = require(Modules:WaitForChild("Log"))

local EngineView    = script.Parent:WaitForChild("EngineView")
local EnginePrompts = require(EngineView:WaitForChild("EnginePrompts"))
local OrbitCamera   = require(EngineView:WaitForChild("OrbitCamera"))
local BodyFade      = require(EngineView:WaitForChild("BodyFade"))

local log = Log.new("EngineCameraController")

local EXIT_KEY     = Enum.KeyCode.E
local SINK_ACTION  = "SinkMovement"

-- ── State ─────────────────────────────────────────────────────────────────────

local currentEngine: Model? = nil -- the engine being viewed

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getEngineCenter(engine: Model): Vector3
	if engine.PrimaryPart then
		return engine.PrimaryPart.Position
	end
	local cf = engine:GetBoundingBox()
	return cf.Position
end

-- Start the orbit behind the player, looking the way they were facing the
-- engine.
local function getStartYaw(engineCenter: Vector3): number
	local char = player.Character
	local hrp  = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then return 0 end

	local toEngine = engineCenter - hrp.Position
	toEngine = Vector3.new(toEngine.X, 0, toEngine.Z)
	if toEngine.Magnitude <= 0.01 then return 0 end
	toEngine = toEngine.Unit
	return math.deg(math.atan2(toEngine.X, toEngine.Z)) + 180
end

-- ── Enter / exit ──────────────────────────────────────────────────────────────

local function exitEngineView()
	if not currentEngine then return end
	currentEngine = nil

	BodyFade.Stop()
	OrbitCamera.Stop()
	EnginePrompts.SetViewing(nil)

	local char = player.Character
	if char then CharacterManager.Show(char) end

	ContextActionService:UnbindAction(SINK_ACTION)
	EngineContext.SetInEngineView(false)
end

local function enterEngineView(engine: Model)
	if currentEngine then
		log.debug("Entry blocked: already in engine view")
		return
	end
	local char = player.Character
	if not char then return end

	log.debug("Entering engine view:", engine.Name)
	currentEngine = engine
	EnginePrompts.SetViewing(engine)

	CharacterManager.Hide(char)
	ContextActionService:BindAction(SINK_ACTION, function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space)

	BodyFade.Start(engine)

	local center = getEngineCenter(engine)
	OrbitCamera.Start(center, getStartYaw(center), function()
		if currentEngine ~= engine then return end
		EngineContext.Init(engine)
		EngineContext.SetInEngineView(true)
	end)
end

-- ── Input ─────────────────────────────────────────────────────────────────────

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == EXIT_KEY and currentEngine then
		exitEngineView()
	end
end)

-- The viewed engine was removed (driven away, destroyed): don't leave the
-- camera stuck in engine view.
Workspace.DescendantRemoving:Connect(function(instance)
	if instance == currentEngine then
		exitEngineView()
	end
end)

-- ── Start ─────────────────────────────────────────────────────────────────────

EnginePrompts.Start(enterEngineView)
