--!strict
--[[
    RepairUI (LocalScript)
    ----------------------
    The workbench screen. While the player is in bench view
    (ClientSignals.WorkbenchViewChanged), selecting a part in the inventory puts a copy of
    it on the bench with two tilted panels beside it:

    Left panel — the two choices (rules from the shared RepairRules):
    - REPAIR   free, takes time, pays XP. Greyed out "TOO WORN" at or below
               the minimum condition, "ALREADY PERFECT" at 100%.
    - REPLACE  costs money (template's Price attribute, or the default),
               instant. Greyed out "ALREADY PERFECT" at 100%.
    Right panel — part name, condition (coloured by WearColors), a progress
    bar, and a message line for results and refusals ("NOT ENOUGH MONEY").

    The server (RepairService) decides everything; this only shows it:
    - RepairProgress  bar updates; -1 = stopped
    - RepairComplete  "REPAIRED" / "REPLACED"
    - RepairRefused   the reason, in words
    The part stays on the bench afterwards, now showing 100%.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared        = ReplicatedStorage:WaitForChild("Shared")
local Config        = Shared:WaitForChild("Config")
local RepairRules   = require(Config:WaitForChild("RepairRules"))
local WearColors    = require(Config:WaitForChild("WearColors"))
local Remotes       = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local ClientSignals = require(Shared:WaitForChild("Modules"):WaitForChild("ClientSignals"))
local Types         = require(Shared:WaitForChild("Modules"):WaitForChild("Types"))
local UITheme       = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))

local C, F = UITheme.Colors, UITheme.Fonts

-- ── Remotes & events ──────────────────────────────────────────────────────────

local inventoryUpdated  = Remotes.InventoryUpdated
local startRepairEvent  = Remotes.StartRepair
local cancelRepairEvent = Remotes.CancelRepair
local replacePartEvent  = Remotes.ReplacePart
local repairProgress    = Remotes.RepairProgress
local repairComplete    = Remotes.RepairComplete
local repairRefused     = Remotes.RepairRefused

-- ── Config ────────────────────────────────────────────────────────────────────

local PART_HEIGHT = 1.2 -- studs above the anchor; matches WorkbenchCameraController
local MOUNT_SIZE  = Vector3.new(3, 1.8, 0.1)
local CANVAS      = Vector2.new(450, 225)

-- ── State ─────────────────────────────────────────────────────────────────────

type Item = Types.InventoryItem

-- The part on the bench.
type Current = { itemId: string, name: string, engineName: string, price: number }

-- The built panels for the current part.
type Panels = {
	instances: { Instance },
	repairButton: TextButton,
	replaceButton: TextButton,
	info: TextLabel,
	fill: Frame,
	message: TextLabel,
}

local inBenchView                = false
local currentInventory: { Item } = {}
local current: Current?          = nil
local busy                       = false -- waiting on the server (repair running or request sent)
local ui: Panels?                = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getBench(): Instance?
	return workspace:FindFirstChild("Workbench")
end

local function getAnchor(wb: Instance?): BasePart?
	local anchor = wb and (wb:FindFirstChild("PartAnchor") or wb:FindFirstChild("Main"))
	return if anchor and anchor:IsA("BasePart") then anchor else nil
end

local function findItem(itemId: string?): Item?
	for _, item in ipairs(currentInventory) do
		if item.id == itemId then return item end
	end
	return nil
end

local function newLabel(parent: Instance, size: UDim2, position: UDim2, textSize: number): TextLabel
	local l                  = Instance.new("TextLabel")
	l.Size                   = size
	l.Position               = position
	l.BackgroundTransparency = 1
	l.Font                   = F.Bold
	l.TextColor3             = C.Text
	l.TextSize               = textSize
	l.Text                   = ""
	l.Parent                 = parent
	return l
end

local function newButton(parent: Instance, position: UDim2): TextButton
	local b            = Instance.new("TextButton")
	b.Size             = UDim2.new(0.84, 0, 0.4, 0)
	b.Position         = position
	b.Font             = F.Bold
	b.TextColor3       = C.Text
	b.TextSize         = 30
	b.AutoButtonColor  = true
	b.Parent           = parent
	UITheme.Corner(b, UITheme.Radius.Large)
	return b
end

-- ── Teardown ──────────────────────────────────────────────────────────────────

local function clearBench()
	if ui then
		for _, inst in ipairs(ui.instances) do
			inst:Destroy()
		end
		ui = nil
	end
	local wb = getBench()
	local old = wb and wb:FindFirstChild("PartOnBench")
	if old then old:Destroy() end
	current = nil
	busy    = false
end

-- ── Showing state ─────────────────────────────────────────────────────────────

local function setButton(button: TextButton, enabled: boolean, text: string, color: Color3)
	button.Text             = text
	button.Active           = enabled
	button.AutoButtonColor  = enabled
	button.BackgroundColor3 = enabled and color or C.Disabled
	button.TextTransparency = enabled and 0 or 0.35
end

local function showMessage(text: string?, color: Color3?)
	if not ui then return end
	ui.message.Text       = text or ""
	ui.message.TextColor3 = color or C.Text
end

-- Redraws everything from the part's current wear (from the inventory).
local function refresh()
	if not ui or not current then return end
	local item = findItem(current.itemId)
	if not item then
		showMessage("PART NOT IN INVENTORY", C.Danger)
		setButton(ui.repairButton, false, "REPAIR", C.Accent)
		setButton(ui.replaceButton, false, "REPLACE", C.Warning)
		return
	end

	local wear = tonumber(item.wear) or 0
	ui.info.Text = string.format("%s\nCONDITION: %d%%", current.name:upper(), math.floor(wear))
	ui.info.TextColor3 = WearColors.Gradient(wear)

	local options = RepairRules.GetOptions(wear)

	if busy then
		setButton(ui.repairButton, false, "...", C.Accent)
		setButton(ui.replaceButton, false, "...", C.Warning)
		return
	end

	if options.canRepair then
		setButton(ui.repairButton, true,
			string.format("REPAIR  ·  FREE  ·  %ds", math.ceil(RepairRules.GetRepairTime(wear))), C.Accent)
	else
		setButton(ui.repairButton, false, options.repairReason or options.reason or "REPAIR", C.Accent)
	end

	if options.canReplace then
		setButton(ui.replaceButton, true, string.format("REPLACE  ·  $%d", current.price), C.Warning)
	else
		setButton(ui.replaceButton, false, options.reason or "REPLACE", C.Warning)
	end
end

local function setProgress(fraction: number, instant: boolean?)
	if not ui then return end
	local size = UDim2.new(math.clamp(fraction, 0, 1), 0, 1, 0)
	if instant then
		ui.fill.Size = size
	else
		TweenService:Create(ui.fill, TweenInfo.new(0.1), { Size = size }):Play()
	end
end

-- ── Building the bench ────────────────────────────────────────────────────────

local function buildPanels(wb: Instance, anchor: BasePart): Panels
	local instances: { Instance } = {}

	local function mount(name: string, offset: CFrame): Part
		local p        = Instance.new("Part")
		p.Name         = name
		p.Size         = MOUNT_SIZE
		p.Transparency = 1
		p.CanCollide   = false
		p.CanQuery     = false
		p.Anchored     = true
		p.CFrame       = anchor.CFrame * offset
		p.Parent       = wb
		table.insert(instances, p)
		return p
	end

	local function surface(adornee: BasePart, name: string): SurfaceGui
		local sg       = Instance.new("SurfaceGui")
		sg.Name        = name
		sg.Adornee     = adornee
		sg.Face        = Enum.NormalId.Back
		sg.AlwaysOnTop = true
		sg.CanvasSize  = CANVAS
		sg.Parent      = playerGui -- in PlayerGui so its buttons can be clicked
		table.insert(instances, sg)
		return sg
	end

	local left  = surface(mount("LeftUiMount",  CFrame.new(-4.5, 1, -1) * CFrame.Angles(0, math.rad(25), 0)),  "LeftRepairSurface")
	local right = surface(mount("RightUiMount", CFrame.new(4.5, 1, -1)  * CFrame.Angles(0, math.rad(-25), 0)), "RightRepairSurface")

	-- Left: the two choices
	local repairButton  = newButton(left, UDim2.new(0.08, 0, 0.06, 0))
	local replaceButton = newButton(left, UDim2.new(0.08, 0, 0.54, 0))

	-- Right: name + condition, progress bar, message line
	local info = newLabel(right, UDim2.new(1, 0, 0.4, 0), UDim2.new(0, 0, 0.06, 0), 30)

	local track            = Instance.new("Frame")
	track.Size             = UDim2.new(0.8, 0, 0.12, 0)
	track.Position         = UDim2.new(0.1, 0, 0.55, 0)
	track.BackgroundColor3 = C.Track
	track.Parent           = right
	UITheme.Corner(track, UITheme.Radius.Large)

	local fill            = Instance.new("Frame")
	fill.Size             = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = C.Accent
	fill.Parent           = track
	UITheme.Corner(fill, UITheme.Radius.Large)

	local message = newLabel(right, UDim2.new(1, 0, 0.2, 0), UDim2.new(0, 0, 0.74, 0), 24)

	return {
		instances     = instances,
		repairButton  = repairButton,
		replaceButton = replaceButton,
		info          = info,
		fill          = fill,
		message       = message,
	}
end

local function showPartOnBench(item: Item)
	clearBench()

	local wb     = getBench()
	local anchor = getAnchor(wb)
	if not wb or not anchor then
		warn("[RepairUI] Workspace.Workbench needs a PartAnchor or Main part")
		return
	end

	local template = RepairRules.FindTemplate(item.engineName, item.name)
	if not template or not template:IsA("PVInstance") then
		warn("[RepairUI] No template for", item.engineName, item.name)
		return
	end

	-- Visual-only copy of the part, held on the anchor by the bench camera.
	local clone = template:Clone()
	clone.Name = "PartOnBench"
	clone:SetAttribute("Inspectable", nil)
	clone:SetAttribute("IsBolt", nil)
	for _, p in ipairs(clone:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored   = true
			p.CanCollide = false
		end
	end
	clone:PivotTo(anchor.CFrame * CFrame.new(0, PART_HEIGHT, 0))
	clone.Parent = wb

	current = {
		itemId     = item.id,
		name       = item.name,
		engineName = item.engineName,
		price      = RepairRules.GetReplacePrice(template),
	}
	local panels = buildPanels(wb, anchor)
	ui = panels
	local itemId = item.id -- these buttons are destroyed with this part

	panels.repairButton.MouseButton1Click:Connect(function()
		if busy or not panels.repairButton.Active then return end
		busy = true
		showMessage("")
		setProgress(0, true)
		refresh()
		startRepairEvent:FireServer(itemId)
	end)

	panels.replaceButton.MouseButton1Click:Connect(function()
		if busy or not panels.replaceButton.Active then return end
		busy = true
		showMessage("")
		refresh()
		replacePartEvent:FireServer(itemId)
	end)

	refresh()
end

-- ── Events ────────────────────────────────────────────────────────────────────

ClientSignals.PartSelected:Connect(function(itemId)
	if not inBenchView then return end
	if busy and current then
		cancelRepairEvent:FireServer()
	end
	local item = itemId and findItem(itemId)
	if item then
		showPartOnBench(item)
	else
		clearBench()
	end
end)

inventoryUpdated.OnClientEvent:Connect(function(inventory)
	currentInventory = inventory
	refresh()
end)

repairProgress.OnClientEvent:Connect(function(itemId, progress)
	if not current or (itemId ~= nil and itemId ~= current.itemId) then return end
	if type(progress) ~= "number" then return end
	if progress < 0 then
		busy = false
		setProgress(0, true)
		refresh()
	else
		setProgress(progress)
	end
end)

repairComplete.OnClientEvent:Connect(function(itemId, _, how)
	if not current or itemId ~= current.itemId then return end
	busy = false
	setProgress(1, true)
	showMessage(how == "replaced" and "REPLACED" or "REPAIRED", C.Accent)
	refresh()
end)

repairRefused.OnClientEvent:Connect(function(itemId, message)
	if not current or (itemId ~= nil and itemId ~= current.itemId) then return end
	busy = false
	showMessage(type(message) == "string" and message or "CAN'T DO THAT", C.Danger)
	refresh()
end)

ClientSignals.WorkbenchViewChanged:Connect(function(active)
	inBenchView = active
	if not active then
		if busy then cancelRepairEvent:FireServer() end
		clearBench()
	end
end)
