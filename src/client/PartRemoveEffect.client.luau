--[[
    PartRemoveEffect (LocalScript)
    ------------------------------
    Plays removal animations when the local player removes a part.
    
    Regular parts: float up and fade out
    Bolts: spin 3 rotations on local Y axis, then pull out along local Y and fade

    Triggered by PartRemoving RemoteEvent from EngineServer.

    Place in: StarterPlayerScripts
]]

local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local partRemovingEvent = ReplicatedStorage
	:WaitForChild("RemoteEvents")
	:WaitForChild("PartRemoving")

-- ── Config ────────────────────────────────────────────────────────────────────

local FLOAT_HEIGHT    = 1.5
local FLOAT_DURATION  = 0.6
local BOLT_SPIN_ROTS  = 3        -- full rotations
local BOLT_SPIN_TIME  = 1.2      -- seconds for spin (increase to slow down)
local BOLT_PULL_DIST  = 0.6      -- studs to pull out along shaft axis
local BOLT_PULL_TIME  = 1.2      -- matches spin so they finish together

-- ── Regular Part — Float Up & Fade ────────────────────────────────────────────

local function playFloatEffect(model)
	if not model or not model.Parent then return end

	local parts = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	if model:IsA("BasePart") then
		table.insert(parts, model)
	end
	if #parts == 0 then return end

	-- Anchor all parts
	for _, part in ipairs(parts) do
		part.Anchored   = true
		part.CanCollide = false
		part.CanQuery   = false
		part.CanTouch   = false
	end

	local tweenInfo = TweenInfo.new(FLOAT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	for _, part in ipairs(parts) do
		local targetCFrame = part.CFrame + Vector3.new(0, FLOAT_HEIGHT, 0)
		TweenService:Create(part, tweenInfo, {
			CFrame       = targetCFrame,
			Transparency = 1,
		}):Play()
	end

	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("Decal") or desc:IsA("Texture") then
			TweenService:Create(desc, tweenInfo, { Transparency = 1 }):Play()
		end
	end
end

-- ── Bolt — Spin Then Pull ─────────────────────────────────────────────────────

local function getBoltShaftAxis(model)
	local cf, size = model:GetBoundingBox()
	if size.X >= size.Y and size.X >= size.Z then
		return cf.RightVector
	elseif size.Y >= size.X and size.Y >= size.Z then
		return cf.UpVector
	else
		return cf.LookVector
	end
end

local function playBoltEffect(model)
	if not model or not model.Parent then return end

	-- Find the primary bolt mesh
	local primaryPart = model.PrimaryPart
		or model:FindFirstChildWhichIsA("BasePart")
	if not primaryPart then return end

	local parts = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end

	-- Anchor all
	for _, part in ipairs(parts) do
		part.Anchored   = true
		part.CanCollide = false
		part.CanQuery   = false
		part.CanTouch   = false
	end

	-- Phase 1: Spin around local Y axis using RenderStepped
	local shaftAxis   = getBoltShaftAxis(model)
	local spinTotal   = math.rad(360 * BOLT_SPIN_ROTS)
	local elapsed     = 0
	local originCF    = model:GetPivot()
	local originPositions = {}
	for _, part in ipairs(parts) do
		originPositions[part] = part.CFrame
	end
	local spinConn

	spinConn = RunService.RenderStepped:Connect(function(dt)
		elapsed = elapsed + dt
		local t = math.clamp(elapsed / BOLT_SPIN_TIME, 0, 1)

		local ease = t < 0.5
			and 2 * t * t
			or 1 - (-2 * t + 2) ^ 2 / 2

		-- Spin around shaft axis
		local angle    = spinTotal * ease
		local rotation = CFrame.fromAxisAngle(shaftAxis, angle)
		local pivot    = originCF.Position

		-- Pull in OPPOSITE direction of shaft axis simultaneously
		local pullOffset = -shaftAxis * (BOLT_PULL_DIST * ease)

		model:PivotTo(
			CFrame.new(pivot + pullOffset) *
				(rotation * (originCF - pivot))
		)

		-- Fade out as animation progresses
		local transparency = ease
		for _, part in ipairs(parts) do
			part.Transparency = transparency
		end

		if t >= 1 then
			spinConn:Disconnect()
		end
	end)
end

-- ── Event Handler ─────────────────────────────────────────────────────────────

partRemovingEvent.OnClientEvent:Connect(function(model)
	if not model then return end

	if model:GetAttribute("IsBolt") then
		playBoltEffect(model)
	else
		playFloatEffect(model)
	end
end)