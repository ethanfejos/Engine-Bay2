--[[
    DroppedPartEffect (LocalScript)
    --------------------------------
    Purely cosmetic "sitting on the ground" animation for dropped parts in
    Workspace.DroppedParts (see PartPickupService) — a slow up/down bob plus
    a lazy spin, like a Minecraft dropped item, so a pile of parts doesn't
    look like a row of static props.

    This is local-only: each client nudges the model's CFrame on top of its
    real (server-authoritative) resting CFrame every frame. That's safe here
    because dropped parts are Anchored and the server never touches their
    CFrame again after placing them, so there's nothing for this to fight
    with or desync from — if the part gets destroyed (collected), it's just
    dropped from tracking.

    Place in: StarterPlayerScripts
]]

local Workspace  = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local droppedFolder = Workspace:WaitForChild("DroppedParts")

-- ── Config ────────────────────────────────────────────────────────────────────

local BOB_HEIGHT = 0.25   -- studs, peak height of the up/down bob
local BOB_SPEED  = 2.0    -- radians/sec

-- Spin is deliberately slow — this is a resting-on-the-ground flourish, not
-- a fast tumble.
local SPIN_SPEED = math.rad(35) -- radians/sec

-- ── Tracking ──────────────────────────────────────────────────────────────────

-- [model] = { baseCFrame, phase, spinDir }
local tracked = {}

local function trackModel(model)
	if not model:IsA("Model") then return end

	local ok, baseCFrame = pcall(function()
		return model:GetPivot()
	end)
	if not ok then return end

	tracked[model] = {
		baseCFrame = baseCFrame,
		phase      = math.random() * math.pi * 2, -- offsets the bob so parts don't bounce in sync
		spinDir    = (math.random(0, 1) == 0) and 1 or -1,
	}

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

-- ── Animate ───────────────────────────────────────────────────────────────────

RunService.Heartbeat:Connect(function()
	local t = os.clock()
	for model, data in pairs(tracked) do
		if model.Parent then
			local bob   = math.sin(t * BOB_SPEED + data.phase) * BOB_HEIGHT
			local spin  = t * SPIN_SPEED * data.spinDir
			local offset = CFrame.new(0, bob, 0) * CFrame.Angles(0, spin, 0)
			model:PivotTo(data.baseCFrame * offset)
		else
			tracked[model] = nil
		end
	end
end)
