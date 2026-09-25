--[[
    CharacterManager (ModuleScript)
    --------------------------------
    What it is: Character visibility and mobility controller for engine view.

    Fixes in this version:

    [CRITICAL]
    1. Saves and restores Transparency instead of LocalTransparencyModifier.
       LocalTransparencyModifier is written to by the engine (camera occlusion,
       LOD, first-person) and is not a stable value to save. Over a long session
       it will be stale by the time Show restores it, leaving parts visually broken.

    [EDGE CASE]
    2. Players.LocalPlayer no longer fetched at module load time. Fetched lazily
       inside ensureCleanupConnected() on first Hide call, so an early require()
       before the player exists doesn't silently break the cleanup connection.

    [MEMORY — important for long sessions]
    3. savedState top-level table is now weak-keyed (__mode = "k"). If a character
       is destroyed and CharacterRemoving lags or fails to fire, the entry
       evaporates via GC rather than pinning the instance. Parts/decals subtables
       are also weak-keyed for the same reason.

    [CORRECTNESS]
    4. UseJumpPower checked before zeroing mobility. Only the active jump property
       is zeroed during Hide and restored during Show.
    5. CanCollide and CanQuery saved and disabled during Hide so the hidden
       character doesn't block raycasts or physics during engine view.
       CanTouch is intentionally left alone — zone detection and workshop
       proximity systems rely on Touched events from the character.

    [API]
    6. CharacterManager.IsHidden(char) added. Callers can query current state
       without accessing savedState directly.
]]

local Players = game:GetService("Players")

local CharacterManager = {}

-- Keyed by character instance. Holds saved state between Hide and Show.
-- Weak keys at the top level: if a character is destroyed and
-- CharacterRemoving lags or fails to fire, the entry evaporates via GC
-- rather than pinning the character instance for the rest of the session.
-- Parts/decals subtables are also weak-keyed for the same reason.
local savedState = setmetatable({}, { __mode = "k" })

-- Connected lazily on first Hide call to avoid a module-load-time
-- LocalPlayer fetch that would fail on early require().
local cleanupConnected = false

local function ensureCleanupConnected()
	if cleanupConnected then return end
	local player = Players.LocalPlayer
	if not player then
		warn("[CharacterManager] LocalPlayer not available — CharacterRemoving cleanup not connected")
		return
	end
	player.CharacterRemoving:Connect(function(char)
		savedState[char] = nil
	end)
	cleanupConnected = true
end

local function getHumanoid(char)
	return char:FindFirstChildOfClass("Humanoid")
end

function CharacterManager.Hide(char)
	if not char then return end
	if savedState[char] then return end  -- double-hide guard

	ensureCleanupConnected()

	local h = getHumanoid(char)
	local state = {
		parts    = setmetatable({}, { __mode = "k" }),
		decals   = setmetatable({}, { __mode = "k" }),
		humanoid = {},
	}

	if h then
		local useJumpPower = h.UseJumpPower
		state.humanoid = {
			walkSpeed    = h.WalkSpeed,
			useJumpPower = useJumpPower,
			-- Only save the active jump property — the inactive one is irrelevant
			jumpPower    = useJumpPower and h.JumpPower  or nil,
			jumpHeight   = (not useJumpPower) and h.JumpHeight or nil,
		}
		h.WalkSpeed = 0
		if useJumpPower then
			h.JumpPower  = 0
		else
			h.JumpHeight = 0
		end
	end

	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") then
			-- Transparency is the authored value. LocalTransparencyModifier is
			-- written to by the engine (occlusion, LOD) and must not be saved.
			-- CanCollide and CanQuery are disabled so the hidden character doesn't
			-- block raycasts or physics during engine view.
			-- CanTouch is intentionally left alone — zone detection and workshop
			-- proximity systems may rely on Touched events from the character.
			state.parts[part] = {
				transparency = part.Transparency,
				anchored     = part.Anchored,
				canCollide   = part.CanCollide,
				canQuery     = part.CanQuery,
			}
			part.Transparency = 1
			part.Anchored     = true
			part.CanCollide   = false
			part.CanQuery     = false
		elseif part:IsA("Decal") or part:IsA("Texture") then
			state.decals[part] = part.Transparency
			part.Transparency  = 1
		end
	end

	savedState[char] = state
end

function CharacterManager.Show(char)
	if not char then return end
	local state = savedState[char]
	if not state then return end

	local h = getHumanoid(char)
	if h and state.humanoid then
		local hum = state.humanoid
		if hum.walkSpeed ~= nil then h.WalkSpeed = hum.walkSpeed end
		if hum.useJumpPower then
			if hum.jumpPower  ~= nil then h.JumpPower  = hum.jumpPower  end
		else
			if hum.jumpHeight ~= nil then h.JumpHeight = hum.jumpHeight end
		end
	end

	for part, data in pairs(state.parts) do
		if part and part.Parent then
			part.Transparency = data.transparency
			part.Anchored     = data.anchored
			part.CanCollide   = data.canCollide
			part.CanQuery     = data.canQuery
		end
	end

	for decal, origTransp in pairs(state.decals) do
		if decal and decal.Parent then
			decal.Transparency = origTransp
		end
	end

	savedState[char] = nil
end

-- Returns true if Hide has been called for this character and Show has not
-- yet been called. Lets callers query state without accessing savedState.
function CharacterManager.IsHidden(char)
	return char ~= nil and savedState[char] ~= nil
end

return CharacterManager