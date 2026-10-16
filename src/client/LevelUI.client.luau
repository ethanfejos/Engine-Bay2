--!strict
--[[
    LevelUI (LocalScript)
    ---------------------
    The level, XP and money card in the bottom-left corner (UI "Option D":
    glass), plus a level-up banner. Purely a display — LevelService,
    MoneyService and TonyService decide everything; this shows it.

        [LVL 4] ━━━━━━━━━━──────  310/500
        $1,240   Owe Tony $50

    - XpUpdated     (server -> client): the bar and numbers, tweened
    - LeveledUp     (server -> client): the banner + a pulse on the pill
    - MoneyUpdated  (server -> client): the money, with a "+$38" / "−$3"
      that floats up off it when it changes
    - TonyStatus    (server -> client): "Owe Tony $X" while you're in debt
    - The little arrow folds the card down to just the money (and opens it
      again).
    - Fires RequestXp and RequestMoney on join to get current values.
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local UITheme = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, FF   = UITheme.Colors, UITheme.Faces

-- ── Build ─────────────────────────────────────────────────────────────────────

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LevelUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local card = Instance.new("Frame")
card.Name = "LevelCard"
card.AnchorPoint = Vector2.new(0, 1)
card.Position = UDim2.new(0, 20, 1, -20)
card.Size = UDim2.new(0, 270, 0, 0)
card.AutomaticSize = Enum.AutomaticSize.Y
card.Parent = screenGui
UITheme.Glass(card)
UITheme.Pad(card, 12, 14)
UITheme.List(card, 8)

-- Row 1: level pill, bar, numbers
local xpRow = Instance.new("Frame")
xpRow.Size = UDim2.new(1, 0, 0, 20)
xpRow.BackgroundTransparency = 1
xpRow.LayoutOrder = 1
xpRow.Parent = card

local levelPill = UITheme.Text(xpRow, "LVL 1", FF.Heavy, 12, C.Glass)
levelPill.Size = UDim2.new(0, 52, 1, 0)
levelPill.TextXAlignment = Enum.TextXAlignment.Center
levelPill.BackgroundColor3 = C.Done
levelPill.BackgroundTransparency = 0
UITheme.Corner(levelPill, UDim.new(0, 6))

local track = Instance.new("Frame")
track.Position = UDim2.new(0, 60, 0.5, -4)
track.Size = UDim2.new(1, -60 - 72, 0, 8)
track.BackgroundColor3 = Color3.new(1, 1, 1)
track.BackgroundTransparency = 0.92
track.BorderSizePixel = 0
track.Parent = xpRow
UITheme.Corner(track, UITheme.Radius.Pill)

local fill = Instance.new("Frame")
fill.Size = UDim2.new(0, 0, 1, 0)
fill.BackgroundColor3 = C.Done
fill.BorderSizePixel = 0
fill.Parent = track
UITheme.Corner(fill, UITheme.Radius.Pill)

local xpLabel = UITheme.Text(xpRow, "0/100", FF.Mono, 11, C.GlassMuted)
xpLabel.AnchorPoint = Vector2.new(1, 0)
xpLabel.Position = UDim2.new(1, 0, 0, 0)
xpLabel.Size = UDim2.new(0, 66, 1, 0)
xpLabel.TextXAlignment = Enum.TextXAlignment.Right

-- Row 2: money and debt
local moneyRow = Instance.new("Frame")
moneyRow.Size = UDim2.new(1, 0, 0, 26)
moneyRow.BackgroundTransparency = 1
moneyRow.LayoutOrder = 2
moneyRow.Parent = card

local moneyLabel = UITheme.Text(moneyRow, "$0", FF.MonoB, 22, C.Amber)
moneyLabel.Size = UDim2.new(0.55, 0, 1, 0)

local debtLabel = UITheme.Text(moneyRow, "", FF.Bold, 13, C.BadText)
debtLabel.AnchorPoint = Vector2.new(1, 0)
debtLabel.Position = UDim2.new(1, 0, 0, 0)
debtLabel.Position = UDim2.new(1, -28, 0, 0)
debtLabel.Size = UDim2.new(0.45, -28, 1, 0)
debtLabel.TextXAlignment = Enum.TextXAlignment.Right
debtLabel.Visible = false

-- Fold arrow: hides the level row, leaving just the money
local foldBtn = Instance.new("TextButton")
foldBtn.AnchorPoint = Vector2.new(1, 0.5)
foldBtn.Position = UDim2.new(1, 0, 0.5, 0)
foldBtn.Size = UDim2.new(0, 22, 0, 22)
foldBtn.BackgroundColor3 = Color3.new(1, 1, 1)
foldBtn.BackgroundTransparency = 0.92
foldBtn.Font = Enum.Font.GothamBold -- has the ▲▼ arrows
foldBtn.Text = "▼"
foldBtn.TextSize = 10
foldBtn.TextColor3 = C.GlassMuted
foldBtn.Parent = moneyRow
UITheme.Corner(foldBtn, UITheme.Radius.Pill)

local folded = false
foldBtn.MouseButton1Click:Connect(function()
	folded = not folded
	xpRow.Visible = not folded
	foldBtn.Text = if folded then "▲" else "▼"
end)

-- ── Level-up banner ───────────────────────────────────────────────────────────

local popup = UITheme.Text(screenGui, "", FF.Heavy, 40, C.Done)
popup.Name = "LevelUpPopup"
popup.AnchorPoint = Vector2.new(0.5, 0.5)
popup.Position = UDim2.new(0.5, 0, 0.35, 0)
popup.Size = UDim2.new(0, 500, 0, 60)
popup.TextXAlignment = Enum.TextXAlignment.Center
popup.TextTransparency = 1
popup.TextStrokeColor3 = C.Glass
popup.TextStrokeTransparency = 1

local function showLevelUpPopup(newLevel: number)
	popup.Text = "LEVEL UP!  ·  LVL " .. newLevel
	popup.TextTransparency = 1
	popup.TextStrokeTransparency = 1
	popup.Position = UDim2.new(0.5, 0, 0.4, 0)

	local fadeIn = TweenService:Create(popup, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		TextTransparency = 0,
		TextStrokeTransparency = 0.5,
		Position = UDim2.new(0.5, 0, 0.35, 0),
	})
	fadeIn:Play()
	fadeIn.Completed:Wait()
	task.wait(1.2)
	TweenService:Create(popup, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Position = UDim2.new(0.5, 0, 0.3, 0),
	}):Play()
end

local function pulseLevelPill()
	TweenService:Create(levelPill, TweenInfo.new(0.12), { BackgroundColor3 = C.Amber }):Play()
	task.delay(0.12, function()
		TweenService:Create(levelPill, TweenInfo.new(0.4), { BackgroundColor3 = C.Done }):Play()
	end)
end

-- "+$38" / "-$3" floating up off the money.
local function moneyPop(delta: number)
	-- In the money row (which has no layout), starting just over the number.
	local pop = UITheme.Text(moneyRow, (if delta > 0 then "+" else "") .. UITheme.Money(delta), FF.MonoB, 16,
		if delta > 0 then C.Done else C.BadText)
	pop.Position = UDim2.new(0, 0, 0, -6)
	pop.Size = UDim2.new(0, 120, 0, 20)
	pop.ZIndex = 5
	local tween = TweenService:Create(pop, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0, 0, 0, -46),
		TextTransparency = 1,
	})
	tween.Completed:Connect(function() pop:Destroy() end)
	tween:Play()
end

-- ── Events ────────────────────────────────────────────────────────────────────

Remotes.XpUpdated.OnClientEvent:Connect(function(_totalXp: any, level: any, xpIntoLevel: any, xpForNextLevel: any)
	local into, need = tonumber(xpIntoLevel) or 0, tonumber(xpForNextLevel) or 0
	levelPill.Text = "LVL " .. tostring(level)
	xpLabel.Text = ("%d/%d"):format(into, need)
	local progress = if need > 0 then math.clamp(into / need, 0, 1) else 0
	TweenService:Create(fill, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(progress, 0, 1, 0),
	}):Play()
end)

Remotes.LeveledUp.OnClientEvent:Connect(function(newLevel: any)
	pulseLevelPill()
	task.spawn(showLevelUpPopup, tonumber(newLevel) or 0)
end)

local shownMoney: number? = nil
Remotes.MoneyUpdated.OnClientEvent:Connect(function(totalMoney: any)
	local total = tonumber(totalMoney)
	if not total then return end
	if shownMoney and total ~= shownMoney then
		moneyPop(total - shownMoney)
	end
	shownMoney = total
	moneyLabel.Text = UITheme.Money(total)
end)

Remotes.TonyStatus.OnClientEvent:Connect(function(status: any)
	if type(status) ~= "table" then return end
	local debt = tonumber(status.debt) or 0
	debtLabel.Visible = debt > 0
	debtLabel.Text = "Owe Tony " .. UITheme.Money(debt)
end)

-- ── Initial sync ──────────────────────────────────────────────────────────────

Remotes.RequestXp:FireServer()
Remotes.RequestMoney:FireServer()
