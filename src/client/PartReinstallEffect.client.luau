--!strict
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

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Remotes"))
local partReinstalledEvent = Remotes.PartReinstalled

-- ── Config ────────────────────────────────────────────────────────────────────

local FLOAT_HEIGHT = 1.5   -- studs above final position to start from
local DURATION     = 0.6
local TWEEN_INFO   = TweenInfo.new(DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ── Effect ────────────────────────────────────────────────────────────────────

local function playReinstallEffect(model: Instance)
	if not model or not model.Parent then return end

	local parts: { BasePart } = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	if #parts == 0 then return end

	-- Remember each part exactly as the server set it (welded and unanchored
	-- on a drivable car, maybe invisible for hitboxes), so it can be put
	-- back afterwards. Only this client's copy is changed for the animation.
	type Saved = { cframe: CFrame, transparency: number, anchored: boolean, canCollide: boolean, canQuery: boolean }
	local saved: { [BasePart]: Saved } = {}
	for _, part in ipairs(parts) do
		saved[part] = {
			cframe       = part.CFrame,
			transparency = part.Transparency,
			anchored     = part.Anchored,
			canCollide   = part.CanCollide,
			canQuery     = part.CanQuery,
		}
		part.Anchored     = true -- held still locally while it floats down
		part.CanCollide   = false
		part.CanQuery     = false
		part.CFrame       = part.CFrame + Vector3.new(0, FLOAT_HEIGHT, 0)
		part.Transparency = 1
	end

	-- Small delay so the part is visible before animation starts
	task.wait(0.05)

	-- Float down to its place and fade in to its own transparency
	for _, part in ipairs(parts) do
		if not part.Parent then continue end
		local s = saved[part]
		TweenService:Create(part, TWEEN_INFO, {
			CFrame       = s.cframe,
			Transparency = s.transparency,
		}):Play()
	end

	-- Fade in decals/textures to their own transparency
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("Decal") then -- Textures are Decals too
			local target = desc.Transparency
			desc.Transparency = 1
			TweenService:Create(desc, TWEEN_INFO, { Transparency = target }):Play()
		end
	end

	-- Hand the part back to physics exactly as the server set it, so a
	-- welded part moves with the car again.
	task.delay(DURATION + 0.1, function()
		for part, s in pairs(saved) do
			if part.Parent then
				part.Anchored   = s.anchored
				part.CanCollide = s.canCollide
				part.CanQuery   = s.canQuery
			end
		end
	end)
end

-- ── Event ─────────────────────────────────────────────────────────────────────

partReinstalledEvent.OnClientEvent:Connect(function(model)
	if not model then return end
	playReinstallEffect(model)
end)