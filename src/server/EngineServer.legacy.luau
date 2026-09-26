--[[
    EngineServer (Script)
    ---------------------
    Changes from previous version:
    - Added InventoryService integration — parts go to inventory on removal
    - Removed respawn system — replaced by reinstall system
    - Added PartRemoving remote for client animation
    - Fixed missing ToolRegistry require

    Other scripts it links to:
    - Workspace.EngineZones: folder of zone BaseParts with ZoneId attributes
    - ReplicatedStorage.Config.ToolRegistry: maps zoneId -> partName
    - ReplicatedStorage.RemoteEvents.RemovePart: fired by Wrench tool
    - ServerScriptService.Services.InventoryService: handles part inventory
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService         = game:GetService("HttpService")

local ToolRegistry     = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolRegistry"))
local InventoryService = require(ServerScriptService:WaitForChild("Services"):WaitForChild("InventoryService"))
local LevelService      = require(ServerScriptService:WaitForChild("Services"):WaitForChild("LevelService"))

local zonesFolder = workspace:WaitForChild("EngineZones")

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

-- ── Zone Registration ─────────────────────────────────────────────────────────

local zoneParts = {}

local function registerZone(part)
	if not part:IsA("BasePart") then return end
	local zoneId = part:GetAttribute("ZoneId")
	if not zoneId then return end
	zoneParts[zoneId] = part
end

for _, part in ipairs(zonesFolder:GetChildren()) do
	registerZone(part)
end
zonesFolder.ChildAdded:Connect(registerZone)

-- ── Zone & Engine Lookup ──────────────────────────────────────────────────────

local function getZoneForPlayer(player)
	local hrp = player.Character
		and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	for zoneId, zone in pairs(zoneParts) do
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

local function getEngineForZone(zoneId)
	local config = ToolRegistry[zoneId]
	if not config then return nil end

	-- Look inside the "engines" folder instead of directly in workspace
	local enginesFolder = workspace:FindFirstChild("Engines")
	if enginesFolder then
		return enginesFolder:FindFirstChild(config.partName)
	else
		warn("[EngineServer] Could not find the 'Engines' folder in Workspace!")
		return nil
	end
end

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

	local zoneId = getZoneForPlayer(player)
	if not zoneId then
		warn("[EngineServer] Out-of-zone remove attempt from:", player.Name)
		return
	end

	local engine = getEngineForZone(zoneId)
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
			model:Destroy()
			InventoryService.AddPart(player, modelName, wear, engineName, relativeData, itemId)
			LevelService.AddXP(player, LevelService.XP_AWARDS.remove, "remove")
		end
	end)
end)

-- ── Init ──────────────────────────────────────────────────────────────────────

initAllWear()