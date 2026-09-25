--[[
    HighlightController (ModuleScript)
    -----------------------------------
    Fixes in this version (all issues from fine-tooth-comb review):

    [CRITICAL — pairs mutation]
    1. ClearAll: was nilng keys inside pairs(). Now collects toolNames into
       a list first, iterates the list to destroy, then wipes.
    2. Recount: was nilng dead keys inside pairs(tool). Now collects dead
       instances into a local list, prunes after the inner loop finishes.
    3. UpdateAll: was nilng dead keys inside pairs(toolHighlights). Same
       collect-then-prune pattern applied.

    [CORRECTNESS]
    4. Has: now checks h ~= nil AND h.Parent ~= nil. Previously returned
       true for a slot whose highlight was externally destroyed but whose
       AncestryChanged callback hadn't fired yet.
    5. Clear: now counts every registered slot as removed (not just live
       ones). Slots that were externally destroyed and already had
       ClearInstance called will have been removed from the table already,
       so there is no double-subtract risk.

    [EDGE CASES]
    6. LOCAL_PLAYER: no longer cached at module load. getHighlightFolder
       fetches Players.LocalPlayer lazily, so an early require() before
       the player exists doesn't permanently break the module.
    7. getHighlightFolder: replaced WaitForChild("PlayerGui") with
       FindFirstChildOfClass("PlayerGui"). PlayerGui always exists by the
       time any LocalScript runs; WaitForChild could yield mid-Create after
       counts are already incremented, which is unsafe.
    8. disconnectCleanup: now always nils toolConns[instance] even when no
       connections are stored, keeping _cleanupConnections in sync with
       _highlightsByTool after a weak-table GC eviction.
]]

local Players = game:GetService("Players")

local HC = {}

local MAX_HIGHLIGHTS_GLOBAL   = 255
local MAX_HIGHLIGHTS_PER_TOOL = 50

HC._highlightsByTool   = {}  -- [toolName][instance] = Highlight  (weak-key per tool)
HC._cleanupConnections = {}  -- [toolName][instance] = { RBXScriptConnection, ... }
HC._count              = 0
HC._countByTool        = {}

local _highlightFolder = nil

-- ──────────────────────────────────────────────────────────────
-- Internal helpers
-- ──────────────────────────────────────────────────────────────

-- Lazy, no-yield fetch. FindFirstChildOfClass never yields — safe to call
-- from inside Create after counts have already been incremented.
local function getHighlightFolder()
	if _highlightFolder and _highlightFolder.Parent then
		return _highlightFolder
	end

	local player = Players.LocalPlayer
	if not player then
		warn("[HighlightController] LocalPlayer not available")
		return nil
	end

	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		warn("[HighlightController] PlayerGui not found — is this running in a LocalScript?")
		return nil
	end

	local folder = playerGui:FindFirstChild("Highlights")
	if not folder then
		folder        = Instance.new("Folder")
		folder.Name   = "Highlights"
		folder.Parent = playerGui
	end

	_highlightFolder = folder
	return folder
end

local function validateParams(toolName, instance, color)
	if type(toolName) ~= "string" or toolName == "" then
		return false, nil
	end
	if not instance
		or (not instance:IsA("BasePart") and not instance:IsA("Model")) then
		return false, nil
	end
	if color ~= nil and typeof(color) ~= "Color3" then
		warn("[HighlightController] Invalid color for tool:", toolName)
		color = Color3.new(1, 0, 0)
	elseif color == nil then
		color = Color3.new(1, 0, 0)
	end
	return true, color
end

-- Disconnect and discard stored connections for one slot.
-- Always nils toolConns[instance] — even if no connections were stored —
-- so _cleanupConnections stays in sync after a weak-table GC eviction.
local function disconnectCleanup(toolName, instance)
	local toolConns = HC._cleanupConnections[toolName]
	if not toolConns then return end

	local conns = toolConns[instance]
	if conns then
		for _, c in ipairs(conns) do
			if c.Connected then c:Disconnect() end
		end
	end

	toolConns[instance] = nil  -- always, not just when conns existed

	if next(toolConns) == nil then
		HC._cleanupConnections[toolName] = nil
	end
end

-- ──────────────────────────────────────────────────────────────
-- Public API
-- ──────────────────────────────────────────────────────────────

-- Remove a single instance's highlight.
-- Idempotent: the nil-check on toolHighlights[instance] is the re-entrancy
-- guard. If h.Destroying fires after the slot was already wiped, we return
-- immediately with no counter side-effects.
function HC.ClearInstance(toolName, instance)
	local toolHighlights = HC._highlightsByTool[toolName]
	if not toolHighlights then return end
	if not toolHighlights[instance] then return end  -- re-entrancy / double-call guard

	local h = toolHighlights[instance]

	-- Disconnect first so the Destroying callback can't re-enter
	disconnectCleanup(toolName, instance)

	if h and h.Parent then
		h:Destroy()
	end

	toolHighlights[instance]  = nil
	HC._count                 = math.max(0, HC._count - 1)
	HC._countByTool[toolName] = math.max(0, (HC._countByTool[toolName] or 1) - 1)

	if next(toolHighlights) == nil then
		HC._highlightsByTool[toolName] = nil
		HC._countByTool[toolName]      = nil
	end
end

function HC.Create(toolName, instance, color, outlineTransparency,
	fillTransparency, depthMode)

	local valid, clr = validateParams(toolName, instance, color)
	if not valid then return nil end

	outlineTransparency = outlineTransparency ~= nil and outlineTransparency or 0
	fillTransparency    = fillTransparency    ~= nil and fillTransparency    or 1
	depthMode           = depthMode or Enum.HighlightDepthMode.AlwaysOnTop

	if not HC._highlightsByTool[toolName] then
		-- Weak keys: if an instance is GC'd without going through ClearInstance
		-- (connections handle this normally, this is the final safety net),
		-- the entry evaporates automatically rather than pinning the instance.
		HC._highlightsByTool[toolName] = setmetatable({}, { __mode = "k" })
	end
	HC._cleanupConnections[toolName] = HC._cleanupConnections[toolName] or {}
	HC._countByTool[toolName]        = HC._countByTool[toolName]        or 0

	if HC._count >= MAX_HIGHLIGHTS_GLOBAL then
		warn("[HighlightController] Global limit (255) reached")
		return nil
	end
	if HC._countByTool[toolName] >= MAX_HIGHLIGHTS_PER_TOOL then
		warn("[HighlightController] Per-tool limit reached for:", toolName)
		return nil
	end

	-- Reuse existing highlight if still alive
	local existing = HC._highlightsByTool[toolName][instance]
	if existing and existing.Parent then
		existing.Enabled             = false
		existing.FillColor           = clr
		existing.OutlineColor        = clr
		existing.FillTransparency    = fillTransparency
		existing.OutlineTransparency = outlineTransparency
		existing.DepthMode           = depthMode
		existing.Enabled             = true
		return existing
	end

	local h = Instance.new("Highlight")
	h.Enabled             = false
	h.Adornee             = instance
	h.FillColor           = clr
	h.OutlineColor        = clr
	h.FillTransparency    = fillTransparency
	h.OutlineTransparency = outlineTransparency
	h.DepthMode           = depthMode

	-- FindFirstChildOfClass — no yield risk inside Create
	local folder = getHighlightFolder()
	if folder then h.Parent = folder end

	h.Enabled = true

	HC._highlightsByTool[toolName][instance] = h
	HC._count                                = HC._count + 1
	HC._countByTool[toolName]                = HC._countByTool[toolName] + 1

	-- Auto-cleanup: highlight destroyed externally
	local destroyConn = h.Destroying:Connect(function()
		HC.ClearInstance(toolName, instance)
	end)

	-- Auto-cleanup: adorned instance leaves the DataModel.
	-- newParent == nil means actual removal, not a reparent.
	local ancestryConn = instance.AncestryChanged:Connect(function(_, newParent)
		if newParent == nil then
			HC.ClearInstance(toolName, instance)
		end
	end)

	HC._cleanupConnections[toolName][instance] = { destroyConn, ancestryConn }

	return h
end

function HC.CreateStencil(toolName, instance, color)
	return HC.Create(toolName, instance, color, 0, 1,
		Enum.HighlightDepthMode.AlwaysOnTop)
end

function HC.Update(toolName, instance, color, outlineTransparency,
	fillTransparency, depthMode)

	local toolHighlights = HC._highlightsByTool[toolName]
	if not toolHighlights then return end
	local h = toolHighlights[instance]
	if not h or not h.Parent then return end

	if color ~= nil and typeof(color) ~= "Color3" then
		warn("[HighlightController] Invalid color in Update:", toolName)
		color = nil
	end

	h.Enabled = false
	if color               ~= nil then h.FillColor           = color               end
	if color               ~= nil then h.OutlineColor        = color               end
	if outlineTransparency ~= nil then h.OutlineTransparency = outlineTransparency  end
	if fillTransparency    ~= nil then h.FillTransparency    = fillTransparency    end
	if depthMode           ~= nil then h.DepthMode           = depthMode           end
	h.Enabled = true

	return h
end

function HC.UpdateStencil(toolName, instance, color)
	return HC.Update(toolName, instance, color, 0, 1,
		Enum.HighlightDepthMode.AlwaysOnTop)
end

-- Update every highlight owned by a tool in one call.
-- Useful for state transitions: warning flash, inspection mode, etc.
-- Dead keys are collected during iteration and pruned after the loop —
-- never inside it — to avoid mutating the table while pairs() walks it.
function HC.UpdateAll(toolName, color, outlineTransparency, fillTransparency, depthMode)
	local toolHighlights = HC._highlightsByTool[toolName]
	if not toolHighlights then return end

	if color ~= nil and typeof(color) ~= "Color3" then
		warn("[HighlightController] Invalid color in UpdateAll:", toolName)
		color = nil
	end

	local dead = nil  -- lazily allocated only if a dead key is found

	for instance, h in pairs(toolHighlights) do
		if h and h.Parent then
			h.Enabled = false
			if color               ~= nil then h.FillColor           = color               end
			if color               ~= nil then h.OutlineColor        = color               end
			if outlineTransparency ~= nil then h.OutlineTransparency = outlineTransparency  end
			if fillTransparency    ~= nil then h.FillTransparency    = fillTransparency    end
			if depthMode           ~= nil then h.DepthMode           = depthMode           end
			h.Enabled = true
		else
			dead = dead or {}
			dead[#dead + 1] = instance
		end
	end

	if dead then
		for _, instance in ipairs(dead) do
			disconnectCleanup(toolName, instance)
			toolHighlights[instance]  = nil
			HC._count                 = math.max(0, HC._count - 1)
			HC._countByTool[toolName] = math.max(0, (HC._countByTool[toolName] or 1) - 1)
		end
		if next(toolHighlights) == nil then
			HC._highlightsByTool[toolName] = nil
			HC._countByTool[toolName]      = nil
		end
	end
end

-- Synchronous clear of all highlights for one tool.
-- Counts every registered slot as removed regardless of h.Parent. Slots
-- that were externally destroyed and already had ClearInstance called will
-- have been removed from the table before we get here, so there's no risk
-- of double-subtracting them.
function HC.Clear(toolName)
	local toolHighlights = HC._highlightsByTool[toolName]
	if not toolHighlights then return end

	local removed = 0
	for instance, h in pairs(toolHighlights) do
		disconnectCleanup(toolName, instance)
		if h and h.Parent then
			h:Destroy()
		end
		removed = removed + 1  -- every slot in the table was counted at Create time
	end

	HC._highlightsByTool[toolName]   = nil
	HC._cleanupConnections[toolName] = nil
	HC._count                        = math.max(0, HC._count - removed)
	HC._countByTool[toolName]        = nil
end

-- Clear all tools.
-- Collects tool names into a list first so we never mutate _highlightsByTool
-- while pairs() is walking it.
function HC.ClearAll()
	local toolNames = {}
	for toolName in pairs(HC._highlightsByTool) do
		toolNames[#toolNames + 1] = toolName
	end

	for _, toolName in ipairs(toolNames) do
		local toolHighlights = HC._highlightsByTool[toolName]
		if toolHighlights then
			for instance, h in pairs(toolHighlights) do
				disconnectCleanup(toolName, instance)
				if h and h.Parent then h:Destroy() end
			end
		end
		HC._highlightsByTool[toolName]   = nil
		HC._cleanupConnections[toolName] = nil
	end

	HC._count       = 0
	HC._countByTool = {}
end

-- Returns true only if a slot exists AND the stored highlight is still alive.
-- Checking h.Parent means externally-destroyed highlights return false even
-- before their AncestryChanged callback has had a chance to fire.
function HC.Has(toolName, instance)
	if not toolName or not instance then return false end
	local t = HC._highlightsByTool[toolName]
	if not t then return false end
	local h = t[instance]
	return h ~= nil and h.Parent ~= nil
end

-- Repair: reconcile counts AND prune dead keys.
-- Collects dead instances per tool before pruning — never nils keys while
-- pairs() is mid-iteration. Not on the hot path; call from a debug command.
function HC.Recount()
	local globalCount = 0
	local perTool     = {}

	-- Collect tool names first so we can nil entries inside the loop safely
	local toolNames = {}
	for toolName in pairs(HC._highlightsByTool) do
		toolNames[#toolNames + 1] = toolName
	end

	for _, toolName in ipairs(toolNames) do
		local tool  = HC._highlightsByTool[toolName]
		local count = 0
		local dead  = nil

		for instance, h in pairs(tool) do
			if h and h.Parent then
				count       = count + 1
				globalCount = globalCount + 1
			else
				dead = dead or {}
				dead[#dead + 1] = instance
			end
		end

		-- Prune after the inner loop
		if dead then
			for _, instance in ipairs(dead) do
				disconnectCleanup(toolName, instance)
				tool[instance] = nil
			end
		end

		if next(tool) == nil then
			HC._highlightsByTool[toolName]   = nil
			HC._cleanupConnections[toolName] = nil
		else
			perTool[toolName] = count
		end
	end

	HC._count       = globalCount
	HC._countByTool = perTool
end

function HC.GetCount()               return HC._count end
function HC.GetCountByTool(toolName) return HC._countByTool[toolName] or 0 end

return HC