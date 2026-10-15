--[[
    RepairService (ModuleScript, run by RepairServiceRunner)
    --------------------------------------------------------
    Server side of the workbench. A part in the player's inventory can be:
    - REPAIRED: free, timed, +XP. The player must stay at the bench.
    - REPLACED: paid through MoneyService, instant, no XP.
    The rules (what's allowed at which wear, repair time, replacement price)
    come from the shared RepairRules, which RepairUI also uses.

    RemoteEvents:
    - StartRepair    (client -> server) itemId
    - CancelRepair   (client -> server)
    - ReplacePart    (client -> server) itemId
    - RepairProgress (server -> client) itemId, 0–1; -1 = stopped
    - RepairComplete (server -> client) itemId, partName, how ("repaired" | "replaced")
    - RepairRefused  (server -> client) itemId, message — a short, player-
                     facing reason for any refusal (also logged in Output)

    Place in: ServerScriptService/Services
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Services = ServerScriptService:WaitForChild("Server"):WaitForChild("Services")

local ProfileManager   = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Modules"):WaitForChild("ProfileManager"))
local InventoryService = require(Services:WaitForChild("InventoryService"))
local LevelService     = require(Services:WaitForChild("LevelService"))
local MoneyService     = require(Services:WaitForChild("MoneyService"))
local RepairRules      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("RepairRules"))

-- ── Config ────────────────────────────────────────────────────────────────────

local WORKBENCH_RADIUS = 12   -- studs the player must stay within
local TICK             = 0.1  -- seconds between repair progress updates

-- ── Remotes ───────────────────────────────────────────────────────────────────

local function getOrCreate(parent, className, name)
	local existing = parent:FindFirstChild(name)
	if existing then return existing end
	local inst  = Instance.new(className)
	inst.Name   = name
	inst.Parent = parent
	return inst
end

local remoteFolder      = getOrCreate(ReplicatedStorage, "Folder", "RemoteEvents")
local startRepairEvent  = getOrCreate(remoteFolder, "RemoteEvent", "StartRepair")
local cancelRepairEvent = getOrCreate(remoteFolder, "RemoteEvent", "CancelRepair")
local replacePartEvent  = getOrCreate(remoteFolder, "RemoteEvent", "ReplacePart")
local repairProgress    = getOrCreate(remoteFolder, "RemoteEvent", "RepairProgress")
local repairComplete    = getOrCreate(remoteFolder, "RemoteEvent", "RepairComplete")
local repairRefused     = getOrCreate(remoteFolder, "RemoteEvent", "RepairRefused")
local inventoryUpdated  = getOrCreate(remoteFolder, "RemoteEvent", "InventoryUpdated")

-- ── State ─────────────────────────────────────────────────────────────────────

local activeRepairs = {} -- [player] = { itemId = string, thread = thread }

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- The bench's "Main" part (or PrimaryPart), looked up once and re-found only
-- if it's been removed — not scanned every repair tick.
local benchPart = nil
local function getBenchPart()
	if benchPart and benchPart.Parent then return benchPart end
	benchPart = nil
	local wb = workspace:FindFirstChild("Workbench")
	if not wb then return nil end
	local main = wb:FindFirstChild("Main", true)
	if main and main:IsA("BasePart") then
		benchPart = main
	elseif wb:IsA("Model") and wb.PrimaryPart then
		benchPart = wb.PrimaryPart
	end
	return benchPart
end

local function isNearWorkbench(player)
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local bench = getBenchPart()
	if not hrp or not bench then return false end
	return (hrp.Position - bench.Position).Magnitude <= WORKBENCH_RADIUS
end

-- Tells the client why, in words for the player, and stops any progress bar.
local function refuse(player, itemId, message, logDetail)
	warn("[RepairService] Refused for", player.Name, "-", logDetail or message)
	repairRefused:FireClient(player, itemId, message)
	repairProgress:FireClient(player, itemId, -1)
end

-- Sets an inventory item to perfect condition and resends the inventory.
-- Returns false if the item is no longer in the inventory.
local function setPerfect(player, itemId)
	local profile = ProfileManager.GetProfile(player)
	if not profile then return false end
	for _, invItem in ipairs(profile.Data.inventory) do
		if invItem.id == itemId then
			invItem.wear = 100
			inventoryUpdated:FireClient(player, profile.Data.inventory)
			return true
		end
	end
	return false
end

-- Common checks for both actions. Returns the inventory item, or nil after
-- refusing.
local function checkRequest(player, itemId)
	if type(itemId) ~= "string" then
		return nil
	end
	if not isNearWorkbench(player) then
		refuse(player, itemId, "GO TO THE WORKBENCH", "not near workbench")
		return nil
	end
	local hasPart, item = InventoryService.HasPartById(player, itemId)
	if not hasPart then
		refuse(player, itemId, "PART NOT IN INVENTORY", "item not in inventory")
		return nil
	end
	return item
end

local function cancelRepair(player)
	local repair = activeRepairs[player]
	if repair then
		task.cancel(repair.thread)
		activeRepairs[player] = nil
	end
end

-- ── Repair (free, timed) ──────────────────────────────────────────────────────

startRepairEvent.OnServerEvent:Connect(function(player, itemId)
	cancelRepair(player)

	local item = checkRequest(player, itemId)
	if not item then return end

	local options = RepairRules.GetOptions(item.wear)
	if not options.canRepair then
		refuse(player, itemId, options.reason or options.repairReason or "CAN'T REPAIR",
			"can't repair at wear " .. tostring(item.wear))
		return
	end

	local repairTime = RepairRules.GetRepairTime(item.wear)

	local thread = task.spawn(function()
		local elapsed = 0
		while elapsed < repairTime do
			task.wait(TICK)
			elapsed += TICK

			if not isNearWorkbench(player) then
				activeRepairs[player] = nil
				refuse(player, itemId, "REPAIR STOPPED: LEFT THE BENCH", "walked away mid-repair")
				return
			end
			repairProgress:FireClient(player, itemId, math.clamp(elapsed / repairTime, 0, 1))
		end

		activeRepairs[player] = nil

		-- The part left the inventory mid-repair (e.g. it was reinstalled):
		-- nothing was repaired, so no completion and no XP.
		if not setPerfect(player, itemId) then
			refuse(player, itemId, "PART NOT IN INVENTORY", "item left inventory during repair")
			return
		end

		repairComplete:FireClient(player, itemId, item.name, "repaired")
		LevelService.AddXP(player, LevelService.XP_AWARDS.repair, "repair")
	end)

	activeRepairs[player] = { itemId = itemId, thread = thread }
end)

cancelRepairEvent.OnServerEvent:Connect(function(player)
	cancelRepair(player)
	repairProgress:FireClient(player, nil, -1)
end)

-- ── Replace (paid, instant) ───────────────────────────────────────────────────

replacePartEvent.OnServerEvent:Connect(function(player, itemId)
	local item = checkRequest(player, itemId)
	if not item then return end

	local options = RepairRules.GetOptions(item.wear)
	if not options.canReplace then
		refuse(player, itemId, options.reason or "CAN'T REPLACE",
			"can't replace at wear " .. tostring(item.wear))
		return
	end

	-- Replacing the part that's mid-repair stops that repair (no XP for it).
	local repair = activeRepairs[player]
	if repair and repair.itemId == itemId then
		cancelRepair(player)
	end

	local price = RepairRules.GetReplacePrice(RepairRules.FindTemplate(item.engineName, item.name))
	-- (TrySpend refuses amounts of 0, so a free part skips paying.)
	if price > 0 and not MoneyService.TrySpend(player, price, "replace " .. item.name) then
		refuse(player, itemId, "NOT ENOUGH MONEY", "can't afford $" .. price)
		return
	end

	if not setPerfect(player, itemId) then
		-- Shouldn't happen (checked above with no yield in between), but never
		-- keep the money for a part that wasn't replaced.
		if price > 0 then
			MoneyService.AddMoney(player, price, "refund: replace failed")
		end
		refuse(player, itemId, "PART NOT IN INVENTORY", "item vanished during replace")
		return
	end

	repairComplete:FireClient(player, itemId, item.name, "replaced")
end)

-- ── Cleanup on leave ──────────────────────────────────────────────────────────

Players.PlayerRemoving:Connect(function(player)
	cancelRepair(player)
end)

local RepairService = {}
return RepairService
