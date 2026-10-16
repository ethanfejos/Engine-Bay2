--!strict
--[[
    ReceiptUI (LocalScript)
    -----------------------
    The receipt that slides up when you hand a customer's car back
    (JobService sends it on JobReceipt): Tony's Auto Services, the date and
    time, an invoice number, the customer, the car, you as the mechanic,
    one line per job done, and the totals. Tony's cut and the tip only get
    a line when they're not $0 (they arrive with bay rental phase 2).

    Click it to put it away, or it goes by itself after SHOW_TIME seconds.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local UITheme = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, F    = UITheme.Colors, UITheme.Fonts

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Config ────────────────────────────────────────────────────────────────────

local WIDTH      = 320
local PAD        = 18
local ROW_H      = 18
local TOOTH      = 14   -- size of the torn-edge teeth
local SHOW_TIME  = 10   -- seconds before it goes away by itself
local SLIDE_IN   = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_OUT  = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SHOWN_POS  = UDim2.new(0.5, 0, 0.5, 0)
local HIDDEN_POS = UDim2.new(0.5, 0, 1.6, 0)

-- ── Formatting ────────────────────────────────────────────────────────────────

local function money(n: number): string
	local digits = tostring(math.abs(math.floor(n)))
	local withCommas = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return (if n < 0 then "-$" else "$") .. withCommas
end

-- A job id (a GUID) as an invoice number: "A3F2-91C0-77B1-04DE"
local function invoiceNumber(id: string): string
	local hex = string.upper((string.gsub(id, "[^%x]", "")))
	local groups = {}
	for i = 1, math.min(#hex, 16), 4 do
		table.insert(groups, string.sub(hex, i, i + 3))
	end
	return table.concat(groups, "-")
end

local function timestamp(unix: number): string
	local ok, text = pcall(function()
		return DateTime.fromUnixTimestamp(unix):FormatLocalTime("ddd, MMM D, YYYY  ·  h:mm:ss A", "en-us")
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

local function text(parent: Instance, value: string, size: number, color: Color3, font: Enum.Font,
	xAlign: Enum.TextXAlignment, order: number): TextLabel
	local l                  = Instance.new("TextLabel")
	l.Size                   = UDim2.new(1, 0, 0, size + 4)
	l.BackgroundTransparency = 1
	l.Font                   = font
	l.Text                   = value
	l.TextSize               = size
	l.TextColor3             = color
	l.TextXAlignment         = xAlign
	l.LayoutOrder            = order
	l.Parent                 = parent
	return l
end

-- "Label ............ value" on one line.
local function row(parent: Instance, labelText: string, value: string, order: number, strong: boolean?)
	local r                  = Instance.new("Frame")
	r.Size                   = UDim2.new(1, 0, 0, ROW_H)
	r.BackgroundTransparency = 1
	r.LayoutOrder            = order
	r.Parent                 = parent

	local left = text(r, labelText, if strong then 15 else 13, if strong then C.Ink else C.InkMuted,
		if strong then F.Bold else F.Mono, Enum.TextXAlignment.Left, 0)
	left.Size = UDim2.new(0.6, 0, 1, 0)
	left.TextTruncate = Enum.TextTruncate.AtEnd

	local right = text(r, value, if strong then 15 else 13, C.Ink,
		if strong then F.Bold else F.Mono, Enum.TextXAlignment.Right, 0)
	right.AnchorPoint = Vector2.new(1, 0)
	right.Position    = UDim2.new(1, 0, 0, 0)
	right.Size        = UDim2.new(0.4, 0, 1, 0)
end

-- A dashed line across the receipt.
local function dashes(parent: Instance, order: number)
	local holder                  = Instance.new("Frame")
	holder.Size                   = UDim2.new(1, 0, 0, 12)
	holder.BackgroundTransparency = 1
	holder.ClipsDescendants       = true
	holder.LayoutOrder            = order
	holder.Parent                 = parent
	local l = text(holder, string.rep("- ", 80), 12, C.InkMuted, F.Mono, Enum.TextXAlignment.Left, 0)
	l.Size = UDim2.new(4, 0, 1, 0)
end

local function build(data: { [string]: any }): Frame
	local root                  = Instance.new("Frame")
	root.AnchorPoint            = Vector2.new(0.5, 0.5)
	root.Position               = HIDDEN_POS
	root.Size                   = UDim2.new(0, WIDTH, 0, 0)
	root.AutomaticSize          = Enum.AutomaticSize.Y
	root.BackgroundTransparency = 1
	root.Rotation               = -2 -- a little crooked, like it was just handed over
	root.Parent                 = screen

	local rootLayout     = Instance.new("UIListLayout")
	rootLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rootLayout.Parent    = root

	-- The paper
	local paper                  = Instance.new("Frame")
	paper.Size                   = UDim2.new(1, 0, 0, 0)
	paper.AutomaticSize          = Enum.AutomaticSize.Y
	paper.BackgroundColor3       = C.Paper
	paper.BorderSizePixel        = 0
	paper.LayoutOrder            = 1
	paper.Parent                 = root

	local pad         = Instance.new("UIPadding")
	pad.PaddingTop    = UDim.new(0, PAD)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft   = UDim.new(0, PAD)
	pad.PaddingRight  = UDim.new(0, PAD)
	pad.Parent        = paper

	local list     = Instance.new("UIListLayout")
	list.Padding   = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent    = paper

	local n = 0
	local function nextOrder(): number n += 1 return n end

	-- Header
	text(paper, "TONY'S", 16, C.Ink, F.Bold, Enum.TextXAlignment.Center, nextOrder())
	text(paper, "Auto Services", 13, C.Ink, F.Mono, Enum.TextXAlignment.Center, nextOrder())
	text(paper, timestamp(tonumber(data.time) or os.time()), 12, C.Ink, F.Mono, Enum.TextXAlignment.Center, nextOrder())

	-- Invoice box (the label sits in a gap in the box's top edge)
	local boxHolder                  = Instance.new("Frame")
	boxHolder.Size                   = UDim2.new(1, 0, 0, 62)
	boxHolder.BackgroundTransparency = 1
	boxHolder.LayoutOrder            = nextOrder()
	boxHolder.Parent                 = paper

	local box                  = Instance.new("Frame")
	box.Position               = UDim2.new(0, 0, 0, 8)
	box.Size                   = UDim2.new(1, 0, 1, -8)
	box.BackgroundTransparency = 1
	box.Parent                 = boxHolder
	UITheme.Corner(box, UDim.new(0, 8))
	local stroke     = Instance.new("UIStroke")
	stroke.Color     = C.Ink
	stroke.Thickness = 1.5
	stroke.Parent    = box

	local number = text(box, invoiceNumber(tostring(data.invoice or "")), 18, C.Ink, F.Bold, Enum.TextXAlignment.Center, 0)
	number.Size = UDim2.new(1, 0, 1, 0)

	local tag                  = Instance.new("TextLabel")
	tag.AnchorPoint            = Vector2.new(0.5, 0)
	tag.Position               = UDim2.new(0.5, 0, 0, 0)
	tag.Size                   = UDim2.new(0, 0, 0, 16)
	tag.AutomaticSize          = Enum.AutomaticSize.X
	tag.BackgroundColor3       = C.Paper
	tag.BorderSizePixel        = 0
	tag.Font                   = F.Bold
	tag.Text                   = "  Invoice  "
	tag.TextSize               = 13
	tag.TextColor3             = C.Ink
	tag.Parent                 = boxHolder

	-- Who and what
	dashes(paper, nextOrder())
	row(paper, "Customer", tostring(data.customerName or "?"), nextOrder())
	row(paper, "Vehicle", tostring(data.car or "?"), nextOrder())
	row(paper, "Mechanic", tostring(data.mechanic or player.DisplayName), nextOrder())

	-- Work done
	dashes(paper, nextOrder())
	if type(data.lines) == "table" then
		for _, line in ipairs(data.lines) do
			if type(line) == "table" then
				row(paper, tostring(line.label or "?"), money(tonumber(line.amount) or 0), nextOrder())
			end
		end
	end

	-- Totals
	dashes(paper, nextOrder())
	local subtotal = tonumber(data.subtotal) or 0
	local tonyCut  = tonumber(data.tonyCut) or 0
	local tip      = tonumber(data.tip) or 0
	row(paper, "Subtotal", money(subtotal), nextOrder())
	if tonyCut ~= 0 then row(paper, "Tony's cut", money(-tonyCut), nextOrder()) end
	if tip ~= 0 then row(paper, "Tip", money(tip), nextOrder()) end
	row(paper, "TOTAL", money(tonumber(data.total) or 0), nextOrder(), true)
	local xp = tonumber(data.xp)
	if xp and xp > 0 then
		row(paper, "XP", "+" .. tostring(xp), nextOrder())
	end

	-- Footer stamp
	dashes(paper, nextOrder())
	local stamp = text(paper, "TONY'S", 40, C.Ink, Enum.Font.LuckiestGuy, Enum.TextXAlignment.Center, nextOrder())
	stamp.Size     = UDim2.new(1, 0, 0, 48)
	stamp.Rotation = -4
	text(paper, "No refunds. No questions.", 11, C.InkMuted, F.Mono, Enum.TextXAlignment.Center, nextOrder())

	-- Torn bottom edge: a row of paper-coloured diamonds, half showing.
	local teeth                  = Instance.new("Frame")
	teeth.Size                   = UDim2.new(1, 0, 0, TOOTH * 0.72)
	teeth.BackgroundTransparency = 1
	teeth.ClipsDescendants       = true
	teeth.LayoutOrder            = 2
	teeth.Parent                 = root
	local step = TOOTH * 1.414
	for i = 0, math.ceil(WIDTH / step) do
		local d             = Instance.new("Frame")
		d.AnchorPoint       = Vector2.new(0.5, 0.5)
		d.Position          = UDim2.new(0, i * step + step / 2, 0, 0)
		d.Size              = UDim2.new(0, TOOTH, 0, TOOTH)
		d.Rotation          = 45
		d.BackgroundColor3  = C.Paper
		d.BorderSizePixel   = 0
		d.Parent            = teeth
	end

	-- Click anywhere on it to put it away
	local hit                  = Instance.new("TextButton")
	hit.Size                   = UDim2.fromScale(1, 1)
	hit.BackgroundTransparency = 1
	hit.Text                   = ""
	hit.ZIndex                 = 10
	hit.Parent                 = paper

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

	local paper = receipt:FindFirstChildWhichIsA("Frame")
	local hit = paper and paper:FindFirstChildWhichIsA("TextButton")
	if hit then
		hit.MouseButton1Click:Connect(function()
			if current == receipt then hide(receipt) end
		end)
	end
	task.delay(SHOW_TIME, function()
		if showId == id and current == receipt then hide(receipt) end
	end)
end)
