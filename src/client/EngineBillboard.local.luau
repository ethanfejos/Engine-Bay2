--[[
    EngineBillboard (LocalScript)
    -----------------------------
    Updated Version:
    - Uses updated ToolRegistry helper method to look inside Workspace.Engines
    - Preserves all original layout structures, completion rings, and fading logic
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Modules   = ReplicatedStorage:WaitForChild("Modules")

local ToolRegistry    = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolRegistry"))
local InspectionState = require(Modules:WaitForChild("InspectionState"))
local EngineContext   = require(Modules:WaitForChild("EngineContext"))

-- ── Palette ───────────────────────────────────────────────────────────────────

local C = {
	White   = Color3.fromRGB(255, 255, 255),
	Dim     = Color3.fromRGB(255, 255, 255),
	Muted   = Color3.fromRGB(255, 255, 255),
	OK      = Color3.fromRGB(255, 255, 255),
	WORN    = Color3.fromRGB(255, 200, 0),
	FAIL    = Color3.fromRGB(255, 50,  50),
	Removed = Color3.fromRGB(140, 140, 140),
}

-- ── Config ────────────────────────────────────────────────────────────────────

local WEAR_OK          = 60
local WEAR_WORN        = 30
local SIDE_PANEL_WIDTH = 260
local PANEL_TWEEN      = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local UPDATE_INTERVAL  = 1
local FADE_DISTANCE    = 25
local FADE_MIN         = 18

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function corner(parent, radius)
	Instance.new("UICorner", parent).CornerRadius = radius or UDim.new(0, 4)
end

local function makeLabel(name, text, size, color, xAlign, parent)
	local l                   = Instance.new("TextLabel")
	l.Name                    = name
	l.Text                    = text
	l.TextSize                = size
	l.TextColor3              = color
	l.Font                    = Enum.Font.Gotham
	l.BackgroundTransparency  = 1
	l.TextXAlignment          = xAlign or Enum.TextXAlignment.Left
	l.TextYAlignment          = Enum.TextYAlignment.Center
	l.Size                    = UDim2.new(1, 0, 1, 0)
	l.Parent                  = parent
	return l
end

local function makeDivider(parent, yPos, xPad)
	xPad = xPad or 0
	local d                   = Instance.new("Frame")
	d.Size                    = UDim2.new(1, -xPad * 2, 0, 1)
	d.Position                = UDim2.new(0, xPad, 0, yPos)
	d.BackgroundColor3        = C.White
	d.BackgroundTransparency  = 0.7
	d.BorderSizePixel         = 0
	d.Parent                  = parent
	return d
end

local function getWearStatus(wear)
	if wear >= WEAR_OK   then return "OK",   C.OK   end
	if wear >= WEAR_WORN then return "WORN", C.WORN end
	return "FAIL", C.FAIL
end

local function getWearColor(wear)
	local _, color = getWearStatus(wear)
	return color
end

local function getAverageWear(parts)
	local total, count = 0, 0
	for _, part in ipairs(parts) do
		if part.Parent and InspectionState.IsInspected(part) then
			total = total + (part:GetAttribute("Wear") or 100)
			count = count + 1
		end
	end
	return count > 0 and math.floor(total / count) or nil
end

local function getOverallStatus(parts)
	local worstWear = math.huge
	for _, part in ipairs(parts) do
		if part.Parent and InspectionState.IsInspected(part) then
			local w = part:GetAttribute("Wear") or 100
			if w < worstWear then worstWear = w end
		end
	end
	if worstWear == math.huge then return "—", C.Muted end
	local status, color = getWearStatus(worstWear)
	if status == "FAIL" then return "CRITICAL", C.FAIL end
	if status == "WORN" then return "WARNING",  C.WORN end
	return "GOOD", C.OK
end

local function findFirstBasePart(model)
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then return desc end
	end
	return nil
end

local function buildBar(parent, yPos, color)
	local track                  = Instance.new("Frame")
	track.Size                   = UDim2.new(1, 0, 0, 4)
	track.Position               = UDim2.new(0, 0, 0, yPos)
	track.BackgroundColor3       = Color3.fromRGB(50, 50, 50)
	track.BackgroundTransparency = 0.3
	track.BorderSizePixel        = 0
	track.Parent                 = parent
	corner(track, UDim.new(1, 0))

	local fill                   = Instance.new("Frame")
	fill.Size                    = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3        = color
	fill.BorderSizePixel         = 0
	fill.Parent                  = track
	corner(fill, UDim.new(1, 0))

	local function update(fraction, fillColor)
		fill.Size             = UDim2.new(math.clamp(fraction, 0, 1), 0, 1, 0)
		fill.BackgroundColor3 = fillColor or color
	end

	return update, fill
end

-- ── Build ─────────────────────────────────────────────────────────────────────

local function buildBillboard(engine)
	local parts = {}
	for _, child in ipairs(engine:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("Inspectable") then
			table.insert(parts, child)
		end
	end
	if #parts == 0 then return end

	local trigger = engine:FindFirstChild("EngineTrigger")
	local adornee = (trigger and trigger:IsA("BasePart") and trigger)
		or engine.PrimaryPart
		or engine:FindFirstChildWhichIsA("BasePart")
		or findFirstBasePart(engine)
	if not adornee then
		warn("[EngineBillboard] No adornee found for:", engine.Name)
		return
	end

	-- ── Root ─────────────────────────────────────────────────────────────────

	local billboard         = Instance.new("BillboardGui")
	billboard.Name          = "EngineBillboard"
	billboard.AlwaysOnTop   = false
	billboard.Size          = UDim2.new(0, 420, 0, 110)
	billboard.StudsOffset   = Vector3.new(0, 5, 0)
	billboard.MaxDistance   = 30
	billboard.Active        = true
	billboard.LightInfluence = 0
	billboard.Adornee       = adornee
	billboard.Parent        = playerGui

	-- ── Main Panel ───────────────────────────────────────────────────────────

	local main                  = Instance.new("Frame")
	main.Name                   = "Main"
	main.Size                   = UDim2.new(0, 200, 1, 0)
	main.BackgroundTransparency = 1
	main.BorderSizePixel        = 0
	main.Parent                 = billboard

	-- Name row
	local nameRow               = Instance.new("Frame")
	nameRow.Size                = UDim2.new(1, -16, 0, 26)
	nameRow.Position            = UDim2.new(0, 8, 0, 6)
	nameRow.BackgroundTransparency = 1
	nameRow.Parent              = main

	local nameLabel = makeLabel("Name", engine.Name:upper(), 15, C.White,
		Enum.TextXAlignment.Left, nameRow)
	nameLabel.Font = Enum.Font.GothamBold

	makeDivider(main, 34, 8)

	-- Inspected row
	local inspRow               = Instance.new("Frame")
	inspRow.Size                = UDim2.new(1, -16, 0, 14)
	inspRow.Position            = UDim2.new(0, 8, 0, 42)
	inspRow.BackgroundTransparency = 1
	inspRow.Parent              = main

	local inspectedLabel = makeLabel("Inspected", "Inspected: 0/" .. #parts,
		11, C.Muted, Enum.TextXAlignment.Left, inspRow)

	-- Wear row
	local wRow                  = Instance.new("Frame")
	wRow.Size                   = UDim2.new(1, -16, 0, 14)
	wRow.Position               = UDim2.new(0, 8, 0, 58)
	wRow.BackgroundTransparency = 1
	wRow.Parent                 = main

	local wearLabel = makeLabel("Wear", "Wear: NOT READY",
		11, C.Muted, Enum.TextXAlignment.Left, wRow)

	-- Status row
	local sRow                  = Instance.new("Frame")
	sRow.Size                   = UDim2.new(1, -16, 0, 14)
	sRow.Position               = UDim2.new(0, 8, 0, 74)
	sRow.BackgroundTransparency = 1
	sRow.Parent                 = main

	local statusLabel = makeLabel("Status", "Status: —",
		11, C.Muted, Enum.TextXAlignment.Left, sRow)
	statusLabel.Font = Enum.Font.GothamBold

	-- ── Progress Bars ─────────────────────────────────────────────────────────

	local barContainer               = Instance.new("Frame")
	barContainer.Size                = UDim2.new(1, -16, 0, 36)
	barContainer.Position            = UDim2.new(0, 8, 1, -42)
	barContainer.BackgroundTransparency = 1
	barContainer.Parent              = main

	-- Build bar
	local buildTitleLabel            = makeLabel("BT", "BUILD", 9, C.Muted,
		Enum.TextXAlignment.Left, barContainer)
	buildTitleLabel.Size             = UDim2.new(0.3, 0, 0, 12)
	buildTitleLabel.Position         = UDim2.new(0, 0, 0, 0)

	local buildPctLabel              = makeLabel("BP", "0%", 9, C.White,
		Enum.TextXAlignment.Right, barContainer)
	buildPctLabel.Size               = UDim2.new(0.3, 0, 0, 12)
	buildPctLabel.Position           = UDim2.new(0.7, 0, 0, 0)
	buildPctLabel.Font               = Enum.Font.RobotoMono

	local updateBuildBar, buildFill  = buildBar(barContainer, 14, C.White)

	-- Health bar
	local healthTitleLabel           = makeLabel("HT", "HEALTH", 9, C.Muted,
		Enum.TextXAlignment.Left, barContainer)
	healthTitleLabel.Size            = UDim2.new(0.3, 0, 0, 12)
	healthTitleLabel.Position         = UDim2.new(0, 0, 0, 22)

	local healthPctLabel             = makeLabel("HP", "—", 9, C.White,
		Enum.TextXAlignment.Right, barContainer)
	healthPctLabel.Size              = UDim2.new(0.3, 0, 0, 12)
	healthPctLabel.Position          = UDim2.new(0.7, 0, 0, 22)
	healthPctLabel.Font              = Enum.Font.RobotoMono

	local updateHealthBar, healthFill = buildBar(barContainer, 36, C.OK)

	-- ── Toggle ───────────────────────────────────────────────────────────────

	local toggleBtn                  = Instance.new("TextButton")
	toggleBtn.Size                   = UDim2.new(0, 18, 0, 18)
	toggleBtn.Position               = UDim2.new(1, -22, 0, 4)
	toggleBtn.BackgroundTransparency = 1
	toggleBtn.BorderSizePixel        = 0
	toggleBtn.Font                   = Enum.Font.GothamBold
	toggleBtn.Text                   = ">"
	toggleBtn.TextColor3             = C.White
	toggleBtn.TextSize               = 15
	toggleBtn.Parent                 = main

	-- ── Side Panel ───────────────────────────────────────────────────────────

	local sidePanel                  = Instance.new("Frame")
	sidePanel.Name                   = "SidePanel"
	sidePanel.Size                   = UDim2.new(0, 0, 1, 0)
	sidePanel.Position               = UDim2.new(0, 218, 0, 0)
	sidePanel.BackgroundTransparency = 1
	sidePanel.BorderSizePixel        = 0
	sidePanel.ClipsDescendants       = true
	sidePanel.Parent                 = billboard

	local vDiv                       = Instance.new("Frame")
	vDiv.Size                        = UDim2.new(0, 1, 1, 0)
	vDiv.BackgroundColor3            = C.White
	vDiv.BackgroundTransparency      = 0.7
	vDiv.BorderSizePixel             = 0
	vDiv.Parent                      = sidePanel

	local inner                      = Instance.new("Frame")
	inner.Size                       = UDim2.new(0, SIDE_PANEL_WIDTH, 1, 0)
	inner.Position                   = UDim2.new(0, 10, 0, 0)
	inner.BackgroundTransparency     = 1
	inner.Parent                     = sidePanel

	-- Column headers
	local headerRow                  = Instance.new("Frame")
	headerRow.Size                   = UDim2.new(1, 0, 0, 16)
	headerRow.Position               = UDim2.new(0, 0, 0, 6)
	headerRow.BackgroundTransparency = 1
	headerRow.Parent                 = inner

	local hName = makeLabel("HN", "COMPONENT", 12, C.Muted,
		Enum.TextXAlignment.Left, headerRow)
	hName.Size = UDim2.new(0.55, 0, 1, 0)
	hName.Font = Enum.Font.GothamBold

	local hWear = makeLabel("HW", "WEAR", 12, C.Muted,
		Enum.TextXAlignment.Center, headerRow)
	hWear.Size     = UDim2.new(0.25, 0, 1, 0)
	hWear.Position = UDim2.new(0.55, 0, 0, 0)
	hWear.Font     = Enum.Font.GothamBold

	local hStat = makeLabel("HS", "STAT", 12, C.Muted,
		Enum.TextXAlignment.Center, headerRow)
	hStat.Size     = UDim2.new(0.2, 0, 1, 0)
	hStat.Position = UDim2.new(0.8, 0, 0, 0)
	hStat.Font     = Enum.Font.GothamBold

	makeDivider(inner, 24)

	-- Scroll list
	local scroll                     = Instance.new("ScrollingFrame")
	scroll.Size                      = UDim2.new(1, 0, 1, -28)
	scroll.Position                  = UDim2.new(0, 0, 0, 28)
	scroll.BackgroundTransparency    = 1
	scroll.BorderSizePixel           = 0
	scroll.ScrollBarThickness        = 2
	scroll.ScrollBarImageColor3      = C.Dim
	scroll.CanvasSize                = UDim2.new(0, 0, 0, 0)
	scroll.Parent                    = inner

	local listLayout                 = Instance.new("UIListLayout")
	listLayout.FillDirection         = Enum.FillDirection.Vertical
	listLayout.Padding               = UDim.new(0, 2)
	listLayout.SortOrder             = Enum.SortOrder.LayoutOrder
	listLayout.Parent                = scroll

	listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		scroll.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y)
	end)

	-- Part rows
	local partRows = {}
	for i, part in ipairs(parts) do
		local row                    = Instance.new("Frame")
		row.Size                     = UDim2.new(1, 0, 0, 15)
		row.BackgroundTransparency   = 1
		row.LayoutOrder              = i
		row.Parent                   = scroll

		local pName = makeLabel("N", part.Name, 11, C.Dim,
			Enum.TextXAlignment.Left, row)
		pName.Size         = UDim2.new(0.55, 0, 1, 0)
		pName.TextTruncate = Enum.TextTruncate.AtEnd

		local pWear = makeLabel("W", "?", 11, C.Muted,
			Enum.TextXAlignment.Center, row)
		pWear.Size     = UDim2.new(0.25, 0, 1, 0)
		pWear.Position = UDim2.new(0.55, 0, 0, 0)
		pWear.Font     = Enum.Font.RobotoMono

		local pStat = makeLabel("S", "?", 11, C.Muted,
			Enum.TextXAlignment.Center, row)
		pStat.Size     = UDim2.new(0.2, 0, 1, 0)
		pStat.Position = UDim2.new(0.8, 0, 0, 0)
		pStat.Font     = Enum.Font.GothamBold

		partRows[part] = {
			wearLabel = pWear,
			statLabel = pStat,
			nameLabel = pName,
		}
	end

	-- ── Toggle Logic ──────────────────────────────────────────────────────────

	local isOpen = false
	toggleBtn.MouseButton1Click:Connect(function()
		isOpen = not isOpen
		toggleBtn.Text = isOpen and "<" or ">"
		TweenService:Create(sidePanel, PANEL_TWEEN, {
			Size = UDim2.new(0, isOpen and SIDE_PANEL_WIDTH + 14 or 0, 1, 0)
		}):Play()
	end)

	-- ── Fade & Visibility Loop ────────────────────────────────────────────────

	local currentTransparency = 1
	billboard.Enabled = false

	RunService.RenderStepped:Connect(function()
		if not billboard.Parent then return end

		if EngineContext.IsInEngineView() then
			if billboard.Enabled then billboard.Enabled = false end
			return
		end

		local char = player.Character
		local hrp  = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp or not adornee then
			billboard.Enabled = false
			return
		end

		local dist        = (hrp.Position - adornee.Position).Magnitude
		local targetAlpha = 0

		if dist <= FADE_MIN then
			targetAlpha = 1
		elseif dist <= FADE_DISTANCE then
			targetAlpha = 1 - ((dist - FADE_MIN) / (FADE_DISTANCE - FADE_MIN))
		end

		currentTransparency = currentTransparency
			+ (targetAlpha - currentTransparency) * 0.1

		if currentTransparency < 0.02 then
			billboard.Enabled = false
		else
			billboard.Enabled = true
			for _, desc in ipairs(billboard:GetDescendants()) do
				if desc:IsA("TextLabel") or desc:IsA("TextButton") then
					desc.TextTransparency = 1 - currentTransparency
				end
				if desc:IsA("Frame") then
					local base = desc:GetAttribute("BaseTransparency")
					if not base then
						base = desc.BackgroundTransparency
						desc:SetAttribute("BaseTransparency", base)
					end
					if base >= 0.7 then
						desc.BackgroundTransparency = base + (1 - base) * (1 - currentTransparency)
					end
				end
			end
		end
	end)

	-- ── Update Loop ───────────────────────────────────────────────────────────

	task.spawn(function()
		while billboard.Parent do
			local inspectedCount = 0
			local presentCount   = 0
			local wearTotal      = 0
			local wearCount      = 0

			for _, part in ipairs(parts) do
				local row = partRows[part]
				if not row then continue end

				local inEngine = engine:FindFirstChild(part.Name) ~= nil

				if inEngine then
					local livePart = engine:FindFirstChild(part.Name)
					presentCount   = presentCount + 1

					if livePart and InspectionState.IsInspected(livePart) then
						inspectedCount           = inspectedCount + 1
						local wear               = livePart:GetAttribute("Wear") or 100
						local status, color      = getWearStatus(wear)
						row.wearLabel.Text       = math.floor(wear) .. "%"
						row.wearLabel.TextColor3 = color
						row.statLabel.Text       = status
						row.statLabel.TextColor3 = color
						row.nameLabel.TextColor3 = C.White
						wearTotal = wearTotal + wear
						wearCount = wearCount + 1
					else
						row.wearLabel.Text       = "?"
						row.wearLabel.TextColor3 = C.Muted
						row.statLabel.Text       = "?"
						row.statLabel.TextColor3 = C.Muted
						row.nameLabel.TextColor3 = C.White
					end
				else
					row.wearLabel.Text       = ""
					row.statLabel.Text       = "REMOVED"
					row.statLabel.TextColor3 = C.Removed
					row.nameLabel.TextColor3 = C.Removed
				end
			end

			inspectedLabel.Text = "Inspected: " .. inspectedCount .. "/" .. #parts

			if inspectedCount == #parts and presentCount == #parts then
				local avg            = math.floor(wearTotal / math.max(wearCount, 1))
				local _, wearColor   = getWearStatus(avg)
				wearLabel.Text       = "Wear: " .. avg .. "%"
				wearLabel.TextColor3 = wearColor
				local status, color  = getOverallStatus(parts)
				statusLabel.Text       = "Status: " .. status
				statusLabel.TextColor3 = color
			else
				wearLabel.Text         = "Wear: NOT READY"
				wearLabel.TextColor3   = C.Muted
				statusLabel.Text       = "Status: —"
				statusLabel.TextColor3 = C.Muted
			end

			local compFraction = #parts > 0 and (presentCount / #parts) or 0
			local compColor    = compFraction >= 1 and C.OK
				or compFraction >= 0.5 and C.WORN
				or C.FAIL
			updateBuildBar(compFraction, compColor)
			buildPctLabel.Text       = math.floor(compFraction * 100) .. "%"
			buildPctLabel.TextColor3 = compColor

			if wearCount > 0 then
				local avgHealth   = math.floor(wearTotal / wearCount)
				local healthColor = getWearColor(avgHealth)
				updateHealthBar(avgHealth / 100, healthColor)
				healthPctLabel.Text       = avgHealth .. "%"
				healthPctLabel.TextColor3 = healthColor
			else
				updateHealthBar(0, C.Muted)
				healthPctLabel.Text       = "—"
				healthPctLabel.TextColor3 = C.Muted
			end

			task.wait(UPDATE_INTERVAL)
		end
	end)
end

-- ── Boot (Updated to use your new ToolRegistry method) ──────────────────────────

local wiredNames = {}
for _, zoneId in ipairs(ToolRegistry.GetAllZoneIds()) do
	local partName = ToolRegistry.GetPartNameForZone(zoneId)
	if partName and not wiredNames[partName] then
		wiredNames[partName] = true
		task.spawn(function()
			-- Uses the clean layout check you just added!
			local engine = ToolRegistry.GetEngineInstance(zoneId, 10)
			if not engine then
				warn("[EngineBillboard] Engine not found in folder layout:", partName)
				return
			end
			task.wait(2)
			buildBillboard(engine)
		end)
	end
end