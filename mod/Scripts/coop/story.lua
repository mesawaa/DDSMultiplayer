-- Every player has their own storyline in a shared world.
--
-- The business is shared (orders, clients, areas, gangs, money: coop/sync.lua). The story
-- that runs on top of it (Eddie's calls, the tutorials, the long-term goals) is kept per
-- player:
--
--   * Story state (which calls and steps a player has been through) never leaves that
--     player's game. The host's lives in the host's save as always. A guest's is stored in
--     a file on the guest's computer, one per host, and put back on the next visit.
--   * The same goes for what the story looks at: a player's level, experience and skills,
--     their exposure and reputation, and their dealings with a gang. Which gang approaches
--     a player is decided by that player's own exposure and reputation.
--   * A guest who is new to a world starts the story from the beginning: go and meet Eddie.
--   * The task table itself stays shared, because orders and many objects in the world
--     refer to tasks by number. A story task belongs to the player whose story created it;
--     the other games keep it out of their task list.
--   * You do the story's steps yourself. The exception is a step about the state of the
--     shared world that somebody has already brought about (territory that is already
--     unlocked and the like): it cannot be done twice, so it completes for you as soon as
--     your story asks for it. What the opening steps need (Eddie on his bench, the first
--     package in its dead drop) is put back for a player who still has to do them.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")
local Sync = require("coop.sync")
local json = require("json")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Story = {
    own = {},        -- task id -> { key, waited, eventAt, rec } story tasks of this player that are still open
    foreign = {},    -- task id -> true: story tasks of other players, kept out of the local task list
    keys = {},       -- task id -> description key, where known
    worldDone = {},  -- description key -> true: this step has been done in this world by somebody
    stats = { created = 0, caughtUp = 0, hidden = 0, recreated = 0, restored = 0 },
}

local QM = "questManager_C"
local QM_PATH = "/Game/WorldControlers/questManager.questManager_C"
local QUEST_TABLE = "/Game/StringTables/strTable_questTasks.strTable_questTasks"
local MARKER = "worldMapMarker_C"
-- The map markers of the world (the engine's own list of them: searching by name takes
-- forty milliseconds).
local function markers()
    return Core.actors("/Game/GUI/WorldMap/worldMapMarker.worldMapMarker_C") or FindAllOf(MARKER) or {}
end

-- Other managers whose personal variables belong to a player's story.
local COMPANIONS = {
    { class = "statisticsManager_C", cdo = "/Game/Interactive/statisticsManager.Default__statisticsManager_C", skip = { firstlaunch = true } },
    { class = "gangManager_C", cdo = "/Game/WorldControlers/Gangs/gangManager.Default__gangManager_C", skip = {} },
}
local TABLE_ARRAYS = { "taskNames", "taskDecriptions", "taskExpRewards", "taskCompleted", "taskFailed", "taskIsSale",
    "taskDisplayed", "taskSpecial", "taskCompletesQuest", "taskStringActions" }
local ELEMENT_DEFAULT = { taskNames = '""', taskDecriptions = '""', taskExpRewards = "0", taskCompleted = "False", taskFailed = "False",
    taskIsSale = "False", taskDisplayed = "False", taskSpecial = "False", taskCompletesQuest = "-1", taskStringActions = '""' }
local FIRST_DAY = "TAKS-FIRST-DAY-DESC"
local FIRST_PACK = "TASK-FIRST-PACK-DESC"
-- The dead drop that holds the first package in an untouched world.
local FIRST_DROP = { class = "dd_wallVentSmall_C", x = 3580, y = -2220, z = 175 }
-- Where the first meeting takes place in an untouched world (read from a new game).
local EDDIE_CLASS = "/Game/Skeletal/NPC/Eddie/eddieFirstDialogue.eddieFirstDialogue_C"
local BENCH = { c = "/Game/Interactive/sitDownPlace.sitDownPlace_C", x = 2310, y = 6650, z = 180, yw = 90 }
local EDDIE = { c = EDDIE_CLASS, x = 2489.99, y = 6684.92, z = 193.198, yw = 90 }
-- A guest's story tasks end their description with two no-break spaces (invisible). The
-- mark is stored with the task, so the host's save still tells them apart from the
-- host's own tasks after a restart.
local TAG = "\194\160\194\160"

-- The story's own tasks, by the string-table key of their description.
--   world  = about the state of the shared world (unlocked territory, standing with a
--            gang, sector C); once somebody has brought it about it completes for everyone
--   event  = the quest manager event the game itself runs when the step is done
-- Everything else is done by each player in person.
local TASKS = {
    [FIRST_DAY] = {},
    ["TASK-FIRST-PACK-DESC"] = { event = "retrievedFirstPackage" },
    ["TASK-FIRST-CLIENTS-DESC"] = {},
    ["TASK-MERCHANDISE-DESC"] = {},
    ["TASK-GAS-STATION-DESC"] = {},
    ["TASK-CARTEL-REFUND-DESC"] = {},
    ["TASK-BANK-DESC"] = { event = "atmActivated" },
    ["TASK-WORK-STATION-DESC"] = {},
    ["TASK-GROWING-FIRST-AREAS"] = { world = true },
    ["TASK-GROWING-SPRAY-DESC"] = {},
    ["TASK-GROWING-SAMPLE-DESC"] = { event = "gaveAwayFreeSample" },
    ["TASK-GROWING-AREAS-01"] = { world = true },
    ["TASK-GROWING-AREAS-02"] = { world = true },
    ["TASK-GROWING-AREAS-03"] = { world = true },
    ["TASK-HIDEOUTS-DESC"] = { event = "apartmentViewerLaunch" },
    ["TASK-RENT-DESC"] = { event = "rentedFirstApartment" },
    ["TASK-FURNITURE-DESC"] = {},
    ["TASK-FURNITURE-MODE-DESC"] = {},
    ["TASK-KEYS-DESC"] = {},
    ["TASK-DRUGSTORE-DESC"] = {},
    ["TASK-JAY-DESC"] = {},
    ["TASK-READ-LAUNDER-DESC"] = {},
    ["TASK-FIRST-DEALER-DESC"] = {},
    ["TASK-CHEMIST-DESC"] = {},
    ["TASK-THEWALL-ROUT-01-DESC"] = { world = true },
    ["TASK-THEWALL-ROUT-02-DESC"] = { world = true },
    ["TASK-FURTHER-NORTH-DESC"] = { world = true },
    ["TASK-GOINGBIG-KEIJI-DESC"] = {},
    ["TASK-GOINGBIG-BALLENA-DESC"] = {},
    ["TASK-GOINGBIG-WORKWAY-DESC"] = { world = true },
    ["TASK-GOINGBIG-REPUTATION-DESC"] = { world = true },
    ["TASK-DOMINATION-DESC"] = { world = true },
    ["TASK-SECTOR-HIDEOUT-DESC"] = { world = true },
    ["TASK-SECTOR-FACTORY-DESC"] = { world = true },
    ["TASK-SECTOR-LAUNDRY-DESC"] = { world = true },
    ["TASK-ENDGAME-SEARCH-SECT-DESC"] = { world = true, event = "SectSearchTaskComplete" },
    ["TASK-ENDGAME-GREENE1-DESC"] = { world = true },
    ["TASK-ENDGAME-VILLA1-DESC"] = { world = true },
    ["TASK-ENDGAME-VILLA2-DESC"] = { world = true },
    ["TASK-ENDGAME-VILLA3-DESC"] = { world = true },
    ["TASK-PAYDAY-DEPOSIT-DESC"] = {},   -- a gang's payday: each player has their own gang
}

local installAt = nil
local askAt = nil
local applying = false     -- true while this module changes the quest manager itself
local wire = {}            -- foreign task id -> its completion as the rest of the world sees it
local ready = false        -- a guest's own story has been put in place for this world
local startedFresh = false
local meetingTried = false       -- false, or the number of times the first meeting was set up
local packageTried = false
local profileText = nil    -- last profile written (JSON)
local profileHost = nil
local pendingInfo = nil

local function enabled()
    return Core.enabled("Story") and Core.enabled("Orders")
end

local function active()
    return World.active and enabled()
end

local function manager()
    return Repl.singleton(QM)
end

local function length(q)
    local ok, n = pcall(function() return q.taskNames:GetArrayNum() end)
    return ok and n or 0
end

local function closed(q, id)
    local ok, v = pcall(function() return q.taskCompleted[id + 1] == true or q.taskFailed[id + 1] == true end)
    return ok and v == true
end

local function send(messageType, data, except)
    for _, id in ipairs(World.targets()) do
        if id ~= except then Repl.send(messageType, data, id) end
    end
end

local function pushSoon()
    Core.after(0.05, function() Sync.pushNow(QM) end)
end

---------------------------------------------------------------- which task is which

local textToKey = nil

local function buildKeys()
    textToKey = {}
    local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    local src = StaticFindObject("/Script/Engine.Default__KismetStringTableLibrary")
    local tableId = FName(QUEST_TABLE)
    local found = 0
    for key in pairs(TASKS) do
        local text = nil
        if valid(lib) then pcall(function() text = lib:TextFromStringTable(tableId, key):ToString() end) end
        if (not text or text == "") and valid(src) then
            pcall(function() text = src:GetTableEntrySourceString(tableId, key):ToString() end)
        end
        if text and text ~= "" and not text:find("<MISSING", 1, true) then
            textToKey[text] = key
            found = found + 1
        end
    end
    vlog("Story: %d task descriptions resolved", found)
    return found
end

local function rowText(q, id)
    local text = nil
    pcall(function() text = q.taskDecriptions[id + 1]:ToString() end)
    return text
end

local function isTagged(q, id)
    local text = rowText(q, id)
    return text ~= nil and text:sub(-#TAG) == TAG
end

-- The description key of the task as it stands in the table right now.
local function readKey(q, id)
    if not textToKey or next(textToKey) == nil then buildKeys() end
    local text = rowText(q, id)
    if not text then return nil end
    if text:sub(-#TAG) == TAG then text = text:sub(1, -#TAG - 1) end
    return textToKey[text]
end

local function keyOf(q, id)
    local key = Story.keys[id]
    if key then return key end
    key = readKey(q, id)
    if key then Story.keys[id] = key end
    return key
end

---------------------------------------------------------------- other players' story tasks

local function pick(values, lowerName)
    for name in pairs(values) do
        if type(name) == "string" and name:lower() == lowerName then return name end
    end
    return nil
end

-- A foreign story task reads "completed" in this game, which keeps it out of the task
-- list and makes anything here that would complete it a no-op. What travels between the
-- games is its real state.
Sync.transform[QM] = {
    out = function(values)
        if next(wire) == nil then return end
        local name = pick(values, "taskcompleted")
        if not name then return end
        local e = Repl.splitArray(values[name])
        for id, v in pairs(wire) do
            if e[id + 1] then e[id + 1] = v and "True" or "False" end
        end
        values[name] = Repl.joinArray(e)
    end,
    inc = function(values)
        if next(wire) == nil then return end
        local name = pick(values, "taskcompleted")
        if not name then return end
        local e = Repl.splitArray(values[name])
        for id in pairs(wire) do
            if e[id + 1] then
                wire[id] = e[id + 1] == "True"
                e[id + 1] = "True"
            end
        end
        values[name] = Repl.joinArray(e)
    end,
}

local function refreshTaskViews()
    local player = World.player()
    if not player then return end
    pcall(function() if valid(player.InventoryWidget) then player.InventoryWidget:renderTasklist() end end)
    pcall(function() player.HUD:updateMiniTaskList() end)
    pcall(function() player.HUD:refreshCompass() end)
end

local function removeMarkers(ids)
    for _, marker in ipairs(markers()) do
        pcall(function()
            if Core.alive(marker) and marker.taskRelated == true then
                local id = marker.relatedTaskID
                if type(id) == "number" and ids[id] then marker:K2_DestroyActor() end
            end
        end)
    end
end

-- Makes sure every foreign task that exists here reads completed.
local function applyHidden(q)
    local pending = {}
    for id in pairs(Story.foreign) do
        local ok, v = pcall(function() return q.taskCompleted[id + 1] end)
        if ok and v == false then pending[id] = true end
    end
    if next(pending) == nil then return end
    local text = Repl.export(q, { "taskCompleted" }).taskCompleted
    if not text then return end
    local e = Repl.splitArray(text)
    for id in pairs(pending) do
        if e[id + 1] then e[id + 1] = "True" end
    end
    applying = true
    Repl.import(q, { taskCompleted = Repl.joinArray(e) })
    applying = false
    removeMarkers(pending)
    refreshTaskViews()
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    Story.stats.hidden = Story.stats.hidden + n
    vlog("Story: %d task(s) of another player's story kept out of the task list", n)
end

local function addForeign(id, key)
    id = tonumber(id)
    if not id or id < 0 or Story.own[id] then return end
    if key then Story.keys[id] = tostring(key) end
    if not Story.foreign[id] then
        Story.foreign[id] = true
        if wire[id] == nil then wire[id] = false end
    end
end

---------------------------------------------------------------- own story tasks

local function announceOwn(ids)
    local a, k = {}, {}
    for _, id in ipairs(ids) do
        a[#a + 1], k[#k + 1] = id, Story.own[id] and Story.own[id].key or ""
    end
    if #a > 0 then send("sown", { a = a, k = k }) end
end

-- The table row of a task, as element texts.
local function readRow(q, id, split)
    local row = {}
    for _, name in ipairs(TABLE_ARRAYS) do
        local e = split and split[name] or Repl.splitArray(Repl.export(q, { name })[name] or "()")
        row[name] = e[id + 1]
    end
    return row
end

local function splitTable(q)
    local out = {}
    local texts = Repl.export(q, TABLE_ARRAYS)
    for _, name in ipairs(TABLE_ARRAYS) do out[name] = Repl.splitArray(texts[name] or "()") end
    return out
end

local function markerOf(id)
    local found = nil
    for _, marker in ipairs(markers()) do
        pcall(function()
            if not found and Core.alive(marker) and marker.taskRelated == true and marker.relatedTaskID == id then
                local loc = marker:K2_GetActorLocation()
                local names = Repl.savedVars(marker)
                found = { x = loc.X, y = loc.Y, z = loc.Z, v = Repl.export(marker, names) }
            end
        end)
    end
    return found
end

local function spawnMarker(q, id, m)
    if type(m) ~= "table" or not m.x then return end
    local player = World.player()
    local class = StaticFindObject("/Game/GUI/WorldMap/worldMapMarker.worldMapMarker_C")
    if not player or not valid(class) then return end
    pcall(function()
        local marker = player:GetWorld():SpawnActor(class, { X = m.x, Y = m.y, Z = m.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(marker) then return end
        if type(m.v) == "table" and next(m.v) ~= nil then
            Repl.import(marker, m.v)
            pcall(function() marker:RamaLoaded() end)
        end
        marker.relatedTaskID = id
    end)
end

-- Puts own story tasks (back) into the table as new rows. `list` holds
-- { old = id, key, row, waited, marker }. Returns old id -> new id.
local function appendTasks(q, list)
    if #list == 0 then return {} end
    local split = splitTable(q)
    local n = #split.taskNames
    local map = {}
    for _, t in ipairs(list) do
        for _, name in ipairs(TABLE_ARRAYS) do
            local value = t.row and t.row[name] or nil
            if name == "taskCompleted" or name == "taskFailed" then value = "False" end
            split[name][n + 1] = value or ELEMENT_DEFAULT[name]
        end
        map[t.old] = n
        n = n + 1
    end
    local values = {}
    for _, name in ipairs(TABLE_ARRAYS) do values[name] = Repl.joinArray(split[name]) end
    applying = true
    Repl.import(q, values)
    -- The story's own references to these tasks follow them.
    local names = {}
    for _, name in ipairs(Repl.savedVars(q)) do
        local lower = name:lower()
        if not Sync.questShared(name) and (lower:find("taskid", 1, true) or lower:find("questid", 1, true)) then
            names[#names + 1] = name
        end
    end
    local moved = {}
    for name, text in pairs(Repl.export(q, names)) do
        local new = map[tonumber(text) or -1]
        if new and tonumber(text) > 0 then moved[name] = tostring(new) end
    end
    if next(moved) ~= nil then Repl.import(q, moved) end
    applying = false
    for _, t in ipairs(list) do
        local id = map[t.old]
        Story.own[id] = { key = t.key, waited = t.waited or 0, row = t.row, marker = t.marker }
        Story.keys[id] = t.key
        spawnMarker(q, id, t.marker)
    end
    Story.stats.recreated = Story.stats.recreated + #list
    return map
end

local function tagRow(q, id)
    local e = Repl.splitArray(Repl.export(q, { "taskDecriptions" }).taskDecriptions or "()")
    local text = e[id + 1]
    if not text or text:sub(-1) ~= '"' or text:sub(-#TAG - 1, -2) == TAG then return end
    e[id + 1] = text:sub(1, -2) .. TAG .. '"'
    applying = true
    Repl.import(q, { taskDecriptions = Repl.joinArray(e) })
    applying = false
end

Core.Hooks.add(QM_PATH .. ":createNewTask", function(ctx)
    if applying or not active() then return end
    local q = ctx:get()
    if not valid(q) then return end
    local id = length(q) - 1
    if id < 0 then return end
    local key = readKey(q, id)
    if key then
        if World.role == "guest" then tagRow(q, id) end
        Story.keys[id] = key
        Story.own[id] = { key = key, waited = 0 }
        Story.stats.created = Story.stats.created + 1
        vlog("Story: own task %d (%s)", id, key)
        if World.shared() then announceOwn({ id }) end
    end
    -- Sent at once: a task added by the other game in the meantime would take the same number.
    if World.shared() then pushSoon() end
end)

Core.Hooks.add(QM_PATH .. ":markTaskStatus", function(ctx, idParam, statusParam)
    if applying or not active() then return end
    local id, status = idParam:get(), statusParam:get()
    local q = ctx:get()
    if status ~= 1 or not valid(q) then return end
    local rec = Story.own[id]
    if rec and closed(q, id) then
        Story.own[id] = nil
        Story.worldDone[rec.key] = true
        send("sdone", { k = rec.key })
        vlog("Story: own task %d (%s) done", id, rec.key)
    end
    if World.shared() then pushSoon() end
end)

-- The game completes the first task by its fixed number (0) when the talk with Eddie
-- ends. A guest's copy of that task has another number.
Core.Hooks.add(QM_PATH .. ":firstMetEddie", function(ctx)
    if applying or not active() then return end
    local q = ctx:get()
    if not valid(q) then return end
    for id, rec in pairs(Story.own) do
        if rec.key == FIRST_DAY and id ~= 0 and not closed(q, id) then
            pcall(function() q:markTaskStatus(id, 1) end)
        end
    end
end)

---------------------------------------------------------------- messages

local function trusted(sender)
    if not active() then return false end
    if World.role == "host" then return World.inWorld[sender] == true end
    return sender == Net.S.owner
end

Net.on("sown", function(sender, data)
    if not trusted(sender) or type(data.a) ~= "table" then return end
    for i, id in ipairs(data.a) do
        local key = type(data.k) == "table" and data.k[i] or nil
        addForeign(id, key ~= "" and key or nil)
    end
    local q = manager()
    if q then applyHidden(q) end
    if World.role == "host" then send("sown", data, sender) end
end)

Net.on("sdone", function(sender, data)
    if not trusted(sender) or type(data.k) ~= "string" then return end
    Story.worldDone[data.k] = true
    if World.role == "host" then send("sdone", data, sender) end
end)

---------------------------------------------------------------- meeting Eddie

local function firstMeetingSeat()
    for _, seat in ipairs(Core.actors("/Game/Interactive/sitDownPlace.sitDownPlace_C") or FindAllOf("sitDownPlace_C") or {}) do
        local ok, isIt = pcall(function()
            return Core.alive(seat) and seat.pawnClass:GetFullName():find("eddieFirstDialogue", 1, true) ~= nil
        end)
        if ok and isIt then return seat end
    end
    return nil
end

local function firstMeetingEddie()
    for _, eddie in ipairs(Core.actors("/Game/Skeletal/NPC/Eddie/eddieFirstDialogue.eddieFirstDialogue_C") or FindAllOf("eddieFirstDialogue_C") or {}) do
        if Core.alive(eddie) then return eddie end
    end
    return nil
end

local function loadClass(path)
    local class = StaticFindObject(path)
    if valid(class) then return class end
    pcall(function() LoadAsset((path:gsub("_C$", ""))) end)
    class = StaticFindObject(path)
    return valid(class) and class or nil
end

local function spawnAt(c)
    local player = World.player()
    local class = loadClass(c.c)
    if not player or not class then return nil end
    local actor = player:GetWorld():SpawnActor(class, { X = c.x, Y = c.y, Z = c.z }, { Pitch = 0, Yaw = c.yw or 0, Roll = 0 })
    return valid(actor) and actor or nil
end

-- A world that is past the first meeting no longer has the bench Eddie waits on. A
-- player whose own story still has to meet him gets both back, in their own game only.
local meetingAt = nil
local function ensureMeeting(q)
    local wanted = false
    for _, rec in pairs(Story.own) do
        if rec.key == FIRST_DAY then wanted = true end
    end
    if not wanted or q.metEddie == true then return end
    -- Looked at again and again while the meeting is still to come: the bench or Eddie can
    -- go missing later (the other player's game takes its own away after their meeting).
    if os.clock() < (meetingAt or 0) then return end
    meetingAt = os.clock() + 6
    if firstMeetingSeat() and firstMeetingEddie() then return end
    meetingTried = (meetingTried or 0) + 1
    if meetingTried > 5 then return end
    local ok, e = pcall(function()
        local eddieClass = loadClass(EDDIE_CLASS)
        if not eddieClass then error("Eddie's class is not available") end
        if not firstMeetingSeat() then
            local seat = spawnAt(BENCH)
            if not seat then error("the bench could not be created") end
            seat.pawnClass = eddieClass
            if not firstMeetingSeat() then error("the bench did not take its setting") end
        end
        -- Eddie looks for his bench when he appears, so he comes second.
        if not firstMeetingEddie() and not spawnAt(EDDIE) then error("Eddie could not be created") end
    end)
    if ok then
        log("Story: Eddie is waiting for you at the first meeting place")
    else
        log("Story: could not set up the first meeting: %s", tostring(e))
    end
end

-- The first package: the game fills one particular dead drop while it is flagged as the
-- first one, and finishes the step when that drop has been emptied.
local function ensureFirstPackage(q)
    if packageTried then return end
    local wanted = false
    for _, rec in pairs(Story.own) do
        if rec.key == FIRST_PACK then wanted = true end
    end
    if not wanted then return end
    packageTried = true
    local drop = nil
    for _, d in ipairs(FindAllOf(FIRST_DROP.class) or {}) do
        pcall(function()
            if Core.alive(d) then
                local l = d:K2_GetActorLocation()
                if math.abs(l.X - FIRST_DROP.x) < 60 and math.abs(l.Y - FIRST_DROP.y) < 60 and math.abs(l.Z - FIRST_DROP.z) < 60 then drop = d end
            end
        end)
    end
    if not drop then
        log("Story: the dead drop for the first package was not found")
        return
    end
    if drop.firstDeadDrop == true then return end
    local ok, e = pcall(function()
        drop.firstDeadDrop = true
        drop:ExecuteUbergraph_dd_wallVentSmall(15)   -- the part of its start-up that puts the package in
    end)
    if ok then
        log("Story: the first package is waiting in its dead drop")
    else
        log("Story: could not place the first package: %s", tostring(e))
    end
end

---------------------------------------------------------------- catching up with the world

-- Seconds after which an open step that the world has already been through completes by
-- itself, or nil for never.
local function graceFor(q, rec)
    local info = TASKS[rec.key] or {}
    if info.world then return 4 end
    local minutes = tonumber(Core.config.StoryCatchUpMinutes) or 0
    if minutes > 0 then return minutes * 60 end
    return nil
end

local function catchUp(q, id, rec)
    local info = TASKS[rec.key] or {}
    if info.event and not rec.eventAt then
        rec.eventAt = os.clock()
        local ok, e = pcall(function() q[info.event](q) end)
        log("Story: \"%s\" was already done in this world, completing it (%s)", rec.key, ok and info.event or tostring(e))
    elseif not rec.eventAt or os.clock() - rec.eventAt >= 4 then
        rec.eventAt = os.clock()
        local ok, e = pcall(function() q:markTaskStatus(id, 1) end)
        if not info.event then log("Story: \"%s\" was already done in this world, completing it%s", rec.key, ok and "" or (": " .. tostring(e))) end
    end
    Story.stats.caughtUp = Story.stats.caughtUp + 1
end

local STEP = 2

local function watch(q)
    local lost = {}
    -- Completing a step can create the next one while we look, so walk a copy.
    local ids = {}
    for id in pairs(Story.own) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local rec = Story.own[id]
        if not rec then
            -- finished by an earlier step of this loop
        elseif id >= length(q) or readKey(q, id) ~= rec.key then
            -- The row was overwritten: both games added a task at the same moment.
            lost[#lost + 1] = { old = id, key = rec.key, row = rec.row, waited = rec.waited, marker = rec.marker }
        elseif closed(q, id) then
            Story.own[id] = nil
        else
            if not rec.row then rec.row = readRow(q, id) end
            -- a task's marker is looked for a few times, not for ever: some have none
            if rec.marker == nil then
                rec.markerTries = (rec.markerTries or 0) + 1
                rec.marker = markerOf(id)
                if rec.marker == nil and rec.markerTries >= 3 then rec.marker = false end
            end
            if Story.worldDone[rec.key] then
                local grace = graceFor(q, rec)
                if grace then
                    rec.waited = (rec.waited or 0) + STEP
                    if rec.waited >= grace then catchUp(q, id, rec) end
                end
            end
        end
    end
    if #lost > 0 then
        for _, t in ipairs(lost) do Story.own[t.old] = nil end
        local map = appendTasks(q, lost)
        local ids = {}
        for _, id in pairs(map) do ids[#ids + 1] = id end
        log("Story: %d own task(s) had been overwritten and were put back", #ids)
        announceOwn(ids)
        pushSoon()
    end
    -- A foreign task that its owner has finished needs no special treatment any more.
    for id in pairs(Story.foreign) do
        if wire[id] == true then
            Story.foreign[id], wire[id] = nil, nil
        end
    end
    applyHidden(q)
end

---------------------------------------------------------------- a guest's own story

local function personalNames(q)
    return Sync.personalNames(QM, q)
end

local function companionNames(m, obj)
    local out = {}
    for _, name in ipairs(Sync.personalNames(m.class, obj)) do
        if not m.skip[name:lower()] then out[#out + 1] = name end
    end
    return out
end

-- name -> text of a companion manager's personal variables: `from` is the live object or
-- nil for the values of a new game.
local function companionValues(m, obj, fresh)
    local source = obj
    if fresh then
        source = StaticFindObject(m.cdo)
        if not valid(source) then return nil end
    end
    return Repl.export(source, companionNames(m, obj))
end

-- A new game's story state is exactly the class defaults.
local function freshStory(q)
    local cdo = StaticFindObject("/Game/WorldControlers/questManager.Default__questManager_C")
    if not valid(cdo) then return nil end
    local vars = Repl.export(cdo, personalNames(q))
    if next(vars) == nil then return nil end
    return { vars = vars, extra = {} }
end

local function profilePath(host)
    local base = os.getenv("LOCALAPPDATA")
    local dir = base and (base:gsub("\\", "/") .. "/DrugDealerSimulator/Saved/SaveGames") or Core.MOD_DIR
    return string.format("%s/ddsmp_story_%s%s.json", dir, tostring(host):gsub("[^%w]", ""), Core.instance and ("_" .. Core.instance) or "")
end

local function buildProfile(q)
    local p = { v = 2, vars = Repl.export(q, personalNames(q)), tasks = {}, extra = {} }
    for _, m in ipairs(COMPANIONS) do
        local obj = Repl.singleton(m.class)
        if obj then p.extra[m.class] = companionValues(m, obj, false) end
    end
    for id, rec in pairs(Story.own) do
        p.tasks[#p.tasks + 1] = { i = id, k = rec.key, w = math.floor(rec.waited or 0), r = rec.row, m = rec.marker }
    end
    table.sort(p.tasks, function(a, b) return a.i < b.i end)
    return p
end

local function saveProfile(q, role)
    if (role or World.role) ~= "guest" or not ready or not profileHost then return end
    if q then
        local ok, text = pcall(function() return json.encode(buildProfile(q)) end)
        if not ok then
            log("Story: could not store the story (%s)", tostring(text))
            return
        end
        if text == profileText then return end
        profileText = text
    end
    if not profileText then return end
    local path = profilePath(profileHost)
    local f = io.open(path .. ".tmp", "wb")
    if not f then
        log("Story: cannot write %s", path)
        return
    end
    f:write(profileText)
    f:close()
    os.remove(path)
    os.rename(path .. ".tmp", path)
end

local function loadProfile(host)
    local f = io.open(profilePath(host), "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    local ok, p = pcall(json.decode, text)
    if ok and type(p) == "table" and type(p.vars) == "table" then return p end
    log("Story: the stored story for this host cannot be read, starting over")
    return nil
end

-- Replaces the story state loaded from the host's save with this player's own.
local function install(q, info)
    profileHost = Net.S.owner
    local p = loadProfile(profileHost)
    startedFresh = p == nil
    local source = p or freshStory(q)
    if not source then
        log("Story: the untouched story state is not available; keeping the host's story state")
        ready = true
        return
    end
    -- The host's story tasks and what this world has already been through.
    for i, id in ipairs(info.st or {}) do addForeign(id, type(info.sk) == "table" and info.sk[i] or nil) end
    for _, key in ipairs(info.dn or {}) do Story.worldDone[tostring(key)] = true end

    local vars = {}
    for name, text in pairs(source.vars) do
        if type(name) == "string" and type(text) == "string" and not Sync.questShared(name) then vars[name] = text end
    end
    applying = true
    Repl.import(q, vars)
    applying = false
    -- Level, skills, exposure, reputation and gang dealings: this player's own, or those
    -- of a new game on a first visit.
    for _, m in ipairs(COMPANIONS) do
        local obj = Repl.singleton(m.class)
        if obj then
            local stored = type(source.extra) == "table" and source.extra[m.class] or nil
            local values = type(stored) == "table" and stored or companionValues(m, obj, true)
            if values then
                local allowed, filtered = {}, {}
                for _, name in ipairs(companionNames(m, obj)) do allowed[name] = true end
                for name, text in pairs(values) do
                    if allowed[name] and type(text) == "string" then filtered[name] = text end
                end
                Repl.import(obj, filtered)
            else
                log("Story: the new-game values of %s are not available; keeping the host's", m.class)
            end
        end
    end

    local missing = {}
    if p and type(p.tasks) == "table" then
        local n = length(q)
        for _, t in ipairs(p.tasks) do
            local id = tonumber(t.i)
            if id and type(t.k) == "string" then
                if id < n and readKey(q, id) == t.k and isTagged(q, id) and not closed(q, id) and not Story.foreign[id] then
                    Story.own[id] = { key = t.k, waited = tonumber(t.w) or 0, row = t.r, marker = t.m }
                    Story.keys[id] = t.k
                    if not markerOf(id) then spawnMarker(q, id, t.m) end
                else
                    missing[#missing + 1] = { old = id, key = t.k, row = t.r, waited = tonumber(t.w) or 0, marker = t.m }
                end
            end
        end
    end
    appendTasks(q, missing)
    ready = true
    Story.stats.restored = Story.stats.restored + 1

    local mine = {}
    for id in pairs(Story.own) do mine[#mine + 1] = id end
    announceOwn(mine)
    applyHidden(q)
    if startedFresh or (q.metEddie ~= true and next(Story.own) == nil) then
        -- The first step of the story: Eddie asks to meet.
        local ok, e = pcall(function() q:eddieFirstCall() end)
        if not ok then log("Story: could not start the story: %s", tostring(e)) end
    end
    refreshTaskViews()
    pushSoon()
    log("Story: %s (%d open story task(s) of your own)", startedFresh and "your story in this world starts from the beginning"
        or "your story in this world continues where you left it", #mine)
end

Repl.on("sinfo", function(sender, data)
    if World.role ~= "guest" or sender ~= Net.S.owner or not active() then return end
    pendingInfo = data
    -- The host's full state is still arriving; the story goes in on top of it.
    installAt = os.clock() + 3
end)

---------------------------------------------------------------- the host's side

-- What a guest needs to know on arrival.
local function describeWorld(q)
    local st, sk, dn, seen = {}, {}, {}, {}
    for id = 0, length(q) - 1 do
        local key = keyOf(q, id)
        if isTagged(q, id) then
            -- A guest's task. One that is still open here belongs to a guest who is away.
            if not closed(q, id) and not Story.own[id] then addForeign(id, key) end
        elseif key and not Story.foreign[id] then
            if closed(q, id) then
                if not seen[key] then
                    seen[key] = true
                    dn[#dn + 1] = key
                end
            else
                if not Story.own[id] then Story.own[id] = { key = key, waited = 0 } end
                st[#st + 1], sk[#sk + 1] = id, key
            end
        end
    end
    for key in pairs(Story.worldDone) do
        if not seen[key] then dn[#dn + 1] = key end
    end
    return { st = st, sk = sk, dn = dn }
end

local function tellStory(id)
    if World.role ~= "host" or not enabled() then return end
    local q = manager()
    if not q then return end
    local ok, info = pcall(describeWorld, q)
    if not ok then
        log("Story: could not describe the world: %s", tostring(info))
        return
    end
    applyHidden(q)
    Repl.send("sinfo", info, id)
    -- Story tasks of other guests that are still open.
    local a, k = {}, {}
    for fid in pairs(Story.foreign) do
        a[#a + 1], k[#k + 1] = fid, Story.keys[fid] or ""
    end
    if #a > 0 then Repl.send("sown", { a = a, k = k }, id) end
end
World.listen("peer", tellStory)
-- A guest that has heard nothing asks again.
Net.on("sreq", function(sender)
    if World.role == "host" and World.inWorld[sender] then tellStory(sender) end
end)

---------------------------------------------------------------- lifecycle

local function reset()
    Story.own, Story.foreign, Story.keys, Story.worldDone = {}, {}, {}, {}
    wire = {}
    ready, startedFresh, meetingTried, packageTried, pendingInfo, installAt = false, false, false, false, nil, nil
    meetingAt, askAt = nil, nil
    profileText, profileHost = nil, nil
end

World.listen("start", function(role)
    reset()
    if role == "host" then ready = true end
end)

World.listen("stop", function(role)
    -- The story as it stands is stored once more, unless the world itself is gone (then
    -- the last stored state, a few seconds old at most, is what there is).
    if not World.gone then
        local q = manager()
        if q then pcall(saveProfile, q, role) end
    end
    reset()
end)

Core.every(STEP, function()
    if not enabled() or not World.active then return end
    local q = manager()
    if not q then return end
    if World.role == "guest" and not ready then
        if not pendingInfo and os.clock() >= (askAt or 0) then
            -- nothing heard about the story yet (after the first wait): ask the host
            if askAt then Net.send("sreq", {}, World.host or Net.S.owner) end
            askAt = os.clock() + 15
        end
        if pendingInfo and os.clock() >= (installAt or 0) then
            local info = pendingInfo
            pendingInfo = nil
            local ok, e = xpcall(install, debug.traceback, q, info)
            applying = false
            if not ok then
                log("Story: setting up your story failed: %s", tostring(e))
                ready = true
            end
        end
        return
    end
    local ok, e = xpcall(watch, debug.traceback, q)
    applying = false
    if not ok then log("Story: %s", tostring(e)) end
    ok, e = pcall(ensureMeeting, q)
    if not ok then log("Story: %s", tostring(e)) end
    ok, e = pcall(ensureFirstPackage, q)
    if not ok then log("Story: %s", tostring(e)) end
end)

-- Stored every few seconds: saveProfile writes only when something changed, and a guest
-- that loses the host (or crashes) restarts from what was stored last.
Core.every(5, function()
    if not active() or World.role ~= "guest" or not ready then return end
    local q = manager()
    if q then pcall(saveProfile, q) end
end)

Story.firstMeetingSeat, Story.firstMeetingEddie = firstMeetingSeat, firstMeetingEddie

function Story.isApplying() return applying end
function Story.hidden() return wire end
function Story.isReady() return ready end
function Story.isFresh() return startedFresh end

return Story
