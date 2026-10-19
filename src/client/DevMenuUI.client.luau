--!strict
--[[
    DevMenuUI (LocalScript)
    -----------------------
    The testing cheat menu (GLASS), for the game's owner only: built only
    when the server has marked this player "IsDev" (DevService), and every
    button is checked again on the server. F2 or the small DEV pill opens it.

    Sections: Money, Reputation, Tony (debt and mood), Testing (customer now,
    inspection, strikes, ban, XP). The last result shows at the bottom.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local UITheme = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, FF   = UITheme.Colors, UITheme.Faces

local player = Players.LocalPlayer

local TOGGLE_KEY = Enum.KeyCode.F2
local MOODS = { "good", "normal", "grumpy", "furious", "desperate" } -- TonyService moods

-- Only the owner: wait for the server's mark (it never comes for anyone else).
if player:GetAttribute("IsDev") ~= true then
	player:GetAttributeChangedSignal("IsDev"):Wait()
end
if player:GetAttribute("IsDev") ~= true then return end

-- ── Screen ────────────────────────────────────────────────────────────────────

local screen          = Instance.new("ScreenGui")
screen.Name           = "DevMenuUI"
screen.ResetOnSpawn   = false
screen.DisplayOrder   = 50
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent         = player:WaitForChild("PlayerGui")

local pill                  = Instance.new("TextButton")
pill.AnchorPoint            = Vector2.new(0, 1)
pill.Position               = UDim2.new(0, 12, 1, -12)
pill.Size                   = UDim2.new(0, 0, 0, 26)
pill.AutomaticSize          = Enum.AutomaticSize.X
pill.AutoButtonColor        = false
pill.FontFace               = FF.MonoB
pill.TextSize               = 12
pill.TextColor3             = C.Amber
pill.Text                   = "DEV  F2"
pill.Parent                 = screen
UITheme.Glass(pill, UITheme.Radius.Pill)
UITheme.Pad(pill, 0, 10)

local panel                 = Instance.new("Frame")
panel.AnchorPoint           = Vector2.new(0, 1)
panel.Position              = UDim2.new(0, 12, 1, -46)
panel.Size                  = UDim2.new(0, 360, 0, 0)
panel.AutomaticSize         = Enum.AutomaticSize.Y
panel.Visible               = false
panel.Parent                = screen
UITheme.Glass(panel, UDim.new(0, 14))
local stroke = panel:FindFirstChildOfClass("UIStroke")
if stroke then stroke.Color, stroke.Transparency = C.Amber, 0.5 end
UITheme.Pad(panel, 14, 14)
UITheme.List(panel, 10)

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

local title = UITheme.Text(panel, "DEV MENU · owner only", FF.Heavy, 13, C.Amber)
title.LayoutOrder = nextOrder()

local function section(name: string): Frame
	local label = UITheme.Text(panel, string.upper(name), FF.Heavy, 11, C.GlassMuted)
	label.LayoutOrder = nextOrder()
	local row                  = Instance.new("Frame")
	row.Size                   = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize          = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	row.LayoutOrder            = nextOrder()
	row.Parent                 = panel
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0, 104, 0, 30)
	grid.CellPadding = UDim2.new(0, 6, 0, 6)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = row
	return row
end

local result = UITheme.Text(panel, "Ready.", FF.Mono, 13, C.GlassText)
result.Size = UDim2.new(1, 0, 0, 0)
result.AutomaticSize = Enum.AutomaticSize.Y
result.TextWrapped = true

local function button(row: Frame, text: string, command: string, value: any, color: Color3?)
	local b                  = Instance.new("TextButton")
	b.AutoButtonColor        = false
	b.BackgroundColor3       = color or Color3.new(1, 1, 1)
	b.BackgroundTransparency = if color then 0.75 else 0.9
	b.FontFace               = FF.Bold
	b.TextSize               = 13
	b.TextColor3             = C.GlassText
	b.Text                   = text
	b.LayoutOrder            = #row:GetChildren()
	b.Parent                 = row
	UITheme.Corner(b, UDim.new(0, 8))
	b.MouseButton1Click:Connect(function()
		result.Text = "…"
		Remotes.DevCommand:FireServer(command, value)
	end)
end

local money = section("Money")
button(money, "-$1,000", "money", -1000, C.Bad)
button(money, "-$100", "money", -100, C.Bad)
button(money, "+$100", "money", 100, C.Done)
button(money, "+$1,000", "money", 1000, C.Done)
button(money, "+$10,000", "money", 10000, C.Done)
button(money, "Set $0", "setMoney", 0)

local stars = section("Reputation")
button(stars, "-1 ★", "stars", -1, C.Bad)
button(stars, "-0.25 ★", "stars", -0.25, C.Bad)
button(stars, "+0.25 ★", "stars", 0.25, C.Done)
button(stars, "+1 ★", "stars", 1, C.Done)
button(stars, "Set 0 ★", "setStars", 0)
button(stars, "Set 5 ★", "setStars", 5)

local tony = section("Tony")
button(tony, "Debt +$50", "debt", 50, C.Bad)
button(tony, "Debt +$200", "debt", 200, C.Bad)
button(tony, "Clear debt", "clearDebt", nil, C.Done)
for _, id in ipairs(MOODS) do
	button(tony, "Mood: " .. id, "mood", id, C.Amber)
end

local testing = section("Testing")
button(testing, "Customer now", "customer", nil, C.Customer)
button(testing, "Inspect in 10s", "inspect", nil, C.Amber)
button(testing, "Clear strikes", "strikes", nil)
button(testing, "Lift ban", "unban", nil)
button(testing, "+500 XP", "xp", 500, C.Done)

result.LayoutOrder = nextOrder()

-- ── Open / close ──────────────────────────────────────────────────────────────

local function toggle()
	panel.Visible = not panel.Visible
end
pill.MouseButton1Click:Connect(toggle)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == TOGGLE_KEY then toggle() end
end)

Remotes.DevCommand.OnClientEvent:Connect(function(text: any)
	if type(text) == "string" then result.Text = text end
end)
