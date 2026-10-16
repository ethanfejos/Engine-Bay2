--!strict
--[[
    DroppedPartEffect (LocalScript)
    -------------------------------
    Client side of dropped parts in Workspace.DroppedParts (made by the
    server's PartPickupService):

    1. Who sees the Pick Up prompt. Only the part's owner (the drop's
       OwnerUserId attribute), and not while in engine view — so other
       players never see a prompt that does nothing for them, and the F
       prompt can't get in the way of engine view controls. The server
       still checks the owner on pickup.

    2. A gentle resting bounce, purely visual and local. Each client lifts
       the model a little above its real (server-placed) resting CFrame;
       safe because drops are anchored and the server never moves them
       again. It's a straight vertical lift (never below the resting
       height), and only for drops within ANIMATE_DISTANCE of the camera —
       drops further away rest still and cost nothing.
]]

local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player        = Players.LocalPlayer
local droppedFolder = Workspace:WaitForChild("DroppedParts")

local Modules       = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local EngineContext = require(Modules:WaitForChild("EngineContext"))

-- ── Config ────────────────────────────────────────────────────────────────────

local BOUNCE_HEIGHT    = 0.18  -- studs, peak height of the bounce
local BOUNCE_SPEED     = 2.2   -- radians/sec
local ANIMATE_DISTANCE = 60    -- studs from the camera

-- ── Prompt visibility ─────────────────────────────────────────────────────────

-- A drop with no owner tag is treated as visible to everyone, so a missing
-- attribute can never hide a prompt (the server still checks the owner).
local function isMine(model)
	local owner = model:GetAttribute("OwnerUserId")
	return owner == nil or owner == player.UserId
end

local function updatePrompt(model)
	local trigger = model:FindFirstChild("PickupTrigger")
	local prompt  = trigger and trigger:FindFirstChildWhichIsA("ProximityPrompt")
	if prompt then
		prompt.Enabled = isMine(model) and not EngineContext.IsInEngineView()
	end
end

-- ── Tracking ──────────────────────────────────────────────────────────────────

-- [model] = { baseCFrame, phase, lifted }
local tracked = {}

local function trackModel(model)
	if not model:IsA("Model") or tracked[model] then return end

	tracked[model] = {
		baseCFrame = model:GetPivot(),
		phase      = math.random() * math.pi * 2, -- so drops don't bob in sync
		lifted     = false,
	}

	-- The trigger/prompt may replicate a moment after the model itself.
	updatePrompt(model)
	model.DescendantAdded:Connect(function(desc)
		if desc:IsA("ProximityPrompt") then
			updatePrompt(model)
		end
	end)
	model:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		updatePrompt(model)
	end)

	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			tracked[model] = nil
		end
	end)
end

for _, model in ipairs(droppedFolder:GetChildren()) do
	trackModel(model)
end
droppedFolder.ChildAdded:Connect(trackModel)

EngineContext.OnViewChanged(function()
	for model in pairs(tracked) do
		if model.Parent then
			updatePrompt(model)
		end
	end
end)

-- ── Animate ───────────────────────────────────────────────────────────────────

RunService.Heartbeat:Connect(function()
	local t      = os.clock()
	local camPos = Workspace.CurrentCamera.CFrame.Position

	for model, data in pairs(tracked) do
		if not model.Parent then
			tracked[model] = nil
			continue
		end

		local near = (data.baseCFrame.Position - camPos).Magnitude <= ANIMATE_DISTANCE
		if near then
			-- abs() so it only ever lifts above the real resting height.
			local bounce = math.abs(math.sin(t * BOUNCE_SPEED + data.phase)) * BOUNCE_HEIGHT
			model:PivotTo(data.baseCFrame + Vector3.new(0, bounce, 0))
			data.lifted = true
		elseif data.lifted then
			-- Out of range: settle back on the floor once, then leave it alone.
			model:PivotTo(data.baseCFrame)
			data.lifted = false
		end
	end
end)
