--!strict
--[[
    ReputationService (ModuleScript, started by Main)
    -------------------------------------------------
    A player's reputation: 0–5 stars, earned and lost in small steps.

    - Saved in profile.Data.reputation. Every player starts at 0 and it
      never goes below 0 or above 5.
    - Shown above every player's head by ReputationStars (client), which
      reads the "Reputation" attribute this service keeps on the Player.
      Attributes replicate to everyone, so all players see each other's
      stars without any remote.

        ReputationService.Add(player, ReputationService.CHANGES.quickJob, "job")

    Who calls it: JobService (jobs handed back, cancelled, customer gave up).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileManager = require(script.Parent.Parent.Modules.ProfileManager)
local Log            = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Log"))

local log = Log.new("ReputationService")

local ATTRIBUTE = "Reputation"
local MAX_STARS = 5

-- How much each thing moves your stars (see the game design document).
local CHANGES = {
	quickJob    = 0.10,  -- good job, finished quickly
	slowJob     = 0.05,  -- good job, finished slowly
	perfectJob  = 0.15,  -- Fussy or Rich customer, finished perfectly (phase 3)
	walkedOut   = -0.25, -- the customer ran out of patience and left
	cancelled   = -0.25, -- you cancelled the job
	caughtUpsell = -0.5, -- caught upselling (phase 4)
}

local ReputationService = {}
ReputationService.CHANGES = CHANGES

local function publish(player: Player, value: number)
	player:SetAttribute(ATTRIBUTE, value)
end

-- Current stars (0–5), or 0 if the profile isn't loaded.
function ReputationService.Get(player: Player): number
	local profile = ProfileManager.GetProfile(player)
	return if profile then profile.Data.reputation else 0
end

-- Moves the player's stars by `delta` (kept between 0 and 5). Returns the
-- new value.
function ReputationService.Add(player: Player, delta: number, reason: string?): number
	local profile = ProfileManager.GetProfile(player)
	if not profile then return 0 end
	local before = profile.Data.reputation
	-- Rounded to 2 decimals so repeated 0.05s don't drift (2.9999999...).
	local after = math.clamp(math.floor((before + delta) * 100 + 0.5) / 100, 0, MAX_STARS)
	profile.Data.reputation = after
	publish(player, after)
	log.debug(("%s reputation %.2f -> %.2f (%s)"):format(player.Name, before, after, reason or "?"))
	return after
end

ProfileManager.OnProfileLoaded(function(player, profile)
	publish(player, profile.Data.reputation)
end)

return ReputationService
