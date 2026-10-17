--!strict
--[[
    Upsell (ModuleScript, server)
    -----------------------------
    Extras you can add to a customer's bill when you hand the car back —
    none of them need doing (there's no such thing as blinker fluid).

    - A normal customer refuses them all, and halves their tip for the cheek.
    - A Clueless customer (CustomerTypes) pays for them. The first SAFE_EXTRAS
      are fine; every extra after that adds CATCH_STEP to the chance they
      work it out. Caught: they pay for none of the extras, you lose
      reputation (ReputationService.CHANGES.caughtUpsell), and they won't be
      back as a regular.
    - Tony takes TONY_SHARE of whatever extras get paid (TonyService).

        local result = Upsell.Evaluate("clueless", { "blinker", "polish" })
        -- result.outcome: "none" | "paid" | "refused" | "caught"
]]

export type Extra = { id: string, label: string, price: number }

export type Result = {
	outcome: string,           -- "none" (no extras), "paid", "refused" (not clueless), "caught"
	lines: { Extra },          -- the extras actually paid for
	total: number,             -- what they came to
	catchChance: number,       -- the chance they had of catching on (0–1)
}

local Upsell = {}

Upsell.SAFE_EXTRAS = 2       -- this many extras never raise suspicion
Upsell.CATCH_STEP  = 0.25    -- each extra after that: +25% chance they catch on
Upsell.TONY_SHARE  = 0.5     -- Tony's cut of the extras
Upsell.REFUSED_TIP = 0.5     -- a normal customer's tip is multiplied by this when you try it on

Upsell.EXTRAS = {
	{ id = "tyreair",  label = "Premium tyre air",      price = 15 },
	{ id = "blinker",  label = "Blinker fluid top-up",  price = 10 },
	{ id = "headlight", label = "Headlight fluid",      price = 10 },
	{ id = "muffler",  label = "Muffler bearings",      price = 20 },
	{ id = "exhaust",  label = "Exhaust sharpening",    price = 20 },
	{ id = "polish",   label = "Engine polish",         price = 25 },
} :: { Extra }

local byId: { [string]: Extra } = {}
for _, e in ipairs(Upsell.EXTRAS) do byId[e.id] = e end

function Upsell.Get(id: string): Extra?
	return byId[id]
end

-- The known extras among `ids`, in menu order, each once.
function Upsell.Clean(ids: { any }): { Extra }
	local wanted: { [string]: boolean } = {}
	for _, id in ipairs(ids) do
		if type(id) == "string" and byId[id] then wanted[id] = true end
	end
	local out = {}
	for _, e in ipairs(Upsell.EXTRAS) do
		if wanted[e.id] then table.insert(out, e) end
	end
	return out
end

-- The chance a Clueless customer catches on, for this many extras.
function Upsell.CatchChance(count: number): number
	return math.clamp((count - Upsell.SAFE_EXTRAS) * Upsell.CATCH_STEP, 0, 1)
end

-- What happens when you hand the car back with these extras ticked.
-- `roll` (0–1) is for tests; normally random.
function Upsell.Evaluate(kindId: string, ids: { any }, roll: number?): Result
	local extras = Upsell.Clean(ids)
	if #extras == 0 then
		return { outcome = "none", lines = {}, total = 0, catchChance = 0 }
	end
	if kindId ~= "clueless" then
		return { outcome = "refused", lines = {}, total = 0, catchChance = 1 }
	end
	local chance = Upsell.CatchChance(#extras)
	if (roll or math.random()) < chance then
		return { outcome = "caught", lines = {}, total = 0, catchChance = chance }
	end
	local total = 0
	for _, e in ipairs(extras) do total += e.price end
	return { outcome = "paid", lines = extras, total = total, catchChance = chance }
end

return Upsell
