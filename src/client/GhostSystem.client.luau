--[[
    GhostSystem (LocalScript)
    -------------------------
    Manages ghost meshes for missing engine parts.
    
    - Listens to InventoryUI selection changes
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
local mouse   = player:GetMouse()

local Modules       = ReplicatedStorage:WaitForChild("Modules")
local EngineContext  = require(Modules:WaitForChild("EngineContext"))
local HC             = require(Modules:WaitForChild("HighlightController"))
local ToolRegistry   = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolRegistry"))

local remoteFolder   = ReplicatedStorage:WaitForChild("RemoteEvents")
local reinstallEvent = remoteFolder:WaitForChild("ReinstallPart")
local templateFolder = ReplicatedStorage:WaitForChild("EnginePartTemplates")

-- Communication with InventoryUI via BindableEvents in ReplicatedStorage
local function getOrCreateBindable(name)
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then return existing end
	local b = Instance.new("BindableEvent")
	b.Name   = name
	b.Parent = ReplicatedStorage
	return b
end

local selectionChangedEvent = getOrCreateBindable("GhostSelectionChanged")
local removeFromListEvent   = getOrCreateBindable("GhostRemoveFromList")

-- ── Constants ─────────────────────────────────────────────────────────────────

local GHOST_KEY       = "GhostHighlight"
local GHOST_COLOR     = Color3.fromRGB(255, 255, 255)
local GHOST_TRANSPARENCY = 0.5  -- must be below 1 for Highlight stencil to render

-- ── State ─────────────────────────────────────────────────────────────────────

local activeGhost      = nil
local activeSelection  = nil
local selectedPart     = nil
local selectedEngine   = nil
local selectedRelData  = nil
local selectedItemId   = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- AFTER
local function getEngine(engineName)
	local enginesFolder = workspace:FindFirstChild("Engines")
	if not enginesFolder then
		warn("[GhostSystem] 'Engines' folder is missing from Workspace!")
		return nil
	end
	return enginesFolder:FindFirstChild(engineName)
end

local function findTemplate(partName, engineName)
	local engineFolder = templateFolder:FindFirstChild(engineName)
	if not engineFolder then
		warn("[GhostSystem] No template folder for engine:", engineName)
		return nil
	end
	return engineFolder:FindFirstChild(partName)
end

local function canShowGhost(partName, engineName, engine)
	local template = findTemplate(partName, engineName)
	if not template then return false end

	-- Part can only be reinstalled if everything it requires is back in the engine
	local requires = template:GetAttribute("Requires")
	if not requires or requires == "" then return true end

	for _, req in ipairs(requires:split(",")) do
		req = req:match("^%s*(.-)%s*$")
		if not engine:FindFirstChild(req) then
			return false
		end
	end
	return true
end

local function clearGhost()
	if activeGhost then
		HC.Clear(GHOST_KEY)
		activeGhost:Destroy()
		activeGhost     = nil
		activeSelection = nil
	end
end

local function showGhost(partName, engineName, engine, relativeData)
	clearGhost()

	local template = findTemplate(partName, engineName)
	if not template then return end

	local ghost = template:Clone()
	ghost.Name  = partName .. "_Ghost"

	for _, desc in ipairs(ghost:GetDescendants()) do
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

local function onSelectionChanged(itemId, partName, engineName, relativeData)
	selectedItemId   = itemId
	selectedPart     = partName
	selectedEngine   = engineName
	selectedRelData  = relativeData

	clearGhost()

	if not partName or not engineName then return end

	local engine = getEngine(engineName)
	if not engine then return end

	if canShowGhost(partName, engineName, engine) then
		showGhost(partName, engineName, engine, relativeData)
	end
end

selectionChangedEvent.Event:Connect(onSelectionChanged)

-- ── Reinstall Input ───────────────────────────────────────────────────────────

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not activeGhost then return end
	if not selectedPart or not selectedEngine then return end

	-- Check mouse is hovering over the ghost
	local target = mouse.Target
	if not target then return end
	if not target:IsDescendantOf(activeGhost) then return end

	-- Fire reinstall to server with itemId
	reinstallEvent:FireServer(selectedItemId)

	-- Optimistically clear ghost and deselect
	clearGhost()
	removeFromListEvent:Fire(selectedItemId)
end)

-- ── Listen for server BLOCKED response ───────────────────────────────────────

reinstallEvent.OnClientEvent:Connect(function(status, blockedBy)
	if status ~= "BLOCKED" then return end
	-- Could show a message here — "reinstall X first"
	warn("[GhostSystem] Reinstall blocked by:", blockedBy)
end)

-- ── Refresh ghost when engine view changes ────────────────────────────────────

EngineContext.OnViewChanged(function(inView)
	if not inView then
		clearGhost()
	else
		if selectedPart and selectedEngine then
			onSelectionChanged(selectedItemId, selectedPart, selectedEngine, selectedRelData)
		end
	end
end)