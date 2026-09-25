-- ProfileService by loleris
-- https://github.com/MadStudioRoblox/ProfileService
-- Simplified version for engine inventory system
-- Place in: ServerScriptService/Modules/ProfileService

local ProfileService = {}

local DataStoreService = game:GetService("DataStoreService")
local RunService       = game:GetService("RunService")
local Players          = game:GetService("Players")

local DATASTORE_NAME = "EngineInventory_v1"
local AUTO_SAVE_INTERVAL = 60 -- seconds

local gameStore  = DataStoreService:GetDataStore(DATASTORE_NAME)
local profiles   = {} -- [player] = profile
local isShutdown = false

-- ── Profile ───────────────────────────────────────────────────────────────────

local Profile = {}
Profile.__index = Profile

function Profile.new(player, data)
	return setmetatable({
		Player    = player,
		Data      = data,
		_loaded   = true,
		_released = false,
	}, Profile)
end

function Profile:IsActive()
	return self._loaded and not self._released
end

function Profile:Save()
	if self._released then return end
	local key = "Player_" .. self.Player.UserId
	local success, err = pcall(function()
		gameStore:SetAsync(key, self.Data)
	end)
	if not success then
		warn("[ProfileService] Failed to save for", self.Player.Name, ":", err)
	end
end

function Profile:Release()
	if self._released then return end
	self:Save()
	self._released = true
	profiles[self.Player] = nil
end

-- ── Load ──────────────────────────────────────────────────────────────────────

local DEFAULT_DATA = {
	inventory = {} -- list of { name, wear, engineName }
}

local function deepCopy(t)
	local copy = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			copy[k] = deepCopy(v)
		else
			copy[k] = v
		end
	end
	return copy
end

function ProfileService.LoadProfile(player)
	local key = "Player_" .. player.UserId
	local data

	local success, result = pcall(function()
		return gameStore:GetAsync(key)
	end)

	if success then
		data = result or deepCopy(DEFAULT_DATA)
	else
		warn("[ProfileService] Failed to load for", player.Name, ":", result)
		data = deepCopy(DEFAULT_DATA)
	end

	-- Ensure all expected keys exist
	for k, v in pairs(DEFAULT_DATA) do
		if data[k] == nil then
			if type(v) == "table" then
				data[k] = deepCopy(v)
			else
				data[k] = v
			end
		end
	end

	local profile = Profile.new(player, data)
	profiles[player] = profile
	return profile
end

function ProfileService.GetProfile(player)
	return profiles[player]
end

-- ── Auto Save ─────────────────────────────────────────────────────────────────

task.spawn(function()
	while not isShutdown do
		task.wait(AUTO_SAVE_INTERVAL)
		for player, profile in pairs(profiles) do
			if profile:IsActive() then
				profile:Save()
			end
		end
	end
end)

-- ── Shutdown save ─────────────────────────────────────────────────────────────

game:BindToClose(function()
	isShutdown = true
	for player, profile in pairs(profiles) do
		if profile:IsActive() then
			profile:Save()
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local profile = profiles[player]
	if profile then
		profile:Release()
	end
end)

return ProfileService