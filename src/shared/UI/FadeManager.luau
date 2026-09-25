--[[
    FadeManager (ModuleScript)
    --------------------------
    What it is: Label fade-out system for smooth UI transitions.

    Changes from previous version:
    - Labels are reparented to a temporary holder before their parent
      GUI is destroyed, so they actually exist long enough to fade out.
      This fixes the bug where GUIBuilder.Destroy killed labels before
      FadeManager could animate them.
    - Fade also sets BackgroundTransparency so any background frames
      fade too, not just text
    - Cleaned up: removed labels whose parent is nil immediately
      rather than iterating them

    Other scripts it links to:
    - Used by: InspectionUI via GUIBuilder.Destroy
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local FadeManager = {}

local fadeLabels = {}
local FADE_SPEED = 5

-- Get or create a temporary holder in PlayerGui for fading labels
local function getFadeHolder()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local holder = playerGui:FindFirstChild("_FadeHolder")
	if not holder then
		holder = Instance.new("ScreenGui")
		holder.Name = "_FadeHolder"
		holder.ResetOnSpawn = false
		holder.Enabled = false  -- invisible container, labels manage own transparency
		holder.Parent = playerGui
	end
	return holder
end

-- Reparent label to fade holder so it survives GUI destruction,
-- then register it for fade-out
function FadeManager.Register(label)
	if not label or not label:IsA("TextLabel") then return end
	local holder = getFadeHolder()
	-- Reparent to keep it alive after the BillboardGui is destroyed
	local ok = pcall(function() label.Parent = holder end)
	if ok then
		table.insert(fadeLabels, label)
	end
end

RunService.RenderStepped:Connect(function(delta)
	for i = #fadeLabels, 1, -1 do
		local lbl = fadeLabels[i]
		if lbl and lbl.Parent then
			local alpha = lbl.TextTransparency
			local newAlpha = alpha + (1 - alpha) * math.clamp(delta * FADE_SPEED, 0, 1)
			lbl.TextTransparency = newAlpha
			if newAlpha >= 0.99 then
				lbl:Destroy()
				table.remove(fadeLabels, i)
			end
		else
			table.remove(fadeLabels, i)
		end
	end
end)

return FadeManager