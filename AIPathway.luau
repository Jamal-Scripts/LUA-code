--[[
    NPCPathfinder.lua - AI Navigation System for NPCs
    
    Built this after spending way too long watching NPCs walk into walls.
    The default Roblox pathfinding is fine but we needed more control over
    how our NPCs behave - patrol routes, chasing players, investigating
    sounds, all that good stuff.
    
    Drop this in ServerScriptService and require it from your NPC scripts.
    
    Quick example:
        local Pathfinder = require(script.Parent.NPCPathfinder)
        local npc = Pathfinder.new(workspace.Enemies.Zombie)
        npc:PatrolBetween({Vector3.new(0,0,0), Vector3.new(50,0,0)})
--]]

local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local NPCPathfinder = {}
NPCPathfinder.__index = NPCPathfinder


--[[
    CONFIGURATION
    Tweak these values to change how all NPCs behave. We spent a lot of time
    playtesting to find numbers that feel right - zombies that are too fast
    feel unfair, too slow feels boring. These defaults work for most cases
    but you can override them per-NPC if needed.
--]]
local DEFAULT_CONFIG = {
    -- Movement speeds in studs per second. Walk is for patrolling when
    -- nothing interesting is happening, run is for chasing players.
    WalkSpeed = 8,
    RunSpeed = 16,
    
    -- How close the NPC needs to get to a waypoint before moving to the next one.
    -- Too small and they get stuck on corners, too big and they cut corners weirdly.
    WaypointReachedDistance = 3,
    
    -- Detection ranges. These control when NPCs notice players and when they give up.
    -- The "lose" range is bigger so NPCs don't instantly forget you when you break line of sight.
    DetectionRange = 40,
    LoseTargetRange = 60,
    
    -- How often we recalculate the path when chasing. Lower = smoother but more expensive.
    -- 0.5 seconds feels responsive without killing the server.
    PathRecalculateInterval = 0.5,
    
    -- Pathfinding agent parameters. These tell the engine what size our NPC is
    -- so it can find paths that actually fit. Measure your NPC model if these seem wrong.
    AgentRadius = 2,
    AgentHeight = 5,
    AgentCanJump = true,
}


function NPCPathfinder.new(npcModel: Model, config: table?)
    --[[
        Creates a new pathfinder controller for an NPC.
        
        The NPC model needs a Humanoid and a PrimaryPart (usually HumanoidRootPart).
        If either is missing, this will error out immediately which is better than
        failing silently later when you try to move.
        
        You can pass a config table to override any of the default values above.
        Only include the keys you want to change - everything else uses defaults.
    --]]
    
    -- Make sure the model has what we need before doing anything else
    local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
    local rootPart = npcModel.PrimaryPart
    
    assert(humanoid, "[NPCPathfinder] Model needs a Humanoid! Got: " .. npcModel.Name)
    assert(rootPart, "[NPCPathfinder] Model needs a PrimaryPart! Got: " .. npcModel.Name)
    
    -- Build our instance. We merge the provided config with defaults so you only
    -- need to specify what you want to change.
    local self = setmetatable({}, NPCPathfinder)
    
    self.Model = npcModel
    self.Humanoid = humanoid
    self.RootPart = rootPart
    
    -- Merge configs - provided values override defaults
    self.Config = {}
    for key, value in pairs(DEFAULT_CONFIG) do
        self.Config[key] = (config and config[key]) or value
    end
    
    -- State tracking. We use these to know what the NPC is currently doing
    -- and to clean up properly when switching behaviors.
    self.CurrentState = "Idle"     -- Idle, Patrolling, Chasing, Investigating
    self.CurrentTarget = nil       -- Player we're chasing (if any)
    self.PatrolPoints = {}         -- Waypoints for patrol route
    self.PatrolIndex = 1           -- Which patrol point we're heading to
    self.CurrentPath = nil         -- The computed path we're following
    self.WaypointIndex = 1         -- Which waypoint in the current path
    
    -- Connection storage so we can disconnect everything on cleanup
    self._connections = {}
    self._activeLoop = nil
    
    -- Apply initial walk speed
    self.Humanoid.WalkSpeed = self.Config.WalkSpeed
    
    print("[NPCPathfinder] Initialized for:", npcModel.Name)
    return self
end


function NPCPathfinder:ComputePathTo(destination: Vector3): boolean
    --[[
        Computes a path from the NPC's current position to a destination.
        
        Returns true if a valid path was found, false if the destination is
        unreachable. When this returns false, the NPC will just stand there
        looking confused (or you can handle it however you want).
        
        The path gets stored in self.CurrentPath and we reset the waypoint
        index so the NPC starts from the beginning of the new path.
    --]]
    
    -- Create the path with our agent parameters. These are important - if your
    -- NPC is bigger than default, paths might go through gaps it can't fit through.
    local path = PathfindingService:CreatePath({
        AgentRadius = self.Config.AgentRadius,
        AgentHeight = self.Config.AgentHeight,
        AgentCanJump = self.Config.AgentCanJump,
    })
    
    -- Actually compute the path. This can fail if there's no valid route.
    local success, errorMessage = pcall(function()
        path:ComputeAsync(self.RootPart.Position, destination)
    end)
    
    if not success then
        warn("[NPCPathfinder] Path computation failed:", errorMessage)
        return false
    end
    
    -- Check if the path is actually usable
    if path.Status == Enum.PathStatus.Success then
        self.CurrentPath = path
        self.WaypointIndex = 1
        return true
    else
        -- Path failed - destination might be inside a wall or across an impossible gap
        return false
    end
end


function NPCPathfinder:FollowPath()
    --[[
        Moves the NPC along the currently computed path.
        
        This uses Humanoid:MoveTo() which handles the actual walking animation
        and physics. We just tell it where to go next and it figures out how.
        
        Call this in a loop or connect it to a heartbeat for continuous movement.
        Returns true if still moving, false if we've reached the destination.
    --]]
    
    -- No path? Nothing to follow.
    if not self.CurrentPath then
        return false
    end
    
    local waypoints = self.CurrentPath:GetWaypoints()
    
    -- Check if we've reached the end
    if self.WaypointIndex > #waypoints then
        self.CurrentPath = nil
        return false
    end
    
    local currentWaypoint = waypoints[self.WaypointIndex]
    local distanceToWaypoint = (self.RootPart.Position - currentWaypoint.Position).Magnitude
    
    -- Are we close enough to this waypoint to move on to the next one?
    if distanceToWaypoint <= self.Config.WaypointReachedDistance then
        self.WaypointIndex = self.WaypointIndex + 1
        
        -- Check again if that was the last waypoint
        if self.WaypointIndex > #waypoints then
            self.CurrentPath = nil
            return false
        end
        
        currentWaypoint = waypoints[self.WaypointIndex]
    end
    
    -- Handle jump waypoints. The pathfinder marks these when the NPC needs to
    -- jump over something. Without this check they just walk into obstacles.
    if currentWaypoint.Action == Enum.PathWaypointAction.Jump then
        self.Humanoid.Jump = true
    end
    
    -- Move toward the current waypoint
    self.Humanoid:MoveTo(currentWaypoint.Position)
    return true
end


function NPCPathfinder:PatrolBetween(points: {Vector3})
    --[[
        Sets the NPC to patrol between a list of points in order.
        
        When it reaches the last point, it loops back to the first.
        Great for guards walking a perimeter or enemies pacing back and forth.
        Pass at least 2 points or this is pretty pointless.
    --]]
    
    if #points < 2 then
        warn("[NPCPathfinder] Patrol needs at least 2 points!")
        return
    end
    
    self:StopCurrentBehavior()
    self.PatrolPoints = points
    self.PatrolIndex = 1
    self.CurrentState = "Patrolling"
    self.Humanoid.WalkSpeed = self.Config.WalkSpeed
    
    -- Start the patrol loop. We use task.spawn so it runs in the background
    -- and doesn't block whatever called this function.
    self._activeLoop = task.spawn(function()
        while self.CurrentState == "Patrolling" do
            local destination = self.PatrolPoints[self.PatrolIndex]
            
            if self:ComputePathTo(destination) then
                -- Follow the path until we reach the destination
                while self:FollowPath() and self.CurrentState == "Patrolling" do
                    task.wait(0.1)
                end
                
                -- Move to next patrol point (loop around at the end)
                self.PatrolIndex = self.PatrolIndex + 1
                if self.PatrolIndex > #self.PatrolPoints then
                    self.PatrolIndex = 1
                end
            else
                -- Couldn't reach the patrol point, skip to next one
                warn("[NPCPathfinder] Can't reach patrol point, skipping")
                self.PatrolIndex = self.PatrolIndex + 1
                if self.PatrolIndex > #self.PatrolPoints then
                    self.PatrolIndex = 1
                end
            end
            
            task.wait(0.5) -- Brief pause at each point
        end
    end)
end


function NPCPathfinder:ChasePlayer(player: Player)
    --[[
        Makes the NPC chase a specific player until it catches them or loses sight.
        
        The NPC switches to run speed and recalculates the path periodically
        since players move around. If the player gets too far away, the NPC
        gives up and returns to idle (you might want to make it return to patrol instead).
    --]]
    
    if not player.Character or not player.Character.PrimaryPart then
        return
    end
    
    self:StopCurrentBehavior()
    self.CurrentState = "Chasing"
    self.CurrentTarget = player
    self.Humanoid.WalkSpeed = self.Config.RunSpeed
    
    self._activeLoop = task.spawn(function()
        local lastPathTime = 0
        
        while self.CurrentState == "Chasing" and self.CurrentTarget do
            local targetRoot = self.CurrentTarget.Character and 
                              self.CurrentTarget.Character.PrimaryPart
            
            -- Did the target disconnect or die?
            if not targetRoot then
                self:StopCurrentBehavior()
                break
            end
            
            local distance = (self.RootPart.Position - targetRoot.Position).Magnitude
            
            -- Are they too far? Give up the chase.
            if distance > self.Config.LoseTargetRange then
                self:StopCurrentBehavior()
                break
            end
            
            -- Recalculate path periodically to follow moving target
            if tick() - lastPathTime > self.Config.PathRecalculateInterval then
                self:ComputePathTo(targetRoot.Position)
                lastPathTime = tick()
            end
            
            self:FollowPath()
            task.wait(0.1)
        end
    end)
end


function NPCPathfinder:StopCurrentBehavior()
    --[[
        Stops whatever the NPC is doing and returns to idle.
        
        This is important to call before starting a new behavior otherwise
        you end up with multiple loops fighting over control and the NPC
        spazzes out. Trust me, I've seen it happen.
    --]]
    
    self.CurrentState = "Idle"
    self.CurrentTarget = nil
    self.CurrentPath = nil
    self.Humanoid.WalkSpeed = self.Config.WalkSpeed
    
    -- Stop any movement
    self.Humanoid:MoveTo(self.RootPart.Position)
end


function NPCPathfinder:Destroy()
    --[[
        Clean up when you're done with this NPC. Disconnects all events and
        stops all behaviors. Call this when the NPC dies or despawns.
    --]]
    
    self:StopCurrentBehavior()
    
    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    
    self._connections = {}
    print("[NPCPathfinder] Destroyed for:", self.Model.Name)
end


return NPCPathfinder
