--!strict
--[[
    DevService (ModuleScript, started by Main)
    ------------------------------------------
    Testing cheats for the game's OWNER only (works in the live game and in
    Studio). The owner is the place's creator — or, for a group game, the
    group's owner. Everyone else gets nothing: no menu (the client only
    builds it when the player has the "IsDev" attribute) and every request
    is checked again here.

    DevCommand (client -> server): command, value
      money        +/- dollars          setMoney     dollars
      stars        +/- stars            setStars     stars (0–5)
      debt         +/- dollars          clearDebt
      xp           + XP
      mood         mood id ("good", "desperate", ...)
      customer     a customer joins your queue now
      inspect      Tony inspects your bay in 10 seconds
      strikes      clear your late-rent strikes
      unban        lift Tony's eviction ban
    DevCommand (server -> client): a short result line for the menu.
]]

local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules           = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local Remotes           = require(Modules:WaitForChild("Remotes"))
local Log               = require(Modules:WaitForChild("Log"))
local ProfileManager    = require(script.Parent.Parent.Modules.ProfileManager)
local Owner             = require(script.Parent.Parent.Modules.Owner)
local MoneyService      = require(script.Parent.MoneyService)
local LevelService      = require(script.Parent.LevelService)
local ReputationService = require(script.Parent.ReputationService)
local TonyService       = require(script.Parent.TonyService)
local JobService        = require(script.Parent.JobService)
local BayRentalService  = require(script.Parent.BayRentalService)

local log = Log.new("DevService")

local DevService = {}

-- ── Who's the owner (rule lives in Owner.luau) ────────────────────────────────

local isOwner = Owner.Is
Players.PlayerAdded:Connect(Owner.Mark)
for _, p in ipairs(Players:GetPlayers()) do task.spawn(Owner.Mark, p) end

-- ── Commands ──────────────────────────────────────────────────────────────────

local function num(value: any): number?
	return if type(value) == "number" and value == value and math.abs(value) < 1e9 then value else nil
end

local COMMANDS: { [string]: (Player, any) -> string } = {
	money = function(player, value)
		local n = num(value)
		if not n then return "Bad amount" end
		local have = MoneyService.GetMoney(player) or 0
		local change = math.max(math.floor(n), -have) -- never below $0
		MoneyService.AddMoney(player, change, "dev")
		return ("Money %+d → $%d"):format(change, MoneyService.GetMoney(player) or 0)
	end,
	setMoney = function(player, value)
		local n = num(value)
		if not n then return "Bad amount" end
		local have = MoneyService.GetMoney(player) or 0
		MoneyService.AddMoney(player, math.max(0, math.floor(n)) - have, "dev")
		return ("Money set to $%d"):format(MoneyService.GetMoney(player) or 0)
	end,
	stars = function(player, value)
		local n = num(value)
		if not n then return "Bad amount" end
		local now = ReputationService.Add(player, n, "dev")
		return ("Reputation %+.2f → %.2f★"):format(n, now)
	end,
	setStars = function(player, value)
		local n = num(value)
		if not n then return "Bad amount" end
		local now = ReputationService.Add(player, math.clamp(n, 0, 5) - ReputationService.Get(player), "dev")
		return ("Reputation set to %.2f★"):format(now)
	end,
	debt = function(player, value)
		local n = num(value)
		if not n then return "Bad amount" end
		TonyService.AdjustDebt(player, -math.floor(n), "dev") -- AdjustDebt takes money OFF the debt
		return ("Debt → $%d"):format(TonyService.GetDebt(player))
	end,
	clearDebt = function(player)
		TonyService.AdjustDebt(player, TonyService.GetDebt(player), "dev")
		return "Debt cleared"
	end,
	xp = function(player, value)
		local n = num(value)
		if not n or n <= 0 then return "Bad amount" end
		LevelService.AddXP(player, math.floor(n), "dev")
		return ("+%d XP"):format(math.floor(n))
	end,
	mood = function(_, value)
		if type(value) ~= "string" or not TonyService.ForceMood(value) then return "Unknown mood" end
		return "Tony's mood: " .. value
	end,
	customer = function(player)
		return if JobService.DevCustomerNow(player) then "A customer's arrived" else "No room (rent a bay, max 3 waiting)"
	end,
	inspect = function(player)
		return if BayRentalService.DevInspectSoon(player, 10) then "Inspection in 10 seconds" else "Rent a bay first"
	end,
	strikes = function(player)
		return if BayRentalService.DevClearStrikes(player) then "Strikes cleared" else "Rent a bay first"
	end,
	unban = function(player)
		BayRentalService.DevLiftBan(player)
		return "Eviction ban lifted"
	end,
}

Remotes.DevCommand.OnServerEvent:Connect(function(player, command: any, value: any)
	if not isOwner(player) then
		log.warn(player.Name, "tried a dev command without being the owner")
		return
	end
	if not ProfileManager.GetProfile(player) then return end
	local run = type(command) == "string" and COMMANDS[command] or nil
	if not run then return end
	local ok, result = pcall(run, player, value)
	local text = if ok then result else "Failed: " .. tostring(result)
	log.info(player.Name, "dev:", command, tostring(value), "→", text)
	Remotes.DevCommand:FireClient(player, text)
end)

-- The mood list for the menu's buttons.
DevService.MoodIds = TonyService.MoodIds

return DevService
