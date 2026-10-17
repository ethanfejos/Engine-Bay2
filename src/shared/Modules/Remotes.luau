--!strict
--[[
    Remotes (ModuleScript, shared)
    ------------------------------
    Every RemoteEvent in the game, listed in one place.

        local Remotes = require(Shared.Modules.Remotes)
        Remotes.InventoryUpdated:FireClient(player, inventory)   -- server
        Remotes.InventoryUpdated.OnClientEvent:Connect(...)      -- client

    - Server: the first require creates ReplicatedStorage.RemoteEvents and
      every remote in it (Main requires this before any service starts).
      Remotes that already exist in the place file are reused, not doubled.
    - Client: the first require waits until every remote has replicated.
    - A misspelt name errors straight away ("no remote called ..."), and the
      type checker flags it before you press Play, instead of a
      WaitForChild that hangs forever.

    The folder and the names are unchanged from before this module, so
    scripts that still look them up by hand (the Wrench and InspectionTool
    scripts in the place file) keep working.

    Adding a remote: add its name to the list AND to the Remotes type below.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local FOLDER_NAME = "RemoteEvents"

export type Remotes = {
	-- Inventory (InventoryService)
	InventoryUpdated : RemoteEvent, -- server -> client: inventory list
	RequestInventory : RemoteEvent, -- client -> server
	ReinstallPart    : RemoteEvent, -- client -> server: itemId; server -> client: status, detail
	PartReinstalled  : RemoteEvent, -- server -> client: the reinstalled model
	ClearInventory   : RemoteEvent, -- client -> server (testing tool)

	-- XP and inspection (LevelService)
	XpUpdated        : RemoteEvent, -- server -> client
	LeveledUp        : RemoteEvent, -- server -> client
	RequestXp        : RemoteEvent, -- client -> server
	InspectStart     : RemoteEvent, -- client -> server
	PartInspected    : RemoteEvent, -- both ways
	InspectedSync    : RemoteEvent, -- server -> client: a spawned car's inspected keys (CarService)

	-- Money (MoneyService)
	MoneyUpdated     : RemoteEvent, -- server -> client
	RequestMoney     : RemoteEvent, -- client -> server

	-- Removing parts (EngineServer)
	RemovePart       : RemoteEvent, -- client -> server
	PartRemoving     : RemoteEvent, -- server -> client: play the removal effect

	-- NPCs talking to you (BayRentalService's landlord, JobService's customers)
	NpcSpeech        : RemoteEvent, -- server -> client: (speaker name, text, info?) — info: { kind = "tony"|"customer", userId?, mood?, moodLabel?, car? }

	-- Customer jobs (JobService)
	JobUpdated       : RemoteEvent, -- server -> client: the work order (or nil: no job)
	CancelJob        : RemoteEvent, -- client -> server
	JobReceipt       : RemoteEvent, -- server -> client: the receipt for a finished job
	JobQueue         : RemoteEvent, -- server -> client: customers waiting outside (the job board)
	TakeJob          : RemoteEvent, -- client -> server: jobId — take that customer from the queue
	SetExtras        : RemoteEvent, -- client -> server: { extraId } ticked on the work order (Upsell)

	-- Tony and your bay (TonyService, BayRentalService)
	TonyStatus       : RemoteEvent, -- server -> client: { debt, mood, rent }
	ReleaseBay       : RemoteEvent, -- client -> server: hand back the keys
	LoanOffer        : RemoteEvent, -- server -> client: Tony's loan terms (Desperate mood)
	RequestLoan      : RemoteEvent, -- client -> server: amount to borrow

	-- Workbench (RepairService)
	StartRepair      : RemoteEvent, -- client -> server: itemId
	CancelRepair     : RemoteEvent, -- client -> server
	ReplacePart      : RemoteEvent, -- client -> server: itemId
	RepairProgress   : RemoteEvent, -- server -> client: itemId, 0–1 (-1 = stopped)
	RepairComplete   : RemoteEvent, -- server -> client
	RepairRefused    : RemoteEvent, -- server -> client: itemId, message
}

local NAMES = {
	"InventoryUpdated", "RequestInventory", "ReinstallPart", "PartReinstalled", "ClearInventory",
	"XpUpdated", "LeveledUp", "RequestXp", "InspectStart", "PartInspected", "InspectedSync",
	"MoneyUpdated", "RequestMoney",
	"RemovePart", "PartRemoving",
	"NpcSpeech", "JobUpdated", "CancelJob", "JobReceipt", "JobQueue", "TakeJob", "SetExtras",
	"TonyStatus", "ReleaseBay", "LoanOffer", "RequestLoan",
	"StartRepair", "CancelRepair", "ReplacePart", "RepairProgress", "RepairComplete", "RepairRefused",
}

local remotes: { [string]: RemoteEvent } = {}

if RunService:IsServer() then
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder        = Instance.new("Folder")
		folder.Name   = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	assert(folder)

	for _, name in ipairs(NAMES) do
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteEvent") then
			remotes[name] = existing
		else
			local remote  = Instance.new("RemoteEvent")
			remote.Name   = name
			remote.Parent = folder
			remotes[name] = remote
		end
	end
else
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	for _, name in ipairs(NAMES) do
		remotes[name] = folder:WaitForChild(name) :: RemoteEvent
	end
end

-- Misspelt names fail loudly instead of returning nil.
setmetatable(remotes, {
	__index = function(_, name)
		error(("[Remotes] no remote called %q — add it to Remotes.luau"):format(tostring(name)), 2)
	end,
})

return (remotes :: any) :: Remotes
