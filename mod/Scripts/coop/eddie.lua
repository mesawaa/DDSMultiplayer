-- Eddie comes for his cash in every game.
--
-- "Bring the cash" in the phone app (shadyCommInterface, btnEddieCash) does four things in
-- the game of the player who pressed it: mainComputer.eddieWaitingForPlayer = true, Eddie
-- (panEddie_C, one per game, kept out of sight at 550 7300 200) is put at 1040 7300 160,
-- a task is created and its number is noted on Eddie (curCashTaskID). Handing the money
-- over (questManager:handOverMoney, from Eddie's dialogue) takes what the player carries
-- off mainComputer.PlayerEddieDebt, completes the task with the number noted on that
-- game's Eddie, clears the flag and lets Eddie walk off.
--
-- The flag, the debt and the task table are shared (coop/sync.lua). Eddie himself is an
-- NPC of each game and was not: for everybody but the caller he stayed out of sight with no
-- task number, so only the caller could pay, and had somebody else paid, the caller's Eddie
-- would have kept standing there. Here every game brings its own Eddie into line with the
-- shared flag: while it is up he stands at the meeting place tied to the same task, when
-- it goes down he leaves.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Eddie = { task = 0, stats = { placed = 0, released = 0 } }

local CLASS = "/Game/Temporary/panEddie.panEddie_C"
local SPOT = { X = 1040, Y = 7300, Z = 160 }       -- where the game puts him for the hand-over
local told = 0                                     -- the task number we last told the others

local function eddie()
    for _, npc in ipairs(Core.actors(CLASS) or FindAllOf("panEddie_C") or {}) do
        if Core.alive(npc) then return npc end
    end
    return nil
end

local function closed(id)
    local done = true
    pcall(function()
        local q = Core.find("questManager_C")
        done = q.taskCompleted[id + 1] == true or q.taskFailed[id + 1] == true
    end)
    return done
end

local function send(data, except)
    for _, id in ipairs(World.targets()) do
        if id ~= except then Net.send("eddie", data, id) end
    end
end

-- Puts our Eddie where the caller's game put its own.
local function place(npc)
    local l = npc:K2_GetActorLocation()
    if math.abs(l.X - SPOT.X) + math.abs(l.Y - SPOT.Y) < 60 then return end
    pcall(function()
        -- left over from an earlier hand-over, this would walk him off again at once
        npc.tryDisappearBool = false
        Core.system():K2_ClearTimer(npc, "disappearCheck")
    end)
    npc:K2_SetActorLocationAndRotation(SPOT, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true)
    Eddie.stats.placed = Eddie.stats.placed + 1
    vlog("Eddie: waiting for the cash here too (task %d)", Eddie.task)
end

Core.every(1, function()
    if not World.shared() or not Core.enabled("Orders") then return end
    local ok, e = pcall(function()
        local computer, npc = Core.find("mainComputer_C"), eddie()
        if not computer or not npc then return end
        local waiting = computer.eddieWaitingForPlayer == true
        local mine = npc.curCashTaskID
        if type(mine) ~= "number" then return end
        if waiting then
            if mine > 0 then
                -- called from this game, or loaded with the world: the others need the number
                Eddie.task = mine
                if told ~= mine then
                    told = mine
                    send({ k = mine })
                end
                place(npc)
            elseif Eddie.task > 0 and not closed(Eddie.task) then
                npc.curCashTaskID = Eddie.task
                place(npc)
            end
        else
            told = 0
            if mine > 0 then
                -- paid (or called off) in another game: ours has nothing left to wait for
                npc.curCashTaskID = 0
                pcall(function() npc:tryDisappear() end)
                Eddie.stats.released = Eddie.stats.released + 1
                vlog("Eddie: the cash was handed over in another game, he leaves here too")
            end
            Eddie.task = 0
        end
    end)
    if not ok then log("Eddie: %s", tostring(e)) end
end)

Net.on("eddie", function(sender, data)
    if not World.active or not Core.enabled("Orders") then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= (World.host or Net.S.owner) then return end
    local id = tonumber(data.k)
    if id and id > 0 then Eddie.task = math.floor(id) end
    if World.role == "host" then send(data, sender) end
end)

-- A player who arrives while he is waiting has the number in the world they loaded, but
-- one who was loading when the call was made does not.
World.listen("peer", function(id)
    if World.role == "host" and Eddie.task > 0 then Net.send("eddie", { k = Eddie.task }, id) end
end)
World.listen("start", function() Eddie.task, told = 0, 0 end)
World.listen("stop", function() Eddie.task, told = 0, 0 end)

---------------------------------------------------------------- orders and their packages

-- An order placed with Eddie is an object (orderInstance_C) in the game of the player who
-- placed it: it waits for the delivery time, puts the package into a dead drop and is gone.
-- Two things followed from that in a shared world. The dead drop is far from everybody when
-- it is filled, and things are only compared next to a player: nobody but the buyer ever
-- saw the package. And a guest who ordered and left took the order along, while the debt
-- for it stayed with the world.
--   * A guest hands each of its orders to the host a little after placing it (the object's
--     saved variables; the host makes the same object from them, as loading a save does),
--     and removes its own once the host has it. Not at once: seven to twelve seconds after
--     the order its object sends Eddie's answer, and a copy made from saved variables does
--     not. For the time in between the host is sent a copy to keep ("h"): should the guest
--     leave before the hand-over, the host makes the order from that.
--   * Whichever game delivers a package sends the dead drop's contents to everybody at
--     once and tells them where it is, so that they get a marker for it too.
local Repl = require("coop.repl")
local Hud = require("coop.hud")

local ORDER = "/Game/Interactive/orderInstance.orderInstance_C"
local HAND_OVER_AFTER = 20       -- seconds: Eddie's answer to the order is sent by the buyer's own object first
local RETRY = 8
local seen = {}                  -- guest: address of an order object -> { at, sentAt }
local packages = {}              -- task number -> the marker we made for another game's package
local held = {}                  -- host: guest -> { order number -> { data, at } }, kept until the hand-over
Eddie.stats.kept = 0             -- orders made from such a copy because their guest had left

local function orderObjects()
    local out = {}
    for _, o in ipairs(Core.actors(ORDER) or FindAllOf("orderInstance_C") or {}) do
        if Core.alive(o) then out[#out + 1] = o end
    end
    return out
end

local function hostId() return World.host or Net.S.owner end

local function offerOrders()
    if World.role ~= "guest" or not World.shared() or not Core.enabled("Orders") then
        if next(seen) then seen = {} end
        return
    end
    local now = os.clock()
    for _, o in ipairs(orderObjects()) do
        pcall(function()
            local address = o:GetAddress()
            local rec = seen[address]
            if not rec then
                rec = { at = now, sentAt = 0 }
                seen[address] = rec
            end
            if not rec.held and o.ready == true then
                rec.held = true
                local l = o:K2_GetActorLocation()
                Repl.send("eorder", { h = true, n = o.orderID, x = l.X, y = l.Y, z = l.Z, v = Repl.export(o, Repl.savedVars(o)) }, hostId())
            end
            if now - rec.at >= HAND_OVER_AFTER and now - rec.sentAt >= RETRY then
                rec.sentAt = now
                local l = o:K2_GetActorLocation()
                Repl.send("eorder", { n = o.orderID, x = l.X, y = l.Y, z = l.Z, v = Repl.export(o, Repl.savedVars(o)) }, hostId())
                vlog("Eddie: order %s offered to the host", tostring(o.orderID))
            end
        end)
    end
end
Core.every(2, offerOrders)
-- (the copy for the host goes out right after the order is placed, not at the next round)
Core.Hooks.add(ORDER .. ":SetupOrder", function()
    if World.role == "guest" and World.shared() then Core.after(0.3, offerOrders) end
end)

local function haveOrder(n)
    local have = false
    for _, o in ipairs(orderObjects()) do
        pcall(function() if o.orderID == n then have = true end end)
    end
    return have
end

-- Makes a guest's order in this game; "late" is how long ago its variables were read.
local function takeOver(n, data, late)
    local player = World.player()
    local class = StaticFindObject(ORDER)
    if not valid(class) then
        pcall(function() LoadAsset("/Game/Interactive/orderInstance") end)
        class = StaticFindObject(ORDER)
    end
    local o = player:GetWorld():SpawnActor(class, { X = data.x or 0, Y = data.y or 0, Z = data.z or 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(o) then error("the order object was not made") end
    Repl.import(o, data.v)
    if late and late > 0 then
        -- the time to the delivery is counted down by the object itself
        local left = o.recoverTimer
        if type(left) == "number" and left > 0 then o.recoverTimer = math.max(1, left - late) end
    end
end

Repl.on("eorder", function(sender, data)
    if World.role ~= "host" or not World.inWorld[sender] or not Core.enabled("Orders") then return end
    local n = tonumber(data.n)
    if not n or type(data.v) ~= "table" then return end
    if data.h then
        held[sender] = held[sender] or {}
        held[sender][n] = { data = data, at = os.clock() }
        return
    end
    if not haveOrder(n) then
        local ok, e = pcall(takeOver, n, data)
        if not ok then
            log("Eddie: could not take over order %d of %s: %s", n, Net.name(sender), tostring(e))
            return
        end
        log("Eddie: order %d of %s is kept by this game now", n, Net.name(sender))
    end
    if held[sender] then held[sender][n] = nil end
    Net.send("eorder_ok", { n = n }, sender)
end)

-- A guest left with orders it had not handed over yet: they are made from the copies.
World.listen("peerleft", function(id)
    local theirs = held[id]
    held[id] = nil
    if World.role ~= "host" or not theirs or not Core.enabled("Orders") then return end
    for n, h in pairs(theirs) do
        if not haveOrder(n) then
            local ok, e = pcall(takeOver, n, h.data, os.clock() - h.at)
            if ok then
                Eddie.stats.kept = Eddie.stats.kept + 1
                log("Eddie: order %d stays in this world, the player who placed it has left", n)
            else
                log("Eddie: order %d of a player who left could not be kept: %s", n, tostring(e))
            end
        end
    end
end)

Net.on("eorder_ok", function(sender, data)
    if World.role ~= "guest" or sender ~= hostId() then return end
    local n = tonumber(data.n)
    for _, o in ipairs(orderObjects()) do
        pcall(function()
            if o.orderID == n then
                seen[o:GetAddress()] = nil
                o:K2_DestroyActor()
                log("Eddie: order %d is with the host now", n)
            end
        end)
    end
end)

-- A package has just been put into a dead drop by this game.
Core.Hooks.add(ORDER .. ":spawnOrderPackage", function(ctx)
    if not World.shared() or not Core.enabled("Orders") then return end
    local order = ctx:get()
    if not valid(order) then return end
    local container, name = nil, "Dead drop"
    pcall(function()
        local place = order.orderSmuggleLocation
        container = place.dropContainer
        name = place.DeadDropName:ToString()
    end)
    if not valid(container) then return end
    -- a moment later: the game is still filling it and making the task
    Core.after(1.0, function()
        if not World.shared() or not Core.alive(container) then return end
        pcall(function()
            require("coop.sync").pushObject(container)
            local l = container:K2_GetActorLocation()
            -- ("t" is taken: it carries the kind of every message)
            local data = { k = Repl.key(container), task = container.retrieveTaskID, nm = name, x = l.X, y = l.Y, z = l.Z }
            for _, id in ipairs(World.targets()) do Net.send("epkg", data, id) end
            log("Eddie: a package was put into '%s'; the others were told", name)
        end)
    end)
end)

Net.on("epkg", function(sender, data)
    if not World.active or not Core.enabled("Orders") then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= hostId() then return end
    local task = tonumber(data.task)
    if task and task > 0 and not packages[task] and tonumber(data.x) then
        packages[task] = Hud.mapMarker("Dead drop package", "Eddie's delivery: " .. tostring(data.nm or "dead drop"), data.x, data.y, data.z, Hud.MARKER_PLAYER)
        pcall(function() World.player().HUD:refreshCompass() end)
        log("Eddie: a package is waiting in '%s'", tostring(data.nm))
    end
    if World.role == "host" then
        for _, id in ipairs(World.targets()) do
            if id ~= sender then Net.send("epkg", data, id) end
        end
    end
end)

-- The marker goes when the package has been collected (its task is closed).
Core.every(3, function()
    if not next(packages) then return end
    for task, marker in pairs(packages) do
        if closed(task) or not Core.alive(marker) then
            Hud.forgetMarker(marker)
            packages[task] = nil
            pcall(function() World.player().HUD:refreshCompass() end)
        end
    end
end)

World.listen("stop", function()
    for _, marker in pairs(packages) do Hud.forgetMarker(marker) end
    packages, seen, held = {}, {}, {}
end)
World.listen("start", function() packages, seen, held = {}, {}, {} end)

return Eddie
