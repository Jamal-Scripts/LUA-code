--[[
	SERVER HANDLER - ELEMENTAL SYSTEM
	Author: [Your Name]
	Date: 2024
	
	Overview:
	This script handles the source of truth for all player abilities.
	We trust the client to ask for an ability, but we DON'T trust the client
	with cooldowns or damage calculation. Sanity checks are heavy here.
	
	TODO: Eventually move the ElementData table to a ModuleScript if this gets too big.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris") -- Used for cleaning up parts automatically

-- Create our RemoteEvent if it doesn't exist (Lazy loading preference)
local RemotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not RemotesFolder then
	RemotesFolder = Instance.new("Folder")
	RemotesFolder.Name = "Remotes"
	RemotesFolder.Parent = ReplicatedStorage
end

local CombatEvent = RemotesFolder:FindFirstChild("CombatEvent")
if not CombatEvent then
	CombatEvent = Instance.new("RemoteEvent")
	CombatEvent.Name = "CombatEvent"
	CombatEvent.Parent = RemotesFolder
end

-- DATA TABLES
-- This tracks the last time a player used a specific move to prevent spam exploits
local CooldownCache = {} 

-- Configuration for the elements
local ElementData = {
	["Fire"] = {
		Damage = 25,
		Cooldown = 3.5,
		Color = Color3.fromRGB(255, 80, 0),
		Speed = 80,
		Size = Vector3.new(4, 4, 4)
	},
	["Ice"] = {
		Damage = 15, -- Lower damage but maybe we add slowing logic later?
		Cooldown = 1.5,
		Color = Color3.fromRGB(100, 200, 255),
		Speed = 120, -- Faster projectile
		Size = Vector3.new(2, 2, 6) -- Icicle shape
	},
	["Earth"] = {
		Damage = 45, -- Heavy hitter
		Cooldown = 6.0,
		Color = Color3.fromRGB(110, 80, 40),
		Speed = 50, -- Slow
		Size = Vector3.new(6, 6, 6)
	}
}

--[[ 
	HELPER FUNCTION: GetCooldown
	Returns true if player is allowed to attack, false if they are cooling down.
]]
local function CheckCooldown(player, abilityName)
	-- If they aren't in the cache, add them
	if not CooldownCache[player.UserId] then
		CooldownCache[player.UserId] = {}
	end

	local lastUsed = CooldownCache[player.UserId][abilityName] or 0
	local now = os.time() -- Using os.time for rough checks, tick() is deprecated-ish
	
	local requiredTime = ElementData[abilityName].Cooldown
	
	-- We give a tiny buffer (0.1) for latency compensation so laggy players don't get rejected
	if (os.clock() - lastUsed) >= (requiredTime - 0.1) then
		CooldownCache[player.UserId][abilityName] = os.clock()
		return true
	else
		-- Player is spamming or lagging badly
		warn(player.Name .. " tried to use " .. abilityName .. " too fast.")
		return false
	end
end

--[[ 
	HELPER FUNCTION: Create Hitbox
	Actually spawns the server-side projectile.
]]
local function SpawnProjectile(player, abilityName, startCFrame, targetPos)
	local stats = ElementData[abilityName]
	
	-- Create the physical part
	local proj = Instance.new("Part")
	proj.Name = player.Name .. "_" .. abilityName
	proj.Size = stats.Size
	proj.Color = stats.Color
	proj.Material = Enum.Material.Neon
	proj.CanCollide = false
	proj.Anchored = true -- We anchor it because we are using CFrame to move it (smoother)
	proj.CFrame = CFrame.new(startCFrame.Position, targetPos)
	proj.Parent = workspace
	
	-- Add a light just for some polish
	local light = Instance.new("PointLight")
	light.Color = stats.Color
	light.Range = 12
	light.Brightness = 2
	light.Parent = proj
	
	-- Add it to Debris so it definitely gets deleted even if the script crashes
	Debris:AddItem(proj, 5) -- 5 second max lifetime
	
	-- Spawn a thread to handle the movement so we don't yield the main script
	task.spawn(function()
		local steps = 0
		local maxSteps = 100 -- fail-safe to stop infinite loops
		local hitSomething = false
		
		while steps < maxSteps and not hitSomething and proj.Parent do
			-- Heartbeat wait ensures we run every physics frame
			local dt = game:GetService("RunService").Heartbeat:Wait()
			
			-- Calculate next position
			local currentPos = proj.Position
			local forwardVector = proj.CFrame.LookVector
			local distance = stats.Speed * dt
			
			-- Raycast ahead to see if we are about to hit something
			local rayParams = RaycastParams.new()
			rayParams.FilterDescendantsInstances = {player.Character, proj}
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			
			local rayResult = workspace:Raycast(currentPos, forwardVector * distance, rayParams)
			
			if rayResult then
				-- WE HIT SOMETHING
				hitSomething = true
				proj.Position = rayResult.Position -- Snap to hit position
				
				local hitModel = rayResult.Instance.Parent
				local humanoid = hitModel:FindFirstChild("Humanoid")
				
				if humanoid and humanoid.Health > 0 then
					-- Deal damage
					humanoid:TakeDamage(stats.Damage)
					
					-- Optional: Knockback?
					local rootPart = hitModel:FindFirstChild("HumanoidRootPart")
					if rootPart then
						-- Apply a slight impulse away from the projectile
						local knockDir = (rootPart.Position - proj.Position).Unit
						rootPart:ApplyImpulse(knockDir * 500)
					end
				end
				
				-- Visual cleanup
				proj.Transparency = 1
				light.Enabled = false
				
				-- Maybe play a particle effect here later?
				task.wait(1) 
				proj:Destroy()
			else
				-- Move forward if nothing was hit
				proj.CFrame = proj.CFrame + (forwardVector * distance)
			end
			
			steps += 1
		end
		
		-- Cleanup if it never hit anything
		if proj.Parent then
			proj:Destroy()
		end
	end)
end

--[[
	EVENT LISTENER
	This is the entry point for Client requests.
]]
CombatEvent.OnServerEvent:Connect(function(player, action, ... )
	local args = {...}
	
	-- Sanity Check 1: is the character alive?
	if not player.Character or not player.Character:FindFirstChild("Humanoid") then return end
	if player.Character.Humanoid.Health <= 0 then return end
	
	if action == "RequestAbility" then
		local abilityName = args[1]
		local mouseHitPosition = args[2]
		
		-- Sanity Check 2: Does this ability exist?
		if not ElementData[abilityName] then 
			warn("Possible Exploit: " .. player.Name .. " requested invalid ability: " .. tostring(abilityName))
			return 
		end
		
		-- Check Cooldowns
		if CheckCooldown(player, abilityName) then
			-- Calculate start position (Right hand or Chest)
			local char = player.Character
			local startCFrame = char.HumanoidRootPart.CFrame * CFrame.new(0, 0, -2) -- Start slightly in front
			
			-- Execute
			SpawnProjectile(player, abilityName, startCFrame, mouseHitPosition)
			
			-- Feedback to console
			-- print("Ability fired: " .. abilityName)
		end
	end
end)

-- PLAYER SETUP
Players.PlayerAdded:Connect(function(player)
	-- Standard Leaderstats setup so we can maybe track kills later
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	ls.Parent = player
	
	local kills = Instance.new("IntValue")
	kills.Name = "Kills"
	kills.Value = 0
	kills.Parent = ls
	
	-- Initialize their cooldown table
	CooldownCache[player.UserId] = {}
	
	player.CharacterAdded:Connect(function(char)
		-- Reset cooldowns on death? Maybe. Let's keep them for now to prevent suicide-spamming.
		-- print(player.Name .. " spawned.")
	end)
end)

-- Cleanup on leave to save memory
Players.PlayerRemoving:Connect(function(player)
	CooldownCache[player.UserId] = nil
end)
