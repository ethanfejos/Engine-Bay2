--!strict
--[[
    SaveData (ModuleScript, server)
    -------------------------------
    The shape of a player's save, and how older or damaged saves are brought
    up to date. Used only by ProfileManager, every time a profile loads:

        1. Migrate   — run each migration step the save hasn't had yet
        2. Reconcile — (ProfileService) add any fields the save is missing
        3. Sanitize  — repair or drop anything malformed, and recover dropped
                       parts left behind by a server that shut down badly

    ── Changing the save format ─────────────────────────────────────────────
    Add a function to MIGRATIONS at the next number, and it runs once on
    every save older than that number, in order. Never edit or remove an
    old step — saves that haven't loaded since then still need it.

    Example (step 3 below): every save's money set to the real starting
    balance, replacing the $100,000 testing balance:
        [3] = function(data)
            data.money = STARTING_MONEY
        end
    Brand-new players get TEMPLATE.money instead (migrations don't run on
    a fresh save). To change the balance of saves that already ran a step,
    add a new step — never edit an old one.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Types"))

type Item = Types.InventoryItem

-- A car the player owns (CarService). Part states are keyed by the part's
-- path inside the engine ("Alternator", "Alternator/Bolt#2"); anything not
-- listed is as the car's template has it.
export type CarRecord = {
	id: string,                     -- the car's CarId, the same every session
	model: string,                  -- template name in ServerStorage.Cars
	missing: { [string]: boolean }, -- parts and bolts not in the engine
	wear: { [string]: number },     -- condition of the parts that are in it
	xpPaid: { [string]: boolean },  -- parts whose removal XP has been paid
	inspected: { [string]: boolean }, -- parts (by name) this car's worker has inspected
}

-- A customer job in progress (JobService). Saved so leaving mid-job
-- doesn't lose it: the customer's car is kept here, not in `cars`.
export type JobRecord = {
	id: string,
	car: CarRecord,               -- the customer's car, as it is right now
	customerName: string,
	customerUserId: number?,      -- the friend whose avatar the customer wears
	faults: { string },           -- part paths the customer asked to have fixed
	pay: number,
	request: string,              -- what the customer said
}

-- A player's save, as every service sees it after loading.
export type Data = {
	dataVersion: number,
	inventory: { Item },
	dropped: { [string]: Item },
	xp: number,
	money: number,
	cars: { [string]: CarRecord },  -- [carId]
	activeCarId: string?,           -- the car that spawns when they join
	activeJob: JobRecord?,          -- the customer job in progress, if any
}

local SaveData = {}

-- What every player starts with (and what step 3 set existing saves to).
local STARTING_MONEY = 500
SaveData.STARTING_MONEY = STARTING_MONEY

-- Bump this together with adding a MIGRATIONS step.
SaveData.CURRENT_VERSION = 4

-- What a brand-new player starts with.
local TEMPLATE: Data = {
	dataVersion = SaveData.CURRENT_VERSION,

	-- Parts held: list of { id, name, wear, engineName, carId, relativeData }
	inventory = {},

	-- Parts lying on the floor, not yet picked up: [id] = same shape as an
	-- inventory item. Written the moment a part drops, so a server crash
	-- can't lose a part that's neither in the engine nor the inventory.
	-- Anything still here when a save loads is moved into the inventory.
	dropped = {},

	xp = 0,

	money = STARTING_MONEY,

	-- Cars the player owns, [carId] = CarRecord, and which one is in use.
	-- (activeCarId starts unset; CarService gives a new player a starter car.)
	cars = {},
}
SaveData.TEMPLATE = TEMPLATE

-- [version] = function(data) — upgrades a save from version-1 to version.
local MIGRATIONS: { [number]: (data: any) -> () } = {
	-- 1: first versioned format. Saves from before versioning already have
	-- every field (Reconcile filled them in), so nothing to change.
	[1] = function(_data) end,

	-- 2: inspections are now remembered per car ("carId:part"), not per
	-- engine name. The old keys can't be matched to a car, so they go;
	-- parts just need inspecting again once.
	[2] = function(data)
		data.inspectedForXp = {}
	end,

	-- 3: the $100,000 testing balance is replaced by the real starting
	-- balance, for every save.
	[3] = function(data)
		data.money = STARTING_MONEY
	end,

	-- 4: inspections move from one ever-growing list ("carId:part") onto
	-- each car's own record, so they leave with the car (job cars). Entries
	-- for cars the player doesn't have are dropped.
	[4] = function(data)
		local old = data.inspectedForXp
		data.inspectedForXp = nil
		if type(old) ~= "table" or type(data.cars) ~= "table" then return end
		for key in pairs(old) do
			if type(key) ~= "string" then continue end
			local carId, partName = string.match(key, "^(.-):(.+)$")
			local car = carId and data.cars[carId]
			if type(car) == "table" and partName then
				car.inspected = if type(car.inspected) == "table" then car.inspected else {}
				car.inspected[partName] = true
			end
		end
	end,
}

-- Runs every migration the save hasn't had. Must run BEFORE Reconcile:
-- Reconcile would otherwise add dataVersion = CURRENT_VERSION to an old
-- save and its migrations would be skipped. Returns the number of steps run.
function SaveData.Migrate(data: any): number
	local version = tonumber(data.dataVersion) or 0
	local ran = 0
	for v = version + 1, SaveData.CURRENT_VERSION do
		local step = MIGRATIONS[v]
		if step then
			step(data)
			ran += 1
		end
		data.dataVersion = v
	end
	return ran
end

-- ── Sanitize ──────────────────────────────────────────────────────────────────

local function cleanRelativeData(rd: any): Types.RelativeData?
	if type(rd) ~= "table" then return nil end
	for _, key in ipairs({ "x", "y", "z", "rx", "ry", "rz" }) do
		if type(rd[key]) ~= "number" or rd[key] ~= rd[key] then -- missing or NaN
			return nil
		end
	end
	return { x = rd.x, y = rd.y, z = rd.z, rx = rd.rx, ry = rd.ry, rz = rd.rz }
end

-- A clean copy of an inventory item, or nil plus a reason if it can't be
-- saved. Missing positions are allowed (the part reinstalls at the
-- template's own position); a missing id, name or engine is not.
local function cleanItem(item: any): (Item?, string?)
	if type(item) ~= "table" then return nil, "not a table" end
	if type(item.id) ~= "string" or item.id == "" then return nil, "no id" end
	if type(item.name) ~= "string" or item.name == "" then return nil, "no name" end
	if type(item.engineName) ~= "string" or item.engineName == "" then return nil, "no engine" end

	local wear: number = tonumber(item.wear) or 100 -- unknown condition: treat as perfect rather than lose the part
	if wear ~= wear then -- NaN
		wear = 100
	end

	return ({
		id           = item.id,
		name         = item.name,
		engineName   = item.engineName,
		carId        = if type(item.carId) == "string" and item.carId ~= "" then item.carId else nil,
		wear         = math.clamp(wear, 0, 100),
		relativeData = cleanRelativeData(item.relativeData),
	} :: Item), nil
end

-- { [string] = true } with only string keys.
local function cleanStringSet(t: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(t) == "table" then
		for k, v in pairs(t) do
			if type(k) == "string" and v == true then out[k] = true end
		end
	end
	return out
end

-- A clean copy of a car record, or nil if it can't be used.
local function cleanCar(id: any, record: any): CarRecord?
	if type(id) ~= "string" or id == "" or type(record) ~= "table" then return nil end
	if type(record.model) ~= "string" or record.model == "" then return nil end
	local wear: { [string]: number } = {}
	if type(record.wear) == "table" then
		for path, w in pairs(record.wear) do
			local n = tonumber(w)
			if type(path) == "string" and n and n == n then
				wear[path] = math.clamp(n, 0, 100)
			end
		end
	end
	return {
		id      = id,
		model   = record.model,
		missing = cleanStringSet(record.missing),
		wear    = wear,
		xpPaid  = cleanStringSet(record.xpPaid),
		inspected = cleanStringSet(record.inspected),
	}
end

-- A clean copy of a saved job, or nil if it can't be used.
local function cleanJob(job: any): JobRecord?
	if type(job) ~= "table" or type(job.id) ~= "string" or type(job.car) ~= "table" then return nil end
	local car = cleanCar(job.car.id, job.car)
	if not car then return nil end
	local faults: { string } = {}
	if type(job.faults) == "table" then
		for _, path in ipairs(job.faults) do
			if type(path) == "string" then table.insert(faults, path) end
		end
	end
	if #faults == 0 then return nil end
	return {
		id             = job.id,
		car            = car,
		customerName   = if type(job.customerName) == "string" then job.customerName else "Customer",
		customerUserId = if type(job.customerUserId) == "number" then job.customerUserId else nil,
		faults         = faults,
		pay            = math.max(0, math.floor(tonumber(job.pay) or 0)),
		request        = if type(job.request) == "string" then job.request else "",
	}
end

-- Repairs `data` in place. Returns a list of human-readable notes about
-- anything that was changed (for the Output log); empty if all was well.
function SaveData.Sanitize(data: any): { string }
	local notes: { string } = {}

	-- Numbers
	local xp = tonumber(data.xp)
	if not xp or xp ~= xp or xp < 0 then
		table.insert(notes, "xp reset (was " .. tostring(data.xp) .. ")")
		xp = 0
	end
	data.xp = math.floor(xp :: number)

	local money = tonumber(data.money)
	if not money or money ~= money then
		table.insert(notes, "money reset (was " .. tostring(data.money) .. ")")
		money = 0
	end
	data.money = math.floor(money :: number)

	-- Inventory: clean every item, drop broken ones and duplicate ids
	local cleaned: { Item }, seen: { [string]: boolean } = {}, {}
	local function keep(item: any, source: string): boolean
		local clean, why = cleanItem(item)
		if not clean then
			table.insert(notes, source .. " item dropped (" .. (why or "?") .. ")")
		elseif seen[clean.id] then
			table.insert(notes, source .. " duplicate " .. clean.id .. " dropped")
		else
			seen[clean.id] = true
			table.insert(cleaned, clean)
			return true
		end
		return false
	end

	if type(data.inventory) ~= "table" then
		table.insert(notes, "inventory was not a list")
	else
		for _, item in ipairs(data.inventory) do
			keep(item, "inventory")
		end
	end

	-- Parts left on the floor by a server that didn't shut down cleanly:
	-- put them in the inventory now.
	if type(data.dropped) == "table" then
		for _, item in pairs(data.dropped) do
			if keep(item, "dropped") then
				table.insert(notes, "recovered dropped part " .. tostring(item.name))
			end
		end
	end
	data.dropped   = {}
	data.inventory = cleaned

	-- Cars: keep well-formed records only, and an activeCarId that exists.
	local cars: { [string]: CarRecord } = {}
	if type(data.cars) == "table" then
		for id, record in pairs(data.cars) do
			local clean = cleanCar(id, record)
			if clean then
				cars[clean.id] = clean
			else
				table.insert(notes, "car " .. tostring(id) .. " dropped (malformed)")
			end
		end
	end
	data.cars = cars
	if data.activeJob ~= nil then
		local job = cleanJob(data.activeJob)
		if not job then table.insert(notes, "activeJob dropped (malformed)") end
		data.activeJob = job
	end

	if type(data.activeCarId) ~= "string" or cars[data.activeCarId] == nil then
		if data.activeCarId ~= nil then
			table.insert(notes, "activeCarId cleared (no such car)")
		end
		data.activeCarId = nil
	end

	return notes
end

return SaveData
