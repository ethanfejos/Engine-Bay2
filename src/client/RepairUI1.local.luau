-- [[ RepairUI - FINAL VERSION ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Remotes & Bindables ───────────────────────────────────────────────────────
local remoteFolder      = ReplicatedStorage:WaitForChild("RemoteEvents")
local inventoryUpdated  = remoteFolder:WaitForChild("InventoryUpdated")
local startRepairEvent  = remoteFolder:WaitForChild("StartRepair")
local repairProgress    = remoteFolder:WaitForChild("RepairProgress")
local repairComplete    = remoteFolder:WaitForChild("RepairComplete")

local workbenchViewChanged  = ReplicatedStorage:WaitForChild("WorkbenchViewChanged")
local selectionChangedEvent = ReplicatedStorage:WaitForChild("GhostSelectionChanged")

-- ── Config ────────────────────────────────────────────────────────────────────
local HOLO_BG = Color3.fromRGB(15, 20, 25)
local GREEN   = Color3.fromRGB(0, 255, 150)
local PART_Y_POS = 1.2
local UI_GAP_STUDS = 0.4

local inWorkbenchView = false
local currentInventory = {}
local partOnBench = nil
local billboardGui = nil

-- ── UI Helpers ────────────────────────────────────────────────────────────────
local function clearBench()
	if billboardGui then billboardGui:Destroy(); billboardGui = nil end
	if partOnBench then partOnBench:Destroy(); partOnBench = nil end
end

local function spawnPart(itemId, partName, wear, engineName)
	clearBench()
	local wb = workspace:FindFirstChild("Workbench")
	local main = wb and wb:FindFirstChild("Main")
	if not main then return end

	local templateFolder = ReplicatedStorage:WaitForChild("EnginePartTemplates")
	local engineFolder = templateFolder:FindFirstChild(engineName)
	local template = engineFolder and engineFolder:FindFirstChild(partName)

	if template then
		local clone = template:Clone()
		clone.Name = "PartOnBench" -- CRITICAL: For Camera Distance

		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then d.Anchored = true; d.CanCollide = false end
		end

		clone.Parent = wb
		clone:PivotTo(CFrame.new(main.Position + Vector3.new(0, PART_Y_POS, 0)))
		partOnBench = clone

		-- Simple Billboard logic
		local gui = Instance.new("BillboardGui", playerGui)
		gui.Adornee = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
		gui.Size = UDim2.new(0, 200, 0, 100)
		gui.StudsOffset = Vector3.new(0, (clone:GetExtentsSize().Y/2) + UI_GAP_STUDS, 0)
		billboardGui = gui
		-- (Add your specific UI background/buttons here as per previous code)
	end
end

-- ── Listeners ────────────────────────────────────────────────────────────────
selectionChangedEvent.Event:Connect(function(itemId, partName, engineName)
	if not inWorkbenchView or not itemId then clearBench(); return end

	local wear = 100
	for _, item in ipairs(currentInventory) do
		if item.id == itemId then wear = item.wear; break end
	end
	spawnPart(itemId, partName, wear, engineName)
end)

workbenchViewChanged.Event:Connect(function(active)
	inWorkbenchView = active
	if not active then clearBench() end
end)

inventoryUpdated.OnClientEvent:Connect(function(inv) currentInventory = inv end)