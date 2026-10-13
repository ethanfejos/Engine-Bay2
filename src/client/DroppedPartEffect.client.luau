--[[
    DroppedPartEffect (LocalScript)
    --------------------------------
    Two cosmetic/UX jobs for dropped parts in Workspace.DroppedParts (see
    PartPickupService):

    1. A gentle resting bounce — purely visual, local-only. Each client
       nudges the model's CFrame on top of its real (server-authoritative)
       resting CFrame every frame. That's safe here because dropped parts
       are Anchored and the server never touches their CFrame again after
       placing them, so there's nothing for this to fight or desync with.
       The bounce is a straight world-space vertical offset (not rotated
       with the part), so a part resting tipped on its side still bounces
       straight up/down instead of sliding along its own tilted axis — and
       it never goes below the part's real resting height, so it can't
       look like it's sinking into the ground.

    2. Disabling each drop's "Pick Up" ProximityPrompt while the local
       player is in engine view. That prompt's default activation key is
       E — the same key EngineCameraController uses to exit engine view —
       so if a prompt was left enabled and in range, pressing E to leave
       got consumed by the prompt instead (see EngineCameraController's
       own EngineTrigger-prompt handling for the same conflict).

    Place in: StarterPlayerScripts
]]

local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local droppedFolder = Workspace:WaitForChild("DroppedParts")

local Modules       = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local EngineContext = require(Modules:WaitForChild("EngineContext"))

-- ── Config ────────────────────────────────────────────────────────────────────

local BOUNCE_HEIGHT = 0.18   -- studs, peak height of the bounce
local BOUNCE_SPEED   = 2.2   -- radians/sec

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function setPromptEnabled(model, enabled)
	local trigger = model:FindFirstChild("PickupTrigger")
	local prompt  = trigger and trigger:FindFirstChildWhichIsA("ProximityPrompt")
	if prompt then
		prompt.Enabled = enabled
	end
end

-- ── Tracking ──────────────────────────────────────────────────────────────────

-- [model] = { baseCFrame, phase }
local tracked = {}

local function trackModel(model)
	if not model:IsA("Model") then return end

	local ok, baseCFrame = pcall(function()
		return model:GetPivot()
	end)
	if not ok then return end

	tracked[model] = {
		baseCFrame = baseCFrame,
		phase      = math.random() * math.pi * 2, -- offsets the bounce so parts don't bob in sync
	}

	-- A part can be dropped while the player is already in engine view
	-- (parts are removed from inside it) — start it in the matching state
	-- rather than waiting for the next view-change event.
	setPromptEnabled(model, not EngineContext.IsInEngineView())

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

EngineContext.OnViewChanged(function(inView)
	for model in pairs(tracked) do
		if model.Parent then
			setPromptEnabled(model, not inView)
		end
	end
end)

-- ── Animate ───────────────────────────────────────────────────────────────────

RunService.Heartbeat:Connect(function()
	local t = os.clock()
	for model, data in pairs(tracked) do
		if model.Parent then
			-- abs() so this only ever lifts the part above its real resting
			-- CFrame, never below it.
			local bounce = math.abs(math.sin(t * BOUNCE_SPEED + data.phase)) * BOUNCE_HEIGHT
			model:PivotTo(data.baseCFrame + Vector3.new(0, bounce, 0))
		else
			tracked[model] = nil
		end
	end
end)
