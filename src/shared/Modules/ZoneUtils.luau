--!strict
--[[
    ZoneUtils (ModuleScript)
    ------------------------
    Single source of truth for zone lookups. Shared by server and client.

    A zone is any BasePart directly under Workspace.EngineZones.
    - Identity  = the part's Name (must be unique, e.g. Mechanic_1)
    - Type      = its "ZoneType" string attribute (e.g. "Mechanic", "Paint")

    Zones are NOT tied to a specific engine. To find the engine currently in a
    bay, use GetEngineInZone — it looks for an engine model (any Model with an
    "EngineTrigger" child) whose pivot is physically inside the bay.
]]

local ZoneUtils = {}

-- Set on a bay (zone part) by BayRentalService while a player rents it:
-- the renter's UserId. Visible to every client (the "your bay" marker).
ZoneUtils.RENTED_BY_ATTRIBUTE = "RentedBy"

-- ── Position math ─────────────────────────────────────────────────────────────

-- Is a world position inside a zone part's bounds?
function ZoneUtils.IsPositionInZone(position: Vector3, zone: BasePart): boolean
	local localPos = zone.CFrame:PointToObjectSpace(position)
	local half     = zone.Size / 2
	return math.abs(localPos.X) <= half.X
		and math.abs(localPos.Y) <= half.Y
		and math.abs(localPos.Z) <= half.Z
end

-- ── Zone lookups ──────────────────────────────────────────────────────────────

-- Returns the zone PART containing a world position, or nil.
function ZoneUtils.GetZonePartForPosition(position: Vector3): BasePart?
	local zonesFolder = workspace:FindFirstChild("EngineZones")
	if not zonesFolder then return nil end

	for _, zone in ipairs(zonesFolder:GetChildren()) do
		if zone:IsA("BasePart") and ZoneUtils.IsPositionInZone(position, zone) then
			return zone
		end
	end
	return nil
end

-- Returns the zone NAME (its identity) containing a position, or nil.
function ZoneUtils.GetZoneForPosition(position: Vector3): string?
	local zone = ZoneUtils.GetZonePartForPosition(position)
	return zone and zone.Name or nil
end

-- Zone part the player's HumanoidRootPart is currently inside, or nil.
function ZoneUtils.GetZonePartForPlayer(player: Player): BasePart?
	local hrp = player.Character
		and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then return nil end
	return ZoneUtils.GetZonePartForPosition(hrp.Position)
end

-- Zone name the player is currently inside, or nil.
function ZoneUtils.GetZoneForPlayer(player: Player): string?
	local zone = ZoneUtils.GetZonePartForPlayer(player)
	return zone and zone.Name or nil
end

-- The zone's type ("Mechanic", "Paint", ...) or nil if it has none.
function ZoneUtils.GetZoneType(zone: Instance?): string?
	local zoneType = zone and zone:GetAttribute("ZoneType")
	if type(zoneType) == "string" and zoneType ~= "" then
		return zoneType
	end
	return nil
end

-- The UserId of the player renting this bay, or nil if nobody is.
function ZoneUtils.GetRenter(zone: Instance): number?
	local renter = zone:GetAttribute(ZoneUtils.RENTED_BY_ATTRIBUTE)
	return if type(renter) == "number" then renter else nil
end

-- ── Engine lookup ─────────────────────────────────────────────────────────────

-- Finds the engine model currently parked in a zone: a Model with a direct
-- "EngineTrigger" child whose pivot is inside the zone. Works wherever the
-- engine lives in the workspace (inside a car, a folder, anywhere).
-- Returns nil if the bay is empty.
function ZoneUtils.GetEngineInZone(zone: BasePart?): Model?
	if not zone then return nil end

	local parts = workspace:GetPartBoundsInBox(zone.CFrame, zone.Size)
	local isEngine: { [Model]: boolean } = {} -- [model] = true/false, so each model is only tested once

	for _, part in ipairs(parts) do
		local model: Instance? = part.Parent
		while model and model ~= workspace do
			if model:IsA("Model") then
				if isEngine[model] == nil then
					isEngine[model] = model:FindFirstChild("EngineTrigger") ~= nil
				end
				if isEngine[model]
					and ZoneUtils.IsPositionInZone(model:GetPivot().Position, zone) then
					return model
				end
			end
			model = model.Parent
		end
	end
	return nil
end

-- Convenience: the engine in the zone the player is standing in.
-- Returns engine, zonePart.
--   not in any zone        -> nil, nil
--   in a zone, bay empty   -> nil, zonePart
function ZoneUtils.GetEngineForPlayer(player: Player): (Model?, BasePart?)
	local zone = ZoneUtils.GetZonePartForPlayer(player)
	if not zone then return nil, nil end
	return ZoneUtils.GetEngineInZone(zone), zone
end

-- The highest ancestor still directly under Workspace — i.e. the whole car,
-- if the given instance is parked inside one, or just the instance itself if
-- it's standalone. Shared by client (camera fade/collision) and server
-- (physics stabilization on part removal, pickup-drop placement) so both
-- agree on what "the car" is.
function ZoneUtils.GetTopLevelAncestor(instance: Instance): Instance
	local current = instance
	local parent = current.Parent
	while parent and parent:IsA("Model") do
		current = parent
		parent = current.Parent
	end
	return current
end

return ZoneUtils
