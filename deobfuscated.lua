local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CAR_FOLDER_NAME = "$cars"
local PLACEABLES_NAME = "%Placeables"

local raceDurations = {
	["Area 52 Quarter Mile"] = 5.2,
	["Around The World"] = 47.1,
	["City Mania"] = 34,
	["Dam Dash"] = 33.4,
	["Dock Quarter Mile"] = 5.3,
	["Downtown Race"] = 43.4,
	["Frenzy Race"] = 53.2,
	["Into the Mountains"] = 81.2,
	["King's Race"] = 75.4,
	["Madness City Race"] = 45,
	["Main Street Drag Race"] = 7.5,
	["Northern Rally"] = 75.6,
	["Shipyard Sprint"] = 19.5,
	["South City Loop"] = 68.5,
	["The Grand Race"] = 150,
	["Trespasser's Dash"] = 51.5,
	["Wall of Death"] = 25,
}

local settings = {
	VehicleName = "MegaBox",
	Delay = 0.1,
	DebugMode = false,
	ForwardNudge = true,
	AutoReset = true,
	ShowFPS = false,
	OffsetY = 15,
}

local selectedRace = nil
local selectedTime = nil

local running = false
local startTime = nil
local teleportThread = nil
local logLines = {}
local MAX_LOG_LINES = 300

local function clamp(n, a, b) return math.max(a, math.min(b, n)) end
local function pushLog(msg)
	local ts = os.date("%X")
	local line = ("[%s] %s"):format(ts, tostring(msg))
	table.insert(logLines, 1, line)
	if #logLines > MAX_LOG_LINES then table.remove(logLines) end
	if settings.DebugMode then print("[Chrona]", line) end
	if DebugRefreshFunc then DebugRefreshFunc() end
end

local function formatTimerHundredths(t)
	if t < 0 then t = 0 end
	local mins = math.floor(t / 60)
	local secs = math.floor(t % 60)
	local hund = math.floor((t - math.floor(t)) * 100)
	return string.format("%d:%02d.%02d", mins, secs, hund)
end

local function getPlaceables() return workspace:FindFirstChild(PLACEABLES_NAME) end
local function getCarFolder() return workspace:FindFirstChild(CAR_FOLDER_NAME) end
local function findVehicleModel()
	local f = getCarFolder()
	if not f then return nil end
	return f:FindFirstChild(settings.VehicleName)
end

local function moveModelTo(model, targetCFrame)
	if not model then return false, "no model" end
	if typeof(model.PivotTo) == "function" then
		local ok, err = pcall(function() model:PivotTo(targetCFrame) end)
		if ok then return true end
		return false, ("PivotTo failed: %s"):format(tostring(err))
	end
	if model.PrimaryPart then
		local ok, err = pcall(function() model:SetPrimaryPartCFrame(targetCFrame) end)
		if ok then return true end
	end
	for _,d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local okSet, _ = pcall(function() model.PrimaryPart = d end)
			if okSet then
				local ok2, _ = pcall(function() model:SetPrimaryPartCFrame(targetCFrame) end)
				if ok2 then return true end
			end
			break
		end
	end
	local okPivot, pivotOrErr = pcall(function() return model:GetModelCFrame() end)
	if not okPivot then return false, ("GetModelCFrame failed: %s"):format(tostring(pivotOrErr)) end
	local currentPivot = pivotOrErr
	local delta = targetCFrame * currentPivot:Inverse()
	local moved = 0
	for _,desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			local ok, _ = pcall(function() desc.CFrame = delta * desc.CFrame end)
			if ok then moved = moved + 1 end
		end
	end
	if moved > 0 then return true end
	return false, "no BaseParts moved"
end

local function findCheckpoint()
	local p = getPlaceables()
	if not p then return nil end
	return p:FindFirstChild("Checkpoint")
end
local function findFinish()
	local p = getPlaceables()
	if not p then return nil end
	return p:FindFirstChild("FinishLine")
end

local FORWARD_NUDGE_STUDS = 2
local FORWARD_NUDGE_TIME = 0.06
local function forwardNudge(model, dirCFrame)
	if not settings.ForwardNudge then return end
	if not model then return end
	local parts = {}
	if model.PrimaryPart then
		table.insert(parts, model.PrimaryPart)
	else
		for _,d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then table.insert(parts, d); if #parts >= 6 then break end end
		end
	end
	if #parts == 0 then return end
	local dir = dirCFrame.LookVector.Unit
	local vel = dir * (FORWARD_NUDGE_STUDS / math.max(0.001, FORWARD_NUDGE_TIME))
	local bvs = {}
	for _,p in ipairs(parts) do
		if p and p:IsA("BasePart") then
			local ok, bv = pcall(function()
				local b = Instance.new("BodyVelocity")
				b.MaxForce = Vector3.new(1e5,1e5,1e5)
				b.Velocity = vel
				b.P = 1000
				b.Parent = p
				return b
			end)
			if ok and bv then table.insert(bvs, bv) end
		end
	end
	spawn(function()
		task.wait(FORWARD_NUDGE_TIME)
		for _,b in ipairs(bvs) do pcall(function() b:Destroy() end) end
		pushLog("Forward nudge applied")
	end)
end

local function teleportToCheckpoint(model)
	local cp = findCheckpoint()
	if not cp then return false, "no checkpoint" end
	local cpPart = cp.PrimaryPart or cp:FindFirstChildWhichIsA("BasePart")
	if not cpPart then return false, "checkpoint missing basepart" end
	local upOffset = Vector3.new(0, settings.OffsetY or 0, 0)
	local targetPos = cpPart.Position + upOffset
	local targetCFrame = CFrame.new(targetPos, targetPos + cpPart.CFrame.LookVector)
	local ok, err = moveModelTo(model, targetCFrame)
	if not ok then return false, err end
	pushLog(("Teleported '%s' to Checkpoint (offset %s)"):format(settings.VehicleName, tostring(settings.OffsetY)))
	return true
end

local function teleportToFinish(model)
	local f = findFinish()
	if not f then return false, "no finish" end
	local fPart = f.PrimaryPart or f:FindFirstChildWhichIsA("BasePart")
	if not fPart then return false, "finish missing basepart" end
	local upOffset = Vector3.new(0, settings.OffsetY or 0, 0)
	local targetPos = fPart.Position + upOffset
	local targetCFrame = CFrame.new(targetPos, targetPos + fPart.CFrame.LookVector)
	local ok, err = moveModelTo(model, targetCFrame)
	if not ok then return false, err end
	pushLog(("Teleported '%s' to Finish (offset %s)"):format(settings.VehicleName, tostring(settings.OffsetY)))
	return true
end

local ok, Rayfield = pcall(function()
	return loadstring(game:HttpGet('https://sirius.menu/rayfield'))()
end)
if not ok or not Rayfield then
	warn("Failed to load Rayfield. Make sure executor allows HTTP and loadstring.")
	return
end

local Window = Rayfield:CreateWindow({
	Name = "Chrona v5",
	LoadingTitle = "Chrona V5",
	LoadingSubtitle = "by @suedbyroblox",
	Theme = "Vaporwave",
	ToggleUIKeybind = "F1",
	ConfigurationSaving = { Enabled = false },
	DisableRayfieldPrompts = true,
})

local RacesTab = Window:CreateTab("Races", 4483362458)
local RacesSection = RacesTab:CreateSection("Available Races (select one)")

local raceNames = {}
for name,_ in pairs(raceDurations) do table.insert(raceNames, name) end
table.sort(raceNames)

local selectedName = nil
local selectedBest = nil

local raceDropdown = RacesTab:CreateDropdown({
	Name = "Choose Race",
	Options = raceNames,
	CurrentOption = raceNames[1],
	Multi = false,
	Callback = function(opt)
		selectedName = opt
		selectedBest = raceDurations[opt]
		Rayfield:Notify({Title="Race Selected", Content = opt.." ("..tostring(selectedBest).."s)", Duration = 3})
		pushLog("Selected race: "..tostring(opt).." ("..tostring(selectedBest).."s)")
	end
})

for _,name in ipairs(raceNames) do
	RacesTab:CreateButton({
		Name = name .. " | Best: " .. tostring(raceDurations[name]) .. "s",
		Callback = function()
			selectedName = name
			selectedBest = raceDurations[name]
			raceDropdown:Set(name)
			Rayfield:Notify({Title="Race Selected", Content = name.." ("..tostring(selectedBest).."s)", Duration = 2})
			pushLog("Selected race (button): "..name)
		end
	})
end
 
local TimerTab = Window:CreateTab("Timer", 4483362458)
local TimerSection = TimerTab:CreateSection("Race Timer")

local goToLabel = TimerTab:CreateLabel("Go To: None")
local timerLabel = TimerTab:CreateLabel("00:00.00")
          
local statusParagraph = TimerTab:CreateParagraph({ Title = "Status: " .. "Idle" })

TimerTab:CreateButton({
	Name = "Start Race",
	Callback = function()
		if not selectedName or not selectedBest then
			Rayfield:Notify({ Title = "No race selected", Content = "Pick a race in the Races tab first.", Duration = 4 })
			return
		end
		if running then
			pushLog("Start pressed but already running")
			return
		end
		local model = findVehicleModel()
		if not model then
			Rayfield:Notify({ Title = "Vehicle missing", Content = "Vehicle '"..settings.VehicleName.."' not found in "..CAR_FOLDER_NAME, Duration = 4 })
			pushLog("Vehicle not found: "..tostring(settings.VehicleName))
			return
		end

		running = true
		startTime = tick()
		goToLabel:Set("Go To: " .. tostring(selectedBest) .. "s")
		statusParagraph:Update({ Content = "Running: " .. selectedName  })

		teleportThread = coroutine.create(function()
			local checkpointMiss = 0
			local finishMiss = 0
			while running do
				local elapsed = tick() - startTime
				timerLabel:Set(formatTimerHundredths(elapsed))

				if elapsed + 1e-6 >= selectedBest then
					pushLog("Target reached; teleporting to FinishLine")
					local f = findFinish()
					if f then
						local ok, err = teleportToFinish(model)
						if not ok then pushLog("Finish teleport error: "..tostring(err)) end
					else
						pushLog("FinishLine not found at target time")
					end
					running = false
					break
				end

				local ok, err = teleportToCheckpoint(model)
				if not ok then
					checkpointMiss = checkpointMiss + 1
					pushLog(("Checkpoint teleport failed (%d/%d): %s"):format(checkpointMiss, MAX_CHECKPOINT_MISS, tostring(err)))
					if checkpointMiss >= MAX_CHECKPOINT_MISS then
						local f = findFinish()
						if f then
							pushLog("Checkpoint missing repeatedly; FinishLine exists. Waiting for target time.")
							while running do
								if tick() - startTime + 1e-6 >= selectedBest then
									local okf, errf = teleportToFinish(model)
									if not okf then pushLog("Finish teleport error: "..tostring(errf)) end
									pushLog("Run ended (finish teleport after missing checkpoints)")
									running = false
									break
								end
								task.wait(0.05)
							end
							break
						else
							finishMiss = finishMiss + 1
							pushLog(("FinishLine not found (%d/%d)."):format(finishMiss, MAX_FINISH_MISS))
							if finishMiss >= MAX_FINISH_MISS then
								pushLog("No FinishLine found after repeated checks. Aborting run.")
								running = false
								break
							end
						end
					end
				else
					checkpointMiss = 0
					finishMiss = 0
				end

				if settings.ForwardNudge then
					local cp = findCheckpoint()
					local dirFrame = nil
					if cp then dirFrame = (cp.PrimaryPart and cp.PrimaryPart.CFrame) or (cp:FindFirstChildWhichIsA("BasePart") and cp:FindFirstChildWhichIsA("BasePart").CFrame) end
					if not dirFrame and model.PrimaryPart then dirFrame = model.PrimaryPart.CFrame end
					if dirFrame then forwardNudge(model, dirFrame) end
				end

				local waited = 0
				while waited < settings.Delay and running do
					task.wait(0.05)
					waited = waited + 0.05
				end
			end
 
			if not running and settings.AutoReset then
				startTime = nil
				timerLabel:Set("00:00.00")
			end
			statusParagraph:Update({ Content = running and "Running" or "Idle" })
		end)

		local okc, cerr = pcall(function() coroutine.resume(teleportThread) end)
		if not okc then
			pushLog("Failed to start teleport coroutine: "..tostring(cerr))
			running = false
			startTime = nil
		end
	end
})

TimerTab:CreateButton({
	Name = "Stop Race",
	Callback = function()
		if not running then
			if settings.AutoReset then timerLabel:Set("00:00.00") end
			pushLog("Stop pressed (not running) - reset")
			return
		end
		running = false
		startTime = nil
		timerLabel:Set("00:00.00")
		statusParagraph:Update({ Content = "Stopped" })
		pushLog("Run stopped by user")
	end
})

local SettingsTab = Window:CreateTab("Settings", 4483362458)
SettingsTab:CreateSection("General Settings")

SettingsTab:CreateInput({
	Name = "Vehicle Name",
	PlaceholderText = "MegaBox",
	CurrentValue = settings.VehicleName,
	RemoveTextAfterFocusLost = false,
	Callback = function(val)
		settings.VehicleName = tostring(val)
		pushLog("Vehicle set to "..tostring(val))
	end
})

SettingsTab:CreateSlider({
	Name = "Checkpoint Delay (s)",
	Range = {0.01, 2},
	Increment = 0.01,
	CurrentValue = settings.Delay,
	Suffix = "s",
	Callback = function(val)
		settings.Delay = tonumber(val)
		pushLog("Delay set to "..tostring(settings.Delay))
	end
})

SettingsTab:CreateSlider({
	Name = "Teleport Vertical Offset (studs)",
	Range = {0, 50},
	Increment = 0.5,
	CurrentValue = settings.OffsetY,
	Suffix = "studs",
	Callback = function(val)
		settings.OffsetY = tonumber(val)
		pushLog("Teleport offset set to "..tostring(settings.OffsetY).." studs")
	end
})

SettingsTab:CreateToggle({
	Name = "Forward Nudge Fix",
	CurrentValue = settings.ForwardNudge,
	Callback = function(val)
		settings.ForwardNudge = val
		pushLog("Forward Nudge set to "..tostring(val))
	end
})

SettingsTab:CreateToggle({
	Name = "Debug Mode",
	CurrentValue = settings.DebugMode,
	Callback = function(val)
		settings.DebugMode = val
		pushLog("Debug Mode set to "..tostring(val))
	end
})

SettingsTab:CreateToggle({
	Name = "Auto Reset Timer",
	CurrentValue = settings.AutoReset,
	Callback = function(val)
		settings.AutoReset = val
		pushLog("Auto Reset set to "..tostring(val))
	end
})

SettingsTab:CreateToggle({
	Name = "Show FPS",
	CurrentValue = settings.ShowFPS,
	Callback = function(val)
		settings.ShowFPS = val
		pushLog("Show FPS set to "..tostring(val))
	end
})

SettingsTab:CreateDropdown({
	Name = "Theme",
	Options = {"Ocean","Neon","Dark","Matrix","Vaporwave"},
	CurrentOption = {"Ocean"},
	Multi = false,
	Callback = function(opt)
		Rayfield:Notify({ Title = "Theme", Content = "Selected "..tostring(opt[1]), Duration = 2 })
		pushLog("Theme changed to "..tostring(opt[1]))
	end
})

local DebugTab = Window:CreateTab("Debug", 4483362458)
local DebugSection = DebugTab:CreateSection("Logs")

local debugLabel = DebugTab:CreateLabel("No logs yet.")

DebugTab:CreateButton({
	Name = "Clear Logs",
	Callback = function()
		logLines = {}
		DebugRefreshFunc()
		debugLabel:Set("No logs yet.")
		pushLog("Logs cleared")
	end
})

function DebugRefreshFunc()
	local out = {}
	for i = 1, math.min(6, #logLines) do table.insert(out, logLines[i]) end
	if #out == 0 then
		debugLabel:Set("No logs yet.")
	else
		debugLabel:Set(table.concat(out, "\n"))
	end
end

if not selectedName and #raceDurations > 0 then
	local firstName
	for n,_ in pairs(raceDurations) do firstName = n; break end
	selectedName = firstName
	selectedBest = raceDurations[firstName]
	if selectedName then
		pushLog("Default race selected: "..tostring(selectedName))
		goToLabel:Set("Go To: " .. tostring(selectedBest) .. "s")
		statusParagraph:Update({ Content = "Idle - Selected: "..selectedName })
	end
end

Rayfield:Notify({ Title = "Chrona v5 Loaded", Content = "UI ready. Press F1 to toggle.", Duration = 4 })
pushLog("Chrona v5 ready (Offset setting enabled).")
