--[[
	CLIENT CONTROLLER - ELEMENTAL SYSTEM (EXPANDED)
	Author: [Your Name]
	Version: 1.2
	
	Overview:
	This script handles the entire frontend experience for the player.
	It manages:
	1. User Input (Keyboard & Mobile compatible via ContextActionService)
	2. Procedural UI Generation (Skill slots + Mana Bar)
	3. Client-Side Prediction (Visual effects before server responds)
	4. Resource Management (Mana/Stamina regeneration loop)
	
	NOTE: We use 'Tick()' for some visual timing, but 'os.clock()' for cooldowns
	to remain consistent with the server.
]]

-- SERVICES
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService") -- Added for mobile support
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

-- PLAYER REFERENCES
local Player = Players.LocalPlayer
local Mouse = Player:GetMouse()
local Camera = workspace.CurrentCamera

-- NETWORK REFERENCES
-- We use WaitForChild because the client sometimes loads before the server creates these.
local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local CombatEvent = RemotesFolder:WaitForChild("CombatEvent")

-- ====================================================================================
-- CONFIGURATION & STATE
-- ====================================================================================

-- Mapped keys to Ability Names
-- We use a dictionary structure here for fast lookups.
local Keybinds = {
	[Enum.KeyCode.Q] = "Fire",
	[Enum.KeyCode.E] = "Ice",
	[Enum.KeyCode.R] = "Earth"
}

-- Client-Side Cooldowns (Visual Feedback Only)
-- Server performs the actual security check.
local AbilityStats = {
	["Fire"]  = { Cooldown = 3.5, Color = Color3.fromRGB(255, 100, 50), ManaCost = 20 },
	["Ice"]   = { Cooldown = 1.5, Color = Color3.fromRGB(100, 220, 255), ManaCost = 10 },
	["Earth"] = { Cooldown = 6.0, Color = Color3.fromRGB(130, 100, 60),  ManaCost = 45 }
}

-- State Variables
local IsCoolingDown = {}    -- Table to track active cooldowns: { ["Fire"] = true }
local CurrentMana = 100     -- Starting Mana
local MaxMana = 100         -- Cap
local ManaRegenRate = 5     -- Mana per second
local IsCasting = false     -- Debounce to prevent double-clicking inputs

-- UI Element Cache (So we don't have to FindFirstChild every frame)
local UI_Elements = {
	CooldownOverlays = {},
	ManaBar = nil
}

-- ====================================================================================
-- PROCEDURAL UI GENERATION
-- ====================================================================================
-- We generate the GUI via script to ensure it looks the same on all resolutions
-- and to avoid cluttering the StarterGui folder.

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "CombatHUD_v2"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = Player:WaitForChild("PlayerGui")

-- 1. Main Container Frame
local MainFrame = Instance.new("Frame")
MainFrame.Name = "Container"
MainFrame.Size = UDim2.new(0, 320, 0, 80)
MainFrame.Position = UDim2.new(0.5, -160, 0.88, 0) -- Centered, near bottom
MainFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
MainFrame.BackgroundTransparency = 0.2
MainFrame.BorderSizePixel = 0
MainFrame.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 10)
MainCorner.Parent = MainFrame

-- 2. Mana Bar Background
local ManaBg = Instance.new("Frame")
ManaBg.Name = "ManaBackground"
ManaBg.Size = UDim2.new(0.9, 0, 0.15, 0)
ManaBg.Position = UDim2.new(0.05, 0, 0.08, 0) -- Top of the container
ManaBg.BackgroundColor3 = Color3.fromRGB(10, 10, 15)
ManaBg.BorderSizePixel = 0
ManaBg.Parent = MainFrame

local ManaCorner = Instance.new("UICorner", ManaBg)
ManaCorner.CornerRadius = UDim.new(1, 0) -- Pill shape

-- 3. Actual Mana Bar (The blue filler)
local ManaFill = Instance.new("Frame")
ManaFill.Name = "Fill"
ManaFill.Size = UDim2.new(1, 0, 1, 0) -- Starts full
ManaFill.BackgroundColor3 = Color3.fromRGB(50, 150, 255)
ManaFill.BorderSizePixel = 0
ManaFill.Parent = ManaBg

local FillCorner = Instance.new("UICorner", ManaFill)
FillCorner.CornerRadius = UDim.new(1, 0)

UI_Elements.ManaBar = ManaFill -- Cache it for the loop later

-- 4. Skill Buttons Generator
local layoutOrder = 1
for key, abilityName in pairs(Keybinds) do
	local stats = AbilityStats[abilityName]
	
	-- Button Frame
	local Slot = Instance.new("Frame")
	Slot.Name = abilityName
	Slot.Size = UDim2.new(0.28, 0, 0.6, 0)
	-- Math to space them out evenly
	Slot.Position = UDim2.new(0.04 + (0.31 * (layoutOrder - 1)), 0, 0.3, 0)
	Slot.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
	Slot.Parent = MainFrame
	
	local SlotCorner = Instance.new("UICorner", Slot)
	SlotCorner.CornerRadius = UDim.new(0, 6)
	
	-- Color Strip (Indicator of element type)
	local ColorStrip = Instance.new("Frame")
	ColorStrip.Size = UDim2.new(1, 0, 0.1, 0)
	ColorStrip.Position = UDim2.new(0, 0, 0.9, 0)
	ColorStrip.BackgroundColor3 = stats.Color
	ColorStrip.BorderSizePixel = 0
	ColorStrip.Parent = Slot
	Instance.new("UICorner", ColorStrip).CornerRadius = UDim.new(0, 6)
	
	-- Text Label
	local Text = Instance.new("TextLabel")
	Text.Size = UDim2.new(1, 0, 0.9, 0)
	Text.BackgroundTransparency = 1
	Text.Text = string.upper(abilityName) .. "\n[" .. key.Name .. "]"
	Text.TextColor3 = Color3.fromRGB(240, 240, 240)
	Text.Font = Enum.Font.GothamBold
	Text.TextSize = 12
	Text.Parent = Slot
	
	-- Cooldown Overlay (Red box that shrinks)
	local Overlay = Instance.new("Frame")
	Overlay.Name = "CD_Overlay"
	Overlay.Size = UDim2.new(1, 0, 0, 0) -- Start invisible
	Overlay.Position = UDim2.new(0, 0, 1, 0)
	Overlay.AnchorPoint = Vector2.new(0, 1) -- Anchor bottom
	Overlay.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	Overlay.BackgroundTransparency = 0.5
	Overlay.BorderSizePixel = 0
	Overlay.ZIndex = 5
	Overlay.Parent = Slot
	
	UI_Elements.CooldownOverlays[abilityName] = Overlay
	
	layoutOrder += 1
end

-- ====================================================================================
-- VISUAL EFFECTS & JUICE
-- ====================================================================================

--[[
	Function: ShakeCamera
	Adds a randomized offset to the camera CFrame for 'duration' seconds.
	Used to make attacks feel powerful.
]]
local function ShakeCamera(intensity)
	local start = os.clock()
	local length = 0.15
	
	task.spawn(function()
		while (os.clock() - start) < length do
			local rx = (math.random() - 0.5) * intensity
			local ry = (math.random() - 0.5) * intensity
			local rz = (math.random() - 0.5) * intensity
			
			Camera.CFrame = Camera.CFrame * CFrame.new(rx, ry, rz)
			RunService.RenderStepped:Wait()
		end
	end)
end

--[[
	Function: PlayChargeEffect
	Creates a temporary neon part on the character's hand before firing.
	This gives the user instant feedback even if ping is high.
]]
local function PlayChargeEffect(color)
	local char = Player.Character
	if not char then return end
	
	-- Prefer Right Hand, fallback to Torso if R6 or loading
	local hand = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm") or char:FindFirstChild("HumanoidRootPart")
	if not hand then return end
	
	local particlePart = Instance.new("Part")
	particlePart.Size = Vector3.new(1,1,1)
	particlePart.Transparency = 1
	particlePart.CanCollide = false
	particlePart.Anchored = false
	particlePart.Parent = workspace
	
	-- Weld it to the hand so it moves with animation
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = particlePart
	weld.Parent = particlePart
	particlePart.CFrame = hand.CFrame
	
	-- Add a light
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 5
	light.Range = 8
	light.Parent = particlePart
	
	-- Add highlight/particle simulation (using a billboard gui for cheap effect)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.new(2,0,2,0)
	bb.AlwaysOnTop = true
	bb.Parent = particlePart
	
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Image = "rbxassetid://3570695787" -- Generic soft glow circle
	img.ImageColor3 = color
	img.Size = UDim2.new(0,0,0,0) -- Start small
	img.Position = UDim2.new(0.5,0,0.5,0)
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Parent = bb
	
	-- Animate pop in
	TweenService:Create(img, TweenInfo.new(0.2), {Size = UDim2.new(1,0,1,0)}):Play()
	
	Debris:AddItem(particlePart, 0.5) -- Auto cleanup
end

-- ====================================================================================
-- GAMEPLAY LOGIC
-- ====================================================================================

--[[
	Function: UpdateMana
	Runs every frame via Heartbeat. Handles regeneration and UI tweening.
]]
local function UpdateManaLoop(dt)
	if CurrentMana < MaxMana then
		CurrentMana = math.clamp(CurrentMana + (ManaRegenRate * dt), 0, MaxMana)
	end
	
	-- Visual Update
	if UI_Elements.ManaBar then
		local percent = CurrentMana / MaxMana
		-- We use TweenService for the bar so it looks smooth, not jittery
		TweenService:Create(UI_Elements.ManaBar, TweenInfo.new(0.1), {Size = UDim2.new(percent, 0, 1, 0)}):Play()
	end
end

--[[
	Function: CastAbility
	The main entry point for using a skill.
]]
local function CastAbility(abilityName)
	-- 1. Debounce / State Check
	if IsCasting then return end
	if IsCoolingDown[abilityName] then return end
	
	local stats = AbilityStats[abilityName]
	
	-- 2. Resource Check
	if CurrentMana < stats.ManaCost then
		-- Optional: Play "Error" sound here
		-- Flash the mana bar red to indicate failure
		local originalColor = UI_Elements.ManaBar.BackgroundColor3
		UI_Elements.ManaBar.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
		task.delay(0.2, function()
			UI_Elements.ManaBar.BackgroundColor3 = originalColor
		end)
		return 
	end
	
	-- 3. Consume Resources
	IsCasting = true
	CurrentMana = CurrentMana - stats.ManaCost
	IsCoolingDown[abilityName] = true
	
	-- 4. Visual Feedback
	PlayChargeEffect(stats.Color)
	ShakeCamera(0.4)
	
	-- 5. Cooldown UI Animation
	local bar = UI_Elements.CooldownOverlays[abilityName]
	if bar then
		bar.Size = UDim2.new(1, 0, 1, 0) -- Fill up red
		TweenService:Create(bar, TweenInfo.new(stats.Cooldown, Enum.EasingStyle.Linear), {Size = UDim2.new(1, 0, 0, 0)}):Play()
	end
	
	-- 6. Network Request
	CombatEvent:FireServer("RequestAbility", abilityName, Mouse.Hit.Position)
	
	-- 7. Reset States
	-- Small delay to prevent machine-gun clicking
	task.delay(0.2, function()
		IsCasting = false 
	end)
	
	-- Reset cooldown flag after full duration
	task.delay(stats.Cooldown, function()
		IsCoolingDown[abilityName] = false
	end)
end

-- ====================================================================================
-- INPUT HANDLING
-- ====================================================================================

-- Mobile & PC Support via ContextActionService
-- This is cleaner than UserInputService because it auto-creates buttons for mobile players.
local function InputHandler(actionName, inputState, inputObject)
	if inputState == Enum.UserInputState.Begin then
		CastAbility(actionName) -- The action name IS the ability name (Fire, Ice, etc)
	end
end

-- Bind keys
for key, abilityName in pairs(Keybinds) do
	ContextActionService:BindAction(abilityName, InputHandler, true, key)
	
	-- Optional: Set mobile button image here if we had icons
	-- ContextActionService:SetImage(abilityName, "rbxassetid://...")
end

-- Connect the Mana Loop
RunService.Heartbeat:Connect(UpdateManaLoop)

