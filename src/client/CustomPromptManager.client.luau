--!strict
--[[
    CustomPromptManager (LocalScript)
    ---------------------------------
    Draws every ProximityPrompt whose Style is Custom: a key tile with a
    fill that shows hold progress, and the action text beside it.

    Works with keyboard and mouse:
    - Pressing the prompt's key is handled by Roblox itself; this only
      animates the fill from the prompt's own hold events.
    - Clicking the drawn prompt calls InputHoldBegin on press and
      InputHoldEnd on release (or when the mouse leaves it), which is how
      Roblox expects a custom prompt to be driven — Roblox then applies
      HoldDuration and fires Triggered itself.

    Used by: the dropped-part Pick Up prompt (F) and any other prompt set
    to the Custom style.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService           = game:GetService("TweenService")
local Players                = game:GetService("Players")
local ReplicatedStorage      = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UI"):WaitForChild("UITheme"))
local F       = UITheme.Fonts

local COLORS = {
	Main   = UITheme.Colors.Text,
	Accent = UITheme.Colors.Accent,
	Text   = UITheme.Colors.Text,
	Dark   = UITheme.Colors.Dark,
}

local TWEEN_FILL_OUT = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function createPromptUI(prompt)
	local billboard = Instance.new("BillboardGui")
	billboard.Name        = "CustomPrompt"
	billboard.AlwaysOnTop = true
	billboard.Size        = UDim2.new(0, 250, 0, 80)
	billboard.Adornee     = prompt.Parent
	-- No distance limit here: a BillboardGui's MaxDistance is measured from
	-- the CAMERA, so using the prompt's (character-based) reach hid prompts
	-- whenever the camera sat further back than that. Roblox already only
	-- shows the prompt (PromptShown/PromptHidden) when the character is
	-- in range.
	billboard.MaxDistance = math.huge
	billboard.Active      = true
	billboard.Parent      = playerGui

	local mainFrame = Instance.new("Frame")
	mainFrame.Name                  = "MainFrame"
	mainFrame.Size                  = UDim2.new(1, 0, 1, 0)
	mainFrame.BackgroundTransparency = 1
	mainFrame.Parent                = billboard

	-- Key icon background
	local keyFrame = Instance.new("Frame")
	keyFrame.Name                  = "KeyFrame"
	keyFrame.Size                  = UDim2.new(0, 45, 0, 45)
	keyFrame.Position              = UDim2.new(0, 10, 0.5, -22)
	keyFrame.BackgroundColor3      = COLORS.Main
	keyFrame.BackgroundTransparency = 0.1
	keyFrame.Parent                = mainFrame
	UITheme.Corner(keyFrame, UITheme.Radius.Large)

	-- Hold progress fill
	local keyFill = Instance.new("Frame")
	keyFill.Name                  = "KeyFill"
	keyFill.Size                  = UDim2.new(1, 0, 0, 0)
	keyFill.Position              = UDim2.new(0, 0, 1, 0)
	keyFill.AnchorPoint           = Vector2.new(0, 1)
	keyFill.BackgroundColor3      = COLORS.Accent
	keyFill.BackgroundTransparency = 0.3
	keyFill.BorderSizePixel       = 0
	keyFill.ZIndex                = 2
	keyFill.Parent                = keyFrame
	UITheme.Corner(keyFill, UITheme.Radius.Large)

	-- Key label
	local keyLabel = Instance.new("TextLabel")
	keyLabel.Size                  = UDim2.new(1, 0, 1, 0)
	keyLabel.BackgroundTransparency = 1
	keyLabel.Font                  = F.Bold
	keyLabel.TextColor3            = COLORS.Dark
	keyLabel.TextSize              = 22
	keyLabel.Text                  = prompt.KeyboardKeyCode.Name
	keyLabel.ZIndex                = 3
	keyLabel.Parent                = keyFrame

	-- Clickable overlay
	local actionButton = Instance.new("TextButton")
	actionButton.Name                  = "ActionButton"
	actionButton.Size                  = UDim2.new(1, 0, 1, 0)
	actionButton.BackgroundTransparency = 1
	actionButton.Text                  = ""
	actionButton.ZIndex                = 4
	actionButton.Parent                = mainFrame

	-- Action text
	local actionLabel = Instance.new("TextLabel")
	actionLabel.Size             = UDim2.new(0, 150, 1, 0)
	actionLabel.Position         = UDim2.new(0, 80, 0, 0)
	actionLabel.BackgroundTransparency = 1
	actionLabel.Font             = F.Mono
	actionLabel.Text             = prompt.ActionText:upper()
	actionLabel.TextColor3       = COLORS.Text
	actionLabel.TextSize         = 18
	actionLabel.TextXAlignment   = Enum.TextXAlignment.Left
	actionLabel.Parent           = mainFrame

	-- Separator
	local separator = Instance.new("Frame")
	separator.Size                  = UDim2.new(0, 2, 0.4, 0)
	separator.Position              = UDim2.new(0, 65, 0.3, 0)
	separator.BackgroundColor3      = COLORS.Main
	separator.BackgroundTransparency = 0.5
	separator.Parent                = mainFrame

	return billboard, actionButton, keyFill
end

ProximityPromptService.PromptShown:Connect(function(prompt)
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then return end

	local gui, btn, keyFill = createPromptUI(prompt)
	local holdTween: Tween? = nil
	local mouseDown   = false -- this prompt is being held with the mouse
	local connections = {}

	local function resetFill()
		if holdTween then
			holdTween:Cancel()
			holdTween = nil
		end
		TweenService:Create(keyFill, TWEEN_FILL_OUT, { Size = UDim2.new(1, 0, 0, 0) }):Play()
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
		local tween = TweenService:Create(keyFill,
			TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear),
			{ Size = UDim2.new(1, 0, 1, 0) })
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
