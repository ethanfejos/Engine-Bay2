--!strict
--[[
    JobUI (LocalScript)
    -------------------
    The work order (top left) while you have a customer job — a sheet of
    paper on a clipboard (UI "Option D": paper, because the customer wrote
    it). JobService sends it on JobUpdated; nil hides it.

    - WORK ORDER and a stopwatch (red once the job stops counting as quick)
    - the customer's picture, name, car, and the pay in red marker
    - a stamp of what kind of customer they are (REGULAR, CHEAPSKATE,
      FUSSY, RUSH JOB, RICH) and their patience: a bar that drains, and the
      time left — when it runs out they leave
    - what they asked for, typed
    - the checklist: faults get a green marker tick and are crossed out once
      fixed and back in the car; "Put back: ..." while other parts are out
    - when everything's done: a green DONE stamp and "E  Hand the car back
      to <name>"
    - CANCEL JOB: the first click shows what it costs (Tony's fine and the
      stars you'd lose); a second click within a few seconds confirms
    - hidden while you're at the workbench (its panels use that side)
    - the arrow tab on the clipboard folds it up to just its header
      ("WORK ORDER · 1/2 · $40" and the stopwatch) and opens it again
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local ClientSignals = require(Shared:WaitForChild("Modules"):WaitForChild("ClientSignals"))
local UITheme = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, FF   = UITheme.Colors, UITheme.Faces

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Config ────────────────────────────────────────────────────────────────────

local WIDTH        = 296
local MARGIN_X     = 20
local MARGIN_Y     = 18
local CONFIRM_TIME = 3 -- seconds the "click again to cancel" state lasts
local STAMP_IN     = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- ── Build ─────────────────────────────────────────────────────────────────────

local screen          = Instance.new("ScreenGui")
screen.Name           = "JobUI"
screen.ResetOnSpawn   = false
screen.Parent         = playerGui

-- The clipboard board
local board                  = Instance.new("Frame")
board.Name                   = "Clipboard"
board.Position               = UDim2.new(0, MARGIN_X, 0, MARGIN_Y + 8)
board.Size                   = UDim2.new(0, WIDTH, 0, 0)
board.AutomaticSize          = Enum.AutomaticSize.Y
board.BackgroundColor3       = C.Wood
board.BorderSizePixel        = 0
board.Visible                = false
board.Parent                 = screen
UITheme.Corner(board, UDim.new(0, 10))
local boardPad = UITheme.Pad(board, 9)
boardPad.PaddingTop = UDim.new(0, 28)

local clip                  = Instance.new("Frame")
clip.AnchorPoint            = Vector2.new(0.5, 0)
clip.Position               = UDim2.new(0.5, 0, 0, -36) -- above the padding, poking over the top edge
clip.Size                   = UDim2.new(0, 100, 0, 26)
clip.BackgroundColor3       = C.Clip
clip.ZIndex                 = 3
clip.Parent                 = board
UITheme.Corner(clip, UDim.new(0, 6))
UITheme.Stroke(clip, C.ClipEdge, 2)

-- Fold tab: a little tab on the board's top-right corner
local foldBtn                  = Instance.new("TextButton")
foldBtn.AnchorPoint            = Vector2.new(1, 0)
foldBtn.Position               = UDim2.new(1, 0, 0, -24)
foldBtn.Size                   = UDim2.new(0, 30, 0, 18)
foldBtn.BackgroundColor3       = C.SheetInk
foldBtn.BackgroundTransparency = 0.75
foldBtn.AutoButtonColor        = true
foldBtn.Font                   = Enum.Font.GothamBold -- has the ▲▼ arrows
foldBtn.Text                   = "▲"
foldBtn.TextSize               = 11
foldBtn.TextColor3             = C.Sheet
foldBtn.ZIndex                 = 4
foldBtn.Parent                 = board
UITheme.Corner(foldBtn, UDim.new(0, 5))

-- The sheet
local sheet                  = Instance.new("Frame")
sheet.Size                   = UDim2.new(1, 0, 0, 0)
sheet.AutomaticSize          = Enum.AutomaticSize.Y
sheet.Parent                 = board
UITheme.Paper(sheet, 0)
UITheme.Pad(sheet, 12)
UITheme.List(sheet, 9)

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

-- Header: WORK ORDER ........ ⏱ 2:14, underlined
local header                  = Instance.new("Frame")
header.Size                   = UDim2.new(1, 0, 0, 24)
header.BackgroundTransparency = 1
header.LayoutOrder            = nextOrder()
header.Parent                 = sheet
local title = UITheme.Text(header, "WORK ORDER", FF.Heavy, 15, C.SheetInk)
title.Size = UDim2.new(1, 0, 0, 20)
local timer = UITheme.Text(header, "", FF.Type, 13, C.SheetInk)
timer.Size = UDim2.new(1, 0, 0, 20)
timer.TextXAlignment = Enum.TextXAlignment.Right
local rule                  = Instance.new("Frame")
rule.Position               = UDim2.new(0, 0, 1, -2)
rule.Size                   = UDim2.new(1, 0, 0, 2)
rule.BackgroundColor3       = C.SheetInk
rule.BorderSizePixel        = 0
rule.Parent                 = header

-- Customer row: photo, name + car, pay
local customerRow                  = Instance.new("Frame")
customerRow.Size                   = UDim2.new(1, 0, 0, 40)
customerRow.BackgroundTransparency = 1
customerRow.LayoutOrder            = nextOrder()
customerRow.Parent                 = sheet

local photo                  = Instance.new("ImageLabel")
photo.Size                   = UDim2.new(0, 38, 0, 38)
photo.BackgroundColor3       = Color3.fromHex("D6DCE4")
photo.BorderSizePixel        = 0
photo.Image                  = ""
photo.Parent                 = customerRow
UITheme.Stroke(photo, C.SheetInk, 2)
local initial = UITheme.Text(photo, "", FF.Heavy, 18, C.SheetInk)
initial.Size = UDim2.fromScale(1, 1)
initial.TextXAlignment = Enum.TextXAlignment.Center

local nameLabel = UITheme.Text(customerRow, "", FF.Type, 15, C.SheetInk)
nameLabel.Position = UDim2.new(0, 46, 0, 1)
nameLabel.Size = UDim2.new(1, -98, 0, 18)
nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
local carLabel = UITheme.Text(customerRow, "", FF.Type, 12, C.SheetMuted)
carLabel.Position = UDim2.new(0, 46, 0, 20)
carLabel.Size = UDim2.new(1, -98, 0, 16)
carLabel.TextScaled = true -- long car names shrink to fit rather than cut off
local carSize = Instance.new("UITextSizeConstraint")
carSize.MaxTextSize = 12
carSize.MinTextSize = 9
carSize.Parent = carLabel
carLabel.TextTruncate = Enum.TextTruncate.AtEnd

local payLabel = UITheme.Text(customerRow, "", FF.Marker, 24, C.Marker)
payLabel.AnchorPoint = Vector2.new(1, 0.5)
payLabel.Position = UDim2.new(1, 0, 0.5, 0)
payLabel.Size = UDim2.new(0, 50, 1, 0)
payLabel.TextXAlignment = Enum.TextXAlignment.Right
payLabel.Rotation = -4

-- Customer type stamp + patience bar + time left
local patienceRow                  = Instance.new("Frame")
patienceRow.Size                   = UDim2.new(1, 0, 0, 20)
patienceRow.BackgroundTransparency = 1
patienceRow.LayoutOrder            = nextOrder()
patienceRow.Parent                 = sheet

local typeStamp                  = Instance.new("TextLabel")
typeStamp.AnchorPoint            = Vector2.new(0, 0.5)
typeStamp.Position               = UDim2.new(0, 2, 0.5, 0)
typeStamp.Size                   = UDim2.new(0, 0, 0, 16)
typeStamp.AutomaticSize          = Enum.AutomaticSize.X
typeStamp.BackgroundTransparency = 1
typeStamp.FontFace               = FF.Heavy
typeStamp.TextSize               = 10
typeStamp.TextColor3             = C.SheetInk
typeStamp.Rotation               = -3
typeStamp.Text                   = "REGULAR"
typeStamp.Parent                 = patienceRow
UITheme.Pad(typeStamp, 0, 5)
local typeStroke = UITheme.Stroke(typeStamp, C.SheetInk, 2)

local patienceTrack                  = Instance.new("Frame")
patienceTrack.AnchorPoint            = Vector2.new(0, 0.5)
patienceTrack.Position               = UDim2.new(0, 96, 0.5, 0)
patienceTrack.Size                   = UDim2.new(1, -96 - 46, 0, 10)
patienceTrack.BackgroundColor3       = Color3.new(1, 1, 1)
patienceTrack.BorderSizePixel        = 0
patienceTrack.Parent                 = patienceRow
UITheme.Stroke(patienceTrack, C.SheetInk, 2)
local patienceFill            = Instance.new("Frame")
patienceFill.Size             = UDim2.new(1, 0, 1, 0)
patienceFill.BackgroundColor3 = C.MarkerGreen
patienceFill.BorderSizePixel  = 0
patienceFill.Parent           = patienceTrack

local patienceText = UITheme.Text(patienceRow, "", FF.Type, 12, C.SheetInk)
patienceText.AnchorPoint = Vector2.new(1, 0)
patienceText.Position = UDim2.new(1, 0, 0, 0)
patienceText.Size = UDim2.new(0, 42, 1, 0)
patienceText.TextXAlignment = Enum.TextXAlignment.Right

-- What the stamp looks like for each kind of customer.
local TYPE_INK: { [string]: Color3 } = {
	regular    = C.SheetInk,
	cheapskate = C.SheetMuted,
	fussy      = Color3.fromHex("6A4C93"),
	rush       = C.Marker,
	rich       = C.MarkerGreen,
}

-- What they asked for
local requestLabel = UITheme.Text(sheet, "", FF.Type, 13, Color3.fromHex("3A3832"))
requestLabel.Size = UDim2.new(1, 0, 0, 0)
requestLabel.AutomaticSize = Enum.AutomaticSize.Y
requestLabel.TextWrapped = true
requestLabel.LayoutOrder = nextOrder()

-- Checklist
local taskList                  = Instance.new("Frame")
taskList.Size                   = UDim2.new(1, 0, 0, 0)
taskList.AutomaticSize          = Enum.AutomaticSize.Y
taskList.BackgroundTransparency = 1
taskList.LayoutOrder            = nextOrder()
taskList.Parent                 = sheet
UITheme.List(taskList, 6)

-- Done: hand it back
local handBack                  = Instance.new("Frame")
handBack.Size                   = UDim2.new(1, 0, 0, 36)
handBack.BackgroundColor3       = Color3.new(1, 1, 1)
handBack.BorderSizePixel        = 0
handBack.LayoutOrder            = nextOrder()
handBack.Visible                = false
handBack.Parent                 = sheet
UITheme.Stroke(handBack, C.SheetInk, 2)
local keyTile = UITheme.Text(handBack, "E", FF.Heavy, 13, C.Sheet)
keyTile.Position = UDim2.new(0, 8, 0.5, -11)
keyTile.Size = UDim2.new(0, 22, 0, 22)
keyTile.TextXAlignment = Enum.TextXAlignment.Center
keyTile.BackgroundColor3 = C.SheetInk
keyTile.BackgroundTransparency = 0
local handBackLabel = UITheme.Text(handBack, "", FF.Heavy, 13, C.SheetInk)
handBackLabel.Position = UDim2.new(0, 40, 0, 0)
handBackLabel.Size = UDim2.new(1, -46, 1, 0)
handBackLabel.TextTruncate = Enum.TextTruncate.AtEnd

-- Cancel: the button, and the warning shown on the first click
local warning                  = Instance.new("Frame")
warning.Size                   = UDim2.new(1, 0, 0, 0)
warning.AutomaticSize          = Enum.AutomaticSize.Y
warning.BackgroundTransparency = 1
warning.LayoutOrder            = nextOrder()
warning.Visible                = false
warning.Parent                 = sheet
UITheme.Stroke(warning, C.Marker, 2)
UITheme.Pad(warning, 8, 10)
local warningText = UITheme.Text(warning, "", FF.Type, 13, C.Marker)
warningText.Size = UDim2.new(1, 0, 0, 0)
warningText.AutomaticSize = Enum.AutomaticSize.Y
warningText.TextWrapped = true
warningText.RichText = true

local cancelBtn                  = Instance.new("TextButton")
cancelBtn.Size                   = UDim2.new(0, 0, 0, 24)
cancelBtn.AutomaticSize          = Enum.AutomaticSize.X
cancelBtn.BackgroundColor3       = C.Marker
cancelBtn.BackgroundTransparency = 1
cancelBtn.AutoButtonColor        = false
cancelBtn.FontFace               = FF.Heavy
cancelBtn.Text                   = "CANCEL JOB"
cancelBtn.TextSize               = 11
cancelBtn.TextColor3             = C.SheetInk
cancelBtn.LayoutOrder            = nextOrder()
cancelBtn.Parent                 = sheet
local cancelStroke = UITheme.Stroke(cancelBtn, C.SheetInk, 2)
UITheme.Pad(cancelBtn, 0, 10)

-- DONE stamp, thumped over the sheet's top right (on the board, so the
-- sheet's list layout doesn't move it)
local doneStamp                  = Instance.new("TextLabel")
doneStamp.AnchorPoint            = Vector2.new(1, 0)
doneStamp.Position               = UDim2.new(1, -18, 0, 62)
doneStamp.Size                   = UDim2.new(0, 0, 0, 30)
doneStamp.AutomaticSize          = Enum.AutomaticSize.X
doneStamp.BackgroundTransparency = 1
doneStamp.FontFace               = FF.Heavy
doneStamp.Text                   = "DONE"
doneStamp.TextSize               = 22
doneStamp.TextColor3             = C.MarkerGreen
doneStamp.TextTransparency       = 0.1
doneStamp.Rotation               = -12
doneStamp.ZIndex                 = 4
doneStamp.Visible                = false
doneStamp.Parent                 = board
UITheme.Pad(doneStamp, 0, 10)
UITheme.Stroke(doneStamp, C.MarkerGreen, 3, 0.1)
local doneScale = Instance.new("UIScale")
doneScale.Parent = doneStamp

-- ── Showing a job ─────────────────────────────────────────────────────────────

type Task = { label: string, done: boolean }

local shownUserId: number? = nil
local deadline: number? = nil
local patienceTotal = 600
local hasJob = false
local atBench = false
local folded = false
local lastTasks: { Task } = {}
local lastPay = 0
local isComplete = false
local startedAt: number? = nil
local quickSeconds = 300
local customerName = "Customer"
local fine, stars = 0, 0
local wasComplete = false

local function setPhoto(userId: number?, name: string)
	initial.Text = string.upper(string.sub(name, 1, 1))
	if userId == shownUserId then return end
	shownUserId = userId
	photo.Image = ""
	initial.Visible = true
	if not userId or userId <= 0 then return end
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and type(image) == "string" and shownUserId == userId then
			photo.Image, initial.Visible = image, false
		end
	end)
end

-- One checklist line: a box (ticked in green marker when done) and the label.
local function taskRow(t: Task, i: number)
	local row                  = Instance.new("Frame")
	row.Size                   = UDim2.new(1, 0, 0, 18)
	row.BackgroundTransparency = 1
	row.LayoutOrder            = i
	row.Parent                 = taskList

	local putBack = string.sub(t.label, 1, 9) == "Put back:"
	local box                  = Instance.new("Frame")
	box.Position               = UDim2.new(0, 1, 0.5, -7)
	box.Size                   = UDim2.new(0, 14, 0, 14)
	box.BackgroundTransparency = 1
	box.Parent                 = row
	UITheme.Stroke(box, if putBack then C.Marker else C.SheetInk, 2)

	if t.done then
		local tick = UITheme.Text(box, "✓", FF.Marker, 22, C.MarkerGreen)
		tick.Position = UDim2.new(0, -2, 0, -12)
		tick.Size = UDim2.new(0, 24, 0, 28)
	end

	local label = UITheme.Text(row, t.label, FF.Type, 14, if putBack then C.Marker else C.SheetInk)
	label.Position = UDim2.new(0, 24, 0, 0)
	label.Size = UDim2.new(1, -24, 1, 0)
	label.TextTruncate = Enum.TextTruncate.AtEnd
	if t.done then
		label.RichText = true
		label.Text = "<s>" .. t.label .. "</s>"
		label.TextColor3 = C.SheetMuted
	end
end

local function setTasks(tasks: { Task })
	for _, child in ipairs(taskList:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	for i, t in ipairs(tasks) do
		taskRow(t, i)
	end
end

local armedAt: number? = nil

local function resetCancel()
	armedAt = nil
	warning.Visible = false
	cancelBtn.Text = "CANCEL JOB"
	cancelBtn.BackgroundTransparency = 1
	cancelBtn.TextColor3 = C.SheetInk
	cancelStroke.Color = C.SheetInk
end

-- Folded: just the header. Open: everything for the current state.
local function applyFold()
	foldBtn.Text = if folded then "▼" else "▲"
	customerRow.Visible  = not folded
	patienceRow.Visible  = not folded
	requestLabel.Visible = not folded
	taskList.Visible     = not folded
	cancelBtn.Visible    = not folded
	handBack.Visible     = not folded and isComplete
	doneStamp.Visible    = not folded and isComplete
	warning.Visible      = not folded and armedAt ~= nil
	if folded then
		local done = 0
		for _, t in ipairs(lastTasks) do
			if t.done then done += 1 end
		end
		title.Text = ("WORK ORDER · %d/%d · %s"):format(done, #lastTasks, UITheme.Money(lastPay))
		title.TextColor3 = if isComplete then C.MarkerGreen else C.SheetInk
		title.TextSize = 13
	else
		title.TextSize = 15
		title.Text = "WORK ORDER"
		title.TextColor3 = C.SheetInk
	end
end

foldBtn.MouseButton1Click:Connect(function()
	folded = not folded
	applyFold()
end)

local function setComplete(complete: boolean)
	isComplete = complete
	handBack.Visible = complete and not folded
	doneStamp.Visible = complete and not folded
	if complete and not wasComplete then
		doneScale.Scale = 1.8
		TweenService:Create(doneScale, STAMP_IN, { Scale = 1 }):Play()
	end
	wasComplete = complete
end

Remotes.JobUpdated.OnClientEvent:Connect(function(job: any)
	if type(job) ~= "table" then
		hasJob = false
		board.Visible = false
		startedAt = nil
		wasComplete = false
		resetCancel()
		return
	end
	customerName      = if type(job.customerName) == "string" then job.customerName else "Customer"
	nameLabel.Text    = customerName
	carLabel.Text     = if type(job.car) == "string" then job.car else ""
	payLabel.Text     = UITheme.Money(tonumber(job.pay) or 0)
	requestLabel.Text = if type(job.request) == "string" then "\u{201C}" .. job.request .. "\u{201D}" else ""
	setPhoto(if type(job.customerUserId) == "number" then job.customerUserId else nil, customerName)
	startedAt    = if type(job.startedAt) == "number" then job.startedAt else nil
	deadline     = if type(job.deadline) == "number" then job.deadline else nil
	patienceTotal = math.max(1, tonumber(job.patience) or 600)
	local kind = if type(job.customerKind) == "string" then job.customerKind else "regular"
	typeStamp.Text = if type(job.customerType) == "string" then job.customerType else "REGULAR"
	if job.repeatVisit == true then typeStamp.Text ..= " · REPEAT" end
	typeStamp.TextColor3 = TYPE_INK[kind] or C.SheetInk
	typeStroke.Color = typeStamp.TextColor3
	quickSeconds = tonumber(job.quickSeconds) or 300
	fine         = tonumber(job.cancelFine) or 0
	stars        = tonumber(job.cancelStars) or 0

	local tasks: { Task } = {}
	if type(job.tasks) == "table" then
		for _, t in ipairs(job.tasks) do
			if type(t) == "table" and type(t.label) == "string" then
				table.insert(tasks, { label = t.label, done = t.done == true })
			end
		end
	end
	setTasks(tasks)
	lastTasks = tasks
	lastPay = tonumber(job.pay) or 0
	handBackLabel.Text = "Hand the car back to " .. customerName
	setComplete(job.complete == true)
	applyFold()
	hasJob = true
	board.Visible = not atBench
end)

-- The stopwatch.
RunService.RenderStepped:Connect(function()
	local started = startedAt
	if not board.Visible or not started then
		timer.Text = ""
		return
	end
	local now = Workspace:GetServerTimeNow()
	local elapsed = math.max(0, math.floor(now - started))
	timer.Text = ("⏱ %d:%02d"):format(elapsed // 60, elapsed % 60)
	timer.TextColor3 = if elapsed > quickSeconds then C.Marker else C.SheetInk

	-- Patience drains towards the customer walking out.
	local due = deadline
	if due then
		local secondsLeft = math.max(0, math.ceil(due - now))
		local share = math.clamp((due - now) / patienceTotal, 0, 1)
		patienceFill.Size = UDim2.new(share, 0, 1, 0)
		patienceFill.BackgroundColor3 = if share > 0.5 then C.MarkerGreen elseif share > 0.25 then C.TonyTab else C.Marker
		patienceText.Text = ("%d:%02d"):format(secondsLeft // 60, secondsLeft % 60)
		patienceText.TextColor3 = if share > 0.25 then C.SheetInk else C.Marker
	end
end)

-- Cancel: the first click shows the cost, a second within CONFIRM_TIME confirms.
cancelBtn.MouseButton1Click:Connect(function()
	if armedAt and os.clock() - armedAt <= CONFIRM_TIME then
		resetCancel()
		Remotes.CancelJob:FireServer()
		return
	end
	armedAt = os.clock()
	local mine = armedAt
	warning.Visible = true
	warningText.Text = ("<b>Cancel this job?</b>\nTony fines you %s and you lose %s stars."):format(
		UITheme.Money(fine), tostring(stars))
	cancelBtn.BackgroundTransparency = 0
	cancelBtn.TextColor3 = C.Sheet
	cancelStroke.Color = C.SheetInk
	for remaining = CONFIRM_TIME, 1, -1 do
		if armedAt ~= mine then return end
		cancelBtn.Text = ("CLICK AGAIN TO CANCEL · %d"):format(remaining)
		task.wait(1)
	end
	if armedAt == mine then resetCancel() end
end)

-- Out of the way while you're at the workbench.
ClientSignals.WorkbenchViewChanged:Connect(function(active: any)
	atBench = active == true
	board.Visible = hasJob and not atBench
end)
