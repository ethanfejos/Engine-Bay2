--[[
    ToolService (Script)
    --------------------
    Changes from previous version:
    - ZoneServiceEvents folder is now inside ServerScriptService/Services
      (created by ZoneService at runtime — ZoneService must run first)
    - ToolRegistry now exposes GetAllZoneIds / GetToolsForZone methods
    - Everything else unchanged
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ToolRegistry = require(ReplicatedStorage:WaitForChild("Config")
	:WaitForChild("ToolRegistry"))

local toolsFolder = ReplicatedStorage:WaitForChild("Tools")

local eventsFolder      = ServerScriptService:WaitForChild("Services")
	:WaitForChild("ZoneServiceEvents", 10)
local PlayerEnteredZone = eventsFolder:WaitForChild("PlayerEnteredZone")
local PlayerLeftZone    = eventsFolder:WaitForChild("PlayerLeftZone")

-- Load and validate all tool templates at startup
local toolTemplates = {}
for _, zoneId in ipairs(ToolRegistry.GetAllZoneIds()) do
	for _, toolName in ipairs(ToolRegistry.GetToolsForZone(zoneId)) do
		if not toolTemplates[toolName] then
			local template = toolsFolder:FindFirstChild(toolName)
			assert(template, "[ToolService] Missing tool template: " .. toolName)
			toolTemplates[toolName] = template
		end
	end
end

-- Ownership tracking: player -> toolName -> { zoneId -> true }
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

local function addReason(player, toolName, zoneId)
	local ownership = getOrCreateOwnership(player)
	ownership[toolName] = ownership[toolName] or {}
	ownership[toolName][zoneId] = true
end

local function removeReason(player, toolName, zoneId)
	local ownership = playerOwnership[player]
	if not ownership or not ownership[toolName] then return end
	ownership[toolName][zoneId] = nil
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
	if not player or not player.Parent then return end
	if playerHasTool(player, toolName) then return end
	local template = toolTemplates[toolName]
	if not template then return end
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

PlayerEnteredZone.Event:Connect(function(player, zoneId)
	for _, toolName in ipairs(ToolRegistry.GetToolsForZone(zoneId)) do
		addReason(player, toolName, zoneId)
		giveTool(player, toolName)
	end
end)

PlayerLeftZone.Event:Connect(function(player, zoneId)
	for _, toolName in ipairs(ToolRegistry.GetToolsForZone(zoneId)) do
		removeReason(player, toolName, zoneId)
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