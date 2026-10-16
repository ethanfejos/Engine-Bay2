--!strict
--[[
    EnginePrompts (ModuleScript, client)
    ------------------------------------
    Finds every engine in the workspace and wires its "enter engine bay"
    prompt. An engine is any Model with an "EngineTrigger" child holding a
    ProximityPrompt — wherever it is (inside a car, on a stand, ...).

        EnginePrompts.Start(onEnter)   -- onEnter(engine, prompt)
        EnginePrompts.SetViewing(engine or nil)

    A prompt is enabled only when:
    - its engine is parked inside a zone, and
    - that engine isn't the one being viewed — its key (E) is the same as
      the exit key, and an enabled prompt would swallow the exit press.

    Those are re-checked for all engines together every CHECK_INTERVAL
    seconds (before the split, every engine ran its own zone lookup every
    frame), and straight away when the viewed engine changes.

    onEnter is only called when the player is standing in the same zone as
    the engine and the engine is visible.

    Cars and owners (CarService / CarUtils): the prompt only shows on YOUR
    car, or as "Claim car" on a car nobody owns while you don't own one yet.
    Claiming fires ClaimCar; once the server sets you as the owner, the
    same prompt turns back into the normal engine-bay prompt.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Modules   = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local ZoneUtils = require(Modules:WaitForChild("ZoneUtils"))
local CarUtils  = require(Modules:WaitForChild("CarUtils"))
local Remotes   = require(Modules:WaitForChild("Remotes"))
local Log       = require(Modules:WaitForChild("Log"))

local log    = Log.new("EnginePrompts")
local player = Players.LocalPlayer

local CHECK_INTERVAL = 0.25 -- seconds; how quickly a prompt appears once a car is parked or claimed
local CLAIM_TEXT     = "Claim car"

-- ── State ─────────────────────────────────────────────────────────────────────

type OnEnter = (engine: Model, prompt: ProximityPrompt) -> ()

-- [engine] = its prompt once wired; false while wire() is still waiting for it
local wired: { [Instance]: ProximityPrompt | false } = {}
local viewingEngine: Model?     = nil
local onEnterCallback: OnEnter? = nil

-- Each prompt's own ActionText from the place file, restored after "Claim car".
local actionTexts: { [ProximityPrompt]: string } = {}

-- ── Checks ────────────────────────────────────────────────────────────────────

-- Some engine models use an invisible anchor/hitbox part as their
-- PrimaryPart, so instead of trusting one part: is ANY part visible? Uses
-- Transparency (the authored value), not LocalTransparencyModifier, which
-- other scripts change locally.
local function isModelVisible(model: Model): boolean
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency < 0.9 then
			return true
		end
	end
	return false
end

-- What this engine's prompt does for you: "enter" (your car), "claim"
-- (nobody's car, and you don't have one yet), or nil (someone else's car,
-- or you already own a different one) — hidden.
type Mode = "enter" | "claim"
local function promptMode(engine: Model): Mode?
	local owner = CarUtils.GetOwnerUserId(engine)
	if owner == player.UserId then return "enter" end
	if owner == nil and CarUtils.FindCarOwnedBy(player.UserId) == nil then return "claim" end
	return nil
end

local function refresh(engine: Model, prompt: ProximityPrompt)
	local mode = promptMode(engine)
	local enabled = mode ~= nil
		and engine ~= viewingEngine
		and ZoneUtils.GetZoneForPosition(engine:GetPivot().Position) ~= nil

	local text = if mode == "claim" then CLAIM_TEXT else (actionTexts[prompt] or prompt.ActionText)
	if prompt.ActionText ~= text then
		prompt.ActionText = text
	end
	if prompt.Enabled ~= enabled then
		prompt.Enabled = enabled
	end
end

local function refreshAll()
	for engine, entry in pairs(wired) do
		if entry == false then continue end -- still being wired
		local prompt = entry :: ProximityPrompt
		if engine.Parent and prompt.Parent and engine:IsA("Model") then
			refresh(engine, prompt)
		else
			wired[engine] = nil
		end
	end
end

-- ── Wiring ────────────────────────────────────────────────────────────────────

local function wire(engine: Model)
	local trigger = engine:WaitForChild("EngineTrigger", 10)
	if not trigger then
		log.warn("No EngineTrigger under", engine:GetFullName())
		wired[engine] = nil
		return
	end

	local found = trigger:FindFirstChildWhichIsA("ProximityPrompt") or trigger:WaitForChild("ProximityPrompt", 5)
	local prompt = if found and found:IsA("ProximityPrompt") then found else nil
	if not prompt then
		log.warn("No ProximityPrompt in EngineTrigger on", engine:GetFullName())
		wired[engine] = nil
		return
	end

	wired[engine] = prompt
	actionTexts[prompt] = prompt.ActionText
	refresh(engine, prompt)
	log.debug("Wired", engine:GetFullName())

	prompt.Triggered:Connect(function()
		-- Must be standing in the zone this engine is parked in.
		local engineZone = ZoneUtils.GetZoneForPosition(engine:GetPivot().Position)
		local playerZone = ZoneUtils.GetZoneForPlayer(player)
		if not engineZone or engineZone ~= playerZone then
			log.debug("Entry blocked: not in the same zone as", engine.Name)
			return
		end
		if not isModelVisible(engine) then
			log.debug("Entry blocked: no visible part on", engine.Name)
			return
		end

		local mode = promptMode(engine)
		if mode == "claim" then
			local carId = CarUtils.GetCarId(engine)
			if carId then
				Remotes.ClaimCar:FireServer(carId)
			end
			return
		elseif mode ~= "enter" then
			log.debug("Entry blocked: not your car", engine.Name)
			return
		end

		local onEnter = onEnterCallback
		if onEnter then
			onEnter(engine, prompt)
		end
	end)
end

local function tryWire(instance: Instance)
	if wired[instance] ~= nil then return end
	if not instance:IsA("Model") then return end
	if not instance:FindFirstChild("EngineTrigger") then return end
	wired[instance] = false -- claimed; wire() fills in the prompt
	task.spawn(wire, instance)
end

-- Some chassis systems build a car up bit by bit, so an engine model can
-- appear before its EngineTrigger does. Catch that from the trigger's side.
local function tryWireTrigger(instance: Instance)
	local parent = instance.Parent
	if instance.Name == "EngineTrigger" and parent then
		tryWire(parent)
	end
end

-- ── Public ────────────────────────────────────────────────────────────────────

local EnginePrompts = {}

function EnginePrompts.Start(onEnter: OnEnter)
	onEnterCallback = onEnter

	for _, descendant in ipairs(Workspace:GetDescendants()) do
		tryWire(descendant)
		tryWireTrigger(descendant)
	end
	Workspace.DescendantAdded:Connect(function(instance)
		tryWire(instance)
		tryWireTrigger(instance)
	end)
	Workspace.DescendantRemoving:Connect(function(instance)
		wired[instance] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			refreshAll()
		end
	end)

	log.debug("Scanning done")
end

-- The engine currently being viewed (nil when not in engine view). Updates
-- the prompts straight away rather than at the next check.
function EnginePrompts.SetViewing(engine: Model?)
	viewingEngine = engine
	refreshAll()
end

return EnginePrompts
