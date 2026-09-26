--[[
    ZoneUtils (ModuleScript)
    ------------------------
    Single source of truth for "is this position inside this zone part"
    math and "which zone is this player standing in right now" lookups.

    Previously this exact math was duplicated separately in:
    - InventoryService.luau  (getZoneForPlayer)
    - EngineServer.legacy.luau (getZoneForPlayer)
    - LevelService.luau      (getZoneForPlayer)
    - ZoneService.legacy.luau (isInsideZone, used for exit detection)

    All four now call through here instead, so a change to the zone-check
    math only needs to happen in one place.

    This does NOT change how ZoneService detects entry — it still uses
    .Touched for that, separately from this module. Only the underlying
    position math and the on-demand "what zone is this player in" lookup
    are consolidated here.
]]

local ZoneUtils = {}

-- Is a world position inside a zone part's bounds?
function ZoneUtils.IsPositionInZone(position, zone)
	local localPos = zone.CFrame:PointToObjectSpace(position)
	local half     = zone.Size / 2
	return math.abs(localPos.X) <= half.X
		and math.abs(localPos.Y) <= half.Y
		and math.abs(localPos.Z) <= half.Z
end

-- Returns the ZoneId of the zone a player's HumanoidRootPart is currently
-- inside, or nil if they're not in any zone. Looks in Workspace.EngineZones.
function ZoneUtils.GetZoneForPlayer(player)
	local hrp = player.Character
		and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	local zonesFolder = workspace:FindFirstChild("EngineZones")
	if not zonesFolder then return nil end

	for _, zone in ipairs(zonesFolder:GetChildren()) do
		if not zone:IsA("BasePart") then continue end
		local zoneId = zone:GetAttribute("ZoneId")
		if not zoneId then continue end
		if ZoneUtils.IsPositionInZone(hrp.Position, zone) then
			return zoneId
		end
	end
	return nil
end

return ZoneUtils
