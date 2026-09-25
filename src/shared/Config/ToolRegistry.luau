--[[
    ToolRegistry (ModuleScript)
    ---------------------------
    Maps zoneId -> { partName, tools }
    Exposes helper methods used by ToolService, EngineCore, and EngineBillboard.
]]

local Workspace = game:GetService("Workspace")

local registry = {
	engine_1 = { partName = "Beetle Engine", tools = {"InspectionTool", "Wrench"} },
	engine_2 = { partName = "coyote 3.2",    tools = {"InspectionTool", "Wrench"} },
}

-- ── Registry Queries ──────────────────────────────────────────────────────────

function registry.GetAllZoneIds()
	local ids = {}
	for zoneId, data in pairs(registry) do
		if type(data) == "table" and data.tools then
			table.insert(ids, zoneId)
		end
	end
	return ids
end

function registry.GetToolsForZone(zoneId)
	local entry = registry[zoneId]
	return entry and entry.tools or {}
end

function registry.GetPartNameForZone(zoneId)
	local entry = registry[zoneId]
	return entry and entry.partName or nil
end

-- ── Physical Instance Resolution ──────────────────────────────────────────────

--[[
	Safely retrieves the physical Engine model from Workspace.Engines.
	Replaces loose workspace searches across server and client scripts.
]]
function registry.GetEngineInstance(zoneId, timeout)
	local partName = registry.GetPartNameForZone(zoneId)
	if not partName then return nil end

	local enginesFolder = Workspace:FindFirstChild("Engines")
	if not enginesFolder then
		warn("[ToolRegistry] 'Engines' folder is completely missing from Workspace!")
		return nil
	end

	if timeout and timeout > 0 then
		return enginesFolder:WaitForChild(partName, timeout)
	else
		return enginesFolder:FindFirstChild(partName)
	end
end

return registry