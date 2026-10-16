--[[
    ZoneService (ModuleScript, started by Main)
    -------------------------------------------
    Tracks which zone (repair bay) each player is standing in and fires two
    signals other services connect to directly:
    - ZoneService.PlayerEnteredZone (player, zoneName, zoneType)
    - ZoneService.PlayerLeftZone    (player, zoneName, zoneType)
    e.g. ZoneService.PlayerLeftZone:Connect(function(player, zoneName) ... end)

    How a player's zone is decided:
    - Polled POLL_RATE times a second from the HumanoidRootPart's position,
      using the same ZoneUtils lookup the server's own checks use
      (EngineServer, InventoryService, LevelService), so "in a zone" means
      the same thing everywhere. No Touched events: a foot or hand
      touching the zone edge no longer counts as entering.
    - Tracked per PLAYER, not per character, so a respawn can't silently
      drop the player's state.
    - A dead player is in no zone. Leave fires the moment they die, again
      if their character is removed, and when they leave the game — so
      tools are taken back and dropped parts are auto-collected.

    Zones are BaseParts directly under Workspace.EngineZones:
    - zoneName = the part's Name — must be unique (Mechanic_1, Mechanic_2, ...)
    - zoneType = its "ZoneType" string attribute ("Mechanic", "Paint", ...)
    Overlapping zones aren't supported: where two overlap, the first one
    ZoneUtils finds wins.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneUtils = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))
local Signal    = require(script.Parent.Parent.Modules.Signal)

-- ── Config ────────────────────────────────────────────────────────────────────

local POLL_RATE = 10 -- checks per second; enter/leave lag is at most 1/POLL_RATE s

-- ── Signals ───────────────────────────────────────────────────────────────────

local ZoneService = {}
ZoneService.PlayerEnteredZone = Signal.new()
ZoneService.PlayerLeftZone    = Signal.new()

local PlayerEnteredZone = ZoneService.PlayerEnteredZone
local PlayerLeftZone    = ZoneService.PlayerLeftZone

-- ── State ─────────────────────────────────────────────────────────────────────

-- [player] = { name = zoneName, zoneType = zoneType } for the zone they're in.
-- zoneType is stored so leave can still report it if the zone part was
-- removed in the meantime.
local playerZone = {}

-- [zoneName] = zone part, for every registered (uniquely named) zone
local zonesByName = {}

-- Moves a player into newZone (a registered zone part) or out of all zones
-- (newZone = nil). Fires leave for the old zone, then enter for the new one.
-- Does nothing if they're already in that zone.
local function setPlayerZone(player, newZone)
	local current = playerZone[player]
	local newName = newZone and newZone.Name or nil
	if (current and current.name) == newName then return end

	if current then
		playerZone[player] = nil
		PlayerLeftZone:Fire(player, current.name, current.zoneType)
	end

	if newZone then
		local zoneType = ZoneUtils.GetZoneType(newZone)
		playerZone[player] = { name = newName, zoneType = zoneType }
		print("[ZoneService] Entered:", player.Name, newName, "(" .. tostring(zoneType) .. ")")
		PlayerEnteredZone:Fire(player, newName, zoneType)
	end
end

-- The registered zone a player is standing in right now, or nil if they're
-- outside every zone, dead, or have no character.
local function findZoneForPlayer(player)
	local char = player.Character
	if not char then return nil end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return nil end

	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	local zone = ZoneUtils.GetZonePartForPosition(hrp.Position)
	-- Ignore duplicate-named zones that registerZone refused.
	if zone and zonesByName[zone.Name] == zone then
		return zone
	end
	return nil
end

-- ── Polling ───────────────────────────────────────────────────────────────────

local POLL_INTERVAL = 1 / POLL_RATE
local sincePoll     = 0

RunService.Heartbeat:Connect(function(dt)
	sincePoll += dt
	if sincePoll < POLL_INTERVAL then return end
	sincePoll = 0

	for _, player in ipairs(Players:GetPlayers()) do
		setPlayerZone(player, findZoneForPlayer(player))
	end
end)

-- ── Death / respawn / leaving ─────────────────────────────────────────────────
-- Fire leave immediately rather than waiting for the next poll, so tools and
-- dropped parts are handled even if the character is gone by then.

local function onCharacterAdded(player, char)
	local humanoid = char:WaitForChild("Humanoid", 10)
	if humanoid then
		humanoid.Died:Connect(function()
			setPlayerZone(player, nil)
		end)
	end
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(char)
		onCharacterAdded(player, char)
	end)
	player.CharacterRemoving:Connect(function()
		setPlayerZone(player, nil)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	setPlayerZone(player, nil)
end)

-- ── Zone registration ─────────────────────────────────────────────────────────

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
end

-- Zones are registered in the background so starting this module never
-- waits on the workspace; players are simply in no zone until it's done.
task.spawn(function()
	local zonesFolder = workspace:WaitForChild("EngineZones")

	for _, zone in ipairs(zonesFolder:GetChildren()) do
		registerZone(zone)
	end

	zonesFolder.ChildAdded:Connect(registerZone)

	-- Players inside a removed zone get their leave on the next poll.
	zonesFolder.ChildRemoved:Connect(function(zone)
		if zonesByName[zone.Name] == zone then
			zonesByName[zone.Name] = nil
		end
	end)
end)

return ZoneService
