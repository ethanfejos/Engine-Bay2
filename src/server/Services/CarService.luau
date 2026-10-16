--!strict
--[[
    CarService (ModuleScript, started by Main)
    ------------------------------------------
    Gives every car an identity and an owner. See CarUtils for what counts
    as a car.

    Identity: every car in the world gets a unique "CarId" attribute and the
    "Car" tag as soon as it appears — including identical copies of the same
    model. (Phase 1: ids are new each server start. Saving cars, with ids
    that last, comes in phase 2.)

    Ownership — one car per player:
    - A car nobody owns shows "Claim car" on its engine-bay prompt (see
      EnginePrompts). ClaimCar (client -> server, carId) claims it if:
      nobody owns it, you don't own another car, and you're standing in the
      bay it's parked in. It sets "OwnerUserId" on the car.
    - Only the owner can inspect, remove or reinstall parts (EngineServer,
      LevelService and InventoryService check), and only the owner sees the
      engine-bay prompt.
    - Leaving the game frees your car.
]]

local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Modules   = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local ZoneUtils = require(Modules:WaitForChild("ZoneUtils"))
local CarUtils  = require(Modules:WaitForChild("CarUtils"))
local Remotes   = require(Modules:WaitForChild("Remotes"))
local Log       = require(Modules:WaitForChild("Log"))

local log = Log.new("CarService")

local CarService = {}

-- [carId] = car, for every car in the world
local carsById: { [string]: Instance } = {}

-- ── Identity ──────────────────────────────────────────────────────────────────

local function register(car: Instance)
	local id = car:GetAttribute(CarUtils.ID_ATTRIBUTE)
	local holder: Instance? = if type(id) == "string" then carsById[id] else nil
	if holder == car then return end -- already known

	-- New car, or a copy that came with another car's id: give it its own.
	if type(id) ~= "string" or id == "" or holder ~= nil then
		id = HttpService:GenerateGUID(false)
		car:SetAttribute(CarUtils.ID_ATTRIBUTE, id)
	end
	local carId = id :: string

	carsById[carId] = car
	CollectionService:AddTag(car, CarUtils.TAG)
	log.debug("Registered car", car:GetFullName(), carId)

	car.AncestryChanged:Connect(function()
		if not car:IsDescendantOf(Workspace) and carsById[carId] == car then
			carsById[carId] = nil
		end
	end)
end

local function isEngine(instance: Instance): boolean
	return instance:IsA("Model") and instance:FindFirstChild("EngineTrigger") ~= nil
end

local function check(instance: Instance)
	if isEngine(instance) then
		register(CarUtils.GetCar(instance))
	elseif instance.Name == "EngineTrigger" then
		-- Some cars are built up bit by bit: the trigger can arrive after its engine.
		local engine = instance.Parent
		if engine and isEngine(engine) then
			register(CarUtils.GetCar(engine))
		end
	end
end

for _, descendant in ipairs(Workspace:GetDescendants()) do
	check(descendant)
end
Workspace.DescendantAdded:Connect(check)

-- ── Public ────────────────────────────────────────────────────────────────────

function CarService.GetCar(carId: string): Instance?
	return carsById[carId]
end

function CarService.GetOwnedCar(player: Player): Instance?
	return CarUtils.FindCarOwnedBy(player.UserId)
end

-- ── Claiming ──────────────────────────────────────────────────────────────────

Remotes.ClaimCar.OnServerEvent:Connect(function(player: Player, carId: any)
	if type(carId) ~= "string" then return end

	local car = carsById[carId]
	if not car then
		return log.debug(player.Name, "claim refused: unknown car")
	end
	if CarUtils.GetOwnerUserId(car) ~= nil then
		return log.debug(player.Name, "claim refused: already owned")
	end
	if CarService.GetOwnedCar(player) then
		return log.debug(player.Name, "claim refused: already owns a car")
	end
	local engine = ZoneUtils.GetEngineForPlayer(player)
	if not engine or CarUtils.GetCar(engine) ~= car then
		return log.debug(player.Name, "claim refused: not in this car's bay")
	end

	car:SetAttribute(CarUtils.OWNER_ATTRIBUTE, player.UserId)
	log.debug(player.Name, "claimed", car:GetFullName())
end)

-- Leaving frees your car for someone else.
Players.PlayerRemoving:Connect(function(player)
	for _, car in pairs(carsById) do
		if CarUtils.GetOwnerUserId(car) == player.UserId then
			car:SetAttribute(CarUtils.OWNER_ATTRIBUTE, nil)
		end
	end
end)

return CarService
