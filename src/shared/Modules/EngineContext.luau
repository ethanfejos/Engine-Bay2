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

local _engine         = nil
local _currentTarget  = nil
local _inEngineView   = false
local _targetListeners = {}
local _viewListeners   = {}
local _nextId = 0

local FALLBACK_SCREEN_THRESHOLD = 120

local function newId()
	_nextId = _nextId + 1
	return _nextId
end

local function fireListeners(listeners, ...)
	for _, entry in pairs(listeners) do
		task.spawn(entry.fn, ...)
	end
end

local function subscribe(listeners, fn)
	local id = newId()
	listeners[id] = { fn = fn }
	return function()
		listeners[id] = nil
	end
end

-- Walk up from a part looking for an Inspectable model within _engine
local function getEngineSubModel(part)
	while part and part ~= _engine do
		if part:IsA("Model") then
			-- Check bolt first so it takes priority over parent model
			if part:GetAttribute("IsBolt") then
				return part
			end
			if part:GetAttribute("Inspectable") then
				return part
			end
		end
		part = part.Parent
	end
	return nil
end

local function getFallbackTarget()
	if not _engine then return nil end
	local camera   = workspace.CurrentCamera
	local mousePos = Vector2.new(mouse.X, mouse.Y)
	local closest  = nil
	local bestDist = FALLBACK_SCREEN_THRESHOLD

	for _, child in ipairs(_engine:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("Inspectable") then
			local part = child.PrimaryPart
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

function EngineContext.Init(engineModel)
	_engine = engineModel
end

function EngineContext.OnTargetChanged(callback)
	return subscribe(_targetListeners, callback)
end

function EngineContext.OnViewChanged(callback)
	return subscribe(_viewListeners, callback)
end

function EngineContext.SetInEngineView(state)
	if state == _inEngineView then return end
	_inEngineView = state
	if not state and _currentTarget then
		_currentTarget = nil
		fireListeners(_targetListeners, nil)
	end
	fireListeners(_viewListeners, state)
end

function EngineContext.IsInEngineView()
	return _inEngineView
end

function EngineContext.GetCurrentTarget()
	return _currentTarget
end

RunService.RenderStepped:Connect(function()
	if not _inEngineView then return end
	local target = mouse.Target
	local model  = target and getEngineSubModel(target)
	if not model then
		model = getFallbackTarget()
	end
	if model ~= _currentTarget then
		_currentTarget = model
		fireListeners(_targetListeners, model)
	end
end)


return EngineContext