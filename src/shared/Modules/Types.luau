--!strict
--[[
    Types (ModuleScript, shared)
    ----------------------------
    Shapes of data that travel between server and client, so both sides
    (and the type checker) agree on them. Types only — no code runs here.

        local Types = require(Shared.Modules.Types)
        local function fillRow(item: Types.InventoryItem) ... end
]]

-- Where a removed part sat, relative to its engine's pivot, so it can be
-- reinstalled (and ghosted) in the same place.
export type RelativeData = {
	x: number, y: number, z: number,
	rx: number, ry: number, rz: number,
}

-- One part in a player's inventory (InventoryUpdated sends a list of
-- these). Saved as-is in profile.Data.inventory; SaveData.Sanitize keeps
-- saves in this shape.
export type InventoryItem = {
	id: string,
	name: string,
	engineName: string,           -- engine type: finds the part's template
	carId: string?,               -- the car it came from (nil: from before car ids)
	wear: number,                 -- 0–100
	relativeData: RelativeData?,  -- nil: reinstall at the template's own position
}

return {}
