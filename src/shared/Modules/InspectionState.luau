--[[
    InspectionState (ModuleScript)
    ------------------------------
    Changes from previous version:
    - _inspectedModels now keyed by "engineName:partName" string instead of
      instance reference. This means reinstalled parts are still recognised
      as inspected without needing re-inspection.
    - MarkInspected, ClearInspected, IsInspected all derive the key from
      the model's name and its parent's name.
    - AncestryChanged cleanup removed — no longer needed since keys are
      strings not instance references.
    - Everything else unchanged.

    Other scripts it links to:
    - Written by: InspectionTool/ToolScript
    - Read by: InspectionUI, Wrench/ToolScript
]]

local InspectionState = {}

local _currentModel       = nil
local _modelListeners     = {}
local _inspectedModels    = {}  -- ["engineName:partName"] = true
local _inspectedListeners = {}
local _dwellProgress      = 0
local _dwellListeners     = {}
local _nextId             = 0

local function newId()
	_nextId = _nextId + 1
	return _nextId
end

local function subscribe(listeners, fn)
	local id = newId()
	listeners[id] = fn
	return function()
		listeners[id] = nil
	end
end

local function fireListeners(listeners, ...)
	for _, fn in pairs(listeners) do
		task.spawn(fn, ...)
	end
end

-- Derive a stable string key from a model instance
local function getKey(model)
	if not model then return nil end
	local engineName = model.Parent and model.Parent.Name or "Unknown"
	return engineName .. ":" .. model.Name
end

-- ── Current hovered model ─────────────────────────────────────────────────────

function InspectionState.SetCurrentModel(model)
	if model == _currentModel then return end
	_currentModel = model
	InspectionState.SetDwellProgress(0)
	fireListeners(_modelListeners, model)
end

function InspectionState.GetCurrentModel()
	return _currentModel
end

function InspectionState.OnChanged(callback)
	return subscribe(_modelListeners, callback)
end

-- ── Inspected set ─────────────────────────────────────────────────────────────

function InspectionState.MarkInspected(model)
	local key = getKey(model)
	if not key then return end
	if _inspectedModels[key] then return end
	_inspectedModels[key] = true
	fireListeners(_inspectedListeners, model, true)
end

function InspectionState.ClearInspected(model)
	local key = getKey(model)
	if not key then return end
	if not _inspectedModels[key] then return end
	_inspectedModels[key] = nil
	fireListeners(_inspectedListeners, model, false)
end

function InspectionState.IsInspected(model)
	local key = getKey(model)
	if not key then return false end
	return _inspectedModels[key] == true
end

function InspectionState.OnInspectedChanged(callback)
	return subscribe(_inspectedListeners, callback)
end

-- ── Dwell progress ────────────────────────────────────────────────────────────

function InspectionState.SetDwellProgress(t)
	_dwellProgress = math.clamp(t or 0, 0, 1)
	fireListeners(_dwellListeners, _dwellProgress)
end

function InspectionState.GetDwellProgress()
	return _dwellProgress
end

function InspectionState.OnDwellProgressChanged(callback)
	return subscribe(_dwellListeners, callback)
end

-- ── Reset ─────────────────────────────────────────────────────────────────────

function InspectionState.Reset()
	_currentModel    = nil
	_inspectedModels = {}
	_dwellProgress   = 0
end

return InspectionState