--[[
    MoneyService (Script)
    ----------------------
    Server-authoritative money balance. Basic on purpose, for the testing
    phase: every profile starts with a flat TEST_STARTING_BALANCE (set on
    ProfileManager's template, not here — see PROFILE_TEMPLATE.money), and
    TEST_FLAT_COST is a placeholder $1 cost any future feature can charge
    without needing its own pricing yet (renting a bay, buying a part off
    the marketplace, etc.) — swap in real numbers later without touching
    the call sites, since they'd just pass a different amount.

    RemoteEvents used:
    - MoneyUpdated   (server -> client) fires whenever the balance changes
    - RequestMoney   (client -> server) client asks for current balance
                       (e.g. on join), mirrors LevelService's RequestXp /
                       InventoryService's RequestInventory pattern

    Also pushes once on its own shortly after the player's character
    spawns — not just reacting to RequestMoney — because the profile load
    InventoryService kicks off on PlayerAdded can still be in flight when
    LevelUI's RequestMoney fires on join. If that race loses, RequestMoney
    silently does nothing (profile not loaded yet = nothing to send) and
    the client is left on its hardcoded placeholder forever, with no
    error anywhere. Same race, same fix InventoryService already uses for
    its own initial push (CharacterAdded + a short wait).

    Other scripts call MoneyService.AddMoney / TrySpend directly, the same
    way RepairService calls LevelService.AddXP — those are already
    server-authoritative at the point they'd be called, so there's no
    remote needed for spending/earning itself, only for syncing the result
    to the client that owns it.

    Place in: ServerScriptService/Services
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileManager = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Modules"):WaitForChild("ProfileManager"))

-- ── Config ────────────────────────────────────────────────────────────────────

-- Placeholder flat cost for "anything that costs money" while nothing has
-- real pricing designed yet. Exported so call sites reference it by name
-- instead of hardcoding 1 everywhere it's used.
local TEST_FLAT_COST = 1

-- ── Remotes ───────────────────────────────────────────────────────────────────

local function getOrCreate(parent, className, name)
	local existing = parent:FindFirstChild(name)
	if existing then return existing end
	local inst  = Instance.new(className)
	inst.Name   = name
	inst.Parent = parent
	return inst
end

local remoteFolder   = getOrCreate(ReplicatedStorage, "Folder", "RemoteEvents")
local moneyUpdated   = getOrCreate(remoteFolder, "RemoteEvent", "MoneyUpdated")
local requestMoney   = getOrCreate(remoteFolder, "RemoteEvent", "RequestMoney")

-- ── Public API ────────────────────────────────────────────────────────────────

local MoneyService = {}
MoneyService.TEST_FLAT_COST = TEST_FLAT_COST

-- Sends this player's current balance to their client. Safe to call any
-- time — does nothing if the profile isn't loaded yet.
local function pushMoneyToClient(player)
	local profile = ProfileManager.GetProfile(player)
	if not profile then return end
	moneyUpdated:FireClient(player, profile.Data.money)
end

-- Current balance, or nil if the profile isn't loaded yet.
function MoneyService.GetMoney(player)
	local profile = ProfileManager.GetProfile(player)
	return profile and profile.Data.money or nil
end

-- Adds (or, with a negative amount, removes) money, saves it, and notifies
-- the client. `reason` is only used for the Output log — purely diagnostic.
-- Prefer TrySpend over a negative AddMoney call when the money is paying
-- for something, so the cost can be validated/refused atomically.
function MoneyService.AddMoney(player, amount, reason)
	local profile = ProfileManager.GetProfile(player)
	if not profile then return end
	if type(amount) ~= "number" or amount == 0 then return end

	profile.Data.money = profile.Data.money + amount

	print(("[MoneyService] %s %s$%d (%s) — total $%d"):format(
		player.Name, amount >= 0 and "+" or "-", math.abs(amount), reason or "?", profile.Data.money))

	pushMoneyToClient(player)
end

-- Attempts to charge `amount`. Returns true and deducts it if the player
-- can afford it; returns false and changes nothing otherwise. Use this
-- (not AddMoney with a negative number) for anything that's actually
-- paying for something, so insufficient funds can't go negative.
function MoneyService.TrySpend(player, amount, reason)
	local profile = ProfileManager.GetProfile(player)
	if not profile then return false end
	if type(amount) ~= "number" or amount <= 0 then return false end

	if profile.Data.money < amount then
		return false
	end

	profile.Data.money = profile.Data.money - amount

	print(("[MoneyService] %s -$%d (%s) — total $%d"):format(
		player.Name, amount, reason or "?", profile.Data.money))

	pushMoneyToClient(player)
	return true
end

-- ── Requests ──────────────────────────────────────────────────────────────────

requestMoney.OnServerEvent:Connect(function(player)
	pushMoneyToClient(player)
end)

-- ── Initial push ──────────────────────────────────────────────────────────────
-- See the header comment: this exists so a player isn't left showing a
-- stale/placeholder balance forever if their own RequestMoney happened to
-- fire before the profile finished loading.

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		task.wait(1)
		pushMoneyToClient(player)
	end)
end)

return MoneyService
