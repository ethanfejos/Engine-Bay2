--!strict
--[[
    TonyService (ModuleScript, started by Main)
    -------------------------------------------
    Tony the landlord's money side: his mood, his taxes and your debt to him.
    (Renting the bay itself, and Tony standing in the garage, are
    BayRentalService.)

    MOOD — one for the whole server. A new one is picked every
    MOOD_MINUTES and Tony announces it to everyone. The mood sets his cut,
    how often he pockets a tip, the rent per minute, the cancellation fine
    and the interest rate (MOODS below).

    DEBT — saved in profile.Data.tonyDebt. Money never goes below $0: when
    Tony charges more than you have (rent, a fine), you pay what you can and
    the rest goes on your debt ("You owe Tony $X").

    SETTLING A JOB (SettleJob, called by JobService when a car is handed back):
        1. Tony's cut: the mood's % of the job's pay
        2. the tip: kept, or Tony pockets it (the mood's chance)
        3. interest: only while you owe under WORK_OFF_AT, the mood's %
        4. repayment: REPAY_SHARE of what you take home (pay after the cut,
           plus the tip) goes to the debt — WORK_OFF_SHARE (and no interest)
           once you owe WORK_OFF_AT or more
    Interest only ever comes at the end of a job, so it never grows while
    you're offline. Every amount is whole dollars.

    Rent (BayRentalService) is noted here per job too (NoteRent /
    TakeRentTally) so the receipt can show what the bay cost during it.

    TonyStatus (server -> client): { debt, mood = { id, label, face },
    rent = { bay, perMinute, nextCharge } or nil } — the HUD's debt line,
    and the rent panel (nextCharge is in workspace:GetServerTimeNow() time).
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules        = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local Remotes        = require(Modules:WaitForChild("Remotes"))
local Signal         = require(Modules:WaitForChild("Signal"))
local Log            = require(Modules:WaitForChild("Log"))
local ProfileManager = require(script.Parent.Parent.Modules.ProfileManager)
local MoneyService   = require(script.Parent.MoneyService)

local log = Log.new("TonyService")

-- ── Config ────────────────────────────────────────────────────────────────────

local NAME           = "Tony"
-- Rent per minute in a normal mood. The real game: $3. Testing: $1.
local RENT_BASE      = MoneyService.TEST_FLAT_COST
local MOOD_MINUTES   = 20
local WORK_OFF_AT    = 200   -- owing this much or more: he takes WORK_OFF_SHARE, no interest
local REPAY_SHARE    = 0.50
local WORK_OFF_SHARE = 0.75
local LOAN_AMOUNTS   = { 50, 100, 200 } -- what Desperate Tony will lend
local LOAN_FEE       = 0.30  -- added to what you owe: borrow $100, owe $130
local LOAN_LIMIT     = 200   -- no loans once you owe this much

export type Mood = {
	id: string,
	label: string,       -- shown on the receipt and Tony's prompt
	face: string,        -- shown above Tony's head
	weight: number,      -- how likely it is to be picked
	cut: number,         -- share of each job's pay
	tipSteal: number,    -- chance he pockets the tip
	rent: number,        -- multiplies RENT_BASE
	cancelFine: number,  -- share of the job's pay
	interest: number,    -- per finished job, while owing under WORK_OFF_AT
	lines: { [string]: string },
}

local MOODS: { Mood } = {
	{
		id = "good", label = "good day", face = "😄", weight = 20,
		cut = 0.15, tipSteal = 1 / 6, rent = 2 / 3, cancelFine = 0.30, interest = 0.10,
		lines = {
			announce = "Lovely day, eh? Feeling generous. Don't get used to it.",
			rented   = "Bay %s's yours, kid. $%d a minute. Practically charity.",
			tab      = "No cash? Eh, it goes on your tab. Today only, I'm a saint.",
			stoleTip = "I'll mind that tip for you. Forever.",
			upsold   = "Blinker fluid? Ha! I taught you well. Half's mine.",
			fine     = "Happens. Still costs you $%d.",
			debt     = "Pay me when you can, kid. You owe me $%d.",
		},
	},
	{
		id = "normal", label = "normal", face = "😐", weight = 40,
		cut = 0.20, tipSteal = 1 / 4, rent = 1, cancelFine = 0.40, interest = 0.10,
		lines = {
			announce = "Right. Back to business. Rent's normal, my cut's normal.",
			rented   = "Bay %s's yours. $%d a minute, every minute. Customers'll turn up.",
			tab      = "No cash? It goes on your tab. And I don't forget a tab.",
			stoleTip = "Tip? Business expenses.",
			upsold   = "Blinker fluid? Ha! I taught you well. Half of that's mine.",
			fine     = "You turned away a paying customer. That's $%d.",
			debt     = "You owe me $%d. Don't forget it.",
		},
	},
	{
		id = "grumpy", label = "grumpy", face = "😠", weight = 20,
		cut = 0.25, tipSteal = 1 / 3, rent = 1.5, cancelFine = 0.50, interest = 0.10,
		lines = {
			announce = "Bad week. Rent's up. Bigger cut. Don't argue.",
			rented   = "Bay %s. $%d a minute. Rent's up. Don't argue.",
			tab      = "Broke AGAIN? Fine. Tab. With interest.",
			stoleTip = "Tip? What tip?",
			upsold   = "Nice. Now hand over my half.",
			fine     = "Cancelling on my time? $%d. Pay up.",
			debt     = "You owe me $%d. Interest is up. Funny how that works.",
		},
	},
	{
		id = "furious", label = "furious", face = "🤬", weight = 10,
		cut = 0.30, tipSteal = 1 / 2, rent = 2, cancelFine = 0.60, interest = 0.10,
		lines = {
			announce = "SOMEONE scratched my car. DOUBLE RENT. EVERYONE.",
			rented   = "BAY %s. $%d A MINUTE. GET OUT OF MY FACE.",
			tab      = "NO MONEY?! TAB. I'M WRITING IT IN PEN.",
			stoleTip = "MINE.",
			upsold   = "HALF. NOW.",
			fine     = "You just cost me money. $%d. NOW.",
			debt     = "$%d. Every job, you pay me. Every. Single. One.",
		},
	},
	{
		id = "desperate", label = "desperate", face = "💸", weight = 10,
		cut = 0.20, tipSteal = 1 / 4, rent = 1, cancelFine = 0.40, interest = 0.15,
		lines = {
			announce = "Listen... business is slow. Interest is fifteen percent now. Nothing personal.",
			rented   = "Bay %s, $%d a minute. Please. I need this.",
			tab      = "On the tab, sure, sure. Fifteen percent. I've got bills, kid.",
			stoleTip = "I'll, uh, borrow that tip.",
			upsold   = "Oh thank god. I'll take half of that, if that's alright.",
			fine     = "Cancelling? I need that money! $%d.",
			debt     = "You owe me $%d. Any chance you could pay it faster?",
		},
	},
}

-- ── State ─────────────────────────────────────────────────────────────────────

local TonyService = {}
TonyService.NAME = NAME
TonyService.MoodChanged = Signal.new() -- (mood)

local mood: Mood = MOODS[2] -- normal until the first pick

type RentInfo = {
	bay: string,
	perMinute: number,
	nextCharge: number,
	strikes: number?,       -- late payments (BayRentalService); 5 = evicted
	inspectAt: number?,     -- workspace:GetServerTimeNow() when the announced inspection happens
}
local rentInfo: { [Player]: RentInfo } = {}
type Tally = { minutes: number, amount: number }
local rentTally: { [Player]: Tally } = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function round(n: number): number
	return math.floor(n + 0.5)
end

local function profileOf(player: Player)
	return ProfileManager.GetProfile(player)
end

local function pushStatus(player: Player)
	local profile = profileOf(player)
	if not profile then return end
	Remotes.TonyStatus:FireClient(player, {
		debt = profile.Data.tonyDebt,
		mood = { id = mood.id, label = mood.label, face = mood.face },
		rent = rentInfo[player],
	})
end

local function addDebt(player: Player, amount: number, reason: string)
	local profile = profileOf(player)
	if not profile or amount == 0 then return end
	profile.Data.tonyDebt = math.max(0, profile.Data.tonyDebt + amount)
	log.debug(("%s debt %+d (%s) — owes $%d"):format(player.Name, amount, reason, profile.Data.tonyDebt))
	pushStatus(player)
end

-- ── Public: mood ──────────────────────────────────────────────────────────────

function TonyService.GetMood(): Mood
	return mood
end

-- One of the current mood's lines, formatted. ("rented", "tab", "fine", ...)
function TonyService.Line(kind: string, ...: any): string
	local line = mood.lines[kind] or ""
	if select("#", ...) > 0 then
		local ok, text = pcall(string.format, line, ...)
		return if ok then text else line
	end
	return line
end

-- Says a line to one player (shown by BayRentalUI as Tony's note, stamped
-- with his mood).
function TonyService.Say(player: Player, text: string)
	Remotes.NpcSpeech:FireClient(player, NAME, text, { kind = "tony", mood = mood.id, moodLabel = mood.label })
end

-- Rent per minute right now, whole dollars, at least $1.
function TonyService.RentPerMinute(): number
	return math.max(1, round(RENT_BASE * mood.rent))
end

-- ── Public: debt ──────────────────────────────────────────────────────────────

function TonyService.GetDebt(player: Player): number
	local profile = profileOf(player)
	return if profile then profile.Data.tonyDebt else 0
end

-- Tony charges `amount`: you pay what you can, the rest goes on your debt.
-- Returns (paid, addedToDebt).
function TonyService.Charge(player: Player, amount: number, reason: string): (number, number)
	amount = round(amount)
	if amount <= 0 or not profileOf(player) then return 0, 0 end
	local money = MoneyService.GetMoney(player) or 0
	local paid = math.clamp(money, 0, amount)
	if paid > 0 then
		MoneyService.TrySpend(player, paid, reason)
	end
	local owed = amount - paid
	if owed > 0 then
		addDebt(player, owed, reason)
	end
	return paid, owed
end

-- Knocks `amount` off (or, negative, adds to) the player's debt.
function TonyService.AdjustDebt(player: Player, amount: number, reason: string)
	addDebt(player, -round(amount), reason)
end

-- ── Public: loans (Desperate mood only) ───────────────────────────────────────

TonyService.LOAN_AMOUNTS = LOAN_AMOUNTS
TonyService.LOAN_FEE = LOAN_FEE
TonyService.LOAN_LIMIT = LOAN_LIMIT

-- Whether Tony will lend to this player right now, and why not.
function TonyService.CanLoan(player: Player): (boolean, string?)
	if mood.id ~= "desperate" then return false, "notDesperate" end
	if TonyService.GetDebt(player) >= LOAN_LIMIT then return false, "tooMuchDebt" end
	return true, nil
end

-- Lends `amount` (one of LOAN_AMOUNTS): the cash now, plus the fee on your
-- debt. Returns what you now owe for it, or nil if he won't.
function TonyService.TakeLoan(player: Player, amount: number): number?
	if not table.find(LOAN_AMOUNTS, amount) or not TonyService.CanLoan(player) then return nil end
	local owed = round(amount * (1 + LOAN_FEE))
	MoneyService.AddMoney(player, amount, "loan from Tony")
	addDebt(player, owed, "loan")
	return owed
end

-- ── Public: rent bookkeeping (BayRentalService) ───────────────────────────────

-- The rent panel's numbers for this player, or nil when they have no bay.
function TonyService.SetRentInfo(player: Player, info: RentInfo?)
	if info then
		rentInfo[player] = info
	else
		rentInfo[player] = nil
	end
	pushStatus(player)
end

-- Rent charged since the last TakeRentTally (for the receipt).
function TonyService.NoteRent(player: Player, amount: number)
	local tally = rentTally[player] or { minutes = 0, amount = 0 }
	tally.minutes += 1
	tally.amount += amount
	rentTally[player] = tally
end

-- Rent noted since the last call, and starts counting again from zero.
function TonyService.TakeRentTally(player: Player): Tally
	local tally = rentTally[player] or { minutes = 0, amount = 0 }
	rentTally[player] = nil
	return tally
end

-- ── Public: jobs (JobService) ─────────────────────────────────────────────────

export type Settlement = {
	pay: number,          -- the job's pay before Tony
	cut: number,          -- Tony's cut
	cutPercent: number,   -- 20 (for "Tony's cut (20%, normal)")
	moodLabel: string,
	tip: number,          -- the tip the customer gave
	tipStolen: boolean,   -- Tony pocketed it
	extras: number,       -- extras the customer paid for (Upsell)
	extrasCut: number,    -- Tony's share of them
	interest: number,     -- added to the debt
	repayment: number,    -- taken off what you'd take home, towards the debt
	debtBefore: number,
	debtAfter: number,
	total: number,        -- what lands in your money
}

-- Works out (and applies) Tony's side of a finished job: takes the cut,
-- maybe the tip, his share of any extras, adds interest, takes the
-- repayment, and pays the player the rest. Returns every number for the
-- receipt.
function TonyService.SettleJob(player: Player, pay: number, tip: number, extras: number?, extrasShare: number?): Settlement
	local profile = profileOf(player)
	local debtBefore = if profile then profile.Data.tonyDebt else 0

	local cut = round(pay * mood.cut)
	local tipStolen = tip > 0 and math.random() < mood.tipSteal
	local extraTotal = extras or 0
	local extrasCut = round(extraTotal * (extrasShare or 0))
	local takeHome = pay - cut + (if tipStolen then 0 else tip) + extraTotal - extrasCut

	local interest, repayment = 0, 0
	local debt = debtBefore
	if debt > 0 then
		if debt < WORK_OFF_AT then
			interest = math.max(1, round(debt * mood.interest))
			debt += interest
			repayment = math.min(debt, round(takeHome * REPAY_SHARE))
		else
			repayment = math.min(debt, round(takeHome * WORK_OFF_SHARE))
		end
		debt -= repayment
	end

	local total = takeHome - repayment
	if profile then
		profile.Data.tonyDebt = debt
	end
	if total > 0 then
		MoneyService.AddMoney(player, total, "job")
	end
	pushStatus(player)

	return {
		pay        = pay,
		cut        = cut,
		cutPercent = round(mood.cut * 100),
		moodLabel  = mood.label,
		tip        = tip,
		tipStolen  = tipStolen,
		extras     = extraTotal,
		extrasCut  = extrasCut,
		interest   = interest,
		repayment  = repayment,
		debtBefore = debtBefore,
		debtAfter  = debt,
		total      = total,
	}
end

-- The cancellation fine for a job paying `pay`: charged now (onto the debt
-- if you can't cover it). Returns the fine.
function TonyService.CancelFine(player: Player, pay: number): number
	local fine = math.max(1, round(pay * mood.cancelFine))
	TonyService.Charge(player, fine, "cancellation fine")
	return fine
end

-- ── Mood changes ──────────────────────────────────────────────────────────────

local function pickMood(): Mood
	local total = 0
	for _, m in ipairs(MOODS) do total += m.weight end
	local roll = math.random() * total
	for _, m in ipairs(MOODS) do
		roll -= m.weight
		if roll <= 0 then return m end
	end
	return MOODS[#MOODS]
end

local function setMood(new: Mood, announce: boolean)
	mood = new
	ReplicatedStorage:SetAttribute("TonyMood", new.id)
	log.info("Tony's mood:", new.label)
	TonyService.MoodChanged:Fire(new)
	for _, player in ipairs(Players:GetPlayers()) do
		pushStatus(player)
		if announce then
			TonyService.Say(player, new.lines.announce)
		end
	end
end

task.spawn(function()
	setMood(pickMood(), false)
	while true do
		task.wait(MOOD_MINUTES * 60)
		-- Always a change: re-pick a few times if it lands on the same mood.
		local new = pickMood()
		for _ = 1, 5 do
			if new ~= mood then break end
			new = pickMood()
		end
		setMood(new, true)
	end
end)

-- Testing (DevService): switch Tony's mood now. Returns false for an unknown id.
function TonyService.ForceMood(id: string): boolean
	for _, m in ipairs(MOODS) do
		if m.id == id then
			setMood(m, true)
			return true
		end
	end
	return false
end

-- Testing (DevService): the mood ids, in order.
function TonyService.MoodIds(): { string }
	local ids = {}
	for _, m in ipairs(MOODS) do table.insert(ids, m.id) end
	return ids
end

-- ── Players ───────────────────────────────────────────────────────────────────

ProfileManager.OnProfileLoaded(function(player)
	pushStatus(player)
end)

-- The HUD scripts ask for their money on join; send Tony's status with it
-- (a status pushed before a script was listening would be missed).
Remotes.RequestMoney.OnServerEvent:Connect(pushStatus)

Players.PlayerRemoving:Connect(function(player)
	rentInfo[player] = nil
	rentTally[player] = nil
end)

return TonyService
