--!strict
--[[
    InventoryUI (LocalScript)
    -------------------------
    The parts inventory panel on the right of the screen (UI "Option D":
    glass — it's your HUD).

    Each row shows:
    - the part name, and under it the engine it came from plus a status:
        FITS HERE        can be reinstalled in your car, in your bay, now
        NEEDS REPLACING  too worn to repair (RepairRules)
        PERFECT          100% condition
    - its condition %, coloured with the same WearColors scale as the
      highlights, billboards and workbench

    Clicking a row selects it (click again or press Escape to deselect).
    Selection is sent on ClientSignals.PartSelected, which GhostSystem
    (reinstall ghost) and RepairUI (workbench) listen to. If the
    selected part leaves the inventory, the selection is cleared.

    Also: search as you type, a sort menu (Name, Condition low/high, Engine),
    a count badge when the panel is closed, and CLEAR INVENTORY (a testing
    tool — needs a second click within a few seconds to confirm).

    Rows are created once per part and updated in place, so typing in the
    search box or receiving an update doesn't rebuild the whole list.
    The panel scales up on large/high-resolution screens (UIScale).
]]

local Players              = game:GetService("Players")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local UserInputService     = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService         = game:GetService("TweenService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera    = workspace.CurrentCamera

local Shared        = ReplicatedStorage:WaitForChild("Shared")
local WearColors    = require(Shared:WaitForChild("Config"):WaitForChild("WearColors"))
local RepairRules   = require(Shared:WaitForChild("Config"):WaitForChild("RepairRules"))
local PartRules     = require(Shared:WaitForChild("Modules"):WaitForChild("PartRules"))
local ZoneUtils     = require(Shared:WaitForChild("Modules"):WaitForChild("ZoneUtils"))
local Remotes       = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local ClientSignals = require(Shared:WaitForChild("Modules"):WaitForChild("ClientSignals"))
local Types         = require(Shared:WaitForChild("Modules"):WaitForChild("Types"))
local CarUtils      = require(Shared:WaitForChild("Modules"):WaitForChild("CarUtils"))
local UITheme       = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))

local C, FF = UITheme.Colors, UITheme.Faces

-- ── Remotes & events ──────────────────────────────────────────────────────────

local inventoryUpdated = Remotes.InventoryUpdated
local requestInventory = Remotes.RequestInventory
local clearInventory   = Remotes.ClearInventory

-- ── Look ──────────────────────────────────────────────────────────────────────

local PANEL_W    = 260
local PANEL_MAX  = 560  -- tallest the panel gets; past that the list scrolls
local TOP        = 64   -- px from the top of the screen (clears Roblox's top bar)
local MARGIN     = 20
local TOGGLE_W   = 22
local TOGGLE_H   = 44
local ROW_H      = 46
local LIST_TOP   = 98   -- where the parts list starts
local SORT_W     = 104  -- the sort button, beside the search box
local CLEAR_H    = 30   -- the CLEAR INVENTORY button at the bottom
local TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- The layout is designed at 1080p and scaled up (never down) on taller screens.
local DESIGN_HEIGHT = 1080
local MAX_SCALE     = 2

local CLEAR_CONFIRM_TIME = 3      -- seconds the "click again" state lasts
local STATUS_REFRESH     = 0.5    -- seconds between "fits here" re-checks

local SORT_MODES = {
	{ label = "Name",        key = "name" },
	{ label = "Worst first", key = "wearAsc" },
	{ label = "Best first",  key = "wearDesc" },
	{ label = "Engine",      key = "engine" },
}

-- ── State ─────────────────────────────────────────────────────────────────────

type Item = Types.InventoryItem
type Row = { frame: Frame, stroke: UIStroke, name: TextLabel, detail: TextLabel, cond: TextLabel, bar: Frame }

local inventory: { Item }        = {}    -- latest list from the server
local rows: { [string]: Row }    = {}    -- [itemId] = row entry (see makeRow)
local selectedId: string?        = nil
local panelOpen    = true
local searchText   = ""
local sortIndex    = 1
local dropdownOpen = false
local clearArmedAt: number? = nil   -- os.clock() when CLEAR was first clicked

-- ── Small builders ────────────────────────────────────────────────────────────

local function text(name: string, value: string, size: number, color: Color3,
	xAlign: Enum.TextXAlignment?, bold: boolean, parent: Instance): TextLabel
	local l                  = Instance.new("TextLabel")
	l.Name                   = name
	l.Text                   = value
	l.TextSize               = size
	l.TextColor3             = color
	l.FontFace               = bold and FF.Bold or FF.Body
	l.BackgroundTransparency = 1
	l.TextXAlignment         = xAlign or Enum.TextXAlignment.Left
	l.TextYAlignment         = Enum.TextYAlignment.Center
	l.TextTruncate           = Enum.TextTruncate.AtEnd
	l.Size                   = UDim2.new(1, 0, 1, 0)
	l.Parent                 = parent
	return l
end

local function divider(parent: Instance, y: number): Frame
	local d                  = Instance.new("Frame")
	d.Size                   = UDim2.new(1, 0, 0, 1)
	d.Position               = UDim2.new(0, 0, 0, y)
	d.BackgroundColor3       = C.Text
	d.BackgroundTransparency = 0.94
	d.BorderSizePixel        = 0
	d.Parent                 = parent
	return d
end

local function flatButton(label: string, parent: Instance): TextButton
	local b                  = Instance.new("TextButton")
	b.BackgroundColor3       = C.Text
	b.BackgroundTransparency = 0.95
	b.BorderSizePixel        = 0
	b.FontFace               = FF.Bold
	b.Text                   = label
	b.TextColor3             = C.GlassText
	b.TextSize               = 12
	b.AutoButtonColor        = false
	b.Parent                 = parent
	UITheme.Corner(b, UDim.new(0, 8))
	UITheme.Stroke(b, Color3.new(1, 1, 1), 1, 0.92)
	return b
end

-- ── Screen & panel ────────────────────────────────────────────────────────────

local screen          = Instance.new("ScreenGui")
screen.Name           = "InventoryUI"
screen.ResetOnSpawn   = false
screen.IgnoreGuiInset = true
screen.Parent         = playerGui

local uiScale = Instance.new("UIScale") -- parented to root below

local root -- created below; declared here so updateScale can re-place it

local function updateScale()
	uiScale.Scale = math.clamp(camera.ViewportSize.Y / DESIGN_HEIGHT, 1, MAX_SCALE)
	-- When closed, the hidden distance depends on the scale, so re-place it.
	if root and not panelOpen then
		root.Position = UDim2.new(1, PANEL_W * uiScale.Scale, 0, TOP)
	end
end
camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
updateScale()

-- Root sits on the right edge near the top and grows downwards with the
-- parts list (resizePanel). AnchorPoint (1, 0) keeps it in place whatever
-- UIScale does to its size.
root                        = Instance.new("Frame")
root.Name                   = "Root"
root.AnchorPoint            = Vector2.new(1, 0)
root.Size                   = UDim2.new(0, PANEL_W + TOGGLE_W, 0, 200)
root.Position               = UDim2.new(1, -MARGIN, 0, TOP)
root.BackgroundTransparency = 1
root.Parent                 = screen
uiScale.Parent              = root -- scales the panel around its top-right anchor

local toggleBtn    = flatButton("", root)
toggleBtn.Size     = UDim2.new(0, TOGGLE_W, 0, TOGGLE_H)
toggleBtn.Position = UDim2.new(0, 0, 0, 12)
toggleBtn.BackgroundColor3       = C.Glass
toggleBtn.BackgroundTransparency = UITheme.GLASS_ALPHA

local arrowLabel = text("Arrow", "▶", 10, C.GlassMuted, Enum.TextXAlignment.Center, true, toggleBtn)

local badge                  = Instance.new("Frame")
badge.Size                   = UDim2.new(0, TOGGLE_W, 0, 20)
badge.Position               = UDim2.new(0, 0, 0, 12 + TOGGLE_H + 6)
badge.BackgroundColor3       = C.Amber
badge.BorderSizePixel        = 0
badge.Visible                = false
badge.Parent                 = root
UITheme.Corner(badge, UITheme.Radius.Pill)
local badgeLabel = text("Count", "0", 11, C.Glass, Enum.TextXAlignment.Center, true, badge)
badgeLabel.FontFace = FF.MonoB

-- The glass card (6px gap after the toggle tab)
local panel                  = Instance.new("Frame")
panel.Name                   = "Panel"
panel.Size                   = UDim2.new(0, PANEL_W - 6, 1, 0)
panel.Position               = UDim2.new(0, TOGGLE_W + 6, 0, 0)
panel.Parent                 = root
UITheme.Glass(panel)

-- Title: "Parts" and a count pill
local titleRow                  = Instance.new("Frame")
titleRow.Size                   = UDim2.new(1, -28, 0, 26)
titleRow.Position               = UDim2.new(0, 14, 0, 10)
titleRow.BackgroundTransparency = 1
titleRow.Parent                 = panel
local titleLabel = text("Title", "Parts", 16, C.GlassText, nil, true, titleRow)
titleLabel.FontFace = FF.Heavy
local countPill                  = Instance.new("TextLabel")
countPill.AnchorPoint            = Vector2.new(1, 0.5)
countPill.Position               = UDim2.new(1, 0, 0.5, 0)
countPill.Size                   = UDim2.new(0, 0, 0, 20)
countPill.AutomaticSize          = Enum.AutomaticSize.X
countPill.BackgroundColor3       = Color3.new(1, 1, 1)
countPill.BackgroundTransparency = 0.92
countPill.FontFace               = FF.Mono
countPill.TextSize               = 12
countPill.TextColor3             = C.GlassText
countPill.Text                   = "0"
countPill.Parent                 = titleRow
UITheme.Corner(countPill, UITheme.Radius.Pill)
UITheme.Pad(countPill, 0, 8)
divider(panel, 44)

-- Search
local searchBox                  = Instance.new("TextBox")
searchBox.Name                   = "SearchBox"
searchBox.Size                   = UDim2.new(1, -(28 + SORT_W + 6), 0, 30)
searchBox.Position               = UDim2.new(0, 14, 0, 54)
searchBox.BackgroundColor3       = C.Text
searchBox.BackgroundTransparency = 0.95
searchBox.BorderSizePixel        = 0
searchBox.FontFace               = FF.Body
searchBox.PlaceholderText        = "Search parts"
searchBox.PlaceholderColor3      = C.GlassFaint
searchBox.Text                   = ""
searchBox.TextColor3             = C.GlassText
searchBox.TextSize               = 13
searchBox.TextXAlignment         = Enum.TextXAlignment.Left
searchBox.ClearTextOnFocus       = false
searchBox.Parent                 = panel
UITheme.Corner(searchBox, UDim.new(0, 8))
UITheme.Stroke(searchBox, Color3.new(1, 1, 1), 1, 0.92)
local searchPad       = Instance.new("UIPadding")
searchPad.PaddingLeft = UDim.new(0, 10)
searchPad.Parent      = searchBox

-- Sort, beside the search box
local sortRow                  = Instance.new("Frame")
sortRow.AnchorPoint            = Vector2.new(1, 0)
sortRow.Size                   = UDim2.new(0, SORT_W, 0, 30)
sortRow.Position               = UDim2.new(1, -14, 0, 54)
sortRow.BackgroundTransparency = 1
sortRow.ZIndex                 = 5
sortRow.Parent                 = panel

local SORT_ARROW = "  ▾" -- drawn in Gotham, which has the arrow (Builder Sans doesn't)
local sortBtn    = flatButton(SORT_MODES[sortIndex].label .. SORT_ARROW, sortRow)
sortBtn.Size     = UDim2.new(1, 0, 1, 0)
sortBtn.Font     = Enum.Font.GothamMedium
sortBtn.TextSize = 12

local dropFrame                  = Instance.new("Frame")
dropFrame.AnchorPoint            = Vector2.new(1, 0)
dropFrame.Size                   = UDim2.new(0, 130, 0, #SORT_MODES * 26)
dropFrame.Position               = UDim2.new(1, 0, 1, 4)
dropFrame.BackgroundColor3       = C.Glass
dropFrame.BackgroundTransparency = 0.02
dropFrame.BorderSizePixel        = 0
dropFrame.Visible                = false
dropFrame.ZIndex                 = 10
dropFrame.Parent                 = sortRow
UITheme.Corner(dropFrame, UDim.new(0, 8))
UITheme.Stroke(dropFrame, Color3.new(1, 1, 1), 1, 0.88)

local dropLayout     = Instance.new("UIListLayout")
dropLayout.SortOrder = Enum.SortOrder.LayoutOrder
dropLayout.Parent    = dropFrame

local dropButtons = {}
for i, mode in ipairs(SORT_MODES) do
	local b                  = Instance.new("TextButton")
	b.Size                   = UDim2.new(1, 0, 0, 26)
	b.BackgroundTransparency = 1
	b.FontFace               = FF.Body
	b.Text                   = mode.label
	b.TextColor3             = C.GlassText
	b.TextSize               = 12
	b.LayoutOrder            = i
	b.ZIndex                 = 11
	b.Parent                 = dropFrame
	dropButtons[i]           = b
end

-- List
local scroll                  = Instance.new("ScrollingFrame")
scroll.Size                   = UDim2.new(1, -16, 1, -(LIST_TOP + CLEAR_H + 20))
scroll.Position               = UDim2.new(0, 8, 0, LIST_TOP)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel        = 0
scroll.ScrollBarThickness     = 4
scroll.ScrollBarImageColor3   = C.Text
scroll.ScrollBarImageTransparency = 0.6
scroll.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar -- rows make room for the bar when it shows
scroll.AutomaticCanvasSize    = Enum.AutomaticSize.Y
scroll.CanvasSize             = UDim2.new(0, 0, 0, 0)
scroll.Parent                 = panel

local listLayout     = Instance.new("UIListLayout")
listLayout.Padding   = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent    = scroll
local listPad = Instance.new("UIPadding")
listPad.PaddingTop = UDim.new(0, 2)
listPad.PaddingLeft = UDim.new(0, 2)
listPad.PaddingRight = UDim.new(0, 4)
listPad.Parent = scroll

-- The panel grows with the list, up to PANEL_MAX (or the screen); past that
-- the list scrolls.
local function resizePanel()
	local scale = math.max(uiScale.Scale, 0.01)
	local content = listLayout.AbsoluteContentSize.Y / scale + 8
	local screenRoom = camera.ViewportSize.Y / scale - TOP - 140
	local maxH = math.max(260, math.min(PANEL_MAX, screenRoom))
	local h = math.clamp(LIST_TOP + content + CLEAR_H + 22, LIST_TOP + 60 + CLEAR_H, maxH)
	root.Size = UDim2.new(0, PANEL_W + TOGGLE_W, 0, h)
end
listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resizePanel)
camera:GetPropertyChangedSignal("ViewportSize"):Connect(function() task.defer(resizePanel) end)
task.defer(resizePanel)

local emptyLabel       = text("Empty", "No parts removed", 12, C.GlassFaint, Enum.TextXAlignment.Center, false, scroll)
emptyLabel.Size        = UDim2.new(1, 0, 0, 34)
emptyLabel.LayoutOrder = -1

-- Clear (testing tool), at the bottom
divider(panel, 0).Position = UDim2.new(0, 0, 1, -(CLEAR_H + 14))
local clearBtn                  = flatButton("CLEAR INVENTORY (TESTING)", panel)
clearBtn.Size                   = UDim2.new(1, -28, 0, CLEAR_H - 4)
clearBtn.Position               = UDim2.new(0, 14, 1, -(CLEAR_H + 4))
clearBtn.BackgroundTransparency = 1
clearBtn.TextColor3             = C.GlassMuted
clearBtn.TextSize               = 11

-- Mouse wheel over the panel scrolls the list instead of zooming the camera.
panel.MouseEnter:Connect(function()
	ContextActionService:BindAction("SinkInvScroll", function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.UserInputType.MouseWheel)
end)
panel.MouseLeave:Connect(function()
	ContextActionService:UnbindAction("SinkInvScroll")
end)

-- ── Part status ───────────────────────────────────────────────────────────────

-- Short status for a part, or nil. "FITS HERE" uses the same rule the
-- server enforces on reinstall (PartRules), so it only shows when a
-- reinstall would really be accepted right now.
local function getStatus(item: Item, bayEngine: Model?): (string?, Color3?)
	local wear = tonumber(item.wear) or 0
	if bayEngine and CarUtils.CanWorkOn(bayEngine, player)
		and CarUtils.PartFits(item.carId, item.engineName, bayEngine)
		and not bayEngine:FindFirstChild(item.name) then
		local template = RepairRules.FindTemplate(item.engineName, item.name)
		if template and PartRules.GetReinstallBlocker(template, bayEngine) == nil then
			return "FITS HERE", C.Done
		end
	end
	if not RepairRules.GetOptions(wear).canRepair and wear < 100 then
		return "NEEDS REPLACING", C.BadText
	end
	if wear >= 100 then
		return "PERFECT", C.Done
	end
	return nil, nil
end

-- ── Rows ──────────────────────────────────────────────────────────────────────

-- Shows which row is selected (no event).
local function highlightSelection()
	for id, row in pairs(rows) do
		local isSel = id == selectedId
		row.frame.BackgroundColor3       = if isSel then C.Done else C.Text
		row.frame.BackgroundTransparency = if isSel then 0.9 else 1
		row.stroke.Transparency          = if isSel then 0.55 else 1
	end
end

-- Changes the selection and tells GhostSystem / RepairUI. Only fires when
-- the selection actually changes, so inventory updates (e.g. a repair
-- finishing) don't make the bench or ghost rebuild.
local function setSelected(itemId: string?)
	local item = nil
	if itemId then
		for _, it in ipairs(inventory) do
			if it.id == itemId then
				item = it
				break
			end
		end
	end
	local newId = item and item.id or nil
	if newId == selectedId then
		highlightSelection()
		return
	end

	selectedId = newId
	highlightSelection()
	if item then
		ClientSignals.PartSelected:Fire(item.id, item.name, item.engineName, item.relativeData, item.carId)
	else
		ClientSignals.PartSelected:Fire(nil, nil, nil, nil, nil)
	end
end

local function makeRow(itemId: string): Row
	local frame                  = Instance.new("Frame")
	frame.Name                   = "Row"
	frame.Size                   = UDim2.new(1, 0, 0, ROW_H)
	frame.BackgroundColor3       = C.Text
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel        = 0
	frame.Parent                 = scroll
	UITheme.Corner(frame, UDim.new(0, 10))
	local stroke = UITheme.Stroke(frame, C.Done, 1, 1)

	local name    = text("Name", "", 14, C.GlassText, nil, true, frame)
	name.Size     = UDim2.new(1, -86, 0, 18)
	name.Position = UDim2.new(0, 10, 0, 6)

	local detail    = text("Detail", "", 11, C.GlassMuted, nil, false, frame)
	detail.Size     = UDim2.new(1, -86, 0, 14)
	detail.Position = UDim2.new(0, 10, 0, 25)
	detail.RichText = true

	local cond       = text("Condition", "", 14, C.Text, Enum.TextXAlignment.Right, true, frame)
	cond.Size        = UDim2.new(0, 60, 0, 18)
	cond.AnchorPoint = Vector2.new(1, 0)
	cond.Position    = UDim2.new(1, -10, 0, 7)
	cond.FontFace    = FF.MonoB

	-- Condition bar under the %
	local track                  = Instance.new("Frame")
	track.AnchorPoint            = Vector2.new(1, 0)
	track.Position               = UDim2.new(1, -10, 0, 30)
	track.Size                   = UDim2.new(0, 54, 0, 4)
	track.BackgroundColor3       = C.Text
	track.BackgroundTransparency = 0.92
	track.BorderSizePixel        = 0
	track.Parent                 = frame
	UITheme.Corner(track, UITheme.Radius.Pill)
	local bar            = Instance.new("Frame")
	bar.Size             = UDim2.new(0, 0, 1, 0)
	bar.BorderSizePixel  = 0
	bar.Parent           = track
	UITheme.Corner(bar, UITheme.Radius.Pill)

	local button                  = Instance.new("TextButton")
	button.Size                   = UDim2.new(1, 0, 1, 0)
	button.BackgroundTransparency = 1
	button.Text                   = ""
	button.ZIndex                 = 2
	button.Parent                 = frame
	button.MouseButton1Click:Connect(function()
		setSelected(selectedId ~= itemId and itemId or nil)
	end)

	return { frame = frame, stroke = stroke, name = name, detail = detail, cond = cond, bar = bar }
end

-- Updates a row's text and colours from its item.
local function fillRow(row: Row, item: Item, bayEngine: Model?)
	local wear = tonumber(item.wear) or 0
	row.name.Text       = item.name
	row.cond.Text       = string.format("%d%%", math.floor(wear))
	row.cond.TextColor3 = WearColors.Gradient(wear)
	row.bar.Size             = UDim2.new(math.clamp(wear / 100, 0, 1), 0, 1, 0)
	row.bar.BackgroundColor3 = WearColors.Gradient(wear)

	local status, statusColor = getStatus(item, bayEngine)
	local engineText = item.engineName or "?"
	if status and statusColor then
		row.detail.Text = string.format('%s  ·  <b><font color="%s">%s</font></b>', engineText, UITheme.ToHex(statusColor), status)
	else
		row.detail.Text = engineText
	end
end

local function sortKey(a: Item, b: Item): boolean
	local key = SORT_MODES[sortIndex].key
	if key == "wearAsc" and a.wear ~= b.wear then return a.wear < b.wear end
	if key == "wearDesc" and a.wear ~= b.wear then return a.wear > b.wear end
	if key == "engine" and a.engineName ~= b.engineName then return (a.engineName or "") < (b.engineName or "") end
	if a.name ~= b.name then return a.name < b.name end
	return a.id < b.id -- stable order for identical parts
end

-- Shows/hides and orders the existing rows for the current search and sort.
local function applyFilterAndSort()
	local query = searchText:lower()
	local visible = {}
	for _, item in ipairs(inventory) do
		local row = rows[item.id]
		local match = query == ""
			or item.name:lower():find(query, 1, true) ~= nil
			or (item.engineName or ""):lower():find(query, 1, true) ~= nil
		row.frame.Visible = match
		if match then table.insert(visible, item) end
	end
	table.sort(visible, sortKey)
	for i, item in ipairs(visible) do
		rows[item.id].frame.LayoutOrder = i
	end

	emptyLabel.Visible = #visible == 0
	emptyLabel.Text = (#inventory == 0) and "No parts removed" or "No matches"
end

local function updateBadge()
	badgeLabel.Text = tostring(#inventory)
	countPill.Text  = tostring(#inventory)
	badge.Visible   = not panelOpen and #inventory > 0
end

-- Re-reads statuses ("fits here" depends on which bay you're standing in).
local function refreshStatuses()
	local bayEngine = ZoneUtils.GetEngineForPlayer(player)
	for _, item in ipairs(inventory) do
		local row = rows[item.id]
		if row then fillRow(row, item, bayEngine) end
	end
end

-- New inventory from the server: create rows for new parts, remove rows
-- for parts that are gone, update the rest in place.
local function setInventory(newInventory: { Item }?)
	inventory = newInventory or {}

	local present = {}
	for _, item in ipairs(inventory) do
		present[item.id] = true
		if not rows[item.id] then
			rows[item.id] = makeRow(item.id)
		end
	end
	for id, row in pairs(rows) do
		if not present[id] then
			row.frame:Destroy()
			rows[id] = nil
		end
	end

	refreshStatuses()
	applyFilterAndSort()
	updateBadge()

	-- The selected part is gone (reinstalled, cleared...): deselect it.
	if selectedId and not present[selectedId] then
		setSelected(nil)
	else
		highlightSelection() -- new rows need the highlight state too
	end
end

-- ── Sort menu ─────────────────────────────────────────────────────────────────

local dropHovered = false
dropFrame.MouseEnter:Connect(function() dropHovered = true end)
dropFrame.MouseLeave:Connect(function() dropHovered = false end)

local function setDropdown(open: boolean)
	dropdownOpen      = open
	dropFrame.Visible = open
end

sortBtn.MouseButton1Click:Connect(function()
	setDropdown(not dropdownOpen)
end)

for i, b in ipairs(dropButtons) do
	b.MouseButton1Click:Connect(function()
		sortIndex    = i
		sortBtn.Text = SORT_MODES[i].label .. SORT_ARROW
		setDropdown(false)
		applyFilterAndSort()
	end)
end

-- ── Search ────────────────────────────────────────────────────────────────────

searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	searchText = searchBox.Text
	applyFilterAndSort()
end)

-- ── Panel open / close ────────────────────────────────────────────────────────

local function setPanelOpen(open: boolean)
	panelOpen       = open
	arrowLabel.Text = open and "▶" or "◀"
	updateBadge()
	-- Closed: slide right so only the toggle tab stays on screen.
	TweenService:Create(root, TWEEN_INFO, {
		Position = open and UDim2.new(1, -MARGIN, 0, TOP)
			or UDim2.new(1, PANEL_W * uiScale.Scale, 0, TOP),
	}):Play()
end

toggleBtn.MouseButton1Click:Connect(function()
	setPanelOpen(not panelOpen)
end)

-- ── Clear inventory (testing) — click twice to confirm ────────────────────────

local function resetClearButton()
	clearArmedAt                    = nil
	clearBtn.Text                   = "CLEAR INVENTORY (TESTING)"
	clearBtn.BackgroundTransparency = 1
	clearBtn.TextColor3             = C.GlassMuted
end

clearBtn.MouseButton1Click:Connect(function()
	if #inventory == 0 then return end

	if clearArmedAt and os.clock() - clearArmedAt <= CLEAR_CONFIRM_TIME then
		resetClearButton()
		clearInventory:FireServer()
		setSelected(nil)
		return
	end

	-- First click: arm it, and disarm automatically if not confirmed in time.
	clearArmedAt                    = os.clock()
	clearBtn.BackgroundColor3       = C.Bad
	clearBtn.BackgroundTransparency = 0
	clearBtn.TextColor3             = C.GlassText
	local armedAt = clearArmedAt
	for remaining = CLEAR_CONFIRM_TIME, 1, -1 do
		if clearArmedAt ~= armedAt then return end
		clearBtn.Text = string.format("DELETE %d PARTS? CLICK AGAIN (%d)", #inventory, remaining)
		task.wait(1)
	end
	if clearArmedAt == armedAt then
		resetClearButton()
	end
end)

-- ── Input ─────────────────────────────────────────────────────────────────────

UserInputService.InputBegan:Connect(function(input, processed)
	-- Any click outside the open sort menu closes it.
	if input.UserInputType == Enum.UserInputType.MouseButton1 and dropdownOpen and not dropHovered then
		setDropdown(false)
	end
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Escape and selectedId then
		setSelected(nil)
	end
end)

-- ── Events ────────────────────────────────────────────────────────────────────

inventoryUpdated.OnClientEvent:Connect(setInventory)

-- GhostSystem removes a part from the list straight away when you reinstall
-- it; the server's next InventoryUpdated confirms (or restores) it.
ClientSignals.ReinstallRequested:Connect(function(itemId)
	local remaining = {}
	for _, item in ipairs(inventory) do
		if item.id ~= itemId then table.insert(remaining, item) end
	end
	setInventory(remaining)
end)

-- "FITS HERE" depends on where you're standing and what's in the engine,
-- so re-check it a couple of times a second (cheap: one zone lookup).
task.spawn(function()
	while true do
		task.wait(STATUS_REFRESH)
		if panelOpen and #inventory > 0 then
			refreshStatuses()
		end
	end
end)

requestInventory:FireServer()
