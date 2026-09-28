--[[
    ToolRegistry (ModuleScript)
    ---------------------------
    Maps zone TYPE -> { tools }.

    A zone's identity is its part name in Workspace.EngineZones (unique per
    bay, e.g. Mechanic_1 ... Mechanic_12). Its type comes from a "ZoneType"
    string attribute on that part. Every bay of the same type gives the same
    tools, so adding another bay is just adding a part — no registry change.

    Zones no longer point at a specific engine. Any car with any engine can be
    parked in any bay; which engine is "in" a zone is found by position (see
    ZoneUtils.GetEngineInZone).
]]

local registry = {
	Mechanic = { tools = { "InspectionTool", "Wrench" } },
	Paint    = { tools = {} }, -- add paint tools here once they exist
}

-- ── Registry Queries ──────────────────────────────────────────────────────────

function registry.GetAllZoneTypes()
	local types = {}
	for zoneType, data in pairs(registry) do
		if type(data) == "table" and data.tools then
			table.insert(types, zoneType)
		end
	end
	return types
end

function registry.GetToolsForType(zoneType)
	local entry = zoneType and registry[zoneType]
	if type(entry) == "table" and entry.tools then
		return entry.tools
	end
	return {}
end

return registry
