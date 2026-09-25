--[[
    WearDisplay (ModuleScript)
    --------------------------
    Drives wear label, bar fill and distance fade.
    Only activates after inspection is complete.
    Bar animates from 0 to wear value on first show.
]]

local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")

local WearDisplay = {}

local FADE_SPEED      = 5
local MIN_DIST        = 3
local MAX_DIST        = 16
local PULSE_THRESHOLD = 30
local PULSE_SPEED     = 2 * math.pi

local function wearColor(w)
	w = math.clamp(w or 100, 0, 100) / 100
	if w <= 0.5 then
		return Color3.new(1, w / 0.5, 0)
	else
		return Color3.new(1 - (w - 0.5) / 0.5, 1, 0)
	end
end

-- Animate bar from 0 to the wear value over 0.6s on first reveal
local function animateBarIn(labels, wear)
	local fill      = labels.barFill
	local color     = wearColor(wear)
	local target    = math.max(wear / 100, 0.02)

	fill.Size              = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3  = color

	TweenService:Create(fill,
		TweenInfo.new(0.6, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Size = UDim2.new(target, 0, 1, 0) }
	):Play()
end

function WearDisplay.Start(model, labels, part)
	local pulseTime = 0

	local conn = RunService.RenderStepped:Connect(function(delta)
		if not labels or not model or not model.Parent then return end

		local wear  = model:GetAttribute("Wear") or 100
		local color = wearColor(wear)

		-- Update wear label
		labels.wear.Text       = string.format("WEAR  %d%%", math.floor(wear))
		labels.wear.TextColor3 = color

		-- Update bar fill color smoothly
		TweenService:Create(labels.barFill,
			TweenInfo.new(0.3),
			{ BackgroundColor3 = color }
		):Play()

		-- Distance fade
		local dist      = (workspace.CurrentCamera.CFrame.Position
			- part.Position).Magnitude
		local distAlpha = math.clamp(
			(dist - MIN_DIST) / (MAX_DIST - MIN_DIST), 0, 1
		)

		-- Fade wear label
		local cur = labels.wear.TextTransparency
		labels.wear.TextTransparency = cur
			+ (distAlpha - cur) * math.clamp(delta * FADE_SPEED, 0, 1)

		-- Pulse on critical wear
		if wear <= PULSE_THRESHOLD then
			pulseTime = pulseTime
				+ delta * PULSE_SPEED * (1 - wear / PULSE_THRESHOLD)
			local pulse = (math.sin(pulseTime) + 1) / 2 * 0.5
			labels.wear.TextTransparency = math.clamp(
				distAlpha - pulse, 0, 1
			)
		end
	end)

	-- Animate bar in on start
	local wear = model:GetAttribute("Wear") or 100
	animateBarIn(labels, wear)

	return conn
end

return WearDisplay