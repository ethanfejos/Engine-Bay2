--[[
    ToolService (Script)
    --------------------
    Grants/removes tools as players enter/leave zones.
    - ZoneServiceEvents folder is inside ServerScriptService/Services
      (created by ZoneService at runtime — ZoneService must run first)
    - Tools come from the zone's TYPE (ToolRegistry.GetToolsForType), so every
      bay of the same type gives the same tools
    - Ownership is tracked per zone NAME, so standing in two overlapping bays
      only removes a tool once the player has left both
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ToolRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
	:WaitForChild("ToolRegistry"))

local toolsFolder = ReplicatedStorage:WaitForChild("Tools")

local eventsFolder      = ServerScriptService:WaitForChild("Server"):WaitForChild("Services")
	:WaitForChild("ZoneServiceEvents", 10)
local PlayerEnteredZone = eventsFolder:WaitForChild("PlayerEnteredZone")
local PlayerLeftZone    = eventsFolder:WaitForChild("PlayerLeftZone")

-- Load and validate all tool templates at startup
local toolTemplates = {}
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
local playerOwnership   = {}
local inventoryWatchers = {}

local function getOrCreateOwnership(player)
	playerOwnership[player] = playerOwnership[player] or {}
	return playerOwnership[player]
end

local function hasReason(player, toolName)
	local ownership = playerOwnership[player]
	if not ownership or not ownership[toolName] then return false end
	return next(ownership[toolName]) ~= nil
end

local function addReason(player, toolName, zoneName)
	local ownership = getOrCreateOwnership(player)
	ownership[toolName] = ownership[toolName] or {}
	ownership[toolName][zoneName] = true
end

local function removeReason(player, toolName, zoneName)
	local ownership = playerOwnership[player]
	if not ownership or not ownership[toolName] then return end
	ownership[toolName][zoneName] = nil
end

local function playerHasTool(player, toolName)
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

local function giveTool(player, toolName)
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

local function removeTool(player, toolName)
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

local function setupInventoryWatcher(player)
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

local function cleanupPlayer(player)
	playerOwnership[player] = nil
	if inventoryWatchers[player] then
		inventoryWatchers[player]:Disconnect()
		inventoryWatchers[player] = nil
	end
end

PlayerEnteredZone.Event:Connect(function(player, zoneName, zoneType)
	for _, toolName in ipairs(ToolRegistry.GetToolsForType(zoneType)) do
		addReason(player, toolName, zoneName)
		giveTool(player, toolName)
	end
end)

-- Leaving doesn't need the zone's type: just drop this zone as a reason for
-- every tool the player holds, and remove any tool left with no reason.
PlayerLeftZone.Event:Connect(function(player, zoneName)
	local ownership = playerOwnership[player]
	if not ownership then return end
	for toolName in pairs(ownership) do
		removeReason(player, toolName, zoneName)
		if not hasReason(player, toolName) then
			removeTool(player, toolName)
		end
	end
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		player.Character:WaitForChild("HumanoidRootPart")
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