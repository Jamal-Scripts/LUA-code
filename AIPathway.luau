local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local NPCPathfinder = {}
NPCPathfinder.__index = NPCPathfinder

-- These are the "sweet spot" settings for our NPCs. 
-- Changing these affects every NPC using the module unless you pass a custom table to .new()
local DEFAULT_CONFIG = {
    -- Walk speed is for regular patrolling. Run speed kicks in during chases.
    WalkSpeed = 8,
    RunSpeed = 16,
    
    -- This helps prevent the NPC from stuttering when they get near a waypoint.
    -- 3 studs is usually enough to trigger the next move smoothly.
    WaypointReachedDistance = 3,
    
    -- How far away can they see players? We make 'lose' slightly higher
    -- so they don't instantly stop chasing the moment a player ducks behind a tree.
    DetectionRange = 40,
    LoseTargetRange = 60,
    
    -- Chasing a moving player requires recalculating the path. 
    -- 0.5s is a good middle ground so the server doesn't lag but the NPC stays on target.
    PathRecalculateInterval = 0.5,
    
    -- Agent settings tell the engine how big the NPC is so it doesn't try
    -- to cram a big zombie through a tiny 1-stud gap.
    AgentRadius = 2,
    AgentHeight = 5,
    AgentCanJump = true,
}

function NPCPathfinder.new(npcModel: Model, config: table?)
    -- Grab the essentials. If these aren't here, the script is going to break anyway,
    -- so we use assert to catch the error early with a clear message.
    local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
    local rootPart = npcModel.PrimaryPart
    
    assert(humanoid, "Missing Humanoid in " .. npcModel.Name .. ". Check the model structure.")
    assert(rootPart, "Missing PrimaryPart in " .. npcModel.Name .. ". Did you set the RootPart?")
    
    local self = setmetatable({}, NPCPathfinder)
    
    self.Model = npcModel
    self.Humanoid = humanoid
    self.RootPart = rootPart
    
    -- Setup the config. If the dev passed in specific settings, use those. 
    -- Otherwise, fall back to the defaults we defined at the top.
    self.Config = {}
    for key, value in pairs(DEFAULT_CONFIG) do
        self.Config[key] = (config and config[key]) or value
    end
    
    -- Keeping track of what the NPC is actually doing right now.
    self.CurrentState = "Idle"
    self.CurrentTarget = nil
    self.PatrolPoints = {}
    self.PatrolIndex = 1
    self.CurrentPath = nil
    self.WaypointIndex = 1
    
    -- Housekeeping for cleaning up loops and events later.
    self._connections = {}
    self._activeLoop = nil
    
    self.Humanoid.WalkSpeed = self.Config.WalkSpeed
    
    return self
end

function NPCPathfinder:ComputePathTo(destination: Vector3): boolean
    -- This handles the heavy lifting of talking to Roblox's pathfinding API.
    local path = PathfindingService:CreatePath({
        AgentRadius = self.Config.AgentRadius,
        AgentHeight = self.Config.AgentHeight,
        AgentCanJump = self.Config.AgentCanJump,
    })
    
    -- pcall here because ComputeAsync can occasionally fail due to external factors.
    local success, errorMessage = pcall(function()
        path:ComputeAsync(self.RootPart.Position, destination)
    end)
    
    if not success then
        warn("Pathfinding error: " .. errorMessage)
        return false
    end
    
    -- Only update the internal path if the engine actually found a way there.
    if path.Status == Enum.PathStatus.Success then
        self.CurrentPath = path
        self.WaypointIndex = 1
        return true
    else
        -- If it failed, the NPC will just stay put.
        return false
    end
end

function NPCPathfinder:FollowPath()
    -- If we don't have a path, there's nowhere to go.
    if not self.CurrentPath then
        return false
    end
    
    local waypoints = self.CurrentPath:GetWaypoints()
    
    -- If we've finished the list of waypoints, we're done.
    if self.WaypointIndex > #waypoints then
        self.CurrentPath = nil
        return false
    end
    
    local currentWaypoint = waypoints[self.WaypointIndex]
    local distanceToWaypoint = (self.RootPart.Position - currentWaypoint.Position).Magnitude
    
    -- Check if we are close enough to the current point to switch to the next one.
    if distanceToWaypoint <= self.Config.WaypointReachedDistance then
        self.WaypointIndex = self.WaypointIndex + 1
        
        -- Make sure we didn't just step past the very last point.
        if self.WaypointIndex > #waypoints then
            self.CurrentPath = nil
            return false
        end
        
        currentWaypoint = waypoints[self.WaypointIndex]
    end
    
    -- If the pathfinder says "Jump", we make the NPC jump. 
    -- Vital for getting over small curbs or stairs.
    if currentWaypoint.Action == Enum.PathWaypointAction.Jump then
        self.Humanoid.Jump = true
    end
    
    -- Actually tell the Humanoid to move toward the specific spot.
    self.Humanoid:MoveTo(currentWaypoint.Position)
    return true
end

function NPCPathfinder:PatrolBetween(points: {Vector3})
    -- Don't bother patrolling if there's only one point.
    if #points < 2 then
        warn("Patrol requires at least 2 points to function.")
        return
    end
    
    self:StopCurrentBehavior()
    self.PatrolPoints = points
    self.PatrolIndex = 1
    self.CurrentState = "Patrolling"
    self.Humanoid.WalkSpeed = self.Config.WalkSpeed
    
    -- Running the patrol logic in a separate thread so it doesn't hang the main script.
    self._activeLoop = task.spawn(function()
        while self.CurrentState == "Patrolling" do
            local destination = self.PatrolPoints[self.PatrolIndex]
            
            if self:ComputePathTo(destination) then
                -- Keep moving until we reach the destination or the state changes.
                while self:FollowPath() and self.CurrentState == "Patrolling" do
                    task.wait(0.1)
                end
                
                -- Increment index or loop back to the start if we finished the circuit.
                self.PatrolIndex = self.PatrolIndex + 1
                if self.PatrolIndex > #self.PatrolPoints then
                    self.PatrolIndex = 1
                end
            else
                -- If a point is unreachable, just skip it and try the next one.
                self.PatrolIndex = self.PatrolIndex + 1
                if self.PatrolIndex > #self.PatrolPoints then
                    self.PatrolIndex = 1
                end
            end
            
            -- Small delay so they don't look like robots instantly snapping to the next point.
            task.wait(0.5)
        end
    end)
end

function NPCPathfinder:ChasePlayer(player: Player)
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
            
            -- If the player leaves or dies, we stop the chase.
            if not targetRoot then
                self:StopCurrentBehavior()
                break
            end
            
            local distance = (self.RootPart.Position - targetRoot.Position).Magnitude
            
            -- Give up if they got too far away.
            if distance > self.Config.LoseTargetRange then
                self:StopCurrentBehavior()
                break
            end
            
            -- Players move, so we need to refresh the path regularly.
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
    -- Reset everything to a clean state. 
    -- This prevents two loops from running at once if you switch from Patrol to Chase.
    self.CurrentState = "Idle"
    self.CurrentTarget = nil
    self.CurrentPath = nil
    self.Humanoid.WalkSpeed = self.Config.WalkSpeed
    
    -- Stop walking immediately.
    self.Humanoid:MoveTo(self.RootPart.Position)
end

function NPCPathfinder:Destroy()
    -- Call this when the NPC is removed from the game to prevent memory leaks.
    self:StopCurrentBehavior()
    
    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    
    self._connections = {}
end

return NPCPathfinder
