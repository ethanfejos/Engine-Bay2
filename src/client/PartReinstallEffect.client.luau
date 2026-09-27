--[[
    PartReinstallEffect (LocalScript)
    ----------------------------------
    Plays a float-down and fade-in animation when the local player reinstalls
    a part. Reverse of the removal float animation.

    Triggered by PartReinstalled RemoteEvent from InventoryService.

    Place in: StarterPlayerScripts
]]

local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local partReinstalledEvent = ReplicatedStorage
	:WaitForChild("RemoteEvents")
	:WaitForChild("PartReinstalled")

-- ── Config ────────────────────────────────────────────────────────────────────

local FLOAT_HEIGHT = 1.5   -- studs above final position to start from
local DURATION     = 0.6
local TWEEN_INFO   = TweenInfo.new(DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ── Effect ────────────────────────────────────────────────────────────────────

local function playReinstallEffect(model)
	if not model or not model.Parent then return end

	local parts = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	if #parts == 0 then return end

	-- Store final positions then offset upward to start
	local finalCFrames = {}
	for _, part in ipairs(parts) do
		finalCFrames[part] = part.CFrame
		part.CFrame        = part.CFrame + Vector3.new(0, FLOAT_HEIGHT, 0)
		part.Transparency  = 1
		part.Anchored      = true
		part.CanCollide    = false
		part.CanQuery      = false
	end

	-- Small delay so the part is visible before animation starts
	task.wait(0.05)

	-- Tween down to final position and fade in
	for _, part in ipairs(parts) do
		if not part.Parent then continue end
		TweenService:Create(part, TWEEN_INFO, {
			CFrame       = finalCFrames[part],
			Transparency = 0,
		}):Play()
	end

	-- Restore physics after animation
	task.delay(DURATION + 0.1, function()
		for _, part in ipairs(parts) do
			if part and part.Parent then
				part.CanCollide = true
				part.CanQuery   = true
				-- Leave anchored — engine parts should stay anchored
			end
		end
	end)

	-- Fade in decals/textures
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("Decal") or desc:IsA("Texture") then
			desc.Transparency = 1
			TweenService:Create(desc, TWEEN_INFO, { Transparency = 0 }):Play()
		end
	end
end

-- ── Event ─────────────────────────────────────────────────────────────────────

partReinstalledEvent.OnClientEvent:Connect(function(model)
	if not model then return end
	playReinstallEffect(model)
end)