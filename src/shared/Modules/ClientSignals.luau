--!strict
--[[
    ClientSignals (ModuleScript, shared — used on the client only)
    --------------------------------------------------------------
    How the client scripts talk to each other. Replaces the BindableEvents
    that used to be created in ReplicatedStorage at runtime by whichever
    script happened to start first, and waited on by the others.

    Each script requires this module and gets the same signals, so there is
    nothing to create, find or wait for:

        local ClientSignals = require(Shared.Modules.ClientSignals)
        ClientSignals.PartSelected:Connect(function(itemId, name, engineName, relativeData) ... end)
        ClientSignals.PartSelected:Fire(item.id, item.name, item.engineName, item.relativeData)

    Every client script gets the same copy of this module, because all
    LocalScripts on one client share their required modules.
]]

local Signal = require(script.Parent:WaitForChild("Signal"))

export type ClientSignals = {
	-- InventoryUI -> GhostSystem, RepairUI
	-- (itemId?, partName?, engineName?, relativeData?) — all nil = nothing selected
	PartSelected : Signal.Signal,

	-- GhostSystem -> InventoryUI: hide this item straight away, it's being
	-- reinstalled (the server's next InventoryUpdated confirms or restores it)
	-- (itemId)
	ReinstallRequested : Signal.Signal,

	-- WorkbenchCameraController -> RepairUI: entered (true) / left (false) bench view
	WorkbenchViewChanged : Signal.Signal,
}

local ClientSignals: ClientSignals = {
	PartSelected         = Signal.new(),
	ReinstallRequested   = Signal.new(),
	WorkbenchViewChanged = Signal.new(),
}

return ClientSignals
