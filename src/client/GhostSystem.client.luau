--!strict
--[[
    GhostSystem (LocalScript)
    -------------------------
    Manages ghost meshes for missing engine parts.
    
    - Listens to InventoryUI selection changes (ClientSignals.PartSelected)
    - When a part is selected, finds its ghost in the engine
    - Ghost only shows if the part it depends on is physically present
    - Shows white stencil highlight on the ghost
    - Player interacts with ghost to reinstall the part

    Place in: StarterPlayerScripts
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local player  = Players.LocalPlayer

local Modules       = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local EngineContext  = require(Modules:WaitForChild("EngineContext"))
local HC             = require(Modules:WaitForChild("HighlightController"))
local ZoneUtils      = require(Modules:WaitForChild("ZoneUtils"))
local PartRules      = require(Modules:WaitForChild("PartRules"))
local Remotes        = require(Modules:WaitForChild("Remotes"))
local ClientSignals  = require(Modules:WaitForChild("ClientSignals"))
local Types          = require(Modules:WaitForChild("Types"))
local CarUtils       = require(Modules:WaitForChild("CarUtils"))

local reinstallEvent = Remotes.ReinstallPart
local templateFolder = ReplicatedStorage:WaitForChild("EnginePartTemplates")

-- ── Constants ─────────────────────────────────────────────────────────────────

local GHOST_KEY       = "GhostHighlight"
local GHOST_COLOR     = Color3.fromRGB(255, 255, 255)
local GHOST_TRANSPARENCY = 0.5  -- must be below 1 for Highlight stencil to render

-- ── State ─────────────────────────────────────────────────────────────────────

type RelativeData = Types.RelativeData

local activeGhost: Instance?            = nil
local selectedPart: string?             = nil
local selectedEngine: string?           = nil
local selectedRelData: RelativeData?    = nil
local selectedItemId: string?           = nil
local selectedCarId: string?            = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- The engine a ghost belongs to is whatever is parked in the bay the player
-- is standing in. It only counts if it's the player's own car and the part
-- belongs in it (same rule as the server: CarUtils.PartFits).
local function getEngine(engineName: string, carId: string?): Model?
	local engine = ZoneUtils.GetEngineForPlayer(player)
	if engine and CarUtils.CanWorkOn(engine, player) and CarUtils.PartFits(carId, engineName, engine) then
		return engine
	end
	return nil
end

local function findTemplate(partName: string, engineName: string): Instance?
	local engineFolder = templateFolder:FindFirstChild(engineName)
	if not engineFolder then
		warn("[GhostSystem] No template folder for engine:", engineName)
		return nil
	end
	return engineFolder:FindFirstChild(partName)
end

-- Same rule the server enforces on reinstall (PartRules): everything this
-- part Requires must already be back in the engine.
local function canShowGhost(partName: string, engineName: string, engine: Model): boolean
	local template = findTemplate(partName, engineName)
	if not template then return false end
	return PartRules.GetReinstallBlocker(template, engine) == nil
end

local function clearGhost()
	if activeGhost then
		HC.Clear(GHOST_KEY)
		activeGhost:Destroy()
		activeGhost = nil
	end
end

local function showGhost(partName: string, engineName: string, engine: Model, relativeData: RelativeData?)
	clearGhost()

	local template = findTemplate(partName, engineName)
	if not template or not template:IsA("PVInstance") then return end

	local ghost = template:Clone()
	ghost.Name  = partName .. "_Ghost"

	-- The ghost sits inside the engine model, so it must not look like a
	-- real engine part: without these attributes EngineContext won't target
	-- it, and the Wrench/inspection tool can't act on it.
	ghost:SetAttribute("Inspectable", nil)
	ghost:SetAttribute("IsBolt", nil)
	-- EngineContext also stops at IsGhost, so hovering the ghost targets
	-- nothing (not the nearest real part behind it) and a Wrench click
	-- meant for the ghost can't remove some other part.
	ghost:SetAttribute("IsGhost", true)

	for _, desc in ipairs(ghost:GetDescendants()) do
		desc:SetAttribute("Inspectable", nil)
		desc:SetAttribute("IsBolt", nil)
		if desc:IsA("BasePart") then
			desc.Transparency = GHOST_TRANSPARENCY
			desc.CanCollide   = false
			desc.CanQuery     = true
			desc.Anchored     = true
			desc.CastShadow   = false
		end
	end

	ghost.Parent = engine

	-- Position ghost relative to engine pivot using stored offset
	if relativeData then
		local rd         = relativeData
		local relativeCF = CFrame.new(rd.x, rd.y, rd.z)
			* CFrame.fromEulerAnglesXYZ(rd.rx, rd.ry, rd.rz)
		ghost:PivotTo(engine:GetPivot() * relativeCF)
	end

	activeGhost = ghost
	HC.CreateStencil(GHOST_KEY, ghost, GHOST_COLOR)
end

local function onSelectionChanged(itemId: string?, partName: string?, engineName: string?,
	relativeData: RelativeData?, carId: string?)
	selectedItemId   = itemId
	selectedPart     = partName
	selectedEngine   = engineName
	selectedRelData  = relativeData
	selectedCarId    = carId

	clearGhost()

	if not partName or not engineName then return end

	local engine = getEngine(engineName, carId)
	if not engine then return end

	if canShowGhost(partName, engineName, engine) then
		showGhost(partName, engineName, engine, relativeData)
	end
end

ClientSignals.PartSelected:Connect(onSelectionChanged)

-- ── Reinstall Input ───────────────────────────────────────────────────────────

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not activeGhost then return end
	if not selectedPart or not selectedEngine then return end

	-- Only when the mouse is on the ghost. Uses EngineContext's hit (a ray
	-- that only sees the engine and looks through invisible parts), the same
	-- one the hover uses — so the car body or a faded part in front can't
	-- swallow the click, and hover and click always agree.
	local target = EngineContext.GetHitPart()
	if not target then return end
	if not target:IsDescendantOf(activeGhost) then return end

	-- Fire reinstall to server with itemId
	reinstallEvent:FireServer(selectedItemId)

	-- Optimistically clear ghost and deselect
	clearGhost()
	ClientSignals.ReinstallRequested:Fire(selectedItemId)
end)

-- ── Listen for server BLOCKED response ───────────────────────────────────────

-- The server also resends the full inventory on any rejection, so the part
-- this script hid optimistically reappears in InventoryUI by itself.
reinstallEvent.OnClientEvent:Connect(function(status, detail)
	if status == "BLOCKED" then
		-- Could show a message here — "reinstall X first"
		warn("[GhostSystem] Reinstall blocked — reinstall first:", detail)
	elseif status == "FAILED" then
		warn("[GhostSystem] Reinstall failed:", detail)
	end
end)

-- ── Refresh ghost when engine view changes ────────────────────────────────────

EngineContext.OnViewChanged(function(inView)
	if not inView then
		clearGhost()
	else
		if selectedPart and selectedEngine then
			onSelectionChanged(selectedItemId, selectedPart, selectedEngine, selectedRelData, selectedCarId)
		end
	end
end)