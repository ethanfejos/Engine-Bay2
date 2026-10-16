--!strict
--[[
    CarService (ModuleScript, started by Main)
    ------------------------------------------
    Cars: their identity, their owner, and saving them. See CarUtils for
    what counts as a car.

    Identity: every car in the world has a unique "CarId" attribute and the
    "Car" tag. A player's car keeps the same id every session (it's saved).

    Each player's car is saved and comes back exactly as they left it:
    - Join: the player's active car (profile.Data.cars / activeCarId) is
      cloned from its template in ServerStorage.Cars, set up from the save
      (missing parts removed, each part's wear restored), owned by them and
      placed in a free bay. A player with no car gets a starter car.
    - While playing: every removal and reinstall updates the save straight
      away (EngineServer / InventoryService call RecordChange), so a server
      crash can't leave a part both in the car and in the inventory.
    - Leave: saved one last time and removed from the world.

    Where a car appears is decided by findSpawnZone — for now the first free
    bay of SPAWN_ZONE_TYPE. Parking spots (rented bays) and owned workshops
    plug in there later.

    Setup in the place file: put each car model in ServerStorage.Cars (its
    engine is any Model inside it with an EngineTrigger, as before). Cars
    left in the Workspace still get ids, but nobody owns them.
]]

local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")
local Workspace         = game:GetService("Workspace")

local Modules        = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local ZoneUtils      = require(Modules:WaitForChild("ZoneUtils"))
local CarUtils       = require(Modules:WaitForChild("CarUtils"))
local Log            = require(Modules:WaitForChild("Log"))
local ProfileManager = require(script.Parent.Parent.Modules.ProfileManager)
local SaveData       = require(script.Parent.Parent.Modules.SaveData)
local CarState       = require(script.Parent.Parent.Modules.CarState)

local log = Log.new("CarService")

type CarRecord = SaveData.CarRecord
type Profile   = ProfileManager.Profile

-- ── Config ────────────────────────────────────────────────────────────────────

local STARTER_MODEL: string? = nil  -- template name for new players; nil = first in ServerStorage.Cars (A–Z)
local SPAWN_ZONE_TYPE        = "Mechanic"
local SPAWN_RETRY            = 3    -- seconds between tries when every bay is taken
local FLOOR_GAP              = 0.05 -- studs left under the car when placing it

local CarService = {}

-- ── State ─────────────────────────────────────────────────────────────────────

-- [carId] = car, for every car in the world
local carsById: { [string]: Instance } = {}

-- Players' spawned cars: [player] = { car, record }
type ActiveCar = { car: Model, record: CarRecord }
local activeCars: { [Player]: ActiveCar } = {}

-- Bays a car is being placed in right now: [zoneName] = true
local reservedZones: { [string]: boolean } = {}

-- Where spawned cars live in the Workspace (a Folder, so each car is its own top-level model).
local carsFolder = Workspace:FindFirstChild("Cars")
if not carsFolder then
	local folder  = Instance.new("Folder")
	folder.Name   = "Cars"
	folder.Parent = Workspace
	carsFolder    = folder
end

local function getTemplates(): Instance?
	return ServerStorage:FindFirstChild("Cars")
end

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

-- The engine inside a car (or the car itself if it is one).
local function findEngine(car: Instance): Model?
	if isEngine(car) then return car :: Model end
	for _, descendant in ipairs(car:GetDescendants()) do
		if isEngine(descendant) then
			return descendant :: Model
		end
	end
	return nil
end

-- ── Saving and restoring ──────────────────────────────────────────────────────

-- The full set of part paths for a template, worked out once per model.
local templatePathCache: { [string]: { [string]: boolean } } = {}
local function templatePaths(modelName: string): { [string]: boolean }
	local cached = templatePathCache[modelName]
	if cached then return cached end
	local templates = getTemplates()
	local template = templates and templates:FindFirstChild(modelName)
	local engine = template and findEngine(template)
	local paths = if engine then CarState.Paths(engine) else {}
	templatePathCache[modelName] = paths
	return paths
end

-- Writes the car's current state into its record (the profile autosaves it).
local function snapshot(car: Instance, record: CarRecord)
	local engine = findEngine(car)
	if engine then
		CarState.Snapshot(engine, templatePaths(record.model), record)
	end
end

-- Sets a fresh clone up the way the record says.
local function applyRecord(car: Model, record: CarRecord)
	local engine = findEngine(car)
	if engine then
		CarState.Apply(engine, record)
	end
end

-- A player's active car record, creating a starter car if they have none.
local function ensureActiveCar(profile: Profile): CarRecord?
	local data = profile.Data
	local activeId = data.activeCarId
	if activeId and data.cars[activeId] then
		return data.cars[activeId]
	end

	local templates = getTemplates()
	if not templates then return nil end
	local modelName = STARTER_MODEL
	if not modelName then
		local names = {}
		for _, child in ipairs(templates:GetChildren()) do
			if child:IsA("Model") then table.insert(names, child.Name) end
		end
		table.sort(names)
		modelName = names[1]
	end
	if not modelName then return nil end

	local record: CarRecord = {
		id      = HttpService:GenerateGUID(false),
		model   = modelName,
		missing = {},
		wear    = {},
		xpPaid  = {},
	}
	data.cars[record.id] = record
	data.activeCarId = record.id
	return record
end

-- ── Where a car appears ───────────────────────────────────────────────────────

-- The bay a player's car spawns in: the first free bay of SPAWN_ZONE_TYPE
-- (no car parked in it, none being placed). Later: a parking spot for
-- players renting a bay, their own workshop for players who bought one.
local function findSpawnZone(_player: Player): BasePart?
	local zonesFolder = Workspace:FindFirstChild("EngineZones")
	if not zonesFolder then return nil end
	local zones = zonesFolder:GetChildren()
	table.sort(zones, function(a, b) return a.Name < b.Name end)
	for _, zone in ipairs(zones) do
		if zone:IsA("BasePart")
			and ZoneUtils.GetZoneType(zone) == SPAWN_ZONE_TYPE
			and not reservedZones[zone.Name]
			and ZoneUtils.GetEngineInZone(zone) == nil then
			return zone
		end
	end
	return nil
end

-- Half the height a box really takes up in the world, whatever way it's
-- rotated (a model's bounding box follows its pivot, which on many cars —
-- A-Chassis included — isn't upright).
local function worldHalfHeight(boxCFrame: CFrame, boxSize: Vector3): number
	local half = boxSize / 2
	return math.abs(boxCFrame.RightVector.Y) * half.X
		+ math.abs(boxCFrame.UpVector.Y) * half.Y
		+ math.abs(boxCFrame.LookVector.Y) * half.Z
end

-- Puts a (not yet parented) car in the middle of a bay, resting on the real
-- floor. The car keeps the rotation it has in ServerStorage.Cars — so it's
-- upright however its pivot is set up — turned by the bay part's own turn
-- (yaw). To change which way cars face in a bay, rotate the bay part.
local function placeInZone(car: Model, zone: BasePart)
	local authored = car:GetPivot().Rotation
	local _, bayYaw, _ = zone.CFrame:ToEulerAnglesYXZ()
	car:PivotTo(CFrame.new(zone.Position) * CFrame.Angles(0, bayYaw, 0) * authored)

	local boxCFrame, boxSize = car:GetBoundingBox()
	local bottomY = boxCFrame.Position.Y - worldHalfHeight(boxCFrame, boxSize)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { car }
	for _, name in ipairs({ "EngineZones", "DroppedParts" }) do
		local folder = Workspace:FindFirstChild(name)
		if folder then table.insert(ignore, folder) end
	end
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		if char then table.insert(ignore, char) end
	end
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true

	local top = zone.Position + Vector3.new(0, zone.Size.Y / 2, 0)
	local hit = Workspace:Raycast(top, Vector3.new(0, -(zone.Size.Y + 50), 0), params)
	local floorY = if hit then hit.Position.Y else zone.Position.Y - zone.Size.Y / 2

	-- Centre the car's box over the bay and sit it on the floor.
	local shift = Vector3.new(zone.Position.X - boxCFrame.Position.X, floorY + FLOOR_GAP - bottomY, zone.Position.Z - boxCFrame.Position.Z)
	car:PivotTo(car:GetPivot() + shift)
end

-- ── Spawning and despawning ───────────────────────────────────────────────────

local function spawnCar(player: Player, profile: Profile)
	local record = ensureActiveCar(profile)
	if not record then
		log.warn("No car for", player.Name, "- put car models in ServerStorage.Cars")
		return
	end
	local templates = getTemplates()
	local template = templates and templates:FindFirstChild(record.model)
	if not template or not template:IsA("Model") then
		log.warn("No template", record.model, "in ServerStorage.Cars for", player.Name)
		return
	end

	-- Wait for a free bay (every bay may be taken).
	local zone: BasePart
	while true do
		local found = findSpawnZone(player)
		if found then
			zone = found
			break
		end
		if not player:IsDescendantOf(Players) then return end
		log.debug("No free bay for", player.Name, "- retrying")
		task.wait(SPAWN_RETRY)
	end
	if not player:IsDescendantOf(Players) or activeCars[player] then return end

	reservedZones[zone.Name] = true
	local ok, err = pcall(function()
		local car = template:Clone()
		car:SetAttribute(CarUtils.ID_ATTRIBUTE, record.id)
		car:SetAttribute(CarUtils.OWNER_ATTRIBUTE, player.UserId)
		applyRecord(car, record)
		placeInZone(car, zone)
		car.Parent = carsFolder
		register(car)
		activeCars[player] = { car = car, record = record }
		log.debug("Spawned", record.model, "for", player.Name, "in", zone.Name)

		-- Brand-new parts get a random wear from EngineServer a moment after
		-- spawning; save it so it's the same next time.
		task.delay(1, function()
			if activeCars[player] and activeCars[player].car == car then
				snapshot(car, record)
			end
		end)
	end)
	reservedZones[zone.Name] = nil
	if not ok then
		log.warn("Couldn't spawn car for", player.Name, err)
	end
end

local function despawnCar(player: Player)
	local active = activeCars[player]
	if not active then return end
	activeCars[player] = nil
	snapshot(active.car, active.record)
	active.car:Destroy()
end

-- ── Public ────────────────────────────────────────────────────────────────────

function CarService.GetCar(carId: string): Instance?
	return carsById[carId]
end

function CarService.GetOwnedCar(player: Player): Instance?
	return CarUtils.FindCarOwnedBy(player.UserId)
end

-- Call after a part or bolt is removed from or put back into a car, so the
-- save matches the car straight away.
function CarService.RecordChange(instance: Instance)
	local car = CarUtils.GetCar(instance)
	for _, active in pairs(activeCars) do
		if active.car == car then
			snapshot(car, active.record)
			return
		end
	end
end

-- ── Start ─────────────────────────────────────────────────────────────────────

for _, descendant in ipairs(Workspace:GetDescendants()) do
	check(descendant)
end
Workspace.DescendantAdded:Connect(check)

if not getTemplates() then
	log.warn("ServerStorage.Cars is missing — players won't get a car")
end

ProfileManager.OnProfileLoaded(spawnCar)

-- Saved one last time and removed, right before the profile is released.
ProfileManager.OnBeforeRelease(function(player)
	despawnCar(player)
end)

return CarService
