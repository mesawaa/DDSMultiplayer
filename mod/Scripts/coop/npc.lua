-- Order clients in a shared world.
--
-- A client for an accepted order is spawned by the phone app of the player handling it
-- (shadyCommInterface:spawnClientOnMap), so by default only that player's game has the
-- client. Here the other game spawns the same client: same class, same place, set up from
-- the order data that coop/sync.lua already shares, following the steps the game's own
-- spawn function takes. When a sale completes, or the client gives up waiting, in one
-- game, the matching client is removed from the other.
--
-- Each game still runs its own copy of the client (its own AI). They start in the same
-- place and are tied to the same order; they are not frame-by-frame mirrors.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Npc = { stats = { spawned = 0, mirrored = 0, removed = 0 } }

local MALE = "/Game/Skeletal/NPC/Klienci/saleClientMaleBP.saleClientMaleBP_C"
local FEMALE = "/Game/Skeletal/NPC/Klienci/saleClientFemaleBP.saleClientFemaleBP_C"
local CONTACT_NAME = "Name_16_FF9AED99407FDA5CC81F3A92D99C45A8"

local applying = false

local function sendAll(data, except)
    for _, id in ipairs(World.targets()) do
        if id ~= except then Net.send("npc", data, id) end
    end
end

-- The live client NPC of an order, if this game has one.
local function clientOfOrder(orderId)
    for _, npc in ipairs(FindAllOf("baseNPC_C") or {}) do
        local ok, match = pcall(function()
            return Core.alive(npc) and npc.orderID == orderId and npc:GetClass():GetFName():ToString():find("saleClient") ~= nil
        end)
        if ok and match then return npc end
    end
    return nil
end

local function loadClass(path)
    local class = StaticFindObject(path)
    if valid(class) then return class end
    pcall(function() LoadAsset(path:gsub("_C$", "")) end)
    class = StaticFindObject(path)
    if valid(class) then return class end
    return nil
end

-- A client carries a marker for the map and the compass (saleMarker), which the game
-- removes when the sale ends in this game. A client that is served or gives up in another
-- game is taken away here by the mod, and its marker has to go with it: left behind, the
-- customer stayed on the map for good.
local markers = {}               -- order id -> the client's map marker

local function noteMarker(orderId, npc)
    pcall(function()
        if valid(npc.saleMarker) then markers[orderId] = npc.saleMarker end
    end)
end

local function removeClient(orderId, npc)
    applying = true
    if npc then
        pcall(function() if valid(npc.saleMarker) then npc.saleMarker:K2_DestroyActor() end end)
        pcall(function() if valid(npc.curDialogue) then npc.curDialogue:K2_DestroyActor() end end)
        pcall(function() npc:K2_DestroyActor() end)
    end
    -- the marker of a client that is gone already
    local marker = markers[orderId]
    markers[orderId] = nil
    pcall(function() if marker and Core.alive(marker) then marker:K2_DestroyActor() end end)
    applying = false
    pcall(function() World.player().HUD:refreshCompass() end)
end

---------------------------------------------------------------- our own spawns

Core.Hooks.add("/Game/GUI/shadyCommInterface.shadyCommInterface_C:spawnClientOnMap", function(_, a, b)
    if applying or not World.shared() or not Core.enabled("Clients") then return end
    local orderId = nil
    for _, param in ipairs({ a, b }) do
        local ok, value = pcall(function() return param:get() end)
        if ok and type(value) == "number" then orderId = math.floor(value) end
    end
    if not orderId then return end
    -- Give the game a moment to place and set up the client, then report where it stands.
    Core.after(1.0, function()
        local npc = clientOfOrder(orderId)
        if not npc then return end
        local loc, rot = npc:K2_GetActorLocation(), npc:K2_GetActorRotation()
        noteMarker(orderId, npc)
        sendAll({ a = "spawn", o = orderId, x = loc.X, y = loc.Y, z = loc.Z, yw = rot.Yaw })
        Npc.stats.spawned = Npc.stats.spawned + 1
        vlog("Npc: client for order %d spawned here, told the others", orderId)
    end)
end)

local function reportGone(reason)
    return function(ctx)
        if applying or not World.shared() or not Core.enabled("Clients") then return end
        local npc = ctx:get()
        local ok, orderId = pcall(function()
            -- every NPC has an order number field; only an order's client means it
            if npc:GetClass():GetFName():ToString():find("saleClient") == nil then return nil end
            return npc.orderID
        end)
        if not ok or type(orderId) ~= "number" then return end
        markers[orderId] = nil
        sendAll({ a = "gone", o = orderId, why = reason })
        vlog("Npc: client of order %d is done here (%s)", orderId, reason)
    end
end

Core.Hooks.add("/Game/Skeletal/NPC/baseNPC.baseNPC_C:drugSaleSuccesfull", reportGone("sold"))
Core.Hooks.add("/Game/Skeletal/NPC/baseNPC.baseNPC_C:clientResignedWaiting", reportGone("left"))

---------------------------------------------------------------- the other game's spawns

-- Spawns the client of an order the way shadyCommInterface:spawnClientOnMap does, but at
-- a given place and without needing the phone app widget. Returns the NPC.
function Npc.spawnClient(orderId, x, y, z, yaw)
    local player, sales = World.player(), Core.find("salesManager_C")
    if not player or not sales then error("no world") end
    local client = sales.orderListClientID[orderId + 1]
    local male = sales.clientsMale[client + 1] == true
    local class = loadClass(male and MALE or FEMALE)
    if not class then error("client class not available") end
    local ai = StaticFindObject("/Script/AIModule.Default__AIBlueprintHelperLibrary")
    local npc = ai:SpawnAIFromClass(player, class, nil, { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw or 0, Roll = 0 }, true)
    if not valid(npc) then error("spawn returned nothing") end
    -- Looks and risk come from the shared client list.
    local looks = Repl.splitArray(Repl.export(sales, { "clientsLookData" }).clientsLookData or "()")[client + 1]
    if looks then
        Repl.importRaw(npc, "clientLooks", looks)
        npc.hasLooksSet = true
    end
    pcall(function() npc.clientRiskFactor = sales.clientsRiskFactor[client + 1] end)
    -- Name from the contact list, the rest from the order.
    local name = FText("Client")
    pcall(function()
        local contacts = Core.find("contactsManager_C")
        name = contacts.characterList[sales.clientsAvailable[client + 1] + 1][CONTACT_NAME]
    end)
    npc:setupNewDrugSale(sales.orderListDrugOrdered[orderId + 1], sales.orderListDrugQuantity[orderId + 1], name,
        sales.orderListDrugExpectedPrice[orderId + 1], orderId, sales.orderListTaskID[orderId + 1], male,
        sales.clientIsDealer[client + 1] == true, sales.clientsExpectedQuality[client + 1])
    pcall(function() player.HUD:refreshCompass() end)
    return npc
end

local function mirrorSpawn(data)
    local orderId = tonumber(data.o)
    if not orderId or not data.x then return end
    if clientOfOrder(orderId) then return end   -- we already have this client
    applying = true
    local ok, e = xpcall(function() noteMarker(orderId, Npc.spawnClient(orderId, data.x, data.y, data.z + 5, data.yw)) end, debug.traceback)
    applying = false
    if not ok then
        log("Npc: could not spawn the client of order %d: %s", orderId, tostring(e))
        return
    end
    Npc.stats.mirrored = Npc.stats.mirrored + 1
    vlog("Npc: client of order %d spawned where the other game has it", orderId)
end

Net.on("npc", function(sender, data)
    if not World.active or not Core.enabled("Clients") then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= Net.S.owner then return end
    if data.a == "spawn" then
        -- The order data travels separately; wait for it to arrive first.
        Core.after(2.0, function()
            if World.active then mirrorSpawn(data) end
        end)
    elseif data.a == "gone" then
        local orderId = tonumber(data.o) or -1
        local npc = clientOfOrder(orderId)
        if npc or markers[orderId] then
            removeClient(orderId, npc)
            Npc.stats.removed = Npc.stats.removed + 1
            vlog("Npc: client of order %s removed with its map marker (%s in the other game)", tostring(data.o), tostring(data.why))
        end
    end
    if World.role == "host" then sendAll(data, sender) end
end)

function Npc.clientOfOrder(orderId) return clientOfOrder(orderId) end
World.listen("start", function() markers = {} end)
World.listen("stop", function() markers = {} end)

---------------------------------------------------------------- markers left behind

-- A customer's marker (worldMapMarker_C, category 3) is saved with the world. After loading,
-- it ties itself to the customer standing in it (same name, no marker yet); the game has
-- nothing for a marker that finds nobody, because without the mod that cannot happen: the
-- customer removes its marker when it goes. Mod versions before 0.12 took a mirrored
-- customer away and left the marker, and such markers were saved with the host's world:
-- customers on the map and the compass who are not there, for good, in every game that
-- loads that world. Each game removes them: a customer marker that belongs to no NPC, with
-- no customer of that name still without a marker, in two looks some seconds apart.
local PERSON = 3                 -- mapMarkerCategories: a customer (flagged as dealer when the customer is one)
local LOOK_EVERY = 5
local AFTER_LOAD = 15            -- seconds: markers and customers find each other after a load
local CERTAIN_AFTER = 8          -- seconds a marker has to be seen without a customer
local suspects = {}              -- marker address -> when it was first seen without a customer
Npc.stats.orphans = 0

Core.every(LOOK_EVERY, function()
    if not Core.enabled("Clients") or not Core.player() then return end
    local now = os.clock()
    if now - World.loadStartedAt < AFTER_LOAD then
        suspects = {}
        return
    end
    -- (the other players' markers are of this kind too, and belong to no NPC either)
    local players = {}
    pcall(function()
        for _, m in pairs(require("coop.teammap").markers) do
            if Core.alive(m) then players[m:GetAddress()] = true end
        end
    end)
    local candidates = {}
    for _, m in ipairs(FindAllOf("worldMapMarker_C") or {}) do
        pcall(function()
            if Core.alive(m) and m.markerCategory == PERSON and m.taskRelated ~= true and not players[m:GetAddress()] then candidates[#candidates + 1] = m end
        end)
    end
    if #candidates == 0 then
        suspects = {}
        return
    end
    local owned, unmarked = {}, {}
    for _, npc in ipairs(FindAllOf("baseNPC_C") or {}) do
        pcall(function()
            if not Core.alive(npc) then return end
            if valid(npc.saleMarker) then
                owned[npc.saleMarker:GetAddress()] = true
            elseif npc.needsDrugs == true then
                unmarked[npc.characterFullName:ToString()] = true
            end
        end)
    end
    local still, removed = {}, 0
    for _, m in ipairs(candidates) do
        pcall(function()
            local address = m:GetAddress()
            if owned[address] or unmarked[m.MarkerName:ToString()] then return end
            local since = suspects[address] or now
            if now - since >= CERTAIN_AFTER then
                local name = m.MarkerName:ToString()
                m:K2_DestroyActor()
                removed = removed + 1
                vlog("Npc: the marker of '%s' had no customer, removed", name)
            else
                still[address] = since
            end
        end)
    end
    suspects = still
    if removed > 0 then
        Npc.stats.orphans = Npc.stats.orphans + removed
        pcall(function() World.player().HUD:refreshCompass() end)
        log("Npc: %d customer marker(s) without a customer removed from the map", removed)
    end
end)

-- Diana Fisk (the deco shop) walks, and the armchair right behind her lets a nudge step her
-- up onto its seat, where she stays. (The game's own doing; seen by the user 2026-11-16.)
-- When she stands well above the spot she started on, she is put back there.
local DIANA = "/Game/GUI/EquipmentShopping/shopOwnerDecorations.shopOwnerDecorations_C"
local diana = { address = nil, home = nil, highSince = nil }
Core.every(2, function()
    local player = World.player()
    if not player then return end
    local p = player:K2_GetActorLocation()
    if math.abs(p.X - 9948) > 3000 or math.abs(p.Y + 5692) > 3000 then return end
    local d = (Core.actors(DIANA) or {})[1]
    if not d then return end
    local address = d:GetAddress()
    local l = d:K2_GetActorLocation()
    if diana.address ~= address or not diana.home or l.Z < diana.home.Z then
        if diana.address ~= address then diana.highSince = nil end
        diana.address, diana.home = address, { X = l.X, Y = l.Y, Z = l.Z }
        -- (she is saved with the world: a save made while she stood on the chair starts her there)
        if l.Z > 250 then diana.home = { X = 9948, Y = -5692, Z = 240 } else return end
    end
    if l.Z - diana.home.Z > 25 then
        diana.highSince = diana.highSince or os.clock()
        if os.clock() - diana.highSince > 3 then
            pcall(function() d:K2_SetActorLocation(diana.home, false, {}, true) end)
            diana.highSince = nil
            vlog("Npc: Diana stood on the furniture; back on the floor")
        end
    else
        diana.highSince = nil
    end
end)

return Npc
