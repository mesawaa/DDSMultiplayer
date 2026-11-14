-- One street population for everyone: passers-by, police patrols and sample clients.
--
-- Every such NPC belongs to the game that spawned it (its "owner"). While it is near
-- another player, the owner has that player's game spawn a copy: a real NPC of the same
-- class whose own behaviour tree is stopped and which walks to wherever the original is
-- (positions arrive twice a second). So all players see the same people in the same
-- places, and can talk to them.
--
-- Police stay dangerous to everybody: an officer's perception runs on the NPC itself, so
-- a copy still notices the local player. When it does, its behaviour tree is restarted,
-- it chases and can arrest like any officer, and this game "drives" it until the chase
-- is over (the original then follows the copy). One game drives an officer at a time.
--
-- Any number of players: every game exchanges its NPCs with every other game in the
-- world, each pair by itself. Where players stand close together only one of their games
-- populates the street (the host's, else the guest with the lowest id among them): the
-- others stop their own spawners and see that game's people. Far apart, each game
-- populates the area around its own player.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")
local Avatar = require("coop.avatar")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

-- owned: our id (number) -> { npc, family, to = { peer -> true }, said = { peer -> text }, saidAt = { peer -> time },
--                             quiet = { peer -> time }, driver, target, localChase, checkAt }
-- copies: "owner:id" -> { npc, family, owner, n, engaged, bornAt, pair = "owner:id", target, ... }
local Pop = { owned = {}, copies = {}, stats = { announced = 0, copied = 0, removed = 0, engaged = 0, suppressed = 0, denied = 0 } }

local RELEVANT_IN = 12000        -- copy an NPC to another game when it is this close to that player
local RELEVANT_OUT = 15000       -- and remove the copy again beyond this
local TOGETHER = 9000            -- players closer than this share one game's population
local TELEPORT = 900             -- a copy further than this from its original is put in place
local ARRIVE = 70                -- a copy closer than this to its target stands still
local RELEASE_AFTER = 8          -- seconds without suspicion before a driven officer is handed back
local REPEAT = 4                 -- an NPC that does not move is reported again after this long
-- needsDrugs and sampleAreaAffected are what makes somebody a potential client: without
-- them a copy can be talked to but cannot be given a sample.
local LOOK_VARS = { "clientLooks", "hasLooksSet", "isMale", "characterName", "characterSurname", "characterFullName", "isStreetPerson", "firstArea",
    "needsDrugs", "sampleAreaAffected" }

local applying = false           -- true while this module spawns or destroys on behalf of a peer
local counter = 0
local policeUnlock = nil         -- this game's own value of policeManager.unlockPatrolSpawning
local together = false           -- true while another game populates the street around our player
local aiLib = nil
local reconcilePopulation        -- defined below
-- A patrol can have a dog (coop/k9.lua, loaded after this file).
local function k9() return package.loaded["coop.k9"] end
local suspicious                 -- defined below

local function ai()
    if not valid(aiLib) then aiLib = StaticFindObject("/Script/AIModule.Default__AIBlueprintHelperLibrary") end
    return aiLib
end

-- Which shared family an NPC belongs to, or nil if it is not part of the street population.
local function family(actor)
    local name = actor:GetClass():GetFName():ToString()
    if name:find("^streetPerson") then return "street" end
    if name == "PM_PatrolLead_C" or name == "PM_PatrolPartner_C" then return "police" end
    if name == "sampleClientBP_C" then return "sample" end
    return nil
end

local function classPath(actor)
    return actor:GetClass():GetFullName():match("^%S+%s+(.+)$")
end

local function loadClass(path)
    local class = StaticFindObject(path)
    if valid(class) then return class end
    pcall(function() LoadAsset(path:gsub("_C$", "")) end)
    class = StaticFindObject(path)
    if valid(class) then return class end
    return nil
end

local function copyKey(owner, id) return tostring(owner) .. ":" .. tostring(id) end

local function dist2(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return dx * dx + dy * dy + dz * dz
end

local function brain(npc)
    local controller = npc:GetController()
    if not valid(controller) then return nil, nil end
    local b = controller.BrainComponent
    if valid(b) then return b, controller end
    return nil, controller
end

local function stopThinking(npc)
    pcall(function()
        local b = brain(npc)
        if b and b:IsRunning() then b:StopLogic("coop") end
    end)
end

local function startThinking(npc)
    pcall(function()
        local b = brain(npc)
        if b then b:RestartLogic() end
    end)
end

---------------------------------------------------------------- who populates the street

local function setSpawners(enabled)
    if enabled then reconcilePopulation() end
    pcall(function()
        local population = Core.find("populationManager_C")
        if population then population.DisableSpawning = not enabled end
    end)
    pcall(function()
        local police = Core.find("policeManager_C")
        if not police then return end
        if policeUnlock == nil then policeUnlock = police.unlockPatrolSpawning == true end
        police.unlockPatrolSpawning = enabled and policeUnlock or false
    end)
end

-- The order in which games get to populate a street: the host, then the guests by id.
local function before(a, b, host)
    if a == host then return b ~= host end
    if b == host then return false end
    return (tonumber(a) or 0) < (tonumber(b) or 0)
end

-- Works out for every player whether their game populates the street around them: a player
-- does unless an earlier one who does is close by. Every game does the same sum from the
-- same positions, so they agree. Returns whether ours does.
local function weSpawn(loc)
    local me, host = Net.S.me, World.role == "host" and Net.S.me or (World.host or Net.S.owner)
    if me == host then return true end
    local players = { { id = me, x = loc.X, y = loc.Y, z = loc.Z } }
    for _, id in ipairs(World.others()) do
        local x, y, z = Avatar.peerPosition(id)
        if x then players[#players + 1] = { id = id, x = x, y = y, z = z } end
    end
    table.sort(players, function(a, b) return before(a.id, b.id, host) end)
    local spawning = {}
    for i, p in ipairs(players) do
        local alone = true
        for j = 1, i - 1 do
            local q = players[j]
            if spawning[q.id] then
                -- a little slack for whoever is sharing already, so that nobody flips at the edge
                local reach = TOGETHER
                if (p.id == me or q.id == me) and together then reach = TOGETHER * 1.15 end
                if dist2(p.x, p.y, p.z, q.x, q.y, q.z) <= reach * reach then
                    alone = false
                    break
                end
            end
        end
        spawning[p.id] = alone
    end
    return spawning[me] == true
end

local function updateTogether(loc)
    if World.role == "host" then return end
    local now = not weSpawn(loc)
    if now ~= together then
        together = now
        setSpawners(not together)
        vlog("Pop: %s, own spawners %s", together and "another game populates this street" or "nobody else populates this street", together and "off" or "on")
    end
end

-- The game saves how many passers-by are out but not the passers-by themselves, so a
-- loaded world can believe its streets are full while they are empty, and then never
-- spawns anyone. Counts what is really there.
reconcilePopulation = function()
    local ok, e = pcall(function()
        local population = Core.find("populationManager_C")
        if not population then return end
        local live, present = 0, {}
        for _, npc in ipairs(Core.actors("/Game/Skeletal/NPC/baseNPC.baseNPC_C") or FindAllOf("baseNPC_C") or {}) do
            pcall(function()
                if Core.alive(npc) and family(npc) == "street" and not Pop.isCopy(npc) then
                    live = live + 1
                    present[npc:GetClass():GetAddress()] = true
                end
            end)
        end
        local before = population.peopleOnStreetCurrent
        if before == live then return end
        population.peopleOnStreetCurrent = live
        local flags = {}
        population.npcClasses:ForEach(function(_, elem)
            local class = elem:get()
            flags[#flags + 1] = (valid(class) and present[class:GetAddress()] == true) and "True" or "False"
        end)
        if #flags > 0 then Repl.import(population, { isOnStreets = "(" .. table.concat(flags, ",") .. ")" }) end
        vlog("Pop: the game counted %s passers-by, %d are really out; corrected", tostring(before), live)
    end)
    if not ok then log("Pop: counting passers-by failed: %s", tostring(e)) end
end

---------------------------------------------------------------- owning NPCs

local function adopt(npc, fam)
    counter = counter + 1
    Pop.owned[counter] = { npc = npc, family = fam, to = {}, said = {}, saidAt = {}, quiet = {} }
end

local function remove(npc)
    applying = true
    pcall(function() npc:K2_DestroyActor() end)
    applying = false
end

local function isLead(npc)
    return npc:GetClass():GetFName():ToString() == "PM_PatrolLead_C"
end

-- Ties a copied patrol lead and its copied partner together the way the game does, so
-- the lead neither spawns another partner nor gives up for lack of one.
local function linkPair(key)
    local a = Pop.copies[key]
    local b = a and a.pair and Pop.copies[a.pair]
    if not a or not b or not Core.alive(a.npc) or not Core.alive(b.npc) then return end
    local lead, partner = a, b
    if not isLead(a.npc) then lead, partner = b, a end
    pcall(function()
        lead.npc.followerRef = partner.npc
        partner.npc.PatrolLead = lead.npc
        partner.npc.LeadID = lead.npc.MyID
    end)
end

-- A copied patrol lead spawns a partner of its own. Returns the copied lead standing next
-- to this freshly spawned officer, if that is what happened.
local function copiedLeadNear(npc)
    local ok, loc = pcall(function() return npc:K2_GetActorLocation() end)
    if not ok then return nil end
    for key, c in pairs(Pop.copies) do
        if c.family == "police" and Core.alive(c.npc) and isLead(c.npc) then
            local p = c.npc:K2_GetActorLocation()
            if dist2(loc.X, loc.Y, loc.Z, p.X, p.Y, p.Z) < 600 * 600 then return key, c end
        end
    end
    return nil
end

pcall(RegisterHook, "/Script/AIModule.AIBlueprintHelperLibrary:SpawnAIFromClass", function() end, function(_, ret)
    if applying or not World.shared() or not Core.enabled("Population") then return end
    local ok, npc = pcall(function() return ret:get() end)
    if not ok or not valid(npc) then return end
    local fam = family(npc)
    if not fam then return end
    -- The spawning Blueprint is still using the NPC; decide a moment later.
    Core.after(0.3, function()
        if not Core.alive(npc) or not World.shared() then return end
        local leadKey, lead = nil, nil
        if fam == "police" and not isLead(npc) then leadKey, lead = copiedLeadNear(npc) end
        if lead then
            -- The partner a copied lead made for itself. If the owner's partner has not
            -- arrived yet, this one stands in for it; otherwise it is surplus.
            if lead.pair and not Pop.copies[lead.pair] then
                local n = tonumber(lead.pair:match(":(%-?%d+)$"))
                Pop.copies[lead.pair] = { npc = npc, family = "police", owner = lead.owner, n = n, engaged = false, bornAt = os.clock(), pair = leadKey }
                linkPair(leadKey)
            else
                remove(npc)
                Pop.stats.suppressed = Pop.stats.suppressed + 1
                if lead.pair then linkPair(leadKey) end
            end
        elseif together then
            remove(npc)
            Pop.stats.suppressed = Pop.stats.suppressed + 1
        else
            adopt(npc, fam)
        end
    end)
end)

-- Takes stock when a shared world starts. The host owns what is on its streets. A guest
-- has just loaded a copy of those same NPCs from the host's save and gets rid of them:
-- the host will send the real ones.
local function takeStock(role)
    Pop.owned, Pop.copies, counter, together, policeUnlock = {}, {}, 0, false, nil
    local seen = {}
    for _, className in ipairs({ "baseNPC_C", "PolicemanBaseClass_C" }) do
        for _, npc in ipairs(FindAllOf(className) or {}) do
            pcall(function()
                if Core.alive(npc) and not seen[npc:GetAddress()] then
                    seen[npc:GetAddress()] = true
                    local fam = family(npc)
                    if fam then
                        if role == "guest" then remove(npc) else adopt(npc, fam) end
                    end
                end
            end)
        end
    end
    if role == "guest" then
        together = true
        setSpawners(false)
    else
        reconcilePopulation()
    end
    local n = 0
    for _ in pairs(Pop.owned) do n = n + 1 end
    log("Pop: world started as %s, %d street NPC(s) owned", tostring(role), n)
end

---------------------------------------------------------------- sending

local function ownedId(npc)
    if not valid(npc) then return nil end
    local addr = npc:GetAddress()
    for id, e in pairs(Pop.owned) do
        if valid(e.npc) and e.npc:GetAddress() == addr then return id end
    end
    return nil
end

-- The other half of a patrol, as one of our ids.
local function pairOf(npc)
    local ok, other = pcall(function()
        if isLead(npc) then return npc.followerRef end
        return npc.PatrolLead
    end)
    if ok then return ownedId(other) end
    return nil
end

local function describe(npc)
    local loc, rot, vel = npc:K2_GetActorLocation(), npc:K2_GetActorRotation(), npc:GetVelocity()
    return loc.X, loc.Y, loc.Z, rot.Yaw, math.sqrt(vel.X * vel.X + vel.Y * vel.Y)
end

local function round(v) return math.floor(v + 0.5) end

local function sendUpdates()
    local peers = World.others()
    if #peers == 0 then return end
    local now = os.clock()
    local place, anyPlace = {}, false
    for _, id in ipairs(peers) do
        local x, y, z = Avatar.peerPosition(id)
        if x then
            place[id] = { x, y, z }
            anyPlace = true
        end
    end
    local lists = {}         -- peer -> positions of our NPCs it has a copy of
    for id, e in pairs(Pop.owned) do
        if not Core.alive(e.npc) then
            for peer in pairs(e.to) do Net.send("pg", { n = id }, peer) end
            Pop.owned[id] = nil
        elseif anyPlace and (next(e.to) ~= nil or now >= (e.checkAt or 0)) then
            -- An NPC nobody has a copy of is only looked at now and then (reading where it
            -- is takes a dozen calls into the game).
            local ok, x, y, z, yaw, speed = pcall(describe, e.npc)
            if ok then
                local nearest = math.huge
                local text = nil
                for peer, p in pairs(place) do
                    local d = dist2(x, y, z, p[1], p[2], p[3])
                    if d < nearest then nearest = d end
                    if not e.to[peer] and not e.retired and d <= RELEVANT_IN * RELEVANT_IN and now >= (e.quiet[peer] or 0) then
                        e.to[peer] = true
                        Net.send("pn", { n = id, c = classPath(e.npc), f = e.family, x = round(x), y = round(y), z = round(z), yw = round(yaw),
                            pr = e.family == "police" and pairOf(e.npc) or nil, v = Repl.export(e.npc, LOOK_VARS),
                            k = (e.family == "police" and k9() and isLead(e.npc) and k9().hasDog(e.npc)) or nil }, peer)
                        Pop.stats.announced = Pop.stats.announced + 1
                    elseif e.to[peer] and d > RELEVANT_OUT * RELEVANT_OUT then
                        e.to[peer], e.said[peer], e.saidAt[peer] = nil, nil, nil
                        if e.driver == peer then
                            e.driver, e.target = nil, nil
                            startThinking(e.npc)
                        end
                        Net.send("pg", { n = id }, peer)
                    end
                    -- The game that drives this officer tells us where it is; everybody
                    -- else hears it from us (our officer follows the driver's).
                    if e.to[peer] and e.driver ~= peer then
                        text = text or (round(x) .. "," .. round(y) .. "," .. round(z) .. "," .. round(yaw) .. "," .. round(speed))
                        if e.said[peer] ~= text or now - (e.saidAt[peer] or 0) >= REPEAT then
                            e.said[peer], e.saidAt[peer] = text, now
                            local l = lists[peer]
                            if not l then
                                l = {}
                                lists[peer] = l
                            end
                            local n = #l
                            l[n + 1], l[n + 2], l[n + 3], l[n + 4], l[n + 5], l[n + 6] = id, round(x), round(y), round(z), round(yaw), round(speed)
                        end
                    end
                end
                if next(e.to) == nil then
                    local far = RELEVANT_IN + 4000
                    e.checkAt = now + (nearest > far * far and 2.5 or 0.5)
                end
            end
        end
    end
    -- At most 30 NPCs per message keeps each one small enough for any transport.
    for peer, l in pairs(lists) do
        for start = 1, #l, 180 do
            Net.send("pt", { o = table.move(l, start, math.min(start + 179, #l), 1, {}) }, peer)
        end
    end
    -- Officers we drive: their owners follow them.
    local driven = {}
    for _, c in pairs(Pop.copies) do
        if c.engaged and Core.alive(c.npc) then
            local ok, x, y, z, yaw, speed = pcall(describe, c.npc)
            if ok then
                local l = driven[c.owner]
                if not l then
                    l = {}
                    driven[c.owner] = l
                end
                local n = #l
                l[n + 1], l[n + 2], l[n + 3], l[n + 4], l[n + 5], l[n + 6] = c.n, round(x), round(y), round(z), round(yaw), round(speed)
            end
        end
    end
    for owner, l in pairs(driven) do Net.send("pt", { e = l }, owner) end
end

---------------------------------------------------------------- receiving

local function follow(npc, t)
    local loc = npc:K2_GetActorLocation()
    -- Where the original will be by the time the copy has reacted (positions are ~0.5 s old).
    local ahead = t.speed * math.min(1.0, os.clock() - t.at + 0.6)
    local yaw = math.rad(t.yaw)
    local tx, ty = t.x + math.cos(yaw) * ahead, t.y + math.sin(yaw) * ahead
    local d = dist2(loc.X, loc.Y, loc.Z, tx, ty, t.z)
    if d > TELEPORT * TELEPORT then
        npc:K2_SetActorLocationAndRotation({ X = t.x, Y = t.y, Z = t.z + 5 }, { Pitch = 0, Yaw = t.yaw, Roll = 0 }, false, {}, true)
        return
    end
    local _, controller = brain(npc)
    if d > ARRIVE * ARRIVE then
        -- The same walk is not ordered again and again: only when the goal has moved.
        local g = t.goal
        if g and math.abs(g.x - tx) < 40 and math.abs(g.y - ty) < 40 and os.clock() - g.at < 2 then return end
        t.goal = { x = tx, y = ty, at = os.clock() }
        pcall(function()
            -- A little faster than the original so the copy closes the gap instead of trailing.
            npc.CharacterMovement.MaxWalkSpeed = math.max(90, math.min(700, t.speed * 1.2 + math.sqrt(d) * 0.15))
        end)
        -- The street's people are steered by crowd controllers. Those take the AI's own
        -- move order; the simple one (made for player characters) is accepted and then
        -- nothing happens, so a copy stood still until it was far enough behind to be put
        -- in place: nobody walked on the other players' screens.
        if controller then
            local ok = pcall(function() controller:MoveToLocation({ X = tx, Y = ty, Z = t.z }, 25, false, true, true, true, nil, true) end)
            if not ok then ai():SimpleMoveToLocation(controller, { X = tx, Y = ty, Z = t.z }) end
        end
    elseif t.speed < 15 then
        if t.stood then return end
        t.stood = true
        if controller then pcall(function() controller:StopMovement() end) end
        npc:K2_SetActorRotation({ Pitch = 0, Yaw = t.yaw, Roll = 0 }, false)
    end
end

local function applyTargets(list, lookup)
    if type(list) ~= "table" then return end
    for i = 1, #list - 5, 6 do
        local entry = lookup(list[i])
        if entry then entry.target = { x = list[i + 1], y = list[i + 2], z = list[i + 3], yaw = list[i + 4], speed = list[i + 5], at = os.clock() } end
    end
end

local function trusted(sender)
    return Core.enabled("Population") and World.isPeer(sender)
end

Net.on("pn", function(sender, data)
    if not trusted(sender) then return end
    local n = tonumber(data.n)
    local player = World.player()
    if not n or not player then return end
    local key = copyKey(sender, n)
    local pairKey = tonumber(data.pr) and copyKey(sender, tonumber(data.pr)) or nil
    if Pop.copies[key] then
        -- Already here (a partner the copied lead made itself): just note what it pairs with.
        Pop.copies[key].pair = pairKey or Pop.copies[key].pair
        linkPair(key)
        return
    end
    local class = loadClass(tostring(data.c))
    if not class then return end
    applying = true
    local ok, e = pcall(function()
        local npc = ai():SpawnAIFromClass(player, class, nil, { X = data.x, Y = data.y, Z = data.z + 10 },
            { Pitch = 0, Yaw = data.yw or 0, Roll = 0 }, true)
        if not valid(npc) then error("spawn returned nothing") end
        if type(data.v) == "table" then
            Repl.import(npc, data.v)
            pcall(function() npc:setClientLooks() end)
        end
        Pop.copies[key] = { npc = npc, family = tostring(data.f), owner = sender, n = n, engaged = false, bornAt = os.clock(), pair = pairKey }
        if data.k == true and k9() then k9().copyHasDog(npc) end
    end)
    applying = false
    if ok then
        linkPair(key)
        Pop.stats.copied = Pop.stats.copied + 1
    else
        log("Pop: could not copy %s: %s", tostring(data.c), tostring(e))
    end
end)

Net.on("pg", function(sender, data)
    if not trusted(sender) then return end
    local key = copyKey(sender, tonumber(data.n) or -1)
    local c = Pop.copies[key]
    if not c then return end
    Pop.copies[key] = nil
    if Core.alive(c.npc) then remove(c.npc) end
    Pop.stats.removed = Pop.stats.removed + 1
end)

Net.on("pt", function(sender, data)
    if not trusted(sender) then return end
    -- "o": NPCs the sender owns (our copies). "e": NPCs we own that the sender drives.
    applyTargets(data.o, function(id)
        local c = Pop.copies[copyKey(sender, id)]
        if c and not c.engaged then return c end
    end)
    applyTargets(data.e, function(id)
        local e = Pop.owned[id]
        if e and e.driver == sender then return e end
    end)
end)

-- "pd": the sender's copy of one of our NPCs is gone; offer it again after a moment.
Net.on("pd", function(sender, data)
    if not trusted(sender) then return end
    local e = Pop.owned[tonumber(data.n) or -1]
    if not e then return end
    e.to[sender], e.said[sender], e.saidAt[sender] = nil, nil, nil
    e.quiet[sender] = os.clock() + 6
    if e.driver == sender then
        e.driver, e.target = nil, nil
        if Core.alive(e.npc) then startThinking(e.npc) end
    end
end)

-- "pa": the sender starts or stops driving one of our officers.
Net.on("pa", function(sender, data)
    if not trusted(sender) then return end
    if data.deny then
        -- The owner keeps this officer (for its own chase, or another player's); our copy
        -- goes back to following.
        local c = Pop.copies[copyKey(sender, tonumber(data.n) or -1)]
        if c then
            c.engaged, c.calmSince = false, nil
            c.denyUntil = os.clock() + 15
            if Core.alive(c.npc) then
                pcall(function() c.npc:EndChase(false, false) end)
                stopThinking(c.npc)
            end
            vlog("Pop: officer %s stays on another player", tostring(data.n))
        end
        return
    end
    local e = Pop.owned[tonumber(data.n) or -1]
    if not e or not Core.alive(e.npc) then return end
    if data.on then
        -- One game drives an officer at a time.
        if e.driver and e.driver ~= sender then
            Net.send("pa", { n = tonumber(data.n), deny = true }, sender)
            Pop.stats.denied = Pop.stats.denied + 1
            return
        end
        -- A patrol that is already after our player splits up: the partner may go after
        -- the other player, the lead (or a lone officer) stays on ours.
        if not e.driver and suspicious(e.npc) then
            local partnerOfPair = e.family == "police" and not isLead(e.npc) and pairOf(e.npc) ~= nil
            if not partnerOfPair then
                Net.send("pa", { n = tonumber(data.n), deny = true }, sender)
                Pop.stats.denied = Pop.stats.denied + 1
                vlog("Pop: officer %s keeps chasing here; %s was told so", tostring(data.n), Net.name(sender))
                return
            end
            vlog("Pop: the patrol splits up, officer %s goes after %s", tostring(data.n), Net.name(sender))
        end
        e.driver = sender
        stopThinking(e.npc)
        vlog("Pop: officer %s is now driven by %s", tostring(data.n), Net.name(sender))
    elseif e.driver == sender then
        e.driver, e.target = nil, nil
        startThinking(e.npc)
        vlog("Pop: officer %s handed back", tostring(data.n))
    end
end)

---------------------------------------------------------------- police that notice the local player

local function copyOf(npc)
    local addr = npc:GetAddress()
    for key, c in pairs(Pop.copies) do
        if valid(c.npc) and c.npc:GetAddress() == addr then return key, c end
    end
    return nil
end

local function ownedOf(npc)
    local addr = npc:GetAddress()
    for id, e in pairs(Pop.owned) do
        if valid(e.npc) and e.npc:GetAddress() == addr then return id, e end
    end
    return nil
end

-- Called when an officer in this game starts suspecting or chasing the local player.
local function onSuspicion(ctx)
    if not World.shared() or not Core.enabled("Population") then return end
    local npc = ctx:get()
    if not valid(npc) then return end
    local key, c = copyOf(npc)
    if c and not c.engaged and os.clock() < (c.denyUntil or 0) then return end
    if c and not c.engaged then
        c.engaged, c.calmSince, c.target = true, nil, nil
        startThinking(npc)
        Net.send("pa", { n = c.n, on = true }, c.owner)
        Pop.stats.engaged = Pop.stats.engaged + 1
        vlog("Pop: copied officer %s noticed the local player, driving it here", key)
        return
    end
    local _, e = ownedOf(npc)
    if e and e.driver then
        -- Our own officer, driven elsewhere, now wants our player too: it thinks for itself again.
        e.localChase = true
        startThinking(npc)
    end
end

for _, fn in ipairs({ "EngageSuspect", "SetChaseMode", "forceSuspect" }) do
    Core.Hooks.add("/Game/Skeletal/NPC/Policeman/PolicemanBaseClass.PolicemanBaseClass_C:" .. fn, onSuspicion)
end

suspicious = function(npc)
    local ok, result = pcall(function() return npc.alerted == true or npc.suspectMode == true end)
    return ok and result
end

local function releaseCalmOfficers()
    local now = os.clock()
    for key, c in pairs(Pop.copies) do
        if c.engaged and Core.alive(c.npc) then
            if suspicious(c.npc) then
                c.calmSince = nil
            else
                c.calmSince = c.calmSince or now
                if now - c.calmSince >= RELEASE_AFTER then
                    c.engaged, c.calmSince = false, nil
                    stopThinking(c.npc)
                    Net.send("pa", { n = c.n, on = false }, c.owner)
                    vlog("Pop: copied officer %s calmed down, handed back", key)
                end
            end
        end
    end
    for _, e in pairs(Pop.owned) do
        if e.localChase and Core.alive(e.npc) and not suspicious(e.npc) then
            e.localChase = false
            if e.driver then stopThinking(e.npc) end
        end
    end
end

---------------------------------------------------------------- potential clients are used up for everybody

-- A potential client who was given a sample (or sent away) in one game walks off there.
-- The same person in the other games has to stop being a potential client too, or every
-- player could give them a sample of their own.
local SAMPLE = "/Game/Skeletal/NPC/sampleClientBP.sampleClientBP_C"

local function retire(npc)
    applying = true
    pcall(function() npc:makeGoHome() end)
    applying = false
end

Core.Hooks.add(SAMPLE .. ":makeGoHome", function(ctx)
    if applying or not World.shared() or not Core.enabled("Population") then return end
    local npc = ctx:get()
    if not valid(npc) then return end
    local key, c = copyOf(npc)
    if c then
        if not c.retired then
            c.retired = true
            Net.send("ps", { n = c.n }, c.owner)
            vlog("Pop: the copied potential client %s is done here, its owner was told", key)
        end
        return
    end
    local id, e = ownedOf(npc)
    if e and not e.retired then
        e.retired = true
        for peer in pairs(e.to) do Net.send("ps", { n = id }, peer) end
        vlog("Pop: potential client %s is done here", tostring(id))
    end
end)

-- "ps": the sender's potential client (our copy), or its copy of ours, is done.
Net.on("ps", function(sender, data)
    if not trusted(sender) then return end
    local n = tonumber(data.n) or -1
    local c = Pop.copies[copyKey(sender, n)]
    if c then
        if not c.retired and Core.alive(c.npc) then
            c.retired = true
            retire(c.npc)
        end
        return
    end
    local e = Pop.owned[n]
    if e and e.to[sender] and not e.retired and Core.alive(e.npc) then
        e.retired = true
        -- as if the sample had been given here: the area may get a new potential client
        pcall(function() Core.find("SampleClientSpawner_C"):UnregisterClient(e.npc.sampleAreaAffected, false) end)
        retire(e.npc)
        for peer in pairs(e.to) do
            if peer ~= sender then Net.send("ps", { n = n }, peer) end
        end
        vlog("Pop: potential client %d was used up by %s", n, Net.name(sender))
    end
end)

---------------------------------------------------------------- talking to a copy

-- A copy the local player is talking to stays put until the conversation is over.
local function hold(seconds)
    return function(ctx)
        local npc = ctx:get()
        if not valid(npc) then return end
        local _, c = copyOf(npc)
        if c then c.busyUntil = os.clock() + seconds end
    end
end

Core.Hooks.add("/Game/Skeletal/NPC/baseNPC.baseNPC_C:dialogueMode", hold(90))
Core.Hooks.add("/Game/Skeletal/NPC/baseNPC.baseNPC_C:activateTrade", hold(90))
Core.Hooks.add("/Game/Skeletal/NPC/baseNPC.baseNPC_C:endDialogueMode", hold(2))
Core.Hooks.add("/Game/Skeletal/NPC/baseNPC.baseNPC_C:endTrade", hold(2))

---------------------------------------------------------------- upkeep

local function moveFollowers()
    local now = os.clock()
    for key, c in pairs(Pop.copies) do
        if not Core.alive(c.npc) then
            -- The game removed it here by itself (a patrol far from this player, somebody
            -- who went home). The owner sends it again if it is still around.
            Pop.copies[key] = nil
            Net.send("pd", { n = c.n }, c.owner)
        elseif not c.engaged then
            -- The class starts its behaviour tree a little after spawning; keep it off.
            if now - c.bornAt < 6 or (c.checkedAt or 0) + 5 < now then
                c.checkedAt = now
                stopThinking(c.npc)
            end
            if c.target and (c.busyUntil or 0) < now then pcall(follow, c.npc, c.target) end
        end
    end
    for _, e in pairs(Pop.owned) do
        if e.driver and e.target and not e.localChase and Core.alive(e.npc) then pcall(follow, e.npc, e.target) end
    end
end

-- A player has left the world: their NPCs go from our streets, and ours are no longer
-- theirs to copy or to drive.
local function forget(id)
    for key, c in pairs(Pop.copies) do
        if c.owner == id then
            Pop.copies[key] = nil
            if not World.gone and Core.alive(c.npc) then remove(c.npc) end
        end
    end
    for _, e in pairs(Pop.owned) do
        e.to[id], e.said[id], e.saidAt[id], e.quiet[id] = nil, nil, nil, nil
        if e.driver == id then
            e.driver, e.target = nil, nil
            if not World.gone and Core.alive(e.npc) then startThinking(e.npc) end
        end
    end
end

World.listen("peerleft", function(id)
    if Core.enabled("Population") then pcall(forget, id) end
end)

Core.every(0.5, function()
    if not World.shared() or not Core.enabled("Population") then return end
    local player = World.player()
    if not player then return end
    updateTogether(player:K2_GetActorLocation())
    local a = Core.profile and os.clock()
    local ok, e = xpcall(sendUpdates, debug.traceback)
    if a then Core.mark("pop.send", os.clock() - a) end
    if not ok then log("Pop: sending failed: %s", tostring(e)) end
    a = Core.profile and os.clock()
    ok, e = xpcall(moveFollowers, debug.traceback)
    if a then Core.mark("pop.follow", os.clock() - a) end
    if not ok then log("Pop: moving failed: %s", tostring(e)) end
end)

Core.every(1, function()
    if World.shared() and Core.enabled("Population") then releaseCalmOfficers() end
end)

World.listen("start", function(role)
    if not Core.enabled("Population") then return end
    local ok, e = xpcall(takeStock, debug.traceback, role)
    if not ok then log("Pop: start failed: %s", tostring(e)) end
end)

World.listen("stop", function()
    -- Copies have no mind of their own; do not leave them standing around. (When the
    -- world itself is gone there is nobody left to tidy up.)
    if not World.gone then
        for _, c in pairs(Pop.copies) do
            if Core.alive(c.npc) then remove(c.npc) end
        end
        for _, e in pairs(Pop.owned) do
            if e.driver and Core.alive(e.npc) then startThinking(e.npc) end
        end
    end
    Pop.owned, Pop.copies = {}, {}
    if policeUnlock ~= nil or together then setSpawners(true) end
    together, policeUnlock = false, nil
end)

function Pop.isApplying() return applying end
function Pop.spawning() return not together end

function Pop.isCopy(npc)
    local addr = npc:GetAddress()
    for _, c in pairs(Pop.copies) do
        if valid(c.npc) and c.npc:GetAddress() == addr then return true end
    end
    return false
end

return Pop
