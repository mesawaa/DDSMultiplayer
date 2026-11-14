-- Levels: the highest level a player can reach (MaxLevel in config.lua; 0, the default, is none).
--
-- The game itself has no highest level: statisticsManager.addExp adds one level whenever
-- the experience is past level x 1200 x (1 + level x 0.18), without end (its story's last
-- step even asks for level 36, and there are achievements for 36, 69 and 100). Nothing in
-- the game is a list with one entry per level: everything that reads the level compares it
-- with a threshold or multiplies it (Eddie's limit, clients), so levels above 30 need no
-- help. What is added here is the end: at MaxLevel the experience is put back to the
-- start of that level after every gain, so that the next level is never reached. Nothing
-- else is written: a game saved at the highest level and loaded without the mod simply
-- goes on levelling.
--
-- Levels are each player's own (they are not exchanged between games), so every game
-- holds its own player.

local Core = require("core")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_LEVELS_GEN") or 0) + 1
_G.DDSMP_LEVELS_GEN = GEN
local function live() return rawget(_G, "DDSMP_LEVELS_GEN") == GEN end

local Levels = { stats = { held = 0, undone = 0 } }

local STATS = "/Game/Interactive/statisticsManager.statisticsManager_C"
local INVENTORY = "/Game/Player/inventoryScreen.inventoryScreen_C"

-- The highest level, or nil when there is none (MaxLevel = 0).
function Levels.max()
    local n = tonumber(Core.config.MaxLevel)
    if n == nil then n = 0 end
    n = math.floor(n)
    return n > 0 and n or nil
end

-- Experience at which `level` begins.
local function begins(s, level)
    return level * s.levelExpFirstLevel * (1 + level * s.levelExpRaiseRatio)
end
Levels.begins = begins

local told = nil            -- the level the log line was written for
local last = nil            -- { address, level }: the level when last looked at

-- Keeps a player at the highest level there. `gained` is true right after the game has
-- added experience: only then can a level have been gained by it.
local function hold(s, gained)
    local max = Levels.max()
    if not max then return false end
    local level = tonumber(s.playerLevel)
    if not level then return false end
    local address = s:GetAddress()
    local before = last and last.address == address and last.level or nil
    if gained and before == max and level == max + 1 then
        -- One gain larger than a whole level (the game adds one level per gain): that
        -- level is taken back with the skill points it brought.
        local points = tonumber(s.playerSkillPointsPerLevel) or 0
        if (tonumber(s.skillLevelQuickLearner) or 0) >= 50 then points = points + 2 end
        s.playerLevel = max
        s.playerSkillPoints = math.max(0, (tonumber(s.playerSkillPoints) or 0) - points)
        level = max
        Levels.stats.undone = Levels.stats.undone + 1
        log("Levels: a level above %d was taken back", max)
    end
    last = { address = address, level = level }
    if level < max then return false end
    local floor = begins(s, level)
    if s.playerExp > floor then
        s.playerExp = floor
        Levels.stats.held = Levels.stats.held + 1
        if told ~= level then
            told = level
            log("Levels: level %d is the highest (MaxLevel = %d): experience no longer adds up", level, max)
        end
    end
    return true
end

function Levels.hold()
    local s = Core.find("statisticsManager_C")
    if not s then return false end
    local ok, held = pcall(hold, s, false)
    return ok and held
end

-- Right after every gain (the callback comes when the game's function has returned) ...
Core.Hooks.add(STATS .. ":addExp", function(ctx)
    if not live() then return end
    pcall(function()
        local s = ctx:get()
        if valid(s) then hold(s, true) end
    end)
end)
-- ... and now and then, for experience that was written and not gained (a loaded game).
Core.every(1, function()
    if not live() or not Core.player() then return end
    Levels.hold()
end)

-- The inventory's level line: at the highest level there is no next one.
Core.Hooks.add(INVENTORY .. ":updateStatistics", function(ctx)
    if not live() then return end
    pcall(function()
        local max = Levels.max()
        local w = ctx:get()
        if not max or not valid(w) or not valid(w.statManagerRef) then return end
        if (tonumber(w.statManagerRef.playerLevel) or 0) < max then return end
        w.txtStatsNextLevel:SetText(FText("MAX"))
        w.progExpLevel:SetPercent(1)
    end)
end)

return Levels
