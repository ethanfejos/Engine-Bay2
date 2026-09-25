--[[
    RepairUI (LocalScript)
    ----------------------
    - 3D Surface UI (Tilted 3D Pods)
    - Visual pass: clear glass panels with crisp white trim + soft glow,
      color reserved for status signals only (dot / wear % / bar tint).
    - Automatic number conversion for Wear %
    - Diagnostic logging to Output
]]

local Players         = game:GetService("Players")
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

-- ── Palette & Config ──────────────────────────────────────────────────────────
local WHITE      = Color3.fromRGB(255, 255, 255)
local TEXT_DIM   = Color3.fromRGB(190, 196, 208)
local PANEL_BG   = Color3.fromRGB(14, 16, 21)     -- dark clear glass fill (not fully invisible)
local PANEL_LINE = Color3.fromRGB(255, 255, 255)  -- crisp white trim

-- Status colors — used ONLY for the dot, wear %, and bar tint, never the whole panel
local GOOD   = Color3.fromRGB(72, 235, 164)
local WORN   = Color3.fromRGB(255, 191, 92)
local FAIL   = Color3.fromRGB(255, 92, 92)
local DIM    = Color3.fromRGB(140, 146, 158)

local MIN_WEAR       = 10
local PART_Y_OFFSET  = 1.2

-- ── State ─────────────────────────────────────────────────────────────────────
local inWorkbenchView  = false
local repairing        = false
local currentItemId    = nil
local currentInventory = {}
local partOnBench      = nil
local progressFill     = nil
local progressTrack    = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getWorkbenchAnchor()
	local wb = workspace:FindFirstChild("Workbench")
	if not wb then
		warn("RepairUI: 'Workbench' model missing!")
		return nil
	end
	return wb:FindFirstChild("PartAnchor") or wb:FindFirstChild("Main")
end

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or UDim.new(0, 10)
	c.Parent = parent
	return c
end

-- Crisp primary trim: thin, bright, low-transparency white line
local function trim(parent, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = PANEL_LINE
	s.Thickness = thickness or 1.5
	s.Transparency = transparency == nil and 0.08 or transparency
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = parent
	return s
end

-- Soft glow: a slightly larger, blurrier-feeling halo behind the trim.
-- Roblox UI has no native blur, so we fake it with 2-3 stacked low-alpha
-- oversized frames matching the panel's corner radius.
local function glow(panel, cornerRadius, glowColor)
	local halo = Instance.new("Frame")
	halo.Name = "Glow"
	halo.AnchorPoint = Vector2.new(0.5, 0.5)
	halo.Position = UDim2.new(0.5, 0, 0.5, 0)
	halo.Size = UDim2.new(1, 14, 1, 14)
	halo.BackgroundColor3 = glowColor or WHITE
	halo.BackgroundTransparency = 0.9
	halo.BorderSizePixel = 0
	halo.ZIndex = panel.ZIndex - 1
	corner(halo, cornerRadius)
	halo.Parent = panel.Parent
	halo.Position = panel.Position
	halo.AnchorPoint = panel.AnchorPoint
	return halo
end

local function makeDivider(parent, yPos, padX)
	padX = padX or 0
	local d = Instance.new("Frame")
	d.Size = UDim2.new(1, -padX * 2, 0, 1)
	d.Position = UDim2.new(0, padX, 0, yPos)
	d.BackgroundColor3 = WHITE
	d.BackgroundTransparency = 0.82
	d.BorderSizePixel = 0
	d.Parent = parent
	return d
end

-- Status color for a given wear value, shared by every element that needs it
local function statusColor(wearValue)
	if wearValue >= 60 then
		return GOOD
	elseif wearValue >= 30 then
		return WORN
	else
		return FAIL
	end
end

local function clearBench()
	print("RepairUI: Clearing workbench...")
	local wb = workspace:FindFirstChild("Workbench")
	if wb then
		local left = wb:FindFirstChild("LeftUiMount")
		local right = wb:FindFirstChild("RightUiMount")
		if left then left:Destroy() end
		if right then right:Destroy() end

		local part = wb:FindFirstChild("PartOnBench")
		if part then part:Destroy() end
	end

	local oldLeft = playerGui:FindFirstChild("LeftRepairSurface")
	local oldRight = playerGui:FindFirstChild("RightRepairSurface")
	if oldLeft then oldLeft:Destroy() end
	if oldRight then oldRight:Destroy() end

	partOnBench = nil
	progressFill = nil
	progressTrack = nil
end

-- ── Build 3D World UI ─────────────────────────────────────────────────────────

local function buildBillboard(itemId, partName, wear)
	local anchor = getWorkbenchAnchor()
	local wb = workspace:FindFirstChild("Workbench")
	if not anchor or not wb then return end

	local wearValue = tonumber(wear) or 0
	local accent = statusColor(wearValue)
	print("RepairUI: Building 3D UI for " .. partName)

	-- 1. Create physical mounts (fully invisible so UI panels float seamlessly)
	local function createMount(name, offset)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = Vector3.new(3, 1.8, 0.01)
		p.Transparency = 1
		p.CanCollide = false
		p.Anchored = true
		p.CFrame = anchor.CFrame * offset
		p.Parent = wb
		return p
	end

	local leftMount = createMount("LeftUiMount", CFrame.new(-4.5, 1, -1) * CFrame.Angles(0, math.rad(25), 0))
	local rightMount = createMount("RightUiMount", CFrame.new(4.5, 1, -1) * CFrame.Angles(0, math.rad(-25), 0))

	-- 2. SurfaceGui Setup
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

	-- ============================================================
	-- LEFT PANEL — Action
	-- ============================================================
	local leftPanel = Instance.new("Frame", leftSgui)
	leftPanel.Size = UDim2.new(1, 0, 1, 0)
	leftPanel.BackgroundColor3 = PANEL_BG
	leftPanel.BackgroundTransparency = 0.4
	leftPanel.BorderSizePixel = 0
	leftPanel.ZIndex = 2
	corner(leftPanel, UDim.new(0, 12))
	glow(leftPanel, UDim.new(0, 12), WHITE)
	trim(leftPanel, 1.5, 0.08)

	-- Thin white underline instead of a colored block — trim stays white,
	-- only its own small status chip carries color
	local statusChip = Instance.new("Frame", leftPanel)
	statusChip.Size = UDim2.new(0, 8, 0, 8)
	statusChip.Position = UDim2.new(1, -22, 0, 18)
	statusChip.BackgroundColor3 = accent
	statusChip.BorderSizePixel = 0
	corner(statusChip, UDim.new(1, 0))
	local chipGlow = glow(statusChip, UDim.new(1, 0), accent)
	chipGlow.BackgroundTransparency = 0.75
	chipGlow.Size = UDim2.new(0, 20, 0, 20)

	-- Small eyebrow label above the button
	local eyebrow = Instance.new("TextLabel", leftPanel)
	eyebrow.Size = UDim2.new(1, -40, 0, 16)
	eyebrow.Position = UDim2.new(0, 24, 0.5, -48)
	eyebrow.BackgroundTransparency = 1
	eyebrow.Font = Enum.Font.GothamMedium
	eyebrow.TextSize = 11
	eyebrow.TextColor3 = TEXT_DIM
	eyebrow.TextXAlignment = Enum.TextXAlignment.Left
	eyebrow.Text = "ACTION"

	-- Primary action button — clear glass by default, flips to solid white on hover for pop
	local btn = Instance.new("TextButton", leftPanel)
	btn.Size = UDim2.new(1, -40, 0, 46)
	btn.Position = UDim2.new(0, 24, 0.5, -22)
	btn.BackgroundColor3 = WHITE
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 14
	btn.AutoButtonColor = false
	corner(btn, UDim.new(0, 9))
	local btnTrim = trim(btn, 1.5, 0.08)

	if wearValue >= 100 then
		btn.BackgroundTransparency = 1
		btn.Text = "✓  OPERATIONAL"
		btn.TextColor3 = GOOD
		btnTrim.Color = GOOD
		btnTrim.Transparency = 0.3
	elseif wearValue <= MIN_WEAR then
		btn.BackgroundTransparency = 1
		btn.Text = "UNREPAIRABLE — SCRAP"
		btn.TextColor3 = FAIL
		btnTrim.Color = FAIL
		btnTrim.Transparency = 0.25
	else
		btn.BackgroundTransparency = 1
		btn.Text = "INITIATE REPAIR"
		btn.TextColor3 = WHITE

		-- Hover inverts to a solid bright-white fill with dark text — the "pop" moment
		btn.MouseEnter:Connect(function()
			if not repairing then
				TweenService:Create(btn, TweenInfo.new(0.12), {BackgroundTransparency = 0}):Play()
				TweenService:Create(btn, TweenInfo.new(0.12), {TextColor3 = Color3.fromRGB(15, 16, 20)}):Play()
			end
		end)
		btn.MouseLeave:Connect(function()
			if not repairing then
				TweenService:Create(btn, TweenInfo.new(0.12), {BackgroundTransparency = 1}):Play()
				TweenService:Create(btn, TweenInfo.new(0.12), {TextColor3 = WHITE}):Play()
			end
		end)

		btn.MouseButton1Click:Connect(function()
			if repairing then return end
			repairing = true
			btn.Text = "REPAIRING..."
			btn.BackgroundTransparency = 1
			btn.TextColor3 = DIM
			btnTrim.Transparency = 0.6
			startRepairEvent:FireServer(itemId)
		end)
	end

	-- Small helper caption under the button
	local caption = Instance.new("TextLabel", leftPanel)
	caption.Size = UDim2.new(1, -40, 0, 16)
	caption.Position = UDim2.new(0, 24, 0.5, 32)
	caption.BackgroundTransparency = 1
	caption.Font = Enum.Font.Gotham
	caption.TextSize = 10
	caption.TextColor3 = TEXT_DIM
	caption.TextXAlignment = Enum.TextXAlignment.Left
	if wearValue >= 100 then
		caption.Text = "No maintenance required"
	elseif wearValue <= MIN_WEAR then
		caption.Text = "Beyond serviceable limits"
	else
		caption.Text = "Estimated cost scales with wear"
	end

	-- ============================================================
	-- RIGHT PANEL — Diagnostics
	-- ============================================================
	local rightPanel = Instance.new("Frame", rightSgui)
	rightPanel.Size = UDim2.new(1, 0, 1, 0)
	rightPanel.BackgroundColor3 = PANEL_BG
	rightPanel.BackgroundTransparency = 0.4
	rightPanel.BorderSizePixel = 0
	rightPanel.ZIndex = 2
	corner(rightPanel, UDim.new(0, 12))
	glow(rightPanel, UDim.new(0, 12), WHITE)
	trim(rightPanel, 1.5, 0.08)

	-- Header row: status dot + part name
	local headerRow = Instance.new("Frame", rightPanel)
	headerRow.Size = UDim2.new(1, -48, 0, 20)
	headerRow.Position = UDim2.new(0, 24, 0, 18)
	headerRow.BackgroundTransparency = 1

	local statusDot = Instance.new("Frame", headerRow)
	statusDot.Size = UDim2.new(0, 8, 0, 8)
	statusDot.Position = UDim2.new(0, 0, 0.5, -4)
	statusDot.BackgroundColor3 = accent
	statusDot.BorderSizePixel = 0
	corner(statusDot, UDim.new(1, 0))
	local dotGlow = glow(statusDot, UDim.new(1, 0), accent)
	dotGlow.BackgroundTransparency = 0.7
	dotGlow.Size = UDim2.new(0, 18, 0, 18)

	local label = Instance.new("TextLabel", headerRow)
	label.Size = UDim2.new(1, -18, 1, 0)
	label.Position = UDim2.new(0, 18, 0, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = WHITE
	label.TextSize = 16
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = partName:upper()

	makeDivider(rightPanel, 48, 24)

	-- Info row: label + wear %
	local infoFrame = Instance.new("Frame", rightPanel)
	infoFrame.Size = UDim2.new(1, -48, 0, 20)
	infoFrame.Position = UDim2.new(0, 24, 0, 60)
	infoFrame.BackgroundTransparency = 1

	local statusLabel = Instance.new("TextLabel", infoFrame)
	statusLabel.Size = UDim2.new(0.62, 0, 1, 0)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextSize = 12
	statusLabel.TextColor3 = TEXT_DIM
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Text = "Hardware Integrity"

	local wearLabel = Instance.new("TextLabel", infoFrame)
	wearLabel.Size = UDim2.new(0.38, 0, 1, 0)
	wearLabel.Position = UDim2.new(0.62, 0, 0, 0)
	wearLabel.BackgroundTransparency = 1
	wearLabel.Font = Enum.Font.GothamBold
	wearLabel.TextSize = 14
	wearLabel.TextXAlignment = Enum.TextXAlignment.Right
	wearLabel.Text = math.floor(wearValue) .. "%"
	wearLabel.TextColor3 = accent

	if wearValue < 30 then
		statusLabel.TextColor3 = FAIL
		statusLabel.Text = "Critical Wear Failure"
	end

	-- Progress Track — clear glass track, white trim, colored fill only
	local track = Instance.new("Frame", rightPanel)
	track.Size = UDim2.new(1, -48, 0, 10)
	track.Position = UDim2.new(0, 24, 0, 102)
	track.BackgroundColor3 = Color3.fromRGB(8, 9, 12)
	track.BackgroundTransparency = 0.25
	track.BorderSizePixel = 0
	corner(track, UDim.new(1, 0))
	trim(track, 1, 0.35)

	-- Static wear-level fill (shows current condition, not repair progress)
	local wearFill = Instance.new("Frame", track)
	wearFill.Size = UDim2.new(math.clamp(wearValue / 100, 0, 1), 0, 1, 0)
	wearFill.BackgroundColor3 = accent
	wearFill.BackgroundTransparency = 0.1
	wearFill.BorderSizePixel = 0
	corner(wearFill, UDim.new(1, 0))

	-- Repair-progress fill, overlays the track and animates 0→1 during a repair
	local fill = Instance.new("Frame", track)
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = WHITE
	fill.BackgroundTransparency = 0.05
	fill.BorderSizePixel = 0
	fill.ZIndex = 2
	corner(fill, UDim.new(1, 0))

	-- Small caption under the bar
	local barCaption = Instance.new("TextLabel", rightPanel)
	barCaption.Size = UDim2.new(1, -48, 0, 14)
	barCaption.Position = UDim2.new(0, 24, 0, 116)
	barCaption.BackgroundTransparency = 1
	barCaption.Font = Enum.Font.Gotham
	barCaption.TextSize = 10
	barCaption.TextColor3 = TEXT_DIM
	barCaption.TextXAlignment = Enum.TextXAlignment.Left
	barCaption.Text = "Condition at last inspection"

	progressFill = fill
	progressTrack = track
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
		TweenService:Create(progressFill, TweenInfo.new(0.1, Enum.EasingStyle.Linear), {
			Size = UDim2.new(progress, 0, 1, 0),
		}):Play()
	end
end)

repairComplete.OnClientEvent:Connect(function(itemId, partName)
	repairing = false
	if progressFill then
		local finishTween = TweenService:Create(progressFill, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(1, 0, 1, 0),
		})
		finishTween:Play()
		finishTween.Completed:Wait()
	end
	task.wait(0.2)
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