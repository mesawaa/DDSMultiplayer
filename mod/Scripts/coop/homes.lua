-- Hideouts.
--
-- 1. "New appartments available! Check out the offer, contact Mike Byers at ShadyComm!",
--    over and over, with nothing new on offer. The game's own doing: every 62 seconds the
--    apartment manager counts the hideouts whose level the player has (by the level written
--    on each hideout in the world) and gives the hint when that is more than the number it
--    remembered (lastApartmentCount). But whenever the list of hideouts on offer is made
--    (after a load, on opening the apartment viewer or Donald's shop, after renting) it
--    remembers the length of that list instead, and the list goes by the levels in the
--    hideout table. Five properties of sector C say "level 1" in the world and 26 and up in
--    the table: counted, never listed, so the count is above the list for the whole game
--    until sector C and every time the list is made the hint comes again a minute later.
--    The mod made it worse: the remembered number travelled between the games, so one
--    player opening the shop gave everybody the hint. Here the number is put back to the
--    count as soon as the list has been made; the game's check then only speaks up when
--    the count itself grows, which is a level that really opens a hideout.
--
-- 2. A hideout rented by one player is everybody's. Renting is done on the phone, far from
--    the hideout, and the mod only compared saved objects next to a player: the other games
--    never heard of it. Their doors stayed locked, and a hideout rented by a guest was not
--    in the host's world at all, so it was gone with the next save. Every hideout's rent
--    state and furniture stock is now compared wherever the players are and sent when it
--    changes; a game that hears a hideout has been rented does what the game does for the
--    one who rented it (unlockAppartment: doors, garage doors, save station).

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Homes = { stats = { held = 0, sent = 0, applied = 0, opened = 0, closed = 0 } }

local AREA = "/Game/Interactive/rentAppartmentArea.rentAppartmentArea_C"
local MANAGER = "/Game/AppartmentSystem/appartmentManager.appartmentManager_C"
local DOOR = "/Game/Interactive/doorBase.doorBase_C"
local GARAGE = "/Game/Interactive/garageDoorBase.garageDoorBase_C"
local STATION = "/Game/Interactive/saveStation.saveStation_C"
local SETTLE = 40                -- seconds after a load before anything here is compared

local function on() return Core.enabled("Homes") end

local function areas()
    return Core.actors(AREA) or {}
end

---------------------------------------------------------------- the hint

local seen = { load = nil, level = nil, count = nil, told = false }
Homes.seen = seen

-- Hideouts the game's 62-second check counts for this level.
local function counted(level)
    local n = 0
    for _, a in ipairs(areas()) do
        local ok, min = pcall(function() return a.areaMinLevel end)
        if ok and type(min) == "number" and min <= level then n = n + 1 end
    end
    return n
end

local function calm()
    if not on() or not Core.player() then return end
    local m, stats = Core.find("appartmentManager_C"), Core.find("statisticsManager_C")
    if not m or not stats then return end
    local level = tonumber(stats.playerLevel)
    if not level then return end
    local count = counted(level)
    if count == 0 then return end
    if seen.load ~= World.loadStartedAt then
        seen.load, seen.level, seen.count, seen.told = World.loadStartedAt, nil, nil, false
    end
    local last = tonumber(m.lastApartmentCount) or 0
    local function pin()
        if last == count then return end
        m.lastApartmentCount = count
        if last < count then
            Homes.stats.held = Homes.stats.held + 1
            if not seen.told then
                seen.told = true
                log("Homes: 'new apartments' hint held back (the game counts %d hideouts for level %d, its list had %d)", count, level, last)
            end
        end
    end
    -- A new start: a world just loaded (a guest's own level is put back some seconds after
    -- the host's world has loaded, and the number in the save is the host's).
    if seen.count == nil or level < seen.level or os.clock() - World.loadStartedAt < SETTLE then
        seen.level, seen.count = level, count
        pin()
        return
    end
    if count > seen.count then
        -- A level that opens a hideout has been reached: the game's check says so, once (it
        -- then remembers the new count).
        if last >= count then
            seen.level, seen.count = level, count
        elseif last ~= seen.count then
            m.lastApartmentCount = seen.count
        end
        return
    end
    seen.level = level
    pin()
end
Homes.calm = calm

-- Right after the list has been made, and now and then for a list made before the hook was
-- there (the one after a load).

-- The game lists the hideouts of the player's own level. In a shared world a hideout is
-- everybody's and is paid from the shared account, so the list goes by the highest level
-- in the world: a guest who has only just started can rent what the host could. Done by
-- making the list once more, right after the game has, with that level standing in for
-- the player's own for the length of the call (nothing else runs in between).
local widening = false
local function widen(manager)
    if widening or not on() or not World.shared() then return end
    local stats = Core.find("statisticsManager_C")
    local Scale = package.loaded["coop.scale"]
    if not stats or not Scale or not Scale.accountLevel then return end
    local own, best = tonumber(stats.playerLevel), tonumber(Scale.accountLevel())
    if not own or not best or best <= own then return end
    widening = true
    stats.playerLevel = best
    local ok, e = pcall(function() manager:refreshAppartments() end)
    stats.playerLevel = own
    widening = false
    Homes.stats.widened = (Homes.stats.widened or 0) + 1
    if not ok then log("Homes: making the hideout list for level %d failed: %s", best, tostring(e)) end
end

Core.Hooks.add(MANAGER .. ":refreshAppartments", function(context)
    if widening then return end
    pcall(function()
        local manager = context:get()
        if valid(manager) then widen(manager) end
    end)
    calm()
end)
Core.every(5, calm)

---------------------------------------------------------------- rented for everybody

-- What of a hideout is the same in every game. (The rest of its saved variables are fixed
-- texts and numbers of the level, or belong to raids and the labs of sector C.)
local SHARED = { "areaRented", "areaRentedTill", "areaRentedForever", "areaOnDebt",
    "appartmentInventory", "appartmentInventoryNames", "appartmentInventoryQuantities", "CustomHideoutName" }
local IS_SHARED = {}
for _, name in ipairs(SHARED) do IS_SHARED[name] = true end

local known = {}                 -- hideout key -> name -> text: what the other games have of it
local cursor = 0
Homes.known = known

local function overlapping(area, path)
    local class = Core.class(path)
    if not class then return {} end
    local out = {}
    if not pcall(function() area.Overlap:GetOverlappingActors(out, class) end) then return {} end
    local raw = out
    if #raw == 0 and type(out.OverlappingActors) == "table" then raw = out.OverlappingActors end
    local list = {}
    for _, x in ipairs(raw) do
        local actor = x
        if type(x) == "userdata" and x.IsValid == nil and x.get then
            local ok, v = pcall(function() return x:get() end)
            actor = ok and v or nil
        end
        if actor ~= nil and Core.alive(actor) then list[#list + 1] = actor end
    end
    return list
end

-- What the game does in the game of the player who rents a hideout.
local function open(area)
    local ok, e = pcall(function() area:unlockAppartment() end)
    if not ok then log("Homes: unlocking a hideout failed: %s", tostring(e)) return end
    pcall(function() area:checkPlayerOverlaping() end)   -- a player already standing in it is at home
    Homes.stats.opened = Homes.stats.opened + 1
end

-- A hideout lost somewhere else (raided): the way in is closed here as well. What stands in
-- it is left alone.
local function shut(area)
    for _, d in ipairs(overlapping(area, DOOR)) do
        pcall(function()
            d.doorLocked = true
            d.canLockpick = true
            if d.doorIsOpen == true then d:closeDoor() end
        end)
    end
    for _, g in ipairs(overlapping(area, GARAGE)) do
        pcall(function()
            g.garageLocked = true
            g.canLockpick = true
        end)
    end
    for _, s in ipairs(overlapping(area, STATION)) do
        pcall(function() s.canUseStation = false end)
    end
    pcall(function() area.playerIn = false end)
    Homes.stats.closed = Homes.stats.closed + 1
end

local function rented(values) return values ~= nil and values.areaRented == "True" end

local function name(area)
    local ok, id = pcall(function() return area.HideoutID:ToString() end)
    return ok and id or "?"
end

local function find(key)
    local a = Repl.find(key)
    if a then return a end
    for _, x in ipairs(areas()) do
        if Repl.key(x) == key then return x end
    end
    return nil
end

-- Takes what another game says about a hideout. Returns the hideout, or nil.
local function apply(key, values)
    local area = find(key)
    if not area then return nil end
    local take, n = {}, 0
    for k, text in pairs(values) do
        if IS_SHARED[k] and type(text) == "string" then
            take[k] = text
            n = n + 1
        end
    end
    if n == 0 then return nil end
    local was = area.areaRented == true
    Repl.import(area, take)
    local now = area.areaRented == true
    known[key] = Repl.export(area, SHARED)
    if now and not was then
        open(area)
        log("Homes: %s has been rented, open to everybody", name(area))
    elseif was and not now then
        shut(area)
        log("Homes: %s is no longer rented, closed", name(area))
    end
    Homes.stats.applied = Homes.stats.applied + 1
    return area
end
Homes.apply = apply

-- What has changed on a hideout since the others last heard of it (nil: nothing, or it was
-- looked at for the first time: everybody has that from the save the world was loaded from).
local function changes(area)
    local key = Repl.key(area)
    local now = Repl.export(area, SHARED)
    local before = known[key]
    known[key] = now
    if not before then return nil end
    local changed, n = {}, 0
    for k, text in pairs(now) do
        if before[k] ~= text then
            changed[k] = text
            n = n + 1
        end
    end
    if n == 0 then return nil end
    -- (the flag can also have come through the comparison of things next to a player: that
    -- sets it and opens nothing)
    if changed.areaRented == "True" then open(area) end
    return key, changed
end
Homes.changes = changes

Core.every(0.5, function()
    if not on() then return end
    if not World.shared() or os.clock() - World.loadStartedAt < SETTLE then
        if next(known) ~= nil then
            known = {}
            Homes.known = known
        end
        return
    end
    local list = areas()
    if #list == 0 then return end
    for _ = 1, math.min(4, #list) do
        cursor = cursor % #list + 1
        local ok, key, changed = pcall(changes, list[cursor])
        if ok and key then
            Repl.sendMany("home", { k = key, v = changed }, World.targets())
            Homes.stats.sent = Homes.stats.sent + 1
            vlog("Homes: sent %s of %s", changed.areaRented and ("rented " .. changed.areaRented) or "a change", name(list[cursor]))
        elseif not ok then
            vlog("Homes: looking at a hideout failed: %s", tostring(key))
        end
    end
end)

Repl.on("home", function(sender, data)
    if not on() or not World.active or type(data.k) ~= "string" or type(data.v) ~= "table" then return end
    if World.role == "guest" then
        if sender ~= (World.host or Net.S.owner) then return end
    elseif not World.isPeer(sender) then
        return
    end
    local ok, area = pcall(apply, data.k, data.v)
    if not ok then
        log("Homes: taking a hideout's state failed: %s", tostring(area))
        return
    end
    if area and World.role == "host" then
        -- the other guests hear it from the host
        local rest = {}
        for _, id in ipairs(World.targets()) do
            if id ~= sender then rest[#rest + 1] = id end
        end
        if #rest > 0 then Repl.sendMany("home", { k = data.k, v = data.v }, rest) end
    end
end)

-- A newcomer has the world as it was saved for them a moment ago: what is rented now is
-- said once more, in case it was rented while they were loading.
World.listen("peer", function(id)
    if not on() or World.role ~= "host" then return end
    Core.after(2, function()
        if not World.isPeer(id) then return end
        local n = 0
        for _, a in ipairs(areas()) do
            pcall(function()
                if a.areaRented == true then
                    Repl.send("home", { k = Repl.key(a), v = Repl.export(a, SHARED) }, id)
                    n = n + 1
                end
            end)
        end
        vlog("Homes: told the newcomer about %d rented hideout(s)", n)
    end)
end)

World.listen("stop", function()
    known = {}
    Homes.known = known
end)

return Homes
