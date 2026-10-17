--!strict
--[[
    BayRentalUI (LocalScript)
    -------------------------
    The player's side of Tony and the bay (UI "Option D": paper for what
    people in the world say, glass for your HUD):

    1. Speech notes (PAPER) — NpcSpeech (name, text, info) shows a note at
       the bottom of the screen: a coloured side tab with the speaker's
       picture and name (Tony's amber tab, a customer's blue tab with their
       Roblox headshot), and the line typed out like a typewriter. Tony's
       notes carry a rubber stamp of his mood; when he's furious the tab
       turns red and he writes in red marker.
    2. YOUR BAY (GLASS) — a marker over the bay you rent (the bay part's
       "RentedBy" attribute is your UserId) with the rent per minute and a
       countdown under it. Hidden while the camera is scripted (engine
       view, workbench).
    3. The rent bar (GLASS) while you rent — top middle of the screen, up in
       Roblox's top bar, level with its menu and chat buttons: the bay, the rate,
       the countdown — red ("on tab in 0:09") when you can't cover the next
       minute — and HAND BACK KEYS, which needs a second click within a
       few seconds (and says so when it would cancel your job), and Jobs —
       how many customers are waiting; opens the job board (JobBoardUI).

    Rent numbers come from TonyStatus (TonyService).
]]

local GuiService        = game:GetService("GuiService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")

local Shared    = ReplicatedStorage:WaitForChild("Shared")
local Remotes   = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local ZoneUtils = require(Shared:WaitForChild("Modules"):WaitForChild("ZoneUtils"))
local ClientSignals = require(Shared:WaitForChild("Modules"):WaitForChild("ClientSignals"))
local UITheme   = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, FF     = UITheme.Colors, UITheme.Faces

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera    = Workspace.CurrentCamera

-- ── Config ────────────────────────────────────────────────────────────────────

local NOTE_WIDTH       = 600
local NOTE_BOTTOM      = 96    -- px above the bottom edge (clears the hotbar)
local TYPE_SPEED       = 55    -- characters per second
local READ_MIN_TIME    = 3     -- seconds a line stays up after it's typed, at least
local READ_PER_CHAR    = 0.035 -- plus this much per character
local SLIDE            = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FADE             = TweenInfo.new(0.2, Enum.EasingStyle.Quad)
local MARKER_HEIGHT    = 2     -- studs above the top of the bay part
local CONFIRM_TIME     = 3     -- seconds the "click again" state of HAND BACK KEYS lasts

-- Tony's mood stamp: ink colour, and whether it's a filled stamp.
local MOOD_STAMPS: { [string]: { color: Color3, filled: boolean } } = {
	good      = { color = C.MarkerGreen, filled = false },
	normal    = { color = C.SheetInk, filled = false },
	grumpy    = { color = C.Marker, filled = false },
	furious   = { color = C.Marker, filled = true },
	desperate = { color = C.SheetMuted, filled = false },
}

local screen          = Instance.new("ScreenGui")
screen.Name           = "BayRentalUI"
screen.ResetOnSpawn   = false
screen.Parent         = playerGui

-- ── 1. Speech notes (paper) ───────────────────────────────────────────────────

local note                  = Instance.new("CanvasGroup") -- fades as one piece
note.Name                   = "SpeechNote"
note.AnchorPoint            = Vector2.new(0.5, 1)
note.Position               = UDim2.new(0.5, 0, 1, -NOTE_BOTTOM)
note.Size                   = UDim2.new(0, NOTE_WIDTH, 0, 0)
note.AutomaticSize          = Enum.AutomaticSize.Y
note.BackgroundTransparency = 1
note.GroupTransparency      = 1
note.Visible                = false
note.Parent                 = screen

-- Body: stamp or caption, then the line. It decides the note's height.
local body                  = Instance.new("Frame")
body.Position               = UDim2.new(0, 90, 0, 0) -- borders overlap the tab's by 2px
body.Size                   = UDim2.new(1, -92, 0, 0)
body.AutomaticSize          = Enum.AutomaticSize.Y
body.Parent                 = note
UITheme.Paper(body)
UITheme.Pad(body, 12, 16)
UITheme.List(body, 6)
local minHeight   = Instance.new("UISizeConstraint")
minHeight.MinSize = Vector2.new(0, 88)
minHeight.Parent  = body

-- Side tab: picture + name, as tall as the body.
local tab                  = Instance.new("Frame")
tab.Position               = UDim2.new(0, 2, 0, 0)
tab.Size                   = UDim2.new(0, 90, 1, 0)
tab.BackgroundColor3       = C.TonyTab
tab.BorderSizePixel        = 0
tab.Parent                 = note
UITheme.Stroke(tab, C.SheetInk, 2)

local photo                  = Instance.new("ImageLabel")
photo.AnchorPoint            = Vector2.new(0.5, 0)
photo.Position               = UDim2.new(0.5, 0, 0, 10)
photo.Size                   = UDim2.new(0, 50, 0, 50)
photo.BackgroundColor3       = C.Sheet
photo.BorderSizePixel        = 0
photo.Image                  = ""
photo.Parent                 = tab
UITheme.Stroke(photo, C.SheetInk, 2)

local initial = UITheme.Text(photo, "T", FF.Heavy, 24, C.SheetInk)
initial.Size = UDim2.fromScale(1, 1)
initial.TextXAlignment = Enum.TextXAlignment.Center

local tabName = UITheme.Text(tab, "TONY", FF.Heavy, 13, C.SheetInk)
tabName.Position = UDim2.new(0, 4, 0, 64)
tabName.Size = UDim2.new(1, -8, 0, 18)
tabName.TextXAlignment = Enum.TextXAlignment.Center
tabName.TextTruncate = Enum.TextTruncate.AtEnd

local stampHolder                  = Instance.new("Frame")
stampHolder.Size                   = UDim2.new(1, 0, 0, 20)
stampHolder.BackgroundTransparency = 1
stampHolder.LayoutOrder            = 1
stampHolder.Parent                 = body

local stamp                  = Instance.new("TextLabel")
stamp.Size                   = UDim2.new(0, 0, 0, 18)
stamp.AutomaticSize          = Enum.AutomaticSize.X
stamp.Rotation               = -3
stamp.BackgroundColor3       = C.Marker
stamp.BackgroundTransparency = 1
stamp.BorderSizePixel        = 0
stamp.FontFace               = FF.Heavy
stamp.TextSize               = 12
stamp.Text                   = "NORMAL"
stamp.TextColor3             = C.SheetInk
stamp.Parent                 = stampHolder
UITheme.Pad(stamp, 0, 8)
local stampStroke = UITheme.Stroke(stamp, C.SheetInk, 2)

local caption = UITheme.Text(stampHolder, "", FF.Heavy, 11, C.SheetMuted)
caption.Size = UDim2.fromScale(1, 1)

local line = UITheme.Text(body, "", FF.Type, 17, C.SheetInk)
line.Size = UDim2.new(1, 0, 0, 0)
line.AutomaticSize = Enum.AutomaticSize.Y
line.TextWrapped = true
line.TextYAlignment = Enum.TextYAlignment.Top
line.LineHeight = 1.15
line.LayoutOrder = 2

-- Who's talking → how the note looks.
local headshotFor: { [number]: string } = {}
local photoFor: number? = nil

local function setPhoto(userId: number?, fallbackLetter: string)
	photoFor = userId
	photo.Image = ""
	initial.Text = string.upper(string.sub(fallbackLetter, 1, 1))
	initial.Visible = true
	if not userId or userId <= 0 then return end
	local cached = headshotFor[userId]
	if cached then
		photo.Image, initial.Visible = cached, false
		return
	end
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and type(image) == "string" then
			headshotFor[userId] = image
			if photoFor == userId then
				photo.Image, initial.Visible = image, false
			end
		end
	end)
end

local function dressNote(name: string, info: { [string]: any })
	tabName.Text = string.upper(name)
	local isTony = info.kind == "tony"
	local mood = if type(info.mood) == "string" then info.mood else "normal"
	local furious = isTony and mood == "furious"

	tab.BackgroundColor3 = if furious then C.Marker elseif isTony then C.TonyTab else C.CustomerTab
	tabName.TextColor3   = if furious then C.Sheet else C.SheetInk
	setPhoto(if type(info.userId) == "number" then info.userId else nil, name)

	if isTony then
		local look = MOOD_STAMPS[mood] or MOOD_STAMPS.normal
		stamp.Visible = true
		caption.Visible = false
		stamp.Text = string.upper(if type(info.moodLabel) == "string" then info.moodLabel else mood)
		stamp.BackgroundTransparency = if look.filled then 0 else 1
		stamp.TextColor3 = if look.filled then C.Sheet else look.color
		stampStroke.Color = look.color
	else
		stamp.Visible = false
		caption.Visible = true
		caption.Text = "CUSTOMER" .. (if type(info.car) == "string" then "  ·  " .. string.upper(info.car) else "")
	end

	-- Furious Tony scrawls in red marker; everyone else types.
	line.FontFace   = if furious then FF.Marker else FF.Type
	line.TextSize   = if furious then 22 else 17
	line.TextColor3 = if furious then C.Marker else C.SheetInk
end

local speechId = 0 -- so an older line's timers can't touch a newer line

Remotes.NpcSpeech.OnClientEvent:Connect(function(name: any, text: any, info: any)
	if type(name) ~= "string" or type(text) ~= "string" then return end
	speechId += 1
	local id = speechId

	dressNote(name, if type(info) == "table" then info else { kind = if name == "Tony" then "tony" else "customer" })
	line.Text = text
	line.MaxVisibleGraphemes = 0

	-- Slide up and fade in (from below, unless a note is already up).
	if not note.Visible or note.GroupTransparency > 0.5 then
		note.Position = UDim2.new(0.5, 0, 1, -NOTE_BOTTOM + 24)
	end
	note.Visible = true
	TweenService:Create(note, SLIDE, { Position = UDim2.new(0.5, 0, 1, -NOTE_BOTTOM) }):Play()
	TweenService:Create(note, FADE, { GroupTransparency = 0 }):Play()

	-- Type it out, wait for it to be read, fade away.
	local length = utf8.len(text) or #text
	task.spawn(function()
		local shown = 0.0
		while shown < length and speechId == id do
			shown = math.min(length, shown + TYPE_SPEED * task.wait())
			line.MaxVisibleGraphemes = math.floor(shown)
		end
		if speechId ~= id then return end
		line.MaxVisibleGraphemes = -1

		task.wait(READ_MIN_TIME + length * READ_PER_CHAR)
		if speechId ~= id then return end
		TweenService:Create(note, FADE, { GroupTransparency = 1 }):Play()
		task.wait(FADE.Time)
		if speechId == id then note.Visible = false end
	end)
end)

-- ── 2. YOUR BAY marker (glass) ────────────────────────────────────────────────

local markers: { [BasePart]: BillboardGui } = {}
local markerRates: { [BillboardGui]: TextLabel } = {}

local function pill(parent: Instance, text: string, fontFace: Font, size: number, color: Color3, bg: Color3, alpha: number): TextLabel
	local l = UITheme.Text(parent, text, fontFace, size, color)
	l.AnchorPoint            = Vector2.new(0.5, 0)
	l.Size                   = UDim2.new(0, 0, 0, size + 10)
	l.AutomaticSize          = Enum.AutomaticSize.X
	l.TextXAlignment         = Enum.TextXAlignment.Center
	l.BackgroundColor3       = bg
	l.BackgroundTransparency = alpha
	UITheme.Corner(l, UITheme.Radius.Pill)
	UITheme.Pad(l, 0, 14)
	return l
end

local function makeMarker(zone: BasePart): BillboardGui
	local gui                  = Instance.new("BillboardGui")
	gui.Name                   = "YourBayMarker"
	gui.Adornee                = zone
	gui.Size                   = UDim2.new(0, 180, 0, 60)
	gui.StudsOffsetWorldSpace  = Vector3.new(0, zone.Size.Y / 2 + MARKER_HEIGHT, 0)
	gui.AlwaysOnTop            = true
	gui.LightInfluence         = 0
	gui.Parent                 = playerGui -- this client only

	local top = pill(gui, "YOUR BAY", FF.Heavy, 15, C.Glass, C.Done, 0)
	top.Position = UDim2.new(0.5, 0, 0, 0)

	local rate = pill(gui, "", FF.Mono, 13, C.Amber, C.Glass, 0.15)
	rate.Position = UDim2.new(0.5, 0, 0, 30)
	rate.Visible = false
	markerRates[gui] = rate
	return gui
end

local function isScripted(): boolean
	return camera.CameraType == Enum.CameraType.Scriptable
end

local function dropMarker(zone: BasePart)
	local existing = markers[zone]
	if existing then
		markerRates[existing] = nil
		existing:Destroy()
		markers[zone] = nil
	end
end

local function refreshMarker(zone: BasePart)
	if ZoneUtils.GetRenter(zone) ~= player.UserId then
		dropMarker(zone)
		return
	end
	local marker = markers[zone] or makeMarker(zone)
	markers[zone] = marker
	marker.Enabled = not isScripted()
end

local function watchZone(zone: Instance)
	if not zone:IsA("BasePart") then return end
	zone:GetAttributeChangedSignal(ZoneUtils.RENTED_BY_ATTRIBUTE):Connect(function()
		refreshMarker(zone)
	end)
	refreshMarker(zone)
end

task.spawn(function()
	local zonesFolder = Workspace:WaitForChild("EngineZones")
	for _, zone in ipairs(zonesFolder:GetChildren()) do
		watchZone(zone)
	end
	zonesFolder.ChildAdded:Connect(watchZone)
	zonesFolder.ChildRemoved:Connect(function(zone)
		if zone:IsA("BasePart") then dropMarker(zone) end
	end)
end)

camera:GetPropertyChangedSignal("CameraType"):Connect(function()
	for zone in pairs(markers) do
		refreshMarker(zone)
	end
end)

-- ── 3. Rent bar (glass) ───────────────────────────────────────────────────────

-- Its own ScreenGui that ignores the top-bar inset, so it can sit IN the
-- top bar, beside Roblox's own buttons.
local topScreen            = Instance.new("ScreenGui")
topScreen.Name             = "RentBarUI"
topScreen.ResetOnSpawn     = false
topScreen.IgnoreGuiInset   = true
topScreen.Parent           = playerGui

local bar                  = Instance.new("Frame")
bar.Name                   = "RentBar"
bar.Size                   = UDim2.new(0, 0, 0, 44)
bar.AutomaticSize          = Enum.AutomaticSize.X
bar.Visible                = false
bar.Parent                 = topScreen

-- Centred across the screen, and level with Roblox's top-bar buttons
-- (GuiService.TopbarInset gives the top bar's height and position).
bar.AnchorPoint = Vector2.new(0.5, 0)
local function placeBar()
	local inset = GuiService.TopbarInset
	local height = if inset.Height > 0 then math.min(inset.Height, 44) else 44
	local top = if inset.Height > 0 then inset.Min.Y + (inset.Height - height) / 2 else 12
	bar.Size = UDim2.new(0, 0, 0, height)
	bar.Position = UDim2.new(0.5, 0, 0, top)
end
placeBar()
GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(placeBar)
UITheme.Glass(bar, UITheme.Radius.Pill)
local barStroke = bar:FindFirstChildOfClass("UIStroke") :: UIStroke
local barPad = UITheme.Pad(bar, 0, 16)
barPad.PaddingRight = UDim.new(0, 6)
UITheme.List(bar, 12, true)

local bayLabel = UITheme.Text(bar, "Bay", FF.Heavy, 15, C.GlassText)
bayLabel.Size = UDim2.new(0, 0, 1, 0)
bayLabel.AutomaticSize = Enum.AutomaticSize.X
bayLabel.LayoutOrder = 1

local rateLabel = UITheme.Text(bar, "", FF.Mono, 14, C.Amber)
rateLabel.Size = UDim2.new(0, 0, 1, 0)
rateLabel.AutomaticSize = Enum.AutomaticSize.X
rateLabel.LayoutOrder = 2

local timeLabel = UITheme.Text(bar, "", FF.Mono, 14, C.GlassMuted)
timeLabel.Size = UDim2.new(0, 130, 1, 0)
timeLabel.LayoutOrder = 3

-- Late payments: ●●●○○ (5 = Tony evicts you). Hidden with none.
local strikesLabel = UITheme.Text(bar, "", FF.Bold, 14, C.BadText)
strikesLabel.Size = UDim2.new(0, 0, 1, 0)
strikesLabel.AutomaticSize = Enum.AutomaticSize.X
strikesLabel.LayoutOrder = 4
strikesLabel.Font = Enum.Font.GothamBold -- BuilderSans has no ● ○
strikesLabel.Visible = false

-- Tony's inspection countdown, once he's announced one.
local inspectLabel = UITheme.Text(bar, "", FF.Bold, 14, C.Amber)
inspectLabel.Size = UDim2.new(0, 0, 1, 0)
inspectLabel.AutomaticSize = Enum.AutomaticSize.X
inspectLabel.LayoutOrder = 5
inspectLabel.Visible = false

local MAX_STRIKES = 5 -- BayRentalService.EVICT_STRIKES

local keysBtn                  = Instance.new("TextButton")
keysBtn.Size                   = UDim2.new(0, 0, 1, -10)
keysBtn.AutomaticSize          = Enum.AutomaticSize.X
keysBtn.BackgroundColor3       = C.Bad
keysBtn.BackgroundTransparency = 0.86
keysBtn.AutoButtonColor        = false
keysBtn.FontFace               = FF.Bold
keysBtn.TextSize               = 13
keysBtn.TextColor3             = C.BadText
keysBtn.Text                   = "Hand back keys"
keysBtn.LayoutOrder            = 7
keysBtn.Parent                 = bar
UITheme.Corner(keysBtn, UITheme.Radius.Pill)
UITheme.Stroke(keysBtn, C.Bad, 1, 0.65)
UITheme.Pad(keysBtn, 0, 14)

-- Jobs: opens the job board (JobBoardUI); shows how many are waiting.
local jobsBtn                  = Instance.new("TextButton")
jobsBtn.Size                   = UDim2.new(0, 0, 1, -10)
jobsBtn.AutomaticSize          = Enum.AutomaticSize.X
jobsBtn.BackgroundColor3       = C.Amber
jobsBtn.BackgroundTransparency = 0.86
jobsBtn.AutoButtonColor        = false
jobsBtn.FontFace               = FF.Bold
jobsBtn.TextSize               = 13
jobsBtn.TextColor3             = C.Amber
jobsBtn.Text                   = "Jobs [J]"
jobsBtn.LayoutOrder            = 6
jobsBtn.Parent                 = bar
UITheme.Corner(jobsBtn, UITheme.Radius.Pill)
UITheme.Stroke(jobsBtn, C.Amber, 1, 0.6)
UITheme.Pad(jobsBtn, 0, 14)
jobsBtn.MouseButton1Click:Connect(function()
	ClientSignals.JobBoardToggle:Fire()
end)

Remotes.JobQueue.OnClientEvent:Connect(function(data: any)
	if type(data) ~= "table" then return end
	local waiting = if type(data.jobs) == "table" then #data.jobs else 0
	local free = data.busy ~= true
	jobsBtn.Text = if waiting > 0 then ("Jobs · %d  [J]"):format(waiting) else "Jobs [J]"
	-- Lit up when customers are waiting and you're free to take one.
	jobsBtn.BackgroundTransparency = if waiting > 0 and free then 0 else 0.86
	jobsBtn.TextColor3 = if waiting > 0 and free then C.Glass else C.Amber
end)

type Rent = { bay: string, perMinute: number, nextCharge: number, strikes: number, inspectAt: number? }
local rent: Rent? = nil
local money = 0
local hasJob = false
local customerName = ""
local armedAt: number? = nil

Remotes.TonyStatus.OnClientEvent:Connect(function(status: any)
	if type(status) ~= "table" then return end
	local r = status.rent
	if type(r) == "table" and type(r.bay) == "string"
		and type(r.perMinute) == "number" and type(r.nextCharge) == "number" then
		rent = {
			bay = r.bay, perMinute = r.perMinute, nextCharge = r.nextCharge,
			strikes = if type(r.strikes) == "number" then r.strikes else 0,
			inspectAt = if type(r.inspectAt) == "number" then r.inspectAt else nil,
		}
	else
		rent = nil
	end
	bar.Visible = rent ~= nil
end)

Remotes.MoneyUpdated.OnClientEvent:Connect(function(total: any)
	if type(total) == "number" then money = total end
end)

Remotes.JobUpdated.OnClientEvent:Connect(function(job: any)
	hasJob = type(job) == "table"
	customerName = if hasJob and type(job.customerName) == "string" then job.customerName else ""
end)

local function countdown(r: Rent): string
	local left = math.max(0, math.ceil(r.nextCharge - Workspace:GetServerTimeNow()))
	return ("%d:%02d"):format(left // 60, left % 60)
end

-- Every frame: the countdowns, the "can't cover it" warning, the confirm text.
RunService.RenderStepped:Connect(function()
	local r = rent
	if not r then
		for _, rate in pairs(markerRates) do rate.Visible = false end
		return
	end
	local short = money < r.perMinute
	local time = countdown(r)

	bayLabel.Text = "Bay " .. r.bay
	if armedAt then
		rateLabel.Text = ""
		timeLabel.Text = if hasJob then ("Cancels %s's job"):format(customerName) else "Give the bay back?"
		timeLabel.FontFace = FF.Bold
		timeLabel.TextColor3 = C.BadText
		timeLabel.Size = UDim2.new(0, 180, 1, 0)
	else
		rateLabel.Text = ("$%d/min"):format(r.perMinute)
		timeLabel.Text = if short then "on tab in " .. time else "next " .. time
		timeLabel.FontFace = FF.Mono
		timeLabel.TextColor3 = if short then C.BadText else C.GlassMuted
		timeLabel.Size = UDim2.new(0, 130, 1, 0)
	end
	strikesLabel.Visible = r.strikes > 0 and not armedAt
	strikesLabel.Text = ("Late %s"):format(string.rep("●", r.strikes) .. string.rep("○", math.max(0, MAX_STRIKES - r.strikes)))
	local inspectAt = r.inspectAt
	inspectLabel.Visible = inspectAt ~= nil and not armedAt
	if inspectAt then
		local left = math.max(0, math.ceil(inspectAt - Workspace:GetServerTimeNow()))
		inspectLabel.Text = ("Inspection %d:%02d"):format(left // 60, left % 60)
	end
	bar.BackgroundColor3 = if short then Color3.fromHex("280E0E") else C.Glass
	barStroke.Color = if short then C.Bad else Color3.new(1, 1, 1)
	barStroke.Transparency = if short then 0.4 else 0.92

	for _, rate in pairs(markerRates) do
		rate.Visible = true
		rate.Text = ("$%d/min · %s"):format(r.perMinute, time)
		rate.TextColor3 = if short then C.BadText else C.Amber
	end
end)

-- HAND BACK KEYS needs a second click within CONFIRM_TIME seconds.
local function resetKeys()
	armedAt = nil
	keysBtn.Text = "Hand back keys"
	keysBtn.BackgroundTransparency = 0.86
	keysBtn.TextColor3 = C.BadText
end

keysBtn.MouseButton1Click:Connect(function()
	if armedAt and os.clock() - armedAt <= CONFIRM_TIME then
		resetKeys()
		Remotes.ReleaseBay:FireServer()
		return
	end
	armedAt = os.clock()
	local mine = armedAt
	keysBtn.BackgroundTransparency = 0
	keysBtn.TextColor3 = C.GlassText
	for remaining = CONFIRM_TIME, 1, -1 do
		if armedAt ~= mine then return end
		keysBtn.Text = ("Click again · %d"):format(remaining)
		task.wait(1)
	end
	if armedAt == mine then resetKeys() end
end)

Remotes.RequestMoney:FireServer() -- the money we start with (for the red countdown)
