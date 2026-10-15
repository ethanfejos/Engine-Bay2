--[[
    HighlightController (ModuleScript, client-only)
    -----------------------------------------------
    The one place every client-side outline/highlight in the game is made.
    Used by the Wrench, InspectionTool and GhostSystem.

    Highlights are grouped by a KEY (usually a tool name, e.g. "WrenchHover",
    "InspectionTool", "GhostHighlight"). Each key holds at most one
    highlight per part, so a tool can clear everything it drew in one call
    (HC.Clear(key)) without touching any other tool's highlights.

    Main API:
    - CreateStencil(key, part, color)  outline only, drawn on top of everything
    - UpdateStencil(key, part, color)  recolour an existing outline
    - Clear(key)                       remove everything for that key
    Also available: Create/Update (full control of fill, outline and depth
    mode), ClearInstance, UpdateAll, ClearAll, Has, and the debug helpers
    Recount / GetCount / GetCountByTool.

    Automatic cleanup — important with multiple players in a server:
    another player can remove, reinstall or destroy the very part you're
    highlighting. A highlight removes itself when its part leaves the game
    or when the Highlight is destroyed by anything else, so no outline is
    left floating where a part used to be and the counts stay correct.

    Limits: 255 highlights per client in total (Roblox's own cap since Nov
    2025) and 50 per key. Re-highlighting a part that's already highlighted
    never counts against them. Each highlighted part costs a draw call, so
    the real budget is performance, not the cap.

    Lives in each player's PlayerGui (a "Highlights" folder), so every
    player only ever sees their own highlights.
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

local DEFAULT_COLOR = Color3.new(1, 0, 0)

-- Checks Create's arguments. A missing colour (nil) means "use the default
-- red". A colour of the WRONG TYPE (e.g. a BrickColor) is refused with a
-- warning instead of quietly turning red, so the mistake shows up in testing
-- as a missing highlight rather than hiding behind a plausible-looking one.
local function validateParams(toolName, instance, color)
	if type(toolName) ~= "string" or toolName == "" then
		return false, nil
	end
	if typeof(instance) ~= "Instance"
		or (not instance:IsA("BasePart") and not instance:IsA("Model")) then
		return false, nil
	end
	if color == nil then
		return true, DEFAULT_COLOR
	end
	if typeof(color) ~= "Color3" then
		warn("[HighlightController] Refused: color must be a Color3, got", typeof(color), "for key:", toolName)
		return false, nil
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

-- Makes sure the bookkeeping tables for a key exist.
local function ensureTool(toolName)
	if not HC._highlightsByTool[toolName] then
		-- Weak keys: if an instance is GC'd without going through removeSlot
		-- (connections handle this normally, this is the final safety net),
		-- the entry evaporates automatically rather than pinning the instance.
		HC._highlightsByTool[toolName] = setmetatable({}, { __mode = "k" })
	end
	HC._cleanupConnections[toolName] = HC._cleanupConnections[toolName] or {}
	HC._countByTool[toolName]        = HC._countByTool[toolName]        or 0
end

-- THE one place a highlight slot is removed. Every removal route — Clear,
-- ClearAll, ClearInstance, UpdateAll/Recount pruning, and both auto-cleanups
-- — goes through here, so the four bookkeeping structures (_highlightsByTool,
-- _cleanupConnections, _count, _countByTool) can't drift apart.
--
-- shouldDestroy: true when we're the ones removing the highlight; false when
-- it's already being destroyed (the Destroying callback), so we only do the
-- bookkeeping and never call Destroy on it a second time.
--
-- Safe to call twice: the slot is emptied BEFORE anything else happens, so a
-- re-entrant call (e.g. Destroy firing Destroying) finds nothing and returns.
local function removeSlot(toolName, instance, shouldDestroy)
	local toolHighlights = HC._highlightsByTool[toolName]
	if not toolHighlights then return end
	local h = toolHighlights[instance]
	if h == nil then return end

	toolHighlights[instance] = nil
	disconnectCleanup(toolName, instance)

	HC._count                 = math.max(0, HC._count - 1)
	HC._countByTool[toolName] = math.max(0, (HC._countByTool[toolName] or 1) - 1)

	if next(toolHighlights) == nil then
		HC._highlightsByTool[toolName] = nil
		HC._countByTool[toolName]      = nil
	end

	if shouldDestroy and h.Parent then
		h:Destroy()
	end
end

-- Snapshot of a key's instances, so callers can remove slots while looping
-- without mutating a table pairs() is walking.
local function instancesOf(toolName)
	local list = {}
	local toolHighlights = HC._highlightsByTool[toolName]
	if toolHighlights then
		for instance in pairs(toolHighlights) do
			list[#list + 1] = instance
		end
	end
	return list
end

-- ──────────────────────────────────────────────────────────────
-- Public API
-- ──────────────────────────────────────────────────────────────

-- Remove a single instance's highlight. Safe to call when it has none.
function HC.ClearInstance(toolName, instance)
	removeSlot(toolName, instance, true)
end

function HC.Create(toolName, instance, color, outlineTransparency,
	fillTransparency, depthMode)

	local valid, clr = validateParams(toolName, instance, color)
	if not valid then return nil end

	outlineTransparency = outlineTransparency ~= nil and outlineTransparency or 0
	fillTransparency    = fillTransparency    ~= nil and fillTransparency    or 1
	depthMode           = depthMode or Enum.HighlightDepthMode.AlwaysOnTop

	ensureTool(toolName)

	-- Reuse an existing live highlight BEFORE checking the limits: it's
	-- already counted, so restyling it adds nothing. (Checking limits first
	-- meant re-highlighting an already-highlighted part failed at the cap.)
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

	-- A slot whose highlight is dead is removed properly first, so the new
	-- highlight doesn't overwrite it while it's still counted and its
	-- cleanup connections are still live.
	if existing then
		removeSlot(toolName, instance, true)
		ensureTool(toolName)
	end

	if HC._count >= MAX_HIGHLIGHTS_GLOBAL then
		warn("[HighlightController] Global limit (" .. MAX_HIGHLIGHTS_GLOBAL .. ") reached")
		return nil
	end
	if HC._countByTool[toolName] >= MAX_HIGHLIGHTS_PER_TOOL then
		warn("[HighlightController] Per-key limit reached for:", toolName)
		return nil
	end

	-- Find the folder BEFORE creating or counting anything. Without one the
	-- highlight would never render, and used to be counted anyway — a count
	-- that never came back down.
	local folder = getHighlightFolder()
	if not folder then
		return nil
	end

	local h = Instance.new("Highlight")
	h.Enabled             = false
	h.Adornee             = instance
	h.FillColor           = clr
	h.OutlineColor        = clr
	h.FillTransparency    = fillTransparency
	h.OutlineTransparency = outlineTransparency
	h.DepthMode           = depthMode

	h.Parent  = folder
	h.Enabled = true

	HC._highlightsByTool[toolName][instance] = h
	HC._count                                = HC._count + 1
	HC._countByTool[toolName]                = HC._countByTool[toolName] + 1

	-- Auto-cleanup 1: the Highlight itself is destroyed by something else.
	-- It's already on its way out, so only the bookkeeping is removed —
	-- removeSlot is told NOT to destroy it again.
	local destroyConn = h.Destroying:Connect(function()
		removeSlot(toolName, instance, false)
	end)

	-- Auto-cleanup 2: the highlighted part (or the car/engine it's in)
	-- leaves the game — typically another player removing it on the server.
	--
	-- This deliberately ALSO fires if a part is parented to nil and later
	-- parented back: the highlight is dropped, and whoever wants it back
	-- calls Create again. That is correct for Engine Bay, where nothing
	-- temporarily unparents parts: removal destroys the part on the server,
	-- reinstall creates a brand-new clone, and StreamingEnabled (if on)
	-- streams parts out as removals and back in as new instances. If a
	-- future system does temporarily unparent parts, revisit this.
	local ancestryConn = instance.AncestryChanged:Connect(function(_, newParent)
		if newParent == nil then
			removeSlot(toolName, instance, true)
		end
	end)

	HC._cleanupConnections[toolName][instance] = { destroyConn, ancestryConn }

	return h
end

function HC.CreateStencil(toolName, instance, color)
	return HC.Create(toolName, instance, color, 0, 1,
		Enum.HighlightDepthMode.AlwaysOnTop)
end

-- Restyles an existing highlight. Arguments left as nil keep their current
-- value. A colour of the wrong type is refused (nothing changes) with a
-- warning, matching Create.
function HC.Update(toolName, instance, color, outlineTransparency,
	fillTransparency, depthMode)

	local toolHighlights = HC._highlightsByTool[toolName]
	if not toolHighlights then return end
	local h = toolHighlights[instance]
	if not h or not h.Parent then return end

	if color ~= nil and typeof(color) ~= "Color3" then
		warn("[HighlightController] Refused Update: color must be a Color3, got", typeof(color), "for key:", toolName)
		return nil
	end

	h.Enabled = false
	if color               ~= nil then h.FillColor           = color               end
	if color               ~= nil then h.OutlineColor        = color               end
	if outlineTransparency ~= nil then h.OutlineTransparency = outlineTransparency end
	if fillTransparency    ~= nil then h.FillTransparency    = fillTransparency    end
	if depthMode           ~= nil then h.DepthMode           = depthMode           end
	h.Enabled = true

	return h
end

function HC.UpdateStencil(toolName, instance, color)
	return HC.Update(toolName, instance, color, 0, 1,
		Enum.HighlightDepthMode.AlwaysOnTop)
end

-- Restyles every highlight under a key in one call (warning flash,
-- inspection mode, etc.). Any dead highlight found on the way is removed.
function HC.UpdateAll(toolName, color, outlineTransparency, fillTransparency, depthMode)
	if color ~= nil and typeof(color) ~= "Color3" then
		warn("[HighlightController] Refused UpdateAll: color must be a Color3, got", typeof(color), "for key:", toolName)
		return
	end

	for _, instance in ipairs(instancesOf(toolName)) do
		local toolHighlights = HC._highlightsByTool[toolName]
		local h = toolHighlights and toolHighlights[instance]
		if h and h.Parent then
			h.Enabled = false
			if color               ~= nil then h.FillColor           = color               end
			if color               ~= nil then h.OutlineColor        = color               end
			if outlineTransparency ~= nil then h.OutlineTransparency = outlineTransparency end
			if fillTransparency    ~= nil then h.FillTransparency    = fillTransparency    end
			if depthMode           ~= nil then h.DepthMode           = depthMode           end
			h.Enabled = true
		elseif h then
			removeSlot(toolName, instance, true)
		end
	end
end

-- Removes every highlight under one key.
function HC.Clear(toolName)
	for _, instance in ipairs(instancesOf(toolName)) do
		removeSlot(toolName, instance, true)
	end
end

-- Removes every highlight under every key.
function HC.ClearAll()
	local toolNames = {}
	for toolName in pairs(HC._highlightsByTool) do
		toolNames[#toolNames + 1] = toolName
	end
	for _, toolName in ipairs(toolNames) do
		HC.Clear(toolName)
	end
end

-- True only if the slot exists AND its highlight is still alive.
function HC.Has(toolName, instance)
	if not toolName or not instance then return false end
	local t = HC._highlightsByTool[toolName]
	if not t then return false end
	local h = t[instance]
	return h ~= nil and h.Parent ~= nil
end

-- Debug repair: removes any dead slots, then recomputes both counters from
-- the highlights that actually exist. Not on the hot path; call from a
-- debug command if the counts ever look wrong.
function HC.Recount()
	local toolNames = {}
	for toolName in pairs(HC._highlightsByTool) do
		toolNames[#toolNames + 1] = toolName
	end

	for _, toolName in ipairs(toolNames) do
		for _, instance in ipairs(instancesOf(toolName)) do
			local h = HC._highlightsByTool[toolName] and HC._highlightsByTool[toolName][instance]
			if h and not h.Parent then
				removeSlot(toolName, instance, true)
			end
		end
	end

	local globalCount, perTool = 0, {}
	for toolName, toolHighlights in pairs(HC._highlightsByTool) do
		local count = 0
		for _ in pairs(toolHighlights) do
			count += 1
		end
		perTool[toolName] = count
		globalCount += count
	end
	HC._count       = globalCount
	HC._countByTool = perTool
end

function HC.GetCount()               return HC._count end
function HC.GetCountByTool(toolName) return HC._countByTool[toolName] or 0 end

return HC
