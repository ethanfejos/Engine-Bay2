--!strict
--[[
    JobService (ModuleScript, started by Main)
    ------------------------------------------
    Customer jobs, phase 1 (basics). Once a player has rented a bay
    (BayRentalService calls BayRented):

    1. A customer arrives: their car spawns in the bay (CarService.SpawnCar,
       the player as its worker, not its owner) and they stand beside the
       bay wearing one of the player's Roblox friends' avatars, with that
       friend's name (a stand-in customer if there are no friends to use).
       Where they stand: a "CustomerSpot" part inside the bay part if there
       is one, otherwise beside the car on the clear side nearest the player.
    2. The work order: 1–2 named faults. The car is built so those parts
       are badly worn (FAULT_WEAR) and everything else is healthy.
    3. The player fixes them with the existing tools: remove, repair or
       replace at the bench, reinstall. Progress is re-checked every time a
       part comes out or goes back in (CarService.CarChanged).
    4. Hand back: talk to the customer. Accepted only when every fault is at
       FIXED_WEAR or better and no part is missing. The customer pays
       PAY_PER_FAULT per fault plus a tip; Tony settles it (TonyService:
       his cut, maybe the tip, interest and debt repayment) and you get the
       rest, XP and reputation (more for a quick job); the car and customer
       leave; the next customer turns up after NEXT_CUSTOMER_DELAY.

    Saved: the job, with the customer's car as it is right now, lives in
    profile.Data.activeJob. Leaving mid-job saves it; renting a bay again
    brings the same customer and car back.

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
local FIXED_WEAR           = 70          -- a fault counts as fixed at this % or better
local FIRST_CUSTOMER_DELAY = 3           -- seconds after renting
local NEXT_CUSTOMER_DELAY  = 6           -- seconds after a job ends
local CUSTOMER_GAP         = 3           -- studs between the bay's edge and the customer (when no CustomerSpot)
local PROMPT_REACH         = 10
local TIP_PERCENT          = { 5, 20 }   -- the customer's tip, % of the pay (customer types change this in phase 3)
local QUICK_JOB_SECONDS    = 5 * 60      -- handed back within this: a quick job (more reputation)
local TONY_LINE_DELAY      = 2.5         -- seconds between the customer's line and Tony butting in

-- Stand-in customers when there are no friends to use.
local FALLBACK_NAMES = { "Dave", "Mere", "Tama", "Sharon", "Wiremu", "Kev", "Aroha", "Brent" }

local REQUESTS_ONE = {
	"My %s's on its way out. Can you sort it?",
	"Reckon the %s is stuffed. Fix it up for me?",
	"Something's off with the %s. Can you take a look?",
}
local REQUESTS_TWO = {
	"The %s and the %s both need sorting.",
	"%s is dodgy, and so's the %s. Can you do both?",
}

local LINES = {
	notDone   = "Not done yet, mate. Still waiting on: %s.",
	thanks    = "Legend, cheers! Here's your $%d.",
	cancelled = "No worries, I'll take it somewhere else.",
	lostBay   = "Where's my car going?! Forget it, I'm off.",
	notYours  = "Sorry, I'm waiting on someone else.",
}

local JobService = {}

-- ── State ─────────────────────────────────────────────────────────────────────

type Active = {
	job: JobRecord,
	bay: BasePart,
	car: Model,
	customer: Model?,
	startedAt: number,     -- os.clock() when the car arrived (this session)
	startedServer: number, -- workspace:GetServerTimeNow() at the same moment (the work order's timer)
}

local active: { [Player]: Active } = {}      -- the job each player is working on
local bays: { [Player]: BasePart } = {}      -- each player's rented bay
local nextToken: { [Player]: number } = {}   -- so only the latest "next customer" timer counts
local lastWork: { [Player]: number } = {}    -- os.clock() of the player's last work (for Tony's idle check)

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

local function isFixed(job: JobRecord, path: string): boolean
	return not job.car.missing[path] and (job.car.wear[path] or 100) >= FIXED_WEAR
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
	for _, path in ipairs(job.faults) do
		local done = isFixed(job, path)
		table.insert(tasks, { label = "Fix the " .. partLabel(path), done = done })
		complete = complete and done
	end
	local missing = otherMissing(job)
	if #missing > 0 then
		table.insert(tasks, { label = "Put back: " .. table.concat(missing, ", "), done = false })
		complete = false
	end
	return tasks, complete
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
		quickSeconds   = QUICK_JOB_SECONDS,
		-- What cancelling would cost right now (shown before you confirm).
		cancelFine     = math.max(1, math.floor(a.job.pay * TonyService.GetMood().cancelFine + 0.5)),
		cancelStars    = -ReputationService.CHANGES.cancelled,
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
	for _, name in ipairs({ "EngineZones", "Cars", "NPCs", "DroppedParts" }) do
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
local cancelJob: (Player, Active, string) -> () -- defined below

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
	scheduleNext(player, NEXT_CUSTOMER_DELAY)
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
	local tip = math.floor(a.job.pay * math.random(TIP_PERCENT[1], TIP_PERCENT[2]) / 100 + 0.5)
	local rent = TonyService.TakeRentTally(player)
	local s = TonyService.SettleJob(player, a.job.pay, tip)

	LevelService.AddXP(player, LevelService.XP_AWARDS.job, "job")
	local quick = os.clock() - a.startedAt <= QUICK_JOB_SECONDS
	ReputationService.Add(player,
		if quick then ReputationService.CHANGES.quickJob else ReputationService.CHANGES.slowJob,
		if quick then "quick job" else "slow job")
	InventoryService.RemovePartsFromCar(player, a.job.car.id) -- normally none left
	worked(player)

	say(player, a.job, LINES.thanks:format(a.job.pay + tip))
	local delay = TONY_LINE_DELAY
	if s.tipStolen then
		tonyLater(player, delay, TonyService.Line("stoleTip"))
		delay += TONY_LINE_DELAY
	end
	if s.debtAfter > 0 then
		tonyLater(player, delay, TonyService.Line("debt", s.debtAfter))
	end

	-- The receipt (ReceiptUI): one line per fault, then the totals.
	local lines = {}
	for _, path in ipairs(a.job.faults) do
		table.insert(lines, { label = partLabel(path), amount = PAY_PER_FAULT })
	end
	Remotes.JobReceipt:FireClient(player, {
		invoice      = a.job.id,
		time         = os.time(),
		customerName = a.job.customerName,
		car          = a.job.car.model,
		mechanic     = player.DisplayName,
		lines        = lines,
		subtotal     = s.pay,
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
	local a: Active = {
		job = job, bay = bay, car = car, customer = nil,
		startedAt = os.clock(), startedServer = Workspace:GetServerTimeNow(),
	}
	active[player] = a
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

-- A brand-new job: a random car with 1–2 faulty parts, and a customer.
local function newJob(player: Player): JobRecord?
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

	-- Pick the faults.
	local shuffled = table.clone(paths)
	for i = #shuffled, 2, -1 do
		local j = math.random(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end
	local faults: { string } = {}
	for i = 1, math.random(FAULTS_MIN, math.min(FAULTS_MAX, #shuffled)) do
		table.insert(faults, shuffled[i])
	end
	local isFault: { [string]: boolean } = {}
	for _, path in ipairs(faults) do isFault[path] = true end

	local car = CarService.NewRecord(model, function(path)
		return if isFault[path] then randomIn(FAULT_WEAR) else randomIn(HEALTHY_WEAR)
	end)
	if not car then return nil end

	local name, userId = pickCustomer(player)
	local request = if #faults == 1
		then REQUESTS_ONE[math.random(1, #REQUESTS_ONE)]:format(partLabel(faults[1]))
		else REQUESTS_TWO[math.random(1, #REQUESTS_TWO)]:format(partLabel(faults[1]), partLabel(faults[2]))

	return {
		id             = HttpService:GenerateGUID(false),
		car            = car,
		customerName   = name,
		customerUserId = userId,
		faults         = faults,
		pay            = PAY_PER_FAULT * #faults,
		request        = request,
	}
end

local function startNewJob(player: Player)
	local bay = bays[player]
	local profile = ProfileManager.GetProfile(player)
	if not bay or not profile or active[player] then return end
	local job = newJob(player)
	if not job then return end
	if not bays[player] or active[player] then return end -- changed while picking a customer
	profile.Data.activeJob = job
	if not spawnJob(player, bay, job) then
		profile.Data.activeJob = nil
	end
end

scheduleNext = function(player: Player, delay: number)
	local token = (nextToken[player] or 0) + 1
	nextToken[player] = token
	task.delay(delay, function()
		if nextToken[player] ~= token or not player:IsDescendantOf(Players) then return end
		startNewJob(player)
	end)
end

-- ── Public ────────────────────────────────────────────────────────────────────

-- Called by BayRentalService once `player` has rented `bay`: carries on a
-- saved job, or sends the first customer.
function JobService.BayRented(player: Player, bay: BasePart)
	bays[player] = bay
	worked(player)
	local profile = ProfileManager.GetProfile(player)
	local saved = profile and profile.Data.activeJob
	if saved then
		if not spawnJob(player, bay, saved) and profile then
			profile.Data.activeJob = nil
			scheduleNext(player, FIRST_CUSTOMER_DELAY)
		end
	else
		scheduleNext(player, FIRST_CUSTOMER_DELAY)
	end
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
	local a = active[player]
	if a then cancelJob(player, a, LINES.lostBay) end
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

-- The job ends without the work done: the car goes home with all its
-- parts, Tony fines you, and you lose reputation.
cancelJob = function(player: Player, a: Active, customerLine: string)
	if active[player] ~= a then return end
	PartPickupService.CollectAllFor(player)
	InventoryService.RemovePartsFromCar(player, a.job.car.id)
	say(player, a.job, customerLine)
	local fine = TonyService.CancelFine(player, a.job.pay)
	ReputationService.Add(player, ReputationService.CHANGES.cancelled, "cancelled job")
	tonyLater(player, TONY_LINE_DELAY, TonyService.Line("fine", fine))
	log.debug(player.Name, "cancelled the job for", a.job.customerName, "fined $" .. fine)
	endJob(player, a)
end

Remotes.CancelJob.OnServerEvent:Connect(function(player)
	local a = active[player]
	if a then cancelJob(player, a, LINES.cancelled) end
end)

-- Leaving: the job stays saved (CarService saves and removes the car into
-- this same record); the customer goes.
ProfileManager.OnBeforeRelease(function(player)
	local a = active[player]
	if a and a.customer then a.customer:Destroy() end
	active[player] = nil
	bays[player] = nil
	nextToken[player] = nil
	lastWork[player] = nil
end)

return JobService
