--!strict
--[[
    Main (Script) — the only server Script
    --------------------------------------
    Starts every server service in a fixed order. Each service is a
    ModuleScript: requiring it sets up its remotes and connections, and
    returns its public API (or an empty table).

    Order matters only where one service listens to another before players
    can act, so the rule is simply: a service comes after everything it
    requires. Adding a service = one line in ORDER.

    If one service fails to start, the error is logged and the others still
    start — one broken system shouldn't take down the whole server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Services      = script.Parent:WaitForChild("Services")
local Modules       = script.Parent:WaitForChild("Modules")
local SharedModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")

local log = require(SharedModules:WaitForChild("Log")).new("Main")

local ORDER = {
	{ SharedModules, "Remotes" },      -- creates every RemoteEvent first
	{ Modules,  "ProfileManager" },    -- saving; everything below uses it
	{ Services, "ZoneService" },       -- zone enter/leave signals
	{ Services, "CarService" },        -- car ids and owners
	{ Services, "InventoryService" },
	{ Services, "LevelService" },
	{ Services, "MoneyService" },
	{ Services, "ReputationService" },
	{ Services, "TonyService" },       -- needs Money
	{ Services, "PartPickupService" }, -- needs Inventory + Zone
	{ Services, "EngineServer" },      -- needs Level + PartPickup
	{ Services, "RepairService" },     -- needs Inventory + Level + Money
	{ Services, "ToolService" },       -- needs Zone
	{ Services, "JobService" },        -- needs Car, Money, Level, Inventory, PartPickup, Reputation, Tony
	{ Services, "BayRentalService" },  -- needs Car, Money, Tony, Job
}

local started, failed = 0, 0
for _, entry in ipairs(ORDER) do
	local folder, name = entry[1], entry[2]
	local module = folder:FindFirstChild(name)
	if not module then
		log.warn("Missing service:", name)
		failed += 1
		continue
	end
	local ok, err = pcall(require, module)
	if ok then
		started += 1
	else
		log.warn(name .. " failed to start:", err)
		failed += 1
	end
end

log.info(("Server started: %d services, %d failed"):format(started, failed))
