--!strict
--[[
    ReceiptUI (LocalScript)
    -----------------------
    The receipt that slides up when you hand a customer's car back
    (JobService sends it on JobReceipt) — UI "Option D": paper, spiked on
    Tony's nail, typed on his typewriter, with his red marker on it:

        TONY'S AUTO
        Fri 16 Oct · 8:43 PM · No. A3F2-91C0
        ──────────────────────────────────────
        Mere                    Ford F1 Pickup
        Alternator                         $40
        Fan                                $40
        Subtotal                           $80
        Tony's cut (20%, normal)          -$16
        Tip              mine — T          $12   (crossed out when Tony took it)
        Debt repayment                    -$32   (only while you owe Tony)
        ══════════════════════════════════════
        TOTAL                              $32
        XP                                 +50
        Bay rent (7 min, paid)             $21   (not part of the total)
        Interest on your debt              +$6
        You still owe Tony                 $34   (red marker)
                        [ PAID ]
        No refunds. No questions.

    Lines that would be $0 are left out. Click it to put it away, or it
    goes by itself after SHOW_TIME seconds. It hangs from the top of the
    screen and shrinks to fit above the speech note (never grows).
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local UITheme = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, FF   = UITheme.Colors, UITheme.Faces

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera    = workspace.CurrentCamera

-- ── Config ────────────────────────────────────────────────────────────────────

local WIDTH      = 320
local ROW_H      = 19
local SHOW_TIME  = 12   -- seconds before it goes away by itself
local SLIDE_IN   = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_OUT  = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local STAMP_IN   = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
-- The receipt hangs from the top of the screen and fits in the space above
-- the speech note (BayRentalUI's, NOTE_ROOM px tall from the bottom), so the
-- customer's "cheers" is never hidden behind it.
local TOP_GAP    = 16   -- px below the top bar
local NOTE_ROOM  = 230  -- px kept clear at the bottom for the speech note and hotbar
local SHOWN_POS  = UDim2.new(0.5, 0, 0, TOP_GAP)
local HIDDEN_POS = UDim2.new(0.5, 0, 1.6, 0)

-- ── Formatting ────────────────────────────────────────────────────────────────

local money = UITheme.Money

-- A job id (a GUID) as an invoice number: "A3F2-91C0"
local function invoiceNumber(id: string): string
	local hex = string.upper((string.gsub(id, "[^%x]", "")))
	return string.sub(hex, 1, 4) .. "-" .. string.sub(hex, 5, 8)
end

local function timestamp(unix: number): string
	local ok, text = pcall(function()
		return DateTime.fromUnixTimestamp(unix):FormatLocalTime("ddd D MMM · h:mm A", "en-us")
	end)
	return if ok then text else ""
end

-- ── Building ──────────────────────────────────────────────────────────────────

local screen                 = Instance.new("ScreenGui")
screen.Name                  = "ReceiptUI"
screen.ResetOnSpawn          = false
screen.DisplayOrder          = 10
screen.Parent                = playerGui

local current: Frame? = nil  -- the receipt on screen
local showId = 0

type RowStyle = {
	strong: boolean?,       -- bigger, heavy (TOTAL)
	muted: boolean?,        -- grey (not part of the total)
	valueFace: Font?,
	valueColor: Color3?,
	valueSize: number?,
	height: number?,
}

-- "Label ............ value" on one line. Returns the row frame.
local function row(parent: Instance, labelText: string, value: string, order: number, style: RowStyle?): Frame
	local st: RowStyle = style or {}
	local r                  = Instance.new("Frame")
	r.Size                   = UDim2.new(1, 0, 0, st.height or (if st.strong then 24 else ROW_H))
	r.BackgroundTransparency = 1
	r.LayoutOrder            = order
	r.Parent                 = parent

	local color = if st.muted then C.SheetMuted else C.SheetInk
	local left = UITheme.Text(r, labelText, if st.strong then FF.Heavy else FF.Type,
		if st.strong then 18 else 13, color)
	left.Size = UDim2.new(0.7, 0, 1, 0)
	left.TextTruncate = Enum.TextTruncate.AtEnd

	local right = UITheme.Text(r, value, st.valueFace or (if st.strong then FF.Heavy else FF.Type),
		st.valueSize or (if st.strong then 18 else 13), st.valueColor or color)
	right.AnchorPoint = Vector2.new(1, 0)
	right.Position = UDim2.new(1, 0, 0, 0)
	right.Size = UDim2.new(0.3, 0, 1, 0)
	right.TextXAlignment = Enum.TextXAlignment.Right
	right.RichText = true
	return r
end

-- A line across the receipt: solid ink (thick) or a faint rule.
local function rule(parent: Instance, order: number, thick: boolean?)
	local holder                  = Instance.new("Frame")
	holder.Size                   = UDim2.new(1, 0, 0, if thick then 8 else 7)
	holder.BackgroundTransparency = 1
	holder.LayoutOrder            = order
	holder.Parent                 = parent
	local l                  = Instance.new("Frame")
	l.AnchorPoint            = Vector2.new(0, 0.5)
	l.Position               = UDim2.new(0, 0, 0.5, 0)
	l.Size                   = UDim2.new(1, 0, 0, if thick then 2 else 1)
	l.BackgroundColor3       = if thick then C.SheetInk else C.SheetMuted
	l.BackgroundTransparency = if thick then 0 else 0.4
	l.BorderSizePixel        = 0
	l.Parent                 = holder
end

local function build(data: { [string]: any }): Frame
	local root                  = Instance.new("Frame")
	root.AnchorPoint            = Vector2.new(0.5, 0)
	root.Position               = HIDDEN_POS
	root.Size                   = UDim2.new(0, WIDTH, 0, 0)
	root.AutomaticSize          = Enum.AutomaticSize.Y
	root.BackgroundTransparency = 1
	root.Parent                 = screen

	-- Shrink to fit the room above the speech note (never grow).
	local fit = Instance.new("UIScale")
	fit.Parent = root
	local function refit()
		local unscaled = root.AbsoluteSize.Y / math.max(fit.Scale, 0.01)
		local room = camera.ViewportSize.Y - 58 - TOP_GAP - NOTE_ROOM -- 58: Roblox's top bar
		if unscaled > 0 then
			fit.Scale = math.clamp(room / unscaled, 0.4, 1)
		end
	end
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)

	-- The paper
	local paper                  = Instance.new("Frame")
	paper.Name                   = "Paper"
	paper.Active                 = true
	paper.Size                   = UDim2.new(1, 0, 0, 0)
	paper.AutomaticSize          = Enum.AutomaticSize.Y
	paper.Parent                 = root
	UITheme.Paper(paper, 0)
	local pad = UITheme.Pad(paper, 12, 18)
	pad.PaddingTop = UDim.new(0, 26)
	UITheme.List(paper, 3)

	-- Tony's nail through the top
	local nail                  = Instance.new("Frame")
	nail.AnchorPoint            = Vector2.new(0.5, 0)
	nail.Position               = UDim2.new(0.5, 0, 0, 7)
	nail.Size                   = UDim2.new(0, 14, 0, 14)
	nail.BackgroundColor3       = C.ClipEdge
	nail.ZIndex                 = 3
	nail.Parent                 = root
	UITheme.Corner(nail, UITheme.Radius.Pill)
	UITheme.Stroke(nail, Color3.fromHex("5E646C"), 2)

	local n = 0
	local function nextOrder(): number
		n += 1
		return n
	end

	-- Header
	local head = UITheme.Text(paper, "TONY'S AUTO", FF.Heavy, 18, C.SheetInk)
	head.TextXAlignment = Enum.TextXAlignment.Center
	head.LayoutOrder = nextOrder()
	local stamp = timestamp(tonumber(data.time) or os.time())
	local sub = UITheme.Text(paper, stamp .. "  ·  No. " .. invoiceNumber(tostring(data.invoice or "")),
		FF.Type, 11, C.SheetMuted)
	sub.TextXAlignment = Enum.TextXAlignment.Center
	sub.LayoutOrder = nextOrder()
	rule(paper, nextOrder(), true)

	local who = tostring(data.customerName or "?")
	if type(data.customerType) == "string" and data.customerType ~= "REGULAR" then
		who ..= " (" .. string.lower(data.customerType) .. ")"
	end
	row(paper, who, tostring(data.car or "?"), nextOrder())
	rule(paper, nextOrder())

	-- Work done
	if type(data.lines) == "table" then
		for _, item in ipairs(data.lines) do
			if type(item) == "table" then
				row(paper, tostring(item.label or "?"), money(tonumber(item.amount) or 0), nextOrder())
			end
		end
	end
	rule(paper, nextOrder())

	-- Tony's side
	local subtotal  = tonumber(data.subtotal) or 0
	local tonyCut   = tonumber(data.tonyCut) or 0
	local tip       = tonumber(data.tip) or 0
	local repayment = tonumber(data.repayment) or 0
	row(paper, "Subtotal", money(subtotal), nextOrder())
	if tonyCut ~= 0 then
		local pct = tonumber(data.cutPercent)
		local mood = if type(data.mood) == "string" then data.mood else nil
		local label = "Tony's cut"
		if pct and mood then
			label = ("Tony's cut (%d%%, %s)"):format(pct, mood)
		elseif pct then
			label = ("Tony's cut (%d%%)"):format(pct)
		end
		row(paper, label, money(-tonyCut), nextOrder())
	end
	if tip ~= 0 then
		if data.tipStolen == true then
			local r = row(paper, "Tip", "<s>" .. money(tip) .. "</s>", nextOrder())
			local scrawl = UITheme.Text(r, "mine — T", FF.Marker, 15, C.Marker)
			scrawl.AnchorPoint = Vector2.new(0.5, 0.5)
			scrawl.Position = UDim2.new(0.55, 0, 0.5, 0)
			scrawl.Size = UDim2.new(0, 90, 1, 4)
			scrawl.TextXAlignment = Enum.TextXAlignment.Center
			scrawl.Rotation = -8
		else
			row(paper, "Tip", money(tip), nextOrder())
		end
	end
	if repayment ~= 0 then row(paper, "Debt repayment", money(-repayment), nextOrder()) end

	-- Total
	rule(paper, nextOrder(), true)
	row(paper, "TOTAL", money(tonumber(data.total) or 0), nextOrder(), { strong = true })
	local xp = tonumber(data.xp)
	if xp and xp > 0 then
		row(paper, "XP", "+" .. tostring(xp), nextOrder(), { valueColor = C.MarkerGreen })
	end

	-- Not part of the total: rent already paid, interest, the debt.
	local rentAmount  = tonumber(data.rentAmount) or 0
	local rentMinutes = tonumber(data.rentMinutes) or 0
	local interest    = tonumber(data.interest) or 0
	local debtAfter   = tonumber(data.debtAfter) or 0
	if rentAmount ~= 0 then
		row(paper, ("Bay rent (%d min, paid)"):format(rentMinutes), money(rentAmount), nextOrder(), { muted = true })
	end
	if interest ~= 0 then
		row(paper, "Interest on your debt", "+" .. money(interest), nextOrder(), { muted = true })
	end
	if debtAfter > 0 then
		row(paper, "You still owe Tony", money(debtAfter), nextOrder(),
			{ valueFace = FF.Marker, valueColor = C.Marker, valueSize = 24, height = 30 })
	elseif repayment ~= 0 then
		row(paper, "Debt to Tony", "PAID OFF", nextOrder(),
			{ valueFace = FF.Marker, valueColor = C.MarkerGreen, valueSize = 18, height = 26 })
	end

	-- PAID stamp
	local stampHolder                  = Instance.new("Frame")
	stampHolder.Size                   = UDim2.new(1, 0, 0, 56)
	stampHolder.BackgroundTransparency = 1
	stampHolder.LayoutOrder            = nextOrder()
	stampHolder.Parent                 = paper
	local paid = UITheme.Text(stampHolder, "PAID", FF.Stamp, 32, C.Marker)
	paid.AnchorPoint = Vector2.new(0.5, 0.5)
	paid.Position = UDim2.new(0.5, 0, 0.5, 0)
	paid.Size = UDim2.new(0, 0, 0, 40)
	paid.AutomaticSize = Enum.AutomaticSize.X
	paid.TextXAlignment = Enum.TextXAlignment.Center
	paid.TextTransparency = 0.12
	paid.Rotation = -4
	UITheme.Pad(paid, 0, 14)
	UITheme.Stroke(paid, C.Marker, 3, 0.12)
	local paidScale = Instance.new("UIScale")
	paidScale.Scale = 1.8
	paidScale.Parent = paid
	task.delay(SLIDE_IN.Time, function()
		TweenService:Create(paidScale, STAMP_IN, { Scale = 1 }):Play()
	end)

	local foot = UITheme.Text(paper, "No refunds. No questions.", FF.Type, 10, C.SheetMuted)
	foot.TextXAlignment = Enum.TextXAlignment.Center
	foot.LayoutOrder = nextOrder()

	return root
end

-- ── Showing ───────────────────────────────────────────────────────────────────

local function hide(receipt: Frame)
	if current == receipt then current = nil end
	local tween = TweenService:Create(receipt, SLIDE_OUT, { Position = HIDDEN_POS })
	tween.Completed:Connect(function() receipt:Destroy() end)
	tween:Play()
end

Remotes.JobReceipt.OnClientEvent:Connect(function(data: any)
	if type(data) ~= "table" then return end
	local old = current
	if old then hide(old) end

	showId += 1
	local id = showId
	local receipt = build(data)
	current = receipt
	TweenService:Create(receipt, SLIDE_IN, { Position = SHOWN_POS }):Play()

	-- Click anywhere on the paper to put it away. (The paper listens for the
	-- click itself: a full-size button inside it would be laid out as one of
	-- its rows and stretch it.)
	local paper = receipt:FindFirstChild("Paper")
	if paper and paper:IsA("GuiObject") then
		paper.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 and current == receipt then
				hide(receipt)
			end
		end)
	end
	task.delay(SHOW_TIME, function()
		if showId == id and current == receipt then hide(receipt) end
	end)
end)
