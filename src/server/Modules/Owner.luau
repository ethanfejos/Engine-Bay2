--!strict
--[[
    Owner (ModuleScript)
    --------------------
    One place that answers "is this player the game's owner?", so every
    owner-only feature (the cheat menu, Clear Inventory, ...) uses the same
    rule instead of each service working it out on its own.

    The owner is the place's creator — or, for a group game, the group's
    owner. An unpublished place (CreatorId 0) has no owner.

    Owner.Is(player)  -> boolean
        Waits for the group lookup the first time (a moment at most), then
        answers instantly.
    Owner.Mark(player)
        Sets the "IsDev" attribute on the owner, which the client reads to
        decide whether to build owner-only UI. The server never trusts that
        attribute — it always asks Owner.Is again.
]]

local GroupService = game:GetService("GroupService")

local Owner = {}

local ownerId: number? = nil
local known = false

task.spawn(function()
	if game.CreatorType == Enum.CreatorType.User then
		ownerId = game.CreatorId
	else
		local ok, info = pcall(function()
			return GroupService:GetGroupInfoAsync(game.CreatorId)
		end)
		if ok and type(info) == "table" and type(info.Owner) == "table" and type(info.Owner.Id) == "number" then
			ownerId = info.Owner.Id
		else
			warn("[Owner] Couldn't look up the group owner — owner-only features are off")
		end
	end
	known = true
end)

function Owner.Is(player: Player): boolean
	while not known do task.wait() end
	return ownerId ~= nil and ownerId > 0 and player.UserId == ownerId
end

function Owner.Mark(player: Player)
	if Owner.Is(player) then player:SetAttribute("IsDev", true) end
end

return Owner
