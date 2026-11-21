-- What the story sets up in the world, with one storyline for everybody (Sync.Story off).
--
-- A story step is run by one game's quest manager (the game whose player took the call,
-- reached the level, finished the step before). The task it adds is in the shared task
-- table, but what it sets up in the world is done in that game alone, usually far from
-- every player, where coop/sync.lua does not look: Eddie's furniture call gives the
-- trigger in the furniture shop the number of the new task and unlocks the shop's door,
-- and in the other games the door stayed shut and walking in completed nothing.
--
-- So the few things of the world the quest manager works on are looked at on a timer,
-- wherever they are, and what changed in their saved variables goes to the other games
-- (Sync.watchObject: the same as for things next to a player). Two of them need more
-- than their variables:
--   * the furniture shop's trigger: a game that hears its task number does what the
--     story's own game did (`prepare`: the number, and the door of the shop);
--   * once that task is closed, by whoever walked in first, the trigger in every other
--     game forgets it: walking in there would complete a closed task a second time.
--
-- Only with one storyline: with separate storylines these things are each player's own.

local Core = require("core")
local Repl = require("coop.repl")
local World = require("coop.world")
local Sync = require("coop.sync")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local GEN = (rawget(_G, "DDSMP_STORYWORLD_GEN") or 0) + 1
_G.DDSMP_STORYWORLD_GEN = GEN
local function live() return rawget(_G, "DDSMP_STORYWORLD_GEN") == GEN end

local StoryWorld = { stats = { looked = 0, sent = 0, prepared = 0, disarmed = 0 } }

local FURNITURE = "/Game/WorldControlers/furnitureShopEnterTrigger.furnitureShopEnterTrigger_C"
-- The things of the world the quest manager looks up and changes (read from its Blueprint);
-- the managers among them are shared by coop/sync.lua already.
local CLASSES = {
    FURNITURE,
    "/Game/StaticMeshes/BuildingsModular/gasStationDoorBP.gasStationDoorBP_C",
    "/Game/WorldControlers/wallCheckpoint.wallCheckpoint_C",
    "/Game/Interactive/SectorHidoutUnlocker.SectorHidoutUnlocker_C",
    "/Game/Interactive/Doors/Special/launderDoor.launderDoor_C",
    "/Game/Interactive/Teleports/passageTrader.passageTrader_C",
    "/Game/PoliceBlockades/PoliceBlockadeArea.PoliceBlockadeArea_C",
    "/Game/Skeletal/NPC/SectantDoorOpener.SectantDoorOpener_C",
    "/Game/Interactive/EndgameQuestClasses/DeathSiteVolume.DeathSiteVolume_C",
    "/Game/Interactive/CursedSpotFixer.CursedSpotFixer_C",
    "/Game/Interactive/LookAtTriggers/deadDropSeeItLookTrigger.deadDropSeeItLookTrigger_C",
    "/Game/PsychedelicGang/weedDialogueFirstDone.weedDialogueFirstDone_C",
    "/Game/Villas/VillaPropertyInstance.VillaPropertyInstance_C",
}
StoryWorld.CLASSES = CLASSES

local STEP = 0.4             -- seconds between two classes: the whole list about every 5 s
local at = 0                 -- which class is next
local prepared = {}          -- trigger address -> the task number it was prepared for here

local function oneStoryline()
    local Story = package.loaded["coop.story"]
    return World.shared() and type(Story) == "table" and Story.oneStoryline ~= nil and Story.oneStoryline() == true
end

-- (a number past the end of the table is a task this game has not heard of yet: reading
-- there gives anything)
local function taskClosed(q, id)
    local ok, v = pcall(function()
        if id < 0 or id >= q.taskCompleted:GetArrayNum() or id >= q.taskFailed:GetArrayNum() then return false end
        return q.taskCompleted[id + 1] == true or q.taskFailed[id + 1] == true
    end)
    return ok and v == true
end

-- The furniture shop's trigger: armed as the story's own game armed it, and disarmed
-- once its task is closed.
local function tendFurniture(trigger)
    local id = tonumber(trigger.taskID) or 0
    local address = trigger:GetAddress()
    if id == 0 then
        prepared[address] = nil
        return
    end
    local q = Repl.singleton("questManager_C")
    if not q then return end
    if taskClosed(q, id) then
        trigger.taskID = 0
        prepared[address] = nil
        StoryWorld.stats.disarmed = StoryWorld.stats.disarmed + 1
        log("StoryWorld: the furniture shop's task %d is closed; its trigger here forgets it", id)
        return
    end
    if prepared[address] ~= id then
        prepared[address] = id
        local ok, e = pcall(function() trigger:prepare(id) end)
        StoryWorld.stats.prepared = StoryWorld.stats.prepared + 1
        log("StoryWorld: the furniture shop is set up for task %d here%s", id, ok and "" or (": " .. tostring(e)))
    end
end

local function look(path)
    local list = Core.actors(path)
    if not list then return end
    for _, a in ipairs(list) do
        if Core.alive(a) then
            StoryWorld.stats.looked = StoryWorld.stats.looked + 1
            if path == FURNITURE then
                local ok, e = pcall(tendFurniture, a)
                if not ok then vlog("StoryWorld: %s", tostring(e)) end
            end
            local n = Sync.watchObject(a)
            if n > 0 then
                StoryWorld.stats.sent = StoryWorld.stats.sent + n
                vlog("StoryWorld: %d variable(s) of a %s sent", n, path:match("[^.]+$"))
            end
        end
    end
end

Core.every(STEP, function()
    if not live() or not Core.enabled("Objects") or not oneStoryline() then return end
    at = at % #CLASSES + 1
    local ok, e = pcall(look, CLASSES[at])
    if not ok and not StoryWorld.failed then
        StoryWorld.failed = true
        log("StoryWorld: %s", tostring(e))
    end
end)

---------------------------------------------------------------- the same step twice

-- A step of the story is in the task table once. Two games can still add it within a
-- moment of each other (a call's task is kept to one game by coop/calls.lua; a step that
-- follows from something both games watch is not, and a game of an older version claims
-- nothing). The host looks at the open steps whenever the table has grown: of two open
-- rows that are the same step the later one is closed, quietly (no XP, nothing follows
-- from it), its marker goes, and whatever points at it (the quest manager's own task
-- numbers, the furniture shop's trigger) points at the first one instead.
local TASK_NUMBERS = { "FirstVillaTaskID", "NewLaunderTaskID", "SectSearchTaskID", "SectorUnlockTaskID", "apartmentModeTaskID", "bankTaskID",
    "drugStoreTaskID", "findSampleClientsTaskID", "firstDeadDropTaskID", "firstDopeOrderTaskID", "firstOwnOrderTaskID", "firstShadyCommTaskID",
    "firstShoppingTaskID", "furnitureModeTaskID", "furtherNorthTaskID", "jayShopTaskID", "keyFinderTaskID", "longAreas01TaskID", "longAreas02TaskID",
    "longAreas03TaskID", "longDominationTaskID", "longFirstDealerTaskID", "longGainClientsTaskID", "longGainGangRepTaskID", "longGangsTaskID",
    "longNewDrugsTaskID", "markTerritoryTaskID", "meetGangTaskID", "rentHideoutTaskID", "rentingTaskID", "sectorBTaskID", "sectorBTaskID2" }
local POINT_FOR = 120        -- seconds the pointers are looked at after a row was closed
local merged = {}            -- closed row -> { keep = the first row, at = os.clock() }
local rowsSeen = nil         -- the table's length when it was last looked through
StoryWorld.stats.merged = 0

local function repoint(q)
    local now = os.clock()
    for dup, m in pairs(merged) do
        if now - m.at > POINT_FOR then
            merged[dup] = nil
        else
            for _, name in ipairs(TASK_NUMBERS) do
                pcall(function() if q[name] == dup then q[name] = m.keep end end)
            end
            for _, tr in ipairs(Core.actors(FURNITURE) or {}) do
                pcall(function() if Core.alive(tr) and tr.taskID == dup then tr.taskID = m.keep end end)
            end
        end
    end
end

local function mergeSteps(q, Story)
    local n = q.taskNames:GetArrayNum()
    if n == rowsSeen then return end
    local first = rowsSeen == nil
    rowsSeen = n
    -- (the table as a world was loaded is left as it is: only what comes while we watch)
    if first then return end
    local open = {}
    for id = 0, n - 1 do
        local sale = true
        pcall(function() sale = q.taskIsSale[id + 1] == true end)
        if not sale and not taskClosed(q, id) then
            local key = Story.stepKey(q, id)
            if key then
                if open[key] == nil then
                    open[key] = id
                else
                    local keep = open[key]
                    q.taskCompleted[id + 1] = true
                    merged[id] = { keep = keep, at = os.clock() }
                    StoryWorld.stats.merged = StoryWorld.stats.merged + 1
                    pcall(Story.removeMarkers, { [id] = true })
                    log("StoryWorld: task %d is the step of task %d again (%s): closed, the first one counts", id, keep, key)
                end
            end
        end
    end
    if next(merged) then pcall(Story.refreshTaskViews) end
end

Core.every(2, function()
    if not live() or World.role ~= "host" or not oneStoryline() then return end
    local Story = package.loaded["coop.story"]
    local q = Repl.singleton("questManager_C")
    if not q or type(Story) ~= "table" or not Story.stepKey then return end
    local ok, e = pcall(mergeSteps, q, Story)
    if not ok then vlog("StoryWorld: %s", tostring(e)) end
    if next(merged) then pcall(repoint, q) end
end)

-- A task's marker on the map and the compass is taken off by the game that completes the
-- task; in the other games it stayed. Every game takes off the markers of closed tasks.
Core.every(5, function()
    if not live() or not oneStoryline() then return end
    local Story = package.loaded["coop.story"]
    local q = Repl.singleton("questManager_C")
    if not q or type(Story) ~= "table" or not Story.taskMarkers then return end
    pcall(function()
        local gone = nil
        for _, marker in ipairs(Story.taskMarkers()) do
            if Core.alive(marker) and marker.taskRelated == true then
                local id = marker.relatedTaskID
                if type(id) == "number" and id >= 0 and taskClosed(q, id) then
                    gone = gone or {}
                    gone[id] = true
                end
            end
        end
        if gone then
            Story.removeMarkers(gone)
            Story.refreshTaskViews()
            local ids = {}
            for id in pairs(gone) do ids[#ids + 1] = id end
            table.sort(ids)
            vlog("StoryWorld: marker(s) of closed task(s) %s taken off", table.concat(ids, ","))
        end
    end)
end)

local function reset() prepared, at, merged, rowsSeen = {}, 0, {}, nil end
World.listen("start", function() if live() then reset() end end)
World.listen("stop", function() if live() then reset() end end)

function StoryWorld.state() return { prepared = prepared, at = at, merged = merged, rowsSeen = rowsSeen } end

return StoryWorld
