--[[
    ProfileManager (ModuleScript)
    -----------------------------
    Thin wrapper around the real ProfileService library (MadStudioRoblox,
    vendored unmodified in ProfileService.luau, same folder).

    This exists so InventoryService and RepairService don't need to change
    how they use profiles — LoadProfile(player) / GetProfile(player) and
    profile.Data still work the same way they did with the old hand-rolled
    ProfileService.luau. What's different underneath:

    - Real session locking via ProfileStore:LoadProfileAsync, instead of
      plain SetAsync/GetAsync. Two servers can no longer silently stomp on
      the same player's save.
    - Automatic retry/backoff on save, handled inside the library.
    - LoadProfile can now return nil (session couldn't be claimed) — the
      old version never did this, so call sites should check for it if
      they load profiles directly instead of going through GetProfile.

    Uses the same DataStore name and "Player_<UserId>" key format as the
    previous ProfileService.luau, so existing saved data still loads.
]]

local Players = game:GetService("Players")

local ProfileService = require(script.Parent:WaitForChild("ProfileService"))

local DATASTORE_NAME = "EngineInventory_v1"

-- Same shape as the old ProfileService.luau's DEFAULT_DATA, plus xp/level
-- tracking and a record of which parts have already paid out inspect XP
-- (so re-inspecting a reinstalled part doesn't farm XP repeatedly).
local PROFILE_TEMPLATE = {
	inventory = {}, -- list of { id, name, wear, engineName, relativeData }
	xp = 0,
	inspectedForXp = {}, -- set of "engineName:partName" -> true
}

local ProfileStore = ProfileService.GetProfileStore(DATASTORE_NAME, PROFILE_TEMPLATE)

local ProfileManager = {}

local profiles = {} -- [player] = Profile

-- Loads (and session-locks) a player's profile. Returns nil if the load
-- failed or the player left before it finished — callers should treat nil
-- as "this player has no working save right now."
function ProfileManager.LoadProfile(player)
	-- "ForceLoad": if a previous session (e.g. this same player on another
	-- server, or a crashed server) still holds the lock, take it over after
	-- one retry cycle instead of refusing to load. Fine for a single-player-
	-- focused game; revisit if that ever causes double-session edge cases.
	local profile = ProfileStore:LoadProfileAsync("Player_" .. player.UserId, "ForceLoad")

	if not profile then
		warn("[ProfileManager] Profile load failed for", player.Name, "- kicking")
		player:Kick("There was a problem loading your data. Please rejoin.")
		return nil
	end

	profile:AddUserId(player.UserId) -- GDPR: associates save data with the user for data requests
	profile:Reconcile() -- fills in any keys missing from an older save (e.g. new fields added later)

	profile:ListenToRelease(function()
		profiles[player] = nil
		-- Only happens if the session lock was taken by another server
		-- while this one still thought it owned it — safest to disconnect
		-- rather than let the player keep playing on stale/unsaved data.
		if player:IsDescendantOf(Players) then
			player:Kick("Your data was loaded on another server. Please rejoin.")
		end
	end)

	if not player:IsDescendantOf(Players) then
		-- Player left while the profile was loading.
		profile:Release()
		return nil
	end

	profiles[player] = profile
	return profile
end

function ProfileManager.GetProfile(player)
	return profiles[player]
end

Players.PlayerRemoving:Connect(function(player)
	local profile = profiles[player]
	if profile then
		profile:Release()
	end
end)

return ProfileManager
