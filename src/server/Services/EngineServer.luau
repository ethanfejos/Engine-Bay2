--!strict
--[[
    EngineServer (ModuleScript, started by Main)
    --------------------------------------------
    Server side of removing parts from an engine (the Wrench), plus giving
    every inspectable part a random starting Wear.

    RemovePart (client -> server): the Wrench asks to remove a part or bolt.
    The server re-checks every rule, using the same PartRules the Wrench
    uses for its hints:
    - the part is a real Inspectable part or bolt in the engine parked in
      the bay the player is standing in, and the player owns that car
    - parts (not bolts) have been inspected by this player
    - nothing is still in the way (Requires / bolts)
    - it isn't already being removed

    RemovePart (server -> client) answers every refusal so the Wrench can
    show why and unlock:  (status, model, detail)
      "BLOCKED"        detail = the part or bolt that must come off first
      "NOT_INSPECTED"  part hasn't been inspected yet
      "FAILED"         detail = short reason (not in a bay, not your car...)
    Success is signalled by PartRemoving (server -> client), which also
    plays the removal animation.
]]

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local HttpService         = game:GetService("HttpService")

local LevelService      = require(script.Parent.LevelService)
local PartPickupService = require(script.Parent.PartPickupService)
local CarService        = require(script.Parent.CarService)
local ProfileManager    = require(script.Parent.Parent.Modules.ProfileManager)
local ZoneUtils         = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))
local PartRules         = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("PartRules"))
local CarUtils          = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("CarUtils"))

-- ── Physics stabilization on removal ────────────────────────────────────────────
-- Destroying a part removes real mass from a live, unanchored vehicle, and
-- its suspension visibly reacts (the whole car lurches up, then resettles).
-- Anchoring every part of the car across the moment of removal freezes the
-- simulation so nothing can react, then each part is restored to whatever
-- its OWN Anchored state actually was beforehand — not forced to false, in
-- case the vehicle has its own anchoring already — so this can't change how
-- the car behaves afterward, just prevents a visible pop at the instant of
-- removal.
--
-- Overlapping removals on the same car (two clicks within the settle time,
-- or two players) share ONE freeze: the original Anchored states are saved
-- only by the first, and restored only when the last one finishes. Without
-- this, the second removal would save "true" (the first one's freeze) as
-- the original state and leave the whole car anchored for good.
local STABILIZE_SETTLE_TIME = 0.3

-- [carRoot] = { count = active removals, saved = { [part] = wasAnchored } }
local activeFreezes = {}

local function stabilizeCarAcross(model, work)
	local carRoot = ZoneUtils.GetTopLevelAncestor(model)

	local freeze = activeFreezes[carRoot]
	if not freeze then
		freeze = { count = 0, saved = {} }
		activeFreezes[carRoot] = freeze
	end
	freeze.count += 1

	for _, part in ipairs(carRoot:GetDescendants()) do
		-- Only record a part the first time this freeze sees it; anything
		-- already in `saved` is currently anchored by us, not by the car.
		if part:IsA("BasePart") and freeze.saved[part] == nil then
			freeze.saved[part] = part.Anchored
			part.Anchored = true
		end
	end

	-- pcall so an error inside work() can't skip the unfreeze below and
	-- leave the car anchored.
	local ok, err = pcall(work)
	if not ok then
		warn("[EngineServer] Error during part removal:", err)
	end

	task.delay(STABILIZE_SETTLE_TIME, function()
		freeze.count -= 1
		if freeze.count > 0 then return end -- another removal still needs the freeze

		activeFreezes[carRoot] = nil
		for part, wasAnchored in pairs(freeze.saved) do
			if part.Parent then
				part.Anchored = wasAnchored
			end
		end
	end)
end

-- ── Remote Events ─────────────────────────────────────────────────────────────

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Remotes"))
local removeEvent       = Remotes.RemovePart
local partRemovingEvent = Remotes.PartRemoving

-- ── Constants ─────────────────────────────────────────────────────────────────

local WEAR_MIN          = 10
local WEAR_MAX          = 100
local REMOVE_ANIM_DELAY = 0.7

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

-- Models currently mid-removal (during the animation delay), so a repeated
-- request for the same part is refused instead of replaying the animation.
local removing = setmetatable({}, { __mode = "k" })

local function refuse(player, status, model, detail)
	removeEvent:FireClient(player, status, model, detail)
end

removeEvent.OnServerEvent:Connect(function(player, model)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn("[EngineServer] Invalid remove target from:", player.Name)
		return -- nothing sensible to answer about
	end

	local isBolt = PartRules.IsBolt(model)
	if not isBolt and not PartRules.IsInspectable(model) then
		warn("[EngineServer] Non-inspectable remove attempt from:", player.Name)
		refuse(player, "FAILED", model, "not a removable part")
		return
	end

	if removing[model] then
		return -- already on its way out; the first request's PartRemoving answers it
	end

	-- The engine is whatever is parked in the bay the player is standing in —
	-- not a fixed engine tied to the zone.
	local engine, zone = ZoneUtils.GetEngineForPlayer(player)
	if not zone then
		refuse(player, "FAILED", model, "not in a bay")
		return
	end
	if not engine or not model:IsDescendantOf(engine) then
		refuse(player, "FAILED", model, "not in this bay's engine")
		return
	end
	if not CarUtils.CanWorkOn(engine, player) then
		refuse(player, "FAILED", model, "not your car")
		return
	end

	-- Bolts — no inspection needed, no inventory, just removed
	if isBolt then
		removing[model] = true
		partRemovingEvent:FireClient(player, model)
		task.delay(REMOVE_ANIM_DELAY, function()
			if model.Parent then
				model:Destroy()
				CarService.RecordChange(engine) -- the save matches the car straight away
			end
		end)
		return
	end

	-- Parts must have been inspected first. Inspections are saved on the
	-- car's record on the server (LevelService records them), so this can't
	-- be skipped by a client that never ran the inspection tool.
	local profile = ProfileManager.GetProfile(player)
	if not profile then
		refuse(player, "FAILED", model, "save not loaded")
		return
	end
	if not CarService.IsInspected(model) then
		refuse(player, "NOT_INSPECTED", model)
		return
	end

	local blockedBy = PartRules.GetRemovalBlocker(model)
	if blockedBy then
		refuse(player, "BLOCKED", model, blockedBy)
		return
	end

	removing[model] = true

	-- Capture data before destroy
	local modelName    = model.Name
	local engineName   = engine.Name
	local carId        = CarUtils.GetCarId(engine)
	local wear         = tonumber(model:GetAttribute("Wear")) or 100

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
		if not model.Parent then return end

		-- Removal XP is paid once per physical part: the first time it
		-- comes off a car. InventoryService marks every reinstalled part
		-- with RemovalXpPaid, so remove → reinstall → remove can't farm
		-- XP. Read before DropPart/Destroy, while the model still exists.
		local removalXpAlreadyPaid = model:GetAttribute("RemovalXpPaid") == true

		stabilizeCarAcross(model, function()
			-- DropPart clones the model for the pickup object before this
			-- destroys the original — the part no longer goes straight into
			-- inventory, it has to be picked up from where it was removed.
			PartPickupService.DropPart(player, model, modelName, wear, engineName, carId, relativeData, itemId, zone.Name)
			model:Destroy()
		end)

		-- If something errored and the part is still there, allow a retry
		-- rather than leaving it stuck as "being removed".
		if model.Parent then
			removing[model] = nil
			return
		end
		CarService.RecordChange(engine) -- the save matches the car straight away

		if not removalXpAlreadyPaid then
			LevelService.AddXP(player, LevelService.XP_AWARDS.remove, "remove")
		end
	end)
end)

-- ── Init ──────────────────────────────────────────────────────────────────────

initAllWear()

return {}
