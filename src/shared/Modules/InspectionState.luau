--!strict
--[[
    InspectionState (ModuleScript, client)
    --------------------------------------
    The client's view of inspection:
    - which part the InspectionTool is currently pointed at
    - how far through the hold-to-inspect the player is (0–1)
    - which parts this player has inspected

    Inspected parts are keyed by PartRules.InspectKey ("carId:part"), the
    same key the server saves, so a reinstalled part stays inspected.

    The server is the authority. This module listens for:
    - InspectedSync  a car's saved inspected parts, sent when the car is
                     spawned for this player, so progress survives rejoining
    - PartInspected  (engine, part, false) when the server refuses an
                     inspection, which un-marks it here

    Written by: InspectionTool. Read by: InspectionUI, Wrench.
]]

local RunService        = game:GetService("RunService")

local PartRules = require(script.Parent:WaitForChild("PartRules"))

local InspectionState = {}

type Listener = (...any) -> ()

local _currentModel: Instance?                      = nil
local _modelListeners: { [number]: Listener }       = {}
local _inspectedModels: { [string]: boolean }       = {}  -- ["engineName:partName"] = true
local _inspectedListeners: { [number]: Listener }   = {}
local _dwellProgress                                = 0
local _dwellListeners: { [number]: Listener }       = {}
local _nextId                                       = 0

local function newId()
	_nextId = _nextId + 1
	return _nextId
end

local function subscribe(listeners: { [number]: Listener }, fn: Listener): () -> ()
	local id = newId()
	listeners[id] = fn
	return function()
		listeners[id] = nil
	end
end

local function fireListeners(listeners: { [number]: Listener }, ...: any)
	for _, fn in pairs(listeners) do
		task.spawn(fn, ...)
	end
end

local function getKey(model: Instance?): string?
	if not model then return nil end
	return PartRules.InspectKeyForModel(model)
end

-- ── Current hovered model ─────────────────────────────────────────────────────

function InspectionState.SetCurrentModel(model: Instance?)
	if model == _currentModel then return end
	_currentModel = model
	InspectionState.SetDwellProgress(0)
	fireListeners(_modelListeners, model)
end

function InspectionState.GetCurrentModel(): Instance?
	return _currentModel
end

function InspectionState.OnChanged(callback: Listener): () -> ()
	return subscribe(_modelListeners, callback)
end

-- ── Inspected set ─────────────────────────────────────────────────────────────

function InspectionState.MarkInspected(model: Instance?)
	local key = getKey(model)
	if not key then return end
	if _inspectedModels[key] then return end
	_inspectedModels[key] = true
	fireListeners(_inspectedListeners, model, true)
end

function InspectionState.ClearInspected(model: Instance?)
	local key = getKey(model)
	if not key then return end
	if not _inspectedModels[key] then return end
	_inspectedModels[key] = nil
	fireListeners(_inspectedListeners, model, false)
end

function InspectionState.IsInspected(model: Instance?): boolean
	local key = getKey(model)
	if not key then return false end
	return _inspectedModels[key] == true
end

-- Listeners get (model, isInspected). For changes that come from the
-- server by key only, model is nil and the key is passed third.
function InspectionState.OnInspectedChanged(callback: Listener): () -> ()
	return subscribe(_inspectedListeners, callback)
end

-- ── Server sync ───────────────────────────────────────────────────────────────

if RunService:IsClient() then
	task.spawn(function()
		local Remotes = require(script.Parent:WaitForChild("Remotes"))

		Remotes.InspectedSync.OnClientEvent:Connect(function(keys)
			if type(keys) ~= "table" then return end
			for _, key in ipairs(keys) do
				if type(key) == "string" and not _inspectedModels[key] then
					_inspectedModels[key] = true
					fireListeners(_inspectedListeners, nil, true, key)
				end
			end
		end)

		Remotes.PartInspected.OnClientEvent:Connect(function(engineName, partName, accepted, serverKey)
			if accepted ~= false then return end
			if type(engineName) ~= "string" or type(partName) ~= "string" then return end
			-- The server sends the exact (per-car) key when it knows the part.
			local key = if type(serverKey) == "string" then serverKey else PartRules.InspectKey(engineName, partName)
			if _inspectedModels[key] then
				_inspectedModels[key] = nil
				fireListeners(_inspectedListeners, nil, false, key)
			end
		end)
	end)
end

-- ── Dwell progress ────────────────────────────────────────────────────────────

function InspectionState.SetDwellProgress(t: number?)
	_dwellProgress = math.clamp(t or 0, 0, 1)
	fireListeners(_dwellListeners, _dwellProgress)
end

function InspectionState.GetDwellProgress(): number
	return _dwellProgress
end

function InspectionState.OnDwellProgressChanged(callback: Listener): () -> ()
	return subscribe(_dwellListeners, callback)
end

-- ── Reset ─────────────────────────────────────────────────────────────────────

function InspectionState.Reset()
	_currentModel    = nil
	_inspectedModels = {}
	_dwellProgress   = 0
end

return InspectionState