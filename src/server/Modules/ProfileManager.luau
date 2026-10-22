--!strict
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

    Every load runs SaveData's migrations, ProfileService's Reconcile, and
    SaveData's repair step (bad entries fixed or dropped, parts left on the
    floor by a crashed server recovered) — see SaveData.
]]

local Players = game:GetService("Players")
local ProfileService = require(script.Parent:WaitForChild("ProfileService"))
local SaveData       = require(script.Parent:WaitForChild("SaveData"))

local DATASTORE_NAME = "EngineInventory_v1"

-- The save's shape, migrations and repair rules live in SaveData.
local PROFILE_TEMPLATE = SaveData.TEMPLATE

local ProfileStore = ProfileService.GetProfileStore(DATASTORE_NAME, PROFILE_TEMPLATE)

-- The parts of a ProfileService profile this game uses. (ProfileService
-- itself is vendored unmodified, so it has no types of its own.)
export type Profile = {
	Data: SaveData.Data,
	AddUserId: (self: Profile, userId: number) -> (),
	Reconcile: (self: Profile) -> (),
	ListenToRelease: (self: Profile, listener: () -> ()) -> any,
	Release: (self: Profile) -> (),
}

type ProfileCallback = (player: Player, profile: Profile) -> ()

local ProfileManager = {}

local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean }  = {} -- true while LoadProfileAsync is in flight

-- Callbacks run once per player, right after their profile has loaded —
-- the moment to push initial state (XP, money, inventory) to the client.
-- A client's own RequestXp/RequestMoney on join usually arrives BEFORE the
-- DataStore load finishes and gets nothing back, so this is what actually
-- fills in the HUD. RemoteEvents fired before the client's LocalScript
-- connects are queued by Roblox, so firing here is safe.
-- callback(player, profile) — profile is guaranteed non-nil.
local loadedCallbacks: { ProfileCallback } = {}

local function runLoadedCallback(callback: ProfileCallback, player: Player, profile: Profile)
	local ok, err = pcall(function() callback(player, profile) end)
	if not ok then
		warn("[ProfileManager] OnProfileLoaded callback errored:", err)
	end
end

-- Registers a callback for every profile that loads from now on, AND runs
-- it straight away for any profile that already loaded before this call —
-- so a service that happens to start late still pushes for everyone.
function ProfileManager.OnProfileLoaded(callback: ProfileCallback)
	table.insert(loadedCallbacks, callback)
	for player, profile in pairs(profiles) do
		task.spawn(function() runLoadedCallback(callback, player, profile) end)
	end
end

-- Loads (and session-locks) a player's profile. Returns nil if the load
-- failed or the player left before it finished — callers should treat nil
-- as "this player has no working save right now."
-- Called automatically for every player (see PlayerAdded at the bottom);
-- other scripts only need GetProfile.
function ProfileManager.LoadProfile(player: Player): Profile?
	if profiles[player] then return profiles[player] end
	if loading[player] then return nil end -- already in flight
	loading[player] = true

	local profile = ProfileManager._loadProfile(player)

	loading[player] = nil
	if profile then
		for _, callback in ipairs(loadedCallbacks) do
			task.spawn(function() runLoadedCallback(callback, player, profile) end)
		end
	end
	return profile
end

function ProfileManager._loadProfile(player: Player): Profile?
	-- "ForceLoad": if a previous session (e.g. this same player on another
	-- server, or a crashed server) still holds the lock, take it over after
	-- one retry cycle instead of refusing to load. Fine for a single-player-
	-- focused game; revisit if that ever causes double-session edge cases.
	local profile: Profile? = ProfileStore:LoadProfileAsync("Player_" .. player.UserId, "ForceLoad")

	if not profile then
		warn("[ProfileManager] Profile load failed for", player.Name, "- kicking")
		player:Kick("There was a problem loading your data. Please rejoin.")
		return nil
	end

	profile:AddUserId(player.UserId) -- GDPR: associates save data with the user for data requests

	-- Bring the save up to date, in this order (see SaveData):
	-- migrations BEFORE Reconcile, or Reconcile would stamp an old save
	-- with the current version and its migrations would never run.
	local migrated = SaveData.Migrate(profile.Data)
	profile:Reconcile() -- adds any fields the save is missing
	local notes = SaveData.Sanitize(profile.Data)
	if migrated > 0 or #notes > 0 then
		warn(("[ProfileManager] %s: ran %d migration(s); %s"):format(
			player.Name, migrated, #notes > 0 and table.concat(notes, "; ") or "no repairs"))
	end

	profile:ListenToRelease(function()
		-- releasePlayer (leaving or shutdown) clears the entry BEFORE it
		-- releases, so a release we asked for ends here.
		if profiles[player] ~= profile then return end
		profiles[player] = nil
		-- Otherwise the session lock was taken by another server while this
		-- one still thought it owned it — safest to disconnect rather than
		-- let the player keep playing on stale/unsaved data.
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

function ProfileManager.GetProfile(player: Player): Profile?
	return profiles[player]
end

-- Callbacks registered here run synchronously, in registration order, right
-- before a leaving player's profile is released — the one guaranteed-safe
-- place to write last-second state into profile.Data. Relying on a second,
-- separate Players.PlayerRemoving connection elsewhere isn't safe for this:
-- connection order between different scripts isn't something to depend on,
-- and if it fired after this file's own release, profile.Data would already
-- be gone. callback(player, profile) — profile is guaranteed non-nil here.
local beforeReleaseCallbacks: { ProfileCallback } = {}

function ProfileManager.OnBeforeRelease(callback: ProfileCallback)
	table.insert(beforeReleaseCallbacks, callback)
end

-- Runs the before-release callbacks and releases (= final save) a player's
-- profile. Safe to call twice for the same player: whichever of leaving or
-- shutting down gets there first does the work, the other finds nothing.
local releasing: { [Player]: boolean } = {}

local function releasePlayer(player: Player)
	local profile = profiles[player]
	if not profile or releasing[player] then return end
	releasing[player] = true
	-- The callbacks may still call GetProfile, so the profile stays listed
	-- until they've all run.
	for _, callback in ipairs(beforeReleaseCallbacks) do
		local ok, err = pcall(function() callback(player, profile) end)
		if not ok then
			warn("[ProfileManager] OnBeforeRelease callback errored:", err)
		end
	end
	profiles[player] = nil
	releasing[player] = nil
	profile:Release()
end

Players.PlayerRemoving:Connect(releasePlayer)

-- Server shutting down (an update, or the last player leaving). PlayerRemoving
-- isn't guaranteed to run before ProfileService's own shutdown save, so the
-- OnBeforeRelease callbacks (jobs, parked cars, parts on the floor) could be
-- skipped and that last bit of progress lost. Doing it here first makes sure
-- it lands in the save. This is registered when ProfileManager is first
-- required (very early in Main), ahead of ProfileService's own handler, and
-- the callbacks don't yield, so they finish before its save runs.
-- ProfileService then waits for the saves to finish before the server closes.
game:BindToClose(function()
	for player in pairs(profiles) do
		releasePlayer(player)
	end
end)

-- ProfileManager owns loading, so no other script has to remember to
-- (InventoryService used to). The loop catches players who joined before
-- this module was first required — common in Studio play-solo.
Players.PlayerAdded:Connect(function(player) ProfileManager.LoadProfile(player) end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function() ProfileManager.LoadProfile(player) end)
end

return ProfileManager
