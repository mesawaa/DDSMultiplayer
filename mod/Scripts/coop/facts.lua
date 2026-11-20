-- Facts about the shared world that the game keeps in each player's own story.
--
-- With separate storylines (coop/story.lua) the quest and gang managers are each player's
-- own. A few things the game decides there are really about the world, and in co-op they
-- go for everybody:
--
--   * Sector C. Whichever game sees the territory for it first opens it (the quest
--     manager's SectorCUnlocked, which is shared) and hears Eddie's call about it. The
--     guard at the gate lets a player through only after that call (eddieCalls[12]), and
--     the call also brings the sector's tasks. Every other player gets the call here, once
--     their story is in place, and their own "unlock sector C" step is done.
--   * Bad Asia. On Keiji's side the game offers the Bad Asia territory without the respect
--     it otherwise asks for (saleAreaManager.saleAreaAvailable[11]). The sale areas are
--     shared, so once any player is with Keiji the area is offered in every game and is
--     saved with the world.
--   * La Ballena's day. From Eddie telling a player about La Ballena until the morning
--     after their visit to the club, the police leave that player alone and no client
--     orders (questManager.ballenaProtection, read by every policeman, police dog and the
--     sales manager). In co-op it holds for everybody while it holds for anyone. What one
--     player has from another is never saved as their own: a save, and a guest's story
--     sent to the host, carry each player's own value.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")
local Story = require("coop.story")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Facts = { stats = { sectorC = 0, badAsia = 0, ballena = 0 } }

local QM = "questManager_C"
local QM_PATH = "/Game/WorldControlers/questManager.questManager_C"
local BAD_ASIA = 11          -- index in saleAreaManager.saleAreaStrings
local SECTOR_C_CALL = 12     -- index in questManager.eddieCalls (set when Eddie's call ends)

-- Only with separate storylines: otherwise the managers are one for everybody anyway.
local function on()
    return World.active and Core.enabled("Story") and Core.enabled("Orders")
end

local function storyReady()
    return World.role == "host" or Story.isReady()
end

---------------------------------------------------------------- sector C

local sectorC = { addr = nil, since = nil, done = nil }

local function tendSectorC(q)
    if q.SectorCUnlocked ~= true then return end
    local addr = q:GetAddress()
    if sectorC.done == addr then return end
    local heard = false
    pcall(function() heard = q.eddieCalls[SECTOR_C_CALL + 1] == true end)
    if heard then
        sectorC.done = addr
        return
    end
    -- the game's own call after a load comes 15 s in; this one later, and the call
    -- itself goes only once however often it is asked for
    if sectorC.addr ~= addr then
        sectorC.addr, sectorC.since = addr, os.clock()
        return
    end
    if os.clock() - sectorC.since < 25 then return end
    sectorC.done = addr
    local ok, e = pcall(function() q:eddieCallSectorC() end)
    log("Facts: sector C is open in this world; Eddie calls about it%s", ok and "" or (" (failed: " .. tostring(e) .. ")"))
    -- this player's own step "unlock sector C" (the game completes it only in the game
    -- that opened the sector)
    pcall(function()
        local id = q.SectorUnlockTaskID
        if type(id) == "number" and id > 0 and q.taskCompleted[id + 1] ~= true then
            q:markTaskStatus(id, 1)
            q.SectorUnlockTaskID = 0
            log("Facts: your step to unlock sector C is done")
        end
    end)
    Facts.stats.sectorC = Facts.stats.sectorC + 1
end

-- The game that opens the sector has Eddie's call from the game itself.
Core.Hooks.add(QM_PATH .. ":UnlockSectorC", function(ctx)
    local q = ctx:get()
    if valid(q) then sectorC.done = q:GetAddress() end
end)

---------------------------------------------------------------- Bad Asia

local function tendBadAsia()
    local gangs = Repl.singleton("gangManager_C")
    if not gangs or gangs.keijiUnlocked ~= true then return end
    local areas = Repl.singleton("saleAreaManager_C")
    if not areas then return end
    local name, available = nil, nil
    pcall(function()
        name = areas.saleAreaStrings[BAD_ASIA + 1]:ToString()
        available = areas.saleAreaAvailable[BAD_ASIA + 1]
    end)
    if name ~= "BAD_ASIA" or available ~= false then return end
    local text = Repl.export(areas, { "saleAreaAvailable" }).saleAreaAvailable
    if not text then return end
    local e = Repl.splitArray(text)
    if not e[BAD_ASIA + 1] then return end
    e[BAD_ASIA + 1] = "True"
    Repl.import(areas, { saleAreaAvailable = Repl.joinArray(e) })
    Facts.stats.badAsia = Facts.stats.badAsia + 1
    log("Facts: you are with Keiji: Bad Asia is offered in this world")
end

---------------------------------------------------------------- La Ballena's day

-- own: this player's own protection; borrowed: true while this game holds protection
-- that is another player's; mark: this player's meeting task when it was borrowed (a new
-- one means La Ballena has now approached this player as well).
local ballena = { own = false, borrowed = false, mark = nil, world = false, guests = {}, sentOwn = nil, sentAt = 0, sentWorld = nil, told = false }

local function setProtection(q, value)
    pcall(function() q.ballenaProtection = value end)
end

-- The protection the world has right now (host: anybody's; guest: as the host said).
local function worldProtection()
    if World.role ~= "host" then return ballena.world end
    if ballena.own then return true end
    for id, v in pairs(ballena.guests) do
        if v and World.inWorld[id] then return true end
    end
    return false
end

local function tendBallena(q)
    local cur = q.ballenaProtection == true
    if ballena.borrowed then
        local visited, meeting = false, nil
        pcall(function() visited = Repl.singleton("gangManager_C").ballenaVisited == true end)
        pcall(function() meeting = q.meetGangTaskID end)
        if cur and meeting ~= ballena.mark and not visited then
            -- La Ballena has approached this player too: the protection is their own now
            ballena.own, ballena.borrowed = true, false
        end
    else
        -- (the end of this player's own protection: the host's word about the world still
        -- counts it for a moment)
        if ballena.own and not cur then ballena.ownEndedAt = os.clock() end
        ballena.own = cur
    end
    -- tell the others
    local now = os.clock()
    if World.role == "guest" then
        if ballena.sentOwn ~= ballena.own or now - ballena.sentAt > 10 then
            ballena.sentOwn, ballena.sentAt = ballena.own, now
            Net.send("blo", { o = ballena.own and 1 or 0 }, World.host or Net.S.owner)
        end
    else
        local w = worldProtection()
        if ballena.sentWorld ~= w or now - ballena.sentAt > 10 then
            ballena.sentWorld, ballena.sentAt = w, now
            for id in pairs(World.inWorld) do Net.send("blw", { p = w and 1 or 0 }, id) end
        end
    end
    local w = worldProtection()
    if World.role == "guest" and now - (ballena.ownEndedAt or -100) < 5 then w = false end
    if w and not ballena.own then
        if not cur then setProtection(q, true) end
        if not ballena.borrowed then
            ballena.borrowed = true
            pcall(function() ballena.mark = q.meetGangTaskID end)
            Facts.stats.ballena = Facts.stats.ballena + 1
            log("Facts: La Ballena's protection holds for this player too")
            if not ballena.told then
                ballena.told = true
                Net.notify("La Ballena has approached one of you: the police leave everybody alone today.")
            end
        end
    elseif ballena.borrowed then
        ballena.borrowed = false
        setProtection(q, false)
        log("Facts: La Ballena's protection is over")
    end
end

Net.on("blo", function(sender, data)
    if World.role ~= "host" or not World.inWorld[sender] or type(data) ~= "table" then return end
    ballena.guests[sender] = data.o == 1
end)

Net.on("blw", function(sender, data)
    if World.role ~= "guest" or sender ~= (World.host or Net.S.owner) or type(data) ~= "table" then return end
    ballena.world = data.p == 1
end)

World.listen("peerleft", function(id) ballena.guests[id] = nil end)

-- The game's own check (every ten seconds) ends the protection of a player who has been to
-- the club, after six in the morning: what is borrowed is put back at once, before any
-- policeman looks.
Core.Hooks.add(QM_PATH .. ":checkLevelUnlocks", function(ctx)
    if not ballena.borrowed or not on() then return end
    local q = ctx:get()
    if valid(q) and q.ballenaProtection ~= true then setProtection(q, true) end
end)

-- Never saved as this player's own: the world file of the host, and a guest's story sent
-- to the host (coop/story.lua asks here).
pcall(RegisterHook, "/Script/RamaSaveSystem.RamaSaveLibrary:RamaSave_SaveToFile", function()
    if not ballena.borrowed then return end
    local q = Repl.singleton(QM)
    if q then setProtection(q, false) end
    Core.after(0.05, function()
        local again = ballena.borrowed and Repl.singleton(QM)
        if again then setProtection(again, true) end
    end)
end, function() end)

Story.profileFilter = function(profile)
    if not ballena.borrowed or type(profile.vars) ~= "table" then return end
    for name in pairs(profile.vars) do
        if type(name) == "string" and name:lower() == "ballenaprotection" then profile.vars[name] = "False" end
    end
end

---------------------------------------------------------------- the ATMs

-- The cash machines say "out of order" until the story's bank step switches them on, and
-- the game does that only in the game whose quest manager runs the step (`introduceBank`:
-- `unlockAtm` on every atmMachine, then bankWasIntroduced). With one storyline for
-- everybody the step runs in one game and arrives in the others as task table and quest
-- variables only: their machines stayed out of order, "Check out the ATM" could not be
-- done there, and the step never runs again once bankWasIntroduced is set (reported with
-- 0.18.0, Sync.Story off). So in every game, once this game's quest manager says the bank
-- was introduced, every machine still switched off is switched on as the game does it.
-- Independent of Sync.Story: with separate storylines bankWasIntroduced is the player's own.
local ATM = "/Game/Interactive/atmMachine.atmMachine_C"
local atm = { addr = nil, done = false, at = 0, useText = nil }

local function atmUseText()
    if atm.useText then return atm.useText end
    pcall(function()
        local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        atm.useText = lib:TextFromStringTable(FName("/Game/StringTables/strTable_interfaceActionNames.strTable_interfaceActionNames"), "ACTION-USE")
    end)
    return atm.useText
end

local function tendAtms(q)
    if q.bankWasIntroduced ~= true then return end
    local addr = q:GetAddress()
    if atm.addr ~= addr then atm.addr, atm.done, atm.at = addr, false, 0 end
    -- once all are on, a look now and then (cheap, but there is no need for more)
    local now = os.clock()
    if atm.done and now - atm.at < 30 then return end
    atm.at = now
    local list = Core.actors(ATM)
    if not list then return end
    local switched = 0
    for _, m in ipairs(list) do
        if valid(m) and m.atmActive ~= true then
            pcall(function() m:unlockAtm() end)
            -- the step already done: the machine reads USE, as after a load
            if q.atmWasActivated == true then
                local text = atmUseText()
                if text then pcall(function() m.objActionName = text end) end
            end
            switched = switched + 1
        end
    end
    pcall(function()
        local computer = Repl.singleton("mainComputer_C")
        if computer and computer.bankAvailable ~= true then computer.bankAvailable = true end
    end)
    atm.done = true
    if switched > 0 then
        Facts.stats.atms = (Facts.stats.atms or 0) + switched
        log("Facts: the bank step has been reached; %d of %d ATM(s) were still out of order here and are switched on", switched, #list)
    end
end

---------------------------------------------------------------- lifecycle

local function reset()
    sectorC = { addr = nil, since = nil, done = nil }
    atm.addr, atm.done, atm.at = nil, false, 0
    ballena = { own = false, borrowed = false, mark = nil, world = false, guests = {}, sentOwn = nil, sentAt = 0, sentWorld = nil, told = false }
end

World.listen("start", reset)
World.listen("stop", function()
    if ballena.borrowed and not World.gone then
        local q = Repl.singleton(QM)
        if q then setProtection(q, false) end
        log("Facts: La Ballena's protection of another player no longer holds here")
    end
    reset()
end)

Core.every(1, function()
    if not on() or not storyReady() then return end
    local q = Repl.singleton(QM)
    if not q then return end
    local ok, e = pcall(tendBallena, q)
    if not ok then log("Facts: %s", tostring(e)) end
end)

Core.every(3, function()
    if not on() or not storyReady() then return end
    local q = Repl.singleton(QM)
    if not q then return end
    local ok, e = pcall(tendSectorC, q)
    if not ok then log("Facts: %s", tostring(e)) end
    ok, e = pcall(tendBadAsia)
    if not ok then log("Facts: %s", tostring(e)) end
end)

-- (any storyline setting)
Core.every(5, function()
    if not World.active or not Core.enabled("Orders") or not storyReady() then return end
    local q = Repl.singleton(QM)
    if not q then return end
    local ok, e = pcall(tendAtms, q)
    if not ok then log("Facts: %s", tostring(e)) end
end)

function Facts.state() return { sectorC = sectorC, ballena = ballena, atm = atm } end

return Facts
