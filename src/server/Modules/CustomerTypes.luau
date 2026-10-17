--!strict
--[[
    CustomerTypes (ModuleScript, server)
    ------------------------------------
    The kinds of customer that bring cars in (JobService), and which ones
    your reputation attracts. Tune everything here.

    Each type sets:
    - pay        multiplies the job's pay ($40 a fault)
    - tip        the tip, % of the pay, before patience (range)
    - patience   seconds before they give up and leave
    - fixedAt    a fault counts as fixed at this condition % (Fussy: 90)
    - minStars   your reputation needed before they turn up
    - weight     how often they turn up, among the types you've unlocked
    - requests   what they say ("%s" = the parts, e.g. "the Starter and the Fan")

    Clueless customers are special: they turn up by chance (CLUELESS_CHANCE,
    about 1 in 15, at any reputation) rather than by weight, and they look
    like Regulars on the job board and work order — you spot them from what
    they say. They'll pay for extras they don't need (Upsell).

    Patience: finishing fast keeps the tip whole; the slower you are, the
    smaller it gets (down to TIP_FLOOR of it). If patience runs out the
    customer leaves angry — no pay, a reputation hit, and Tony's fine.
]]

export type CustomerType = {
	id: string,
	label: string,          -- shown on the work order ("RICH")
	pay: number,
	tip: { number },        -- { min %, max % }
	patience: number,       -- seconds
	fixedAt: number,        -- %
	minStars: number,
	weight: number,
	perfectBonus: boolean,  -- a quick, perfect job earns the bigger reputation bump
	requests: { string },
	leaving: string,        -- what they say when they run out of patience
}

local CustomerTypes = {}

-- The tip never shrinks below this share of the full tip, however slow.
CustomerTypes.TIP_FLOOR = 0.3

-- How often a customer is Clueless (whatever your reputation).
CustomerTypes.CLUELESS_CHANCE = 1 / 15

-- A job handed back with at least this share of patience left is "quick".
CustomerTypes.QUICK_SHARE = 0.5

local TYPES: { CustomerType } = {
	{
		id = "regular", label = "REGULAR",
		pay = 1, tip = { 5, 15 }, patience = 10 * 60, fixedAt = 70,
		minStars = 0, weight = 40, perfectBonus = false,
		requests = {
			"Reckon %s is stuffed. Fix it up for me?",
			"Something's off with %s. Can you take a look?",
			"%s needs sorting. Cheers, mate.",
		},
		leaving = "I've waited long enough. I'm taking it somewhere else.",
	},
	{
		id = "cheapskate", label = "CHEAPSKATE",
		pay = 0.7, tip = { 0, 0 }, patience = 12 * 60, fixedAt = 70,
		minStars = 0, weight = 25, perfectBonus = false,
		requests = {
			"%s is playing up. I'm not paying full price though. Take it or leave it.",
			"Fix %s. And don't you dare charge me the full whack.",
			"My cousin says %s is a five-minute job. So I'm paying for five minutes.",
		},
		leaving = "This is taking forever. I'm not paying for this. Bye.",
	},
	{
		id = "fussy", label = "FUSSY",
		pay = 1, tip = { 20, 30 }, patience = 10 * 60, fixedAt = 90,
		minStars = 1, weight = 15, perfectBonus = true,
		requests = {
			"%s needs doing. PROPERLY. Not just patched up.",
			"I want %s like new. 90%% or better. I will check.",
			"Please be careful with %s. My last mechanic was a butcher.",
		},
		leaving = "Unacceptable. I'll be leaving a review.",
	},
	{
		id = "rush", label = "RUSH JOB",
		pay = 1.3, tip = { 10, 20 }, patience = 4 * 60, fixedAt = 70,
		minStars = 2, weight = 12, perfectBonus = false,
		requests = {
			"Quick! %s died and I've got to be somewhere in four minutes!",
			"Hurry, hurry! %s — I'm late for my own wedding!",
			"No time to chat. %s. Go go go!",
		},
		leaving = "Too slow! I'll call a taxi!",
	},
	{
		id = "rich", label = "RICH",
		pay = 1.5, tip = { 20, 35 }, patience = 6 * 60, fixedAt = 70,
		minStars = 3, weight = 8, perfectBonus = true,
		requests = {
			"Darling, %s is making a frightful noise. Chop chop, I've a lunch at the club.",
			"%s, please. Money's no object. Time is.",
			"Sort out %s and there's a little something extra in it for you.",
		},
		leaving = "I don't wait. Ever. Goodbye.",
	},
	{
		-- Looks like a Regular (same label); picked by CLUELESS_CHANCE, not weight.
		id = "clueless", label = "REGULAR",
		pay = 1, tip = { 5, 15 }, patience = 10 * 60, fixedAt = 70,
		minStars = 0, weight = 0, perfectBonus = false,
		requests = {
			"The car makes a noise. Or maybe that's the radio? My cousin reckons it's %s.",
			"Is the engine the one in the front? Anyway, %s apparently. Whatever that is.",
			"My cousin said it needs new blinker fluid. And something about %s.",
			"I don't really know cars. Someone said %s? Is that bad?",
		},
		leaving = "Oh, it's been ages. I'll just push it home I guess.",
	},
}

local byId: { [string]: CustomerType } = {}
for _, t in ipairs(TYPES) do byId[t.id] = t end

CustomerTypes.All = TYPES

-- The type with this id, or Regular (older saved jobs have no type).
function CustomerTypes.Get(id: string?): CustomerType
	return (id and byId[id]) or byId.regular
end

-- The types your reputation attracts.
function CustomerTypes.Unlocked(stars: number): { CustomerType }
	local out = {}
	for _, t in ipairs(TYPES) do
		if stars >= t.minStars and t.weight > 0 then table.insert(out, t) end
	end
	return out
end

-- A random customer type for a player with `stars` reputation (now and
-- then a Clueless one). `roll` (0–1) is for tests; normally random, and a
-- test roll never gives Clueless.
function CustomerTypes.Pick(stars: number, roll: number?): CustomerType
	if roll == nil and math.random() < CustomerTypes.CLUELESS_CHANCE then
		return byId.clueless
	end
	local pool = CustomerTypes.Unlocked(stars)
	local total = 0
	for _, t in ipairs(pool) do total += t.weight end
	local r = (roll or math.random()) * total
	for _, t in ipairs(pool) do
		r -= t.weight
		if r <= 0 then return t end
	end
	return pool[#pool]
end

-- How many faults a job can have at this reputation: simple jobs (1) until
-- you have a star.
function CustomerTypes.MaxFaults(stars: number): number
	return if stars < 1 then 1 else 2
end

-- The tip for a job paying `pay`, given the share of patience left (0–1).
-- `roll` (0–1) is for tests.
function CustomerTypes.Tip(t: CustomerType, pay: number, patienceLeft: number, roll: number?): number
	if t.tip[2] <= 0 then return 0 end
	local r = roll or math.random()
	local percent = t.tip[1] + (t.tip[2] - t.tip[1]) * r
	local keep = CustomerTypes.TIP_FLOOR + (1 - CustomerTypes.TIP_FLOOR) * math.clamp(patienceLeft, 0, 1)
	return math.floor(pay * percent / 100 * keep + 0.5)
end

-- "the Starter" / "the Starter and the Fan" / "the Starter, the Fan and the Belt"
function CustomerTypes.PartList(labels: { string }): string
	local named = {}
	for i, l in ipairs(labels) do named[i] = "the " .. l end
	if #named <= 1 then return named[1] or "the car" end
	return table.concat(named, ", ", 1, #named - 1) .. " and " .. named[#named]
end

-- What this customer says when they drop the car off.
function CustomerTypes.Request(t: CustomerType, labels: { string }): string
	local line = t.requests[math.random(1, #t.requests)]
	local parts = CustomerTypes.PartList(labels)
	local text = string.format(line, parts)
	-- Capitalise when the parts start the sentence.
	return (string.gsub(text, "^the ", "The "))
end

return CustomerTypes
