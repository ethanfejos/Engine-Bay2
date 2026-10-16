--!strict
--[[
    CarUtils (ModuleScript, shared)
    -------------------------------
    What "a car" is, and who owns it — the same answer on server and client.

    A car is the top-level model around an engine (ZoneUtils.
    GetTopLevelAncestor): the whole car if the engine sits inside one, or the
    engine itself if it stands alone. Keep cars directly in Workspace or in
    a Folder — not grouped inside another Model, or the group would count as
    one car.

    CarService (server) gives every car:
    - a "CarId" attribute (unique, so identical copies are still different
      cars; a player's saved car keeps its id every session) and the "Car" tag
    - an "OwnerUserId" attribute on a player's own car

    Parts in the inventory remember the carId they came from and only go
    back into that car. Parts from before car ids (no carId), or from a car
    that isn't in this server, fit any car with the same engine, so nothing
    is ever stuck.
]]

local CollectionService = game:GetService("CollectionService")
local Workspace         = game:GetService("Workspace")

local ZoneUtils = require(script.Parent:WaitForChild("ZoneUtils"))

local CarUtils = {}

CarUtils.TAG             = "Car"
CarUtils.ID_ATTRIBUTE    = "CarId"
CarUtils.OWNER_ATTRIBUTE = "OwnerUserId"

-- The car an engine (or any part of a car) belongs to.
function CarUtils.GetCar(instance: Instance): Instance
	return ZoneUtils.GetTopLevelAncestor(instance)
end

function CarUtils.GetCarId(instance: Instance): string?
	local id = CarUtils.GetCar(instance):GetAttribute(CarUtils.ID_ATTRIBUTE)
	return if type(id) == "string" and id ~= "" then id else nil
end

-- UserId of the player who owns the car, or nil if nobody does.
function CarUtils.GetOwnerUserId(instance: Instance): number?
	local owner = CarUtils.GetCar(instance):GetAttribute(CarUtils.OWNER_ATTRIBUTE)
	return if type(owner) == "number" then owner else nil
end

function CarUtils.IsOwnedBy(instance: Instance, player: Player): boolean
	return CarUtils.GetOwnerUserId(instance) == player.UserId
end

-- The car with this id that's in the world right now, or nil.
function CarUtils.FindCarById(carId: string): Instance?
	for _, car in ipairs(CollectionService:GetTagged(CarUtils.TAG)) do
		if car:GetAttribute(CarUtils.ID_ATTRIBUTE) == carId and car:IsDescendantOf(Workspace) then
			return car
		end
	end
	return nil
end

-- The car this player owns in the world right now, or nil.
function CarUtils.FindCarOwnedBy(userId: number): Instance?
	for _, car in ipairs(CollectionService:GetTagged(CarUtils.TAG)) do
		if car:GetAttribute(CarUtils.OWNER_ATTRIBUTE) == userId and car:IsDescendantOf(Workspace) then
			return car
		end
	end
	return nil
end

-- Does an inventory part (its carId and engineName) belong in `engine`?
-- Same engine type, and either the same car, a part from before car ids
-- (no carId), or a part whose car no longer exists in this server.
function CarUtils.PartFits(itemCarId: string?, itemEngineName: string?, engine: Instance): boolean
	if engine.Name ~= itemEngineName then return false end
	if itemCarId == nil then return true end
	if CarUtils.GetCarId(engine) == itemCarId then return true end
	return CarUtils.FindCarById(itemCarId) == nil
end

return CarUtils
