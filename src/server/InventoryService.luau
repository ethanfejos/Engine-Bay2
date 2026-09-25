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

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Points at ProfileManager (wraps the real ProfileService library) rather
-- than the old hand-rolled ProfileService.luau. Kept as the local name
-- "ProfileService" so every ProfileService.GetProfile(...) call below is
-- unchanged.
local ProfileService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("ProfileManager"))
local ToolRegistry   = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolRegistry"))

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

local function getEngineForZone(zoneId)
	-- Routed through ToolRegistry.GetEngineInstance so engine lookup stays
	-- consistent with EngineServer/EngineCameraController/EngineBillboard —
	-- engines live in Workspace.Engines, not directly under Workspace.
	return ToolRegistry.GetEngineInstance(zoneId)
end

local function getZoneForPlayer(player)
	local hrp = player.Character
		and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	local zonesFolder = workspace:WaitForChild("EngineZones")
	for _, zone in ipairs(zonesFolder:GetChildren()) do
		if not zone:IsA("BasePart") then continue end
		local zoneId  = zone:GetAttribute("ZoneId")
		if not zoneId then continue end
		local localPos = zone.CFrame:PointToObjectSpace(hrp.Position)
		local half     = zone.Size / 2
		if  math.abs(localPos.X) <= half.X
			and math.abs(localPos.Y) <= half.Y
			and math.abs(localPos.Z) <= half.Z then
			return zoneId
		end
	end
	return nil
end

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

Players.PlayerAdded:Connect(function(player)
	local profile = ProfileService.LoadProfile(player)
	if not profile then
		-- LoadProfile already kicked the player in this case (session
		-- couldn't be claimed, or they left before loading finished).
		return
	end
	-- Send inventory to client once character loads
	player.CharacterAdded:Connect(function()
		task.wait(1)
		inventoryUpdated:FireClient(player, profile.Data.inventory)
	end)
end)

-- Client requesting inventory (e.g. on rejoin)
requestInventory.OnServerEvent:Connect(function(player)
	local profile = ProfileService.GetProfile(player)
	if profile then
		inventoryUpdated:FireClient(player, profile.Data.inventory)
	end
end)

-- ── Reinstall Handler ─────────────────────────────────────────────────────────

reinstallEvent.OnServerEvent:Connect(function(player, itemId)
	-- Validate player has this item by id
	local hasPart, item = InventoryService.HasPartById(player, itemId)
	if not hasPart then
		warn("[InventoryService] Player", player.Name, "tried to reinstall item they don't have:", itemId)
		return
	end

	local partName   = item.name
	local engineName = item.engineName

	-- Validate player is in correct zone
	local zoneId = getZoneForPlayer(player)
	if not zoneId then
		warn("[InventoryService] Player not in zone:", player.Name)
		return
	end

	local engine = getEngineForZone(zoneId)
	if not engine or engine.Name ~= engineName then
		warn("[InventoryService] Engine mismatch for:", player.Name)
		return
	end

	-- Check part doesn't already exist in engine
	if engine:FindFirstChild(partName) then
		warn("[InventoryService] Part already exists in engine:", partName)
		return
	end

	-- Check reinstall dependencies — part can only go back if parts
	-- that depend on it are already reinstalled (reverse dependency order)
	-- We check: does any currently-missing part list this part in its Requires?
	-- If so, that part must be reinstalled first
	local templateFolder = ReplicatedStorage:WaitForChild("EnginePartTemplates")
	local engineFolder   = templateFolder:FindFirstChild(engineName)
	if not engineFolder then
		warn("[InventoryService] No template folder for engine:", engineName)
		return
	end
	local template = engineFolder:FindFirstChild(partName)
	if not template then
		warn("[InventoryService] No template found for:", partName)
		return
	end

	-- Check reinstall order using the part's own Requires attribute
	-- A part can only be reinstalled if all parts listed in its Requires
	-- are already back in the engine (not in inventory)
	local requires = template:GetAttribute("Requires")
	if requires and requires ~= "" then
		for _, req in ipairs(requires:split(",")) do
			req = req:match("^%s*(.-)%s*$")
			if not engine:FindFirstChild(req) then
				-- Required part is not in engine yet — must reinstall it first
				reinstallEvent:FireClient(player, "BLOCKED", req)
				return
			end
		end
	end

	-- All checks passed — clone template into engine with original wear and position
	local clone = template:Clone()
	clone:SetAttribute("Wear", item.wear)
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