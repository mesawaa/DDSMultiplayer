-- What a kind of character does besides its base numbers (coop/look.lua has the list and
-- applies stamina, speed, pockets and how easily the police spot you):
--
--   tagTime   a wall tag takes this share of the usual time. The game counts the hold on
--             the spray marker (sprayPlacementGizmo_C.heldTimer) up to holdTimePlacement;
--             that number is set on the player's marker whenever there is one.
--   drugTime  a drug works this many times as long. Every dose in the body is a record of
--             its own (HumanoidActor.inBodySubstances): calcRateExcretion is how many game
--             hours it takes to leave the body, calcRateDecomposition goes with it, and
--             both are the substance's rate times what calcRateAbsorption is times its
--             rate. The two are kept at drugTime times that. Nothing else is written, so
--             the same check after a load finds a stretched dose as it left it.
--   seenHigh  how much easier the police spot the player while a dose is working.
--   freePick  a lock opens for one bobby pin without the lockpick game: when the game has
--             started it (it only does with a pin in the pockets), what its success does
--             is done at once and the game is closed again.
--   pickHeat  what the police make of a lock opened like that: a row of the game's own
--             list of things that expose a dealer (ExpoEventsDatabase), added for every
--             pickHeatEvery-th lock the player forces (2: half a police search a lock).
--
-- Everything here is about the local player and nothing is sent to anybody.

local Core = require("core")
local World = require("coop.world")
local Look = require("coop.look")
local Hud = require("coop.hud")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_TRAITS_GEN") or 0) + 1
_G.DDSMP_TRAITS_GEN = GEN
local function live() return rawget(_G, "DDSMP_TRAITS_GEN") == GEN end

local Traits = { stats = { tags = 0, doses = 0, picks = 0 }, high = false }

local GIZMO_DEFAULTS = "/Game/TerritorySpraying/sprayPlacementGizmo.Default__sprayPlacementGizmo_C"
local DOOR = "/Game/Interactive/doorBase.doorBase_C"
local GARAGE = "/Game/Interactive/garageDoorBase.garageDoorBase_C"
local PLAYER = "/Game/Player/playerCharacterBP.playerCharacterBP_C"
local OPENED = "/Game/Audio/Lockpick/lockOpenCue.lockOpenCue"

---------------------------------------------------------------- tags

local usualHold = nil

Core.every(0.3, function()
    if not live() then return end
    local player = World.player()
    if not player then return end
    local gizmo = nil
    pcall(function() gizmo = player.sprayGizmo end)
    if not valid(gizmo) then return end
    if not usualHold then
        local defaults = Core.object(GIZMO_DEFAULTS)
        local ok, v = pcall(function() return defaults.holdTimePlacement end)
        if not ok or type(v) ~= "number" or v <= 0 then return end
        usualHold = v
    end
    local c = Look.active()
    local want = usualHold * ((c and c.tagTime) or 1)
    pcall(function()
        if math.abs(gizmo.holdTimePlacement - want) > 0.001 then
            gizmo.holdTimePlacement = want
            Traits.stats.tags = Traits.stats.tags + 1
        end
    end)
end)

---------------------------------------------------------------- drugs

local body, bodyOf = nil, nil

-- The object the game keeps the player's doses in (one per world).
local function health()
    local player = World.player()
    if not player then return nil end
    local address = player:GetAddress()
    if bodyOf == address and body then return body end
    body, bodyOf = nil, nil
    pcall(function()
        local sae = Core.object("/Script/DrugDealerSimulator.Default__ShiroBlueprint"):GetSAE()
        local h = valid(sae) and sae:GetHealthObject() or nil
        if valid(h) then body, bodyOf = h, address end
    end)
    return body
end

local function near(a, b) return math.abs(a - b) <= math.max(1e-5, math.abs(b) * 0.002) end

Core.every(0.5, function()
    if not live() then return end
    local c = Look.active()
    local stretch = c and c.drugTime or nil
    local watched = c and (stretch or c.seenHigh)
    if not watched then
        if Traits.high then
            Traits.high = false
            Look.applyTraits()
        end
        return
    end
    local h = health()
    if not h then return end
    local high = false
    pcall(function()
        h.inBodySubstances:ForEach(function(e)
            local dose = e:get()
            if not valid(dose) or dose.stillEffective ~= true then return end
            high = true
            if not stretch or stretch == 1 then return end
            local rates = dose.takenBase
            if not valid(rates) or rates.rateAbsorption <= 0 then return end
            local share = dose.calcRateAbsorption / rates.rateAbsorption
            if share <= 0 then return end
            local leave, decay = rates.rateExcretion * share * stretch, rates.rateDecomposition * share * stretch
            if not near(dose.calcRateExcretion, leave) or not near(dose.calcRateDecomposition, decay) then
                dose.calcRateExcretion, dose.calcRateDecomposition = leave, decay
                Traits.stats.doses = Traits.stats.doses + 1
            end
        end)
    end)
    if high ~= Traits.high then
        Traits.high = high
        Look.applyTraits()
    end
end)

-- coop/look.lua asks this whenever it works out how visible the player is.
Look.seenNow = function(c)
    if c and c.seenHigh and Traits.high then return c.seenHigh end
    return 1
end

---------------------------------------------------------------- locks

local function isA(object, path)
    local class = Core.class(path)
    local ok, yes = pcall(function() return class ~= nil and object:IsA(class) end)
    return ok and yes == true
end

-- Does what the lockpick game does when it is won (BP_MyLockpickPuzzle_C: UnlockedDone),
-- for the price of one pin.
local function force(player)
    local target = player.hoveredObject
    if not valid(target) then return false end
    local door, garage = isA(target, DOOR), isA(target, GARAGE)
    if not door and not garage then return false end
    local has, left = {}, {}
    player:checkBobbyPins(true, has, left)
    if door then target.doorLocked = false else target.garageLocked = false end
    pcall(function()
        local cue = Core.object(OPENED)
        if valid(cue) then Core.statics():PlaySound2D(player, cue, 1.0, 1.0, 0.0, nil, nil) end
    end)
    player:closeLockpickMode()
    Traits.stats.picks = Traits.stats.picks + 1
    local c = Look.active()
    if c and c.pickHeat then
        local count = Look.forcedLock()
        local every = math.max(1, math.floor(tonumber(c.pickHeatEvery) or 1))
        if count % every == 0 then
            Traits.stats.pickHeat = (Traits.stats.pickHeat or 0) + 1
            pcall(function()
                local stats = Core.find("statisticsManager_C")
                if valid(stats) then stats:NewExpoEvent(FName(c.pickHeat)) end
            end)
        end
    end
    local pins = tonumber(left.bobbyPinCount)
    if pins then Hud.toast(string.format("Lock forced. Bobby pins left: %d", pins), 3) end
    return true
end

Core.Hooks.add(PLAYER .. ":startLockpickMode", function(context)
    if not live() then return end
    local c = Look.active()
    if not c or not c.freePick then return end
    local player = context:get()
    if not valid(player) then return end
    local started = false
    pcall(function() started = player.isLockpicking == true end)
    if not started then return end          -- no pin: the game has said so itself
    local ok, e = pcall(force, player)
    if not ok then log("Traits: forcing a lock failed: %s", tostring(e)) end
end)

World.listen("stop", function()
    if not live() then return end
    body, bodyOf = nil, nil
    Traits.high = false
end)

return Traits
