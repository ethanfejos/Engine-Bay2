--!strict
--[[
    InventoryService (ModuleScript, started by Main)
    ------------------------------------------------
    Server-side inventory management for engine parts.
    Uses ProfileService for persistent saving.

    Handles:
    - Adding parts to player inventory when removed
    - Removing parts from inventory when reinstalled
    - Replicating inventory state to client
    - Saving on leave via ProfileService
    - Clear Inventory (testing tool, game owner only — see Owner.luau)

    RemoteEvents used:
    - InventoryUpdated  (server -> client) fires when inventory changes
    - ReinstallPart     (client -> server) player wants to reinstall a part
    - RequestInventory  (client -> server) client requests current inventory on join

    Started by Main.server.luau (see there for the order).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Points at ProfileManager (wraps the real ProfileService library) rather
-- than the old hand-rolled ProfileService.luau. Kept as the local name
-- "ProfileService" so every ProfileService.GetProfile(...) call below is
-- unchanged.
local ProfileService = require(script.Parent.Parent.Modules.ProfileManager)
local Owner          = require(script.Parent.Parent.Modules.Owner)
local CarService     = require(script.Parent.CarService)
local ZoneUtils      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))
local CarUtils       = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("CarUtils"))
local PartRules      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("PartRules"))

-- ── Remotes ───────────────────────────────────────────────────────────────────

local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Types"))

type Item = Types.InventoryItem

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Remotes"))
local inventoryUpdated     = Remotes.InventoryUpdated
local reinstallEvent       = Remotes.ReinstallPart
local requestInventory     = Remotes.RequestInventory
local partReinstalledEvent = Remotes.PartReinstalled
local clearInventory       = Remotes.ClearInventory

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- ── Inventory API ─────────────────────────────────────────────────────────────

local InventoryService = {}

function InventoryService.AddPart(player: Player, partName: string, wear: number, engineName: string,
	carId: string?, relativeData: Types.RelativeData?, itemId: string)
	local profile = ProfileService.GetProfile(player)
	if not profile then return end

	-- Never hold the same part twice (e.g. a pickup racing a recovery).
	for _, existing in ipairs(profile.Data.inventory) do
		if existing.id == itemId then return end
	end

	table.insert(profile.Data.inventory, {
		id           = itemId,
		name         = partName,
		wear         = wear,
		engineName   = engineName,
		carId        = carId,
		relativeData = relativeData,
	})

	inventoryUpdated:FireClient(player, profile.Data.inventory)
end

function InventoryService.RemovePart(player: Player, itemId: string): Item?
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

function InventoryService.HasPartById(player: Player, itemId: any): (boolean, Item?)
	local inventory = InventoryService.GetInventory(player)
	for _, item in ipairs(inventory) do
		if item.id == itemId then
			return true, item
		end
	end
	return false, nil
end

-- Removes every part that came from `carId` (a customer's car going home
-- takes its parts with it). Returns how many were removed.
function InventoryService.RemovePartsFromCar(player: Player, carId: string): number
	local profile = ProfileService.GetProfile(player)
	if not profile then return 0 end
	local kept, removed = {}, 0
	for _, item in ipairs(profile.Data.inventory) do
		if item.carId == carId then
			removed += 1
		else
			table.insert(kept, item)
		end
	end
	if removed > 0 then
		profile.Data.inventory = kept
		inventoryUpdated:FireClient(player, kept)
	end
	return removed
end

function InventoryService.GetInventory(player: Player): { Item }
	local profile = ProfileService.GetProfile(player)
	if not profile then return {} end
	return profile.Data.inventory
end

function InventoryService.HasPart(player: Player, partName: string, engineName: string): (boolean, Item?)
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

-- Is `instance` inside a part or bolt that can itself be removed?
local function isInRemovable(instance: Instance, engine: Instance): boolean
	local current: Instance? = instance
	while current and current ~= engine do
		if current:GetAttribute("Inspectable") or current:GetAttribute("IsBolt") then
			return true
		end
		current = current.Parent
	end
	return false
end

-- What a reinstalled part is welded to: a fixed part of the engine (never
-- another removable part, or removing that one would drop this one too).
-- The engine's PrimaryPart if it qualifies, otherwise its biggest fixed part.
local function weldTarget(engine: Model): BasePart?
	local primary = engine.PrimaryPart
	if primary and not isInRemovable(primary, engine) then
		return primary
	end
	local best: BasePart? = nil
	local bestVolume = -1
	for _, d in ipairs(engine:GetDescendants()) do
		if d:IsA("BasePart") and d.Name ~= "EngineTrigger" and not isInRemovable(d, engine) then
			local volume = d.Size.X * d.Size.Y * d.Size.Z
			if volume > bestVolume then
				best, bestVolume = d, volume
			end
		end
	end
	return best
end

-- Joins a reinstalled part to the car so it moves with it (the cars are
-- drivable): every BasePart of the part is welded to the engine's fixed part
-- and takes its Anchored state — unanchored on a live car, anchored on a
-- static one. Call once the part is in place in the engine.
local function attachToEngine(part: Instance, engine: Model)
	local target = weldTarget(engine)
	if not target then
		warn("[InventoryService] No fixed engine part to weld to in", engine:GetFullName())
		return
	end
	local baseParts: { BasePart } = {}
	if part:IsA("BasePart") then table.insert(baseParts, part) end
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("BasePart") then table.insert(baseParts, d) end
	end
	for _, bp in ipairs(baseParts) do
		local weld  = Instance.new("WeldConstraint")
		weld.Name   = "ReinstallWeld"
		weld.Part0  = target
		weld.Part1  = bp
		weld.Parent = bp
	end
	-- Unanchor only after every weld exists, so nothing drops in between.
	for _, bp in ipairs(baseParts) do
		bp.Anchored = target.Anchored
	end
end

-- Every rejected reinstall tells the client why AND resends the real
-- inventory. GhostSystem hides the part from the list optimistically when
-- you click its ghost; without this resend, a rejected part stayed hidden
-- until rejoin.
--   status "BLOCKED" -> detail = name of the part that must go back in first
--   status "FAILED"  -> detail = short reason, for Output / future UI
local function rejectReinstall(player: Player, status: string, detail: string)
	reinstallEvent:FireClient(player, status, detail)
	inventoryUpdated:FireClient(player, InventoryService.GetInventory(player))
end

reinstallEvent.OnServerEvent:Connect(function(player, itemId)
	-- Validate player has this item by id
	local hasPart, item = InventoryService.HasPartById(player, itemId)
	if not hasPart or not item then
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

	if not CarUtils.CanWorkOn(engine, player) then
		rejectReinstall(player, "FAILED", "not your car")
		return
	end

	-- A part goes back into the car it came from (see CarUtils.PartFits).
	if not CarUtils.PartFits(item.carId, engineName, engine) then
		rejectReinstall(player, "FAILED", "from a different car")
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

	-- Position it relative to the engine's pivot BEFORE it enters the world,
	-- so it never appears at the template's position for a frame.
	local rd = item.relativeData
	if rd and clone:IsA("PVInstance") then
		local relativeCF = CFrame.new(rd.x, rd.y, rd.z)
			* CFrame.fromEulerAnglesXYZ(rd.rx, rd.ry, rd.rz)
		clone:PivotTo(engine:GetPivot() * relativeCF)
	end
	clone.Parent = engine

	-- Weld it to the car, so it moves with the car instead of staying behind.
	attachToEngine(clone, engine)

	-- Fire reinstall animation to client
	partReinstalledEvent:FireClient(player, clone)

	-- Remove from inventory by id, and save the car with the part back in
	InventoryService.RemovePart(player, itemId)
	CarService.RecordChange(engine)
end)

-- Testing tool, owner only: anyone else firing this remote is ignored
-- (the button is only shown to the owner, but the client can't be trusted).
clearInventory.OnServerEvent:Connect(function(player)
	if not Owner.Is(player) then
		warn("[InventoryService]", player.Name, "tried to clear their inventory without being the owner")
		return
	end
	local profile = ProfileService.GetProfile(player)
	if not profile then return end
	profile.Data.inventory = {}
	inventoryUpdated:FireClient(player, profile.Data.inventory)
end)

return InventoryService