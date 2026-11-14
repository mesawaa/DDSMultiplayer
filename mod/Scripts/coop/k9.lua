-- Police dogs.
--
-- The game has a finished police dog (policeDog_C with its leash, behaviour tree, bark and
-- a "first dog" tip): it walks with its patrol, smells drugs on a player within 8 m (a
-- second standing, less running) and, if it can see them, makes its handler suspect them.
-- It is never spawned: the only code that makes one is policeManager.spawnNewPatrol (30 %
-- of patrols once spawnDogPatrols is set: exposure above 500 and level above 7), and that
-- function, like the checkWorldStatus that sets the flag, is called by nothing since
-- patrols are spawned by the patrol areas themselves.
--
-- Here: a patrol lead that appears while a player near it is that exposed and that far up
-- gets a dog with the same odds, made exactly as the unused code makes it. (Rule and
-- numbers: Core.config.PoliceDogs = false switches it off; PoliceDogChance,
-- PoliceDogExposure, PoliceDogLevel.)
--
-- Shared world: a patrol belongs to the game that spawned it (coop/pop.lua) and that game
-- decides, from the exposure and level of the players within 150 m of the patrol (every
-- game tells the others whether its player qualifies; with nobody that near, its own
-- player's). The patrol's copies in the other games get a dog of their own: the owner
-- says so when it hands the patrol over. Each dog smells the player of the game it is in
-- and alerts the officer of that game; a copied officer that suspects somebody is driven
-- by that game, as with everything else an officer notices. Dog and leash are not saved.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")
local Avatar = require("coop.avatar")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local K9 = { stats = { considered = 0, dogs = 0, copies = 0, failed = 0 } }

local LEAD = "/Game/Skeletal/NPC/Policeman/PM_PatrolLead.PM_PatrolLead_C"
local DOG = "/Game/Skeletal/NPC/PoliceDog/policeDog.policeDog_C"
local LEASH = "/Game/Skeletal/NPC/Policeman/policeDogLeash.policeDogLeash_C"
local TREE = "/Game/Skeletal/NPC/PoliceDog/policeDogBT.policeDogBT"
local NEAR = 15000               -- players this close to a patrol count for its dog

local function on() return Core.config.PoliceDogs ~= false end
local function chance() return tonumber(Core.config.PoliceDogChance) or 0.3 end
local function minExposure() return tonumber(Core.config.PoliceDogExposure) or 500 end
local function minLevel() return tonumber(Core.config.PoliceDogLevel) or 7 end

-- Per world: patrol lead (address) -> { dog = true/false, actor, leash }.
local state = { owner = nil, load = nil, leads = {} }
local function leads()
    local player = World.player()
    if not player then return nil end
    local a = player:GetAddress()
    if state.owner ~= a or state.load ~= World.loadStartedAt then state = { owner = a, load = World.loadStartedAt, leads = {} } end
    return state.leads, player
end

local function asset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() LoadAsset((path:gsub("%.[^%.]+$", ""))) end)
    o = StaticFindObject(path)
    if valid(o) then return o end
    return nil
end

---------------------------------------------------------------- who qualifies

-- Whether this game's player is one the police bring dogs for.
local function localHot()
    local stats = Core.find("statisticsManager_C")
    if not stats then return false end
    local ok, hot = pcall(function() return stats.expoFactorLevel > minExposure() and stats.playerLevel > minLevel() end)
    return ok and hot == true
end
K9.localHot = localHot

local peerHot = {}               -- player -> true while that player qualifies
local saidHot, saidAt = nil, 0

Net.on("k9h", function(sender, data)
    if not World.isPeer(sender) then return end
    peerHot[sender] = data.h == true or nil
end)

Core.every(4, function()
    if not on() or not World.shared() then
        saidHot = nil
        return
    end
    local hot = localHot()
    local now = os.clock()
    if hot ~= saidHot or now - saidAt > 30 then
        saidHot, saidAt = hot, now
        for _, id in ipairs(World.others()) do Net.send("k9h", { h = hot }, id) end
    end
end)

World.listen("peerleft", function(id) peerHot[id] = nil end)
World.listen("stop", function() peerHot, saidHot = {}, nil end)
World.listen("start", function() peerHot, saidHot = {}, nil end)
World.listen("peer", function() saidHot = nil end)
World.listen("peerjoined", function() saidHot = nil end)

-- Does a patrol at this place get to have a dog?
local function wanted(loc)
    local mine = localHot()
    if not World.shared() then return mine end
    local player = World.player()
    local p = player:K2_GetActorLocation()
    local anyNear, hot = false, false
    if (p.X - loc.X) ^ 2 + (p.Y - loc.Y) ^ 2 <= NEAR * NEAR then anyNear, hot = true, mine end
    for _, id in ipairs(World.others()) do
        local x, y = Avatar.peerPosition(id)
        if x and (x - loc.X) ^ 2 + (y - loc.Y) ^ 2 <= NEAR * NEAR then
            anyNear = true
            if peerHot[id] then hot = true end
        end
    end
    if not anyNear then return mine end
    return hot
end

---------------------------------------------------------------- making a dog

-- What policeManager.spawnNewPatrol does for a patrol with a dog.
local function attach(lead, entry)
    local _, player = leads()
    local leashClass, dogClass, tree = asset(LEASH), asset(DOG), asset(TREE)
    if not leashClass or not dogClass or not tree then error("the dog's classes are missing") end
    local at = lead:K2_GetActorLocation()
    local leash = player:GetWorld():SpawnActor(leashClass, { X = at.X + 60, Y = at.Y, Z = at.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(leash) then error("no leash") end
    leash.leashHolder = lead
    local from = at
    pcall(function()
        local partner = lead.followerRef
        from = (valid(partner) and partner or lead).leashPosition:K2_GetComponentLocation()
    end)
    local dog = Core.object("/Script/AIModule.Default__AIBlueprintHelperLibrary"):SpawnAIFromClass(player, dogClass, tree,
        { X = from.X, Y = from.Y, Z = from.Z }, { Pitch = 0, Yaw = 0, Roll = 0 }, true)
    if not valid(dog) then
        pcall(function() leash:K2_DestroyActor() end)
        error("no dog")
    end
    dog.policemanRef = lead
    dog.leashRef = leash
    -- neither is written into a save: a loaded dog would look for a handler by a number
    -- patrols of the patrol areas never get
    for _, a in ipairs({ dog, leash }) do
        pcall(function()
            local saver = a.RamaSave
            if valid(saver) then saver:K2_DestroyComponent(a) end
        end)
    end
    entry.actor, entry.leash = dog, leash
end

local function give(lead, entry, copy)
    -- never a second dog for a patrol that has one
    local address = lead:GetAddress()
    for _, d in ipairs(Core.actors(DOG) or {}) do
        local ok, same = pcall(function() return valid(d.policemanRef) and d.policemanRef:GetAddress() == address end)
        if ok and same then
            entry.dog, entry.actor = true, d
            pcall(function() entry.leash = d.leashRef end)
            return true
        end
    end
    entry.dog = true
    local ok, e = pcall(attach, lead, entry)
    if ok then
        if copy then K9.stats.copies = K9.stats.copies + 1 else K9.stats.dogs = K9.stats.dogs + 1 end
        vlog("K9: a patrol %s has a dog", copy and "of another game" or "here")
    else
        entry.dog = false
        K9.stats.failed = K9.stats.failed + 1
        log("K9: a dog could not be made: %s", tostring(e))
    end
    return ok
end

local function isCopy(lead)
    local Pop = package.loaded["coop.pop"]
    if not Pop or not World.shared() then return false end
    local ok, copy = pcall(Pop.isCopy, lead)
    return ok and copy == true
end

-- Decides once for a patrol of this game. Returns whether it has a dog.
local function consider(lead)
    local list = leads()
    if not list or not on() then return false end
    local address = lead:GetAddress()
    local entry = list[address]
    if entry then return entry.dog == true and Core.alive(entry.actor) end
    entry = { dog = false }
    list[address] = entry
    if isCopy(lead) then return false end           -- its owner decides
    K9.stats.considered = K9.stats.considered + 1
    local ok, want = pcall(wanted, lead:K2_GetActorLocation())
    if ok and want and math.random() < chance() then return give(lead, entry, false) end
    return false
end

-- coop/pop.lua asks when it hands a patrol lead to another game.
function K9.hasDog(lead)
    local ok, has = pcall(consider, lead)
    return ok and has == true
end

-- coop/pop.lua: a copied patrol lead whose original has a dog.
function K9.copyHasDog(lead)
    if not on() then return end
    Core.after(0.6, function()
        local list = leads()
        if not list or not Core.alive(lead) then return end
        local address = lead:GetAddress()
        if list[address] and list[address].dog then return end
        list[address] = { dog = false }
        give(lead, list[address], true)
    end)
end

-- Patrols that appear are looked at within a few seconds; the list forgets the ones gone.
Core.every(3, function()
    if not on() then return end
    local list = leads()
    if not list or not Core.find("statisticsManager_C") then return end
    local out = Core.actors(LEAD)
    if not out then return end
    local still = {}
    for _, lead in ipairs(out) do
        pcall(function()
            local address = lead:GetAddress()
            if not list[address] then consider(lead) end
            still[address] = list[address]
        end)
    end
    -- a dog whose patrol is gone removes itself (the game's own check, every 3 s)
    state.leads = still
end)

---------------------------------------------------------------- after a search that found drugs

-- A fault of the game that dogs would make much worse. When the police find drugs the game
-- takes them with the inventory's "something changed" notice switched off, and switches it
-- on again only while it takes the fine from the cash in the pockets. A player with no
-- cash in the pockets is not fined, so the notice stays off and nothing looks at the
-- pockets again: hasDrugs and hasIllegalItems stay true with nothing there. A dog then goes
-- on smelling drugs and the next search "finds" them again. (In a shared world a guest
-- often has no cash in the pockets.) Some seconds after the game says "caught" (it waits 4 s
-- and more before it takes anything) the notice is switched on and sent, which is what the
-- fine would have done: the game's own handler then looks at the pockets and redraws them.
-- This is done with or without dogs.
Core.Hooks.add("/Game/Player/playerCharacterBP.playerCharacterBP_C:caughtInSearch", function()
    for _, t in ipairs({ 7, 10, 14, 20 }) do
        Core.after(t, function()
            local player = World.player()
            if not player then return end
            local ok = pcall(function()
                local inventory = player.InventoryComponent
                inventory:UnlockDispatcher()
                inventory:DispatchUpdate()
            end)
            if ok then K9.stats.looked = (K9.stats.looked or 0) + 1 end
        end)
    end
end)

-- Tests.
function K9.count()
    local n = 0
    for _, e in pairs(state.leads) do
        if e.dog and Core.alive(e.actor) then n = n + 1 end
    end
    return n
end
K9.state = function() return state end
K9.peerHot = function() return peerHot end

return K9
