--!strict
--[[
    EngineHelpUI (LocalScript)
    --------------------------
    The controls bar in engine view (GLASS), just under the rent bar:

        [RMB drag] Turn · [WASD] Move · [Wheel] Zoom · [Click] Use tool ·
        [G] Find parts · [E] Leave            (?)  Settings  (fold)

    - (?)     a short how-to: inspecting, removing, putting parts back.
    - Settings  the player's settings (PlayerSettings): camera speeds, invert,
              skip the swoop in, bodywork fade 0–100%, show this bar. Saved
              by SettingsService (SaveSetting).
    - (fold)  hides the bar down to a small "Controls" pill (the "Show the
              controls bar" setting, so it stays hidden next time).
    - G / Find parts: flashes a red outline on the job's faulty parts that
      are still in the car and not fixed yet (JobUpdated.findParts).

    Only shown while in engine view (EngineContext.OnViewChanged).
]]

local GuiService        = game:GetService("GuiService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local Shared         = ReplicatedStorage:WaitForChild("Shared")
local Modules        = Shared:WaitForChild("Modules")
local Remotes        = require(Modules:WaitForChild("Remotes"))
local EngineContext  = require(Modules:WaitForChild("EngineContext"))
local HC             = require(Modules:WaitForChild("HighlightController"))
local PlayerSettings = require(Shared:WaitForChild("Config"):WaitForChild("PlayerSettings"))
local UITheme        = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, FF          = UITheme.Colors, UITheme.Faces

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Config ────────────────────────────────────────────────────────────────────

local FIND_KEY      = Enum.KeyCode.G
local FIND_KEY_NAME = "PartFinder"     -- HighlightController key
local FIND_COLOR    = Color3.fromHex("FF3B3B")
local FIND_FLASHES  = 3                -- on/off blinks
local FIND_BLINK    = 0.35             -- seconds on, then off
local BAR_GAP       = 8                -- px below the rent bar
local RENT_BAR      = 44               -- the rent bar's height (BayRentalUI)

local CONTROLS = {
	{ key = "RMB", text = "drag to turn" },
	{ key = "WASD", text = "move" },
	{ key = "Wheel", text = "zoom" },
	{ key = "Click", text = "use tool" },
	{ key = "G", text = "find parts" },
	{ key = "E", text = "leave" },
}

local HOW_TO = {
	"Inspection Tool: hold click on a part to inspect it and see its condition. A part must be inspected before it can come out.",
	"Wrench: undo the bolts, then click the part to take it out (anything in the way comes off first). It drops on the floor: walk over and press F to pick it up.",
	"Putting a part back: pick it in your inventory, then click its white ghost in the engine.",
	"Can't find a faulty part? Press G and it flashes red.",
	"Fix parts at the workbench, or replace them there.",
}

-- ── State ─────────────────────────────────────────────────────────────────────

local findPaths: { string } = {} -- the job's faulty parts still in the car
local open: string? = nil        -- "help" | "settings" | nil
local flashing = false

-- ── Screen ────────────────────────────────────────────────────────────────────

local screen          = Instance.new("ScreenGui")
screen.Name           = "EngineHelpUI"
screen.ResetOnSpawn   = false
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Enabled        = false
screen.Parent         = playerGui

-- Everything hangs from this column, centred under the rent bar.
local column                  = Instance.new("Frame")
column.AnchorPoint            = Vector2.new(0.5, 0)
column.Size                   = UDim2.new(0, 0, 0, 0)
column.AutomaticSize          = Enum.AutomaticSize.XY
column.BackgroundTransparency = 1
column.Parent                 = screen
local columnList = UITheme.List(column, 8)
columnList.HorizontalAlignment = Enum.HorizontalAlignment.Center

local function place()
	local inset = GuiService.TopbarInset
	local barTop = if inset.Height > 0 then inset.Min.Y + (inset.Height - math.min(inset.Height, RENT_BAR)) / 2 else 12
	local barHeight = if inset.Height > 0 then math.min(inset.Height, RENT_BAR) else RENT_BAR
	column.Position = UDim2.new(0.5, 0, 0, barTop + barHeight + BAR_GAP)
end
place()
GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(place)

-- A round icon button. Arrows and symbols use Gotham (BuilderSans lacks them).
local function iconButton(parent: Instance, glyph: string, label: string, order: number): TextButton
	local b                  = Instance.new("TextButton")
	b.Size                   = UDim2.new(0, 30, 0, 30)
	b.BackgroundColor3       = Color3.new(1, 1, 1)
	b.BackgroundTransparency = 0.92
	b.AutoButtonColor        = false
	b.Font                   = Enum.Font.GothamBold
	b.TextSize               = 15
	b.TextColor3             = C.GlassText
	b.Text                   = glyph
	b.LayoutOrder            = order
	b:SetAttribute("Label", label)
	b.Parent                 = parent
	UITheme.Corner(b, UITheme.Radius.Pill)
	return b
end

-- ── The bar ───────────────────────────────────────────────────────────────────

local bar             = Instance.new("Frame")
bar.Size              = UDim2.new(0, 0, 0, 40)
bar.AutomaticSize     = Enum.AutomaticSize.X
bar.LayoutOrder       = 1
bar.Parent            = column
UITheme.Glass(bar, UITheme.Radius.Pill)
local barPad = UITheme.Pad(bar, 0, 14)
barPad.PaddingRight = UDim.new(0, 5)
UITheme.List(bar, 12, true)

for i, control in ipairs(CONTROLS) do
	local item                  = Instance.new("Frame")
	item.Size                   = UDim2.new(0, 0, 1, 0)
	item.AutomaticSize          = Enum.AutomaticSize.X
	item.BackgroundTransparency = 1
	item.LayoutOrder            = i
	item.Parent                 = bar
	UITheme.List(item, 6, true)

	local cap                  = Instance.new("TextLabel")
	cap.Size                   = UDim2.new(0, 0, 0, 22)
	cap.AutomaticSize          = Enum.AutomaticSize.X
	cap.BackgroundColor3       = Color3.new(1, 1, 1)
	cap.BackgroundTransparency = 0.88
	cap.FontFace               = FF.MonoB
	cap.TextSize               = 12
	cap.TextColor3             = if control.key == "G" then C.BadText else C.GlassText
	cap.Text                   = control.key
	cap.LayoutOrder            = 1
	cap.Parent                 = item
	UITheme.Corner(cap, UDim.new(0, 5))
	UITheme.Pad(cap, 0, 7)

	local words = UITheme.Text(item, control.text, FF.Body, 13, C.GlassMuted)
	words.Size = UDim2.new(0, 0, 0, 22)
	words.AutomaticSize = Enum.AutomaticSize.X
	words.LayoutOrder = 2
end

local helpBtn     = iconButton(bar, "?", "Help", 20)
local settingsBtn = iconButton(bar, "Settings", "Settings", 21)
settingsBtn.Size = UDim2.new(0, 0, 0, 30)
settingsBtn.AutomaticSize = Enum.AutomaticSize.X
settingsBtn.FontFace = FF.Bold
settingsBtn.TextSize = 13
UITheme.Pad(settingsBtn, 0, 12)
local foldBtn     = iconButton(bar, "▲", "Hide", 22)
foldBtn.TextSize  = 11

-- Folded: a small pill to bring the bar back.
local pill                  = Instance.new("TextButton")
pill.Size                   = UDim2.new(0, 0, 0, 30)
pill.AutomaticSize          = Enum.AutomaticSize.X
pill.AutoButtonColor        = false
pill.FontFace               = FF.Bold
pill.TextSize               = 13
pill.TextColor3             = C.GlassText
pill.Text                   = "?  Controls"
pill.LayoutOrder            = 1
pill.Parent                 = column
UITheme.Glass(pill, UITheme.Radius.Pill)
UITheme.Pad(pill, 0, 14)

-- ── Help panel ────────────────────────────────────────────────────────────────

local function panel(order: number): Frame
	local f         = Instance.new("Frame")
	f.Size          = UDim2.new(0, 460, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.LayoutOrder   = order
	f.Visible       = false
	f.Parent        = column
	UITheme.Glass(f, UDim.new(0, 14))
	UITheme.Pad(f, 14, 16)
	UITheme.List(f, 8)
	return f
end

local helpPanel = panel(2)
local helpTitle = UITheme.Text(helpPanel, "HOW TO WORK ON AN ENGINE", FF.Heavy, 12, C.Amber)
helpTitle.LayoutOrder = 0
for i, line in ipairs(HOW_TO) do
	local l = UITheme.Text(helpPanel, "•  " .. line, FF.Body, 14, C.GlassText)
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.TextWrapped = true
	l.LayoutOrder = i
end

-- ── Settings panel ────────────────────────────────────────────────────────────

local settingsPanel = panel(3)
local settingsTitle = UITheme.Text(settingsPanel, "SETTINGS", FF.Heavy, 12, C.Amber)
settingsTitle.LayoutOrder = 0

local refreshers: { () -> () } = {}

local function save(key: string, value: any)
	-- Show it straight away; the server saves it and sets the attribute.
	player:SetAttribute(PlayerSettings.ATTRIBUTE_PREFIX .. key, value)
	Remotes.SaveSetting:FireServer(key, value)
	for _, refresh in ipairs(refreshers) do refresh() end
end

local function showNumber(s: PlayerSettings.Setting, value: number): string
	if s.unit == "%" then return ("%d%%"):format(math.floor(value + 0.5)) end
	return ((("%.2f"):format(value)):gsub("0+$", ""):gsub("%.$", "")) .. "x"
end

for i, s in ipairs(PlayerSettings.LIST) do
	local row                  = Instance.new("Frame")
	row.Size                   = UDim2.new(1, 0, 0, 34)
	row.BackgroundTransparency = 1
	row.LayoutOrder            = i
	row.Parent                 = settingsPanel

	local label = UITheme.Text(row, s.label, FF.Bold, 14, C.GlassText)
	label.Size = UDim2.new(1, -150, 1, 0)

	local controls                  = Instance.new("Frame")
	controls.AnchorPoint            = Vector2.new(1, 0.5)
	controls.Position               = UDim2.new(1, 0, 0.5, 0)
	controls.Size                   = UDim2.new(0, 140, 0, 30)
	controls.BackgroundTransparency = 1
	controls.Parent                 = row
	local list = UITheme.List(controls, 6, true)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right

	if s.kind == "toggle" then
		local switch                  = Instance.new("TextButton")
		switch.Size                   = UDim2.new(0, 52, 0, 28)
		switch.AutoButtonColor        = false
		switch.Text                   = ""
		switch.Parent                 = controls
		UITheme.Corner(switch, UITheme.Radius.Pill)
		local knob                  = Instance.new("Frame")
		knob.Size                   = UDim2.new(0, 22, 0, 22)
		knob.AnchorPoint            = Vector2.new(0, 0.5)
		knob.BackgroundColor3       = C.GlassText
		knob.BorderSizePixel        = 0
		knob.Parent                 = switch
		UITheme.Corner(knob, UITheme.Radius.Pill)
		local function refresh()
			local on = PlayerSettings.Get(player, s.key) == true
			switch.BackgroundColor3 = if on then C.Done else Color3.new(1, 1, 1)
			switch.BackgroundTransparency = if on then 0 else 0.85
			knob.Position = if on then UDim2.new(1, -25, 0.5, 0) else UDim2.new(0, 3, 0.5, 0)
		end
		switch.MouseButton1Click:Connect(function()
			save(s.key, not (PlayerSettings.Get(player, s.key) == true))
		end)
		table.insert(refreshers, refresh)
	else
		local minus = iconButton(controls, "-", "Less", 1)
		local value = UITheme.Text(controls, "", FF.MonoB, 14, C.Amber)
		value.Size = UDim2.new(0, 56, 0, 30)
		value.TextXAlignment = Enum.TextXAlignment.Center
		value.LayoutOrder = 2
		local plus = iconButton(controls, "+", "More", 3)
		local function current(): number
			local v = PlayerSettings.Get(player, s.key)
			return if type(v) == "number" then v else (s.default :: number)
		end
		local function nudge(direction: number)
			local clean = PlayerSettings.Clean(s.key, current() + direction * (s.step or 1))
			if clean ~= nil then save(s.key, clean) end
		end
		minus.MouseButton1Click:Connect(function() nudge(-1) end)
		plus.MouseButton1Click:Connect(function() nudge(1) end)
		table.insert(refreshers, function()
			local v = current()
			value.Text = showNumber(s, v)
			minus.TextTransparency = if v <= (s.min or 0) then 0.6 else 0
			plus.TextTransparency = if v >= (s.max or 10) then 0.6 else 0
		end)
	end
end

local resetBtn                  = Instance.new("TextButton")
resetBtn.Size                   = UDim2.new(0, 0, 0, 28)
resetBtn.AutomaticSize          = Enum.AutomaticSize.X
resetBtn.BackgroundTransparency = 1
resetBtn.FontFace               = FF.Bold
resetBtn.TextSize               = 12
resetBtn.TextColor3             = C.GlassMuted
resetBtn.Text                   = "Reset to defaults"
resetBtn.LayoutOrder            = 100
resetBtn.Parent                 = settingsPanel
resetBtn.MouseButton1Click:Connect(function()
	for _, s in ipairs(PlayerSettings.LIST) do
		if s.key ~= "showHelp" then save(s.key, s.default) end
	end
end)

-- ── Showing ───────────────────────────────────────────────────────────────────

local function refreshAll()
	local showBar = PlayerSettings.Get(player, "showHelp") ~= false
	bar.Visible = showBar
	pill.Visible = not showBar
	helpPanel.Visible = open == "help"
	settingsPanel.Visible = open == "settings"
	helpBtn.BackgroundTransparency = if open == "help" then 0.7 else 0.92
	settingsBtn.BackgroundTransparency = if open == "settings" then 0.7 else 0.92
	for _, refresh in ipairs(refreshers) do refresh() end
end
table.insert(refreshers, function()
	local showBar = PlayerSettings.Get(player, "showHelp") ~= false
	bar.Visible = showBar
	pill.Visible = not showBar
end)

local function toggle(which: string)
	open = if open == which then nil else which
	refreshAll()
end
helpBtn.MouseButton1Click:Connect(function() toggle("help") end)
settingsBtn.MouseButton1Click:Connect(function() toggle("settings") end)
foldBtn.MouseButton1Click:Connect(function()
	open = nil
	save("showHelp", false)
	refreshAll()
end)
pill.MouseButton1Click:Connect(function()
	save("showHelp", true)
	refreshAll()
end)

player.AttributeChanged:Connect(function(name)
	if string.sub(name, 1, #PlayerSettings.ATTRIBUTE_PREFIX) == PlayerSettings.ATTRIBUTE_PREFIX then
		for _, refresh in ipairs(refreshers) do refresh() end
	end
end)

-- ── Part finder ───────────────────────────────────────────────────────────────

-- The model at `path` ("Alternator", "Alternator/Bolt#2") inside `engine`,
-- counting same-named siblings the way CarState does.
local function resolve(engine: Instance, path: string): Instance?
	local node: Instance? = engine
	for segment in string.gmatch(path, "[^/]+") do
		if not node then return nil end
		local name, index = string.match(segment, "^(.-)#(%d+)$")
		local wanted = name or segment
		local n = if index then tonumber(index) or 1 else 1
		local found: Instance? = nil
		local seen = 0
		for _, child in ipairs(node:GetChildren()) do
			if child:IsA("Model") and child.Name == wanted then
				seen += 1
				if seen == n then
					found = child
					break
				end
			end
		end
		node = found
	end
	return node
end

-- A little message under the bar ("Nothing to find").
local toast = UITheme.Text(column, "", FF.Bold, 13, C.GlassText)
toast.Size = UDim2.new(0, 0, 0, 28)
toast.AutomaticSize = Enum.AutomaticSize.X
toast.BackgroundColor3 = C.Glass
toast.BackgroundTransparency = UITheme.GLASS_ALPHA
toast.LayoutOrder = 4
toast.Visible = false
UITheme.Corner(toast, UITheme.Radius.Pill)
UITheme.Pad(toast, 0, 14)
local toastToken = 0
local function say(text: string)
	toastToken += 1
	local mine = toastToken
	toast.Text = text
	toast.Visible = true
	task.delay(2.5, function()
		if toastToken == mine then toast.Visible = false end
	end)
end

local function findParts()
	if flashing then return end
	local engine = EngineContext.GetEngine()
	if not engine then return end
	local targets: { Instance } = {}
	for _, path in ipairs(findPaths) do
		local model = resolve(engine, path)
		if model then table.insert(targets, model) end
	end
	if #targets == 0 then
		say(if #findPaths == 0 then "Nothing to find: no faulty parts left in this car" else "Can't see those parts in this engine")
		return
	end
	flashing = true
	task.spawn(function()
		for _ = 1, FIND_FLASHES do
			for _, model in ipairs(targets) do
				HC.CreateStencil(FIND_KEY_NAME, model, FIND_COLOR)
			end
			task.wait(FIND_BLINK)
			HC.Clear(FIND_KEY_NAME)
			task.wait(FIND_BLINK * 0.6)
		end
		flashing = false
	end)
end

Remotes.JobUpdated.OnClientEvent:Connect(function(job: any)
	table.clear(findPaths)
	if type(job) == "table" and type(job.findParts) == "table" then
		for _, path in ipairs(job.findParts) do
			if type(path) == "string" then table.insert(findPaths, path) end
		end
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not EngineContext.IsInEngineView() then return end
	if input.KeyCode == FIND_KEY then findParts() end
end)

-- ── Engine view on / off ──────────────────────────────────────────────────────

EngineContext.OnViewChanged(function(inView: boolean)
	screen.Enabled = inView
	if not inView then
		open = nil
		HC.Clear(FIND_KEY_NAME)
	end
	refreshAll()
end)

refreshAll()
