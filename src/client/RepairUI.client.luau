--[[
    RepairUI (LocalScript)
    ----------------------
    - 3D Surface UI (Tilted 3D Pods)
    - Static placement relative to PartAnchor
    - Automatic number conversion for Wear %
    - Diagnostic logging to Output
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Remotes ───────────────────────────────────────────────────────────────────
local remoteFolder      = ReplicatedStorage:WaitForChild("RemoteEvents")
local inventoryUpdated  = remoteFolder:WaitForChild("InventoryUpdated")
local startRepairEvent  = remoteFolder:WaitForChild("StartRepair")
local cancelRepairEvent = remoteFolder:WaitForChild("CancelRepair")
local repairProgress    = remoteFolder:WaitForChild("RepairProgress")
local repairComplete    = remoteFolder:WaitForChild("RepairComplete")

-- ── Bindables ─────────────────────────────────────────────────────────────────
local workbenchViewChanged  = ReplicatedStorage:WaitForChild("WorkbenchViewChanged")
local selectionChangedEvent = ReplicatedStorage:WaitForChild("GhostSelectionChanged")

-- ── Config ────────────────────────────────────────────────────────────────────
local GREEN = Color3.fromRGB(0, 200, 120)
local FAIL  = Color3.fromRGB(255, 50, 50)
local WHITE = Color3.fromRGB(255, 255, 255)

local MIN_WEAR       = 10
local PART_Y_OFFSET  = 1.2 

-- ── State ─────────────────────────────────────────────────────────────────────
local inWorkbenchView  = false
local repairing        = false
local currentItemId    = nil
local currentInventory = {}
local partOnBench      = nil 
local progressFill     = nil 

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getWorkbenchAnchor()
	local wb = workspace:FindFirstChild("Workbench")
	if not wb then 
		warn("RepairUI: 'Workbench' model missing!") 
		return nil 
	end
	return wb:FindFirstChild("PartAnchor") or wb:FindFirstChild("Main")
end

local function clearBench()
	print("RepairUI: Clearing workbench...")
	local wb = workspace:FindFirstChild("Workbench")
	if wb then
		-- Clean up physical 3D mounts
		local left = wb:FindFirstChild("LeftUiMount")
		local right = wb:FindFirstChild("RightUiMount")
		if left then left:Destroy() end
		if right then right:Destroy() end

		-- Clean up part
		local part = wb:FindFirstChild("PartOnBench")
		if part then part:Destroy() end
	end

	-- Clean up any lingering GUIs in PlayerGui
	local oldLeft = playerGui:FindFirstChild("LeftRepairSurface")
	local oldRight = playerGui:FindFirstChild("RightRepairSurface")
	if oldLeft then oldLeft:Destroy() end
	if oldRight then oldRight:Destroy() end

	partOnBench = nil
	progressFill = nil
end

-- ── Build 3D World UI ─────────────────────────────────────────────────────────

local function buildBillboard(itemId, partName, wear)
	local anchor = getWorkbenchAnchor()
	local wb = workspace:FindFirstChild("Workbench")
	if not anchor or not wb then return end

	local wearValue = tonumber(wear) or 0
	print("RepairUI: Building 3D UI for " .. partName)

	-- 1. Helper to create physical mounts
	local function createMount(name, offset)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = Vector3.new(3, 1.8, 0.1)
		p.Transparency = 1 -- Set to 0.5 for debugging if needed
		p.CanCollide = false
		p.Anchored = true
		p.CFrame = anchor.CFrame * offset
		p.Parent = wb
		return p
	end

	-- Create the tilted frames
	local leftMount = createMount("LeftUiMount", CFrame.new(-4.5, 1, -1) * CFrame.Angles(0, math.rad(25), 0))
	local rightMount = createMount("RightUiMount", CFrame.new(4.5, 1, -1) * CFrame.Angles(0, math.rad(-25), 0))

	-- 2. SurfaceGui Setup (Parented to PlayerGui for interaction)
	local function createSurface(mount, name)
		local sg = Instance.new("SurfaceGui")
		sg.Name = name
		sg.Adornee = mount
		sg.Face = Enum.NormalId.Back
		sg.AlwaysOnTop = true
		sg.CanvasSize = Vector2.new(450, 225)
		sg.Parent = playerGui
		return sg
	end

	local leftSgui = createSurface(leftMount, "LeftRepairSurface")
	local rightSgui = createSurface(rightMount, "RightRepairSurface")

	-- 3. Left Side Content (Button)
	local btn = Instance.new("TextButton", leftSgui)
	btn.Size = UDim2.new(0.8, 0, 0.6, 0)
	btn.Position = UDim2.new(0.1, 0, 0.2, 0)
	btn.BackgroundColor3 = GREEN
	btn.Font = Enum.Font.GothamBold
	btn.Text = "REPAIR"
	btn.TextColor3 = WHITE
	btn.TextSize = 45
	Instance.new("UICorner", btn)

	btn.MouseButton1Click:Connect(function()
		if repairing then return end
		if wearValue <= MIN_WEAR then return end
		repairing = true
		btn.Text = "..."
		startRepairEvent:FireServer(itemId)
	end)

	-- 4. Right Side Content (Info)
	local frame = Instance.new("Frame", rightSgui)
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundTransparency = 1

	local label = Instance.new("TextLabel", frame)
	label.Size = UDim2.new(1, 0, 0.4, 0)
	label.Position = UDim2.new(0, 0, 0.1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = WHITE
	label.TextSize = 30
	label.Text = partName:upper() .. "\nCONDITION: " .. math.floor(wearValue) .. "%"

	local track = Instance.new("Frame", frame)
	track.Size = UDim2.new(0.8, 0, 0.15, 0)
	track.Position = UDim2.new(0.1, 0, 0.7, 0)
	track.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	Instance.new("UICorner", track)

	local fill = Instance.new("Frame", track)
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = GREEN
	Instance.new("UICorner", fill)
	progressFill = fill
end

-- ── Spawn Part ───────────────────────────────────────────────────────────────

local function spawnPartOnBench(itemId, partName, wear, engineName)
	clearBench()
	print("RepairUI: Spawning " .. partName)

	local anchor = getWorkbenchAnchor()
	if not anchor then return end

	local templateFolder = ReplicatedStorage:WaitForChild("EnginePartTemplates")
	local engineFolder = templateFolder:FindFirstChild(engineName)
	local template = engineFolder and engineFolder:FindFirstChild(partName)

	if not template then
		warn("RepairUI: Template missing for " .. partName)
		return
	end

	local clone = template:Clone()
	clone.Name = "PartOnBench"
	clone.Parent = workspace:FindFirstChild("Workbench")

	for _, p in ipairs(clone:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
		end
	end

	clone:PivotTo(anchor.CFrame * CFrame.new(0, PART_Y_OFFSET, 0))
	partOnBench = clone

	buildBillboard(itemId, partName, wear)
end

-- ── Events ────────────────────────────────────────────────────────────────────

selectionChangedEvent.Event:Connect(function(itemId, partName, engineName)
	if not inWorkbenchView then return end
	currentItemId = itemId
	repairing = false

	if not itemId then
		clearBench()
		return
	end

	local wear = 100
	for _, item in ipairs(currentInventory) do
		if item.id == itemId then
			wear = item.wear
			engineName = item.engineName
			break
		end
	end

	spawnPartOnBench(itemId, partName, wear, engineName)
end)

repairProgress.OnClientEvent:Connect(function(itemId, progress)
	if progress < 0 then repairing = false; return end
	if progressFill then
		TweenService:Create(progressFill, TweenInfo.new(0.1), {Size = UDim2.new(progress, 0, 1, 0)}):Play()
	end
end)

repairComplete.OnClientEvent:Connect(function(itemId, partName)
	repairing = false
	if progressFill then progressFill.Size = UDim2.new(1, 0, 1, 0) end
	task.wait(0.3)
	clearBench()
end)

inventoryUpdated.OnClientEvent:Connect(function(inv) currentInventory = inv end)

workbenchViewChanged.Event:Connect(function(active)
	inWorkbenchView = active
	if not active then
		clearBench()
		if repairing then cancelRepairEvent:FireServer(); repairing = false end
	end
end)