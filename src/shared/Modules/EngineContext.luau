--!strict
--[[
    EngineContext (ModuleScript)
    ---------------------------
    Changes from previous version:
    - Removed hardcoded EngineZone reference
    - getEngineSubModel now walks up to _engine boundary instead of EngineZone
    - Everything else unchanged
]]
local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")

local player = Players.LocalPlayer
local mouse  = player:GetMouse()

local EngineContext = {}

type Listener = (...any) -> ()
type Listeners = { [number]: { fn: Listener } }

local _engine: Model?          = nil
local _currentTarget: Instance? = nil
local _inEngineView            = false
local _targetListeners: Listeners = {}
local _viewListeners: Listeners   = {}
local _nextId = 0

local FALLBACK_SCREEN_THRESHOLD = 120

local function newId()
	_nextId = _nextId + 1
	return _nextId
end

local function fireListeners(listeners: Listeners, ...: any)
	for _, entry in pairs(listeners) do
		task.spawn(entry.fn, ...)
	end
end

local function subscribe(listeners: Listeners, fn: Listener): () -> ()
	local id = newId()
	listeners[id] = { fn = fn }
	return function()
		listeners[id] = nil
	end
end

-- Walk up from a part looking for an Inspectable model within _engine.
-- Returns model, isGhost. Only parts INSIDE the engine count: without this
-- check the walk climbed past the engine to the top of the game and could
-- return dropped parts or another car's parts. isGhost = true when the
-- part belongs to a GhostSystem reinstall ghost.
local function getEngineSubModel(part: Instance?): (Model?, boolean)
	local engine = _engine
	if not engine or not part or not part:IsDescendantOf(engine) then
		return nil, false
	end
	local current: Instance? = part
	while current and current ~= engine do
		if current:GetAttribute("IsGhost") then
			return nil, true
		end
		if current:IsA("Model") then
			-- Check bolt first so it takes priority over parent model
			if current:GetAttribute("IsBolt") then
				return current, false
			end
			if current:GetAttribute("Inspectable") then
				return current, false
			end
		end
		current = current.Parent
	end
	return nil, false
end

local function getFallbackTarget(): Model?
	local engine = _engine
	if not engine then return nil end
	local camera   = workspace.CurrentCamera
	local mousePos = Vector2.new(mouse.X, mouse.Y)
	local closest: Model? = nil
	local bestDist = FALLBACK_SCREEN_THRESHOLD

	for _, child in ipairs(engine:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("Inspectable") then
			local part: BasePart? = child.PrimaryPart
				or child:FindFirstChildWhichIsA("BasePart")
			if part then
				local screenPos, onScreen =
					camera:WorldToViewportPoint(part.Position)
				if onScreen then
					local dist = (mousePos - Vector2.new(
						screenPos.X, screenPos.Y)).Magnitude
					if dist < bestDist then
						bestDist = dist
						closest  = child
					end
				end
			end
		end
	end
	return closest
end

function EngineContext.Init(engineModel: Model?)
	_engine = engineModel
end

function EngineContext.OnTargetChanged(callback: Listener): () -> ()
	return subscribe(_targetListeners, callback)
end

function EngineContext.OnViewChanged(callback: Listener): () -> ()
	return subscribe(_viewListeners, callback)
end

function EngineContext.SetInEngineView(state: boolean)
	if state == _inEngineView then return end
	_inEngineView = state
	if not state and _currentTarget then
		_currentTarget = nil
		fireListeners(_targetListeners, nil)
	end
	fireListeners(_viewListeners, state)
end

function EngineContext.IsInEngineView(): boolean
	return _inEngineView
end

-- The engine being viewed (set on entering engine view), or nil.
function EngineContext.GetEngine(): Model?
	return _engine
end

function EngineContext.GetCurrentTarget(): Instance?
	return _currentTarget
end

RunService.RenderStepped:Connect(function()
	if not _inEngineView then return end
	local model, onGhost = getEngineSubModel(mouse.Target)
	-- Hovering the ghost means "nothing" — no fallback, or the nearest
	-- real part behind the ghost would be targeted instead.
	if not model and not onGhost then
		model = getFallbackTarget()
	end
	if model ~= _currentTarget then
		_currentTarget = model
		fireListeners(_targetListeners, model)
	end
end)


return EngineContext