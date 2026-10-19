--!strict
--[[
    PlayerSettings (ModuleScript, shared)
    -------------------------------------
    The player's own settings (the engine-view settings panel, EngineHelpUI).
    Saved in their profile (profile.Data.settings) by SettingsService, and
    put on the Player as attributes ("Setting_orbitSpeed", ...) so every
    client script can read them:

        PlayerSettings.Get(player, "orbitSpeed") --> 1.25

    Changing one (client): Remotes.SaveSetting:FireServer(key, value).
    Adding one: a line in LIST. Old saves just get its default.
]]

export type Setting = {
	key: string,
	label: string,
	kind: string,       -- "number" (− / + steps) or "toggle"
	default: number | boolean,
	min: number?,       -- number only
	max: number?,
	step: number?,
	unit: string?,      -- how a number shows: "x" (1.25x) or "%" (65%)
}

local PlayerSettings = {}

PlayerSettings.ATTRIBUTE_PREFIX = "Setting_"

PlayerSettings.LIST = {
	-- Camera (engine view)
	{ key = "orbitSpeed", label = "Camera turn speed", kind = "number", default = 1, min = 0.25, max = 2, step = 0.25, unit = "x" },
	{ key = "panSpeed",   label = "Camera move speed", kind = "number", default = 1, min = 0.25, max = 2, step = 0.25, unit = "x" },
	{ key = "zoomSpeed",  label = "Zoom speed",        kind = "number", default = 1, min = 0.25, max = 2, step = 0.25, unit = "x" },
	{ key = "invertY",    label = "Invert up / down",  kind = "toggle", default = false },
	{ key = "skipIntro",  label = "Skip the camera swoop in", kind = "toggle", default = false },
	-- What you see
	{ key = "bodyFade",   label = "Bodywork fade",     kind = "number", default = 65, min = 0, max = 100, step = 5, unit = "%" },
	{ key = "showHelp",   label = "Show the controls bar", kind = "toggle", default = true },
} :: { Setting }

local byKey: { [string]: Setting } = {}
for _, s in ipairs(PlayerSettings.LIST) do byKey[s.key] = s end

function PlayerSettings.Find(key: string): Setting?
	return byKey[key]
end

-- `value` made valid for `key` (clamped, snapped to its step), or nil if
-- the key is unknown or the value is the wrong type.
function PlayerSettings.Clean(key: any, value: any): (number | boolean)?
	local s = type(key) == "string" and byKey[key] or nil
	if not s then return nil end
	if s.kind == "toggle" then
		return if type(value) == "boolean" then value else nil
	end
	if type(value) ~= "number" or value ~= value then return nil end
	local step = s.step or 0.05
	local snapped = math.floor(value / step + 0.5) * step
	return math.clamp(snapped, s.min or 0, s.max or 10)
end

-- The player's current value (their attribute, else the default).
function PlayerSettings.Get(player: Player, key: string): any
	local s = byKey[key]
	local value = player:GetAttribute(PlayerSettings.ATTRIBUTE_PREFIX .. key)
	if s and PlayerSettings.Clean(key, value) ~= nil then return value end
	return if s then s.default else nil
end

return PlayerSettings
