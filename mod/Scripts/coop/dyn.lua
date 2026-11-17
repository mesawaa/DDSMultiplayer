-- Objects that appear or disappear during play: dropped items and cash, placed furniture,
-- bought containers, things picked up.
--
-- Every interactive object runs interactiveBaseObject's BeginPlay when it comes to life.
-- Whatever comes to life next to our player during play, carries a save component and is
-- not an NPC is created in the other game too, at the same place and with the same saved
-- variables. From then on it syncs like any other saved object
-- (coop/sync.lua). When such an object, or any saved object near a player, is destroyed
-- by that player's game, it is destroyed in the other game as well, so picking something
-- up removes it for everyone.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Dyn = { objects = {}, stats = { spawned = 0, received = 0, removed = 0 } }

local NEAR = 900                 -- a removal is only passed on if the object was this close to us
local CREATE_RANGE = 1200        -- only things created this close to our player are the player's doing
local SETTLE = 0.4               -- seconds between creation and copying, so the game can finish setting it up
local QUIET_AFTER_START = 6      -- seconds after a guest has loaded the world during which nothing is copied
-- Only interactive objects (items, cash, furniture, containers) are copied. Each game
-- creates its own NPC equipment, dialogue helpers and map markers.
local INTERACTIVE_BASE = "/Game/Interactive/interactiveBaseObject.interactiveBaseObject_C"
-- The bench of the first meeting is each player's own too: the game destroys it when its
-- player stands up from it, and the other player has yet to sit down on theirs.
local DENY = {
    policeWalkieTalkie_C = true, worldMapMarker_C = true, worldCustomMarker_C = true, PlayerInfluenceRadius_C = true,
    sitDownPlace_C = true,
}
local startedAt = 0

local applying = false           -- true while we create or destroy something on behalf of a peer
local pending = {}               -- freshly created actors waiting to settle
local counter = 0
local pawnClass = nil

local function isPawn(actor)
    if not valid(pawnClass) then pawnClass = StaticFindObject("/Script/Engine.Pawn") end
    local ok, result = pcall(function() return actor:IsA(pawnClass) end)
    return ok and result
end

local function classPath(actor)
    local full = actor:GetClass():GetFullName()
    return full:match("^%S+%s+(.+)$")
end

local function loadClass(path)
    local class = StaticFindObject(path)
    if valid(class) then return class end
    -- "/Game/X/Asset.Asset_C" -> load the package that holds it
    pcall(function() LoadAsset(path:gsub("_C$", "")) end)
    class = StaticFindObject(path)
    if valid(class) then return class end
    return nil
end

local interactiveClass = nil

-- True for the kind of object players create and remove: an interactive object with saved state.
function Dyn.isInteractive(actor)
    interactiveClass = Core.class(INTERACTIVE_BASE)
    if not valid(interactiveClass) then return false end
    local ok, result = pcall(function() return actor:IsA(interactiveClass) end)
    return ok and result == true and not DENY[actor:GetClass():GetFName():ToString()]
end

local function eligible(actor)
    if not Core.alive(actor) or isPawn(actor) or not Dyn.isInteractive(actor) then return false end
    if Repl.ramaComponent(actor) == nil then return false end
    local player = World.player()
    if not player then return false end
    local a, p = actor:K2_GetActorLocation(), player:K2_GetActorLocation()
    local dx, dy, dz = a.X - p.X, a.Y - p.Y, a.Z - p.Z
    return dx * dx + dy * dy + dz * dz <= CREATE_RANGE * CREATE_RANGE
end

local function sendTo(messageType, data, except)
    for _, id in ipairs(World.targets()) do
        if id ~= except then Repl.send(messageType, data, id) end
    end
end

-- What a player is about to put down at a work station (a package from the pockets, a jar
-- from the flat's stock, equipment picked up to be moved) is shown by the game as a
-- "gizmo": a real object of the same class that follows the player's aim until it is put
-- down, when the game makes the lasting object and removes the gizmo. A gizmo is nothing
-- of the world yet. Copied like any other new object it stood on the other players' desk
-- as a package or a jar that was not there, and they could pick the package up: the
-- drugs then existed twice, in their pockets and still in the pockets of the player who
-- was only aiming. Equipment and furniture carry a flag; a package is known by being the
-- one the local player's station holds as its gizmo.
function Dyn.isGizmo(actor)
    local gizmo = false
    pcall(function() gizmo = actor.isGizmo == true end)
    if gizmo then return true end
    pcall(function() gizmo = actor.isGizmo_0 == true end)
    if gizmo then return true end
    pcall(function()
        local station = World.player().curWorkStation
        if not valid(station) then return end
        local addr = actor:GetAddress()
        for _, name in ipairs({ "drugPackageGizmo", "equipmentGizmo" }) do
            local held = station[name]
            if valid(held) and held:GetAddress() == addr then gizmo = true end
        end
    end)
    return gizmo
end

---------------------------------------------------------------- a model for everything

-- A dropped thing that shows nothing cannot be found again, by whoever dropped it or by
-- the player it was meant for. A pickup that still has no model a moment after it was made
-- gets a small bag as a stand-in; picking it up gives the real item all the same.
local PICKUP_BASE = "/Game/Interactive/pickupItemBase.pickupItemBase_C"
local STAND_IN = "/Game/Interactive/Additives/spiceBag_Small.spiceBag_Small"
local MODEL_CHECK = 1.0          -- seconds after creation; the game sets some models late
local unseen = {}                -- pickups waiting for that check

-- True if the pickup had no model and was given the stand-in.
function Dyn.ensureModel(actor)
    if not Core.alive(actor) then return false end
    local ok, fixed = pcall(function()
        local base = Core.class(PICKUP_BASE)
        if not valid(base) or not actor:IsA(base) then return false end
        local model = actor.Model
        if not valid(model) or valid(model.StaticMesh) then return false end
        -- looked up now and used now: a mesh kept across ticks can be collected meanwhile
        local mesh = StaticFindObject(STAND_IN)
        if not valid(mesh) then
            pcall(function() LoadAsset(STAND_IN:gsub("%.[^%.]+$", "")) end)
            mesh = StaticFindObject(STAND_IN)
        end
        if not valid(mesh) then return false end
        model:SetStaticMesh(mesh)
        model:SetVisibility(true, false)
        return true
    end)
    if ok and fixed == true then
        Dyn.stats.standIns = (Dyn.stats.standIns or 0) + 1
        log("Dyn: %s had no model, a small bag stands in for it", actor:GetClass():GetFName():ToString())
        return true
    end
    return false
end

local function checkModelLater(actor)
    unseen[#unseen + 1] = { actor = actor, at = os.clock() + MODEL_CHECK }
end

---------------------------------------------------------------- creation

local STAMP = string.format("%x", os.time() % 0xFFFFFFF)

-- A dropped thing stays where it was made (at the player's hands); what falls to the ground
-- is its model. A copy made from the thing's place alone hangs in the air, so the model's
-- place travels along: while it falls the copy is let fall too, and when it has come to
-- rest the copy is put exactly there.
local function modelPose(actor)
    local pose = nil
    pcall(function()
        local model = actor.Model
        if not valid(model) then return end
        local l, r = model:K2_GetComponentLocation(), model:K2_GetComponentRotation()
        pose = { x = l.X, y = l.Y, z = l.Z, p = r.Pitch, yw = r.Yaw, r = r.Roll, f = model:IsSimulatingPhysics(FName("None")) == true }
    end)
    return pose
end

local function placeModel(actor, pose, falling)
    pcall(function()
        local model = actor.Model
        if not valid(model) then return end
        if not falling then model:SetSimulatePhysics(false) end
        model:K2_SetWorldLocationAndRotation({ X = pose.x, Y = pose.y, Z = pose.z }, { Pitch = pose.p or 0, Yaw = pose.yw or 0, Roll = pose.r or 0 }, false, {}, true)
        if falling then model:SetSimulatePhysics(true) end
    end)
end

local falling = {}               -- our own things whose model has not come to rest yet, by id
local REST_AFTER = 6             -- seconds after which a model counts as at rest whatever it does

-- Somebody is loading the world we saved for them: what is made now is not in that save.
local late = {}                  -- what this game made lately: { id, actor, at }
local LATE_KEEP = 300
local function joinInFlight()
    if World.role == "guest" or not Net.isHost() then return false end
    local now = os.clock()
    for _, at in pairs(World.savedFor) do
        if now - at < LATE_KEEP then return true end
    end
    return false
end

local function spawnMessage(id, actor)
    local loc = actor:K2_GetActorLocation()
    local rot = actor:K2_GetActorRotation()
    local data = { n = id, c = classPath(actor), x = loc.X, y = loc.Y, z = loc.Z, p = rot.Pitch, yw = rot.Yaw, r = rot.Roll,
        v = Repl.export(actor, Repl.savedVars(actor)) }
    local pose = modelPose(actor)
    -- only a model that has left its thing is worth telling about
    if pose and (pose.f or math.abs(pose.x - loc.X) + math.abs(pose.y - loc.Y) + math.abs(pose.z - loc.Z) > 2) then data.m = pose end
    return data, pose
end

local function announce(actor, madeAt)
    if not eligible(actor) then return end
    if Dyn.isGizmo(actor) then
        Dyn.stats.gizmos = (Dyn.stats.gizmos or 0) + 1
        return
    end
    counter = counter + 1
    -- player, the moment this game was started, a running number: a game that is restarted
    -- does not hand out the numbers of its earlier run again
    local id = tostring(Net.S.me) .. "-" .. STAMP .. "-" .. tostring(counter)
    local key = "d:" .. id
    Repl.adopt(actor, key)
    Dyn.objects[id] = { actor = actor, near = true }
    local data, pose = spawnMessage(id, actor)
    sendTo("spawn", data)
    if pose and pose.f then falling[id] = { actor = actor, since = os.clock(), last = pose, still = 0 } end
    late[#late + 1] = { id = id, actor = actor, at = madeAt or os.clock() }
    Dyn.stats.spawned = Dyn.stats.spawned + 1
    checkModelLater(actor)
    vlog("Dyn: created %s as %s", actor:GetClass():GetFName():ToString(), id)
end

-- Objects that were read from the map's own file are in every game already.
local RF_WAS_LOADED = 0x00040000
local function fromTheMap(actor)
    local ok, loaded = pcall(function() return actor:HasAnyFlags(RF_WAS_LOADED) end)
    return ok and loaded == true
end
local LOAD_TIME = 30             -- seconds after a save starts loading: what appears then is the save's

-- Up to v0.11.1 this was a hook on the engine's own FinishSpawningActor. UE4SS crashes
-- the game when such a hook on an engine function fires for a call made by the inventory
-- window's drop handler (a Blueprint function with reference parameters): dragging an item
-- out of the inventory killed the game, alone or with others. A hook on a Blueprint
-- function has no such problem, and every interactive class passes through this one.
Core.Hooks.add(INTERACTIVE_BASE .. ":ReceiveBeginPlay", function(context)
    Dyn.stats.begun = (Dyn.stats.begun or 0) + 1
    if applying or not Core.enabled("Spawns") or not (World.shared() or joinInFlight()) then return end
    local now = os.clock()
    if now - startedAt < QUIET_AFTER_START or now - World.loadStartedAt < LOAD_TIME then return end
    local ok, actor = pcall(function() return context:get() end)
    if not ok or not valid(actor) or fromTheMap(actor) then return end
    pending[#pending + 1] = { actor = actor, at = now + SETTLE, made = now }
end)

Repl.on("spawn", function(sender, data)
    if not World.active or not Core.enabled("Spawns") then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= Net.S.owner then return end
    local id = tostring(data.n)
    if Dyn.objects[id] then return end
    local player = World.player()
    local class = loadClass(tostring(data.c))
    if not player or not class then
        log("Dyn: cannot create %s", tostring(data.c))
        return
    end
    applying = true
    local ok, e = pcall(function()
        local actor = player:GetWorld():SpawnActor(class, { X = data.x, Y = data.y, Z = data.z },
            { Pitch = data.p or 0, Yaw = data.yw or 0, Roll = data.r or 0 })
        if not valid(actor) then error("spawn returned nothing") end
        if type(data.v) == "table" then Repl.import(actor, data.v) end
        -- The hooks the game itself runs after loading such an object from a save.
        pcall(function() actor:SubclassRamaLoaded() end)
        pcall(function() actor:RamaLoaded() end)
        Repl.adopt(actor, "d:" .. id)
        Dyn.objects[id] = { actor = actor, near = true }
        if type(data.m) == "table" and type(data.m.x) == "number" then placeModel(actor, data.m, data.m.f == true) end
        checkModelLater(actor)
    end)
    applying = false
    if not ok then
        log("Dyn: creating %s failed: %s", tostring(data.c), tostring(e))
        return
    end
    Dyn.stats.received = Dyn.stats.received + 1
    vlog("Dyn: %s created %s", Net.name(sender), id)
    if World.role == "host" then sendTo("spawn", data, sender) end
end)

---------------------------------------------------------------- coming to rest

Core.every(0.25, function()
    if next(falling) == nil then return end
    local now = os.clock()
    for id, f in pairs(falling) do
        local pose = Core.alive(f.actor) and modelPose(f.actor) or nil
        if not pose then
            falling[id] = nil
        else
            local moved = math.abs(pose.x - f.last.x) + math.abs(pose.y - f.last.y) + math.abs(pose.z - f.last.z)
            f.still = moved < 0.5 and f.still + 1 or 0
            f.last = pose
            if f.still >= 2 or now - f.since > REST_AFTER then
                falling[id] = nil
                pose.f = nil
                pose.n = id
                sendTo("rest", pose)
                vlog("Dyn: %s came to rest at %.0f %.0f %.0f", id, pose.x, pose.y, pose.z)
            end
        end
    end
end)

Net.on("rest", function(sender, data)
    if not World.active or not Core.enabled("Spawns") then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= Net.S.owner then return end
    local entry = Dyn.objects[tostring(data.n)]
    if entry and Core.alive(entry.actor) and type(data.x) == "number" then placeModel(entry.actor, data, false) end
    if World.role == "host" then sendTo("rest", data, sender) end
end)

---------------------------------------------------------------- removal

-- Tells the others that an object is gone here. `key` is its replication key.
function Dyn.announceGone(id, key)
    sendTo("despawn", { n = id, k = key })
    Dyn.stats.removed = Dyn.stats.removed + 1
    vlog("Dyn: removed %s", tostring(id or key))
end

Net.on("despawn", function(sender, data)
    if not World.active or not Core.enabled("Spawns") then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= Net.S.owner then return end
    local id = data.n and tostring(data.n) or nil
    local entry = id and Dyn.objects[id] or nil
    local actor = entry and entry.actor or (data.k and Repl.find(tostring(data.k))) or nil
    if id then Dyn.objects[id] = nil end
    if actor and Core.alive(actor) and not isPawn(actor) then
        applying = true
        pcall(function() Repl.remoteGone[Repl.key(actor)] = true end)
        pcall(function() actor:K2_DestroyActor() end)
        applying = false
        vlog("Dyn: %s removed %s", Net.name(sender), tostring(id or data.k))
    end
    if World.role == "host" then sendTo("despawn", data, sender) end
end)

---------------------------------------------------------------- upkeep

Core.onTick(function()
    if #unseen > 0 then
        local now = os.clock()
        local i = 1
        while i <= #unseen do
            if now >= unseen[i].at then
                Dyn.ensureModel(table.remove(unseen, i).actor)
            else
                i = i + 1
            end
        end
    end
    if #pending == 0 then return end
    local now = os.clock()
    local i = 1
    while i <= #pending do
        local p = pending[i]
        if now >= p.at then
            table.remove(pending, i)
            if World.shared() or joinInFlight() then
                local ok, e = pcall(announce, p.actor, p.made)
                if not ok then log("Dyn: announce failed: %s", tostring(e)) end
            end
        else
            i = i + 1
        end
    end
end)

Core.every(1, function()
    if not World.shared() then return end
    local player = World.player()
    if not player then return end
    local loc = player:K2_GetActorLocation()
    for id, e in pairs(Dyn.objects) do
        if Core.alive(e.actor) then
            local ok, a = pcall(function() return e.actor:K2_GetActorLocation() end)
            if ok then
                local dx, dy, dz = a.X - loc.X, a.Y - loc.Y, a.Z - loc.Z
                e.near = dx * dx + dy * dy + dz * dz <= NEAR * NEAR
            end
        else
            Dyn.objects[id] = nil
            -- Objects can also be despawned by distance; only a removal that happened
            -- next to our player is something the player did.
            if e.near then Dyn.announceGone(id, "d:" .. id) end
        end
    end
end)

World.listen("start", function(role)
    Dyn.objects, pending, unseen, falling, Repl.remoteGone = {}, {}, {}, {}, {}
    -- A freshly loaded world creates a burst of objects of its own; the host has no such burst.
    startedAt = role == "guest" and os.clock() or 0
end)
World.listen("stop", function() Dyn.objects, pending, unseen, falling, late = {}, {}, {}, {}, {} end)

-- Things made during play are known under a name given at that moment. A guest who
-- arrives later loads them from the host's save under the name they have by themselves,
-- so the host tells the newcomer which is which.
World.listen("peer", function(id)
    if World.role ~= "host" then return end
    local list = Repl.aliases()
    for start = 1, #list, 60 do
        Repl.send("alias", { l = table.move(list, start, math.min(start + 59, #list), 1, {}) }, id)
    end
    if #list > 0 then vlog("Dyn: %d name(s) of things made during play sent to %s", #list / 2, Net.name(id)) end
    -- What was made after the world was saved for this player is not in what they loaded.
    local since, now, sent = World.savedFor[id], os.clock(), 0
    for i = #late, 1, -1 do
        local e = late[i]
        if now - e.at > LATE_KEEP or not Core.alive(e.actor) then
            table.remove(late, i)
        elseif since and e.at > since then
            local ok, err = pcall(function()
                -- the first player to arrive starts the shared world, which forgets all names
                Repl.adopt(e.actor, "d:" .. e.id)
                Dyn.objects[e.id] = Dyn.objects[e.id] or { actor = e.actor, near = true }
                local data = spawnMessage(e.id, e.actor)
                -- what has come to rest already is put there, not dropped again
                if data.m and not falling[e.id] then data.m.f = false end
                Repl.send("spawn", data, id)
                -- players who are in already loaded it under the name it has by itself
                local natural = Repl.naturalKey(e.actor)
                for _, other in ipairs(World.targets()) do
                    if other ~= id and natural then Repl.send("alias", { l = { natural, "d:" .. e.id } }, other) end
                end
                sent = sent + 1
            end)
            if not ok then log("Dyn: could not pass on %s: %s", tostring(e.id), tostring(err)) end
        end
    end
    if sent > 0 then log("Dyn: %d thing(s) made while %s was loading passed on", sent, Net.name(id)) end
end)

Repl.on("alias", function(sender, data)
    if World.role ~= "guest" or sender ~= (World.host or Net.S.owner) or type(data.l) ~= "table" then return end
    Repl.registry(90)
    local n = 0
    for i = 1, #data.l - 1, 2 do
        local natural, given = tostring(data.l[i]), tostring(data.l[i + 1])
        local actor = Repl.known(natural)
        if actor and given:sub(1, 2) == "d:" then
            Repl.adopt(actor, given)
            Dyn.objects[given:sub(3)] = { actor = actor, near = true }
            n = n + 1
        end
    end
    log("Dyn: %d of %d thing(s) made during play matched with the host's names", n, #data.l / 2)
end)

function Dyn.isApplying() return applying end

return Dyn
