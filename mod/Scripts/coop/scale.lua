-- More players, more to do.
--
-- While other players are in the world the host's game puts more people on the streets and
-- finds new clients faster and in greater number, and Eddie's order limit is higher for
-- everybody. The amounts are in config.lua. Nothing of this reaches a save: the game's own
-- numbers are put back before every save and when the last guest leaves.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")

local log = Core.log

local Scale = { knobs = {} }

-- Players in this world, ourselves included.
function Scale.players()
    if not World.shared() then return 1 end
    -- The host knows who is in the world and tells every guest (World.others).
    return #World.others() + 1
end

local function extra() return math.max(0, Scale.players() - 1) end

-- The host's world: each number grows by `per` (config) for every player after the first.
-- `inverse` numbers are waiting times and shrink instead.
local KNOBS = {
    { class = "populationManager_C", var = "peopleOnStreetMax", per = "PopulationPerExtraPlayer", whole = true },
    { class = "salesManager_C", var = "maxClientsPerLevel", per = "ClientsPerExtraPlayer", whole = true },
    { class = "salesManager_C", var = "newClientIntervalMin", per = "ClientsPerExtraPlayer", inverse = true },
    { class = "salesManager_C", var = "newClientIntervalMax", per = "ClientsPerExtraPlayer", inverse = true },
}

local function same(a, b) return math.abs(a - b) < 0.001 end

local function apply(restore)
    for _, k in ipairs(KNOBS) do
        local obj = Core.find(k.class)
        if obj then
            local ok, e = pcall(function()
                local key = k.class .. "." .. k.var
                local now = obj[k.var]
                local s = Scale.knobs[key]
                -- A different value than the one we left there: a new world, or the game changed it.
                if not s or not same(now, s.value) then
                    s = { base = now, value = now, factor = 1 }
                    Scale.knobs[key] = s
                end
                local factor = 1
                if not restore and World.role == "host" then
                    factor = 1 + (tonumber(Core.config[k.per]) or 0) * extra()
                end
                if same(factor, s.factor) then return end
                local value = k.inverse and s.base / factor or s.base * factor
                if k.whole then value = math.floor(value + 0.5) end
                obj[k.var] = value
                log("Scale: %s %s -> %s (%d player(s))", key, tostring(s.base), tostring(value), Scale.players())
                s.value, s.factor = value, factor
            end)
            if not ok then log("Scale: could not set %s.%s: %s", k.class, k.var, tostring(e)) end
        end
    end
end

Core.every(2, function()
    if not Core.player() then return end         -- at the menu and while loading there is nothing to scale
    apply(false)
end)

-- The game's own numbers go into the save.
pcall(RegisterHook, "/Script/RamaSaveSystem.RamaSaveLibrary:RamaSave_SaveToFile", function()
    pcall(apply, true)
end, function() end)

---------------------------------------------------------------- Eddie's order limit

-- What the game works out is (limit by level) - debt: 120 + 35 a level (more from level 5)
-- minus mainComputer.PlayerEddieDebt. The debt is one number for the whole world, the
-- level is each player's own. Left alone, a level 1 guest in a level 3 host's world had 140
-- less to order than the host from the very same account (15 left where the host had 155).
-- So the limit by level is taken from the highest level in the world, the same in every
-- game, and then multiplied; the debt is not.
function Scale.orderLimitFactor()
    if not World.shared() then return 1 end
    return (tonumber(Core.config.OrderLimitMultiplier) or 1) + (tonumber(Core.config.OrderLimitPerExtraPlayer) or 0) * extra()
end

local levels = {}            -- host: every guest's level, as they told us
local toldAccount = nil      -- guest: the highest level in the world, as the host told us
local sentOwn, sentAccount, sentAt = nil, nil, 0

local function ownLevel()
    local level = nil
    pcall(function() level = Core.find("statisticsManager_C").playerLevel end)
    return type(level) == "number" and level or nil
end

-- The level Eddie's limit is worked out from: the highest among the players in the world.
function Scale.accountLevel()
    local own = ownLevel()
    if not own or not World.shared() then return own end
    local best = own
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if (levels[id] or 0) > best then best = levels[id] end
        end
    elseif (toldAccount or 0) > best then
        best = toldAccount
    end
    return best
end

Core.every(2, function()
    if not World.shared() then
        sentOwn, sentAccount = nil, nil
        return
    end
    local own, now = ownLevel(), os.clock()
    if not own then return end
    if World.role == "host" then
        local account = Scale.accountLevel()
        if account ~= sentAccount or now - sentAt > 20 then
            sentAccount, sentAt = account, now
            for _, id in ipairs(World.targets()) do Net.send("lvl", { a = account }, id) end
        end
    elseif own ~= sentOwn or now - sentAt > 20 then
        sentOwn, sentAt = own, now
        Net.send("lvl", { l = own }, World.host or Net.S.owner)
    end
end)

Net.on("lvl", function(sender, data)
    if not World.active then return end
    if World.role == "host" then
        if World.inWorld[sender] and tonumber(data.l) then levels[sender] = math.floor(tonumber(data.l)) end
    elseif sender == (World.host or Net.S.owner) and tonumber(data.a) then
        toldAccount = math.floor(tonumber(data.a))
    end
end)

World.listen("peer", function() sentAccount = nil end)                      -- the newcomer hears it at once
World.listen("peerleft", function(id) levels[id] = nil end)
World.listen("start", function() levels, toldAccount, sentOwn, sentAccount = {}, nil, nil, nil end)
World.listen("stop", function() levels, toldAccount, sentOwn, sentAccount = {}, nil, nil, nil end)

local asking = false         -- true while we ask the game for the limit of another level

Core.Hooks.add("/Game/Interactive/mainComputer.mainComputer_C:GetPlayerOrderLimit", function(context, limit)
    if asking then return end
    local factor = Scale.orderLimitFactor()
    local computer = context:get()
    local debt = computer.PlayerEddieDebt
    local now = limit:get()
    -- The game's own sum for the account's level: it reads the level from the statistics
    -- manager, so the level is lent to it for the length of one call.
    local account = Scale.accountLevel()
    local stats = Core.find("statisticsManager_C")
    local own = stats and stats.playerLevel
    if account and type(own) == "number" and account > own then
        local out = {}
        asking = true
        local ok = pcall(function()
            stats.playerLevel = account
            computer:GetPlayerOrderLimit(out)
        end)
        pcall(function() stats.playerLevel = own end)
        asking = false
        if ok and type(out.Limit) == "number" then now = out.Limit end
    end
    local value = now + (factor - 1) * (now + debt)
    if not same(value, limit:get()) then limit:set(value) end
end)

return Scale
