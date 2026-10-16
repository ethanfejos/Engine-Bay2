--!strict
--[[
    RepairUI (LocalScript)
    ----------------------
    The workbench screen. While the player is in bench view
    (ClientSignals.WorkbenchViewChanged), selecting a part in the inventory puts a copy of
    it on the bench, and a column on the left of the screen shows (UI
    "Option D"; flat on screen so nothing overlaps whatever the camera
    angle — the work order hides while you're at the bench):

    Top (PAPER, a manila part tag) — the part's name in marker, its
    engine, its condition, a progress bar, and a stamped message for
    results and refusals ("NOT ENOUGH MONEY").
    Under it (GLASS, your controls) — the two choices, as cards (rules
    from the shared RepairRules):
    - Repair   free, takes time, pays XP. Greyed out "TOO WORN" at or below
               the minimum condition, "ALREADY PERFECT" at 100%.
    - Replace  costs money (template's Price attribute, or the default),
               instant. Greyed out "ALREADY PERFECT" at 100%.
    Then "Q to leave the bench".

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
local camera    = workspace.CurrentCamera

local Shared        = ReplicatedStorage:WaitForChild("Shared")
local Config        = Shared:WaitForChild("Config")
local RepairRules   = require(Config:WaitForChild("RepairRules"))
local Remotes       = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local ClientSignals = require(Shared:WaitForChild("Modules"):WaitForChild("ClientSignals"))
local Types         = require(Shared:WaitForChild("Modules"):WaitForChild("Types"))
local UITheme       = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))

local C, FF = UITheme.Colors, UITheme.Faces

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
local COLUMN_W    = 320 -- the left-hand column
local COLUMN_X    = 24

-- ── State ─────────────────────────────────────────────────────────────────────

type Item = Types.InventoryItem

-- The part on the bench.
type Current = { itemId: string, name: string, engineName: string, price: number }

-- The built panels for the current part.
type Choice = { button: TextButton, title: TextLabel, sub: TextLabel, value: TextLabel, icon: Frame }

type Panels = {
	instances: { Instance },
	repair: Choice,
	replace: Choice,
	name: TextLabel,
	engine: TextLabel,
	cond: TextLabel,
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

-- A choice card (glass): icon tile, title + one line under it, and a value
-- on the right ("FREE", "$45").
local function newChoice(parent: Instance, order: number, title: string, accent: Color3): Choice
	local b                  = Instance.new("TextButton")
	b.Size                   = UDim2.new(1, 0, 0, 72)
	b.Text                   = ""
	b.AutoButtonColor        = false
	b.LayoutOrder            = order
	b.Parent                 = parent
	UITheme.Glass(b)
	local stroke = b:FindFirstChildOfClass("UIStroke")
	if stroke then stroke.Color, stroke.Transparency = accent, 0.5 end

	local icon                  = Instance.new("Frame")
	icon.AnchorPoint            = Vector2.new(0, 0.5)
	icon.Position               = UDim2.new(0, 14, 0.5, 0)
	icon.Size                   = UDim2.new(0, 42, 0, 42)
	icon.BackgroundColor3       = accent
	icon.BackgroundTransparency = 0.82
	icon.Parent                 = b
	UITheme.Corner(icon, UDim.new(0, 10))
	local letter = UITheme.Text(icon, string.sub(title, 1, 1), FF.Heavy, 22, accent)
	letter.Size = UDim2.fromScale(1, 1)
	letter.TextXAlignment = Enum.TextXAlignment.Center

	local t = UITheme.Text(b, title, FF.Heavy, 18, C.GlassText)
	t.Position = UDim2.new(0, 68, 0, 14)
	t.Size = UDim2.new(1, -150, 0, 22)
	local sub = UITheme.Text(b, "", FF.Body, 13, C.GlassMuted)
	sub.Position = UDim2.new(0, 68, 0, 38)
	sub.Size = UDim2.new(1, -82, 0, 18)
	sub.TextTruncate = Enum.TextTruncate.AtEnd

	local value = UITheme.Text(b, "", FF.MonoB, 16, accent)
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, -14, 0, 14)
	value.Size = UDim2.new(0, 80, 0, 22)
	value.TextXAlignment = Enum.TextXAlignment.Right

	return { button = b, title = t, sub = sub, value = value, icon = icon }
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

-- Sets a choice card: usable or greyed out, its line and its value.
local function setChoice(choice: Choice, enabled: boolean, sub: string, value: string)
	choice.button.Active = enabled
	choice.sub.Text      = sub
	choice.value.Text    = value
	local alpha = if enabled then 0 else 0.55
	choice.title.TextTransparency = alpha
	choice.sub.TextTransparency   = alpha
	choice.value.TextTransparency = alpha
	choice.icon.BackgroundTransparency = if enabled then 0.82 else 0.94
	choice.button.BackgroundTransparency = if enabled then UITheme.GLASS_ALPHA else 0.35
end

-- The stamp on the part tag: green for good news, red otherwise.
local function showMessage(text: string?, good: boolean?)
	if not ui then return end
	ui.message.Text = text or ""
	ui.message.Visible = (text or "") ~= ""
	local color = if good then C.MarkerGreen else C.TagInk
	ui.message.TextColor3 = color
	local stroke = ui.message:FindFirstChildOfClass("UIStroke")
	if stroke then stroke.Color = color end
end

-- Redraws everything from the part's current wear (from the inventory).
local function refresh()
	if not ui or not current then return end
	local item = findItem(current.itemId)
	if not item then
		showMessage("NOT IN YOUR INVENTORY")
		setChoice(ui.repair, false, "", "")
		setChoice(ui.replace, false, "", "")
		return
	end

	local wear = tonumber(item.wear) or 0
	ui.name.Text = current.name
	ui.engine.Text = current.engineName
	ui.cond.Text = string.format("%d%%", math.floor(wear))
	ui.cond.TextColor3 = if wear >= 70 then C.MarkerGreen elseif wear >= 35 then C.SheetInk else C.TagInk

	local options = RepairRules.GetOptions(wear)

	if busy then
		setChoice(ui.repair, false, "Working on it…", "")
		setChoice(ui.replace, false, "Working on it…", "")
		return
	end

	if options.canRepair then
		setChoice(ui.repair, true,
			string.format("Takes %ds · +%d XP", math.ceil(RepairRules.GetRepairTime(wear)), 25), "FREE")
	else
		setChoice(ui.repair, false, string.lower(options.repairReason or options.reason or "can't repair"), "")
	end

	if options.canReplace then
		setChoice(ui.replace, true, "Brand new part · instant", UITheme.Money(current.price))
	else
		setChoice(ui.replace, false, string.lower(options.reason or "can't replace"), "")
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

local function buildPanels(): Panels
	local screen          = Instance.new("ScreenGui")
	screen.Name           = "WorkbenchUI"
	screen.ResetOnSpawn   = false
	screen.Parent         = playerGui

	local column                  = Instance.new("Frame")
	column.AnchorPoint            = Vector2.new(0, 0.5)
	column.Position               = UDim2.new(0, COLUMN_X, 0.45, 0)
	column.Size                   = UDim2.new(0, COLUMN_W, 0, 0)
	column.AutomaticSize          = Enum.AutomaticSize.Y
	column.BackgroundTransparency = 1
	column.Parent                 = screen
	UITheme.List(column, 10)
	-- Shrink on short screens so it never runs into the money card.
	local fit = Instance.new("UIScale")
	fit.Parent = column
	local function refit()
		local unscaled = column.AbsoluteSize.Y / math.max(fit.Scale, 0.01)
		if unscaled > 0 then
			fit.Scale = math.clamp((camera.ViewportSize.Y - 260) / unscaled, 0.6, 1)
		end
	end
	column:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)

	-- The manila part tag (paper)
	local tag                  = Instance.new("Frame")
	tag.Size                   = UDim2.new(1, 0, 0, 0)
	tag.AutomaticSize          = Enum.AutomaticSize.Y
	tag.BackgroundColor3       = C.Tag
	tag.BorderSizePixel        = 0
	tag.LayoutOrder            = 1
	tag.Parent                 = column
	UITheme.Corner(tag, UDim.new(0, 12))
	UITheme.Pad(tag, 12, 16)
	UITheme.List(tag, 4)

	local head                  = Instance.new("Frame")
	head.Size                   = UDim2.new(1, 0, 0, 16)
	head.BackgroundTransparency = 1
	head.LayoutOrder            = 1
	head.Parent                 = tag
	UITheme.Text(head, "PART TAG", FF.Heavy, 11, C.SheetInk).Size = UDim2.fromScale(1, 1)
	local hole                  = Instance.new("Frame")
	hole.AnchorPoint            = Vector2.new(0.5, 0.5)
	hole.Position               = UDim2.new(0.5, 0, 0.5, 0)
	hole.Size                   = UDim2.new(0, 12, 0, 12)
	hole.BackgroundColor3       = C.Glass
	hole.Parent                 = head
	UITheme.Corner(hole, UITheme.Radius.Pill)
	UITheme.Stroke(hole, Color3.fromHex("A8895D"), 2)

	local name = UITheme.Text(tag, "", FF.Marker, 28, C.SheetInk)
	name.Size = UDim2.new(1, 0, 0, 34)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.LayoutOrder = 2

	local row                  = Instance.new("Frame")
	row.Size                   = UDim2.new(1, 0, 0, 32)
	row.BackgroundTransparency = 1
	row.LayoutOrder            = 3
	row.Parent                 = tag
	local engine = UITheme.Text(row, "", FF.Type, 14, C.SheetInk)
	engine.Size = UDim2.new(0.6, 0, 1, 0)
	engine.TextTruncate = Enum.TextTruncate.AtEnd
	local cond = UITheme.Text(row, "", FF.Type, 28, C.TagInk)
	cond.AnchorPoint = Vector2.new(1, 0)
	cond.Position = UDim2.new(1, 0, 0, 0)
	cond.Size = UDim2.new(0.4, 0, 1, 0)
	cond.TextXAlignment = Enum.TextXAlignment.Right

	local track                  = Instance.new("Frame")
	track.Size                   = UDim2.new(1, 0, 0, 12)
	track.BackgroundColor3       = C.Sheet
	track.BorderSizePixel        = 0
	track.LayoutOrder            = 4
	track.Parent                 = tag
	UITheme.Stroke(track, C.SheetInk, 2)
	local fill            = Instance.new("Frame")
	fill.Size             = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = C.MarkerGreen
	fill.BorderSizePixel  = 0
	fill.Parent           = track

	local stampRow                  = Instance.new("Frame")
	stampRow.Size                   = UDim2.new(1, 0, 0, 30)
	stampRow.BackgroundTransparency = 1
	stampRow.LayoutOrder            = 5
	stampRow.Parent                 = tag
	local message = UITheme.Text(stampRow, "", FF.Type, 14, C.TagInk)
	message.AnchorPoint = Vector2.new(0.5, 0.5)
	message.Position = UDim2.new(0.5, 0, 0.5, 2)
	message.Size = UDim2.new(0, 0, 0, 22)
	message.AutomaticSize = Enum.AutomaticSize.X
	message.TextXAlignment = Enum.TextXAlignment.Center
	message.Rotation = -2
	message.Visible = false
	UITheme.Pad(message, 0, 8)
	UITheme.Stroke(message, C.TagInk, 2)

	-- The choices (glass)
	local repair  = newChoice(column, 2, "Repair", C.Done)
	local replace = newChoice(column, 3, "Replace", C.Amber)

	local hint = UITheme.Text(column, "Q to leave the bench", FF.Body, 13, C.GlassMuted)
	hint.LayoutOrder = 4
	hint.TextStrokeTransparency = 0.6
	hint.TextStrokeColor3 = C.Glass

	return {
		instances = { screen },
		repair    = repair,
		replace   = replace,
		name      = name,
		engine    = engine,
		cond      = cond,
		fill      = fill,
		message   = message,
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
	local panels = buildPanels()
	ui = panels
	local itemId = item.id -- these buttons are destroyed with this part

	panels.repair.button.MouseButton1Click:Connect(function()
		if busy or not panels.repair.button.Active then return end
		busy = true
		showMessage("")
		setProgress(0, true)
		refresh()
		startRepairEvent:FireServer(itemId)
	end)

	panels.replace.button.MouseButton1Click:Connect(function()
		if busy or not panels.replace.button.Active then return end
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
	showMessage(how == "replaced" and "REPLACED" or "REPAIRED", true)
	refresh()
end)

repairRefused.OnClientEvent:Connect(function(itemId, message)
	if not current or (itemId ~= nil and itemId ~= current.itemId) then return end
	busy = false
	showMessage(type(message) == "string" and message or "CAN'T DO THAT")
	refresh()
end)

ClientSignals.WorkbenchViewChanged:Connect(function(active)
	inBenchView = active
	if not active then
		if busy then cancelRepairEvent:FireServer() end
		clearBench()
	end
end)
