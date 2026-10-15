--[[
    InventoryService (Script)
    -------------------------
    Server-side inventory management for engine parts.
    Uses ProfileService for persistent saving.

    Handles:
    - Adding parts to player inventory when removed
    - Removing parts from inventory when reinstalled
    - Replicating inventory state to client
    - Saving on leave via ProfileService

    RemoteEvents used:
    - InventoryUpdated  (server -> client) fires when inventory changes
    - ReinstallPart     (client -> server) player wants to reinstall a part
    - RequestInventory  (client -> server) client requests current inventory on join

    Place in: ServerScriptService/Services
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Points at ProfileManager (wraps the real ProfileService library) rather
-- than the old hand-rolled ProfileService.luau. Kept as the local name
-- "ProfileService" so every ProfileService.GetProfile(...) call below is
-- unchanged.
local ProfileService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Modules"):WaitForChild("ProfileManager"))
local ZoneUtils      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))
local PartRules      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("PartRules"))

-- ── Remotes ───────────────────────────────────────────────────────────────────

local function getOrCreate(parent, className, name)
	local existing = parent:FindFirstChild(name)
	if existing then return existing end
	local inst  = Instance.new(className)
	inst.Name   = name
	inst.Parent = parent
	return inst
end

local remoteFolder         = getOrCreate(ReplicatedStorage, "Folder", "RemoteEvents")
local inventoryUpdated     = getOrCreate(remoteFolder, "RemoteEvent", "InventoryUpdated")
local reinstallEvent       = getOrCreate(remoteFolder, "RemoteEvent", "ReinstallPart")
local requestInventory     = getOrCreate(remoteFolder, "RemoteEvent", "RequestInventory")
local partReinstalledEvent = getOrCreate(remoteFolder, "RemoteEvent", "PartReinstalled")
local clearInventory       = getOrCreate(remoteFolder, "RemoteEvent", "ClearInventory")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- ── Inventory API ─────────────────────────────────────────────────────────────

local InventoryService = {}

function InventoryService.AddPart(player, partName, wear, engineName, relativeData, itemId)
	local profile = ProfileService.GetProfile(player)
	if not profile then return end

	table.insert(profile.Data.inventory, {
		id           = itemId,
		name         = partName,
		wear         = wear,
		engineName   = engineName,
		relativeData = relativeData,
	})

	inventoryUpdated:FireClient(player, profile.Data.inventory)
end

function InventoryService.RemovePart(player, itemId)
	local profile = ProfileService.GetProfile(player)
	if not profile then return end

	for i, item in ipairs(profile.Data.inventory) do
		if item.id == itemId then
			local removed = table.remove(profile.Data.inventory, i)
			inventoryUpdated:FireClient(player, profile.Data.inventory)
			return removed
		end
	end
	return nil
end

function InventoryService.HasPartById(player, itemId)
	local inventory = InventoryService.GetInventory(player)
	for _, item in ipairs(inventory) do
		if item.id == itemId then
			return true, item
		end
	end
	return false, nil
end

function InventoryService.GetInventory(player)
	local profile = ProfileService.GetProfile(player)
	if not profile then return {} end
	return profile.Data.inventory
end

function InventoryService.HasPart(player, partName, engineName)
	local inventory = InventoryService.GetInventory(player)
	for _, item in ipairs(inventory) do
		if item.name == partName and item.engineName == engineName then
			return true, item
		end
	end
	return false, nil
end

-- ── Player Join/Leave ─────────────────────────────────────────────────────────

-- ProfileManager loads every player's profile itself; this just pushes the
-- inventory to the client the moment it's ready (replaces the old
-- CharacterAdded + task.wait(1) guess, which lost the race on slow loads).
ProfileService.OnProfileLoaded(function(player, profile)
	inventoryUpdated:FireClient(player, profile.Data.inventory)
end)

-- Client requesting inventory (e.g. on rejoin)
requestInventory.OnServerEvent:Connect(function(player)
	local profile = ProfileService.GetProfile(player)
	if profile then
		inventoryUpdated:FireClient(player, profile.Data.inventory)
	end
end)

-- ── Reinstall Handler ─────────────────────────────────────────────────────────

-- Every rejected reinstall tells the client why AND resends the real
-- inventory. GhostSystem hides the part from the list optimistically when
-- you click its ghost; without this resend, a rejected part stayed hidden
-- until rejoin.
--   status "BLOCKED" -> detail = name of the part that must go back in first
--   status "FAILED"  -> detail = short reason, for Output / future UI
local function rejectReinstall(player, status, detail)
	reinstallEvent:FireClient(player, status, detail)
	inventoryUpdated:FireClient(player, InventoryService.GetInventory(player))
end

reinstallEvent.OnServerEvent:Connect(function(player, itemId)
	-- Validate player has this item by id
	local hasPart, item = InventoryService.HasPartById(player, itemId)
	if not hasPart then
		warn("[InventoryService] Player", player.Name, "tried to reinstall item they don't have:", itemId)
		rejectReinstall(player, "FAILED", "not in inventory")
		return
	end

	local partName   = item.name
	local engineName = item.engineName

	-- Validate player is in correct zone
	-- The engine is whatever is parked in the bay the player is standing in.
	local engine, zone = ZoneUtils.GetEngineForPlayer(player)
	if not zone then
		warn("[InventoryService] Player not in zone:", player.Name)
		rejectReinstall(player, "FAILED", "not in a bay")
		return
	end

	if not engine or engine.Name ~= engineName then
		warn("[InventoryService] Engine mismatch for:", player.Name)
		rejectReinstall(player, "FAILED", "wrong engine")
		return
	end

	-- Check part doesn't already exist in engine
	if engine:FindFirstChild(partName) then
		warn("[InventoryService] Part already exists in engine:", partName)
		rejectReinstall(player, "FAILED", "already installed")
		return
	end

	local templateFolder = ReplicatedStorage:WaitForChild("EnginePartTemplates")
	local engineFolder   = templateFolder:FindFirstChild(engineName)
	if not engineFolder then
		warn("[InventoryService] No template folder for engine:", engineName)
		rejectReinstall(player, "FAILED", "no template")
		return
	end
	local template = engineFolder:FindFirstChild(partName)
	if not template then
		warn("[InventoryService] No template found for:", partName)
		rejectReinstall(player, "FAILED", "no template")
		return
	end

	-- Reverse dependency order: every part this one Requires must already be
	-- back in the engine (see PartRules — the ghost uses the same rule).
	local blockedBy = PartRules.GetReinstallBlocker(template, engine)
	if blockedBy then
		rejectReinstall(player, "BLOCKED", blockedBy)
		return
	end

	-- All checks passed — clone template into engine with original wear and position
	local clone = template:Clone()
	clone:SetAttribute("Wear", item.wear)
	-- This part has already paid removal XP once (that's how it got into the
	-- inventory), so removing it again pays nothing. See EngineServer.
	clone:SetAttribute("RemovalXpPaid", true)
	clone.Parent = engine

	-- Apply relative CFrame to position correctly relative to engine pivot
	if item.relativeData then
		local rd  = item.relativeData
		local relativeCF = CFrame.new(rd.x, rd.y, rd.z)
			* CFrame.fromEulerAnglesXYZ(rd.rx, rd.ry, rd.rz)
		clone:PivotTo(engine:GetPivot() * relativeCF)
	end

	-- Fire reinstall animation to client
	partReinstalledEvent:FireClient(player, clone)

	-- Remove from inventory by id
	InventoryService.RemovePart(player, itemId)
end)

clearInventory.OnServerEvent:Connect(function(player)
	local profile = ProfileService.GetProfile(player)
	if not profile then return end
	profile.Data.inventory = {}
	inventoryUpdated:FireClient(player, profile.Data.inventory)
end)

return InventoryService