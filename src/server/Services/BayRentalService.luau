--!strict
--[[
    BayRentalService (ModuleScript, started by Main)
    ------------------------------------------------
    Renting a bay from the landlord, Tony:

    - Tony stands in the garage with a "Rent a bay" prompt, and his mood
      (TonyService) floats over his head.
    - Rent is per minute (TonyService.RentPerMinute: $3 in a normal mood,
      $1 while testing; his mood moves it). The first minute is paid up
      front, then one minute every RENT_PERIOD seconds for as long as you
      keep the bay. Whatever you can't pay goes on your debt to Tony — he
      always rents you a bay, so you can work a debt off.
    - You get the first free Mechanic bay to yourself: it's marked with your
      UserId ("RentedBy" on the bay part, which the client uses for the YOUR
      BAY marker). Customers' cars come to it (JobService.BayRented). (With
      SPAWN_OWN_CAR on, your own car spawns into it instead — off until the
      junkyard gives players cars of their own.)
    - One bay per player. If every bay is taken, Tony says so.
    - Hand back the keys (ReleaseBay, client -> server): the bay goes back
      and the charges stop. A job in progress counts as cancelled.
    - Doing nothing for IDLE_KICK seconds (not moving, no part out or in,
      no job started or finished — JobService.IdleSeconds): Tony kicks you
      out, same as handing back the keys.
    - Leaving the game also ends it: the bay goes back to Tony (your job and
      its car are saved for next time, by JobService and CarService), and
      nothing is charged while you're away.

    Tony being nasty:
    - Late rent: every minute that goes on the tab is a strike (shown on the
      rent bar); every minute paid in full takes one away. At WARN_STRIKES
      he warns you; at EVICT_STRIKES he throws you out — the bay goes, a job
      in progress is cancelled (fine and stars, as usual), and he won't rent
      to you for BAN_SECONDS.
    - Surprise inspections: every INSPECT_MIN–INSPECT_MAX seconds, with
      INSPECT_WARNING seconds' notice. Each problem is a fine of FINE_MIN–
      FINE_MAX: parts on the floor, more than PARTS_OUT_LIMIT parts out of the
      car, a customer kept waiting past half their patience. A clean bay
      knocks CLEAN_DEBT off what you owe (or, owing nothing, +CLEAN_STARS).
    - Loans, only while he's Desperate: a second prompt on Tony ("Borrow
      money", F). LoanUI picks the amount (TonyService.TakeLoan).

    Tony's lines reach the player through NpcSpeech (server -> client),
    shown by BayRentalUI.

    Tony in the place file (either works):
    - a Model named "Landlord" in the Workspace (your own NPC) — the prompt
      is added to its HumanoidRootPart or PrimaryPart; or
    - a Part named "LandlordSpot" in the Workspace — a default placeholder
      Tony is created standing on it.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Modules        = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local ZoneUtils      = require(Modules:WaitForChild("ZoneUtils"))
local Remotes        = require(Modules:WaitForChild("Remotes"))
local Log            = require(Modules:WaitForChild("Log"))
local ProfileManager = require(script.Parent.Parent.Modules.ProfileManager)
local Npc            = require(script.Parent.Parent.Modules.Npc)
local CarService     = require(script.Parent.CarService)
local PartPickupService = require(script.Parent.PartPickupService)
local ReputationService = require(script.Parent.ReputationService)
local TonyService    = require(script.Parent.TonyService)
local JobService     = require(script.Parent.JobService)

local log = Log.new("BayRentalService")

-- ── Config ────────────────────────────────────────────────────────────────────

local LANDLORD_NAME  = TonyService.NAME
local RENT_PERIOD    = 60      -- seconds per rent charge
local IDLE_KICK      = 5 * 60  -- seconds of doing nothing before Tony kicks you out
local BAY_ZONE_TYPE  = "Mechanic"
local PROMPT_REACH   = 10
local SPAWN_OWN_CAR  = false -- spawn the player's own (starter) car on renting; back on with the junkyard

local WARN_STRIKES    = 3       -- late payments before Tony warns you
local EVICT_STRIKES   = 5       -- late payments before he throws you out
local BAN_SECONDS     = 5 * 60  -- how long after an eviction he won't rent to you
local INSPECT_MIN     = 15 * 60 -- seconds between inspections, at least
local INSPECT_MAX     = 25 * 60 -- and at most
local INSPECT_WARNING = 60      -- notice before he inspects
local FINE_MIN        = 10      -- each problem he finds costs this much…
local FINE_MAX        = 30      -- …to this much
local PARTS_OUT_LIMIT = 3       -- more parts than this out of the car is a mess
local CLEAN_DEBT      = 5       -- a clean inspection knocks this off your debt
local CLEAN_STARS     = 0.05    -- or, owing nothing, gives you this much reputation
local LOAN_KEY        = Enum.KeyCode.F

-- Tony's lines that don't change with his mood (the rest are in TonyService).
local LINES = {
	alreadyHave  = "You've already got a bay, kid. One's plenty.",
	full         = "Full up. Come back when someone clears out.",
	notLoaded    = "Hang on, still finding your paperwork. Try again in a sec.",
	noCar        = "Bay's yours, but your car's not turned up. Talk to me again later.",
	keysBack     = "Keys back. Pleasure doing business.",
	kickedOut    = "You're not working, you're loitering. Out.",
	strikesWarn  = "That's %d late payments. Two more and you're out.",
	lastStrike   = "One more late payment and you're out. I mean it.",
	evicted      = "That's it. Five late payments. Keys. Now. Cool off, kid.",
	banned       = "Cool off, kid. Come back in %s.",
	inspectSoon  = "Inspection in a minute. Tidy up.",
	inspectPass  = "Hmph. Fine.",
	inspectFail  = "Look at this place. %s. That's $%d.",
	loanNo       = "I'm desperate, kid, not stupid. Pay off what you owe first.",
	loanNotNow   = "Loans? Who said anything about loans?",
	loanTaken    = "Here's $%d. You owe me $%d for it. Don't make me come looking.",
}

local BayRentalService = {}

-- ── State ─────────────────────────────────────────────────────────────────────

type Rental = {
	bay: BasePart,
	nextCharge: number,   -- workspace:GetServerTimeNow() time
	lastPos: Vector3?,    -- where the character was at the last check
	movedAt: number,      -- os.clock() when they last moved
	short: boolean,       -- the last charge didn't get paid in full
	strikes: number,      -- late payments (see EVICT_STRIKES)
	inspectAt: number,    -- workspace:GetServerTimeNow() of the next inspection
	warned: boolean,      -- told about the next inspection yet
}
local rentals: { [Player]: Rental } = {}
local bannedUntil: { [number]: number } = {} -- [UserId] = GetServerTimeNow() the eviction ban ends
local loanOffered: { [Player]: boolean } = {} -- shown the loan offer; RequestLoan only counts then

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function say(player: Player, text: string)
	TonyService.Say(player, text)
end

-- What players call a bay: its "DisplayName" attribute if you've set one,
-- else the number at the end of the part's name ("Mechanic_1" -> "1").
local function bayLabel(bay: BasePart): string
	local custom = bay:GetAttribute("DisplayName")
	if type(custom) == "string" and custom ~= "" then return custom end
	return string.match(bay.Name, "(%d+)$") or bay.Name
end

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function nextInspection(): number
	return now() + math.random(INSPECT_MIN, INSPECT_MAX)
end

-- Tells the player's rent panel the bay, the rate and the next charge.
local function pushRent(player: Player)
	local rental = rentals[player]
	TonyService.SetRentInfo(player, if rental then {
		bay = bayLabel(rental.bay),
		perMinute = TonyService.RentPerMinute(),
		nextCharge = rental.nextCharge,
		strikes = rental.strikes,
		inspectAt = if rental.warned then rental.inspectAt else nil,
	} else nil)
end

-- One minute of rent. Returns what went on the debt (0 if fully paid).
local function chargeRent(player: Player): number
	local amount = TonyService.RentPerMinute()
	TonyService.NoteRent(player, amount)
	local _, owed = TonyService.Charge(player, amount, "bay rent")
	return owed
end

-- The first Mechanic bay nobody rents, with no car in it.
local function findFreeBay(): BasePart?
	local zonesFolder = Workspace:FindFirstChild("EngineZones")
	if not zonesFolder then return nil end
	local zones = zonesFolder:GetChildren()
	table.sort(zones, function(a, b) return a.Name < b.Name end)
	for _, zone in ipairs(zones) do
		if zone:IsA("BasePart")
			and ZoneUtils.GetZoneType(zone) == BAY_ZONE_TYPE
			and ZoneUtils.GetRenter(zone) == nil
			and not CarService.IsPlacingIn(zone.Name)
			and ZoneUtils.GetEngineInZone(zone) == nil then
			return zone
		end
	end
	return nil
end

local function release(player: Player)
	local rental = rentals[player]
	if not rental then return end
	rentals[player] = nil
	local bay = rental.bay
	if ZoneUtils.GetRenter(bay) == player.UserId then
		bay:SetAttribute(ZoneUtils.RENTED_BY_ATTRIBUTE, nil)
	end
	if player:IsDescendantOf(Players) then
		pushRent(player)
	end
	log.debug(player.Name, "gave back", bay.Name)
end

-- The player loses the bay while still in the game (keys handed back, or
-- kicked out): a job in progress is cancelled, then the bay goes back.
local function giveUp(player: Player, line: string)
	if not rentals[player] then return end
	JobService.BayReleased(player)
	release(player)
	say(player, line)
end

-- ── Renting ───────────────────────────────────────────────────────────────────

local function rent(player: Player)
	if rentals[player] then
		return say(player, LINES.alreadyHave)
	end
	if not ProfileManager.GetProfile(player) then
		return say(player, LINES.notLoaded)
	end

	local ban = bannedUntil[player.UserId]
	if ban and now() < ban then
		local left = math.ceil(ban - now())
		return say(player, LINES.banned:format(("%d:%02d"):format(left // 60, left % 60)))
	end
	bannedUntil[player.UserId] = nil

	local bay = findFreeBay()
	if not bay then
		return say(player, LINES.full)
	end
	bay:SetAttribute(ZoneUtils.RENTED_BY_ATTRIBUTE, player.UserId)
	rentals[player] = {
		bay = bay, nextCharge = now() + RENT_PERIOD, lastPos = nil, movedAt = os.clock(),
		short = false, strikes = 0, inspectAt = nextInspection(), warned = false,
	}

	-- The first minute, up front. Can't cover it? Tony still rents the bay —
	-- it goes on your tab (and that's a strike).
	local owed = chargeRent(player)
	local rental = rentals[player]
	if rental then
		rental.short = owed > 0
		if owed > 0 then rental.strikes = 1 end
	end
	pushRent(player)
	say(player, if owed > 0
		then TonyService.Line("tab")
		else TonyService.Line("rented", bayLabel(bay), TonyService.RentPerMinute()))

	if not SPAWN_OWN_CAR then
		JobService.BayRented(player, bay) -- a saved job comes back, or the first customer turns up
	elseif not CarService.SpawnActiveCar(player, bay) then
		say(player, LINES.noCar)
	end
	log.debug(player.Name, "rented", bay.Name)
end

-- ── Strikes and inspections ───────────────────────────────────────────────────

-- After a minute's rent: a strike if it went on the tab, one off if paid.
-- Returns true if that got them evicted.
local function noteRentPaid(player: Player, rental: Rental, owed: number): boolean
	if owed <= 0 then
		rental.strikes = math.max(0, rental.strikes - 1)
		return false
	end
	rental.strikes += 1
	if rental.strikes >= EVICT_STRIKES then
		giveUp(player, LINES.evicted)
		bannedUntil[player.UserId] = now() + BAN_SECONDS
		log.info(player.Name, "evicted for late rent")
		return true
	elseif rental.strikes == EVICT_STRIKES - 1 then
		say(player, LINES.lastStrike)
	elseif rental.strikes == WARN_STRIKES then
		say(player, LINES.strikesWarn:format(rental.strikes))
	end
	return false
end

-- Tony looks round the bay: a fine for each problem, or a grudging bonus.
local function inspect(player: Player, rental: Rental)
	local problems: { string } = {}
	local floor = PartPickupService.FloorCount(player)
	if floor > 0 then
		table.insert(problems, if floor == 1 then "A part on the floor" else floor .. " parts on the floor")
	end
	local report = JobService.InspectionReport(player)
	if report.partsOut > PARTS_OUT_LIMIT then
		table.insert(problems, report.partsOut .. " parts out of the car at once")
	end
	if report.keptWaiting then
		table.insert(problems, "Your customer's been waiting ages")
	end

	if #problems == 0 then
		if TonyService.GetDebt(player) > 0 then
			TonyService.AdjustDebt(player, CLEAN_DEBT, "clean inspection")
		else
			ReputationService.Add(player, CLEAN_STARS, "clean inspection")
		end
		say(player, LINES.inspectPass)
		return
	end
	local fine = 0
	for _ = 1, #problems do fine += math.random(FINE_MIN, FINE_MAX) end
	TonyService.Charge(player, fine, "inspection fine")
	say(player, LINES.inspectFail:format(table.concat(problems, ". "), fine))
	log.debug(player.Name, "failed inspection:", table.concat(problems, "; "), "$" .. fine)
end

-- ── Every second: rent due, idle renters, inspections ─────────────────────────

task.spawn(function()
	while true do
		task.wait(1)
		for player, rental in pairs(rentals) do
			if not player:IsDescendantOf(Players) then continue end
			-- Walking about counts as not idle (e.g. at the workbench).
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local last = rental.lastPos
				if not last or (root.Position - last).Magnitude > 2 then
					rental.lastPos = root.Position
					rental.movedAt = os.clock()
				end
			end
			local idle = math.min(JobService.IdleSeconds(player), os.clock() - rental.movedAt)
			if idle >= IDLE_KICK then
				giveUp(player, LINES.kickedOut)
				continue
			end
			if now() >= rental.nextCharge then
				rental.nextCharge += RENT_PERIOD
				local owed = chargeRent(player)
				-- Tony mentions it when you first run short, not every minute.
				local firstShort = owed > 0 and not rental.short
				rental.short = owed > 0
				if noteRentPaid(player, rental, owed) then continue end
				if firstShort and rental.strikes < WARN_STRIKES then
					say(player, TonyService.Line("tab"))
				end
				pushRent(player)
			end
			if not rental.warned and now() >= rental.inspectAt - INSPECT_WARNING then
				rental.warned = true
				say(player, LINES.inspectSoon)
				pushRent(player)
			elseif rental.warned and now() >= rental.inspectAt then
				rental.warned = false
				rental.inspectAt = nextInspection()
				inspect(player, rental)
				pushRent(player)
			end
		end
	end
end)

-- ── Public ────────────────────────────────────────────────────────────────────

-- The bay this player rents, or nil.
function BayRentalService.GetBay(player: Player): BasePart?
	local rental = rentals[player]
	return if rental then rental.bay else nil
end

-- ── Tony ──────────────────────────────────────────────────────────────────────

-- "Rent a bay ($3/min) · Tony's grumpy"
local function promptText(): string
	local mood = TonyService.GetMood()
	return ("Rent a bay ($%d/min) · %s"):format(TonyService.RentPerMinute(),
		if mood.id == "normal" then "Tony's all business" else "Tony's having a " .. mood.label)
end

-- A face over Tony's head showing his mood.
local function addMoodFace(landlord: Model): TextLabel?
	local head = landlord:FindFirstChild("Head")
	local adornee = if head and head:IsA("BasePart") then head else landlord.PrimaryPart
	if not adornee then return nil end
	local gui                 = Instance.new("BillboardGui")
	gui.Name                  = "TonyMood"
	gui.Adornee               = adornee
	gui.Size                  = UDim2.new(0, 48, 0, 48)
	gui.StudsOffset           = Vector3.new(0, 3.2, 0)
	gui.MaxDistance           = 80
	gui.LightInfluence        = 0
	gui.Parent                = adornee
	local face                  = Instance.new("TextLabel")
	face.Size                   = UDim2.fromScale(1, 1)
	face.BackgroundTransparency = 1
	face.TextScaled             = true
	face.Text                   = TonyService.GetMood().face
	face.Parent                 = gui
	return face
end

local function addPrompt(landlord: Model)
	local root = landlord:FindFirstChild("HumanoidRootPart") or landlord.PrimaryPart
	if not root or not root:IsA("BasePart") then
		log.warn("Landlord model has no HumanoidRootPart or PrimaryPart for the prompt")
		return
	end
	local prompt                 = Instance.new("ProximityPrompt")
	prompt.ActionText            = promptText()
	prompt.ObjectText            = LANDLORD_NAME .. " · Landlord"
	prompt.Style                 = Enum.ProximityPromptStyle.Custom
	prompt:SetAttribute("Tone", "money") -- amber key (CustomPromptManager)
	prompt.HoldDuration          = 0
	prompt.MaxActivationDistance = PROMPT_REACH
	prompt.RequiresLineOfSight   = false
	prompt.Parent                = root
	prompt.Triggered:Connect(rent)

	-- Borrowing (Desperate mood only): its own key, just under the rent prompt.
	local loanSpot           = Instance.new("Attachment")
	loanSpot.Name            = "LoanPrompt"
	loanSpot.Position        = Vector3.new(0, -1.3, 0)
	loanSpot.Parent          = root
	local loan               = Instance.new("ProximityPrompt")
	loan.ActionText          = "Borrow money"
	loan.ObjectText          = ("+%d%% on top · desperate times"):format(math.floor(TonyService.LOAN_FEE * 100 + 0.5))
	loan.Style               = Enum.ProximityPromptStyle.Custom
	loan:SetAttribute("Tone", "money")
	loan.KeyboardKeyCode     = LOAN_KEY
	loan.HoldDuration        = 0
	loan.MaxActivationDistance = PROMPT_REACH
	loan.RequiresLineOfSight = false
	loan.Enabled             = TonyService.GetMood().id == "desperate"
	loan.Parent              = loanSpot
	loan.Triggered:Connect(function(player)
		local ok, why = TonyService.CanLoan(player)
		if not ok then
			return say(player, if why == "tooMuchDebt" then LINES.loanNo else LINES.loanNotNow)
		end
		loanOffered[player] = true
		Remotes.LoanOffer:FireClient(player, {
			amounts = TonyService.LOAN_AMOUNTS,
			fee = TonyService.LOAN_FEE,
			debt = TonyService.GetDebt(player),
		})
	end)

	local face = addMoodFace(landlord)
	TonyService.MoodChanged:Connect(function(mood)
		prompt.ActionText = promptText()
		if face then face.Text = mood.face end
		loan.Enabled = mood.id == "desperate"
		if mood.id ~= "desperate" then
			-- The offer's off: close any open loan card.
			for player in pairs(loanOffered) do Remotes.LoanOffer:FireClient(player, nil) end
			table.clear(loanOffered)
		end
		-- Everyone renting sees the new rate on their panel.
		for player in pairs(rentals) do pushRent(player) end
	end)
end

-- A default-looking placeholder Tony standing on top of `spot`, facing its front.
local function makePlaceholder(spot: BasePart): Model?
	local top = spot.Position + Vector3.new(0, spot.Size.Y / 2, 0)
	return Npc.Spawn(LANDLORD_NAME .. " (Landlord)", CFrame.lookAt(top, top + spot.CFrame.LookVector), nil)
end

task.spawn(function()
	local landlord = Workspace:FindFirstChild("Landlord")
	if landlord and landlord:IsA("Model") then
		addPrompt(landlord)
		return
	end
	local spot = Workspace:WaitForChild("LandlordSpot", 10)
	if spot and spot:IsA("BasePart") then
		local placeholder = makePlaceholder(spot)
		if placeholder then addPrompt(placeholder) end
	else
		log.warn("No Workspace.Landlord model or Workspace.LandlordSpot part — nobody to rent a bay from")
	end
end)

-- ── Loans ─────────────────────────────────────────────────────────────────────

Remotes.RequestLoan.OnServerEvent:Connect(function(player, amount: any)
	if not loanOffered[player] then return end
	loanOffered[player] = nil
	if type(amount) ~= "number" then return end -- "no thanks"
	local owed = TonyService.TakeLoan(player, amount)
	if owed then
		say(player, LINES.loanTaken:format(amount, owed))
	else
		local _, why = TonyService.CanLoan(player)
		say(player, if why == "tooMuchDebt" then LINES.loanNo else LINES.loanNotNow)
	end
end)

-- ── Leaving ───────────────────────────────────────────────────────────────────

Remotes.ReleaseBay.OnServerEvent:Connect(function(player)
	giveUp(player, LINES.keysBack)
end)

-- Leaving ends the shift: the bay goes back to Tony. (The job and its car
-- are saved by JobService and CarService in their OnBeforeRelease.)
Players.PlayerRemoving:Connect(function(player)
	loanOffered[player] = nil
	release(player)
end)

return BayRentalService
