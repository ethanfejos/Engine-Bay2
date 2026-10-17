--!strict
--[[
    JobService (ModuleScript, started by Main)
    ------------------------------------------
    Customer jobs. Once a player has rented a bay (BayRentalService calls
    BayRented):

    1. A customer arrives: their car spawns in the bay (CarService.SpawnCar,
       the player as its worker, not its owner) and they stand beside the
       bay wearing one of the player's Roblox friends' avatars, with that
       friend's name (a stand-in customer if there are no friends to use).
       Where they stand: a "CustomerSpot" part inside the bay part if there
       is one, otherwise beside the car on the clear side nearest the player.
    2. Who they are: a customer type (CustomerTypes) — Regular, Cheapskate,
       Fussy, Rush job or Rich — picked from the types your reputation has
       unlocked. The type sets the pay, the tip, how patient they are, and
       how good "fixed" has to be (Fussy: 90%).
    3. The work order: 1 named fault (until you have a star), then 1–2.
       The car is built so those parts are badly worn (FAULT_WEAR) and
       everything else is healthy.
    4. The player fixes them with the existing tools: remove, repair or
       replace at the bench, reinstall. Progress is re-checked every time a
       part comes out or goes back in (CarService.CarChanged).
    5. Hand back: talk to the customer. Accepted only when every fault is at
       the customer's standard and no part is missing. They pay, plus a tip
       that shrinks the longer they waited; Tony settles it (TonyService:
       his cut, maybe the tip, interest and debt repayment) and you get the
       rest, XP and reputation (more with half their patience left, most
       for Fussy and Rich customers); the next customer turns up after
       NEXT_CUSTOMER_DELAY.
    6. Out of patience: they leave with the car, angry — no pay, Tony's
       fine, and a reputation hit (ReputationService.CHANGES.walkedOut).

    THE QUEUE AND THE JOB BOARD (phase 5): customers don't walk straight in.
    Up to MAX_QUEUE wait outside your bay — one turns up every ARRIVAL_GAP
    seconds while there's room. Each waits QUEUE_WAIT seconds (a Rush job
    less) before giving up, with no penalty. You pick one on the job board
    (JobBoardUI; JobQueue server -> client, TakeJob client -> server); then
    their car comes in and the job runs as above.

    THE CAR PARK: while they queue, each customer waits outside with their
    car in a parking space (a look-alike, CarService.SpawnParked). You can
    walk up and take the job there too ("Take job" prompt, only you see it).
    Spaces: parts in Workspace.ParkingSpots with a "Bay" attribute naming
    the bay they belong to (the bay part's name, e.g. "Mechanic_1"); the
    lowest "Order" attribute (then name) fills first. A "CustomerSpot" part
    inside a space is where the customer stands; otherwise beside the car.
    No free space for your bay: they still queue, just on the board only.

    REGULARS (phase 5): from REGULAR_STARS, a customer whose job you handed
    back quickly remembers you (profile.Data.regulars, their car as you
    left it). Now and then (REPEAT_CHANCE) a regular comes back instead of
    a stranger: same car, new problem, REPEAT_TIP times the tip. One who
    walks out on you (or whose job you cancel) stops coming back.

    EXTRAS (Upsell): once the work's done, the work order lists extras you
    can tick (SetExtras, client -> server) before handing back. A normal
    customer refuses and tips less; a Clueless one pays — unless you push
    it and they catch on (no extras, a reputation hit, never back). Tony
    takes his share of extras paid.

    Saved: the job, with the customer's car as it is right now, lives in
    profile.Data.activeJob. Leaving mid-job saves it; renting a bay again
    brings the same customer and car back. Their patience pauses while
    you're away (JobRecord.waited).

    Cancel (CancelJob, client -> server): the car goes home with all its
    parts — any on the floor or in the inventory are taken back — Tony
    fines you (TonyService.CancelFine), you lose reputation, and the next
    customer comes. Losing the bay mid-job (handing back the keys, or Tony
    kicking you out for doing nothing) counts as a cancel too (BayReleased).

    Remotes: JobUpdated (server -> client) sends the work order to the
    JobUI (or nil when there's no job); JobReceipt sends the receipt shown
    when a car is handed back; the customer talks via NpcSpeech.
]]

local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Modules           = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local Remotes           = require(Modules:WaitForChild("Remotes"))
local Log               = require(Modules:WaitForChild("Log"))
local ProfileManager    = require(script.Parent.Parent.Modules.ProfileManager)
local SaveData          = require(script.Parent.Parent.Modules.SaveData)
local Npc               = require(script.Parent.Parent.Modules.Npc)
local CustomerTypes     = require(script.Parent.Parent.Modules.CustomerTypes)
local Upsell            = require(script.Parent.Parent.Modules.Upsell)
local CarService        = require(script.Parent.CarService)
local LevelService      = require(script.Parent.LevelService)
local InventoryService  = require(script.Parent.InventoryService)
local PartPickupService = require(script.Parent.PartPickupService)
local ReputationService = require(script.Parent.ReputationService)
local TonyService       = require(script.Parent.TonyService)

local log = Log.new("JobService")

type JobRecord = SaveData.JobRecord

-- ── Config ────────────────────────────────────────────────────────────────────

local PAY_PER_FAULT        = 40
local FAULTS_MIN           = 1
local FAULTS_MAX           = 2
local FAULT_WEAR           = { 5, 25 }   -- a faulty part's condition, %
local HEALTHY_WEAR         = { 75, 100 } -- every other part, %
local FIRST_CUSTOMER_DELAY = 3           -- seconds after renting
local NEXT_CUSTOMER_DELAY  = 6           -- seconds after a job ends
local CUSTOMER_GAP         = 3           -- studs between the bay's edge and the customer (when no CustomerSpot)
local PROMPT_REACH         = 10
local PARKED_GAP           = 2           -- studs between a parking space's side and its waiting customer
local LAST_CHANCE          = 30          -- seconds of patience a resumed job gets if it had none left
local MAX_QUEUE            = 3           -- customers waiting outside at once
local ARRIVAL_GAP          = 12          -- seconds between customers joining the queue
local QUEUE_WAIT           = 150         -- seconds a queued customer waits before giving up
local RUSH_QUEUE_WAIT      = 60          -- ...a Rush job, less
local REGULAR_STARS        = 3           -- reputation from which customers become regulars
local REPEAT_CHANCE        = 0.35        -- chance a new arrival is a regular coming back
local REPEAT_TIP           = 1.5         -- regulars tip this much more
local TONY_LINE_DELAY      = 2.5         -- seconds between the customer's line and Tony butting in

-- Stand-in customers when there are no friends to use.
local FALLBACK_NAMES = { "Dave", "Mere", "Tama", "Sharon", "Wiremu", "Kev", "Aroha", "Brent" }

local LINES = {
	notDone   = "Not done yet, mate. Still waiting on: %s.",
	thanks    = "Legend, cheers! Here's your $%d.",
	cancelled = "No worries, I'll take it somewhere else.",
	lostBay   = "Where's my car going?! Forget it, I'm off.",
	notYours  = "Sorry, I'm waiting on someone else.",
	backAgain = "Back again! You did a great job last time. ",
	refused   = "%s? Do I look stupid? Just the job, thanks. Here's your $%d.",
	caught    = "Hang on. %s isn't even a thing, is it? I'm not paying for any of that. Here's your $%d.",
	paidExtras = "Wow, all that? Thanks for looking after it so well! Here's your $%d.",
	gaveUp    = "Been standing out here for ages. I'm off.",
	firstHint = "Customers are lining up outside your bay. Job board's on the wall — press J and pick one.",
}

local JobService = {}

-- ── State ─────────────────────────────────────────────────────────────────────

type Active = {
	job: JobRecord,
	kind: CustomerTypes.CustomerType,
	bay: BasePart,
	car: Model,
	customer: Model?,
	startedAt: number,     -- os.clock() when the car arrived (this session)
	startedServer: number, -- workspace:GetServerTimeNow() when the job started, earlier sessions included (the work order's timer)
	patience: number,      -- seconds the customer waits in total
	deadline: number,      -- workspace:GetServerTimeNow() when their patience runs out
	extras: { string },    -- extras ticked on the work order (Upsell)
}

local active: { [Player]: Active } = {}      -- the job each player is working on
local bays: { [Player]: BasePart } = {}      -- each player's rented bay
local nextToken: { [Player]: number } = {}   -- so only the latest "next customer" timer counts
local lastWork: { [Player]: number } = {}    -- os.clock() of the player's last work (for Tony's idle check)

type Queued = {
	job: JobRecord,
	kind: CustomerTypes.CustomerType,
	wait: number,      -- seconds they'll wait outside in total
	deadline: number,  -- workspace:GetServerTimeNow() when they give up
	spot: BasePart?,   -- their parking space, if they got one
	parked: Model?,    -- their car waiting in it
	waiting: Model?,   -- the customer standing by it
	gone: boolean?,    -- left the queue (taken or gave up): don't show them
}
local queues: { [Player]: { Queued } } = {}  -- customers waiting outside each player's bay
local hinted: { [Player]: boolean } = {}     -- Tony has explained the job board this shift

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function randomIn(range: { number }): number
	return math.random(range[1], range[2])
end

-- "Alternator", "Belts/Fan#2" -> "Alternator", "Fan"
local function partLabel(path: string): string
	local last = string.match(path, "([^/]+)$") or path
	return (string.gsub(last, "#%d+$", ""))
end

local function say(player: Player, job: JobRecord, text: string)
	Remotes.NpcSpeech:FireClient(player, job.customerName, text,
		{ kind = "customer", userId = job.customerUserId, car = job.car.model })
end

-- Tony butts in a moment after the customer has spoken.
local function tonyLater(player: Player, delay: number, text: string)
	task.delay(delay, function()
		if player:IsDescendantOf(Players) then TonyService.Say(player, text) end
	end)
end

local function worked(player: Player)
	lastWork[player] = os.clock()
end

local function deepCopy<T>(t: T): T
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t :: any) do out[k] = deepCopy(v) end
	return out :: any
end

-- Who a regular is: their friend's UserId, or the stand-in name.
local function regularKey(name: string, userId: number?): string
	return if userId then tostring(userId) else "name:" .. name
end

-- Fixed = back in the car at the customer's standard (Fussy wants 90%).
local function isFixed(job: JobRecord, path: string): boolean
	return not job.car.missing[path] and (job.car.wear[path] or 100) >= CustomerTypes.Get(job.kind).fixedAt
end

-- Share of the customer's patience left right now (0–1).
local function patienceLeft(a: Active): number
	return math.clamp((a.deadline - Workspace:GetServerTimeNow()) / a.patience, 0, 1)
end

-- Parts (not faults) that are out of the car right now.
local function otherMissing(job: JobRecord): { string }
	local faults: { [string]: boolean } = {}
	for _, path in ipairs(job.faults) do faults[path] = true end
	local out: { string } = {}
	for _, path in ipairs(CarService.GetPartPaths(job.car.model)) do
		if job.car.missing[path] and not faults[path] then
			table.insert(out, partLabel(path))
		end
	end
	return out
end

type Task = { label: string, done: boolean }

-- The work order's checklist, and whether the car can be handed back.
local function progress(job: JobRecord): ({ Task }, boolean)
	local tasks: { Task } = {}
	local complete = true
	local fixedAt = CustomerTypes.Get(job.kind).fixedAt
	local standard = if fixedAt > 70 then (" (%d%%+)"):format(fixedAt) else ""
	for _, path in ipairs(job.faults) do
		local done = isFixed(job, path)
		table.insert(tasks, { label = "Fix the " .. partLabel(path) .. standard, done = done })
		complete = complete and done
	end
	local missing = otherMissing(job)
	if #missing > 0 then
		table.insert(tasks, { label = "Put back: " .. table.concat(missing, ", "), done = false })
		complete = false
	end
	return tasks, complete
end

-- The extras menu for the work order, with what's ticked.
local function extrasFor(a: Active): { { id: string, label: string, price: number, selected: boolean } }
	local ticked: { [string]: boolean } = {}
	for _, id in ipairs(a.extras) do ticked[id] = true end
	local out = {}
	for _, e in ipairs(Upsell.EXTRAS) do
		table.insert(out, { id = e.id, label = e.label, price = e.price, selected = ticked[e.id] == true })
	end
	return out
end

local function sendUpdate(player: Player)
	local a = active[player]
	if not a then
		Remotes.JobUpdated:FireClient(player, nil)
		return
	end
	local tasks, complete = progress(a.job)
	Remotes.JobUpdated:FireClient(player, {
		customerName   = a.job.customerName,
		customerUserId = a.job.customerUserId,
		car            = a.job.car.model,
		request        = a.job.request,
		pay            = a.job.pay,
		tasks          = tasks,
		complete       = complete,
		startedAt      = a.startedServer,
		quickSeconds   = a.patience * (1 - CustomerTypes.QUICK_SHARE),
		customerType   = a.kind.label,
		-- Clueless customers look like Regulars on the work order.
		customerKind   = if a.kind.id == "clueless" then "regular" else a.kind.id,
		repeatVisit    = a.job.repeatVisit == true,
		patience       = a.patience,
		deadline       = a.deadline,
		-- What cancelling would cost right now (shown before you confirm).
		cancelFine     = math.max(1, math.floor(a.job.pay * TonyService.GetMood().cancelFine + 0.5)),
		cancelStars    = -ReputationService.CHANGES.cancelled,
		extras         = if complete then extrasFor(a) else nil,
	})
end

-- Where the customer stands, facing the bay:
-- 1. a Part named "CustomerSpot" inside the bay part, if you've placed one
--    (they stand on top of it) — exact control for any bay;
-- 2. otherwise beside the car: one of the bay's two LONG sides (the car lies
--    along the bay, so that's next to its doors, not at its nose or tail),
--    with real floor under it and nothing solid in the way, the one closest
--    to the player (who's inside the garage). Only if both long sides are
--    blocked does it use an end of the bay.
local function customerSpot(bay: BasePart, player: Player): CFrame
	local function facingBay(ground: Vector3): CFrame
		return CFrame.lookAt(ground, Vector3.new(bay.Position.X, ground.Y, bay.Position.Z))
	end

	local placed = bay:FindFirstChild("CustomerSpot")
	if placed and placed:IsA("BasePart") then
		return facingBay(placed.Position + Vector3.new(0, placed.Size.Y / 2, 0))
	end

	local ignore: { Instance } = {}
	for _, name in ipairs({ "EngineZones", "Cars", "ParkedCars", "ParkingSpots", "NPCs", "DroppedParts" }) do
		local folder = Workspace:FindFirstChild(name)
		if folder then table.insert(ignore, folder) end
	end
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		if char then table.insert(ignore, char) end
	end
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = ignore
	rayParams.RespectCanCollide = true
	local boxParams = OverlapParams.new()
	boxParams.FilterType = Enum.RaycastFilterType.Exclude
	boxParams.FilterDescendantsInstances = ignore
	boxParams.RespectCanCollide = true

	local function flat(v: Vector3): Vector3
		local f = Vector3.new(v.X, 0, v.Z)
		return if f.Magnitude > 0.01 then f.Unit else Vector3.zero
	end
	local right, forward = flat(bay.CFrame.RightVector), flat(bay.CFrame.LookVector)
	local acrossX = {
		right * (bay.Size.X / 2 + CUSTOMER_GAP),
		-right * (bay.Size.X / 2 + CUSTOMER_GAP),
	}
	local acrossZ = {
		forward * (bay.Size.Z / 2 + CUSTOMER_GAP),
		-forward * (bay.Size.Z / 2 + CUSTOMER_GAP),
	}
	-- Beside the car = across the bay's narrow direction.
	local besideSides, endSides = acrossX, acrossZ
	if bay.Size.Z < bay.Size.X then
		besideSides, endSides = acrossZ, acrossX
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local playerPos = if hrp and hrp:IsA("BasePart") then hrp.Position else nil

	local fallback: Vector3? = nil

	-- The clear spot among `offsets` closest to the player, or nil.
	local function bestOf(offsets: { Vector3 }): Vector3?
		local best: Vector3? = nil
		local bestDist = math.huge
		for _, offset in ipairs(offsets) do
			local pos = bay.Position + offset
			local top = pos + Vector3.new(0, bay.Size.Y / 2, 0)
			local hit = Workspace:Raycast(top, Vector3.new(0, -(bay.Size.Y + 50), 0), rayParams)
			if hit then
				local ground = hit.Position
				fallback = fallback or ground
				-- Room to stand: nothing solid in a person-sized box on the spot.
				local clear = #Workspace:GetPartBoundsInBox(
					CFrame.new(ground + Vector3.new(0, 3, 0)), Vector3.new(2, 5, 2), boxParams) == 0
				if clear then
					local dist = if playerPos then (ground - playerPos).Magnitude else 0
					if dist < bestDist then
						best, bestDist = ground, dist
					end
				end
			end
		end
		return best
	end

	local ground = bestOf(besideSides) or bestOf(endSides) or fallback
		or (bay.Position + besideSides[1] - Vector3.new(0, bay.Size.Y / 2, 0))
	return facingBay(ground)
end

-- ── Jobs ──────────────────────────────────────────────────────────────────────

local scheduleNext -- defined below
local sendQueue: (Player) -> () -- defined below
local cancelJob: (Player, Active, string, number?, string?) -> () -- defined below

local function endJob(player: Player, a: Active)
	if active[player] ~= a then return end
	active[player] = nil
	CarService.DespawnCar(a.job.car.id)
	if a.customer then a.customer:Destroy() end
	local profile = ProfileManager.GetProfile(player)
	if profile and profile.Data.activeJob == a.job then
		profile.Data.activeJob = nil
	end
	sendUpdate(player)
	sendQueue(player) -- the board can offer jobs again
	scheduleNext(player, NEXT_CUSTOMER_DELAY) -- room for another customer in the queue
end

local function handBack(player: Player, triggering: Player, a: Active)
	if active[player] ~= a then return end
	if triggering ~= player then
		say(triggering, a.job, LINES.notYours)
		return
	end

	local tasks, complete = progress(a.job)
	if not complete then
		local left = {}
		for _, t in ipairs(tasks) do
			if not t.done then table.insert(left, t.label) end
		end
		say(player, a.job, LINES.notDone:format(string.lower(table.concat(left, "; "))))
		return
	end

	-- The customer pays; Tony takes his share (TonyService.SettleJob pays
	-- the player the rest).
	-- The tip shrinks the longer they waited (CustomerTypes.Tip).
	local left = patienceLeft(a)
	local tip = CustomerTypes.Tip(a.kind, a.job.pay, left)
	if a.job.repeatVisit then
		tip = math.floor(tip * REPEAT_TIP + 0.5)
	end
	-- Extras: refused (and a smaller tip), paid, or caught out (Upsell).
	local upsell = Upsell.Evaluate(a.kind.id, a.extras)
	if upsell.outcome == "refused" then
		tip = math.floor(tip * Upsell.REFUSED_TIP + 0.5)
	end
	local rent = TonyService.TakeRentTally(player)
	local s = TonyService.SettleJob(player, a.job.pay, tip, upsell.total, Upsell.TONY_SHARE)

	LevelService.AddXP(player, LevelService.XP_AWARDS.job, "job")
	-- Quick = at least half their patience left. Fussy and Rich customers
	-- reward a quick job more (it was done perfectly, to their standard).
	local quick = left >= CustomerTypes.QUICK_SHARE
	local change, why = ReputationService.CHANGES.slowJob, "slow job"
	if quick and a.kind.perfectBonus then
		change, why = ReputationService.CHANGES.perfectJob, "perfect job (" .. a.kind.id .. ")"
	elseif quick then
		change, why = ReputationService.CHANGES.quickJob, "quick job"
	end
	local stars = ReputationService.Add(player, change, why)
	if upsell.outcome == "caught" then
		stars = ReputationService.Add(player, ReputationService.CHANGES.caughtUpsell, "caught upselling")
	end
	InventoryService.RemovePartsFromCar(player, a.job.car.id) -- normally none left

	-- A quick job from REGULAR_STARS up: they'll remember you.
	local profile = ProfileManager.GetProfile(player)
	local regularKeyNow = regularKey(a.job.customerName, a.job.customerUserId)
	if profile and upsell.outcome == "caught" then
		profile.Data.regulars[regularKeyNow] = nil -- they won't be back
	elseif profile and quick and stars >= REGULAR_STARS then
		local key = regularKey(a.job.customerName, a.job.customerUserId)
		local regulars = profile.Data.regulars
		local existing = regulars[key]
		if not existing then
			-- Full: forget the one you've seen least.
			local count, leastKey, leastVisits = 0, nil, math.huge
			for k, r in pairs(regulars) do
				count += 1
				if r.visits < leastVisits then leastKey, leastVisits = k, r.visits end
			end
			if count >= SaveData.MAX_REGULARS and leastKey then regulars[leastKey] = nil end
		end
		regulars[key] = {
			name   = a.job.customerName,
			userId = a.job.customerUserId,
			kind   = a.kind.id,
			car    = deepCopy(a.job.car),
			visits = (if existing then existing.visits else 0) + 1,
		}
	end
	worked(player)

	local paid = a.job.pay + tip + upsell.total
	local firstExtra = Upsell.Clean(a.extras)[1]
	if upsell.outcome == "refused" and firstExtra then
		say(player, a.job, LINES.refused:format(firstExtra.label, paid))
	elseif upsell.outcome == "caught" and firstExtra then
		say(player, a.job, LINES.caught:format(firstExtra.label, paid))
	elseif upsell.outcome == "paid" then
		say(player, a.job, LINES.paidExtras:format(paid))
	else
		say(player, a.job, LINES.thanks:format(paid))
	end
	local delay = TONY_LINE_DELAY
	if upsell.outcome == "paid" then
		tonyLater(player, delay, TonyService.Line("upsold"))
		delay += TONY_LINE_DELAY
	end
	if s.tipStolen then
		tonyLater(player, delay, TonyService.Line("stoleTip"))
		delay += TONY_LINE_DELAY
	end
	if s.debtAfter > 0 then
		tonyLater(player, delay, TonyService.Line("debt", s.debtAfter))
	end

	-- The receipt (ReceiptUI): one line per fault, then the totals.
	local lines = {}
	local each = math.floor(a.job.pay / math.max(1, #a.job.faults))
	for i, path in ipairs(a.job.faults) do
		-- Split the pay over the faults; the last line takes any rounding.
		local amount = if i == #a.job.faults then a.job.pay - each * (#a.job.faults - 1) else each
		table.insert(lines, { label = partLabel(path), amount = amount })
	end
	for _, e in ipairs(upsell.lines) do
		table.insert(lines, { label = e.label, amount = e.price })
	end
	Remotes.JobReceipt:FireClient(player, {
		invoice      = a.job.id,
		time         = os.time(),
		customerName = a.job.customerName,
		customerType = a.kind.label,
		car          = a.job.car.model,
		mechanic     = player.DisplayName,
		lines        = lines,
		subtotal     = s.pay + s.extras,
		extrasCut    = s.extrasCut,
		tonyCut      = s.cut,
		cutPercent   = s.cutPercent,
		mood         = s.moodLabel,
		tip          = s.tip,
		tipStolen    = s.tipStolen,
		rentMinutes  = rent.minutes,
		rentAmount   = rent.amount,
		interest     = s.interest,
		repayment    = s.repayment,
		debtAfter    = s.debtAfter,
		total        = s.total,
		xp           = LevelService.XP_AWARDS.job,
	})
	log.debug(player.Name, "finished a job for", a.job.customerName, "$" .. a.job.pay, "took home $" .. s.total)
	endJob(player, a)
end

-- Brings a job's car and customer into the bay.
local function spawnJob(player: Player, bay: BasePart, job: JobRecord): boolean
	local car = CarService.SpawnCar(player, job.car, bay, false)
	if not car then
		log.warn("Couldn't spawn the job car for", player.Name)
		return false
	end
	-- Patience carries on from earlier sessions (it pauses while you're offline).
	local kind = CustomerTypes.Get(job.kind)
	local patience = job.patience or kind.patience
	local waited = job.waited or 0
	local now = Workspace:GetServerTimeNow()
	local a: Active = {
		job = job, kind = kind, bay = bay, car = car, customer = nil, extras = {},
		startedAt = os.clock(), startedServer = now - waited,
		patience = patience,
		deadline = now + math.max(LAST_CHANCE, patience - waited),
	}
	active[player] = a

	-- Out of patience: they leave.
	task.delay(a.deadline - now, function()
		if active[player] == a then
			cancelJob(player, a, kind.leaving, ReputationService.CHANGES.walkedOut, "walked out")
		end
	end)
	TonyService.TakeRentTally(player) -- the receipt's rent line counts from now
	worked(player)
	sendUpdate(player)
	say(player, job, job.request)

	-- The customer (loading a friend's avatar can take a moment).
	task.spawn(function()
		local customer = Npc.Spawn(job.customerName, customerSpot(bay, player), job.customerUserId)
		if not customer then return end
		if active[player] ~= a then
			customer:Destroy() -- the job ended while the avatar loaded
			return
		end
		a.customer = customer

		local root = customer:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local prompt                 = Instance.new("ProximityPrompt")
			prompt.ActionText            = "Hand back car"
			prompt.ObjectText            = job.customerName
			prompt.Style                 = Enum.ProximityPromptStyle.Custom
			prompt:SetAttribute("Tone", "done") -- green key (CustomPromptManager)
			prompt.HoldDuration          = 0
			prompt.MaxActivationDistance = PROMPT_REACH
			prompt.RequiresLineOfSight   = false
			prompt.Parent                = root
			prompt.Triggered:Connect(function(triggering)
				handBack(player, triggering, a)
			end)
		end
	end)
	return true
end

-- Who the customer is: a random friend of the player, or a stand-in.
local function pickCustomer(player: Player): (string, number?)
	local friends = Npc.GetFriends(player)
	if #friends > 0 then
		local friend = friends[math.random(1, #friends)]
		return friend.name, friend.id
	end
	return FALLBACK_NAMES[math.random(1, #FALLBACK_NAMES)], nil
end

-- Customers already in the queue or in the bay (so a regular can't turn up twice).
local function present(player: Player): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, q in ipairs(queues[player] or {}) do
		out[regularKey(q.job.customerName, q.job.customerUserId)] = true
	end
	local a = active[player]
	if a then out[regularKey(a.job.customerName, a.job.customerUserId)] = true end
	return out
end

-- Picks `count` random paths from `paths`.
local function pickFaults(paths: { string }, count: number): { string }
	local shuffled = table.clone(paths)
	for i = #shuffled, 2, -1 do
		local j = math.random(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end
	local faults: { string } = {}
	for i = 1, math.min(count, #shuffled) do
		table.insert(faults, shuffled[i])
	end
	return faults
end

-- A regular coming back: their own car (as you left it) with a new problem.
local function repeatJob(player: Player): JobRecord?
	local profile = ProfileManager.GetProfile(player)
	if not profile or ReputationService.Get(player) < REGULAR_STARS then return nil end
	local here = present(player)
	local choices = {}
	for key, r in pairs(profile.Data.regulars) do
		if not here[key] then table.insert(choices, r) end
	end
	if #choices == 0 then return nil end
	local r = choices[math.random(1, #choices)]
	local paths = CarService.GetPartPaths(r.car.model)
	if #paths == 0 then return nil end

	local kind = CustomerTypes.Get(r.kind)
	local faults = pickFaults(paths, math.random(FAULTS_MIN, FAULTS_MAX))
	local car = deepCopy(r.car)
	car.missing = {}
	for _, path in ipairs(faults) do car.wear[path] = randomIn(FAULT_WEAR) end
	local labels = {}
	for i, path in ipairs(faults) do labels[i] = partLabel(path) end

	return {
		id             = HttpService:GenerateGUID(false),
		car            = car,
		customerName   = r.name,
		customerUserId = r.userId,
		faults         = faults,
		pay            = math.floor(PAY_PER_FAULT * #faults * kind.pay + 0.5),
		request        = LINES.backAgain .. CustomerTypes.Request(kind, labels),
		kind           = kind.id,
		patience       = kind.patience,
		waited         = 0,
		repeatVisit    = true,
	}
end

-- A brand-new job: a random car with 1–2 faulty parts, and a customer
-- (sometimes a regular coming back).
local function newJob(player: Player): JobRecord?
	if math.random() < REPEAT_CHANCE then
		local again = repeatJob(player)
		if again then return again end
	end

	local models = CarService.ListModels()
	if #models == 0 then
		log.warn("No car models in ServerStorage.Cars — no customers can come")
		return nil
	end
	local model = models[math.random(1, #models)]
	local paths = CarService.GetPartPaths(model)
	if #paths == 0 then
		log.warn("Car model", model, "has no Inspectable parts to fault")
		return nil
	end

	-- Who turns up depends on your reputation (CustomerTypes).
	local stars = ReputationService.Get(player)
	local kind = CustomerTypes.Pick(stars)

	-- Pick the faults (just one until you've a star to your name).
	local faults = pickFaults(paths, math.random(FAULTS_MIN, math.min(FAULTS_MAX, CustomerTypes.MaxFaults(stars))))
	local isFault: { [string]: boolean } = {}
	for _, path in ipairs(faults) do isFault[path] = true end

	local car = CarService.NewRecord(model, function(path)
		return if isFault[path] then randomIn(FAULT_WEAR) else randomIn(HEALTHY_WEAR)
	end)
	if not car then return nil end

	-- Someone not already waiting (if we can manage it).
	local here = present(player)
	local name, userId = pickCustomer(player)
	for _ = 1, 5 do
		if not here[regularKey(name, userId)] then break end
		name, userId = pickCustomer(player)
	end
	local labels = {}
	for i, path in ipairs(faults) do labels[i] = partLabel(path) end

	return {
		id             = HttpService:GenerateGUID(false),
		car            = car,
		customerName   = name,
		customerUserId = userId,
		faults         = faults,
		pay            = math.floor(PAY_PER_FAULT * #faults * kind.pay + 0.5),
		request        = CustomerTypes.Request(kind, labels),
		kind           = kind.id,
		patience       = kind.patience,
		waited         = 0,
	}
end

-- ── The queue ─────────────────────────────────────────────────────────────────

local function tipLabel(t: CustomerTypes.CustomerType, isRepeat: boolean): string
	local top = t.tip[2] * (if isRepeat then REPEAT_TIP else 1)
	return if top <= 0 then "None" elseif top <= 15 then "Small" elseif top <= 22 then "Medium" else "Big"
end

local function boardNote(q: Queued): string
	if q.job.repeatVisit then return "Was here before: you did a great job." end
	local id = q.kind.id
	if id == "rush" then return "Leaves fast. Only take it if you're quick." end
	if id == "fussy" then return ("Wants every part at %d%%+."):format(q.kind.fixedAt) end
	if id == "cheapskate" then return "Haggled the price down already." end
	if id == "rich" then return "Pays well, tips well, hates waiting." end
	return ""
end

-- Tells the player's job board who's waiting.
sendQueue = function(player: Player)
	local list = {}
	for _, q in ipairs(queues[player] or {}) do
		table.insert(list, {
			id             = q.job.id,
			customerName   = q.job.customerName,
			customerUserId = q.job.customerUserId,
			car            = q.job.car.model,
			customerKind   = if q.kind.id == "clueless" then "regular" else q.kind.id,
			customerType   = q.kind.label,
			request        = q.job.request,
			pay            = q.job.pay,
			tip            = tipLabel(q.kind, q.job.repeatVisit == true),
			faults         = #q.job.faults,
			patience       = q.job.patience or q.kind.patience,
			repeatVisit    = q.job.repeatVisit == true,
			note           = boardNote(q),
			deadline       = q.deadline,
			wait           = q.wait,
		})
	end
	Remotes.JobQueue:FireClient(player, { jobs = list, busy = active[player] ~= nil, open = if bays[player] then true else false })
end

-- ── The car park ──────────────────────────────────────────────────────────────

local takeJob: (Player, string) -> () -- defined below

-- The parking spaces that belong to `bay`, in the order they fill.
local function spotsFor(bay: BasePart): { BasePart }
	local folder = Workspace:FindFirstChild("ParkingSpots")
	local list: { BasePart } = {}
	if not folder then return list end
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("Bay") == bay.Name then
			table.insert(list, d)
		end
	end
	table.sort(list, function(a, b)
		local oa, ob = a:GetAttribute("Order"), b:GetAttribute("Order")
		local na = if type(oa) == "number" then oa else math.huge
		local nb = if type(ob) == "number" then ob else math.huge
		if na ~= nb then return na < nb end
		return a.Name < b.Name
	end)
	return list
end

local function freeSpot(player: Player, bay: BasePart): BasePart?
	local used: { [BasePart]: boolean } = {}
	for _, q in ipairs(queues[player] or {}) do
		if q.spot then used[q.spot] = true end
	end
	for _, spot in ipairs(spotsFor(bay)) do
		if not used[spot] then return spot end
	end
	return nil
end

-- Where a waiting customer stands: the space's CustomerSpot, or on the
-- floor beside the space, facing the bay.
local function parkedCustomerSpot(spot: BasePart, bay: BasePart): CFrame
	local placed = spot:FindFirstChild("CustomerSpot")
	local ground: Vector3
	if placed and placed:IsA("BasePart") then
		ground = placed.Position + Vector3.new(0, placed.Size.Y / 2, 0)
	else
		local side = Vector3.new(spot.CFrame.RightVector.X, 0, spot.CFrame.RightVector.Z)
		side = if side.Magnitude > 0.01 then side.Unit else Vector3.xAxis
		-- The side nearer the bay.
		if (spot.Position + side - bay.Position).Magnitude > (spot.Position - side - bay.Position).Magnitude then
			side = -side
		end
		local beside = spot.Position + side * (spot.Size.X / 2 + PARKED_GAP)
		local ignore: { Instance } = {}
		for _, name in ipairs({ "EngineZones", "Cars", "ParkedCars", "ParkingSpots", "NPCs", "DroppedParts" }) do
			local folder = Workspace:FindFirstChild(name)
			if folder then table.insert(ignore, folder) end
		end
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Character then table.insert(ignore, p.Character) end
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = ignore
		params.RespectCanCollide = true
		local hit = Workspace:Raycast(beside + Vector3.new(0, spot.Size.Y / 2 + 5, 0), Vector3.new(0, -(spot.Size.Y + 60), 0), params)
		ground = if hit then hit.Position else beside - Vector3.new(0, spot.Size.Y / 2, 0)
	end
	return CFrame.lookAt(ground, Vector3.new(bay.Position.X, ground.Y, bay.Position.Z))
end

-- Takes a customer's car and themselves out of the car park.
local function unpark(q: Queued)
	q.gone = true
	if q.parked then q.parked:Destroy() end
	if q.waiting then q.waiting:Destroy() end
	q.parked, q.waiting, q.spot = nil, nil, nil
end

-- Parks a newly queued customer's car outside, with them beside it.
local function park(player: Player, bay: BasePart, q: Queued)
	local spot = freeSpot(player, bay)
	if not spot then return end
	q.spot = spot
	q.parked = CarService.SpawnParked(q.job.car, spot)
	task.spawn(function()
		local npc = Npc.Spawn(q.job.customerName, parkedCustomerSpot(spot, bay), q.job.customerUserId)
		if not npc then return end
		if q.gone then
			npc:Destroy() -- taken or gave up while the avatar loaded
			return
		end
		q.waiting = npc
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local prompt                 = Instance.new("ProximityPrompt")
			prompt.ActionText            = "Take job"
			prompt.ObjectText            = ("%s · %s · $%d"):format(q.job.customerName, q.kind.label, q.job.pay)
			prompt.Style                 = Enum.ProximityPromptStyle.Custom
			prompt:SetAttribute("Tone", "done")
			prompt:SetAttribute("OnlyUserId", player.UserId) -- other players don't see it (CustomPromptManager)
			prompt.HoldDuration          = 0
			prompt.MaxActivationDistance = PROMPT_REACH
			prompt.RequiresLineOfSight   = false
			prompt.Parent                = root
			prompt.Triggered:Connect(function(triggering)
				if triggering == player then takeJob(player, q.job.id) end
			end)
		end
	end)
end

-- Everyone waiting outside goes (lost the bay, or left the game).
local function clearQueue(player: Player)
	for _, q in ipairs(queues[player] or {}) do unpark(q) end
	queues[player] = nil
end

local function removeQueued(player: Player, q: Queued): boolean
	local queue = queues[player]
	local i = queue and table.find(queue, q)
	if not queue or not i then return false end
	table.remove(queue, i)
	unpark(q)
	return true
end

-- A new customer joins the queue (if there's room). Returns true if one did.
local function arrive(player: Player): boolean
	if not bays[player] then return false end
	local queue = queues[player] or {}
	queues[player] = queue
	if #queue >= MAX_QUEUE then return false end
	local job = newJob(player)
	if not job or not bays[player] or #queue >= MAX_QUEUE then return false end

	local kind = CustomerTypes.Get(job.kind)
	local wait = if kind.id == "rush" then RUSH_QUEUE_WAIT else QUEUE_WAIT
	local q: Queued = { job = job, kind = kind, wait = wait, deadline = Workspace:GetServerTimeNow() + wait }
	local bay = bays[player]
	if bay then park(player, bay, q) end
	table.insert(queue, q)
	sendQueue(player)

	if not hinted[player] then
		hinted[player] = true
		TonyService.Say(player, LINES.firstHint)
	end

	-- Fed up of waiting: they leave, no harm done.
	task.delay(wait, function()
		if removeQueued(player, q) then
			say(player, job, LINES.gaveUp)
			sendQueue(player)
			scheduleNext(player, ARRIVAL_GAP)
		end
	end)
	return true
end

-- Keeps the queue topped up: one arrival after `delay`, then one every
-- ARRIVAL_GAP until it's full.
scheduleNext = function(player: Player, delay: number)
	local token = (nextToken[player] or 0) + 1
	nextToken[player] = token
	task.delay(delay, function()
		if nextToken[player] ~= token or not player:IsDescendantOf(Players) then return end
		arrive(player)
		local queue = queues[player]
		if bays[player] and queue and #queue < MAX_QUEUE then
			scheduleNext(player, ARRIVAL_GAP)
		end
	end)
end

-- The player picked a customer (on the job board, or in the car park).
takeJob = function(player: Player, jobId: string)
	local bay = bays[player]
	local profile = ProfileManager.GetProfile(player)
	if not bay or not profile or active[player] then return end
	local chosen: Queued? = nil
	for _, q in ipairs(queues[player] or {}) do
		if q.job.id == jobId then
			chosen = q
			break
		end
	end
	if not chosen or not removeQueued(player, chosen) then return end

	profile.Data.activeJob = chosen.job
	if not spawnJob(player, bay, chosen.job) then
		profile.Data.activeJob = nil
	end
	sendQueue(player)
	scheduleNext(player, ARRIVAL_GAP)
end

-- ── Public ────────────────────────────────────────────────────────────────────

-- Called by BayRentalService once `player` has rented `bay`: carries on a
-- saved job, and customers start queuing outside.
function JobService.BayRented(player: Player, bay: BasePart)
	bays[player] = bay
	clearQueue(player)
	queues[player] = {}
	worked(player)
	local profile = ProfileManager.GetProfile(player)
	local saved = profile and profile.Data.activeJob
	if saved and not spawnJob(player, bay, saved) and profile then
		profile.Data.activeJob = nil
	end
	sendQueue(player)
	scheduleNext(player, FIRST_CUSTOMER_DELAY)
end

-- What Tony's inspector sees in the bay (BayRentalService): how many of the
-- job car's parts are out, and whether the customer has been kept waiting
-- more than half their patience. No job: nothing to see.
function JobService.InspectionReport(player: Player): { partsOut: number, keptWaiting: boolean }
	local a = active[player]
	if not a then return { partsOut = 0, keptWaiting = false } end
	local out = 0
	for _, path in ipairs(CarService.GetPartPaths(a.job.car.model)) do
		if a.job.car.missing[path] then out += 1 end
	end
	return { partsOut = out, keptWaiting = patienceLeft(a) < 0.5 }
end

-- Seconds since the player last did any work: a part out or in, a job
-- started or finished. (BayRentalService kicks idle renters out.)
function JobService.IdleSeconds(player: Player): number
	local last = lastWork[player]
	return if last then os.clock() - last else 0
end

-- Called by BayRentalService when `player` loses their bay while still in
-- the game (handed back the keys, or kicked out): a job in progress counts
-- as cancelled, and no more customers come.
function JobService.BayReleased(player: Player)
	bays[player] = nil
	nextToken[player] = nil
	lastWork[player] = nil
	clearQueue(player)
	hinted[player] = nil
	local a = active[player]
	if a then cancelJob(player, a, LINES.lostBay) end
	sendQueue(player)
end

-- ── Events ────────────────────────────────────────────────────────────────────

-- A part came out or went back in: re-check that player's work order.
CarService.CarChanged:Connect(function(carId: string)
	for player, a in pairs(active) do
		if a.job.car.id == carId then
			worked(player)
			sendUpdate(player)
			return
		end
	end
end)

-- The job ends without the work done (you cancelled, lost the bay, or the
-- customer ran out of patience): the car goes home with all its parts,
-- Tony fines you, and you lose reputation.
cancelJob = function(player: Player, a: Active, customerLine: string, starChange: number?, reason: string?)
	if active[player] ~= a then return end
	PartPickupService.CollectAllFor(player)
	InventoryService.RemovePartsFromCar(player, a.job.car.id)
	say(player, a.job, customerLine)
	local fine = TonyService.CancelFine(player, a.job.pay)
	ReputationService.Add(player, starChange or ReputationService.CHANGES.cancelled, reason or "cancelled job")
	tonyLater(player, TONY_LINE_DELAY, TonyService.Line("fine", fine))
	-- Walked out or let down: they won't be back.
	local profile = ProfileManager.GetProfile(player)
	if profile then
		profile.Data.regulars[regularKey(a.job.customerName, a.job.customerUserId)] = nil
	end
	log.debug(player.Name, "cancelled the job for", a.job.customerName, "fined $" .. fine)
	endJob(player, a)
end

Remotes.CancelJob.OnServerEvent:Connect(function(player)
	local a = active[player]
	if a then cancelJob(player, a, LINES.cancelled) end
end)

Remotes.TakeJob.OnServerEvent:Connect(function(player, jobId: any)
	if type(jobId) == "string" then takeJob(player, jobId) end
end)

-- Extras ticked on the work order.
Remotes.SetExtras.OnServerEvent:Connect(function(player, ids: any)
	local a = active[player]
	if not a or type(ids) ~= "table" then return end
	local clean = {}
	for _, e in ipairs(Upsell.Clean(ids)) do table.insert(clean, e.id) end
	a.extras = clean
	sendUpdate(player)
end)

-- Leaving: the job stays saved (CarService saves and removes the car into
-- this same record); the customer goes.
ProfileManager.OnBeforeRelease(function(player)
	local a = active[player]
	if a then
		-- Patience pauses while you're away: remember how long they waited.
		a.job.waited = (a.job.waited or 0) + (os.clock() - a.startedAt)
	end
	if a and a.customer then a.customer:Destroy() end
	active[player] = nil
	bays[player] = nil
	nextToken[player] = nil
	lastWork[player] = nil
	clearQueue(player)
	hinted[player] = nil
end)

return JobService
