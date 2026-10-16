--!strict
--[[
    CustomPromptManager (LocalScript)
    ---------------------------------
    Draws every ProximityPrompt in the game in one style (UI "Option D":
    glass) — a dark pill with a round key, the action and what it's on:

        ( F )  Pick up
               Belt · 48%

    - Every prompt in the Workspace is switched to the Custom style on this
      client, so the engine, workbench, Tony, customer and pick-up prompts
      all look the same.
    - Hold prompts: the key fills up green from the bottom while held.
    - A prompt with the attribute Tone = "money" gets an amber key (Tony's
      rent), Tone = "done" a green one (handing a car back).

    Works with keyboard and mouse:
    - Pressing the prompt's key is handled by Roblox itself; this only
      animates the fill from the prompt's own hold events.
    - Clicking the drawn prompt calls InputHoldBegin on press and
      InputHoldEnd on release (or when the mouse leaves it), which is how
      Roblox expects a custom prompt to be driven — Roblox then applies
      HoldDuration and fires Triggered itself.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService           = game:GetService("TweenService")
local Players                = game:GetService("Players")
local ReplicatedStorage      = game:GetService("ReplicatedStorage")
local Workspace              = game:GetService("Workspace")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UI"):WaitForChild("UITheme"))
local C, FF   = UITheme.Colors, UITheme.Faces

local KEY_SIZE       = 34
local TWEEN_FILL_OUT = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ── Every prompt in one style ─────────────────────────────────────────────────

local function makeCustom(inst: Instance)
	if inst:IsA("ProximityPrompt") then
		inst.Style = Enum.ProximityPromptStyle.Custom
	end
end
for _, inst in ipairs(Workspace:GetDescendants()) do makeCustom(inst) end
Workspace.DescendantAdded:Connect(makeCustom)

-- ── Drawing one prompt ────────────────────────────────────────────────────────

local function keyText(prompt: ProximityPrompt): string
	local name = prompt.KeyboardKeyCode.Name
	return if #name <= 2 then name else string.sub(name, 1, 3)
end

-- Sets how much of the key is filled (0–1, from the bottom).
local function setFill(gradient: UIGradient, amount: number)
	if amount <= 0.001 then
		gradient.Transparency = NumberSequence.new(1)
	elseif amount >= 0.999 then
		gradient.Transparency = NumberSequence.new(0)
	else
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(amount, 0),
			NumberSequenceKeypoint.new(math.min(amount + 0.001, 0.999), 1),
			NumberSequenceKeypoint.new(1, 1),
		})
	end
end

local function createPromptUI(prompt: ProximityPrompt): (BillboardGui, TextButton, NumberValue)
	local tone = prompt:GetAttribute("Tone")
	local keyColor = if tone == "money" then C.Amber elseif tone == "done" then C.Done else C.GlassText
	local fillColor = if tone == "done" then C.Amber else C.Done

	local billboard       = Instance.new("BillboardGui")
	billboard.Name        = "CustomPrompt"
	billboard.AlwaysOnTop = true
	billboard.Size        = UDim2.new(0, 280, 0, 52)
	billboard.Adornee     = prompt.Parent :: any -- the part (or attachment) the prompt is in
	-- No distance limit: a BillboardGui's MaxDistance is measured from the
	-- CAMERA; Roblox already only shows the prompt when the character is
	-- in range (PromptShown/PromptHidden).
	billboard.MaxDistance = math.huge
	billboard.Active      = true
	billboard.Parent      = playerGui

	-- The pill (sized to its text)
	local pill            = Instance.new("Frame")
	pill.AnchorPoint      = Vector2.new(0.5, 0.5)
	pill.Position         = UDim2.new(0.5, 0, 0.5, 0)
	pill.Size             = UDim2.new(0, 0, 0, 46)
	pill.AutomaticSize    = Enum.AutomaticSize.X
	pill.Parent           = billboard
	UITheme.Glass(pill, UITheme.Radius.Pill)
	if tone == "money" then
		local stroke = pill:FindFirstChildOfClass("UIStroke")
		if stroke then stroke.Color, stroke.Transparency = C.Amber, 0.6 end
	end
	local pad = UITheme.Pad(pill, 6)
	pad.PaddingRight = UDim.new(0, 16)
	UITheme.List(pill, 10, true)

	-- Round key with its hold fill
	local key            = Instance.new("Frame")
	key.Size             = UDim2.new(0, KEY_SIZE, 0, KEY_SIZE)
	key.BackgroundColor3 = keyColor
	key.BorderSizePixel  = 0
	key.LayoutOrder      = 1
	key.Parent           = pill
	UITheme.Corner(key, UITheme.Radius.Pill)

	local fillDisc            = Instance.new("Frame")
	fillDisc.Size             = UDim2.fromScale(1, 1)
	fillDisc.BackgroundColor3 = fillColor
	fillDisc.BorderSizePixel  = 0
	fillDisc.ZIndex           = 2
	fillDisc.Parent           = key
	UITheme.Corner(fillDisc, UITheme.Radius.Pill)
	local gradient    = Instance.new("UIGradient")
	gradient.Rotation = -90 -- fills from the bottom up
	gradient.Parent   = fillDisc
	setFill(gradient, 0)

	local keyLabel = UITheme.Text(key, keyText(prompt), FF.MonoB, 15, C.Glass)
	keyLabel.Size = UDim2.fromScale(1, 1)
	keyLabel.TextXAlignment = Enum.TextXAlignment.Center
	keyLabel.ZIndex = 3

	-- Action + object
	local words                  = Instance.new("Frame")
	words.Size                   = UDim2.new(0, 0, 0, KEY_SIZE)
	words.AutomaticSize          = Enum.AutomaticSize.X
	words.BackgroundTransparency = 1
	words.LayoutOrder            = 2
	words.Parent                 = pill
	local wordsList = UITheme.List(words, 0)
	wordsList.VerticalAlignment = Enum.VerticalAlignment.Center

	local action = UITheme.Text(words, prompt.ActionText, FF.Bold, 15, C.GlassText)
	action.Size = UDim2.new(0, 0, 0, 18)
	action.AutomaticSize = Enum.AutomaticSize.X
	action.LayoutOrder = 1

	if prompt.ObjectText ~= "" then
		local object = UITheme.Text(words, prompt.ObjectText, FF.Body, 12, C.GlassMuted)
		object.Size = UDim2.new(0, 0, 0, 15)
		object.AutomaticSize = Enum.AutomaticSize.X
		object.LayoutOrder = 2
	end

	-- Clickable overlay (outside the pill's layout)
	local button                  = Instance.new("TextButton")
	button.Size                   = UDim2.fromScale(1, 1)
	button.BackgroundTransparency = 1
	button.Text                   = ""
	button.ZIndex                 = 5
	button.Parent                 = billboard

	-- Hold progress, 0–1, drives the gradient
	local progress = Instance.new("NumberValue")
	progress.Parent = billboard
	progress.Changed:Connect(function(value: number)
		setFill(gradient, value)
	end)

	return billboard, button, progress
end

-- ── Showing / hiding ──────────────────────────────────────────────────────────

ProximityPromptService.PromptShown:Connect(function(prompt)
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then return end

	local gui, btn, progress = createPromptUI(prompt)
	local holdTween: Tween? = nil
	local mouseDown   = false -- this prompt is being held with the mouse
	local connections = {}

	local function resetFill()
		if holdTween then
			holdTween:Cancel()
			holdTween = nil
		end
		TweenService:Create(progress, TWEEN_FILL_OUT, { Value = 0 }):Play()
	end

	-- Mouse: drive the prompt the way Roblox expects for custom prompts.
	local function mouseRelease()
		if not mouseDown then return end
		mouseDown = false
		prompt:InputHoldEnd()
	end

	table.insert(connections, btn.MouseButton1Down:Connect(function()
		if mouseDown or not prompt.Enabled then return end
		mouseDown = true
		prompt:InputHoldBegin()
	end))
	table.insert(connections, btn.MouseButton1Up:Connect(mouseRelease))
	table.insert(connections, btn.MouseLeave:Connect(mouseRelease))

	-- Fill animation, for both key and mouse holds (Roblox fires these for
	-- prompts with a HoldDuration above 0).
	table.insert(connections, prompt.PromptButtonHoldBegan:Connect(function()
		if holdTween then holdTween:Cancel() end
		progress.Value = 0
		local tween = TweenService:Create(progress,
			TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear), { Value = 1 })
		holdTween = tween
		tween:Play()
	end))
	table.insert(connections, prompt.PromptButtonHoldEnded:Connect(resetFill))
	table.insert(connections, prompt.Triggered:Connect(resetFill))

	-- Cleanup when the prompt goes away (walked off, disabled, destroyed).
	table.insert(connections, prompt.PromptHidden:Connect(function()
		mouseRelease()
		for _, c in ipairs(connections) do c:Disconnect() end
		table.clear(connections)
		gui:Destroy()
	end))
end)
