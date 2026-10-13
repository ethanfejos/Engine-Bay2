--[[
    MoneyServiceRunner (Script)
    ----------------------------
    Runs MoneyService on the server.
    Place in: ServerScriptService/Services
]]
local ServerScriptService = game:GetService("ServerScriptService")
require(ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("MoneyService"))
