--!strict
--[[
    ToolService (ModuleScript, started by Main)
    -------------------------------------------
    Grants/removes tools as players enter/leave zones, listening to
    ZoneService.PlayerEnteredZone / PlayerLeftZone directly.
    - Tools come from the zone's TYPE (ToolRegistry.GetToolsForType), so every
      bay of the same type gives the same tools
    - Ownership is tracked per zone NAME, so standing in two overlapping bays
      only removes a tool once the player has left both
    - Rented zone types (ToolRegistry.NeedsRent — Mechanic bays): only the
      player renting the bay gets the tools. Rent it while standing in it and
      they appear; hand back the keys (or get evicted) and they go.
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local Workspace           = game:GetService("Workspace")

local ToolRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
	:WaitForChild("ToolRegistry"))

local toolsFolder = ReplicatedStorage:WaitForChild("Tools")

local ZoneService = require(script.Parent.ZoneService)
local ZoneUtils   = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))

-- Load and validate all tool templates at startup
local toolTemplates: { [string]: Instance } = {}
for _, zoneType in ipairs(ToolRegistry.GetAllZoneTypes()) do
	for _, toolName in ipairs(ToolRegistry.GetToolsForType(zoneType)) do
		if not toolTemplates[toolName] then
			local template = toolsFolder:FindFirstChild(toolName)
			assert(template, "[ToolService] Missing tool template: " .. toolName)
			toolTemplates[toolName] = template
		end
	end
end

-- Ownership tracking: player -> toolName -> { zoneName -> true }
local playerOwnership: { [Player]: { [string]: { [string]: boolean } } } = {}
local inventoryWatchers: { [Player]: RBXScriptConnection } = {}

local function getOrCreateOwnership(player: Player)
	playerOwnership[player] = playerOwnership[player] or {}
	return playerOwnership[player]
end

local function hasReason(player: Player, toolName: string)
	local ownership = playerOwnership[player]
	if not ownership or not ownership[toolName] then return false end
	return next(ownership[toolName]) ~= nil
end

local function addReason(player: Player, toolName: string, zoneName: string)
	local ownership = getOrCreateOwnership(player)
	ownership[toolName] = ownership[toolName] or {}
	ownership[toolName][zoneName] = true
end

local function removeReason(player: Player, toolName: string, zoneName: string)
	local ownership = playerOwnership[player]
	if not ownership or not ownership[toolName] then return end
	ownership[toolName][zoneName] = nil
end

local function playerHasTool(player: Player, toolName: string)
	for _, container in ipairs({
		player:FindFirstChild("Backpack"),
		player.Character,
		}) do
		if container and container:FindFirstChild(toolName) then
			return true
		end
	end
	return false
end

local function giveTool(player: Player, toolName: string)
	if not player or not player.Parent then
		warn("[ToolService] giveTool aborted — player invalid")
		return
	end
	if playerHasTool(player, toolName) then
		return
	end
	local template = toolTemplates[toolName]
	if not template then
		warn("[ToolService] giveTool aborted — no template loaded for:", toolName)
		return
	end
	local clone   = template:Clone()
	local backpack = player:WaitForChild("Backpack", 3)
	if backpack then
		clone.Parent = backpack
	else
		clone:Destroy()
		warn("[ToolService] Backpack not found for", player.Name)
	end
end

local function removeTool(player: Player, toolName: string)
	for _, container in ipairs({
		player:FindFirstChild("Backpack"),
		player.Character,
		}) do
		if container then
			local tool = container:FindFirstChild(toolName)
			if tool then tool:Destroy() end
		end
	end
end

local function setupInventoryWatcher(player: Player)
	if inventoryWatchers[player] then
		inventoryWatchers[player]:Disconnect()
		inventoryWatchers[player] = nil
	end
	local backpack = player:WaitForChild("Backpack", 5)
	if not backpack then return end
	inventoryWatchers[player] = backpack.ChildRemoved:Connect(function(child)
		if not child:IsA("Tool") then return end
		if not toolTemplates[child.Name] then return end
		task.wait()
		if hasReason(player, child.Name) then
			giveTool(player, child.Name)
		end
	end)
end

-- [player] = the zone they're standing in (from ZoneService's signals)
local currentZone: { [Player]: { name: string, zoneType: string? } } = {}

-- May this player have this zone's tools? Rented zone types: only its renter.
local function allowed(player: Player, zoneName: string, zoneType: string?): boolean
	if not ToolRegistry.NeedsRent(zoneType) then return true end
	local zones = Workspace:FindFirstChild("EngineZones")
	local zone = zones and zones:FindFirstChild(zoneName)
	return zone ~= nil and ZoneUtils.GetRenter(zone) == player.UserId
end

local function grant(player: Player, zoneName: string, zoneType: string?)
	for _, toolName in ipairs(ToolRegistry.GetToolsForType(zoneType)) do
		addReason(player, toolName, zoneName)
		giveTool(player, toolName)
	end
end

-- Drops this zone as a reason for every tool the player holds, and removes
-- any tool left with no reason.
local function revoke(player: Player, zoneName: string)
	local ownership = playerOwnership[player]
	if not ownership then return end
	for toolName in pairs(ownership) do
		removeReason(player, toolName, zoneName)
		if not hasReason(player, toolName) then
			removeTool(player, toolName)
		end
	end
end

local function cleanupPlayer(player: Player)
	currentZone[player] = nil
	playerOwnership[player] = nil
	if inventoryWatchers[player] then
		inventoryWatchers[player]:Disconnect()
		inventoryWatchers[player] = nil
	end
end

ZoneService.PlayerEnteredZone:Connect(function(player, zoneName, zoneType)
	currentZone[player] = { name = zoneName, zoneType = zoneType }
	if allowed(player, zoneName, zoneType) then
		grant(player, zoneName, zoneType)
	end
end)

ZoneService.PlayerLeftZone:Connect(function(player, zoneName)
	local cz = currentZone[player]
	if cz and cz.name == zoneName then currentZone[player] = nil end
	revoke(player, zoneName)
end)

-- A bay rented or given back while someone's standing in it.
local function watchZone(zone: Instance)
	if not zone:IsA("BasePart") then return end
	zone:GetAttributeChangedSignal(ZoneUtils.RENTED_BY_ATTRIBUTE):Connect(function()
		for player, cz in pairs(currentZone) do
			if cz.name ~= zone.Name then continue end
			if allowed(player, cz.name, cz.zoneType) then
				grant(player, cz.name, cz.zoneType)
			else
				revoke(player, cz.name)
			end
		end
	end)
end
task.spawn(function()
	local zones = Workspace:WaitForChild("EngineZones", 30)
	if not zones then return end
	for _, zone in ipairs(zones:GetChildren()) do watchZone(zone) end
	zones.ChildAdded:Connect(watchZone)
end)

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		character:WaitForChild("HumanoidRootPart")
		setupInventoryWatcher(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	cleanupPlayer(player)
end)

for _, player in ipairs(Players:GetPlayers()) do
	if player.Character then
		setupInventoryWatcher(player)
	end
end

return {}
