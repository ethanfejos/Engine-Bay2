--!strict
--[[
    Npc (ModuleScript, server)
    --------------------------
    Builds the standing NPCs: Tony the landlord and the customers.

        local rig = Npc.Spawn("Mere", standAt, friendUserId)

    - standAt: a CFrame on the ground where the NPC stands, facing its
      LookVector (only its position and yaw are used).
    - avatarUserId: whose Roblox avatar to wear (a friend of the player, for
      customers). nil, or if it can't be loaded: a plain default avatar.
    The NPC is anchored in place and parented to Workspace.NPCs. Roblox shows
    `name` above its head.

    Also: Npc.GetFriends(player) — the player's Roblox friends ({ id,
    name }), fetched once per player and cached. Empty if it fails (e.g.
    Studio test players).
]]

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Npc = {}

local MAX_FRIENDS = 200

local npcFolder = Workspace:FindFirstChild("NPCs")
if not npcFolder then
	local folder  = Instance.new("Folder")
	folder.Name   = "NPCs"
	folder.Parent = Workspace
	npcFolder     = folder
end

-- ── Avatars ───────────────────────────────────────────────────────────────────

local function getDescription(userId: number?): HumanoidDescription
	if userId and userId > 0 then
		local ok, desc = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(userId)
		end)
		if ok and desc then return desc end
	end
	return Instance.new("HumanoidDescription")
end

function Npc.Spawn(name: string, standAt: CFrame, avatarUserId: number?): Model?
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(getDescription(avatarUserId), Enum.HumanoidRigType.R15)
	end)
	if not ok or not rig then
		warn("[Npc] Couldn't build", name, rig)
		return nil
	end
	rig.Name = name

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	local root = rig:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") then
		root.Anchored = true
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
		local look = standAt.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 0.01 then flat = Vector3.zAxis end
		local at = standAt.Position + Vector3.new(0, humanoid.HipHeight + root.Size.Y / 2, 0)
		rig:PivotTo(CFrame.lookAt(at, at + flat.Unit))
	end
	rig.Parent = npcFolder
	return rig
end

-- ── Friends ───────────────────────────────────────────────────────────────────

export type Friend = { id: number, name: string }

local friendCache: { [number]: { Friend } } = {}

function Npc.GetFriends(player: Player): { Friend }
	local cached = friendCache[player.UserId]
	if cached then return cached end

	local friends: { Friend } = {}
	local ok, err = pcall(function()
		local pages = Players:GetFriendsAsync(player.UserId)
		while #friends < MAX_FRIENDS do
			for _, entry in ipairs(pages:GetCurrentPage()) do
				local id = entry.Id
				if type(id) == "number" then
					local display = entry.DisplayName or entry.Username
					table.insert(friends, { id = id, name = if type(display) == "string" then display else "Customer" })
				end
			end
			if pages.IsFinished then break end
			pages:AdvanceToNextPageAsync()
		end
	end)
	if not ok then
		warn("[Npc] Couldn't load friends for", player.Name, err)
	end
	friendCache[player.UserId] = friends
	return friends
end

Players.PlayerRemoving:Connect(function(player)
	friendCache[player.UserId] = nil
end)

return Npc
