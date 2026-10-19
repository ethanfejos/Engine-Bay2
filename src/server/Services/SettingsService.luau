--!strict
--[[
    SettingsService (ModuleScript, started by Main)
    -----------------------------------------------
    Saves the player's own settings (PlayerSettings) in their profile and
    puts them on the Player as attributes ("Setting_<key>") for the client.

    SaveSetting (client -> server): key, value — checked and cleaned by
    PlayerSettings.Clean; anything invalid is ignored.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared         = ReplicatedStorage:WaitForChild("Shared")
local Remotes        = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local PlayerSettings = require(Shared:WaitForChild("Config"):WaitForChild("PlayerSettings"))
local ProfileManager = require(script.Parent.Parent.Modules.ProfileManager)

local SettingsService = {}

local function attributeName(key: string): string
	return PlayerSettings.ATTRIBUTE_PREFIX .. key
end

ProfileManager.OnProfileLoaded(function(player)
	local profile = ProfileManager.GetProfile(player)
	if not profile then return end
	for _, s in ipairs(PlayerSettings.LIST) do
		local saved = profile.Data.settings[s.key]
		player:SetAttribute(attributeName(s.key), if saved ~= nil then saved else s.default)
	end
end)

Remotes.SaveSetting.OnServerEvent:Connect(function(player, key: any, value: any)
	local clean = PlayerSettings.Clean(key, value)
	local profile = ProfileManager.GetProfile(player)
	if clean == nil or not profile then return end
	profile.Data.settings[key] = clean
	player:SetAttribute(attributeName(key), clean)
end)

return SettingsService
