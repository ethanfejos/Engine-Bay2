--[[
    LevelService (ModuleScript, started by Main)
    --------------------------------------------
    Server-authoritative XP and level tracking. Awards XP for repairing,
    removing, and inspecting parts; saves through ProfileManager the same
    way InventoryService does.

    RemoteEvents used:
    - XpUpdated      (server -> client) fires whenever xp/level changes
    - LeveledUp      (server -> client) fires only on a level-up, for the
                       popup/effect — separate from XpUpdated so the client
                       doesn't have to diff levels itself
    - RequestXp      (client -> server) client asks for current xp/level
                       (e.g. on join), mirrors InventoryService's
                       RequestInventory pattern
    - InspectStart   (client -> server) the InspectionTool started holding
                       on a part; the server notes the time
    - PartInspected  (client -> server) the hold finished. Accepted only if
                       it's the same part and at least the dwell time
                       (PartRules.INSPECT_DWELL_TIME) has passed on the
                       SERVER's clock. Accepted inspections are saved in
                       profile.Data.inspectedForXp, which EngineServer also
                       uses to require inspection before removal.
      (server -> client) (engineName, partName, false) when refused, so
                       the client un-marks the part.
    - InspectedSync  (server -> client) the player's saved inspected parts,
                       sent when their profile loads, so progress survives
                       rejoining.

    Other scripts call LevelService.AddXP(player, amount, reason) directly
    (EngineServer on removal, RepairService on repair completion)
    rather than going through a remote, since those actions are already
    server-authoritative at the point AddXP is called.

    Started by Main.server.luau (see there for the order).
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileManager = require(script.Parent.Parent.Modules.ProfileManager)
local LevelCurve      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("LevelCurve"))
local ZoneUtils       = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("ZoneUtils"))
local PartRules       = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("PartRules"))

-- ── XP Award Amounts ─────────────────────────────────────────────────────────

local XP_AWARDS = {
	remove  = 15,
	repair  = 25,
	inspect = 10,
}

-- ── Remotes ───────────────────────────────────────────────────────────────────

local function getOrCreate(parent, className, name)
	local existing = parent:FindFirstChild(name)
	if existing then return existing end
	local inst  = Instance.new(className)
	inst.Name   = name
	inst.Parent = parent
	return inst
end

local remoteFolder     = getOrCreate(ReplicatedStorage, "Folder", "RemoteEvents")
local xpUpdated        = getOrCreate(remoteFolder, "RemoteEvent", "XpUpdated")
local leveledUp        = getOrCreate(remoteFolder, "RemoteEvent", "LeveledUp")
local requestXp        = getOrCreate(remoteFolder, "RemoteEvent", "RequestXp")
local partInspected    = getOrCreate(remoteFolder, "RemoteEvent", "PartInspected")
local inspectStart     = getOrCreate(remoteFolder, "RemoteEvent", "InspectStart")
local inspectedSync    = getOrCreate(remoteFolder, "RemoteEvent", "InspectedSync")

-- ── Public API ────────────────────────────────────────────────────────────────

local LevelService = {}
LevelService.XP_AWARDS = XP_AWARDS -- exposed so RepairService/EngineServer can reference amounts by name

-- Sends this player's current xp/level/progress to their client. Safe to
-- call any time — does nothing if the profile isn't loaded yet.
local function pushXpToClient(player)
	local profile = ProfileManager.GetProfile(player)
	if not profile then return end

	local level, xpIntoLevel, xpForNextLevel = LevelCurve.GetLevelInfo(profile.Data.xp)
	xpUpdated:FireClient(player, profile.Data.xp, level, xpIntoLevel, xpForNextLevel)
end

-- Awards `amount` XP to a player, saves it, and notifies their client.
-- `reason` is only used for the Output log — purely diagnostic.
function LevelService.AddXP(player, amount, reason)
	local profile = ProfileManager.GetProfile(player)
	if not profile then return end
	if type(amount) ~= "number" or amount <= 0 then return end

	local oldLevel = LevelCurve.GetLevelInfo(profile.Data.xp)
	profile.Data.xp = profile.Data.xp + amount
	local newLevel = LevelCurve.GetLevelInfo(profile.Data.xp)

	print(("[LevelService] %s +%d XP (%s) — total %d"):format(
		player.Name, amount, reason or "?", profile.Data.xp))

	pushXpToClient(player)

	if newLevel > oldLevel then
		leveledUp:FireClient(player, newLevel)
	end
end

-- ── Requests ──────────────────────────────────────────────────────────────────

requestXp.OnServerEvent:Connect(function(player)
	pushXpToClient(player)
end)

-- LevelUI's RequestXp usually arrives before the profile has loaded and gets
-- nothing back, which left the bar at "LEVEL 1" until the first XP gain.
-- Push as soon as the profile is ready instead.
-- Push as soon as the profile is ready instead. The saved inspected parts
-- go out at the same time, so the client's inspection state matches the
-- server's after rejoining.
ProfileManager.OnProfileLoaded(function(player, profile)
	pushXpToClient(player)

	local keys = {}
	for key in pairs(profile.Data.inspectedForXp) do
		table.insert(keys, key)
	end
	inspectedSync:FireClient(player, keys)
end)

-- ── Inspection ────────────────────────────────────────────────────────────────
-- Inspection is timed on the SERVER: InspectStart notes when the hold began,
-- and PartInspected is only accepted once the dwell time has passed. Both
-- remotes are fired by the client, so everything is re-validated here — a
-- client could otherwise claim to have inspected anything, instantly.

-- Small allowance for the two remotes arriving with slightly different
-- network delays. Kept well under the dwell time so it can't be abused.
local TIMING_TOLERANCE = 0.25

-- [player] = { key = "engine:part", at = os.clock() } for the current hold
local inspectStarts = {}

-- The real, inspectable part the client is talking about, in the engine
-- parked in the bay the player is standing in — or nil (with a reason) if
-- the claim doesn't check out.
local function resolvePart(player, engineName, partName)
	if type(engineName) ~= "string" or type(partName) ~= "string" then
		return nil, "bad arguments"
	end
	local engine, zone = ZoneUtils.GetEngineForPlayer(player)
	if not zone then
		return nil, "not in a bay"
	end
	if not engine or engine.Name ~= engineName then
		return nil, "engine mismatch"
	end
	local model = engine:FindFirstChild(partName)
	if not model or not model:IsA("Model") or not PartRules.IsInspectable(model) then
		return nil, "not an inspectable part"
	end
	return model
end

inspectStart.OnServerEvent:Connect(function(player, engineName, partName)
	local model = resolvePart(player, engineName, partName)
	if not model then
		inspectStarts[player] = nil
		return
	end
	inspectStarts[player] = {
		key = PartRules.InspectKey(engineName, partName),
		at  = os.clock(),
	}
end)

partInspected.OnServerEvent:Connect(function(player, engineName, partName)
	local function refuse(reason)
		warn("[LevelService] Inspection refused for", player.Name, "-", reason)
		if type(engineName) == "string" and type(partName) == "string" then
			partInspected:FireClient(player, engineName, partName, false)
		end
	end

	local profile = ProfileManager.GetProfile(player)
	if not profile then return refuse("save not loaded") end

	local model, why = resolvePart(player, engineName, partName)
	if not model then return refuse(why) end

	local key   = PartRules.InspectKey(engineName, partName)
	local start = inspectStarts[player]
	inspectStarts[player] = nil

	-- Already inspected (e.g. a reinstalled part): nothing to record or pay.
	if profile.Data.inspectedForXp[key] then return end

	if not start or start.key ~= key then
		return refuse("no matching InspectStart")
	end
	if os.clock() - start.at < PartRules.INSPECT_DWELL_TIME - TIMING_TOLERANCE then
		return refuse("held for less than the dwell time")
	end

	-- Saved, so it survives rejoining, can't be re-farmed after a reinstall,
	-- and lets EngineServer require inspection before removal.
	profile.Data.inspectedForXp[key] = true
	LevelService.AddXP(player, XP_AWARDS.inspect, "inspect")
end)

Players.PlayerRemoving:Connect(function(player)
	inspectStarts[player] = nil
end)

return LevelService
