--!strict
--[[
    EngineContext (ModuleScript)
    ---------------------------
    Which engine is being viewed, whether we're in engine view, and which
    part of it the mouse is pointing at (the "hover target").

    How the hover target is picked, every frame in engine view:
    1. A ray goes from the camera through the mouse. It only sees the engine
       being viewed (not the car body, the bay or other cars), and it looks
       straight through invisible parts.
    2. Whatever it hits first decides:
         - a bolt            -> the bolt (it wins over the part it holds on)
         - an engine part    -> that part (the nearest Inspectable model)
         - the block, or anything that isn't a part you can work on
                             -> nothing
         - a reinstall ghost -> nothing (so a click meant for the ghost can't
                                remove the real part behind it)
    3. Only if the ray goes through a gap and hits nothing does it fall back
       to the part closest to the mouse on screen (within 70 px). It sticks
       with the current part unless another one is 25 px closer, so it
       doesn't flicker between two parts that are about the same distance.

    EngineContext.GetHitPart() gives the exact part the ray hit this frame
    (or nil). GhostSystem uses it for ghost clicks, so the click and the
    hover always agree on what's under the mouse.
]]
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local EngineContext = {}

type Listener = (...any) -> ()
type Listeners = { [number]: { fn: Listener } }

local _engine: Model?          = nil
local _currentTarget: Instance? = nil
local _hitPart: BasePart?       = nil
local _inEngineView            = false
local _targetListeners: Listeners = {}
local _viewListeners: Listeners   = {}
local _nextId = 0

local FALLBACK_RADIUS = 70    -- px: how far from the mouse a part can be and still be picked in a gap
local STICKY_MARGIN   = 25    -- px: how much closer another part must be to take over
local RAY_LENGTH      = 500   -- studs
local SEE_THROUGH     = 0.95  -- parts at least this transparent are looked through
local MAX_SEE_THROUGH = 16    -- most invisible parts one ray will pass through

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include

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

-- How see-through a part looks right now: its own Transparency combined
-- with the client-only LocalTransparencyModifier (body fade, part effects).
local function looksInvisible(part: BasePart): boolean
	local seen = 1 - (1 - part.Transparency) * (1 - part.LocalTransparencyModifier)
	return seen >= SEE_THROUGH
end

-- The first visible part of the engine under the mouse, or nil if the ray
-- goes through a gap. Invisible parts are stepped through.
local function castAtEngine(engine: Model): BasePart?
	local camera = workspace.CurrentCamera
	if not camera then return nil end
	local mousePos = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
	rayParams.FilterDescendantsInstances = { engine }

	local origin = ray.Origin
	local dir    = ray.Direction.Unit
	local left   = RAY_LENGTH
	for _ = 1, MAX_SEE_THROUGH do
		local result = workspace:Raycast(origin, dir * left, rayParams)
		if not result then return nil end
		local part = result.Instance
		if part:IsA("BasePart") and not looksInvisible(part) then
			return part
		end
		-- Step just past the invisible part's surface and keep going.
		local travelled = (result.Position - origin).Magnitude + 0.01
		left -= travelled
		if left <= 0 then return nil end
		origin = result.Position + dir * 0.01
	end
	return nil
end

-- Every Inspectable part of the engine the gap fallback can pick (not
-- bolts, not ghosts). Rebuilt only when the engine's contents change.
local _candidates: { Model }? = nil
local _candidateConns: { RBXScriptConnection } = {}

local function dropCandidates()
	_candidates = nil
end

local function watchEngine(engine: Model?)
	for _, c in ipairs(_candidateConns) do c:Disconnect() end
	table.clear(_candidateConns)
	_candidates = nil
	if engine then
		table.insert(_candidateConns, engine.DescendantAdded:Connect(dropCandidates))
		table.insert(_candidateConns, engine.DescendantRemoving:Connect(dropCandidates))
	end
end

local function getCandidates(engine: Model): { Model }
	local list = _candidates
	if list then return list end
	local built: { Model } = {}
	for _, d in ipairs(engine:GetDescendants()) do
		if d:IsA("Model") and d:GetAttribute("Inspectable") and not d:GetAttribute("IsBolt") then
			local model, onGhost = getEngineSubModel(d)
			if model == d and not onGhost then
				table.insert(built, d)
			end
		end
	end
	_candidates = built
	return built
end

-- Screen distance (px) from the mouse to a part, or nil if it's off screen
-- or has no visible geometry to aim at.
local function screenDistance(model: Model, mousePos: Vector2): number?
	local part: BasePart? = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not part then return nil end
	local camera = workspace.CurrentCamera
	local screenPos, onScreen = camera:WorldToViewportPoint(part.Position)
	if not onScreen then return nil end
	return (mousePos - Vector2.new(screenPos.X, screenPos.Y)).Magnitude
end

-- The mouse is over a gap: pick the closest part on screen, within reach,
-- preferring to keep the current one.
local function getFallbackTarget(engine: Model): Model?
	local mousePos = UserInputService:GetMouseLocation()
	local closest: Model? = nil
	local bestDist = FALLBACK_RADIUS

	for _, model in ipairs(getCandidates(engine)) do
		local dist = screenDistance(model, mousePos)
		if dist and dist < bestDist then
			bestDist = dist
			closest  = model
		end
	end

	-- Stick with the current part while it's still in reach, unless the
	-- new one is clearly closer.
	local current = _currentTarget
	if current and current ~= closest and current:IsA("Model") and current:IsDescendantOf(engine)
		and not current:GetAttribute("IsBolt") then
		local currentDist = screenDistance(current, mousePos)
		if currentDist and currentDist <= FALLBACK_RADIUS
			and (closest == nil or bestDist > currentDist - STICKY_MARGIN) then
			return current
		end
	end
	return closest
end

function EngineContext.Init(engineModel: Model?)
	if engineModel == _engine then return end
	_engine = engineModel
	watchEngine(engineModel)
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
	if not state then
		_hitPart = nil
		if _currentTarget then
			_currentTarget = nil
			fireListeners(_targetListeners, nil)
		end
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

-- The exact part of the viewed engine under the mouse this frame (after
-- looking through invisible parts), or nil over a gap / outside engine view.
-- Can be a ghost's part, a bolt's part, or a part of the block.
function EngineContext.GetHitPart(): BasePart?
	if _hitPart and not _hitPart.Parent then _hitPart = nil end
	return _hitPart
end

RunService.RenderStepped:Connect(function()
	if not _inEngineView then return end
	local engine = _engine
	local model: Model? = nil
	if engine then
		local hit = castAtEngine(engine)
		_hitPart = hit
		if hit then
			-- Something solid is under the mouse: it decides, even when it's
			-- the block or a ghost (both mean "nothing").
			model = getEngineSubModel(hit)
		else
			model = getFallbackTarget(engine)
		end
	else
		_hitPart = nil
	end
	if model ~= _currentTarget then
		_currentTarget = model
		fireListeners(_targetListeners, model)
	end
end)


return EngineContext