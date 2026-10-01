--[[
    ZoneService (Script)
    --------------------
    - Creates ZoneServiceEvents inside ServerScriptService/Services
    - Fires PlayerEnteredZone / PlayerLeftZone with (player, zoneName, zoneType)
    - Uses Touched for entry, Heartbeat position check for exit
      (TouchEnded is unreliable for zone detection)

    Zones are BaseParts directly under Workspace.EngineZones:
    - zoneName = the part's Name — must be unique (Mechanic_1, Mechanic_2, ...)
    - zoneType = its "ZoneType" string attribute ("Mechanic", "Paint", ...)
]]

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ZoneUtils = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))

-- Parent events inside Services folder so ToolService can find them
local servicesFolder    = ServerScriptService:WaitForChild("Server"):WaitForChild("Services")
local eventsFolder      = Instance.new("Folder")
eventsFolder.Name       = "ZoneServiceEvents"
eventsFolder.Parent     = servicesFolder

local PlayerEnteredZone      = Instance.new("BindableEvent")
PlayerEnteredZone.Name       = "PlayerEnteredZone"
PlayerEnteredZone.Parent     = eventsFolder

local PlayerLeftZone         = Instance.new("BindableEvent")
PlayerLeftZone.Name          = "PlayerLeftZone"
PlayerLeftZone.Parent        = eventsFolder

local zonesFolder = workspace:WaitForChild("EngineZones")

-- [char] = zoneName currently occupied
local playerZone = {}

-- [zoneName] = zone part, for every registered zone
local zonesByName = {}

-- On Touched, fire entry if not already in this zone
local function onTouched(zone, hit)
	local char = hit.Parent
	if not char then return end
	local player = Players:GetPlayerFromCharacter(char)
	if not player then return end

	local zoneName = zone.Name
	if playerZone[char] == zoneName then return end

	-- Fire leave for previous zone if any
	local previous = playerZone[char]
	if previous then
		local previousZone = zonesByName[previous]
		PlayerLeftZone:Fire(player, previous, ZoneUtils.GetZoneType(previousZone))
	end

	playerZone[char] = zoneName
	local zoneType = ZoneUtils.GetZoneType(zone)
	print("[ZoneService] Entered:", player.Name, zoneName, "(" .. tostring(zoneType) .. ")")
	PlayerEnteredZone:Fire(player, zoneName, zoneType)
end

-- Heartbeat checks if players have left their zone
RunService.Heartbeat:Connect(function()
	for char, zoneName in pairs(playerZone) do
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			playerZone[char] = nil
			continue
		end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then continue end

		local zone = zonesByName[zoneName]
		local stillInside = zone ~= nil
			and zone.Parent ~= nil
			and ZoneUtils.IsPositionInZone(hrp.Position, zone)

		if not stillInside then
			playerZone[char] = nil
			PlayerLeftZone:Fire(player, zoneName, ZoneUtils.GetZoneType(zone))
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local char = player.Character
	local zoneName = char and playerZone[char]
	if zoneName then
		PlayerLeftZone:Fire(player, zoneName, ZoneUtils.GetZoneType(zonesByName[zoneName]))
		playerZone[char] = nil
	end
end)

local function registerZone(zone)
	if not zone:IsA("BasePart") then return end

	-- Zone names are identities — two zones with the same name would be
	-- treated as one bay, so refuse the duplicate loudly.
	if zonesByName[zone.Name] then
		warn("ZoneService: duplicate zone name '" .. zone.Name .. "' — skipping the second one. Zone names must be unique.")
		return
	end

	local zoneType = ZoneUtils.GetZoneType(zone)
	if not zoneType then
		warn("ZoneService: " .. zone.Name .. " has no ZoneType attribute — it will detect players but grant no tools.")
	end

	zonesByName[zone.Name] = zone
	print("[ZoneService] Registered zone:", zone.Name, "type:", tostring(zoneType))
	zone.CanTouch = true
	zone.Touched:Connect(function(hit) onTouched(zone, hit) end)
end

for _, zone in ipairs(zonesFolder:GetChildren()) do
	registerZone(zone)
end

zonesFolder.ChildAdded:Connect(registerZone)

zonesFolder.ChildRemoved:Connect(function(zone)
	if zonesByName[zone.Name] == zone then
		zonesByName[zone.Name] = nil
	end
end)
