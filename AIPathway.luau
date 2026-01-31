local PathfindingService = game:GetService("PathfindingService")

local NPCPathfinder = {}
NPCPathfinder.__index = NPCPathfinder

-- Default settings. I kept these lowercase to keep it looking consistent.
local default_settings = {
	WalkSpeed = 8,
	RunSpeed = 16,
	StopDist = 3, 
	PathUpdateDelay = 0.4, -- Slightly faster update for better tracking
	Size = 2,
	Height = 5,
	CanJump = true,
	StuckTime = 2, -- If we haven't moved in 2 seconds, we're stuck
	StuckThreshold = 0.5 -- Studs moved to be considered "moving"
}

function NPCPathfinder.new(npc, config)
	local hum = npc:FindFirstChildOfClass("Humanoid")
	local root = npc.PrimaryPart
	
	-- Rig check
	if not hum or not root then 
		error("NPCPathfinder: Missing Humanoid/RootPart in " .. npc.Name) 
	end
	
	local self = setmetatable({}, NPCPathfinder)
	
	self.Char = npc
	self.Hum = hum
	self.Root = root
	
	-- Merge configs manually
	self.Data = {}
	for k, v in pairs(default_settings) do
		self.Data[k] = (config and config[k]) or v
	end
	
	-- Behavior vars
	self.Status = "Idle" 
	self.CurrentPoint = 1
	self.PathData = nil
	self.Moving = false
	self.TargetObject = nil -- Used for following moving players
	
	-- Tracking for stuck detection
	self.LastPos = root.Position
	self.LastMoveTick = os.clock()
	
	-- Connections storage
	self._conn = nil
	
	self.Hum.WalkSpeed = self.Data.WalkSpeed
	
	return self
end

-- Core path logic
function NPCPathfinder:GetNewPath(goal)
	-- No point computing if the goal is right on top of us
	local distToGoal = (self.Root.Position - goal).Magnitude
	if distToGoal < self.Data.StopDist then return false end

	local p = PathfindingService:CreatePath({
		AgentRadius = self.Data.Size,
		AgentHeight = self.Data.Height,
		AgentCanJump = self.Data.Jump,
		-- Adding a small costs table for future navigation tweaks
		Costs = {
			Water = 20,
			Neon = 2 
		}
	})
	
	local success, err = pcall(function()
		p:ComputeAsync(self.Root.Position, goal)
	end)
	
	if success and p.Status == Enum.PathStatus.Success then
		self.PathData = p
		self.CurrentPoint = 1
		return true
	end
	
	-- Log the fail if it's not just a "no path" error
	if not success then
		warn("Path computing exploded: " .. tostring(err))
	end
	
	return false
end

-- The actual movement stepper
function NPCPathfinder:Move()
	if not self.PathData then 
		self.Moving = false
		return 
	end
	
	local waypoints = self.PathData:GetWaypoints()
	
	-- Path finished check
	if self.CurrentPoint > #waypoints then
		self.Moving = false
		return
	end
	
	local node = waypoints[self.CurrentPoint]
	
	-- Handles Jumping
	if node.Action == Enum.PathWaypointAction.Jump then
		self.Hum.Jump = true
	end
	
	self.Hum:MoveTo(node.Position)
	self.Moving = true
	
	-- clean up old connection if we called Move() again before it finished
	if self._conn then self._conn:Disconnect() end
	
	self._conn = self.Hum.MoveToFinished:Connect(function(reached)
		if self._conn then self._conn:Disconnect() end
		self._conn = nil
		
		if reached then
			self.CurrentPoint = self.CurrentPoint + 1
			
			-- Only continue if we aren't at the end
			if self.CurrentPoint <= #waypoints then
				self:Move()
			else
				self.Moving = false
			end
		else
			-- We failed to reach the point (blocked by wall/physics)
			self.Moving = false
		end
	end)
end

-- Stuck check: run this inside a loop to make sure the NPC isn't a vegetable
function NPCPathfinder:CheckIfStuck()
	local now = os.clock()
	local currentPos = self.Root.Position
	local distMoved = (currentPos - self.LastPos).Magnitude
	
	if distMoved > self.Data.StuckThreshold then
		-- We are moving fine
		self.LastPos = currentPos
		self.LastMoveTick = now
		return false
	end
	
	-- If we haven't moved enough in X seconds
	if (now - self.LastMoveTick) > self.Data.StuckTime then
		-- Reset timers
		self.LastPos = currentPos
		self.LastMoveTick = now
		return true
	end
	
	return false
end

-- High level patrolling logic
function NPCPathfinder:Patrol(list)
	if #list < 1 then return end
	
	self:Reset()
	self.Status = "Patrolling"
	
	task.spawn(function()
		local idx = 1
		while self.Status == "Patrolling" do
			local dest = list[idx]
			
			-- Try to walk to the point
			if self:GetNewPath(dest) then
				self:Move()
				
				-- Loop until reached or state changed
				while self.Moving and self.Status == "Patrolling" do
					-- Stuck handling
					if self:CheckIfStuck() then
						-- Try to jump or move slightly to unstick
						self.Hum.Jump = true
						task.wait(0.2)
						self:Move() -- Try moving again
					end
					task.wait(0.2)
				end
			end
			
			-- Wait at the corner for realism
			task.wait(math.random(1, 3))
			
			-- Next point
			idx = (idx % #list) + 1
		end
	end)
end

-- Aggressive player tracking
function NPCPathfinder:Hunt(targetChar)
	local targetRoot = targetChar:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return end
	
	self:Reset()
	self.Status = "Chasing"
	self.TargetObject = targetChar
	self.Hum.WalkSpeed = self.Data.RunSpeed
	
	task.spawn(function()
		local lastGoal = Vector3.new(0,0,0)
		
		while self.Status == "Chasing" and targetChar.Parent do
			local currentTargetPos = targetRoot.Position
			
			-- Optimization: Don't re-calculate if target hasn't moved much
			local moveDelta = (lastGoal - currentTargetPos).Magnitude
			
			if moveDelta > 2 then
				if self:GetNewPath(currentTargetPos) then
					lastGoal = currentTargetPos
					self:Move()
				end
			end
			
			-- Chase logic doesn't need stuck checks as often because the path refreshes
			task.wait(self.Data.PathUpdateDelay)
		end
		
		-- If we exited loop, reset
		if self.Status == "Chasing" then
			self:Reset()
		end
	end)
end

-- To-do: Add a "LookForTarget" function that uses Raycasts for line-of-sight
-- To-do: Implement a simple wandering state if no patrol points are found

function NPCPathfinder:Stop()
	self.Status = "Idle"
	self.Moving = false
	self.TargetObject = nil
	
	if self._conn then 
		self._conn:Disconnect() 
		self._conn = nil
	end
	
	-- Force stop the humanoid
	self.Hum:MoveTo(self.Root.Position)
end

-- Full cleanup
function NPCPathfinder:Reset()
	self:Stop()
	self.Hum.WalkSpeed = self.Data.WalkSpeed
	self.CurrentPoint = 1
	self.PathData = nil
end

-- Used for deleting the NPC object from memory
function NPCPathfinder:Destroy()
	self:Reset()
	-- Clean up references
	self.Char = nil
	self.Root = nil
	self.Hum = nil
	setmetatable(self, nil)
end

return NPCPathfinder
