--[[
    EngineServer (Script)
    ---------------------
    Changes from previous version:
    - Added InventoryService integration — parts go to inventory on removal
    - Removed respawn system — replaced by reinstall system
    - Added PartRemoving remote for client animation
    - Fixed missing ToolRegistry require

    Other scripts it links to:
    - Workspace.EngineZones: folder of zone BaseParts (name = zone identity)
    - ReplicatedStorage.Modules.ZoneUtils: finds the engine parked in a bay
    - ReplicatedStorage.RemoteEvents.RemovePart: fired by Wrench tool
    - ServerScriptService.Services.InventoryService: handles part inventory
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService         = game:GetService("HttpService")

local LevelService      = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("LevelService"))
local PartPickupService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("PartPickupService"))
local ZoneUtils         = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))

-- ── Physics stabilization on removal ────────────────────────────────────────────
-- Destroying a part removes real mass from a live, unanchored vehicle, and
-- its suspension visibly reacts (the whole car lurches up, then resettles).
-- Anchoring every part of the car across the moment of removal freezes the
-- simulation so nothing can react, then each part is restored to whatever
-- its OWN Anchored state actually was beforehand — not forced to false, in
-- case the vehicle has its own anchoring already — so this can't change how
-- the car behaves afterward, just prevents a visible pop at the instant of
-- removal.
local STABILIZE_SETTLE_TIME = 0.3

local function stabilizeCarAcross(model, work)
	local carRoot = ZoneUtils.GetTopLevelAncestor(model)
	local parts = {}
	for _, part in ipairs(carRoot:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(parts, { part = part, wasAnchored = part.Anchored })
			part.Anchored = true
		end
	end

	work()

	task.delay(STABILIZE_SETTLE_TIME, function()
		for _, entry in ipairs(parts) do
			if entry.part and entry.part.Parent then
				entry.part.Anchored = entry.wasAnchored
			end
		end
	end)
end

-- ── Remote Events ─────────────────────────────────────────────────────────────

local function getOrCreate(parent, className, name)
	local existing = parent:FindFirstChild(name)
	if existing then return existing end
	local inst  = Instance.new(className)
	inst.Name   = name
	inst.Parent = parent
	return inst
end

local remoteFolder      = getOrCreate(ReplicatedStorage, "Folder", "RemoteEvents")
local removeEvent       = getOrCreate(remoteFolder, "RemoteEvent", "RemovePart")
local partRemovingEvent = getOrCreate(remoteFolder, "RemoteEvent", "PartRemoving")

-- ── Constants ─────────────────────────────────────────────────────────────────

local WEAR_MIN          = 10
local WEAR_MAX          = 100
local REMOVE_ANIM_DELAY = 0.7

-- ── Dependency Check ──────────────────────────────────────────────────────────

local function checkDependencies(model)
	local requires = model:GetAttribute("Requires")
	if requires and requires ~= "" then
		local engine = model.Parent
		for _, partName in ipairs(requires:split(",")) do
			partName = partName:match("^%s*(.-)%s*$")
			if engine:FindFirstChild(partName) then
				return false, partName
			end
		end
	end

	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("IsBolt") then
			return false, child.Name
		end
	end

	return true, nil
end

-- ── Wear Initialisation ───────────────────────────────────────────────────────

local function initWear(model)
	if not model:IsA("Model") then return end
	if not model:GetAttribute("Inspectable") then return end
	if model:GetAttribute("Wear") ~= nil then return end
	model:SetAttribute("Wear", math.random(WEAR_MIN, WEAR_MAX))
end

workspace.DescendantAdded:Connect(function(descendant)
	task.defer(function()
		initWear(descendant)
	end)
end)

local function initAllWear()
	for _, descendant in ipairs(workspace:GetDescendants()) do
		initWear(descendant)
	end
end

-- ── Remove Event ──────────────────────────────────────────────────────────────

removeEvent.OnServerEvent:Connect(function(player, model)
	if not model or not model:IsA("Model") then
		warn("[EngineServer] Invalid remove target from:", player.Name)
		return
	end

	if not model:GetAttribute("Inspectable") and not model:GetAttribute("IsBolt") then
		warn("[EngineServer] Non-inspectable remove attempt from:", player.Name)
		return
	end

	-- The engine is whatever is parked in the bay the player is standing in —
	-- not a fixed engine tied to the zone.
	local engine, zone = ZoneUtils.GetEngineForPlayer(player)
	if not zone then
		warn("[EngineServer] Out-of-zone remove attempt from:", player.Name)
		return
	end

	if not engine or not model:IsDescendantOf(engine) then
		warn("[EngineServer] Model not in player's zone engine from:", player.Name)
		return
	end

	-- Bolts — remove with animation, no inventory
	if model:GetAttribute("IsBolt") then
		partRemovingEvent:FireClient(player, model)
		task.delay(REMOVE_ANIM_DELAY, function()
			if model and model.Parent then
				model:Destroy()
			end
		end)
		return
	end

	-- Dependency check
	local canRemove, blockedBy = checkDependencies(model)
	if not canRemove then
		removeEvent:FireClient(player, "BLOCKED", model, blockedBy)
		return
	end

	-- Capture data before destroy
	local modelName    = model.Name
	local engineName   = engine.Name
	local wear         = model:GetAttribute("Wear") or 100

	-- Calculate CFrame relative to engine pivot
	local enginePivot  = engine:GetPivot()
	local modelPivot   = model:GetPivot()
	local relativeCF   = enginePivot:ToObjectSpace(modelPivot)

	-- Serialize CFrame for DataStore (CFrames can't be stored directly)
	local rx, ry, rz   = relativeCF:ToEulerAnglesXYZ()
	local relativeData = {
		x  = relativeCF.X,
		y  = relativeCF.Y,
		z  = relativeCF.Z,
		rx = rx,
		ry = ry,
		rz = rz,
	}

	-- Unique id so duplicate part names can be distinguished
	local itemId = HttpService:GenerateGUID(false)

	partRemovingEvent:FireClient(player, model)

	task.delay(REMOVE_ANIM_DELAY, function()
		if model and model.Parent then
			stabilizeCarAcross(model, function()
				-- DropPart clones the model for the pickup object before this
				-- destroys the original — the part no longer goes straight into
				-- inventory, it has to be picked up from where it was removed.
				PartPickupService.DropPart(player, model, modelName, wear, engineName, relativeData, itemId, zone.Name)
				model:Destroy()
			end)
			LevelService.AddXP(player, LevelService.XP_AWARDS.remove, "remove")
	end
end)
end)

-- ── Init ──────────────────────────────────────────────────────────────────────

initAllWear()