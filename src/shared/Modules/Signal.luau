--!strict
--[[
    Signal (ModuleScript, shared)
    -----------------------------
    A minimal event for scripts to talk to each other, instead of
    BindableEvents parked in ServerScriptService or ReplicatedStorage for
    other scripts to WaitForChild on.

        local changed = Signal.new()
        local conn = changed:Connect(function(a, b) ... end)
        changed:Fire(1, 2)
        conn:Disconnect()

    Each handler runs in its own thread, so one handler erroring or yielding
    never stops the others (or the code that fired the signal).

    Used by: ZoneService (server), ClientSignals (client).
]]

type Handler = (...any) -> ()
type Entry = { handler: Handler, connected: boolean }

export type Connection = { Disconnect: () -> () }

export type Signal = {
	_handlers: { Entry },
	Connect: (self: Signal, handler: Handler) -> Connection,
	Fire: (self: Signal, ...any) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
	return (setmetatable({ _handlers = {} }, Signal) :: any) :: Signal
end

function Signal.Connect(self: Signal, handler: Handler): Connection
	local entry: Entry = { handler = handler, connected = true }
	table.insert(self._handlers, entry)

	local handlers = self._handlers
	return {
		Disconnect = function()
			if not entry.connected then return end
			entry.connected = false
			local i = table.find(handlers, entry)
			if i then table.remove(handlers, i) end
		end,
	}
end

function Signal.Fire(self: Signal, ...: any)
	-- Copy first, so a handler that connects/disconnects while this runs
	-- doesn't change who gets this particular call.
	for _, entry in ipairs(table.clone(self._handlers)) do
		if entry.connected then
			task.spawn(entry.handler, ...)
		end
	end
end

return Signal
