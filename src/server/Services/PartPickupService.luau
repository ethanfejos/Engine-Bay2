--[[
    PartPickupService (ModuleScript)
    ---------------------------------
    Removed engine parts don't go straight into inventory — they drop as a
    physical, anchored object near where they were removed, and the player
    has to interact with it (Pick Up prompt) to actually claim it.

    Safety nets, so a part can never be permanently lost:
    - Leaving the zone the part is sitting in auto-collects it.
    - Leaving the game entirely auto-collects it too, via
      ProfileManager.OnBeforeRelease — NOT a second PlayerRemoving
      connection, since connection order between separate scripts isn't
      something to rely on and could otherwise write into an
      already-released profile.

    Required by EngineServer, which calls DropPart right after destroying a
    removed part.

    Place in: ServerScriptService/Services
]]

local Workspace            = game:GetService("Workspace")
local ServerScriptService  = game:GetService("ServerScriptService")

local InventoryService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("InventoryService"))
local ProfileManager    = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Modules"):WaitForChild("ProfileManager"))
local ZoneUtils         = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))

local zoneEventsFolder = ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("ZoneServiceEvents")
local PlayerLeftZone    = zoneEventsFolder:WaitForChild("PlayerLeftZone")

local droppedFolder = Workspace:FindFirstChild("DroppedParts")
if not droppedFolder then
	droppedFolder = Instance.new("Folder")
	droppedFolder.Name = "DroppedParts"
	droppedFolder.Parent = Workspace
end

-- [itemId] = { player, modelName, wear, engineName, relativeData, zoneName, instance }
local droppedParts = {}

local DROP_CLEARANCE   = 2 -- studs clear of the engine/car's own footprint, past its bounding box edge
local GROUND_CLEARANCE = 0.05 -- tiny gap so the part doesn't z-fight with the ground

-- Multiple parts dropped near the same engine/car are spread out in a loose
-- spiral (golden-angle, like seed packing) running all the way AROUND it,
-- not just to one fixed side — each later slot in the same bay rings
-- further out. Starting the index at 1 (not 0) means the very first part
-- lands right at the clearance radius instead of dead-center on top of it.
local SPREAD_RING_RADIUS = 1.6 -- studs of extra spread per ring of the spiral
local GOLDEN_ANGLE       = math.rad(137.5)

local PartPickupService = {}

-- [zoneName] = { [slotIndex] = true }, tracks which spiral slots around a
-- given bay's drop point are currently occupied, so a freed slot (part
-- collected) gets reused rather than the spiral only ever growing outward.
local activeSlotsByZone = {}

local function claimSlot(zoneName)
	local slots = activeSlotsByZone[zoneName]
	if not slots then
		slots = {}
		activeSlotsByZone[zoneName] = slots
	end
	local index = 1
	while slots[index] do
		index += 1
	end
	slots[index] = true
	return index
end

local function releaseSlot(zoneName, slotIndex)
	local slots = activeSlotsByZone[zoneName]
	if slots then
		slots[slotIndex] = nil
	end
end

-- Placed in a ring around the engine/car's own footprint, at ground height
-- — not near the removed part's own position, which is inside the body (or
-- up on the hoist) and invisible until you leave engine-view camera.
--
-- Also gives each drop a random yaw and a chance to land tipped onto its
-- side, so a pile of parts doesn't look like a row of parts all standing
-- perfectly upright. "Ground height" is measured using dropClone's OWN
-- bounding box at that final orientation (not a flat guess based on the
-- car), so a small bolt and a big body panel both actually rest on the
-- ground instead of floating above it or sinking into it.
local function getDropCFrame(dropClone, sourceModel, zoneName, slotIndex)
	local carRoot = ZoneUtils.GetTopLevelAncestor(sourceModel)
	local carCFrame, carSize = carRoot:GetBoundingBox()
	local groundY = carCFrame.Position.Y - carSize.Y / 2

	-- Radius clear of the whole footprint's horizontal extent (its bounding
	-- box's half-diagonal), so parts never spawn inside the engine/car/hoist
	-- regardless of which way they're facing.
	local footprintRadius = math.sqrt(carSize.X ^ 2 + carSize.Z ^ 2) / 2 + DROP_CLEARANCE

	local angle  = slotIndex * GOLDEN_ANGLE
	local radius = footprintRadius + SPREAD_RING_RADIUS * math.sqrt(slotIndex - 1)
	local spreadOffset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)

	local horizontal = Vector3.new(carCFrame.Position.X, 0, carCFrame.Position.Z) + spreadOffset

	local yaw  = math.random() * math.pi * 2
	local tilt = CFrame.new()
	if math.random() < 0.5 then
		local axis = (math.random(0, 1) == 0) and Vector3.xAxis or Vector3.zAxis
		tilt = CFrame.fromAxisAngle(axis, math.rad(90))
	end
	local orientation = CFrame.Angles(0, yaw, 0) * tilt

	-- Measure the clone's own bounding box at this orientation (position
	-- doesn't matter yet) so we know how far its lowest point sits below
	-- its pivot once tipped/rotated.
	dropClone:PivotTo(orientation)
	local boundsCFrame, boundsSize = dropClone:GetBoundingBox()
	local pivotToBoundsCenterY = boundsCFrame.Position.Y -- relative to pivot at Y=0
	local desiredBoundsCenterY = groundY + boundsSize.Y / 2 + GROUND_CLEARANCE
	local pivotY = desiredBoundsCenterY - pivotToBoundsCenterY

	return CFrame.new(horizontal.X, pivotY, horizontal.Z) * orientation
end

-- Actually adds the part to its owner's inventory and removes the dropped
-- object from the world. Safe to call more than once for the same itemId —
-- the zone-leave and game-leave safety nets can both race to collect the
-- same part, and only the first should do anything.
function PartPickupService.CollectPart(itemId)
	local drop = droppedParts[itemId]
	if not drop then return end
	droppedParts[itemId] = nil
	releaseSlot(drop.zoneName, drop.slotIndex)

	InventoryService.AddPart(drop.player, drop.modelName, drop.wear, drop.engineName, drop.relativeData, itemId)

	if drop.instance and drop.instance.Parent then
		drop.instance:Destroy()
	end
end

-- Called by EngineServer right after a part is removed from an engine.
-- sourceModel is the removed model itself, still valid and not yet
-- destroyed, so its appearance/position can be reused for the dropped clone.
function PartPickupService.DropPart(player, sourceModel, modelName, wear, engineName, relativeData, itemId, zoneName)
	local dropClone = sourceModel:Clone()
	dropClone.Name = modelName

	-- Strip anything that tried to weld this to the engine it just came out
	-- of — that engine (or its other parts) may not exist by the time this
	-- clone is parented in.
	for _, inst in ipairs(dropClone:GetDescendants()) do
		if inst:IsA("JointInstance") then
			inst:Destroy()
		end
	end

	-- Fixed spot, no physics, per design: anchored, non-collidable so it
	-- can't block movement in a tight engine bay.
	for _, part in ipairs(dropClone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored   = true
			part.CanCollide = false
		end
	end

	local slotIndex = claimSlot(zoneName)
	local dropCFrame = getDropCFrame(dropClone, sourceModel, zoneName, slotIndex)
	dropClone:PivotTo(dropCFrame)

	local trigger         = Instance.new("Part")
	trigger.Name          = "PickupTrigger"
	trigger.Size          = Vector3.new(3, 3, 3)
	trigger.Transparency  = 1
	trigger.CanCollide    = false
	trigger.Anchored      = true
	trigger.CFrame        = dropCFrame
	trigger.Parent        = dropClone

	local prompt                  = Instance.new("ProximityPrompt")
	prompt.ActionText              = "Pick Up"
	prompt.ObjectText               = modelName
	prompt.HoldDuration             = 0
	prompt.MaxActivationDistance    = 8
	prompt.Parent                   = trigger

	dropClone.Parent = droppedFolder

	droppedParts[itemId] = {
		player       = player,
		modelName    = modelName,
		wear         = wear,
		engineName   = engineName,
		relativeData = relativeData,
		zoneName     = zoneName,
		instance     = dropClone,
		slotIndex    = slotIndex,
	}

	prompt.Triggered:Connect(function(triggeringPlayer)
		-- Only the player who removed it can pick it up.
		local drop = droppedParts[itemId]
		if drop and triggeringPlayer == drop.player then
			PartPickupService.CollectPart(itemId)
		end
	end)
end

-- Safety net #1: leaving the zone a dropped part is sitting in auto-collects
-- it, so walking away doesn't strand it somewhere the player can't easily
-- get back to (especially once other players can use the same bay).
PlayerLeftZone.Event:Connect(function(player, zoneName)
	for itemId, drop in pairs(droppedParts) do
		if drop.player == player and drop.zoneName == zoneName then
			PartPickupService.CollectPart(itemId)
		end
	end
end)

-- Safety net #2: leaving the game entirely. Writes directly into the
-- profile this callback is handed, since it runs before release/save —
-- NOT through InventoryService.AddPart's own GetProfile lookup, which
-- could return nil if this ever ran after release for any reason.
ProfileManager.OnBeforeRelease(function(player, profile)
	for itemId, drop in pairs(droppedParts) do
		if drop.player == player then
			table.insert(profile.Data.inventory, {
				id           = itemId,
				name         = drop.modelName,
				wear         = drop.wear,
				engineName   = drop.engineName,
				relativeData = drop.relativeData,
			})
			if drop.instance and drop.instance.Parent then
				drop.instance:Destroy()
			end
			releaseSlot(drop.zoneName, drop.slotIndex)
			droppedParts[itemId] = nil
		end
	end
end)

return PartPickupService
