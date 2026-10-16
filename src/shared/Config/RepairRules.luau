--!strict
--[[
    RepairRules (ModuleScript, shared)
    ----------------------------------
    The workbench rules, used by BOTH RepairService (server, decides) and
    RepairUI (client, shows the buttons), so the buttons always match what
    the server will allow.

    At the workbench a part can be:
    - REPAIRED: free, takes time (longer the more worn it is), pays XP.
      Only possible above MIN_REPAIRABLE_WEAR.
    - REPLACED: costs money, instant, no XP. Possible at any wear below 100,
      so it's the only way to save a part that's too worn to repair.

    Replacement price: a "Price" number attribute on the part's template in
    ReplicatedStorage.EnginePartTemplates/<engine>/<part>. Parts without one
    use DEFAULT_REPLACE_PRICE — a testing placeholder matching
    MoneyService.TEST_FLAT_COST until real prices are designed.
]]

export type Options = {
	canRepair: boolean,
	canReplace: boolean,
	reason: string?,       -- why NOTHING can be done ("ALREADY PERFECT")
	repairReason: string?, -- why repair specifically isn't allowed ("TOO WORN")
}

local RepairRules = {}

RepairRules.MIN_REPAIRABLE_WEAR   = 10 -- at or below this, a part can only be replaced
RepairRules.MAX_REPAIR_TIME       = 10 -- seconds to repair the most worn repairable part
RepairRules.MIN_REPAIR_TIME       = 1  -- seconds, for a part that's almost perfect
RepairRules.DEFAULT_REPLACE_PRICE = 1  -- testing placeholder (see header)

-- Seconds a repair takes for a part at `wear` (0–100).
function RepairRules.GetRepairTime(wear: number): number
	local fraction = 1 - (wear / 100)
	return math.max(RepairRules.MIN_REPAIR_TIME, fraction * RepairRules.MAX_REPAIR_TIME)
end

-- What the player may do with a part at `wear`. Returns a table:
--   canRepair     bool
--   canReplace    bool
--   reason        nil, or why NOTHING can be done ("ALREADY PERFECT")
--   repairReason  nil, or why repair specifically isn't allowed ("TOO WORN")
function RepairRules.GetOptions(wear: any): Options
	if type(wear) ~= "number" then
		return { canRepair = false, canReplace = false, reason = "UNKNOWN PART" }
	end
	if wear >= 100 then
		return { canRepair = false, canReplace = false, reason = "ALREADY PERFECT" }
	end
	if wear <= RepairRules.MIN_REPAIRABLE_WEAR then
		return { canRepair = false, canReplace = true, repairReason = "TOO WORN" }
	end
	return { canRepair = true, canReplace = true }
end

-- Price to replace the part described by `template` (nil = unknown part,
-- which uses the default).
function RepairRules.GetReplacePrice(template: Instance?): number
	local price = template and template:GetAttribute("Price")
	if type(price) == "number" and price >= 0 then
		return math.floor(price)
	end
	return RepairRules.DEFAULT_REPLACE_PRICE
end

-- The template for an inventory part, or nil.
function RepairRules.FindTemplate(engineName: string?, partName: string?): Instance?
	local templates = game:GetService("ReplicatedStorage"):FindFirstChild("EnginePartTemplates")
	if not templates or not engineName or not partName then return nil end
	local engineFolder = templates:FindFirstChild(engineName)
	return engineFolder and engineFolder:FindFirstChild(partName) or nil
end

return RepairRules
