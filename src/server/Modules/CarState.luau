--!strict
--[[
    CarState (ModuleScript, server)
    -------------------------------
    Reads a car's engine into a save record and puts it back. Used by
    CarService; kept separate (and free of Roblox services) so it can be
    tested on its own.

    Every part and bolt in an engine is named by its path from the engine:
    "Alternator", "Alternator/Bolt", "Alternator/Bolt#2" (#n tells apart
    siblings with the same name). A record lists:
    - missing  paths the template has but the car doesn't (removed)
    - wear     each present part's Wear
    - xpPaid   present parts whose removal XP was already paid
]]

local SaveData = require(script.Parent:WaitForChild("SaveData"))

type CarRecord = SaveData.CarRecord

local CarState = {}

-- Every Inspectable part and bolt under `engine`, by path.
function CarState.Track(engine: Instance): { [string]: Instance }
	local out: { [string]: Instance } = {}
	local function walk(parent: Instance, prefix: string?)
		local seen: { [string]: number } = {}
		for _, child in ipairs(parent:GetChildren()) do
			if child:IsA("Model") then
				local n = (seen[child.Name] or 0) + 1
				seen[child.Name] = n
				local segment = if n == 1 then child.Name else child.Name .. "#" .. n
				local path = if prefix then prefix .. "/" .. segment else segment
				if child:GetAttribute("Inspectable") or child:GetAttribute("IsBolt") then
					out[path] = child
				end
				walk(child, path)
			end
		end
	end
	walk(engine, nil)
	return out
end

-- Just the set of paths (for a template).
function CarState.Paths(engine: Instance): { [string]: boolean }
	local paths: { [string]: boolean } = {}
	for path in pairs(CarState.Track(engine)) do
		paths[path] = true
	end
	return paths
end

-- Writes the engine's current state into `record`. `allPaths` is the
-- template's full set, so anything not in the engine now is "missing".
function CarState.Snapshot(engine: Instance, allPaths: { [string]: boolean }, record: CarRecord)
	local live = CarState.Track(engine)

	local missing: { [string]: boolean } = {}
	for path in pairs(allPaths) do
		if not live[path] then missing[path] = true end
	end
	local wear: { [string]: number } = {}
	local xpPaid: { [string]: boolean } = {}
	for path, model in pairs(live) do
		local w = tonumber(model:GetAttribute("Wear"))
		if w then wear[path] = w end
		if model:GetAttribute("RemovalXpPaid") == true then xpPaid[path] = true end
	end

	record.missing, record.wear, record.xpPaid = missing, wear, xpPaid
end

-- Sets up a fresh copy of the car (straight from its template) the way
-- `record` says: removes missing parts, restores wear and XP flags.
function CarState.Apply(engine: Instance, record: CarRecord)
	for path, model in pairs(CarState.Track(engine)) do
		if record.missing[path] then
			model:Destroy()
		else
			local w = record.wear[path]
			if w then model:SetAttribute("Wear", w) end -- unset: EngineServer gives a random wear
			if record.xpPaid[path] then model:SetAttribute("RemovalXpPaid", true) end
		end
	end
end

return CarState
