--!strict
--[[
    BodyFade (ModuleScript, client)
    -------------------------------
    While in engine view, fades the car body parts (hood, fenders, panels)
    that sit between the camera and the engine, so they don't block the
    view — faded, not hidden, so it still feels like you're inside a car.

        BodyFade.Start(engine)  -- on entering engine view
        BodyFade.Stop()         -- on leaving; restores everything

    - On Start, everything in a padded box around the engine fades at once,
      so there's no gap before the first check.
    - Then every CHECK_INTERVAL seconds it re-checks a "tube" from the
      camera to the engine, so the fade follows the camera as you orbit,
      and only fades/restores what changed.

    Uses LocalTransparencyModifier: client-only, and never touches the real
    Transparency, which PartRemoveEffect / PartReinstallEffect and the
    engine-visibility check use.

    Used by EngineCameraController. Moved here unchanged from it.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")

local ZoneUtils = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

-- ── Config ────────────────────────────────────────────────────────────────────

local CHECK_INTERVAL = 0.2  -- seconds between re-checks while in view
local PADDING        = 6    -- studs added around the engine's box for the first fade
local LINE_WIDTH     = 4    -- width/height of the camera -> engine "tube"
local AMOUNT         = 0.65 -- 0 = no change, 1 = fully invisible
local TWEEN_TIME     = 0.2
local RESTORE_TIME   = 0.25

-- ── State ─────────────────────────────────────────────────────────────────────

local fadedParts: { [BasePart]: boolean } = {}  -- the parts currently faded
local checkThread: thread? = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function isPointInBox(point: Vector3, boxCFrame: CFrame, boxSize: Vector3): boolean
	local localPos = boxCFrame:PointToObjectSpace(point)
	local half     = boxSize / 2
	return math.abs(localPos.X) <= half.X
		and math.abs(localPos.Y) <= half.Y
		and math.abs(localPos.Z) <= half.Z
end

local function fadeTo(part: BasePart, amount: number, time: number)
	TweenService:Create(part, TweenInfo.new(time), { LocalTransparencyModifier = amount }):Play()
end

-- Every body part of the car (not the engine itself, not the player) whose
-- centre is inside the given box. Scoped to the whole car — the engine's
-- top-level ancestor (ZoneUtils.GetTopLevelAncestor) — so it stays cheap
-- and never touches another car. Plain position maths rather than a
-- physics query, because body panels are often CanQuery = false.
local function bodyPartsInBox(engine: Model, boxCFrame: CFrame, boxSize: Vector3): { [BasePart]: boolean }
	local carRoot = ZoneUtils.GetTopLevelAncestor(engine)
	local char    = player.Character
	local result: { [BasePart]: boolean } = {}
	for _, part in ipairs(carRoot:GetDescendants()) do
		if not part:IsA("BasePart") then continue end
		if part:IsDescendantOf(engine) then continue end
		if char and part:IsDescendantOf(char) then continue end
		if isPointInBox(part.Position, boxCFrame, boxSize) then
			result[part] = true
		end
	end
	return result
end

-- What's between the camera and the engine right now.
local function getObstructingParts(engine: Model): { [BasePart]: boolean }
	local enginePos = engine:GetPivot().Position
	local camPos    = camera.CFrame.Position
	local diff      = enginePos - camPos
	local dist      = diff.Magnitude
	if dist < 1 then return {} end

	local tubeCFrame = CFrame.new(camPos + diff * 0.5, enginePos)
	local tubeSize   = Vector3.new(LINE_WIDTH, LINE_WIDTH, dist)
	return bodyPartsInBox(engine, tubeCFrame, tubeSize)
end

-- Fades what newly obstructs, restores what no longer does.
local function update(engine: Model)
	local obstructing = getObstructingParts(engine)

	for part in pairs(obstructing) do
		if not fadedParts[part] then
			fadedParts[part] = true
			fadeTo(part, AMOUNT, TWEEN_TIME)
		end
	end

	for part in pairs(fadedParts) do
		if not obstructing[part] then
			fadedParts[part] = nil
			if part.Parent then
				fadeTo(part, 0, TWEEN_TIME)
			end
		end
	end
end

-- ── Public ────────────────────────────────────────────────────────────────────

local BodyFade = {}

function BodyFade.Start(engine: Model)
	BodyFade.Stop()

	-- First fade: a padded box around the whole engine.
	local engineCFrame, size = engine:GetBoundingBox()
	local padded = size + Vector3.new(PADDING, PADDING, PADDING) * 2
	for part in pairs(bodyPartsInBox(engine, engineCFrame, padded)) do
		fadedParts[part] = true
		fadeTo(part, AMOUNT, TWEEN_TIME)
	end

	-- Then follow the camera.
	checkThread = task.spawn(function()
		while engine.Parent do
			task.wait(CHECK_INTERVAL)
			update(engine)
		end
	end)
end

function BodyFade.Stop()
	if checkThread then
		task.cancel(checkThread)
		checkThread = nil
	end
	for part in pairs(fadedParts) do
		if part.Parent then
			fadeTo(part, 0, RESTORE_TIME)
		end
	end
	table.clear(fadedParts)
end

return BodyFade
