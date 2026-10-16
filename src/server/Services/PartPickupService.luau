--!strict
--[[
    PartPickupService (ModuleScript)
    --------------------------------
    Removed engine parts don't go straight into the inventory: a visual copy
    drops on the floor beside the car, and the player who removed it picks
    it up with a prompt ([F] Pick Up · "Alternator · 34%").

    Where a drop lands:
    - In a spiral of spots around the car's footprint (golden angle), so
      several drops spread out instead of stacking.
    - Each spot is checked before use: the real floor is found by raycasting
      down (so a car on a hoist or an engine on a stand doesn't make parts
      float), the spot must be clear of anything solid (walls, benches) and
      inside the player's bay. Blocked spots are skipped. If no spot passes
      within MAX_SPOT_TRIES, the first free spot is used anyway.

    The prompt:
    - Uses the custom prompt style (drawn by CustomPromptManager) and the F
      key, so it never competes with the engine-bay prompt on E.
    - Is shown only to the owner (DroppedPartEffect hides it on other
      players' screens using the OwnerUserId attribute); the server also
      checks the owner when it's triggered.

    Saved straight away: the moment a part drops it's written into the
    owner's save (profile.Data.dropped), and moved to the inventory when
    picked up. If a server crashes before pickup, the part is recovered into
    the inventory on the player's next join (SaveData.Sanitize).

    Safety nets, so a part can never be lost:
    - Leaving the bay (or dying in it) auto-collects your drops there.
    - Leaving the game auto-collects them too, via
      ProfileManager.OnBeforeRelease — not a second PlayerRemoving
      connection, whose order relative to the profile release isn't
      guaranteed.

    Called by EngineServer (DropPart) right before it destroys the removed
    part.
]]

local Workspace           = game:GetService("Workspace")
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local InventoryService = require(script.Parent.InventoryService)
local ProfileManager   = require(script.Parent.Parent.Modules.ProfileManager)
local ZoneUtils        = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))

local ZoneService      = require(script.Parent.ZoneService)
local Types            = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Types"))

local droppedFolder = Workspace:FindFirstChild("DroppedParts")
if not droppedFolder then
	droppedFolder        = Instance.new("Folder")
	droppedFolder.Name   = "DroppedParts"
	droppedFolder.Parent = Workspace
end

-- ── Config ────────────────────────────────────────────────────────────────────

local DROP_CLEARANCE     = 2     -- studs clear of the car's footprint
local GROUND_CLEARANCE   = 0.05  -- tiny gap so the part doesn't z-fight with the floor
local SPREAD_RING_RADIUS = 1.6   -- studs of extra spread per ring of the spiral
local GOLDEN_ANGLE       = math.rad(137.5)
local MAX_SPOT_TRIES     = 24    -- spots checked before falling back
local CLEAR_SHRINK       = 0.9   -- clearance box is 90% of the part, so touching a wall isn't "blocked"
local FLOOR_TOLERANCE    = 1     -- studs a "floor" may sit above the car's lowest point (rejects walls/shelves)
local RAY_DEPTH          = 40    -- studs below the car the floor search goes

local PROMPT_KEY         = Enum.KeyCode.F -- not E: that's the engine-bay prompt
local PROMPT_DISTANCE    = 8
local MIN_TRIGGER_SIZE   = 1.5

-- Instances a dropped copy must not keep: anything that runs, interacts or
-- joins it to the car it came from. It's purely visual.
local STRIP_CLASSES = {
	"Script", "LocalScript", "ModuleScript",
	"ProximityPrompt", "ClickDetector", "BillboardGui", "SurfaceGui",
	"JointInstance", "WeldConstraint", "NoCollisionConstraint", "Constraint",
}

-- ── State ─────────────────────────────────────────────────────────────────────

type Drop = {
	player: Player,
	modelName: string,
	wear: number,
	engineName: string,
	carId: string?,
	relativeData: Types.RelativeData?,
	zoneName: string,
	instance: Model,
	slotIndex: number,
}

local droppedParts: { [string]: Drop } = {} -- [itemId]

-- [zoneName] = { [slotIndex] = true } — spiral spots in use per bay, so a
-- freed spot (part collected) gets reused.
local activeSlotsByZone: { [string]: { [number]: boolean } } = {}

local PartPickupService = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function slotsFor(zoneName: string): { [number]: boolean }
	local slots = activeSlotsByZone[zoneName]
	if not slots then
		slots = {}
		activeSlotsByZone[zoneName] = slots
	end
	return slots
end

local function releaseSlot(zoneName: string, slotIndex: number?)
	local slots = activeSlotsByZone[zoneName]
	if slots and slotIndex then
		slots[slotIndex] = nil
	end
end

local function shouldStrip(inst: Instance): boolean
	for _, className in ipairs(STRIP_CLASSES) do
		if inst:IsA(className) then return true end
	end
	return false
end

local function clearAttributes(inst: Instance)
	for name in pairs(inst:GetAttributes()) do
		inst:SetAttribute(name, nil)
	end
end

-- Turns a clone of an engine part into a plain visual: no attributes (so
-- nothing treats it as an engine part), no scripts/prompts/GUIs, no joints,
-- anchored and non-collidable.
local function makeVisualCopy(sourceModel: Model): Model
	local copy = sourceModel:Clone()
	clearAttributes(copy)
	for _, inst in ipairs(copy:GetDescendants()) do
		if shouldStrip(inst) then
			inst:Destroy()
		elseif inst.Parent then
			clearAttributes(inst)
			if inst:IsA("BasePart") then
				inst.Anchored   = true
				inst.CanCollide = false
				inst.CanQuery   = false
				inst.CanTouch   = false
			end
		end
	end
	return copy
end

-- Everything the floor and clearance checks should ignore.
local function ignoreList(carRoot: Instance): { Instance }
	local list: { Instance } = { carRoot, droppedFolder }
	local zones = Workspace:FindFirstChild("EngineZones")
	if zones then table.insert(list, zones) end
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		if char then table.insert(list, char) end
	end
	return list
end

-- Is a world position inside the zone's footprint (ignoring height, since
-- bay volumes don't always reach exactly to the floor)?
local function insideBayFootprint(position: Vector3, zone: BasePart): boolean
	local localPos = zone.CFrame:PointToObjectSpace(position)
	return math.abs(localPos.X) <= zone.Size.X / 2
		and math.abs(localPos.Z) <= zone.Size.Z / 2
end

-- Height of the real floor below (x, z), or nil if there's none, or if what
-- was hit sits too high to be the floor (a wall top, a shelf).
local function findFloorY(x: number, z: number, carTopY: number, carBottomY: number, rayParams: RaycastParams): number?
	local origin = Vector3.new(x, carTopY + 2, z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -((carTopY - carBottomY) + 2 + RAY_DEPTH), 0), rayParams)
	if not result then return nil end
	if result.Position.Y > carBottomY + FLOOR_TOLERANCE then return nil end
	return result.Position.Y
end

-- Picks a spot and orientation for `dropClone` around the car. Returns the
-- CFrame and the claimed spiral slot index.
local function placeDrop(dropClone: Model, sourceModel: Model, zoneName: string): (CFrame, number)
	-- The whole car: always a Model, since sourceModel is one.
	local carRoot = ZoneUtils.GetTopLevelAncestor(sourceModel) :: Model
	local carCFrame, carSize = carRoot:GetBoundingBox()
	local carBottomY = carCFrame.Position.Y - carSize.Y / 2
	local carTopY    = carCFrame.Position.Y + carSize.Y / 2
	local footprintRadius = math.sqrt(carSize.X ^ 2 + carSize.Z ^ 2) / 2 + DROP_CLEARANCE

	local zonesFolder = Workspace:FindFirstChild("EngineZones")
	local found = zonesFolder and zonesFolder:FindFirstChild(zoneName)
	local zone  = if found and found:IsA("BasePart") then found else nil

	local ignore = ignoreList(carRoot)
	local rayParams = RaycastParams.new()
	rayParams.FilterType                 = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = ignore
	rayParams.RespectCanCollide          = true
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType                 = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = ignore
	overlapParams.RespectCanCollide          = true

	-- Random resting pose (yaw, maybe tipped on its side), measured once:
	-- how far the part's bounds centre sits from its pivot in that pose.
	local yaw  = math.random() * math.pi * 2
	local tilt = CFrame.new()
	if math.random() < 0.5 then
		local axis = (math.random(0, 1) == 0) and Vector3.xAxis or Vector3.zAxis
		tilt = CFrame.fromAxisAngle(axis, math.rad(90))
	end
	local orientation = CFrame.Angles(0, yaw, 0) * tilt
	dropClone:PivotTo(orientation)
	local boundsCFrame, boundsSize = dropClone:GetBoundingBox()
	local pivotToCentre = boundsCFrame.Position -- pivot is at the origin here

	local function spotFor(index: number): (number, number)
		local angle  = index * GOLDEN_ANGLE
		local radius = footprintRadius + SPREAD_RING_RADIUS * math.sqrt(index - 1)
		return carCFrame.Position.X + math.cos(angle) * radius,
			carCFrame.Position.Z + math.sin(angle) * radius
	end

	local function cframeAt(x: number, z: number, floorY: number): CFrame
		local centreY = floorY + boundsSize.Y / 2 + GROUND_CLEARANCE
		return CFrame.new(x - pivotToCentre.X, centreY - pivotToCentre.Y, z - pivotToCentre.Z) * orientation
	end

	local slots     = slotsFor(zoneName)
	local firstFree: number? = nil
	local tried     = 0
	local index     = 1
	while tried < MAX_SPOT_TRIES do
		if not slots[index] then
			tried += 1
			firstFree = firstFree or index

			local x, z = spotFor(index)
			local floorY = findFloorY(x, z, carTopY, carBottomY, rayParams)
			if floorY then
				local centre = Vector3.new(x, floorY + boundsSize.Y / 2 + GROUND_CLEARANCE, z)
				local inBay  = (zone == nil) or insideBayFootprint(centre, zone)
				local clear  = #Workspace:GetPartBoundsInBox(CFrame.new(centre), boundsSize * CLEAR_SHRINK, overlapParams) == 0
				if inBay and clear then
					slots[index] = true
					return cframeAt(x, z, floorY), index
				end
			end
		end
		index += 1
	end

	-- Nothing passed: use the first free spot, on the real floor if found.
	index = firstFree or index
	slots[index] = true
	local x, z = spotFor(index)
	local floorY = findFloorY(x, z, carTopY, carBottomY, rayParams) or carBottomY
	return cframeAt(x, z, floorY), index
end

-- ── Saved record of a drop ────────────────────────────────────────────────────

local function itemRecord(itemId: string, drop: Drop): Types.InventoryItem
	return {
		id           = itemId,
		name         = drop.modelName,
		wear         = drop.wear,
		engineName   = drop.engineName,
		carId        = drop.carId,
		relativeData = drop.relativeData,
	}
end

local function saveDropped(player: Player, itemId: string, drop: Drop)
	local profile = ProfileManager.GetProfile(player)
	if profile then
		profile.Data.dropped[itemId] = itemRecord(itemId, drop)
	end
end

local function forgetDropped(player: Player, itemId: string)
	local profile = ProfileManager.GetProfile(player)
	if profile then
		profile.Data.dropped[itemId] = nil
	end
end

-- ── Collecting ────────────────────────────────────────────────────────────────

-- Moves a dropped part into its owner's inventory and removes it from the
-- world. Safe to call more than once for the same itemId — the safety nets
-- can race to collect the same part; only the first does anything.
function PartPickupService.CollectPart(itemId: string)
	local drop = droppedParts[itemId]
	if not drop then return end
	droppedParts[itemId] = nil
	releaseSlot(drop.zoneName, drop.slotIndex)

	-- Into the inventory first, then off the saved "on the floor" list, so
	-- there's never a moment where the save has the part in neither.
	InventoryService.AddPart(drop.player, drop.modelName, drop.wear, drop.engineName, drop.carId, drop.relativeData, itemId)
	forgetDropped(drop.player, itemId)

	if drop.instance and drop.instance.Parent then
		drop.instance:Destroy()
	end
end

-- ── Dropping ──────────────────────────────────────────────────────────────────

-- Called by EngineServer while the removed part still exists, so its look
-- and position can be copied.
function PartPickupService.DropPart(player: Player, sourceModel: Model, modelName: string, wear: number,
	engineName: string, carId: string?, relativeData: Types.RelativeData?, itemId: string, zoneName: string)
	local dropClone = makeVisualCopy(sourceModel)
	dropClone.Name  = modelName
	dropClone:SetAttribute("OwnerUserId", player.UserId)

	local dropCFrame, slotIndex = placeDrop(dropClone, sourceModel, zoneName)
	dropClone:PivotTo(dropCFrame)

	-- Invisible trigger at the part's centre, sized to it, holding the prompt.
	local boundsCFrame, boundsSize = dropClone:GetBoundingBox()
	local trigger        = Instance.new("Part")
	trigger.Name         = "PickupTrigger"
	trigger.Size         = Vector3.new(
		math.max(boundsSize.X, MIN_TRIGGER_SIZE),
		math.max(boundsSize.Y, MIN_TRIGGER_SIZE),
		math.max(boundsSize.Z, MIN_TRIGGER_SIZE))
	trigger.CFrame       = boundsCFrame
	trigger.Transparency = 1
	trigger.Anchored     = true
	trigger.CanCollide   = false
	trigger.CanQuery     = false
	trigger.CanTouch     = false
	trigger.Parent       = dropClone

	local prompt                 = Instance.new("ProximityPrompt")
	prompt.ActionText            = "Pick Up"
	prompt.ObjectText            = string.format("%s · %d%%", modelName, math.floor(tonumber(wear) or 0))
	prompt.KeyboardKeyCode       = PROMPT_KEY
	prompt.Style                 = Enum.ProximityPromptStyle.Custom
	prompt.HoldDuration          = 0
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight   = false
	prompt.Parent                = trigger

	dropClone.Parent = droppedFolder

	local drop: Drop = {
		player       = player,
		modelName    = modelName,
		wear         = wear,
		engineName   = engineName,
		carId        = carId,
		relativeData = relativeData,
		zoneName     = zoneName,
		instance     = dropClone,
		slotIndex    = slotIndex,
	}
	droppedParts[itemId] = drop
	saveDropped(player, itemId, drop)

	prompt.Triggered:Connect(function(triggeringPlayer: Player)
		-- Only the player who removed it can pick it up (the prompt is
		-- hidden for everyone else, but never trust the client for that).
		local drop = droppedParts[itemId]
		if drop and triggeringPlayer == drop.player then
			PartPickupService.CollectPart(itemId)
		end
	end)
end

-- ── Safety nets ───────────────────────────────────────────────────────────────

-- Leaving the bay (or dying in it) collects your drops there, so they're
-- never stranded where you can't easily get back to them.
ZoneService.PlayerLeftZone:Connect(function(player, zoneName)
	for itemId, drop in pairs(droppedParts) do
		if drop.player == player and drop.zoneName == zoneName then
			PartPickupService.CollectPart(itemId)
		end
	end
end)

-- Leaving the game: written straight into the profile this callback is
-- handed (it runs just before the profile is released and saved).
ProfileManager.OnBeforeRelease(function(player, profile)
	for itemId, drop in pairs(droppedParts) do
		if drop.player == player then
			table.insert(profile.Data.inventory, itemRecord(itemId, drop))
			profile.Data.dropped[itemId] = nil
			if drop.instance and drop.instance.Parent then
				drop.instance:Destroy()
			end
			releaseSlot(drop.zoneName, drop.slotIndex)
			droppedParts[itemId] = nil
		end
	end
end)

return PartPickupService
