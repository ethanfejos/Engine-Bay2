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

    Example: before launch, wipe the testing money from every save:
        [2] = function(data)
            data.money = 500 -- real starting balance
        end
    (Also lower TEMPLATE.money, which is what brand-new players get.)
]]

local SaveData = {}

-- Bump this together with adding a MIGRATIONS step.
SaveData.CURRENT_VERSION = 1

-- What a brand-new player starts with.
SaveData.TEMPLATE = {
	dataVersion = SaveData.CURRENT_VERSION,

	-- Parts held: list of { id, name, wear, engineName, relativeData }
	inventory = {},

	-- Parts lying on the floor, not yet picked up: [id] = same shape as an
	-- inventory item. Written the moment a part drops, so a server crash
	-- can't lose a part that's neither in the engine nor the inventory.
	-- Anything still here when a save loads is moved into the inventory.
	dropped = {},

	xp = 0,

	-- Parts this player has inspected: ["engineName:partName"] = true
	inspectedForXp = {},

	-- Testing-phase starting balance; see the migration example above.
	money = 100000,
}

-- [version] = function(data) — upgrades a save from version-1 to version.
local MIGRATIONS = {
	-- 1: first versioned format. Saves from before versioning already have
	-- every field (Reconcile filled them in), so nothing to change.
	[1] = function(_data) end,
}

-- Runs every migration the save hasn't had. Must run BEFORE Reconcile:
-- Reconcile would otherwise add dataVersion = CURRENT_VERSION to an old
-- save and its migrations would be skipped. Returns the number of steps run.
function SaveData.Migrate(data)
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

local function cleanRelativeData(rd)
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
local function cleanItem(item)
	if type(item) ~= "table" then return nil, "not a table" end
	if type(item.id) ~= "string" or item.id == "" then return nil, "no id" end
	if type(item.name) ~= "string" or item.name == "" then return nil, "no name" end
	if type(item.engineName) ~= "string" or item.engineName == "" then return nil, "no engine" end

	local wear = tonumber(item.wear)
	if not wear or wear ~= wear then
		wear = 100 -- unknown condition: treat as perfect rather than lose the part
	end

	return {
		id           = item.id,
		name         = item.name,
		engineName   = item.engineName,
		wear         = math.clamp(wear, 0, 100),
		relativeData = cleanRelativeData(item.relativeData),
	}
end

-- Repairs `data` in place. Returns a list of human-readable notes about
-- anything that was changed (for the Output log); empty if all was well.
function SaveData.Sanitize(data)
	local notes = {}

	-- Numbers
	local xp = tonumber(data.xp)
	if not xp or xp ~= xp or xp < 0 then
		table.insert(notes, "xp reset (was " .. tostring(data.xp) .. ")")
		xp = 0
	end
	data.xp = math.floor(xp)

	local money = tonumber(data.money)
	if not money or money ~= money then
		table.insert(notes, "money reset (was " .. tostring(data.money) .. ")")
		money = 0
	end
	data.money = math.floor(money)

	-- Inspected set: only "string -> true"
	if type(data.inspectedForXp) ~= "table" then
		table.insert(notes, "inspectedForXp reset")
		data.inspectedForXp = {}
	end
	for key, value in pairs(data.inspectedForXp) do
		if type(key) ~= "string" or value ~= true then
			data.inspectedForXp[key] = nil
			table.insert(notes, "bad inspected entry removed")
		end
	end

	-- Inventory: clean every item, drop broken ones and duplicate ids
	local cleaned, seen = {}, {}
	local function keep(item, source)
		local clean, why = cleanItem(item)
		if not clean then
			table.insert(notes, source .. " item dropped (" .. why .. ")")
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

	return notes
end

return SaveData
