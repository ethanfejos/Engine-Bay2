--[[
    LevelService (Script)
    ----------------------
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
    - PartInspected  (client -> server) fired once by InspectionUI the
                       moment a part is newly marked inspected. Validated
                       server-side before any XP is granted — see the
                       handler below for what "validated" means.

    Other scripts call LevelService.AddXP(player, amount, reason) directly
    (EngineServer.legacy on removal, RepairService on repair completion)
    rather than going through a remote, since those actions are already
    server-authoritative at the point AddXP is called.

    Place in: ServerScriptService/Services
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileManager = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("ProfileManager"))
local LevelCurve      = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("LevelCurve"))
local ToolRegistry    = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolRegistry"))

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

-- ── Inspect Award ─────────────────────────────────────────────────────────────
-- InspectionUI fires this once, client-side, the moment a part is newly
-- marked inspected. Everything here exists to stop that being trusted
-- blindly — a client could otherwise fire this remote directly (e.g. via
-- a script executor) for parts it never actually looked at.

local function getZoneForPlayer(player)
	local hrp = player.Character
		and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	local zonesFolder = workspace:FindFirstChild("EngineZones")
	if not zonesFolder then return nil end

	for _, zone in ipairs(zonesFolder:GetChildren()) do
		if not zone:IsA("BasePart") then continue end
		local zoneId = zone:GetAttribute("ZoneId")
		if not zoneId then continue end
		local localPos = zone.CFrame:PointToObjectSpace(hrp.Position)
		local half      = zone.Size / 2
		if  math.abs(localPos.X) <= half.X
			and math.abs(localPos.Y) <= half.Y
			and math.abs(localPos.Z) <= half.Z then
			return zoneId
		end
	end
	return nil
end

partInspected.OnServerEvent:Connect(function(player, engineName, partName)
	if type(engineName) ~= "string" or type(partName) ~= "string" then return end

	local profile = ProfileManager.GetProfile(player)
	if not profile then return end

	-- Must actually be standing in a zone whose engine matches the one claimed.
	local zoneId = getZoneForPlayer(player)
	if not zoneId then
		warn("[LevelService] Inspect XP claim with no zone from:", player.Name)
		return
	end

	local engine = ToolRegistry.GetEngineInstance(zoneId)
	if not engine or engine.Name ~= engineName then
		warn("[LevelService] Inspect XP claim engine mismatch from:", player.Name)
		return
	end

	-- The part has to actually exist, in that engine, and be a real
	-- inspectable model — not just any string the client feels like sending.
	local model = engine:FindFirstChild(partName)
	if not model or not model:IsA("Model") or not model:GetAttribute("Inspectable") then
		warn("[LevelService] Inspect XP claim on invalid part from:", player.Name)
		return
	end

	-- Only pay out once per part, ever, per player — persisted so it
	-- survives rejoin and can't be farmed by re-inspecting after reinstall.
	local key = engineName .. ":" .. partName
	if profile.Data.inspectedForXp[key] then return end
	profile.Data.inspectedForXp[key] = true

	LevelService.AddXP(player, XP_AWARDS.inspect, "inspect")
end)

return LevelService
