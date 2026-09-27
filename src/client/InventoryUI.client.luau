--[[
    InventoryUI (LocalScript)
    -------------------------
    Changes from previous version:
    - Search/filter bar filters as you type
    - Sort dropdown (Name, Wear Asc, Wear Desc, Engine)
    - Part count badge above toggle button when panel is closed
    - All previous features retained

    Place in: StarterPlayerScripts
]]

local Players              = game:GetService("Players")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local UserInputService     = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService         = game:GetService("TweenService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Remotes ───────────────────────────────────────────────────────────────────

local remoteFolder     = ReplicatedStorage:WaitForChild("RemoteEvents")
local inventoryUpdated = remoteFolder:WaitForChild("InventoryUpdated")
local requestInventory = remoteFolder:WaitForChild("RequestInventory")
local clearInventory   = remoteFolder:WaitForChild("ClearInventory")

-- ── Bindables ─────────────────────────────────────────────────────────────────

local function getOrCreateBindable(name)
	local e = ReplicatedStorage:FindFirstChild(name)
	if e then return e end
	local b  = Instance.new("BindableEvent")
	b.Name   = name
	b.Parent = ReplicatedStorage
	return b
end

local selectionChangedEvent = getOrCreateBindable("GhostSelectionChanged")
local removeFromListEvent   = getOrCreateBindable("GhostRemoveFromList")

-- ── Palette ───────────────────────────────────────────────────────────────────

local WHITE  = Color3.fromRGB(255, 255, 255)
local GREEN  = Color3.fromRGB(0,   200, 120)
local WORN   = Color3.fromRGB(255, 200, 0)
local FAIL   = Color3.fromRGB(255, 50,  50)
local DIM    = Color3.fromRGB(160, 160, 160)

local function getWearColor(wear)
	if wear >= 60 then return GREEN end
	if wear >= 30 then return WORN  end
	return FAIL
end

-- ── Config ────────────────────────────────────────────────────────────────────

local PANEL_W     = 200
local PANEL_H     = 340
local MARGIN      = 20
local TWEEN_INFO  = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TOGGLE_W    = 18
local TOGGLE_H    = 36

-- Sort modes
local SORT_MODES  = { "Name", "Wear ↑", "Wear ↓", "Engine" }
local sortIndex   = 1

-- ── State ─────────────────────────────────────────────────────────────────────

local currentInventory = {}
local selectedId       = nil
local selectedPartName = nil
local selectedEngine   = nil
local rowEntries       = {}
local panelOpen        = true
local searchText       = ""
local dropdownOpen     = false

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function corner(parent, radius)
	local c           = Instance.new("UICorner")
	c.CornerRadius    = radius or UDim.new(0, 4)
	c.Parent          = parent
end

local function makeDivider(parent, yPos, padX)
	padX = padX or 0
	local d                  = Instance.new("Frame")
	d.Size                   = UDim2.new(1, -padX * 2, 0, 1)
	d.Position               = UDim2.new(0, padX, 0, yPos)
	d.BackgroundColor3       = WHITE
	d.BackgroundTransparency = 0.7
	d.BorderSizePixel        = 0
	d.Parent                 = parent
	return d
end

local function makeText(name, text, size, color, xAlign, bold, parent)
	local l                  = Instance.new("TextLabel")
	l.Name                   = name
	l.Text                   = text
	l.TextSize               = size
	l.TextColor3             = color
	l.Font                   = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.BackgroundTransparency = 1
	l.TextXAlignment         = xAlign or Enum.TextXAlignment.Left
	l.TextYAlignment         = Enum.TextYAlignment.Center
	l.Size                   = UDim2.new(1, 0, 1, 0)
	l.Parent                 = parent
	return l
end

-- ── Sort & Filter ─────────────────────────────────────────────────────────────

local function sortInventory(inventory)
	local sorted = {}
	for _, v in ipairs(inventory) do table.insert(sorted, v) end

	local mode = SORT_MODES[sortIndex]
	if mode == "Name" then
		table.sort(sorted, function(a, b) return a.name < b.name end)
	elseif mode == "Wear ↑" then
		table.sort(sorted, function(a, b) return a.wear < b.wear end)
	elseif mode == "Wear ↓" then
		table.sort(sorted, function(a, b) return a.wear > b.wear end)
	elseif mode == "Engine" then
		table.sort(sorted, function(a, b) return a.engineName < b.engineName end)
	end
	return sorted
end

local function filterInventory(inventory)
	if searchText == "" then return inventory end
	local filtered = {}
	local lower    = searchText:lower()
	for _, item in ipairs(inventory) do
		if item.name:lower():find(lower, 1, true) then
			table.insert(filtered, item)
		end
	end
	return filtered
end

-- ── Screen ────────────────────────────────────────────────────────────────────

local screen              = Instance.new("ScreenGui")
screen.Name               = "InventoryUI"
screen.ResetOnSpawn       = false
screen.IgnoreGuiInset     = true
screen.Parent             = playerGui

local root                = Instance.new("Frame")
root.Name                 = "Root"
root.Size                 = UDim2.new(0, PANEL_W + TOGGLE_W, 0, PANEL_H)
root.Position             = UDim2.new(1, -(PANEL_W + TOGGLE_W + MARGIN), 0.5, -PANEL_H / 2)
root.BackgroundTransparency = 1
root.BorderSizePixel      = 0
root.Parent               = screen

-- ── Toggle Button ─────────────────────────────────────────────────────────────

local toggleBtn               = Instance.new("TextButton")
toggleBtn.Size                = UDim2.new(0, TOGGLE_W, 0, TOGGLE_H)
toggleBtn.Position            = UDim2.new(0, 0, 0.5, -TOGGLE_H / 2)
toggleBtn.BackgroundColor3    = WHITE
toggleBtn.BackgroundTransparency = 0.88
toggleBtn.BorderSizePixel     = 0
toggleBtn.Text                = ""
toggleBtn.AutoButtonColor     = false
toggleBtn.Parent              = root
corner(toggleBtn, UDim.new(0, 4))

local arrowLabel              = Instance.new("TextLabel")
arrowLabel.Size               = UDim2.new(1, 0, 1, 0)
arrowLabel.BackgroundTransparency = 1
arrowLabel.Text               = "▶"
arrowLabel.TextColor3         = WHITE
arrowLabel.TextSize           = 9
arrowLabel.Font               = Enum.Font.GothamBold
arrowLabel.TextXAlignment     = Enum.TextXAlignment.Center
arrowLabel.TextYAlignment     = Enum.TextYAlignment.Center
arrowLabel.Parent             = toggleBtn

-- Part count badge above toggle
local badge                   = Instance.new("Frame")
badge.Name                    = "Badge"
badge.Size                    = UDim2.new(0, TOGGLE_W, 0, 18)
badge.Position                = UDim2.new(0, 0, 0.5, -(TOGGLE_H / 2) - 22)
badge.BackgroundColor3        = FAIL
badge.BackgroundTransparency  = 0.2
badge.BorderSizePixel         = 0
badge.Visible                 = false
badge.Parent                  = root
corner(badge, UDim.new(0, 4))

local badgeLabel              = Instance.new("TextLabel")
badgeLabel.Size               = UDim2.new(1, 0, 1, 0)
badgeLabel.BackgroundTransparency = 1
badgeLabel.Font               = Enum.Font.GothamBold
badgeLabel.Text               = "0"
badgeLabel.TextColor3         = WHITE
badgeLabel.TextSize           = 10
badgeLabel.TextXAlignment     = Enum.TextXAlignment.Center
badgeLabel.TextYAlignment     = Enum.TextYAlignment.Center
badgeLabel.Parent             = badge

-- ── Panel ─────────────────────────────────────────────────────────────────────

local panel                   = Instance.new("Frame")
panel.Name                    = "Panel"
panel.Size                    = UDim2.new(0, PANEL_W, 1, 0)
panel.Position                = UDim2.new(0, TOGGLE_W, 0, 0)
panel.BackgroundTransparency  = 1
panel.BorderSizePixel         = 0
panel.Parent                  = root

-- Title
local titleRow                = Instance.new("Frame")
titleRow.Size                 = UDim2.new(1, -16, 0, 26)
titleRow.Position             = UDim2.new(0, 8, 0, 6)
titleRow.BackgroundTransparency = 1
titleRow.Parent               = panel

local titleLabel = makeText("T", "PARTS INVENTORY", 13, WHITE,
	Enum.TextXAlignment.Left, true, titleRow)
titleLabel.Size  = UDim2.new(1, 0, 1, 0)

makeDivider(panel, 34, 8)

-- ── Search Bar ────────────────────────────────────────────────────────────────

local searchRow               = Instance.new("Frame")
searchRow.Size                = UDim2.new(1, -16, 0, 20)
searchRow.Position            = UDim2.new(0, 8, 0, 40)
searchRow.BackgroundTransparency = 1
searchRow.Parent              = panel

local searchBox               = Instance.new("TextBox")
searchBox.Name                = "SearchBox"
searchBox.Size                = UDim2.new(1, 0, 1, 0)
searchBox.BackgroundColor3    = WHITE
searchBox.BackgroundTransparency = 0.92
searchBox.BorderSizePixel     = 0
searchBox.Font                = Enum.Font.Gotham
searchBox.PlaceholderText     = "Search parts..."
searchBox.PlaceholderColor3   = DIM
searchBox.Text                = ""
searchBox.TextColor3          = WHITE
searchBox.TextSize            = 11
searchBox.ClearTextOnFocus    = false
searchBox.Parent              = searchRow
corner(searchBox, UDim.new(0, 4))

local searchPad               = Instance.new("UIPadding")
searchPad.PaddingLeft         = UDim.new(0, 6)
searchPad.Parent              = searchBox

-- ── Sort Dropdown ─────────────────────────────────────────────────────────────

local sortRow                 = Instance.new("Frame")
sortRow.Size                  = UDim2.new(1, -16, 0, 18)
sortRow.Position              = UDim2.new(0, 8, 0, 64)
sortRow.BackgroundTransparency = 1
sortRow.Parent                = panel

local sortLabel               = makeText("SL", "SORT:", 10, DIM,
	Enum.TextXAlignment.Left, false, sortRow)
sortLabel.Size                = UDim2.new(0.35, 0, 1, 0)

local sortBtn                 = Instance.new("TextButton")
sortBtn.Size                  = UDim2.new(0.65, 0, 1, 0)
sortBtn.Position              = UDim2.new(0.35, 0, 0, 0)
sortBtn.BackgroundColor3      = WHITE
sortBtn.BackgroundTransparency = 0.92
sortBtn.BorderSizePixel       = 0
sortBtn.Font                  = Enum.Font.GothamBold
sortBtn.Text                  = SORT_MODES[sortIndex] .. " ▾"
sortBtn.TextColor3            = WHITE
sortBtn.TextSize              = 10
sortBtn.AutoButtonColor       = false
sortBtn.Parent                = sortRow
corner(sortBtn, UDim.new(0, 4))

-- Dropdown menu
local dropFrame               = Instance.new("Frame")
dropFrame.Name                = "Dropdown"
dropFrame.Size                = UDim2.new(0.65, 0, 0, #SORT_MODES * 18)
dropFrame.Position            = UDim2.new(0.35, 0, 1, 2)
dropFrame.BackgroundColor3    = Color3.fromRGB(20, 20, 20)
dropFrame.BackgroundTransparency = 0.1
dropFrame.BorderSizePixel     = 0
dropFrame.Visible             = false
dropFrame.ZIndex              = 10
dropFrame.Parent              = sortRow
corner(dropFrame, UDim.new(0, 4))

local dropLayout              = Instance.new("UIListLayout")
dropLayout.FillDirection      = Enum.FillDirection.Vertical
dropLayout.SortOrder          = Enum.SortOrder.LayoutOrder
dropLayout.Parent             = dropFrame

local dropButtons = {}
for i, mode in ipairs(SORT_MODES) do
	local db                  = Instance.new("TextButton")
	db.Size                   = UDim2.new(1, 0, 0, 18)
	db.BackgroundTransparency = 1
	db.Font                   = Enum.Font.Gotham
	db.Text                   = mode
	db.TextColor3             = WHITE
	db.TextSize               = 10
	db.LayoutOrder            = i
	db.ZIndex                 = 11
	db.Parent                 = dropFrame
	dropButtons[i]            = db
end

makeDivider(panel, 86, 8)

-- Column headers
local colRow                  = Instance.new("Frame")
colRow.Size                   = UDim2.new(1, -16, 0, 14)
colRow.Position               = UDim2.new(0, 8, 0, 90)
colRow.BackgroundTransparency = 1
colRow.Parent                 = panel

local hPart                   = makeText("HP", "PART", 10, WHITE,
	Enum.TextXAlignment.Left, true, colRow)
hPart.Size                    = UDim2.new(0.6, 0, 1, 0)

local hWear                   = makeText("HW", "WEAR", 10, WHITE,
	Enum.TextXAlignment.Center, true, colRow)
hWear.Size                    = UDim2.new(0.2, 0, 1, 0)
hWear.Position                = UDim2.new(0.6, 0, 0, 0)

local hEng                    = makeText("HE", "ENG", 10, WHITE,
	Enum.TextXAlignment.Center, true, colRow)
hEng.Size                     = UDim2.new(0.2, 0, 1, 0)
hEng.Position                 = UDim2.new(0.8, 0, 0, 0)

makeDivider(panel, 106, 8)

-- Clear all button
local clearBtn                = Instance.new("TextButton")
clearBtn.Size                 = UDim2.new(1, -16, 0, 16)
clearBtn.Position             = UDim2.new(0, 8, 0, 110)
clearBtn.BackgroundColor3     = FAIL
clearBtn.BackgroundTransparency = 0.6
clearBtn.BorderSizePixel      = 0
clearBtn.Font                 = Enum.Font.GothamBold
clearBtn.Text                 = "CLEAR INVENTORY"
clearBtn.TextColor3           = WHITE
clearBtn.TextSize             = 10
clearBtn.AutoButtonColor      = false
clearBtn.Parent               = panel
corner(clearBtn, UDim.new(0, 4))

makeDivider(panel, 130, 8)

-- Scroll (shifted down to make room for clear button)
local scroll                  = Instance.new("ScrollingFrame")
scroll.Size                   = UDim2.new(1, -16, 1, -138)
scroll.Position               = UDim2.new(0, 8, 0, 134)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel        = 0
scroll.ScrollBarThickness     = 2
scroll.ScrollBarImageColor3   = WHITE
scroll.CanvasSize             = UDim2.new(0, 0, 0, 0)
scroll.Parent                 = panel

local layout                  = Instance.new("UIListLayout")
layout.FillDirection          = Enum.FillDirection.Vertical
layout.Padding                = UDim.new(0, 2)
layout.SortOrder              = Enum.SortOrder.LayoutOrder
layout.Parent                 = scroll

layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
	scroll.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y)
end)

local emptyLabel              = makeText("Empty", "No parts removed", 11, DIM,
	Enum.TextXAlignment.Center, false, scroll)
emptyLabel.Size               = UDim2.new(1, 0, 0, 30)

-- ── Scroll Sink ───────────────────────────────────────────────────────────────

panel.MouseEnter:Connect(function()
	ContextActionService:BindAction("SinkInvScroll", function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.UserInputType.MouseWheel)
end)
panel.MouseLeave:Connect(function()
	ContextActionService:UnbindAction("SinkInvScroll")
end)

-- ── Selection ─────────────────────────────────────────────────────────────────

local function setSelected(itemId, partName, engineName, relativeData)
	selectedId       = itemId
	selectedPartName = partName
	selectedEngine   = engineName

	for _, entry in ipairs(rowEntries) do
		local isSel = entry.itemId == itemId and itemId ~= nil
		entry.nameLabel.TextColor3 = isSel and GREEN or WHITE
		entry.nameLabel.Font       = isSel and Enum.Font.GothamBold or Enum.Font.Gotham
		entry.indicator.BackgroundTransparency = isSel and 0 or 1
	end

	selectionChangedEvent:Fire(itemId, partName, engineName, relativeData)
end

-- ── Populate ──────────────────────────────────────────────────────────────────

local function populateList()
	for _, entry in ipairs(rowEntries) do
		entry.frame:Destroy()
	end
	rowEntries = {}

	local filtered = filterInventory(currentInventory)
	local sorted   = sortInventory(filtered)

	emptyLabel.Visible = #sorted == 0

	-- Update badge
	local count        = #currentInventory
	badgeLabel.Text    = tostring(count)
	badge.Visible      = not panelOpen and count > 0

	for i, item in ipairs(sorted) do
		local wearColor = getWearColor(item.wear)
		local isSel     = item.id == selectedId

		local row                    = Instance.new("Frame")
		row.Name                     = "Row_" .. item.id
		row.Size                     = UDim2.new(1, 0, 0, 20)
		row.BackgroundTransparency   = 1
		row.BorderSizePixel          = 0
		row.LayoutOrder              = i
		row.Parent                   = scroll

		local indicator              = Instance.new("Frame")
		indicator.Name               = "Indicator"
		indicator.Size               = UDim2.new(0, 2, 0.7, 0)
		indicator.Position           = UDim2.new(0, 0, 0.15, 0)
		indicator.BackgroundColor3   = GREEN
		indicator.BackgroundTransparency = isSel and 0 or 1
		indicator.BorderSizePixel    = 0
		indicator.Parent             = row
		corner(indicator, UDim.new(1, 0))

		local nameLabel              = Instance.new("TextLabel")
		nameLabel.Name               = "NameLabel"
		nameLabel.Size               = UDim2.new(0.6, 0, 1, 0)
		nameLabel.Position           = UDim2.new(0, 6, 0, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font               = isSel and Enum.Font.GothamBold or Enum.Font.Gotham
		nameLabel.Text               = item.name
		nameLabel.TextColor3         = isSel and GREEN or WHITE
		nameLabel.TextSize           = 11
		nameLabel.TextXAlignment     = Enum.TextXAlignment.Left
		nameLabel.TextYAlignment     = Enum.TextYAlignment.Center
		nameLabel.TextTruncate       = Enum.TextTruncate.AtEnd
		nameLabel.Parent             = row

		local wearLabel              = Instance.new("TextLabel")
		wearLabel.Name               = "WearLabel"
		wearLabel.Size               = UDim2.new(0.2, 0, 1, 0)
		wearLabel.Position           = UDim2.new(0.6, 0, 0, 0)
		wearLabel.BackgroundTransparency = 1
		wearLabel.Font               = Enum.Font.RobotoMono
		wearLabel.Text               = math.floor(item.wear) .. "%"
		wearLabel.TextColor3         = wearColor
		wearLabel.TextSize           = 11
		wearLabel.TextXAlignment     = Enum.TextXAlignment.Center
		wearLabel.TextYAlignment     = Enum.TextYAlignment.Center
		wearLabel.Parent             = row

		local engLabel               = Instance.new("TextLabel")
		engLabel.Name                = "EngLabel"
		engLabel.Size                = UDim2.new(0.2, 0, 1, 0)
		engLabel.Position            = UDim2.new(0.8, 0, 0, 0)
		engLabel.BackgroundTransparency = 1
		engLabel.Font                = Enum.Font.Gotham
		engLabel.Text                = item.engineName:sub(1, 4):upper()
		engLabel.TextColor3          = DIM
		engLabel.TextSize            = 10
		engLabel.TextXAlignment      = Enum.TextXAlignment.Center
		engLabel.TextYAlignment      = Enum.TextYAlignment.Center
		engLabel.Parent              = row

		local btn                    = Instance.new("TextButton")
		btn.Size                     = UDim2.new(1, 0, 1, 0)
		btn.BackgroundTransparency   = 1
		btn.Text                     = ""
		btn.ZIndex                   = 2
		btn.Parent                   = row

		local capturedItem = item
		btn.MouseButton1Click:Connect(function()
			if selectedId == capturedItem.id then
				setSelected(nil, nil, nil, nil)
			else
				setSelected(capturedItem.id, capturedItem.name,
					capturedItem.engineName, capturedItem.relativeData)
			end
		end)

		rowEntries[i] = {
			frame     = row,
			nameLabel = nameLabel,
			indicator = indicator,
			itemId    = item.id,
		}
	end
end

-- ── Sort Dropdown Logic ───────────────────────────────────────────────────────

sortBtn.MouseButton1Click:Connect(function()
	dropdownOpen = not dropdownOpen
	dropFrame.Visible = dropdownOpen
end)

for i, db in ipairs(dropButtons) do
	db.MouseButton1Click:Connect(function()
		sortIndex         = i
		sortBtn.Text      = SORT_MODES[sortIndex] .. " ▾"
		dropdownOpen      = false
		dropFrame.Visible = false
		populateList()
	end)
end

-- Close dropdown when clicking elsewhere
local dropHovered = false
dropFrame.MouseEnter:Connect(function() dropHovered = true end)
dropFrame.MouseLeave:Connect(function() dropHovered = false end)

UserInputService.InputBegan:Connect(function(input, processed)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if dropdownOpen and not dropHovered then
			dropdownOpen      = false
			dropFrame.Visible = false
		end
	end
end)

-- ── Search Logic ──────────────────────────────────────────────────────────────

searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	searchText = searchBox.Text
	populateList()
end)

-- ── Panel Toggle ──────────────────────────────────────────────────────────────

local function setPanelOpen(open)
	panelOpen = open
	badge.Visible = not open and #currentInventory > 0
	local targetX = open
		and -(PANEL_W + TOGGLE_W + MARGIN)
		or  -TOGGLE_W
	arrowLabel.Text = open and "▶" or "◀"
	TweenService:Create(root, TWEEN_INFO, {
		Position = UDim2.new(1, targetX, 0.5, -PANEL_H / 2)
	}):Play()
end

toggleBtn.MouseButton1Click:Connect(function()
	setPanelOpen(not panelOpen)
end)

-- ── Clear Button ──────────────────────────────────────────────────────────────

clearBtn.MouseButton1Click:Connect(function()
	clearInventory:FireServer()
	setSelected(nil, nil, nil, nil)
end)

-- ── Events ────────────────────────────────────────────────────────────────────

inventoryUpdated.OnClientEvent:Connect(function(inventory)
	currentInventory = inventory
	populateList()
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Escape then
		setSelected(nil, nil, nil, nil)
	end
end)

removeFromListEvent.Event:Connect(function(itemId)
	for i, item in ipairs(currentInventory) do
		if item.id == itemId then
			table.remove(currentInventory, i)
			break
		end
	end
	populateList()
	setSelected(nil, nil, nil, nil)
end)

requestInventory:FireServer()