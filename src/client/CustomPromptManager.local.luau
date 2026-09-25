--[[
    CustomPromptManager (LocalScript)
    ----------------------------------
    What it is: Custom UI system for ProximityPrompts.
    
    Fixed: Unnested functions from resetFill() and resolved syntax closures.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService           = game:GetService("TweenService")
local UserInputService       = game:GetService("UserInputService")
local Players                = game:GetService("Players")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local COLORS = {
	Main   = Color3.fromRGB(255, 255, 255),
	Accent = Color3.fromRGB(0, 255, 150),
	Text   = Color3.fromRGB(255, 255, 255),
	Dark   = Color3.fromRGB(20, 20, 20),
}

local TWEEN_FILL_OUT = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function createPromptUI(prompt)
	local billboard = Instance.new("BillboardGui")
	billboard.Name        = "CustomPrompt"
	billboard.AlwaysOnTop = true
	billboard.Size        = UDim2.new(0, 250, 0, 80)
	billboard.Adornee     = prompt.Parent
	billboard.MaxDistance = prompt.MaxActivationDistance or 15
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
	Instance.new("UICorner", keyFrame).CornerRadius = UDim.new(0, 6)

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
	Instance.new("UICorner", keyFill).CornerRadius = UDim.new(0, 6)

	-- Key label
	local keyLabel = Instance.new("TextLabel")
	keyLabel.Size                  = UDim2.new(1, 0, 1, 0)
	keyLabel.BackgroundTransparency = 1
	keyLabel.Font                  = Enum.Font.GothamBold
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
	actionLabel.Font             = Enum.Font.RobotoMono
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
	local holdTween    = nil
	local holding      = false
	local holdThread   = nil
	local connections  = {}

	local function disconnectAll()
		for _, c in ipairs(connections) do c:Disconnect() end
		table.clear(connections)
	end

	local function resetFill()
		if holdTween then
			holdTween:Cancel()
			holdTween = nil
		end
		if holdThread then
			task.cancel(holdThread)
			holdThread = nil
		end
		holding = false
		local resetTween = TweenService:Create(keyFill, TWEEN_FILL_OUT, { Size = UDim2.new(1, 0, 0, 0) })
		resetTween:Play()
	end

	local function beginHold()
		if holding then return end
		holding = true

		-- Animate fill
		if holdTween then holdTween:Cancel() end
		local info = TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear)
		holdTween = TweenService:Create(keyFill, info, { Size = UDim2.new(1, 0, 1, 0) })
		holdTween:Play()

		-- Safely handle instant clicks vs duration holds
		if prompt.HoldDuration <= 0 then
			prompt:InputHoldEnd()
			resetFill()
		else
			holdThread = task.delay(prompt.HoldDuration, function()
				if holding then
					prompt:InputHoldEnd()
					resetFill()
				end
			end)
		end
	end

	local function endHold()
		if not holding then return end
		resetFill()
	end

	-- Mouse click / hold support
	table.insert(connections, btn.MouseButton1Down:Connect(beginHold))
	table.insert(connections, btn.MouseButton1Up:Connect(endHold))

	-- Keyboard hold support via existing prompt events
	table.insert(connections, prompt.PromptButtonHoldBegan:Connect(function()
		if holdTween then holdTween:Cancel() end
		local info = TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear)
		holdTween = TweenService:Create(keyFill, info, { Size = UDim2.new(1, 0, 1, 0) })
		holdTween:Play()
	end))

	table.insert(connections, prompt.PromptButtonHoldEnded:Connect(function()
		resetFill()
	end))

	-- Cleanup on hide
	table.insert(connections, prompt.PromptHidden:Connect(function()
		disconnectAll()
		resetFill()
		gui:Destroy()
	end))
end)