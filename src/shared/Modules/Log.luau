--!strict
--[[
    Log (ModuleScript, shared)
    --------------------------
    One way to write to Output, with each line tagged by the script it came
    from:

        local log = Log.new("MoneyService")
        log.debug("Alex +$50 (repair)")   -- only when debug logs are on
        log.info("Server started")         -- always
        log.warn("Profile failed to load") -- always, as a warning

    Debug logs are OFF by default, so Output stays readable with several
    players. To turn them on while testing, either:
    - tick the "DebugLogs" attribute on ReplicatedStorage (works live, in
      Studio or a running server — set it on the server and every client
      sees it too), or
    - set DEBUG_DEFAULT to true below.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DEBUG_DEFAULT = false

export type Logger = {
	debug: (...any) -> (),
	info:  (...any) -> (),
	warn:  (...any) -> (),
}

local Log = {}

function Log.IsDebugOn(): boolean
	local attr = ReplicatedStorage:GetAttribute("DebugLogs")
	if type(attr) == "boolean" then
		return attr
	end
	return DEBUG_DEFAULT
end

function Log.new(tag: string): Logger
	local prefix = "[" .. tag .. "]"
	return {
		debug = function(...: any)
			if Log.IsDebugOn() then
				print(prefix, ...)
			end
		end,
		info = function(...: any)
			print(prefix, ...)
		end,
		warn = function(...: any)
			warn(prefix, ...)
		end,
	}
end

return Log
