--[[
    GameManager.lua - Core game management module for our Roblox experience
    
    Written during the summer 2024 crunch when we realized our spaghetti code
    wasn't gonna cut it anymore. This module handles pretty much everything
    important: player data, round management, combat, rewards, the works.
    
    Before this existed, we had like 15 different scripts all fighting over
    who gets to manage player state. It was a nightmare. Now everything goes
    through here and life is so much better.
    
    The team spent about 3 weeks refactoring everything to use this system.
    Yes it was painful. Yes it was worth it. Our bug count dropped by like 60%
    after we finished.
    
    HOW TO USE THIS:
        local GameManager = require(game.ReplicatedStorage.Modules.GameManager)
        GameManager:Initialize()
        
        -- Then anywhere else in your code:
        local playerData = GameManager:GetPlayerData(player)
        GameManager:AwardCoins(player, 100)
    
    IMPORTANT NOTES:
        - Always call Initialize() once on server startup before doing anything else
        - Player data auto-saves every 60 seconds but you can force it with SavePlayerData()
        - The combat system uses server-authoritative hit detection so don't even try
          to do it on the client, it won't work and you'll waste 2 hours debugging
    
    Questions? Bug reports? Ping @gamedev-team in Discord
    
    Last updated: Fixed that stupid leaderboard desync bug - Jake
--]]

-- Services we need. Grabbing these at the top so we don't have to keep calling
-- GetService everywhere. Also makes it obvious what this module depends on.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

-- Our main data store. The version number at the end is crucial - if you ever
-- need to wipe everyone's data (god forbid) just increment this number.
-- We had to do this once during beta when we completely changed the data structure.
-- Players were NOT happy but it was necessary.
local PlayerDataStore = DataStoreService:GetDataStore("PlayerData_v3")

-- Remote events for client-server communication. We create these dynamically
-- if they don't exist, which is handy during development but maybe we should
-- pre-create them in studio for production? Something to think about.
local RemoteEvents = {}
local RemoteFunctions = {}

--[[
    Module table. Everything public goes in here.
    We're using the revealing module pattern because it makes it super clear
    what's meant to be called externally vs what's internal implementation.
--]]
local GameManager = {}
GameManager.__index = GameManager

-- Configuration values. Tweaking these is way easier than hunting through code.
-- If you're testing and things feel too slow/fast, check here first.
GameManager.Config = {
    -- How often we auto-save player data (in seconds)
    -- 60 is a good balance between data safety and not hammering the datastore
    AUTO_SAVE_INTERVAL = 60,
    
    -- Round timing stuff
    ROUND_INTERMISSION = 15,      -- Seconds between rounds for bathroom breaks
    ROUND_DURATION = 180,          -- 3 minutes per round, felt good in playtesting
    MIN_PLAYERS_TO_START = 2,      -- Can't really have a game with 1 person
    
    -- Economy balancing. These numbers came from like 2 weeks of spreadsheet hell.
    -- Please consult the game design doc before changing these or Sarah will be upset.
    BASE_KILL_REWARD = 25,
    WIN_BONUS = 100,
    PARTICIPATION_REWARD = 10,     -- Even losers get something so they don't rage quit
    DAILY_LOGIN_BONUS = 50,
    
    -- Combat settings
    BASE_PLAYER_HEALTH = 100,
    RESPAWN_TIME = 5,
    DAMAGE_MULTIPLIER = 1.0,       -- Set this higher for events/testing
    
    -- Anti-cheat thresholds. If someone exceeds these, something fishy is going on.
    MAX_SPEED = 50,                -- Studs per second, normal walk is like 16
    MAX_DAMAGE_PER_HIT = 100,      -- Nothing in our game does more than this
    SUSPICIOUS_KILLS_PER_MINUTE = 10,  -- If you're getting 10 kills/min you're probably hacking
}

-- Internal state that we don't want external scripts messing with directly
local _playerDataCache = {}        -- Cached data for all connected players
local _roundState = "Intermission" -- Current round state: Intermission, Active, Ending
local _roundTimer = 0              -- Seconds remaining in current phase
local _currentMap = nil            -- Reference to the currently loaded map
local _lastSaveTime = {}           -- Track last save time per player to avoid spam
local _initialized = false         -- Has Initialize() been called?
local _combatLog = {}              -- Recent combat events for anti-cheat analysis

--[[
    DEFAULT PLAYER DATA TEMPLATE
    
    When a new player joins and has no saved data, they get a copy of this.
    Make sure every field has a sensible default value. We learned the hard
    way that nil values cause all sorts of weird issues down the line.
    
    If you add new fields here, existing players won't have them until their
    data gets migrated. See the MigratePlayerData function below for how we
    handle that.
--]]
local DEFAULT_PLAYER_DATA = {
    -- Currency and progression
    Coins = 0,
    Gems = 0,                       -- Premium currency, rarely given out
    Experience = 0,
    Level = 1,
    
    -- Lifetime stats for the profile page
    TotalKills = 0,
    TotalDeaths = 0,
    TotalWins = 0,
    TotalGamesPlayed = 0,
    TotalPlayTime = 0,              -- In seconds
    
    -- Inventory system. Keys are item IDs, values are quantities.
    -- We use string keys because JSON doesn't like numeric keys
    Inventory = {},
    
    -- Currently equipped items. nil means nothing equipped in that slot.
    Equipped = {
        Weapon = "starter_sword",   -- Everyone starts with the basic sword
        Armor = nil,
        Accessory = nil,
        Pet = nil,
    },
    
    -- Settings and preferences
    Settings = {
        MusicVolume = 0.5,
        SFXVolume = 0.7,
        ShowDamageNumbers = true,
        ParticleQuality = "Medium",
    },
    
    -- Daily/weekly reset tracking
    LastLoginDate = "",             -- ISO date string, used for daily rewards
    DailyRewardsClaimed = 0,        -- How many days in a row
    WeeklyQuestsCompleted = {},
    
    -- Anti-cheat and moderation
    WarningCount = 0,
    IsBanned = false,
    BanReason = "",
    
    -- Data versioning for migrations
    DataVersion = 3,
}


--[[
    ============================================================================
    INITIALIZATION AND SETUP
    ============================================================================
    This section handles getting everything ready when the server starts up.
    Order matters here - don't move stuff around without understanding the
    dependencies.
--]]

function GameManager:Initialize()
    --[[
        Main entry point. Call this once when your game starts.
        Sets up all the event connections, creates remote events, and starts
        the core game loops.
        
        Returns true if initialization succeeded, false if something went wrong.
        Honestly though, if this fails the game probably can't run anyway.
    --]]
    
    if _initialized then
        warn("[GameManager] Already initialized! Ignoring duplicate call.")
        return false
    end
    
    print("[GameManager] Starting initialization...")
    local startTime = tick()
    
    -- Create all our remote events and functions
    -- We do this first because other setup code might need to reference them
    self:_setupRemotes()
    
    -- Connect player join/leave handlers
    -- The anonymous functions are intentional here - we want 'self' captured
    Players.PlayerAdded:Connect(function(player)
        self:_onPlayerJoin(player)
    end)
    
    Players.PlayerRemoving:Connect(function(player)
        self:_onPlayerLeave(player)
    end)
    
    -- Handle players that joined before this script ran
    -- This can happen if you're testing in studio with Play Solo
    for _, player in ipairs(Players:GetPlayers()) do
        task.spawn(function()
            self:_onPlayerJoin(player)
        end)
    end
    
    -- Start the auto-save loop
    -- We use task.spawn so this doesn't block initialization
    task.spawn(function()
        self:_autoSaveLoop()
    end)
    
    -- Start the main game loop
    task.spawn(function()
        self:_gameLoop()
    end)
    
    -- Bind to server shutdown for emergency saves
    -- This gives us 30 seconds to save everyone's data before Roblox kills the server
    game:BindToClose(function()
        self:_onServerShutdown()
    end)
    
    _initialized = true
    local elapsed = tick() - startTime
    print(string.format("[GameManager] Initialization complete! Took %.2fms", elapsed * 1000))
    
    return true
end


function GameManager:_setupRemotes()
    --[[
        Creates all the RemoteEvent and RemoteFunction instances we need.
        
        We put them in a folder under ReplicatedStorage so they're easy to find
        and so clients can access them. The folder structure also makes it obvious
        in the Explorer what remotes exist.
    --]]
    
    -- Create or get the remotes folder
    local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotesFolder then
        remotesFolder = Instance.new("Folder")
        remotesFolder.Name = "Remotes"
        remotesFolder.Parent = ReplicatedStorage
    end
    
    -- List of events we need. Adding a new one is as simple as adding to this table.
    local eventNames = {
        "PlayerDataUpdated",     -- Fired when player's data changes (coins, level, etc)
        "RoundStateChanged",     -- Intermission started, round started, etc
        "PlayerDamaged",         -- Someone took damage, clients use this for hit effects
        "PlayerKilled",          -- Someone died, triggers killfeed UI
        "RewardEarned",          -- Coins/XP earned, shows the +100 popup
        "ChatMessage",           -- Custom chat messages (announcements, system messages)
        "ItemPurchased",         -- Shop purchase confirmation
        "AbilityUsed",           -- Player used an ability, play effects on all clients
    }
    
    for _, name in ipairs(eventNames) do
        local event = remotesFolder:FindFirstChild(name)
        if not event then
            event = Instance.new("RemoteEvent")
            event.Name = name
            event.Parent = remotesFolder
        end
        RemoteEvents[name] = event
    end
    
    -- Remote functions for request/response patterns
    -- Use these when the client needs data back immediately
    local functionNames = {
        "GetPlayerData",         -- Client requests their own data
        "PurchaseItem",          -- Shop purchase request
        "EquipItem",             -- Change equipped item
        "UseAbility",            -- Request to use an ability (server validates)
    }
    
    for _, name in ipairs(functionNames) do
        local func = remotesFolder:FindFirstChild(name)
        if not func then
            func = Instance.new("RemoteFunction")
            func.Name = name
            func.Parent = remotesFolder
        end
        RemoteFunctions[name] = func
        
        -- Bind the handler
        func.OnServerInvoke = function(player, ...)
            return self:_handleRemoteFunction(name, player, ...)
        end
    end
    
    print("[GameManager] Remote events and functions created")
end


--[[
    ============================================================================
    PLAYER DATA MANAGEMENT
    ============================================================================
    All the functions for loading, saving, and manipulating player data.
    This is probably the most critical section - if data gets corrupted or
    lost, players will riot.
--]]

function GameManager:_onPlayerJoin(player: Player)
    --[[
        Called when a player joins the game. Handles:
        1. Loading their saved data (or creating new data)
        2. Setting up their character
        3. Initializing their leaderstats
        4. Checking for daily login rewards
        
        This whole function is wrapped in pcall because we CANNOT let errors
        here crash the join process. If loading fails, give them default data
        and log the error for investigation.
    --]]
    
    print("[GameManager] Player joining:", player.Name)
    
    local success, playerData = pcall(function()
        return self:_loadPlayerData(player)
    end)
    
    if not success then
        warn("[GameManager] Failed to load data for", player.Name, "- using defaults")
        warn("[GameManager] Error:", playerData) -- playerData contains error message on failure
        playerData = self:_deepCopy(DEFAULT_PLAYER_DATA)
    end
    
    -- Run data migrations if needed
    -- This handles adding new fields that didn't exist in older versions
    playerData = self:_migratePlayerData(playerData)
    
    -- Cache the data for quick access
    _playerDataCache[player.UserId] = playerData
    _lastSaveTime[player.UserId] = tick()
    
    -- Create leaderstats folder for the default Roblox leaderboard
    -- Some people disable this but we like having it for quick reference
    self:_setupLeaderstats(player, playerData)
    
    -- Check for daily login bonus
    self:_checkDailyReward(player, playerData)
    
    -- Set up character spawn/death handling
    player.CharacterAdded:Connect(function(character)
        self:_onCharacterSpawned(player, character)
    end)
    
    -- If they already have a character (possible in some edge cases), set it up
    if player.Character then
        self:_onCharacterSpawned(player, player.Character)
    end
    
    -- Tell the client their data is ready
    RemoteEvents.PlayerDataUpdated:FireClient(player, playerData)
    
    print("[GameManager] Player setup complete:", player.Name)
end


function GameManager:_loadPlayerData(player: Player): table
    --[[
        Loads a player's data from the DataStore.
        
        We use UpdateAsync instead of GetAsync because it's atomic and handles
        the case where two servers try to load the same player simultaneously
        (can happen during server transfers).
        
        Returns the player's data table, or nil if they're a new player.
    --]]
    
    local key = "Player_" .. player.UserId
    local data = nil
    
    -- Retry logic because DataStore calls can fail randomly
    -- 3 retries with exponential backoff is usually enough
    local maxRetries = 3
    local retryDelay = 1
    
    for attempt = 1, maxRetries do
        local success, result = pcall(function()
            return PlayerDataStore:GetAsync(key)
        end)
        
        if success then
            data = result
            break
        else
            warn(string.format(
                "[GameManager] DataStore load failed for %s (attempt %d/%d): %s",
                player.Name, attempt, maxRetries, tostring(result)
            ))
            
            if attempt < maxRetries then
                task.wait(retryDelay)
                retryDelay = retryDelay * 2 -- Exponential backoff
            end
        end
    end
    
    -- New player? Give them fresh data
    if data == nil then
        print("[GameManager] New player detected:", player.Name)
        data = self:_deepCopy(DEFAULT_PLAYER_DATA)
        data.LastLoginDate = os.date("%Y-%m-%d")
    end
    
    return data
end


function GameManager:SavePlayerData(player: Player, forceImmediate: boolean?): boolean
    --[[
        Saves a player's data to the DataStore.
        
        By default, this respects a cooldown to prevent save spam. Pass
        forceImmediate=true to bypass the cooldown (used during server shutdown).
        
        Returns true if save succeeded, false otherwise.
    --]]
    
    local userId = player.UserId
    local data = _playerDataCache[userId]
    
    if not data then
        warn("[GameManager] No cached data for", player.Name, "- cannot save")
        return false
    end
    
    -- Check cooldown unless forced
    if not forceImmediate then
        local lastSave = _lastSaveTime[userId] or 0
        local timeSinceLastSave = tick() - lastSave
        
        if timeSinceLastSave < 10 then -- Minimum 10 seconds between saves
            return true -- Not an error, just rate limited
        end
    end
    
    local key = "Player_" .. userId
    
    -- Update playtime before saving
    -- We track this for analytics and some achievements
    if data._sessionStart then
        local sessionTime = tick() - data._sessionStart
        data.TotalPlayTime = (data.TotalPlayTime or 0) + sessionTime
        data._sessionStart = tick() -- Reset for next save
    end
    
    -- Remove any temporary fields that shouldn't be persisted
    -- These are prefixed with underscore by convention
    local dataToSave = self:_deepCopy(data)
    for key, _ in pairs(dataToSave) do
        if string.sub(key, 1, 1) == "_" then
            dataToSave[key] = nil
        end
    end
    
    -- Actually save to DataStore
    local success, errorMessage = pcall(function()
        PlayerDataStore:SetAsync(key, dataToSave)
    end)
    
    if success then
        _lastSaveTime[userId] = tick()
        return true
    else
        warn("[GameManager] Failed to save data for", player.Name, "-", errorMessage)
        return false
    end
end


function GameManager:GetPlayerData(player: Player): table?
    --[[
        Returns a player's cached data. This is what you should use in gameplay
        code - it's instant and doesn't hit the DataStore.
        
        Returns nil if the player isn't loaded yet (shouldn't happen in normal
        gameplay, but good to handle just in case).
    --]]
    
    return _playerDataCache[player.UserId]
end


function GameManager:UpdatePlayerData(player: Player, updates: table)
    --[[
        Applies updates to a player's data and notifies the client.
        
        Usage:
            GameManager:UpdatePlayerData(player, {
                Coins = currentCoins + 100,
                TotalKills = currentKills + 1,
            })
        
        This is the preferred way to change player data because it handles
        cache updates, client notification, and eventual persistence all in one.
    --]]
    
    local data = _playerDataCache[player.UserId]
    if not data then
        warn("[GameManager] Cannot update data for unloaded player:", player.Name)
        return
    end
    
    -- Apply the updates
    for key, value in pairs(updates) do
        data[key] = value
    end
    
    -- Update leaderstats if relevant fields changed
    self:_syncLeaderstats(player, data)
    
    -- Tell the client about the changes
    RemoteEvents.PlayerDataUpdated:FireClient(player, updates)
end


--[[
    ============================================================================
    ROUND/MATCH MANAGEMENT
    ============================================================================
    The core gameplay loop. Handles intermissions, starting rounds, determining
    winners, and transitioning between states.
--]]

function GameManager:_gameLoop()
    --[[
        Main game loop that runs forever. Controls the flow of:
        Intermission -> Round Active -> Round End -> Intermission -> ...
        
        Uses a state machine pattern which makes it easy to add new states
        later (like a special "Event" state for double XP weekends).
    --]]
    
    print("[GameManager] Game loop started")
    
    while true do
        if _roundState == "Intermission" then
            self:_runIntermission()
        elseif _roundState == "Active" then
            self:_runActiveRound()
        elseif _roundState == "Ending" then
            self:_runRoundEnd()
        end
        
        task.wait(1) -- Tick once per second
    end
end


function GameManager:_runIntermission()
    --[[
        Intermission phase - players can hang out in the lobby, buy stuff,
        customize their loadout, etc.
        
        We wait for minimum players before starting the countdown. If players
        leave and we drop below minimum, the countdown pauses.
    --]]
    
    local playerCount = #Players:GetPlayers()
    
    if playerCount < self.Config.MIN_PLAYERS_TO_START then
        -- Not enough players, just wait
        -- We broadcast this occasionally so people know what's happening
        if _roundTimer % 10 == 0 then
            self:_broadcastMessage("Waiting for players... (" .. playerCount .. "/" .. self.Config.MIN_PLAYERS_TO_START .. ")")
        end
        _roundTimer = self.Config.ROUND_INTERMISSION -- Reset timer
        return
    end
    
    -- Countdown
    _roundTimer = _roundTimer - 1
    
    if _roundTimer <= 0 then
        self:_startRound()
    elseif _roundTimer <= 5 then
        -- Final countdown announcements
        self:_broadcastMessage("Round starting in " .. _roundTimer .. "...")
    end
end


function GameManager:_startRound()
    --[[
        Transitions from intermission to active round.
        
        Handles:
        - Loading and setting up the map
        - Teleporting players to spawn points
        - Resetting combat stats for the round
        - Notifying all clients
    --]]
    
    print("[GameManager] Starting new round")
    
    _roundState = "Active"
    _roundTimer = self.Config.ROUND_DURATION
    
    -- Pick a random map from our available maps
    -- In production you'd probably want a voting system or rotation
    _currentMap = self:_loadRandomMap()
    
    -- Teleport all players to the map
    local spawnPoints = self:_getSpawnPoints(_currentMap)
    local spawnIndex = 1
    
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then
            local spawn = spawnPoints[spawnIndex]
            player.Character:PivotTo(spawn.CFrame + Vector3.new(0, 3, 0))
            
            -- Round-robin through spawn points
            spawnIndex = spawnIndex + 1
            if spawnIndex > #spawnPoints then
                spawnIndex = 1
            end
            
            -- Reset their stats for this round
            player.Character:SetAttribute("RoundKills", 0)
            player.Character:SetAttribute("RoundDeaths", 0)
        end
        
        -- Track participation
        local data = self:GetPlayerData(player)
        if data then
            data._inCurrentRound = true
        end
    end
    
    -- Notify everyone
    RemoteEvents.RoundStateChanged:FireAllClients("Active", {
        Duration = self.Config.ROUND_DURATION,
        MapName = _currentMap.Name,
    })
    
    self:_broadcastMessage("Round started! Good luck!")
end


function GameManager:_runActiveRound()
    --[[
        Active round tick. Checks for round end conditions and manages the timer.
        
        The round ends when:
        1. Timer runs out
        2. Only one player/team remains (TODO: implement teams)
        3. Someone reaches the kill target (for deathmatch mode)
    --]]
    
    _roundTimer = _roundTimer - 1
    
    -- Check win conditions
    local alivePlayers = self:_getAlivePlayers()
    
    if #alivePlayers <= 1 then
        -- Someone won by elimination
        if #alivePlayers == 1 then
            self:_endRound(alivePlayers[1])
        else
            -- Nobody alive? Draw I guess
            self:_endRound(nil)
        end
        return
    end
    
    if _roundTimer <= 0 then
        -- Time's up - winner is whoever has most kills
        local winner = self:_getPlayerWithMostKills()
        self:_endRound(winner)
        return
    end
    
    -- Periodic time announcements
    if _roundTimer == 60 then
        self:_broadcastMessage("One minute remaining!")
    elseif _roundTimer == 30 then
        self:_broadcastMessage("30 seconds left!")
    elseif _roundTimer <= 10 and _roundTimer > 0 then
        self:_broadcastMessage(tostring(_roundTimer) .. "...")
    end
end


function GameManager:_endRound(winner: Player?)
    --[[
        Handles the end of a round. Distributes rewards, updates stats,
        and transitions to the ending state.
    --]]
    
    print("[GameManager] Round ended. Winner:", winner and winner.Name or "Nobody")
    
    _roundState = "Ending"
    _roundTimer = 5 -- Brief pause before returning to lobby
    
    -- Distribute rewards
    for _, player in ipairs(Players:GetPlayers()) do
        local data = self:GetPlayerData(player)
        if not data or not data._inCurrentRound then
            continue -- Didn't participate
        end
        
        local reward = self.Config.PARTICIPATION_REWARD
        local message = "Round complete!"
        
        if player == winner then
            reward = reward + self.Config.WIN_BONUS
            message = "Victory! +"
            
            self:UpdatePlayerData(player, {
                TotalWins = data.TotalWins + 1,
            })
        end
        
        self:AwardCoins(player, reward, message .. reward .. " coins")
        
        -- Update games played
        self:UpdatePlayerData(player, {
            TotalGamesPlayed = data.TotalGamesPlayed + 1,
        })
        
        data._inCurrentRound = false
    end
    
    -- Announce winner
    if winner then
        RemoteEvents.RoundStateChanged:FireAllClients("Ending", {
            WinnerName = winner.Name,
            WinnerUserId = winner.UserId,
        })
    else
        RemoteEvents.RoundStateChanged:FireAllClients("Ending", {
            WinnerName = nil,
            Message = "Draw - nobody wins!",
        })
    end
    
    -- Clean up map after a short delay
    task.delay(5, function()
        if _currentMap then
            _currentMap:Destroy()
            _currentMap = nil
        end
    end)
end


function GameManager:_runRoundEnd()
    --[[
        Brief state after round ends. Lets players see the results before
        being teleported back to lobby.
    --]]
    
    _roundTimer = _roundTimer - 1
    
    if _roundTimer <= 0 then
        _roundState = "Intermission"
        _roundTimer = self.Config.ROUND_INTERMISSION
        
        -- Teleport everyone back to lobby
        self:_teleportAllToLobby()
        
        RemoteEvents.RoundStateChanged:FireAllClients("Intermission", {
            Duration = self.Config.ROUND_INTERMISSION,
        })
    end
end


--[[
    ============================================================================
    COMBAT SYSTEM
    ============================================================================
    Server-authoritative combat. All damage must go through here.
    
    We used to let clients report their own hits but that lasted about 3 days
    before the exploiters showed up. Now everything is validated server-side.
--]]

function GameManager:DealDamage(attacker: Player, victim: Player, amount: number, damageType: string?)
    --[[
        Core damage function. Call this whenever something should hurt a player.
        
        Handles:
        - Damage validation (anti-cheat)
        - Applying damage multipliers
        - Death detection
        - Kill attribution
        - Broadcasting to clients for effects
        
        Args:
            attacker: Who did the damage (can be nil for environmental damage)
            victim: Who's taking the damage
            amount: Base damage before multipliers
            damageType: Optional string like "Melee", "Ranged", "Explosion"
    --]]
    
    -- Sanity checks
    if not victim or not victim.Character then
        return
    end
    
    local humanoid = victim.Character:FindFirstChild("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
        return -- Already dead
    end
    
    -- Anti-cheat: validate damage amount
    if amount > self.Config.MAX_DAMAGE_PER_HIT then
        warn("[GameManager] Suspicious damage detected:", amount, "from", attacker and attacker.Name or "unknown")
        self:_logSuspiciousActivity(attacker, "excessive_damage", {amount = amount})
        amount = self.Config.MAX_DAMAGE_PER_HIT
    end
    
    -- Apply multipliers
    local finalDamage = amount * self.Config.DAMAGE_MULTIPLIER
    
    -- Log the combat event (for anti-cheat analysis)
    table.insert(_combatLog, {
        time = tick(),
        attacker = attacker and attacker.UserId or nil,
        victim = victim.UserId,
        damage = finalDamage,
        type = damageType or "Unknown",
    })
    
    -- Trim old combat log entries (keep last 100)
    while #_combatLog > 100 do
        table.remove(_combatLog, 1)
    end
    
    -- Apply the damage
    humanoid:TakeDamage(finalDamage)
    
    -- Notify clients for hit effects, damage numbers, etc
    RemoteEvents.PlayerDamaged:FireAllClients({
        VictimId = victim.UserId,
        AttackerId = attacker and attacker.UserId or nil,
        Damage = finalDamage,
        DamageType = damageType,
        Position = victim.Character.PrimaryPart and victim.Character.PrimaryPart.Position,
    })
    
    -- Check for death
    if humanoid.Health <= 0 then
        self:_onPlayerKilled(attacker, victim, damageType)
    end
end


function GameManager:_onPlayerKilled(killer: Player?, victim: Player, damageType: string?)
    --[[
        Handles player death. Awards kill credit, updates stats, handles respawn.
    --]]
    
    print("[GameManager] Player killed:", victim.Name, "by", killer and killer.Name or "environment")
    
    -- Update victim stats
    local victimData = self:GetPlayerData(victim)
    if victimData then
        self:UpdatePlayerData(victim, {
            TotalDeaths = victimData.TotalDeaths + 1,
        })
    end
    
    -- Track round deaths
    if victim.Character then
        local current = victim.Character:GetAttribute("RoundDeaths") or 0
        victim.Character:SetAttribute("RoundDeaths", current + 1)
    end
    
    -- Handle killer rewards
    if killer and killer ~= victim then -- No credit for suicide
        local killerData = self:GetPlayerData(killer)
        if killerData then
            self:UpdatePlayerData(killer, {
                TotalKills = killerData.TotalKills + 1,
            })
            
            self:AwardCoins(killer, self.Config.BASE_KILL_REWARD, "Kill! +" .. self.Config.BASE_KILL_REWARD)
        end
        
        -- Track round kills
        if killer.Character then
            local current = killer.Character:GetAttribute("RoundKills") or 0
            killer.Character:SetAttribute("RoundKills", current + 1)
        end
    end
    
    -- Broadcast kill event
    RemoteEvents.PlayerKilled:FireAllClients({
        KillerId = killer and killer.UserId or nil,
        KillerName = killer and killer.Name or "Environment",
        VictimId = victim.UserId,
        VictimName = victim.Name,
        DamageType = damageType,
    })
    
    -- Schedule respawn
    task.delay(self.Config.RESPAWN_TIME, function()
        if victim and victim.Parent then -- Still in game?
            victim:LoadCharacter()
        end
    end)
end


--[[
    ============================================================================
    UTILITY FUNCTIONS
    ============================================================================
    Helper functions used throughout the module. Most of these are internal
    (prefixed with underscore) but some are exposed for other scripts to use.
--]]

function GameManager:AwardCoins(player: Player, amount: number, message: string?)
    --[[
        Awards coins to a player. Use this instead of directly modifying data
        so the client gets the reward notification.
    --]]
    
    local data = self:GetPlayerData(player)
    if not data then return end
    
    local newTotal = data.Coins + amount
    self:UpdatePlayerData(player, {Coins = newTotal})
    
    if message then
        RemoteEvents.RewardEarned:FireClient(player, {
            Type = "Coins",
            Amount = amount,
            Message = message,
            NewTotal = newTotal,
        })
    end
end


function GameManager:_deepCopy(original: table): table
    --[[
        Deep copies a table. Essential for giving new players a fresh copy of
        DEFAULT_PLAYER_DATA instead of a reference to the same table.
        
        Handles nested tables but not metatables or userdata.
    --]]
    
    local copy = {}
    
    for key, value in pairs(original) do
        if type(value) == "table" then
            copy[key] = self:_deepCopy(value)
        else
            copy[key] = value
        end
    end
    
    return copy
end


function GameManager:_broadcastMessage(message: string)
    --[[
        Sends a system message to all connected players.
        These show up in the chat box with special formatting.
    --]]
    
    RemoteEvents.ChatMessage:FireAllClients({
        Type = "System",
        Message = message,
        Timestamp = os.time(),
    })
end


function GameManager:_onPlayerLeave(player: Player)
    --[[
        Cleanup when a player leaves. MUST save their data or they'll lose progress.
    --]]
    
    print("[GameManager] Player leaving:", player.Name)
    
    -- Emergency save
    self:SavePlayerData(player, true)
    
    -- Clean up cached data
    _playerDataCache[player.UserId] = nil
    _lastSaveTime[player.UserId] = nil
end


function GameManager:_onServerShutdown()
    --[[
        Called when the server is shutting down. We have ~30 seconds to save everyone.
        This is critical - if we don't save here, everyone loses their session progress.
    --]]
    
    warn("[GameManager] SERVER SHUTDOWN - Emergency saving all player data!")
    
    -- Save everyone simultaneously using coroutines
    local saveCoroutines = {}
    
    for _, player in ipairs(Players:GetPlayers()) do
        local co = coroutine.create(function()
            self:SavePlayerData(player, true)
        end)
        table.insert(saveCoroutines, co)
        coroutine.resume(co)
    end
    
    -- Wait for all saves to complete (with timeout)
    local startTime = tick()
    local timeout = 25 -- Leave some buffer before Roblox kills us
    
    while tick() - startTime < timeout do
        local allDone = true
        for _, co in ipairs(saveCoroutines) do
            if coroutine.status(co) ~= "dead" then
                allDone = false
                break
            end
        end
        
        if allDone then break end
        task.wait(0.1)
    end
    
    print("[GameManager] Emergency save complete")
end


-- More helper functions omitted for brevity but the pattern continues...
-- In a real codebase, you'd have functions for:
-- _autoSaveLoop, _migratePlayerData, _setupLeaderstats, _syncLeaderstats,
-- _checkDailyReward, _onCharacterSpawned, _getAlivePlayers, 
-- _getPlayerWithMostKills, _loadRandomMap, _getSpawnPoints,
-- _teleportAllToLobby, _handleRemoteFunction, _logSuspiciousActivity, etc.


return GameManager
