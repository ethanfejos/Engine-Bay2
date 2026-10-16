--!strict
--[[
    BayRentalService (ModuleScript, started by Main)
    ------------------------------------------------
    Renting a bay from the landlord, Tony. Phase 1 (basics):

    - Tony stands in the garage with a "Rent a bay" prompt. Renting costs
      RENT (MoneyService.TEST_FLAT_COST, $1, while testing), paid up front.
    - You get the first free Mechanic bay to yourself for this session (a
      "shift"): it's marked with your UserId ("RentedBy" on the bay part,
      which the client uses for the YOUR BAY marker). Customers' cars come
      to it (JobService.BayRented). (With SPAWN_OWN_CAR on, your own car spawns into it instead —
      off until the junkyard gives players cars of their own.)
    - One bay per player. If every bay is taken, or you can't afford it,
      Tony says so and nothing is charged.
    - Leaving the game ends the shift: the bay goes back to Tony (and your
      car is saved and removed by CarService). No refunds.

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
local MoneyService   = require(script.Parent.MoneyService)
local CarService     = require(script.Parent.CarService)
local JobService     = require(script.Parent.JobService)

local log = Log.new("BayRentalService")

-- ── Config ────────────────────────────────────────────────────────────────────

local LANDLORD_NAME  = "Tony"
local RENT           = MoneyService.TEST_FLAT_COST -- per shift; $1 while testing
local BAY_ZONE_TYPE  = "Mechanic"
local PROMPT_REACH   = 10
local SPAWN_OWN_CAR  = false -- spawn the player's own (starter) car on renting; back on with the junkyard

-- Tony's lines. Greedy, short.
local LINES = {
	rented       = "Bay %s is yours. $%d, paid up front. Scratch anything and you're paying for it.",
	rentedNoCar  = "Bay %s is yours. $%d, paid up front. Wait there, customers'll turn up.",
	alreadyHave  = "You've already got a bay, kid. One's plenty.",
	full         = "Full up. Come back when someone clears out.",
	broke        = "Rent's $%d. Up front. No money, no bay.",
	notLoaded    = "Hang on, still finding your paperwork. Try again in a sec.",
	noCar        = "Bay's yours, but your car's not turned up. Talk to me again later.",
}

local BayRentalService = {}

-- ── State ─────────────────────────────────────────────────────────────────────

-- [player] = the bay they rent
local rentals: { [Player]: BasePart } = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function say(player: Player, text: string)
	Remotes.NpcSpeech:FireClient(player, LANDLORD_NAME, text)
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
	local bay = rentals[player]
	if not bay then return end
	rentals[player] = nil
	if ZoneUtils.GetRenter(bay) == player.UserId then
		bay:SetAttribute(ZoneUtils.RENTED_BY_ATTRIBUTE, nil)
	end
	log.debug(player.Name, "gave back", bay.Name)
end

-- ── Renting ───────────────────────────────────────────────────────────────────

local function rent(player: Player)
	if rentals[player] then
		return say(player, LINES.alreadyHave)
	end
	if not ProfileManager.GetProfile(player) then
		return say(player, LINES.notLoaded)
	end

	local bay = findFreeBay()
	if not bay then
		return say(player, LINES.full)
	end
	-- Take the bay before paying, so two players can't get the same one.
	bay:SetAttribute(ZoneUtils.RENTED_BY_ATTRIBUTE, player.UserId)
	rentals[player] = bay

	if not MoneyService.TrySpend(player, RENT, "bay rent") then
		release(player)
		return say(player, LINES.broke:format(RENT))
	end

	if not SPAWN_OWN_CAR then
		say(player, LINES.rentedNoCar:format(bay.Name, RENT))
		JobService.BayRented(player, bay) -- a saved job comes back, or the first customer turns up
	elseif CarService.SpawnActiveCar(player, bay) then
		say(player, LINES.rented:format(bay.Name, RENT))
	else
		say(player, LINES.noCar)
	end
	log.debug(player.Name, "rented", bay.Name)
end

-- ── Public ────────────────────────────────────────────────────────────────────

-- The bay this player rents, or nil.
function BayRentalService.GetBay(player: Player): BasePart?
	return rentals[player]
end

-- ── Tony ──────────────────────────────────────────────────────────────────────

local function addPrompt(landlord: Model)
	local root = landlord:FindFirstChild("HumanoidRootPart") or landlord.PrimaryPart
	if not root or not root:IsA("BasePart") then
		log.warn("Landlord model has no HumanoidRootPart or PrimaryPart for the prompt")
		return
	end
	local prompt                 = Instance.new("ProximityPrompt")
	prompt.ActionText            = ("Rent a bay ($%d)"):format(RENT)
	prompt.ObjectText            = LANDLORD_NAME .. " · Landlord"
	prompt.HoldDuration          = 0
	prompt.MaxActivationDistance = PROMPT_REACH
	prompt.RequiresLineOfSight   = false
	prompt.Parent                = root
	prompt.Triggered:Connect(rent)
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

-- ── Leaving ───────────────────────────────────────────────────────────────────

-- The shift ends: the bay goes back to Tony. (CarService saves and removes
-- the car in its own OnBeforeRelease.)
Players.PlayerRemoving:Connect(release)

return BayRentalService
