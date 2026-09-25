--[[
    ZoneService (Script)
    --------------------
    - Creates ZoneServiceEvents inside ServerScriptService/Services
    - Fires PlayerEnteredZone / PlayerLeftZone with (player, zoneId)
    - Uses Touched for entry, Heartbeat position check for exit
      (TouchEnded is unreliable for zone detection)
]]

local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- Parent events inside Services folder so ToolService can find them
local servicesFolder    = ServerScriptService:WaitForChild("Services")
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

-- [char] = zoneId currently occupied
local playerZone = {}

local function isInsideZone(hrp, zone)
	local local_pos = zone.CFrame:PointToObjectSpace(hrp.Position)
	local half      = zone.Size / 2
	return math.abs(local_pos.X) <= half.X
		and math.abs(local_pos.Y) <= half.Y
		and math.abs(local_pos.Z) <= half.Z
end

local function getZoneParts()
	local parts = {}
	for _, child in ipairs(zonesFolder:GetChildren()) do
		if child:IsA("BasePart") and child:GetAttribute("ZoneId") then
			table.insert(parts, child)
		end
	end
	return parts
end

-- On Touched, fire entry if not already in this zone
local function onTouched(zone, zoneId, hit)
	local char = hit.Parent
	if not char then return end
	local player = Players:GetPlayerFromCharacter(char)
	if not player then return end
	if playerZone[char] == zoneId then return end

	-- Fire leave for previous zone if any
	if playerZone[char] then
		PlayerLeftZone:Fire(player, playerZone[char])
	end

	playerZone[char] = zoneId
	PlayerEnteredZone:Fire(player, zoneId)
end

-- Heartbeat checks if players have left their zone
RunService.Heartbeat:Connect(function()
	local zoneParts = getZoneParts()
	for char, zoneId in pairs(playerZone) do
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			playerZone[char] = nil
			continue
		end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then continue end

		-- Find the zone part for this zoneId
		local stillInside = false
		for _, zone in ipairs(zoneParts) do
			if zone:GetAttribute("ZoneId") == zoneId then
				if isInsideZone(hrp, zone) then
					stillInside = true
				end
				break
			end
		end

		if not stillInside then
			playerZone[char] = nil
			PlayerLeftZone:Fire(player, zoneId)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local char = player.Character
	if char and playerZone[char] then
		PlayerLeftZone:Fire(player, playerZone[char])
		playerZone[char] = nil
	end
end)

local function registerZone(zone)
	if not zone:IsA("BasePart") then return end
	local zoneId = zone:GetAttribute("ZoneId")
	if not zoneId or zoneId == "" then
		warn("ZoneService: " .. zone.Name .. " has no ZoneId attribute, skipping.")
		return
	end
	zone.CanTouch = true
	zone.Touched:Connect(function(hit) onTouched(zone, zoneId, hit) end)
end

for _, zone in ipairs(zonesFolder:GetChildren()) do
	registerZone(zone)
end

zonesFolder.ChildAdded:Connect(registerZone)

