--!strict
--[[
    PartRules (ModuleScript, shared)
    --------------------------------
    The single source of truth for the engine-part rules, used by BOTH sides
    so the client's hints and the server's checks can never disagree:

    - Server (authoritative): EngineServer (removal), InventoryService
      (reinstall), LevelService (inspection)
    - Client (hints/visuals):  Wrench, InspectionTool, GhostSystem,
      InspectionState

    Part attributes these rules read:
    - Inspectable (bool)  a part the player can inspect, remove and reinstall
    - IsBolt      (bool)  a bolt: no inspection needed, never goes to inventory
    - Requires    (string, comma-separated part names)
        On a part in the engine: those sibling parts must be REMOVED first.
        On a part's template:    those parts must be BACK IN before it can
        be reinstalled (the reverse order).
]]

local CarUtils = require(script.Parent:WaitForChild("CarUtils"))

local PartRules = {}

-- How long the player must hold the inspection tool on a part. The client
-- uses it for the progress bar; the server uses it to reject inspections
-- that arrive faster than this.
PartRules.INSPECT_DWELL_TIME = 2

-- "a, b ,c" -> { "a", "b", "c" }; empty or missing -> {}
function PartRules.ParseRequires(requires: any): { string }
	local names = {}
	if type(requires) ~= "string" or requires == "" then
		return names
	end
	for _, raw in ipairs(string.split(requires, ",")) do
		local name = string.match(raw, "^%s*(.-)%s*$")
		if name and name ~= "" then
			table.insert(names, name)
		end
	end
	return names
end

function PartRules.IsBolt(model: Instance): boolean
	return model:GetAttribute("IsBolt") == true
end

function PartRules.IsInspectable(model: Instance): boolean
	return model:GetAttribute("Inspectable") == true
end

-- What's stopping `model` being removed from its engine right now, or nil
-- if nothing is. Returns the name of the part (or bolt) that has to come
-- off first.
function PartRules.GetRemovalBlocker(model: Instance): string?
	local engine = model.Parent
	if engine then
		for _, name in ipairs(PartRules.ParseRequires(model:GetAttribute("Requires"))) do
			if engine:FindFirstChild(name) then
				return name
			end
		end
	end
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("Model") and PartRules.IsBolt(child) then
			return child.Name
		end
	end
	return nil
end

-- What's stopping a part (described by its template) being reinstalled
-- into `engine` right now, or nil if nothing is. Returns the name of the
-- part that has to go back in first.
function PartRules.GetReinstallBlocker(template: Instance, engine: Instance): string?
	for _, name in ipairs(PartRules.ParseRequires(template:GetAttribute("Requires"))) do
		if not engine:FindFirstChild(name) then
			return name
		end
	end
	return nil
end

-- The key a part's inspection is remembered by, on both client and server
-- (the server saves it in profile.Data.inspectedForXp): the car's id + the
-- part name, so each car is inspected separately and a part reinstalled in
-- the same car stays inspected. Falls back to the engine name for an
-- engine CarService hasn't given an id yet.
function PartRules.InspectKey(carKey: string, partName: string): string
	return carKey .. ":" .. partName
end

function PartRules.InspectKeyForModel(model: Instance): string?
	local engine = model.Parent
	if not engine then return nil end
	return PartRules.InspectKey(CarUtils.GetCarId(engine) or engine.Name, model.Name)
end

return PartRules
