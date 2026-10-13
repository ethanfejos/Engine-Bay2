--[[
    RepairService (ModuleScript)
    ----------------------------
    Server side repair logic.
    - Validates player is near workbench
    - Validates part is in inventory and above 10% wear
    - Repairs over time based on wear
    - Updates wear in ProfileService on completion
    - Fires RepairProgress and RepairComplete to client

    Place in: ServerScriptService/Services
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Points at ProfileManager (wraps the real ProfileService library) rather
-- than the old hand-rolled ProfileService.luau. Kept as the local name
-- "ProfileService" so the ProfileService.GetProfile(...) call below is unchanged.
local ProfileService   = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Modules"):WaitForChild("ProfileManager"))
local InventoryService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("InventoryService"))
local LevelService      = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("LevelService"))

-- ── Constants ─────────────────────────────────────────────────────────────────

local MIN_REPAIRABLE_WEAR = 10   -- below this, part cannot be repaired
local MAX_REPAIR_TIME     = 10   -- seconds for worst repairable part
local WORKBENCH_RADIUS    = 12   -- studs player must stay within

-- ── Remotes ───────────────────────────────────────────────────────────────────

local function getOrCreate(parent, className, name)
	local existing = parent:FindFirstChild(name)
	if existing then return existing end
	local inst  = Instance.new(className)
	inst.Name   = name
	inst.Parent = parent
	return inst
end

local remoteFolder     = getOrCreate(ReplicatedStorage, "Folder", "RemoteEvents")
local startRepairEvent = getOrCreate(remoteFolder, "RemoteEvent", "StartRepair")
local cancelRepairEvent = getOrCreate(remoteFolder, "RemoteEvent", "CancelRepair")
local repairProgress   = getOrCreate(remoteFolder, "RemoteEvent", "RepairProgress")
local repairComplete   = getOrCreate(remoteFolder, "RemoteEvent", "RepairComplete")

-- ── State ─────────────────────────────────────────────────────────────────────

local activeRepairs = {} -- [player] = { itemId, thread }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getWorkbenchPosition()
	local wb = workspace:FindFirstChild("Workbench")
	if not wb then return nil end
	for _, desc in ipairs(wb:GetDescendants()) do
		if desc.Name == "Main" and desc:IsA("BasePart") then
			return desc.Position
		end
	end
	local pp = wb.PrimaryPart
	if pp then return pp.Position end
	return nil
end

local function isNearWorkbench(player)
	local hrp = player.Character
		and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	local wbPos = getWorkbenchPosition()
	if not wbPos then return false end
	return (hrp.Position - wbPos).Magnitude <= WORKBENCH_RADIUS
end

local function getRepairTime(wear)
	-- Parts closer to 10% take longer
	local fraction = 1 - (wear / 100)
	return math.max(1, fraction * MAX_REPAIR_TIME)
end

-- ── Cancel ────────────────────────────────────────────────────────────────────

local function cancelRepair(player)
	local repair = activeRepairs[player]
	if repair then
		task.cancel(repair.thread)
		activeRepairs[player] = nil
	end
end

-- ── Start Repair ──────────────────────────────────────────────────────────────

-- Every rejected StartRepair answers with progress -1 (the same "cancelled"
-- signal used when you walk away mid-repair), so RepairUI resets its button
-- instead of sitting on "..." forever.
local function rejectRepair(player, itemId, reason)
	warn("[RepairService] Repair rejected for", player.Name, "-", reason)
	repairProgress:FireClient(player, itemId, -1)
end

startRepairEvent.OnServerEvent:Connect(function(player, itemId)
	-- Cancel any existing repair
	cancelRepair(player)

	-- Validate near workbench
	if not isNearWorkbench(player) then
		rejectRepair(player, itemId, "not near workbench")
		return
	end

	-- Find item in inventory
	local hasPart, item = InventoryService.HasPartById(player, itemId)
	if not hasPart then
		rejectRepair(player, itemId, "item not in inventory")
		return
	end

	-- Validate wear
	if item.wear <= MIN_REPAIRABLE_WEAR then
		rejectRepair(player, itemId, "wear too low to repair (" .. tostring(item.wear) .. ")")
		return
	end

	if item.wear >= 100 then
		rejectRepair(player, itemId, "already at full condition")
		return
	end

	local repairTime = getRepairTime(item.wear)

	-- Start repair thread
	local thread = task.spawn(function()
		local elapsed = 0
		local interval = 0.1

		while elapsed < repairTime do
			task.wait(interval)
			elapsed = elapsed + interval

			-- Check player still near workbench
			if not isNearWorkbench(player) then
				repairProgress:FireClient(player, itemId, -1) -- -1 signals cancelled
				activeRepairs[player] = nil
				return
			end

			local progress = math.clamp(elapsed / repairTime, 0, 1)
			repairProgress:FireClient(player, itemId, progress)
		end

		-- Repair complete — update wear in inventory
		local profile = ProfileService.GetProfile(player)
		if profile then
			local found = false
			for _, invItem in ipairs(profile.Data.inventory) do
				if invItem.id == itemId then
					invItem.wear = 100
					found = true
					break
				end
			end

			-- The part left the inventory mid-repair (e.g. it was
			-- reinstalled) — nothing was repaired, so no completion or XP.
			if not found then
				rejectRepair(player, itemId, "item left inventory during repair")
				activeRepairs[player] = nil
				return
			end

			-- Fire updated inventory and completion event
			local inventoryUpdated = ReplicatedStorage
				:WaitForChild("RemoteEvents")
				:WaitForChild("InventoryUpdated")
			inventoryUpdated:FireClient(player, profile.Data.inventory)
		end

		repairComplete:FireClient(player, itemId, item.name)
		LevelService.AddXP(player, LevelService.XP_AWARDS.repair, "repair")
		activeRepairs[player] = nil
	end)

	activeRepairs[player] = { itemId = itemId, thread = thread }
end)

-- ── Cancel Repair ─────────────────────────────────────────────────────────────

cancelRepairEvent.OnServerEvent:Connect(function(player)
	cancelRepair(player)
	repairProgress:FireClient(player, nil, -1)
end)

-- ── Cleanup on leave ──────────────────────────────────────────────────────────

Players.PlayerRemoving:Connect(function(player)
	cancelRepair(player)
end)

local RepairService = {}
return RepairService