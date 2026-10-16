--!strict
--[[
    JobUI (LocalScript)
    -------------------
    The work order panel (top left) while you have a customer job
    (JobService sends it on JobUpdated; nil hides the panel):

    - the customer's picture and name (one of your friends), and the pay
    - what they asked for
    - the checklist: each fault ticks off once it's fixed and back in the
      car; "Put back: ..." appears while other parts are out
    - when everything's done: "Hand the car back to <name>"
    - CANCEL JOB — needs a second click within a few seconds to confirm
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Modules"):WaitForChild("Remotes"))
local UITheme = require(Shared:WaitForChild("UI"):WaitForChild("UITheme"))
local C, F    = UITheme.Colors, UITheme.Fonts

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Config ────────────────────────────────────────────────────────────────────

local WIDTH          = 290
local MARGIN         = 20
local ROW_H          = 20
local CONFIRM_TIME   = 3 -- seconds the "click again to cancel" state lasts

-- ── Build ─────────────────────────────────────────────────────────────────────

local screen          = Instance.new("ScreenGui")
screen.Name           = "JobUI"
screen.ResetOnSpawn   = false
screen.Parent         = playerGui

local panel                  = Instance.new("Frame")
panel.Position               = UDim2.new(0, MARGIN, 0, MARGIN)
panel.Size                   = UDim2.new(0, WIDTH, 0, 0)
panel.AutomaticSize          = Enum.AutomaticSize.Y
panel.BackgroundColor3       = C.Dark
panel.BackgroundTransparency = 0.2
panel.Visible                = false
panel.Parent                 = screen
UITheme.Corner(panel, UITheme.Radius.Large)

local padding         = Instance.new("UIPadding")
padding.PaddingTop    = UDim.new(0, 10)
padding.PaddingBottom = UDim.new(0, 10)
padding.PaddingLeft   = UDim.new(0, 12)
padding.PaddingRight  = UDim.new(0, 12)
padding.Parent        = panel

local layout     = Instance.new("UIListLayout")
layout.Padding   = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent    = panel

local function label(text: string, size: number, color: Color3, bold: boolean, order: number): TextLabel
	local l                  = Instance.new("TextLabel")
	l.Size                   = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize          = Enum.AutomaticSize.Y
	l.BackgroundTransparency = 1
	l.Font                   = if bold then F.Bold else F.Regular
	l.Text                   = text
	l.TextSize               = size
	l.TextColor3             = color
	l.TextWrapped            = true
	l.TextXAlignment         = Enum.TextXAlignment.Left
	l.LayoutOrder            = order
	l.Parent                 = panel
	return l
end

label("WORK ORDER", 12, C.TextMuted, true, 1)

-- Customer row: picture, name, pay
local customerRow                  = Instance.new("Frame")
customerRow.Size                   = UDim2.new(1, 0, 0, 40)
customerRow.BackgroundTransparency = 1
customerRow.LayoutOrder            = 2
customerRow.Parent                 = panel

local headshot                  = Instance.new("ImageLabel")
headshot.Size                   = UDim2.new(0, 40, 0, 40)
headshot.BackgroundColor3       = C.Track
headshot.Image                  = ""
headshot.Parent                 = customerRow
UITheme.Corner(headshot, UITheme.Radius.Pill)

local nameLabel                  = Instance.new("TextLabel")
nameLabel.Position               = UDim2.new(0, 50, 0, 0)
nameLabel.Size                   = UDim2.new(1, -120, 1, 0)
nameLabel.BackgroundTransparency = 1
nameLabel.Font                   = F.Bold
nameLabel.TextSize               = 16
nameLabel.TextColor3             = C.Text
nameLabel.TextXAlignment         = Enum.TextXAlignment.Left
nameLabel.TextTruncate           = Enum.TextTruncate.AtEnd
nameLabel.Parent                 = customerRow

local payLabel                  = Instance.new("TextLabel")
payLabel.AnchorPoint            = Vector2.new(1, 0)
payLabel.Position               = UDim2.new(1, 0, 0, 0)
payLabel.Size                   = UDim2.new(0, 70, 1, 0)
payLabel.BackgroundTransparency = 1
payLabel.Font                   = F.Bold
payLabel.TextSize               = 16
payLabel.TextColor3             = C.Money
payLabel.TextXAlignment         = Enum.TextXAlignment.Right
payLabel.Parent                 = customerRow

local requestLabel = label("", 13, C.TextDim, false, 3)

local taskList                  = Instance.new("Frame")
taskList.Size                   = UDim2.new(1, 0, 0, 0)
taskList.AutomaticSize          = Enum.AutomaticSize.Y
taskList.BackgroundTransparency = 1
taskList.LayoutOrder            = 4
taskList.Parent                 = panel
local taskLayout     = Instance.new("UIListLayout")
taskLayout.Padding   = UDim.new(0, 2)
taskLayout.SortOrder = Enum.SortOrder.LayoutOrder
taskLayout.Parent    = taskList

local statusLabel = label("", 13, C.Accent, true, 5)

local cancelBtn                  = Instance.new("TextButton")
cancelBtn.Size                   = UDim2.new(1, 0, 0, 22)
cancelBtn.BackgroundColor3       = C.Danger
cancelBtn.BackgroundTransparency = 0.6
cancelBtn.AutoButtonColor        = false
cancelBtn.Font                   = F.Bold
cancelBtn.Text                   = "CANCEL JOB"
cancelBtn.TextSize               = 11
cancelBtn.TextColor3             = C.Text
cancelBtn.LayoutOrder            = 6
cancelBtn.Parent                 = panel
UITheme.Corner(cancelBtn)

-- ── Showing a job ─────────────────────────────────────────────────────────────

type Task = { label: string, done: boolean }

local shownUserId: number? = nil

local function setHeadshot(userId: number?)
	if userId == shownUserId then return end
	shownUserId = userId
	headshot.Image = ""
	if not userId or userId <= 0 then return end
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and shownUserId == userId then
			headshot.Image = image
		end
	end)
end

local function setTasks(tasks: { Task })
	for _, child in ipairs(taskList:GetChildren()) do
		if child:IsA("TextLabel") then child:Destroy() end
	end
	for i, t in ipairs(tasks) do
		local row                  = Instance.new("TextLabel")
		row.Size                   = UDim2.new(1, 0, 0, ROW_H)
		row.BackgroundTransparency = 1
		row.Font                   = if t.done then F.Bold else F.Regular
		row.Text                   = (if t.done then "✓  " else "○  ") .. t.label
		row.TextSize               = 14
		row.TextColor3             = if t.done then C.Accent else C.Text
		row.TextXAlignment         = Enum.TextXAlignment.Left
		row.TextTruncate           = Enum.TextTruncate.AtEnd
		row.LayoutOrder            = i
		row.Parent                 = taskList
	end
end

local armedAt: number? = nil

local function resetCancel()
	armedAt = nil
	cancelBtn.Text = "CANCEL JOB"
	cancelBtn.BackgroundTransparency = 0.6
end

Remotes.JobUpdated.OnClientEvent:Connect(function(job: any)
	if type(job) ~= "table" then
		panel.Visible = false
		resetCancel()
		return
	end
	local name = if type(job.customerName) == "string" then job.customerName else "Customer"
	nameLabel.Text    = name
	payLabel.Text     = "$" .. tostring(tonumber(job.pay) or 0)
	requestLabel.Text = if type(job.request) == "string" then "\u{201C}" .. job.request .. "\u{201D}" else ""
	setHeadshot(if type(job.customerUserId) == "number" then job.customerUserId else nil)

	local tasks: { Task } = {}
	if type(job.tasks) == "table" then
		for _, t in ipairs(job.tasks) do
			if type(t) == "table" and type(t.label) == "string" then
				table.insert(tasks, { label = t.label, done = t.done == true })
			end
		end
	end
	setTasks(tasks)
	statusLabel.Text = if job.complete == true then ("All done: hand the car back to " .. name) else ""
	statusLabel.Visible = job.complete == true
	panel.Visible = true
end)

-- Cancel needs a second click within CONFIRM_TIME seconds.
cancelBtn.MouseButton1Click:Connect(function()
	if armedAt and os.clock() - armedAt <= CONFIRM_TIME then
		resetCancel()
		Remotes.CancelJob:FireServer()
		return
	end
	armedAt = os.clock()
	local mine = armedAt
	cancelBtn.BackgroundTransparency = 0.15
	for remaining = CONFIRM_TIME, 1, -1 do
		if armedAt ~= mine then return end
		cancelBtn.Text = ("CLICK AGAIN TO CANCEL (%d)"):format(remaining)
		task.wait(1)
	end
	if armedAt == mine then resetCancel() end
end)
