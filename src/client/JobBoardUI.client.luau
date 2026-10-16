--!strict
--[[
    JobBoardUI (LocalScript)
    ------------------------
    The job board: customers waiting outside your bay, one per page on a
    clipboard (UI "Option D": paper). JobService sends who's waiting on
    JobQueue; picking one fires TakeJob.

    Each page: the customer's headshot, name, car, a stamp of what kind of
    customer they are, what they said, pay, tip, number of problems, how
    long they'll wait once the job starts, a short note, a REPEAT CUSTOMER
    sticker for regulars, and WAITING OUTSIDE — a bar that drains until they
    give up and leave.

    Controls (only while it's open):
        J          open / close   (also the Jobs button on the rent bar)
        A / D, ← → flip pages — the top page folds up over the clip
        E          take this job
        Q / Esc    close

    Flipping: the page folds up into the clip (its height shrinks from the
    bottom, pinned at the top) with a shadow darkening it, revealing the
    next page underneath. Going back drops the page down from the clip.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players              = game:GetService("Players")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local RunService           = game:GetService("RunService")
local SoundService         = game:GetService("SoundService")
local TweenService         = game:GetService("TweenService")
local UserInputService     = game:GetService("UserInputService")
local Workspace            = game:GetService("Workspace")

local Shared        = ReplicatedStorage:WaitForChild("Shared")
local Remotes       = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local ClientSignals = require(Shared:WaitForChild("Modules"):WaitForChild("ClientSignals"))
local UITheme       = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, FF         = UITheme.Colors, UITheme.Faces

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera    = Workspace.CurrentCamera

-- ── Config ────────────────────────────────────────────────────────────────────

local BOARD_W, BOARD_H = 460, 620
local PAGE_W, PAGE_H   = 432, 572
local FLIP_TIME        = 0.38
local FLIP_SOUND_ID    = "rbxassetid://0" -- set a paper-rustle sound id here (0 = silent)
local OPEN             = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Stamp ink for each kind of customer
local TYPE_INK: { [string]: Color3 } = {
	regular    = C.SheetInk,
	cheapskate = C.SheetMuted,
	fussy      = Color3.fromHex("6A4C93"),
	rush       = C.Marker,
	rich       = C.MarkerGreen,
}

-- ── State ─────────────────────────────────────────────────────────────────────

type Entry = {
	id: string,
	customerName: string,
	customerUserId: number?,
	car: string,
	customerKind: string,
	customerType: string,
	request: string,
	pay: number,
	tip: string,
	faults: number,
	patience: number,
	repeatVisit: boolean,
	note: string,
	deadline: number,
	wait: number,
}

local jobs: { Entry } = {}
local busy = false     -- you've a job on already
local hasBay = false
local page = 1
local isOpen = false
local flipping = false

-- ── Build ─────────────────────────────────────────────────────────────────────

local screen                = Instance.new("ScreenGui")
screen.Name                 = "JobBoardUI"
screen.ResetOnSpawn         = false
screen.IgnoreGuiInset       = true
screen.DisplayOrder         = 6
screen.Enabled              = false
screen.Parent               = playerGui

local dim                  = Instance.new("TextButton") -- dims the game, and catches stray clicks
dim.Size                   = UDim2.fromScale(1, 1)
dim.BackgroundColor3       = Color3.fromHex("0A0B0D")
dim.BackgroundTransparency = 0.45
dim.Text                   = ""
dim.AutoButtonColor        = false
dim.Parent                 = screen

local holder                  = Instance.new("Frame")
holder.AnchorPoint            = Vector2.new(0.5, 0.5)
holder.Position               = UDim2.fromScale(0.5, 0.52)
holder.Size                   = UDim2.fromOffset(BOARD_W + 180, BOARD_H)
holder.BackgroundTransparency = 1
holder.Parent                 = screen
local fit = Instance.new("UIScale")
fit.Parent = holder
local function refit()
	fit.Scale = math.clamp((camera.ViewportSize.Y * 0.88) / BOARD_H, 0.5, 1.2)
end
camera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
refit()

-- The clipboard
local board                  = Instance.new("Frame")
board.AnchorPoint            = Vector2.new(0.5, 0)
board.Position               = UDim2.new(0.5, 0, 0, 0)
board.Size                   = UDim2.fromOffset(BOARD_W, BOARD_H)
board.BackgroundColor3       = C.Wood
board.BorderSizePixel        = 0
board.Parent                 = holder
UITheme.Corner(board, UDim.new(0, 14))

-- Pages underneath, peeking out
type Peek = { rotation: number, color: string, x: number, y: number }
local PEEKS: { Peek } = {
	{ rotation = 2.2, color = "E6E1D2", x = 22, y = 44 },
	{ rotation = -1.4, color = "EDE8DA", x = 18, y = 40 },
}
for i, spec in ipairs(PEEKS) do
	local back                  = Instance.new("Frame")
	back.Position               = UDim2.fromOffset(spec.x, spec.y)
	back.Size                   = UDim2.fromOffset(PAGE_W - 8, PAGE_H - 12)
	back.Rotation               = spec.rotation
	back.BackgroundColor3       = Color3.fromHex(spec.color)
	back.BorderSizePixel        = 0
	back.ZIndex                 = i
	back.Parent                 = board
end

local clip                  = Instance.new("Frame")
clip.AnchorPoint            = Vector2.new(0.5, 0)
clip.Position               = UDim2.new(0.5, 0, 0, -10)
clip.Size                   = UDim2.fromOffset(120, 32)
clip.BackgroundColor3       = C.Clip
clip.ZIndex                 = 20
clip.Parent                 = board
UITheme.Corner(clip, UDim.new(0, 7))
UITheme.Stroke(clip, C.ClipEdge, 2)

-- ── One page ──────────────────────────────────────────────────────────────────

type Page = {
	frame: Frame,     -- clips its content (the flip shrinks its height)
	shade: Frame,
	header: TextLabel,
	photo: ImageLabel,
	initial: TextLabel,
	name: TextLabel,
	car: TextLabel,
	stamp: TextLabel,
	stampStroke: UIStroke,
	sticker: TextLabel,
	request: TextLabel,
	pay: TextLabel,
	tip: TextLabel,
	faults: TextLabel,
	patience: TextLabel,
	note: TextLabel,
	waitFill: Frame,
	takeBtn: TextButton,
	dots: Frame,
	empty: TextLabel,
	content: Frame,
}

local function cell(parent: Instance, x: number, y: number, label: string): TextLabel
	local row                  = Instance.new("Frame")
	row.Position               = UDim2.fromOffset(x, y)
	row.Size                   = UDim2.fromOffset(186, 28)
	row.BackgroundTransparency = 1
	row.Parent                 = parent
	local l = UITheme.Text(row, label, FF.Type, 14, C.SheetMuted)
	l.Size = UDim2.fromScale(1, 1)
	local v = UITheme.Text(row, "", FF.Type, 14, C.SheetInk)
	v.Size = UDim2.fromScale(1, 1)
	v.TextXAlignment = Enum.TextXAlignment.Right
	local line                  = Instance.new("Frame")
	line.Position               = UDim2.new(0, 0, 1, -1)
	line.Size                   = UDim2.new(1, 0, 0, 1)
	line.BackgroundColor3       = C.SheetMuted
	line.BackgroundTransparency = 0.6
	line.BorderSizePixel        = 0
	line.Parent                 = row
	return v
end

local function buildPage(z: number): Page
	local frame                  = Instance.new("Frame")
	frame.Position               = UDim2.fromOffset(14, 34)
	frame.Size                   = UDim2.fromOffset(PAGE_W, PAGE_H)
	frame.BackgroundColor3       = C.Sheet
	frame.BorderSizePixel        = 0
	frame.ClipsDescendants       = true
	frame.ZIndex                 = z
	frame.Parent                 = board

	-- Everything sits in a fixed-size layer, so when the frame's height
	-- shrinks the page folds up from the bottom rather than reflowing.
	local content                  = Instance.new("Frame")
	content.Size                   = UDim2.fromOffset(PAGE_W, PAGE_H)
	content.BackgroundTransparency = 1
	content.Parent                 = frame

	local header = UITheme.Text(content, "JOB BOARD", FF.Heavy, 18, C.SheetInk)
	header.Name = "Keep" -- stays visible on an empty board
	header.Position = UDim2.fromOffset(20, 16)
	header.Size = UDim2.fromOffset(PAGE_W - 40, 24)
	local count = UITheme.Text(content, "", FF.Type, 13, C.SheetInk)
	count.Name = "Keep"
	count.Position = UDim2.fromOffset(20, 16)
	count.Size = UDim2.fromOffset(PAGE_W - 40, 24)
	count.TextXAlignment = Enum.TextXAlignment.Right
	local rule                  = Instance.new("Frame")
	rule.Position               = UDim2.fromOffset(20, 44)
	rule.Size                   = UDim2.fromOffset(PAGE_W - 40, 2)
	rule.BackgroundColor3       = C.SheetInk
	rule.BorderSizePixel        = 0
	rule.Name                   = "Keep"
	rule.Parent                 = content

	local photo                  = Instance.new("ImageLabel")
	photo.Position               = UDim2.fromOffset(22, 60)
	photo.Size                   = UDim2.fromOffset(64, 64)
	photo.Rotation               = -2
	photo.BackgroundColor3       = Color3.fromHex("D6DCE4")
	photo.BorderSizePixel        = 0
	photo.Parent                 = content
	UITheme.Stroke(photo, C.SheetInk, 2)
	local initial = UITheme.Text(photo, "", FF.Heavy, 28, C.SheetInk)
	initial.Size = UDim2.fromScale(1, 1)
	initial.TextXAlignment = Enum.TextXAlignment.Center

	local name = UITheme.Text(content, "", FF.Type, 20, C.SheetInk)
	name.Position = UDim2.fromOffset(100, 58)
	name.Size = UDim2.fromOffset(220, 24)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local car = UITheme.Text(content, "", FF.Type, 13, C.SheetMuted)
	car.Position = UDim2.fromOffset(100, 82)
	car.Size = UDim2.fromOffset(220, 18)
	car.TextTruncate = Enum.TextTruncate.AtEnd
	local stamp = UITheme.Text(content, "", FF.Heavy, 11, C.SheetInk)
	stamp.Position = UDim2.fromOffset(102, 104)
	stamp.Size = UDim2.fromOffset(0, 18)
	stamp.AutomaticSize = Enum.AutomaticSize.X
	stamp.Rotation = -3
	UITheme.Pad(stamp, 0, 6)
	local stampStroke = UITheme.Stroke(stamp, C.SheetInk, 2)

	local sticker = UITheme.Text(content, "REPEAT\nCUSTOMER\n★ TIPS MORE", FF.Heavy, 10, C.SheetInk)
	sticker.Position = UDim2.fromOffset(PAGE_W - 98, 54)
	sticker.Size = UDim2.fromOffset(76, 76)
	sticker.TextXAlignment = Enum.TextXAlignment.Center
	sticker.BackgroundColor3 = C.Amber
	sticker.BackgroundTransparency = 0
	sticker.Rotation = 10
	sticker.Visible = false
	UITheme.Corner(sticker, UITheme.Radius.Pill)

	local requestBox                  = Instance.new("Frame")
	requestBox.Position               = UDim2.fromOffset(20, 140)
	requestBox.Size                   = UDim2.fromOffset(PAGE_W - 40, 92)
	requestBox.BackgroundColor3       = C.SheetInk
	requestBox.BackgroundTransparency = 0.96
	requestBox.BorderSizePixel        = 0
	requestBox.Parent                 = content
	UITheme.Pad(requestBox, 8, 12)
	local request = UITheme.Text(requestBox, "", FF.Type, 15, Color3.fromHex("3A3832"))
	request.Size = UDim2.fromScale(1, 1)
	request.TextWrapped = true
	request.TextYAlignment = Enum.TextYAlignment.Top

	local pay = cell(content, 20, 246, "Pay")
	pay.FontFace = FF.Marker
	pay.TextSize = 20
	pay.TextColor3 = C.Marker
	local tip = cell(content, 226, 246, "Tip")
	local faults = cell(content, 20, 282, "Problems")
	local patience = cell(content, 226, 282, "Will wait")

	local note = UITheme.Text(content, "", FF.Type, 13, C.SheetMuted)
	note.Position = UDim2.fromOffset(20, 322)
	note.Size = UDim2.fromOffset(PAGE_W - 40, 36)
	note.TextWrapped = true
	note.TextYAlignment = Enum.TextYAlignment.Top

	local waitLabel = UITheme.Text(content, "WAITING OUTSIDE", FF.Heavy, 10, C.SheetMuted)
	waitLabel.Position = UDim2.fromOffset(20, 370)
	waitLabel.Size = UDim2.fromOffset(120, 14)
	local waitTrack                  = Instance.new("Frame")
	waitTrack.Position               = UDim2.fromOffset(140, 371)
	waitTrack.Size                   = UDim2.fromOffset(PAGE_W - 160, 12)
	waitTrack.BackgroundColor3       = Color3.new(1, 1, 1)
	waitTrack.BorderSizePixel        = 0
	waitTrack.Parent                 = content
	UITheme.Stroke(waitTrack, C.SheetInk, 2)
	local waitFill            = Instance.new("Frame")
	waitFill.Size             = UDim2.fromScale(1, 1)
	waitFill.BackgroundColor3 = C.MarkerGreen
	waitFill.BorderSizePixel  = 0
	waitFill.Parent           = waitTrack

	local takeBtn                  = Instance.new("TextButton")
	takeBtn.Position               = UDim2.fromOffset(20, PAGE_H - 104)
	takeBtn.Size                   = UDim2.fromOffset(PAGE_W - 40, 52)
	takeBtn.BackgroundColor3       = C.SheetInk
	takeBtn.BorderSizePixel        = 0
	takeBtn.AutoButtonColor        = true
	takeBtn.FontFace               = FF.Heavy
	takeBtn.TextSize               = 16
	takeBtn.TextColor3             = C.Sheet
	takeBtn.Text                   = "[E]  TAKE THIS JOB"
	takeBtn.Parent                 = content

	local dots                  = Instance.new("Frame")
	dots.Position               = UDim2.fromOffset(20, PAGE_H - 36)
	dots.Size                   = UDim2.fromOffset(PAGE_W - 40, 12)
	dots.BackgroundTransparency = 1
	dots.Parent                 = content
	local dotsList = UITheme.List(dots, 8, true)
	dotsList.HorizontalAlignment = Enum.HorizontalAlignment.Center

	local empty = UITheme.Text(content, "", FF.Type, 16, C.SheetMuted)
	empty.Position = UDim2.fromOffset(30, 200)
	empty.Size = UDim2.fromOffset(PAGE_W - 60, 120)
	empty.TextWrapped = true
	empty.TextXAlignment = Enum.TextXAlignment.Center
	empty.Visible = false

	-- Page curl in the bottom-right corner
	local curl                  = Instance.new("Frame")
	curl.AnchorPoint            = Vector2.new(1, 1)
	curl.Position               = UDim2.fromScale(1, 1)
	curl.Size                   = UDim2.fromOffset(34, 34)
	curl.BackgroundColor3       = C.SheetLine
	curl.BorderSizePixel        = 0
	curl.Parent                 = content
	local curlGradient      = Instance.new("UIGradient")
	curlGradient.Rotation   = 45
	curlGradient.Color      = ColorSequence.new({
		ColorSequenceKeypoint.new(0, C.Sheet), ColorSequenceKeypoint.new(0.5, C.Sheet),
		ColorSequenceKeypoint.new(0.501, C.SheetLine), ColorSequenceKeypoint.new(1, C.SheetLine),
	})
	curlGradient.Parent = curl

	-- Shadow that darkens the page as it folds up
	local shade                  = Instance.new("Frame")
	shade.Size                   = UDim2.fromScale(1, 1)
	shade.BackgroundColor3       = C.SheetInk
	shade.BackgroundTransparency = 1
	shade.BorderSizePixel        = 0
	shade.ZIndex                 = 5
	shade.Parent                 = frame
	local shadeGradient       = Instance.new("UIGradient")
	shadeGradient.Rotation    = 90
	shadeGradient.Transparency = NumberSequence.new(1, 0)
	shadeGradient.Parent      = shade

	return {
		frame = frame, shade = shade, header = count, photo = photo, initial = initial,
		name = name, car = car, stamp = stamp, stampStroke = stampStroke, sticker = sticker,
		request = request, pay = pay, tip = tip, faults = faults, patience = patience,
		note = note, waitFill = waitFill, takeBtn = takeBtn, dots = dots, empty = empty,
		content = content,
	}
end

-- Two pages: the one you're looking at, and one used during a flip.
local pageA = buildPage(10)
local pageB = buildPage(11)
pageB.frame.Visible = false
local shown, spare = pageA, pageB

-- ── Filling a page ────────────────────────────────────────────────────────────

local headshots: { [number]: string } = {}

local function setPhoto(p: Page, userId: number?, name: string)
	p.initial.Text = string.upper(string.sub(name, 1, 1))
	p.initial.Visible = true
	p.photo.Image = ""
	if not userId or userId <= 0 then return end
	local cached = headshots[userId]
	if cached then
		p.photo.Image, p.initial.Visible = cached, false
		return
	end
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and type(image) == "string" then
			headshots[userId] = image
			p.photo.Image, p.initial.Visible = image, false
		end
	end)
end

local function minutes(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

local function setDots(p: Page, index: number, total: number)
	for _, child in ipairs(p.dots:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	for i = 1, total do
		local dot                  = Instance.new("Frame")
		dot.Size                   = UDim2.fromOffset(10, 10)
		dot.BackgroundColor3       = C.SheetInk
		dot.BackgroundTransparency = if i == index then 0 else 1
		dot.LayoutOrder            = i
		dot.Parent                 = p.dots
		UITheme.Corner(dot, UITheme.Radius.Pill)
		UITheme.Stroke(dot, C.SheetInk, 2)
	end
end

-- Shows job `index` (or the empty / no-bay message) on page `p`.
local function fill(p: Page, index: number)
	local e = jobs[index]
	local hasJob = e ~= nil
	for _, child in ipairs(p.content:GetChildren()) do
		if child:IsA("GuiObject") and child ~= p.empty and child.Name ~= "Keep" then
			child.Visible = hasJob
		end
	end
	p.empty.Visible = not hasJob
	p.sticker.Visible = hasJob and e.repeatVisit
	p.header.Text = if #jobs > 0 then ("%d of %d waiting"):format(index, #jobs) else ""

	if not e then
		p.empty.Text = if hasBay
			then "No one's waiting right now.\n\nCustomers turn up outside your bay every so often."
			else "No bay, no customers.\n\nRent a bay from Tony first."
		return
	end

	setPhoto(p, e.customerUserId, e.customerName)
	p.name.Text = e.customerName
	p.car.Text = e.car
	p.stamp.Text = e.customerType
	local ink = TYPE_INK[e.customerKind] or C.SheetInk
	p.stamp.TextColor3 = ink
	p.stampStroke.Color = ink
	p.request.Text = "\u{201C}" .. e.request .. "\u{201D}"
	p.pay.Text = UITheme.Money(e.pay)
	p.tip.Text = e.tip
	p.faults.Text = tostring(e.faults)
	p.patience.Text = minutes(e.patience)
	p.note.Text = e.note
	setDots(p, index, #jobs)

	if busy then
		p.takeBtn.Text = "FINISH YOUR CURRENT JOB FIRST"
		p.takeBtn.BackgroundColor3 = C.SheetMuted
		p.takeBtn.AutoButtonColor = false
	else
		p.takeBtn.Text = "[E]  TAKE THIS JOB"
		p.takeBtn.BackgroundColor3 = C.SheetInk
		p.takeBtn.AutoButtonColor = true
	end
end

local function refresh()
	if #jobs == 0 then page = 1 end
	page = math.clamp(page, 1, math.max(1, #jobs))
	fill(shown, page)
end

-- ── Flipping ──────────────────────────────────────────────────────────────────

local flipSound = Instance.new("Sound")
flipSound.SoundId = FLIP_SOUND_ID
flipSound.Volume = 0.6
flipSound.Parent = SoundService

local FULL = UDim2.fromOffset(PAGE_W, PAGE_H)
local FOLDED = UDim2.fromOffset(PAGE_W, 0)

-- dir 1: the top page folds up over the clip, revealing the next page.
-- dir -1: the previous page drops down from the clip over this one.
local function flipNow(dir: number)
	if flipping or #jobs < 2 then return end
	flipping = true
	local target = ((page - 1 + dir) % #jobs) + 1
	if FLIP_SOUND_ID ~= "rbxassetid://0" then flipSound:Play() end

	local moving: Page
	if dir > 0 then
		-- the page you see folds away; the next one waits underneath
		fill(spare, target)
		spare.frame.ZIndex, shown.frame.ZIndex = 10, 11
		spare.frame.Size, spare.frame.Visible = FULL, true
		spare.shade.BackgroundTransparency = 1
		moving = shown
		local t = TweenService:Create(moving.frame, TweenInfo.new(FLIP_TIME, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut), { Size = FOLDED })
		TweenService:Create(moving.shade, TweenInfo.new(FLIP_TIME), { BackgroundTransparency = 0.45 }):Play()
		t:Play()
		t.Completed:Wait()
		moving.frame.Visible = false
		moving.frame.Size = FULL
		moving.shade.BackgroundTransparency = 1
		shown, spare = spare, shown
	else
		-- the previous page drops down over this one
		fill(spare, target)
		spare.frame.ZIndex, shown.frame.ZIndex = 11, 10
		spare.frame.Size, spare.frame.Visible = FOLDED, true
		spare.shade.BackgroundTransparency = 0.45
		moving = spare
		local t = TweenService:Create(moving.frame, TweenInfo.new(FLIP_TIME, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut), { Size = FULL })
		TweenService:Create(moving.shade, TweenInfo.new(FLIP_TIME), { BackgroundTransparency = 1 }):Play()
		t:Play()
		t.Completed:Wait()
		shown.frame.Visible = false
		shown, spare = spare, shown
	end
	page = target
	flipping = false
end

-- Flips without holding up whoever asked (a key press, a click).
local function flip(dir: number)
	task.spawn(flipNow, dir)
end

-- ── Arrows, close, hint ───────────────────────────────────────────────────────

local function roundButton(text: string, x: UDim): TextButton
	local b                  = Instance.new("TextButton")
	b.AnchorPoint            = Vector2.new(0.5, 0.5)
	b.Position               = UDim2.new(x, UDim.new(0.5, 0))
	b.Size                   = UDim2.fromOffset(56, 56)
	b.Font                   = Enum.Font.GothamBold -- has the ◀ ▶ arrows
	b.Text                   = text
	b.TextSize               = 20
	b.TextColor3             = C.GlassText
	b.AutoButtonColor        = true
	b.Parent                 = holder
	UITheme.Glass(b, UITheme.Radius.Pill)
	return b
end
local prevBtn = roundButton("◀", UDim.new(0, 30))
local nextBtn = roundButton("▶", UDim.new(1, -30))

local closeBtn                  = Instance.new("TextButton")
closeBtn.AnchorPoint            = Vector2.new(1, 0)
closeBtn.Position               = UDim2.new(0.5, BOARD_W / 2 + 4, 0, -18)
closeBtn.Size                   = UDim2.fromOffset(0, 32)
closeBtn.AutomaticSize          = Enum.AutomaticSize.X
closeBtn.FontFace               = FF.Bold
closeBtn.Text                   = "Close · Q"
closeBtn.TextSize               = 13
closeBtn.TextColor3             = C.GlassText
closeBtn.ZIndex                 = 30
closeBtn.Parent                 = holder
UITheme.Glass(closeBtn, UITheme.Radius.Pill)
UITheme.Pad(closeBtn, 0, 14)

local hint = UITheme.Text(holder, "A / D or the arrows to flip pages  ·  E to take a job  ·  Q to close", FF.Body, 13, C.GlassMuted)
hint.Position = UDim2.new(0, 0, 1, 10)
hint.Size = UDim2.new(1, 0, 0, 18)
hint.TextXAlignment = Enum.TextXAlignment.Center

-- ── Open / close / take ───────────────────────────────────────────────────────

local KEYS = {
	Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.Left, Enum.KeyCode.Right,
	Enum.KeyCode.E, Enum.KeyCode.Q, Enum.KeyCode.Escape,
}

local setOpen -- defined below

local function take()
	if busy or flipping then return end
	local e = jobs[page]
	if not e then return end
	Remotes.TakeJob:FireServer(e.id)
	setOpen(false)
end

-- While open, the board's keys win over everything else (E won't trigger
-- prompts behind it, A/D won't walk you about).
local function onKey(_action: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Sink end
	local key = input.KeyCode
	if key == Enum.KeyCode.A or key == Enum.KeyCode.Left then
		flip(-1)
	elseif key == Enum.KeyCode.D or key == Enum.KeyCode.Right then
		flip(1)
	elseif key == Enum.KeyCode.E then
		take()
	else
		setOpen(false)
	end
	return Enum.ContextActionResult.Sink
end

setOpen = function(open: boolean)
	if open == isOpen then return end
	isOpen = open
	if open then
		refresh()
		screen.Enabled = true
		fit.Scale = fit.Scale * 0.9
		local target = fit.Scale / 0.9
		TweenService:Create(fit, OPEN, { Scale = target }):Play()
		ContextActionService:BindActionAtPriority("JobBoardKeys", onKey, false,
			Enum.ContextActionPriority.High.Value + 100, table.unpack(KEYS))
	else
		screen.Enabled = false
		ContextActionService:UnbindAction("JobBoardKeys")
		refit()
	end
end

prevBtn.MouseButton1Click:Connect(function() flip(-1) end)
nextBtn.MouseButton1Click:Connect(function() flip(1) end)
closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)
dim.MouseButton1Click:Connect(function() setOpen(false) end)
pageA.takeBtn.MouseButton1Click:Connect(take)
pageB.takeBtn.MouseButton1Click:Connect(take)

ClientSignals.JobBoardToggle:Connect(function()
	setOpen(not isOpen)
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.J then setOpen(not isOpen) end
end)

-- ── From the server ───────────────────────────────────────────────────────────

Remotes.JobQueue.OnClientEvent:Connect(function(data: any)
	if type(data) ~= "table" then return end
	busy = data.busy == true
	hasBay = data.open == true
	local list: { Entry } = {}
	if type(data.jobs) == "table" then
		for _, j in ipairs(data.jobs) do
			if type(j) == "table" and type(j.id) == "string" then
				table.insert(list, {
					id             = j.id,
					customerName   = tostring(j.customerName or "Customer"),
					customerUserId = if type(j.customerUserId) == "number" then j.customerUserId else nil,
					car            = tostring(j.car or ""),
					customerKind   = tostring(j.customerKind or "regular"),
					customerType   = tostring(j.customerType or "REGULAR"),
					request        = tostring(j.request or ""),
					pay            = tonumber(j.pay) or 0,
					tip            = tostring(j.tip or ""),
					faults         = tonumber(j.faults) or 1,
					patience       = tonumber(j.patience) or 600,
					repeatVisit    = j.repeatVisit == true,
					note           = tostring(j.note or ""),
					deadline       = tonumber(j.deadline) or 0,
					wait           = math.max(1, tonumber(j.wait) or 150),
				})
			end
		end
	end
	-- Stay on the same customer if they're still there.
	local current = jobs[page]
	jobs = list
	if current then
		for i, e in ipairs(jobs) do
			if e.id == current.id then
				page = i
				break
			end
		end
	end
	if not hasBay and isOpen then setOpen(false) end
	if isOpen and not flipping then refresh() end
end)

-- The WAITING OUTSIDE bar drains while the board is open.
RunService.RenderStepped:Connect(function()
	if not isOpen then return end
	local e = jobs[page]
	if not e then return end
	local share = math.clamp((e.deadline - Workspace:GetServerTimeNow()) / e.wait, 0, 1)
	shown.waitFill.Size = UDim2.fromScale(share, 1)
	shown.waitFill.BackgroundColor3 = if share > 0.5 then C.MarkerGreen elseif share > 0.25 then C.TonyTab else C.Marker
end)
