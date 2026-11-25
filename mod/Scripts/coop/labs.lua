-- Drug labs: one business for everybody.
--
-- A lab is built in furniture mode in a hideout that has a lab floor (the warehouses and
-- flats of sector C and a few others). Its state is kept on the hideout itself
-- (rentAppartmentArea): the kind of lab (LabTypeID), the dealers working in it (LabCrew,
-- client numbers), the batch timer (LabProductionTimer, real seconds), what lies finished on
-- the output table (LabProducedTotal, grams) and whether it waits for cash
-- (ProductionOnHold). The lab's prefab in the hideout ticks the timer, takes the cost of the
-- next batch out of its cash box (a container) and puts the batch on the output table.
--
-- Without this, every game ran its own copy of every lab: each counted down and made its own
-- batches, and each took the batch cost out of its own copy of the cash box. A lab built by
-- a guest existed in the guest's game only and was gone with the next load of the host's
-- world.
--
-- Now the host's game makes the batches. Guests show the host's lab:
--   * The host sends the state of every lab when it changes (the timer once a second).
--   * A guest's game never finishes a batch: its timer is held below the batch time and
--     follows the host's.
--   * What a guest does to a lab is sent to the host, which takes it over: building,
--     converting and removing a lab (furniture mode), taking product off the table (sent as
--     the grams taken, so a batch the host finishes at the same time is not lost), and
--     starting a batch with cash the guest put into the box.
--   * The cash box is an ordinary container (coop/sync.lua). The game takes the batch cost
--     out of it far from any player, where containers are not otherwise compared, so the
--     boxes of working labs are compared here.
--   * Crew members are people of the game, which every game spawns itself: a lab built or
--     manned in another game gets its crew spawned here, the way furniture mode does.
--   * The game tells its player when a batch is ready, wherever he is. Guests are told by
--     the host's game, in the same words.
--   * Building a lab is a step of the endgame. Showing somebody else's lab does not do that
--     step again in this game.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")
local Sync = require("coop.sync")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Labs = { stats = { sent = 0, applied = 0, built = 0, removed = 0, crew = 0, taken = 0 } }

local AREA = "/Game/Interactive/rentAppartmentArea.rentAppartmentArea_C"
local CREW_NPC = "/Game/Skeletal/NPC/LabCrewNPC_BP.LabCrewNPC_BP_C"
local LAB_DB = "/Game/DataTables/LabTypeDatabase.LabTypeDatabase"
local F_TIME = "ProductionTime_11_9AAFB8A44E049E7A00066FA6C5092BAD"
local F_DRUG = "ProducesDrug_8_EA3D34AB431DC7EB832B06BD80DBFD4E"

local VARS = { "LabTypeID", "LabCrew", "ProductionOnHold", "LabProducedTotal", "LabProductionTimer" }
local NONE = "None"
local SETTLE = 12          -- seconds after a load before this game's labs are compared
local TIMER_EVERY = 1      -- seconds between sends of a running timer
local HOLD_BACK = 30       -- a guest's timer stays this many seconds below the batch time
local QUIET = 3            -- seconds during which a guest keeps what it has just sent
local RETRY_HOLD = 5       -- host: a lab waiting for cash looks at its box again after this long

local function on() return Core.enabled("Labs") end

---------------------------------------------------------------- reading and writing

local function lab(area)
    local ok, prefab = pcall(function() return area.LabPrefabRef end)
    if ok and valid(prefab) then return prefab end
    return nil
end

-- Hideouts that have a lab floor: { area, prefab, key }. Looked up anew now and then.
local list, listedAt = {}, -1000
local boxes = {}           -- address of a cash box -> its entry

local function labs()
    if os.clock() - listedAt < 10 and #list > 0 then return list end
    listedAt = os.clock()
    local out, byBox = {}, {}
    for _, a in ipairs(Core.actors(AREA) or {}) do
        local prefab = Core.alive(a) and lab(a) or nil
        if prefab then
            local ok, key = pcall(Repl.key, a)
            if ok and key then
                local e = { area = a, prefab = prefab, key = key }
                out[#out + 1] = e
                pcall(function()
                    local box = prefab.CashSource
                    if valid(box) then byBox[box:GetAddress()] = e end
                end)
            end
        end
    end
    list, boxes = out, byBox
    return list
end

local function byKey(key)
    for _, e in ipairs(labs()) do
        if e.key == key and Core.alive(e.area) then return e end
    end
    listedAt = -1000
    for _, e in ipairs(labs()) do
        if e.key == key then return e end
    end
    return nil
end

local function crewOf(text)
    local out = {}
    for _, v in ipairs(Repl.splitArray(text or "()")) do
        local n = tonumber(v)
        if n then out[#out + 1] = math.floor(n) end
    end
    return out
end

local function crewText(crew)
    if #crew == 0 then return "()" end
    local parts = {}
    for i, n in ipairs(crew) do parts[i] = tostring(math.floor(n)) end
    return "(" .. table.concat(parts, ",") .. ")"
end

local function sameCrew(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- { t = kind, c = crew, h = on hold, p = grams on the table, r = timer }
local function read(area)
    local v = Repl.export(area, VARS)
    if not v.LabTypeID then return nil end
    return {
        t = (v.LabTypeID:gsub('^"(.*)"$', "%1")),     -- (a name comes out in quotes)
        c = crewOf(v.LabCrew),
        h = v.ProductionOnHold == "True",
        p = math.floor(tonumber(v.LabProducedTotal) or 0),
        r = tonumber(v.LabProductionTimer) or 0,
    }
end

local function write(area, s)
    local values = {}
    if s.t ~= nil then values.LabTypeID = '"' .. s.t .. '"' end
    if s.c ~= nil then values.LabCrew = crewText(s.c) end
    if s.h ~= nil then values.ProductionOnHold = s.h and "True" or "False" end
    if s.p ~= nil then values.LabProducedTotal = tostring(math.max(0, math.floor(s.p))) end
    if s.r ~= nil then values.LabProductionTimer = string.format("%.6f", s.r) end
    Repl.import(area, values)
end

local function copy(s)
    return { t = s.t, c = { table.unpack(s.c) }, h = s.h, p = s.p, r = s.r }
end

---------------------------------------------------------------- the lab table

local rows = {}            -- kind -> { time, drug } or false

local function row(kind)
    if kind == nil or kind == NONE then return nil end
    local cached = rows[kind]
    if cached ~= nil then return cached or nil end
    local found = false
    pcall(function()
        local db = StaticFindObject(LAB_DB)
        if not valid(db) then return end
        local r = db:FindRow(kind)
        if r == nil then return end
        found = { time = tonumber(r[F_TIME]) or 0, drug = r[F_DRUG] }
    end)
    -- (a table that was not there yet is looked up again next time)
    if found then rows[kind] = found end
    return found or nil
end

-- The packs on the output table are drawn by the game when it changes the amount itself.
local function redrawTable(e, s)
    local r = row(s.t)
    if not r then return end
    pcall(function()
        local tableActor = e.prefab.OutputTable
        if valid(tableActor) then tableActor:OutputDrug(r.drug, math.max(0, s.p)) end
    end)
end

---------------------------------------------------------------- batch ready

local HINTS = "/Game/StringTables/strTable_QuickHints.strTable_QuickHints"
local HELPERS = "/Game/WorldControlers/BlueprintLibraries/BlueprintHelpers.Default__BlueprintHelpers_C"
local F_NAME = "DrugSourceName_2_BD60123B47D8A346B9BF039C049228C7"

-- The game's own "Batch of ... is ready!" for a lab of this kind, in the game's language.
local function batchText(kind)
    local r = row(kind)
    if not r then return nil end
    local name, line = nil, nil
    pcall(function()
        local ok, meta = {}, {}
        StaticFindObject(HELPERS):GetDrugMeta(r.drug, World.player(), ok, meta)
        local m = meta.DrugMeta or meta
        name = m[F_NAME]:ToString()
    end)
    pcall(function()
        line = StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):TextFromStringTable(FName(HINTS), "QUICK-HINT-BATCH-READY"):ToString()
    end)
    if not name or name == "" then pcall(function() name = r.drug:ToString():gsub("^DRUG%-", ""):lower() end) end
    if not line or line == "" or line:find("<MISSING", 1, true) or not line:find("{name}", 1, true) then
        line = "Batch of {name} is ready!"
    end
    return (line:gsub("{name}", function() return name or "" end))
end
Labs.batchText = batchText

local function batchReady(kind)
    local text = batchText(kind)
    local Hud = package.loaded["coop.hud"]
    if not text or type(Hud) ~= "table" or not Hud.toast then return end
    pcall(Hud.toast, text)
    log("Labs: guests told: %s", text)
end

---------------------------------------------------------------- what furniture mode does

-- The endgame's "build a lab" step is done by the game whenever a lab comes on (also when a
-- world with labs is loaded). A lab that came on in another game must not do it here again:
-- that game has done it and the task list is shared.
local function quietly(fn)
    local salesman, task = nil, nil
    pcall(function()
        salesman = Core.find("villaSalesman_C")
        if salesman then
            task = salesman.curTaskID
            salesman.curTaskID = 0
        end
    end)
    local ok, err = pcall(fn)
    if salesman and task ~= nil then pcall(function() salesman.curTaskID = task end) end
    if not ok then log("Labs: switching a lab failed: %s", tostring(err)) end
    return ok
end

local function overlapping(area, path)
    local class = Core.class(path)
    if not class then return {} end
    local out = {}
    if not pcall(function() area.Overlap:GetOverlappingActors(out, class) end) then return {} end
    local raw = out
    if #raw == 0 and type(out.OverlappingActors) == "table" then raw = out.OverlappingActors end
    local res = {}
    for _, x in ipairs(raw) do
        local actor = x
        if type(x) == "userdata" and x.IsValid == nil and x.get then
            local ok, v = pcall(function() return x:get() end)
            actor = ok and v or nil
        end
        if actor ~= nil and Core.alive(actor) then res[#res + 1] = actor end
    end
    return res
end

local function crewClass()
    local class = StaticFindObject(CREW_NPC)
    if valid(class) then return class end
    pcall(function() LoadAsset(CREW_NPC:gsub("_C$", "")) end)
    class = StaticFindObject(CREW_NPC)
    return valid(class) and class or nil
end

local spawned = {}         -- hideout key -> client number -> the crew member spawned here

-- Puts the crew of a lab at their places, as furniture mode does when a lab is built: the
-- n-th member at the n-th place of the prefab, 90 units up.
local function spawnCrew(e, crew)
    if #crew == 0 then return end
    local class = crewClass()
    if not class then return end
    local have = {}
    for _, npc in ipairs(overlapping(e.area, CREW_NPC)) do
        pcall(function() have[npc.LabCrewClientID] = true end)
    end
    local mine = spawned[e.key] or {}
    spawned[e.key] = mine
    for id, npc in pairs(mine) do
        if Core.alive(npc) then have[id] = true else mine[id] = nil end
    end
    local points = {}
    pcall(function()
        e.prefab.LabCrewSpawnPoints:ForEach(function(_, elem) points[#points + 1] = elem:get() end)
    end)
    for i, id in ipairs(crew) do
        local point = points[i]
        if not have[id] and point and valid(point) then
            local ok, err = pcall(function()
                local l, r = point:K2_GetActorLocation(), point:K2_GetActorRotation()
                local npc = e.prefab:GetWorld():SpawnActor(class, { X = l.X, Y = l.Y, Z = l.Z + 90 },
                    { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll })
                if not valid(npc) then error("nothing spawned") end
                npc:SetupLabCrew(id)
                mine[id] = npc
            end)
            if ok then
                Labs.stats.crew = Labs.stats.crew + 1
            else
                log("Labs: a crew member could not be put in place: %s", tostring(err))
            end
        end
    end
end

-- A cash box that has just taken what another game put in or took out is redrawn, and the
-- lab hears that its box changed: waiting for cash, it would take the cost of a batch here
-- as well. Only the game whose player put the cash in (or the host, see hostLook) starts
-- the batch; while the box is redrawn the lab does not wait.
local fromGuestAt = {}     -- host: hideout key -> when another game last changed the lab or its box

table.insert(Sync.refreshGuards, function(obj)
    if not on() or not World.active then return nil end
    local e = boxes[obj:GetAddress()]
    if not e or not Core.alive(e.area) then return nil end
    -- (the word that the other game has started the batch may still be on its way)
    fromGuestAt[e.key] = os.clock()
    local held = e.area.ProductionOnHold
    if held ~= true then return nil end
    e.area.ProductionOnHold = false
    return function() e.area.ProductionOnHold = held end
end)

-- The cash box: compared with what the others have and the difference sent.
local function watchBox(e)
    pcall(function()
        local box = e.prefab.CashSource
        if valid(box) then Sync.watchObject(box) end
    end)
end

---------------------------------------------------------------- applying

local seen = {}            -- hideout key -> the state the others have of it, as far as we know
local quietUntil = {}      -- guest: hideout key -> { t = until, h = until, p = until }
local heldSince = {}       -- host: hideout key -> when the lab started waiting for cash

-- A lab comes on (built, or turned into another kind) or goes off in this game because it
-- did in another one. `s` is the full state to take.
local function switch(e, before, s)
    local isGuest = World.role == "guest"
    if s.t == NONE then
        if isGuest then
            -- the box is emptied in the host's game and comes from there
            write(e.area, { t = NONE, h = s.h, p = s.p, r = s.r })
            quietly(function() e.prefab:SetPrefabActive(false, false) end)
        else
            -- also empties the box, which then goes to the guests
            quietly(function() e.prefab:PurgeLab(false) end)
        end
        write(e.area, { c = s.c })
        spawned[e.key] = nil
        Labs.stats.removed = Labs.stats.removed + 1
        log("Labs: the lab in %s was removed in another game", e.key)
        return
    end
    -- A guest's game must not take the cost of a batch out of its box for the host:
    -- switching on looks at the box when the lab waits for cash.
    -- (in the host's game it may take the cost here, as it does for the one who built it)
    write(e.area, { t = s.t, c = s.c, p = s.p, r = s.r, h = isGuest and false or s.h })
    quietly(function() e.prefab:SetPrefabActive(true, false) end)
    if isGuest then write(e.area, { h = s.h }) end
    redrawTable(e, s)
    if before.t == NONE then
        spawnCrew(e, s.c)
        Labs.stats.built = Labs.stats.built + 1
        log("Labs: a %s lab in %s was built in another game", s.t, e.key)
    else
        log("Labs: the lab in %s now makes %s (changed in another game)", e.key, s.t)
    end
end

-- Guest: takes the host's state of one lab.
local function takeFromHost(entry)
    local e = byKey(entry.k)
    if not e then return end
    if entry.b == true then batchReady(tostring(entry.t)) end
    local now = read(e.area)
    if not now then return end
    -- This game's player has just done something to the lab that has not gone out yet (it
    -- goes with the next look, a moment from now): the host's state is older than that.
    local before = seen[e.key]
    if before and (now.t ~= before.t or now.h ~= before.h or now.p < before.p or not sameCrew(now.c, before.c)) then
        return
    end
    local s = { t = tostring(entry.t), c = crewOf(entry.c), h = entry.h == true,
        p = math.floor(tonumber(entry.p) or 0), r = tonumber(entry.r) or 0 }
    local q = quietUntil[e.key] or {}
    local clock = os.clock()
    -- What this game has just done is on its way to the host; an older state from the host
    -- does not undo it.
    if (q.t or 0) > clock and s.t ~= now.t then return end
    if (q.h or 0) > clock then s.h = now.h end
    if (q.p or 0) > clock and s.p > now.p then s.p = now.p end
    if s.t ~= now.t then
        switch(e, now, s)
    else
        local changes = {}
        if not sameCrew(s.c, now.c) then changes.c = s.c end
        if s.h ~= now.h then changes.h = s.h end
        if s.p ~= now.p then changes.p = s.p end
        changes.r = s.r
        write(e.area, changes)
        if changes.p and s.t ~= NONE then redrawTable(e, s) end
        if changes.c and s.t ~= NONE then spawnCrew(e, s.c) end
    end
    seen[e.key] = read(e.area) or s
    Labs.stats.applied = Labs.stats.applied + 1
end

-- Host: takes what a guest did to a lab.
local function takeFromGuest(entry)
    local e = byKey(entry.k)
    if not e then return end
    local now = read(e.area)
    if not now then return end
    fromGuestAt[e.key] = os.clock()
    if entry.full then
        local s = { t = tostring(entry.t), c = crewOf(entry.c), h = entry.h == true,
            p = math.floor(tonumber(entry.p) or 0), r = tonumber(entry.r) or 0 }
        if s.t ~= now.t then
            switch(e, now, s)
        else
            write(e.area, s)
            redrawTable(e, s)
        end
    else
        if entry.c ~= nil then
            local crew = crewOf(entry.c)
            write(e.area, { c = crew })
            if now.t ~= NONE then spawnCrew(e, crew) end
        end
        -- the guest's game has started a batch with cash put into the box there
        if entry.h ~= nil then write(e.area, { h = entry.h == true }) end
        local dp = math.floor(tonumber(entry.dp) or 0)
        if dp > 0 then
            local p = math.max(0, now.p - dp)
            write(e.area, { p = p })
            redrawTable(e, { t = now.t, p = p })
            Labs.stats.taken = Labs.stats.taken + 1
            vlog("Labs: a guest took %d g from the lab in %s, %d g left", dp, e.key, p)
        end
    end
    watchBox(e)
    Labs.stats.applied = Labs.stats.applied + 1
end

Repl.on("lab", function(sender, data)
    if not on() or not World.active or not World.player() or type(data.l) ~= "table" then return end
    if World.role == "guest" then
        if sender ~= (World.host or Net.S.owner) then return end
        for _, entry in ipairs(data.l) do
            if type(entry) == "table" and type(entry.k) == "string" then
                local ok, err = pcall(takeFromHost, entry)
                if not ok then log("Labs: taking the host's lab failed: %s", tostring(err)) end
            end
        end
    elseif World.role == "host" and World.isPeer(sender) then
        for _, entry in ipairs(data.l) do
            if type(entry) == "table" and type(entry.k) == "string" then
                local ok, err = pcall(takeFromGuest, entry)
                if not ok then log("Labs: taking a guest's lab change failed: %s", tostring(err)) end
            end
        end
    end
end)

---------------------------------------------------------------- comparing

local lastTimerSent = {}   -- host: hideout key -> when its timer was last sent

local function entryOf(key, s, full)
    return { k = key, t = s.t, c = crewText(s.c), h = s.h, p = s.p, r = math.floor(s.r * 100 + 0.5) / 100, full = full or nil }
end

local function hostLook(targets)
    local out, clock = {}, os.clock()
    for _, e in ipairs(labs()) do
        if Core.alive(e.area) then
            local s = read(e.area)
            if s then
                local before = seen[e.key]
                if not before then
                    seen[e.key] = s
                else
                    local changed = s.t ~= before.t or s.h ~= before.h or s.p ~= before.p or not sameCrew(s.c, before.c)
                    local ticking = s.r ~= before.r and clock - (lastTimerSent[e.key] or -100) >= TIMER_EVERY
                    if changed or ticking then
                        local entry = entryOf(e.key, s)
                        -- (only a finished batch adds to the table; what guests take comes off it)
                        if s.t == before.t and s.t ~= NONE and s.p > before.p then entry.b = true end
                        out[#out + 1] = entry
                        seen[e.key] = s
                        lastTimerSent[e.key] = clock
                    end
                    -- a batch started (cost taken), a lab removed (box emptied)
                    if s.t ~= before.t or s.h ~= before.h then watchBox(e) end
                end
                -- Cash put into the box in another game reaches this one as a change of the
                -- box's contents, which does not start the batch the way the game's own
                -- inventory window does. A lab that keeps waiting looks at its box again.
                if s.t ~= NONE and s.h then
                    heldSince[e.key] = heldSince[e.key] or clock
                    if clock - heldSince[e.key] >= RETRY_HOLD and clock - (fromGuestAt[e.key] or -100) >= RETRY_HOLD then
                        heldSince[e.key] = clock
                        pcall(function() e.prefab:TryInitiateProduction(false) end)
                    end
                else
                    heldSince[e.key] = nil
                end
            end
        end
    end
    if #out > 0 then
        Repl.sendMany("lab", { l = out }, targets)
        Labs.stats.sent = Labs.stats.sent + #out
    end
end

local function guestLook(targets)
    local out, clock, touched = {}, os.clock(), {}
    for _, e in ipairs(labs()) do
        if Core.alive(e.area) then
            local s = read(e.area)
            local before = seen[e.key]
            if s and not before then
                seen[e.key] = s
            elseif s then
                local q = quietUntil[e.key] or {}
                quietUntil[e.key] = q
                if s.t ~= before.t then
                    -- built, converted or removed in furniture mode here
                    out[#out + 1] = entryOf(e.key, s, true)
                    q.t, q.h, q.p = clock + QUIET, clock + QUIET, clock + QUIET
                    seen[e.key] = copy(s)
                    touched[#touched + 1] = e
                    log("Labs: lab in %s changed here to %s; sent to the host", e.key, s.t)
                else
                    local entry, any = { k = e.key }, false
                    if not sameCrew(s.c, before.c) then
                        entry.c, any = crewText(s.c), true
                    end
                    if s.h ~= before.h then
                        entry.h, any = s.h, true
                        q.h = clock + QUIET
                    end
                    if s.p < before.p then
                        entry.dp, any = before.p - s.p, true
                        q.p = clock + QUIET
                    end
                    if any then
                        out[#out + 1] = entry
                        touched[#touched + 1] = e
                    end
                    local keep = copy(s)
                    keep.r = before.r
                    seen[e.key] = keep
                end
            end
        end
    end
    if #out > 0 then
        Repl.sendMany("lab", { l = out }, targets)
        Labs.stats.sent = Labs.stats.sent + #out
    end
    for _, e in ipairs(touched) do watchBox(e) end
end

local function settled()
    return World.shared() and os.clock() - World.loadStartedAt >= SETTLE
end

Core.every(0.25, function()
    if not on() then return end
    if not settled() then
        if next(seen) ~= nil then seen, quietUntil, heldSince, fromGuestAt, lastTimerSent = {}, {}, {}, {}, {} end
        return
    end
    local targets = World.targets()
    if #targets == 0 then return end
    local ok, err = pcall(World.role == "host" and hostLook or guestLook, targets)
    if not ok then log("Labs: comparing failed: %s", tostring(err)) end
end)

-- The cash boxes of working labs, wherever the players are.
Core.every(2, function()
    if not on() or not settled() then return end
    for _, e in ipairs(labs()) do
        local s = seen[e.key]
        if s and s.t ~= NONE then watchBox(e) end
    end
end)

-- A guest's game never finishes a batch: its timer is held below the batch time. (Waiting
-- runs the game up to twenty times faster, and the lab adds its time a few times a
-- second; the margin covers that.)
Core.onTick(function()
    -- (not at the main menu, where the world's hideouts are gone: reading one of those ends the game)
    if World.role ~= "guest" or not on() or not World.shared() then return end
    for _, e in ipairs(list) do
        local s = seen[e.key]
        if s and s.t ~= NONE and Core.alive(e.area) then
            local r = row(s.t)
            if r and r.time > HOLD_BACK then
                pcall(function()
                    local limit = r.time - HOLD_BACK
                    if e.area.LabProductionTimer > limit then e.area.LabProductionTimer = limit end
                end)
            end
        end
    end
end)

-- A newcomer has the world as it was saved for them; what the labs did while they were
-- loading is said once more.
World.listen("peer", function(id)
    if not on() or World.role ~= "host" then return end
    Core.after(2, function()
        if not World.isPeer(id) then return end
        local out = {}
        for _, e in ipairs(labs()) do
            local s = Core.alive(e.area) and read(e.area) or nil
            if s then out[#out + 1] = entryOf(e.key, s) end
        end
        if #out > 0 then Repl.send("lab", { l = out }, id) end
        vlog("Labs: told the newcomer about %d lab floor(s)", #out)
    end)
end)

World.listen("stop", function()
    seen, quietUntil, heldSince, fromGuestAt, lastTimerSent, spawned = {}, {}, {}, {}, {}, {}
    list, listedAt, boxes = {}, -1000, {}
end)

Labs.labs, Labs.read, Labs.seen, Labs.row = labs, read, function() return seen end, row

return Labs
