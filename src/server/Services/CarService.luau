--!strict
--[[
    CarService (ModuleScript, started by Main)
    ------------------------------------------
    Cars: their identity, who may work on them, saving them, and putting
    them in a bay. See CarUtils for what counts as a car.

    Identity: every car in the world has a unique "CarId" attribute and the
    "Car" tag. A saved car keeps the same id every session.

    Every spawned car comes from a record (SaveData.CarRecord) and is kept
    exactly in step with it:
    - SpawnCar(worker, record, bay, owned) clones record.model from
      ServerStorage.Cars, sets it up from the record (missing parts
      removed, every part's wear from the record — never random), marks
      `worker` as the one allowed to work on it (WorkerUserId), and places
      it in the bay. `owned` = it's the worker's own car (OwnerUserId too);
      a customer's car isn't.
    - Where the record is saved is up to the caller: a player's own car
      lives in profile.Data.cars, a customer's car in their active job.
      CarService only ever changes the record table it was given.
    - Every removal and reinstall updates the record straight away
      (RecordChange), so a crash can't leave a part both in the car and in
      the inventory.
    - Inspections are kept on the record too (IsInspected / MarkInspected),
      so they leave with the car instead of piling up in the save.
    - When the worker leaves, each of their cars is saved one last time and
      removed.

    Parked cars: SpawnParked(record, spot) puts a look-alike of a car in a
    parking space (customers waiting outside — JobService). It's just for
    show: no id, no worker, nothing on it works, and it isn't saved. It's
    removed with :Destroy() when the customer is taken or leaves.

    Own cars: SpawnActiveCar spawns the player's garage car (a starter car
    if they have none). Not used right now — players work on customers'
    cars until the junkyard exists (BayRentalService.SPAWN_OWN_CAR).

    Setup in the place file: car models in ServerStorage.Cars (the engine is
    any Model inside with an EngineTrigger). Cars left in the Workspace get
    ids, but nobody can work on them.
]]

local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")
local Workspace         = game:GetService("Workspace")

local Modules        = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local CarUtils       = require(Modules:WaitForChild("CarUtils"))
local Remotes        = require(Modules:WaitForChild("Remotes"))
local Signal         = require(Modules:WaitForChild("Signal"))
local Log            = require(Modules:WaitForChild("Log"))
local ProfileManager = require(script.Parent.Parent.Modules.ProfileManager)
local SaveData       = require(script.Parent.Parent.Modules.SaveData)
local CarState       = require(script.Parent.Parent.Modules.CarState)

local log = Log.new("CarService")

type CarRecord = SaveData.CarRecord
type Profile   = ProfileManager.Profile

-- ── Config ────────────────────────────────────────────────────────────────────

local STARTER_MODEL: string? = nil  -- starter car template; nil = first in ServerStorage.Cars (A–Z)
local FLOOR_GAP              = 0.05 -- studs left under the car when placing it

-- Cars in a bay are held perfectly still: their own scripts (e.g. the
-- A-Chassis driving scripts) are switched off and every part is anchored.
-- With live suspension, every part taken out made the car bounce, and parts
-- went back in the wrong place because the engine had moved under them.
-- Customers' cars are never driven; turn this off once players drive their
-- own cars in and out.
local HOLD_STILL_IN_BAY      = true

local CarService = {}

-- Fired with (carId) whenever a spawned car's record changes because a part
-- or bolt was removed or put back (JobService watches job progress with it).
CarService.CarChanged = Signal.new()

-- ── State ─────────────────────────────────────────────────────────────────────

-- [carId] = car, for every car in the world
local carsById: { [string]: Instance } = {}

-- Every car CarService has spawned: [carId] = { car, record, worker, owned }
type Spawned = { car: Model, record: CarRecord, worker: Player, owned: boolean }
local spawned: { [string]: Spawned } = {}

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

-- The Inspectable part paths of a template, worked out once per model.
local inspectableCache: { [string]: { string } } = {}
local function inspectablePaths(modelName: string): { string }
	local cached = inspectableCache[modelName]
	if cached then return cached end
	local templates = getTemplates()
	local template = templates and templates:FindFirstChild(modelName)
	local engine = template and findEngine(template)
	local paths = if engine then CarState.InspectablePaths(engine) else {}
	inspectableCache[modelName] = paths
	return paths
end

-- The spawned entry for a car (or anything inside one), or nil.
local function entryFor(instance: Instance): Spawned?
	local id = CarUtils.GetCarId(instance)
	local entry = if id then spawned[id] else nil
	if entry and entry.car == CarUtils.GetCar(instance) then
		return entry
	end
	return nil
end

-- A player's own (garage) car record, creating a starter car if they have none.
local function ensureActiveCar(profile: Profile): CarRecord?
	local data = profile.Data
	local activeId = data.activeCarId
	if activeId and data.cars[activeId] then
		return data.cars[activeId]
	end

	local modelName = STARTER_MODEL or CarService.ListModels()[1]
	if not modelName then return nil end

	-- Starter cars get a random condition, part by part.
	local record = CarService.NewRecord(modelName, function()
		return math.random(10, 100)
	end)
	if not record then return nil end
	data.cars[record.id] = record
	data.activeCarId = record.id
	return record
end

-- ── Placing a car ─────────────────────────────────────────────────────────────

-- Switches off the car's own scripts and anchors every part (see
-- HOLD_STILL_IN_BAY). Done before the car enters the world, so nothing in
-- it ever runs or moves.
local function holdStill(car: Model)
	for _, d in ipairs(car:GetDescendants()) do
		if d:IsA("BaseScript") then
			d.Enabled = false
		elseif d:IsA("BasePart") then
			d.Anchored = true
		end
	end
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
	for _, name in ipairs({ "EngineZones", "DroppedParts", "NPCs", "Cars", "ParkedCars", "ParkingSpots" }) do
		local folder = Workspace:FindFirstChild(name)
		if folder then table.insert(ignore, folder) end
	end
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		if char then table.insert(ignore, char) end
	end
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true

	-- Look for the floor from the MIDDLE of the bay down, not from its top:
	-- a tall bay part can poke up through the garage roof, and a ray from
	-- its top would land the car on the roof.
	local hit = Workspace:Raycast(zone.Position, Vector3.new(0, -(zone.Size.Y / 2 + 50), 0), params)
	local floorY = if hit then hit.Position.Y else zone.Position.Y - zone.Size.Y / 2

	-- Centre the car's box over the bay and sit it on the floor.
	local shift = Vector3.new(zone.Position.X - boxCFrame.Position.X, floorY + FLOOR_GAP - bottomY, zone.Position.Z - boxCFrame.Position.Z)
	car:PivotTo(car:GetPivot() + shift)
end

-- Where look-alike cars waiting in the car park live.
local parkedFolder = Workspace:FindFirstChild("ParkedCars")
if not parkedFolder then
	local folder  = Instance.new("Folder")
	folder.Name   = "ParkedCars"
	folder.Parent = Workspace
	parkedFolder  = folder
end

-- ── Spawning and despawning ───────────────────────────────────────────────────

-- Tells the worker's client which parts of this car they've inspected.
local function syncInspections(worker: Player, record: CarRecord)
	local keys = {}
	for partName in pairs(record.inspected) do
		table.insert(keys, record.id .. ":" .. partName)
	end
	Remotes.InspectedSync:FireClient(worker, keys)
end

local function despawn(carId: string)
	local entry = spawned[carId]
	if not entry then return end
	spawned[carId] = nil
	snapshot(entry.car, entry.record)
	entry.car:Destroy()
end

-- ── Public ────────────────────────────────────────────────────────────────────

-- Car models available in ServerStorage.Cars, A–Z.
function CarService.ListModels(): { string }
	local names = {}
	local templates = getTemplates()
	if templates then
		for _, child in ipairs(templates:GetChildren()) do
			if child:IsA("Model") then table.insert(names, child.Name) end
		end
	end
	table.sort(names)
	return names
end

-- The Inspectable part paths of a car model ("Alternator", ...).
function CarService.GetPartPaths(modelName: string): { string }
	return table.clone(inspectablePaths(modelName))
end

-- A brand-new record for a car of `modelName` with a new id, nothing
-- missing, and every part's wear set: wearFor(path) for each part, or
-- perfect (100) if no wearFor is given. Saving it is up to the caller.
function CarService.NewRecord(modelName: string, wearFor: ((path: string) -> number)?): CarRecord?
	local templates = getTemplates()
	if not templates or not templates:FindFirstChild(modelName) then
		log.warn("No car model", modelName, "in ServerStorage.Cars")
		return nil
	end
	local wear: { [string]: number } = {}
	for _, path in ipairs(inspectablePaths(modelName)) do
		wear[path] = math.clamp(if wearFor then wearFor(path) else CarState.DEFAULT_WEAR, 0, 100)
	end
	return {
		id        = HttpService:GenerateGUID(false),
		model     = modelName,
		missing   = {},
		wear      = wear,
		xpPaid    = {},
		inspected = {},
	}
end

-- Spawns the car `record` describes in `zone`, for `worker` to work on.
-- `owned`: it's the worker's own car. Returns the car, or nil if it
-- couldn't be spawned (a warning says why).
function CarService.SpawnCar(worker: Player, record: CarRecord, zone: BasePart, owned: boolean): Model?
	local existing = spawned[record.id]
	if existing then return existing.car end

	local templates = getTemplates()
	local template = templates and templates:FindFirstChild(record.model)
	if not template or not template:IsA("Model") then
		log.warn("No template", record.model, "in ServerStorage.Cars for", worker.Name)
		return nil
	end

	reservedZones[zone.Name] = true
	local ok, result = pcall(function(): Model
		local car = template:Clone()
		car:SetAttribute(CarUtils.ID_ATTRIBUTE, record.id)
		car:SetAttribute(CarUtils.WORKER_ATTRIBUTE, worker.UserId)
		if owned then
			car:SetAttribute(CarUtils.OWNER_ATTRIBUTE, worker.UserId)
		end
		applyRecord(car, record)
		if HOLD_STILL_IN_BAY then
			holdStill(car)
		end
		placeInZone(car, zone)
		car.Parent = carsFolder
		register(car)
		return car
	end)
	reservedZones[zone.Name] = nil

	if not ok then
		log.warn("Couldn't spawn", record.model, "for", worker.Name, result)
		return nil
	end
	local car = result :: Model
	spawned[record.id] = { car = car, record = record, worker = worker, owned = owned }
	snapshot(car, record) -- the record now matches the car exactly
	syncInspections(worker, record)
	log.debug("Spawned", record.model, "for", worker.Name, "in", zone.Name)
	return car
end

-- A look-alike of the car `record` describes, parked in `spot` (a part in
-- Workspace.ParkingSpots, used like a bay: centred on it, on the floor,
-- turned the way the part is turned). For show only — see the header.
function CarService.SpawnParked(record: CarRecord, spot: BasePart): Model?
	local templates = getTemplates()
	local template = templates and templates:FindFirstChild(record.model)
	if not template or not template:IsA("Model") then return nil end
	local ok, result = pcall(function(): Model
		local car = template:Clone()
		applyRecord(car, record)
		-- Nothing on it works: no engine trigger (so it never counts as a
		-- car), no prompts, clicks or scripts.
		for _, d in ipairs(car:GetDescendants()) do
			if d.Name == "EngineTrigger" or d:IsA("ProximityPrompt") or d:IsA("ClickDetector") then
				d:Destroy()
			elseif d:IsA("Seat") then
				d.Disabled = true -- nobody sits in a customer's waiting car
			elseif d:IsA("VehicleSeat") then
				d.Disabled = true
			end
		end
		holdStill(car)
		placeInZone(car, spot)
		car.Name = record.model .. " (waiting)"
		car.Parent = parkedFolder
		return car
	end)
	if not ok then
		log.warn("Couldn't park", record.model, result)
		return nil
	end
	return result
end

-- Saves and removes a spawned car (e.g. a customer's car going home).
function CarService.DespawnCar(carId: string)
	despawn(carId)
end

-- Spawns the player's own car (a starter car if they have none) in `zone`.
function CarService.SpawnActiveCar(player: Player, zone: BasePart): Model?
	local profile = ProfileManager.GetProfile(player)
	if not profile then return nil end
	local record = ensureActiveCar(profile)
	if not record then
		log.warn("No car for", player.Name, "- put car models in ServerStorage.Cars")
		return nil
	end
	return CarService.SpawnCar(player, record, zone, true)
end

-- Is a car being placed in this bay right now?
function CarService.IsPlacingIn(zoneName: string): boolean
	return reservedZones[zoneName] == true
end

function CarService.GetCar(carId: string): Instance?
	return carsById[carId]
end

function CarService.GetOwnedCar(player: Player): Instance?
	return CarUtils.FindCarOwnedBy(player.UserId)
end

-- The record of a spawned car (or of the car something is inside), or nil.
function CarService.GetRecord(instance: Instance): CarRecord?
	local entry = entryFor(instance)
	return entry and entry.record
end

-- Has this car's worker inspected `part` (a part directly in the engine)?
function CarService.IsInspected(part: Instance): boolean
	local entry = entryFor(part)
	return entry ~= nil and entry.record.inspected[part.Name] == true
end

-- Records that `part` has been inspected. False if the car isn't a
-- spawned (saved) car — nothing to record it on.
function CarService.MarkInspected(part: Instance): boolean
	local entry = entryFor(part)
	if not entry then return false end
	entry.record.inspected[part.Name] = true
	return true
end

-- Call after a part or bolt is removed from or put back into a car, so the
-- record matches the car straight away.
function CarService.RecordChange(instance: Instance)
	local entry = entryFor(instance)
	if entry then
		snapshot(entry.car, entry.record)
		CarService.CarChanged:Fire(entry.record.id)
	end
end

-- ── Start ─────────────────────────────────────────────────────────────────────

for _, descendant in ipairs(Workspace:GetDescendants()) do
	check(descendant)
end
Workspace.DescendantAdded:Connect(check)

if not getTemplates() then
	log.warn("ServerStorage.Cars is missing — no cars can be spawned")
end

-- Every car a leaving player works on is saved one last time and removed,
-- right before their profile is released.
ProfileManager.OnBeforeRelease(function(player)
	for carId, entry in pairs(spawned) do
		if entry.worker == player then
			despawn(carId)
		end
	end
end)

return CarService
