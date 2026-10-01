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

local DROP_SIDE_CLEARANCE = 3 -- studs clear of the car's own side, past its bounding box
local DROP_GROUND_HEIGHT  = 1.5 -- studs above the car's lowest point, so it sits near the ground, not at body height

local PartPickupService = {}

-- Placed just outside the car's own side, near ground height — not near the
-- removed part's own position, which is inside the body and invisible until
-- you leave engine-view camera. Uses the car's own orientation (its CFrame's
-- RightVector), so "outside" is correct regardless of which way the car is
-- facing, and scales with the car's own size via its bounding box.
local function getDropCFrame(sourceModel)
	local carRoot = ZoneUtils.GetTopLevelAncestor(sourceModel)
	local carCFrame, carSize = carRoot:GetBoundingBox()

	local sideOffset   = carCFrame.RightVector * (carSize.X / 2 + DROP_SIDE_CLEARANCE)
	local groundOffset = Vector3.new(0, -(carSize.Y / 2) + DROP_GROUND_HEIGHT, 0)

	return CFrame.new(carCFrame.Position + sideOffset + groundOffset)
end

-- Actually adds the part to its owner's inventory and removes the dropped
-- object from the world. Safe to call more than once for the same itemId —
-- the zone-leave and game-leave safety nets can both race to collect the
-- same part, and only the first should do anything.
function PartPickupService.CollectPart(itemId)
	local drop = droppedParts[itemId]
	if not drop then return end
	droppedParts[itemId] = nil

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

	local dropCFrame = getDropCFrame(sourceModel)
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
			droppedParts[itemId] = nil
		end
	end
end)

return PartPickupService
