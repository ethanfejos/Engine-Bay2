--!strict
--[[
    LoanUI (LocalScript)
    --------------------
    Tony's loan card (GLASS), shown when you use his "Borrow money" prompt
    while he's Desperate (LoanOffer, server -> client: { amounts, fee, debt },
    or nil to close it).

        ┌──────────────────────────────────┐
        │ TONY'S LOAN                      │
        │ Cash now. You pay back 30% more. │
        │ You owe him $40.                 │
        │ [ $50 · owe $65 ] [ $100 · …   ] │
        │ No thanks                         │
        └──────────────────────────────────┘

    Picking an amount (or No thanks / Q) sends RequestLoan to the server.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players              = game:GetService("Players")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local UITheme = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, FF   = UITheme.Colors, UITheme.Faces

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local screen          = Instance.new("ScreenGui")
screen.Name           = "LoanUI"
screen.ResetOnSpawn   = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Enabled        = false
screen.Parent         = playerGui

local card          = Instance.new("Frame")
card.AnchorPoint    = Vector2.new(0.5, 0.5)
card.Position       = UDim2.fromScale(0.5, 0.5)
card.Size           = UDim2.new(0, 420, 0, 0)
card.AutomaticSize  = Enum.AutomaticSize.Y
card.Parent         = screen
UITheme.Glass(card, UITheme.Radius.Large)
local cardStroke = card:FindFirstChildOfClass("UIStroke")
if cardStroke then cardStroke.Color, cardStroke.Transparency = C.Amber, 0.5 end
UITheme.Pad(card, 18, 20)
UITheme.List(card, 10)

local function line(text: string, font: Font, size: number, color: Color3, order: number): TextLabel
	local l = UITheme.Text(card, text, font, size, color)
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.TextWrapped = true
	l.LayoutOrder = order
	return l
end

line("TONY'S LOAN", FF.Heavy, 20, C.Amber, 1)
local terms = line("", FF.Body, 15, C.GlassText, 2)
local owes  = line("", FF.Mono, 14, C.GlassMuted, 3)

local row                  = Instance.new("Frame")
row.Size                   = UDim2.new(1, 0, 0, 52)
row.BackgroundTransparency = 1
row.LayoutOrder            = 4
row.Parent                 = card
local rowList = UITheme.List(row, 8, true)
rowList.HorizontalFlex = Enum.UIFlexAlignment.Fill

local function button(parent: Instance, text: string, filled: boolean): TextButton
	local b                  = Instance.new("TextButton")
	b.Size                   = UDim2.new(0, 100, 1, 0)
	b.AutoButtonColor        = false
	b.BackgroundColor3       = C.Amber
	b.BackgroundTransparency = if filled then 0 else 1
	b.FontFace               = FF.Bold
	b.TextSize               = 14
	b.TextColor3             = if filled then C.Glass else C.GlassMuted
	b.Text                   = text
	b.Parent                 = parent
	UITheme.Corner(b, UITheme.Radius.Large)
	if not filled then UITheme.Stroke(b, C.GlassMuted, 1, 0.6) end
	return b
end

local noThanks = button(card, "No thanks  [Q]", false)
noThanks.Size = UDim2.new(1, 0, 0, 34)
noThanks.LayoutOrder = 5

local CLOSE_ACTION = "CloseLoan"
local open = false

local function close(amount: number?)
	if not open then return end
	open = false
	screen.Enabled = false
	ContextActionService:UnbindAction(CLOSE_ACTION)
	Remotes.RequestLoan:FireServer(amount)
end

noThanks.MouseButton1Click:Connect(function() close(nil) end)

Remotes.LoanOffer.OnClientEvent:Connect(function(offer: any)
	for _, child in ipairs(row:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	if type(offer) ~= "table" or type(offer.amounts) ~= "table" then
		-- The offer's off (Tony's mood changed).
		open = false
		screen.Enabled = false
		ContextActionService:UnbindAction(CLOSE_ACTION)
		return
	end
	local fee = if type(offer.fee) == "number" then offer.fee else 0.3
	local debt = if type(offer.debt) == "number" then offer.debt else 0
	terms.Text = ("Cash now. You pay him back %d%% more, out of your jobs like any debt."):format(math.floor(fee * 100 + 0.5))
	owes.Text = if debt > 0 then ("You owe him %s already."):format(UITheme.Money(debt)) else "You don't owe him anything. Yet."
	for i, amount in ipairs(offer.amounts) do
		if type(amount) ~= "number" then continue end
		local b = button(row, ("%s\nowe %s"):format(UITheme.Money(amount), UITheme.Money(math.floor(amount * (1 + fee) + 0.5))), true)
		b.LayoutOrder = i
		b.MouseButton1Click:Connect(function() close(amount) end)
	end
	open = true
	screen.Enabled = true
	ContextActionService:BindAction(CLOSE_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then close(nil) end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Q)
end)
