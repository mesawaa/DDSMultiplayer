-- Every player has their own storyline in a shared world.
--
-- The business is shared (orders, clients, areas, gangs, money: coop/sync.lua). The story
-- that runs on top of it (Eddie's calls, the tutorials, the long-term goals) is kept per
-- player:
--
--   * Story state (which calls and steps a player has been through) is each player's own.
--     The host's lives in the host's save as always. A guest's is sent to the host, kept
--     with the host's world (coop/guests.lua: written beside every save of it) and put
--     back on the next visit.
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
--     package in its dead drop) is there for every player who still has to do them: the
--     dead drop of the first package is a player's own until they have taken theirs.
--   * Sector B opens for everybody as soon as it is open for one player; sector C, Bad Asia
--     and La Ballena's day go for everybody as well (coop/facts.lua).

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")
local Sync = require("coop.sync")
local Guests = require("coop.guests")
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
local FIRST_DROP = { class = "dd_wallVentSmall_C", path = "/Game/Interactive/Containers/DeadDrops/dd_wallVentSmall.dd_wallVentSmall_C",
    x = 3580, y = -2220, z = 175 }
local WALL = "/Game/WorldControlers/wallCheckpoint.wallCheckpoint_C"
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
-- The dead drop of the first package: `private` while this game keeps it to itself,
-- `given` once this player's package has been put in.
local drop = { actor = nil, key = nil, private = false, given = false, searchAt = 0 }
local wallsAt, wallsTold = 0, false
local profileText = nil    -- last story sent to the host (JSON)
-- Without separate storylines (see "without separate storylines" below): `ready` once this
-- guest's own level and skills are in place, `text` what was last sent to the host,
-- `hostOff` when the host has said that it keeps no stories.
local plain = { ready = false, text = nil, hostOff = false }
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
        -- A story task is finished or failed by its owner's game and by no other: what
        -- another game says about one of ours is not taken.
        if next(Story.own) ~= nil then
            local q = Repl.singleton(QM)
            for _, lower in ipairs({ "taskcompleted", "taskfailed" }) do
                local name = pick(values, lower)
                if name and q then
                    local e = Repl.splitArray(values[name])
                    local mine = Repl.splitArray(Repl.export(q, { name })[name] or "()")
                    local changed = false
                    for id in pairs(Story.own) do
                        if e[id + 1] and mine[id + 1] and e[id + 1] ~= mine[id + 1] then
                            e[id + 1] = mine[id + 1]
                            changed = true
                        end
                    end
                    if changed then values[name] = Repl.joinArray(e) end
                end
            end
        end
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
    local n = 0
    for _, name in ipairs(TABLE_ARRAYS) do n = math.max(n, #split[name]) end
    for _, name in ipairs(TABLE_ARRAYS) do
        for i = 1, n do
            if split[name][i] == nil then split[name][i] = ELEMENT_DEFAULT[name] end
        end
    end
    local map = {}
    for _, t in ipairs(list) do
        for _, name in ipairs(TABLE_ARRAYS) do
            local value = t.row and t.row[name] or nil
            if name == "taskCompleted" or name == "taskFailed" then value = "False" end
            if name == "taskDecriptions" and type(value) == "string" and value:sub(-1) == '"' then
                -- a guest's rows carry the mark, the host's do not
                local text = value:sub(1, -2)
                if text:sub(-#TAG) == TAG then text = text:sub(1, -#TAG - 1) end
                value = text .. (World.role == "guest" and TAG or "") .. '"'
            end
            split[name][n + 1] = value or ELEMENT_DEFAULT[name]
        end
        map[t.old] = n
        n = n + 1
    end
    local values = {}
    for _, name in ipairs(TABLE_ARRAYS) do values[name] = Repl.joinArray(split[name]) end
    applying = true
    Repl.import(q, values)
    -- The story's own references to these tasks follow them (every variable of the kind,
    -- not only the ones the game saves: firstDeadDropTaskID is not saved, and the first
    -- package then closed the row the task had before).
    local names, seen = {}, {}
    local function consider(list)
        for _, name in ipairs(list) do
            local lower = name:lower()
            if not seen[lower] and not Sync.questShared(name) and (lower:find("taskid", 1, true) or lower:find("questid", 1, true)) then
                seen[lower] = true
                names[#names + 1] = name
            end
        end
    end
    consider(Repl.savedVars(q))
    pcall(function() consider(Repl.propertyNames(q)) end)
    local moved = {}
    for name, text in pairs(Repl.export(q, names)) do
        local new = map[tonumber(text) or -1]
        if new and tonumber(text) > 0 then moved[name] = tostring(new) end
    end
    if next(moved) ~= nil then Repl.import(q, moved) end
    applying = false
    for _, t in ipairs(list) do
        local id = map[t.old]
        Story.own[id] = { key = t.key, waited = t.waited or 0, row = t.row, marker = t.marker, back = t.back }
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
        Story.own[id] = { key = key, waited = 0, row = readRow(q, id) }
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
local function ensureMeeting(q, force)
    local wanted = force == true
    for _, rec in pairs(Story.own) do
        if rec.key == FIRST_DAY then wanted = true end
    end
    if not wanted or q.metEddie == true then return end
    if force then meetingAt, meetingTried = nil, 0 end
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
-- first one, and finishes the step when that drop has been emptied and closed. There is
-- one such drop in the world and every player's story sends them to it. Shared like any
-- other container, the first player to take the package left the others with an empty
-- drop and a step that could not be done. So while a player still has to fetch theirs,
-- their game's copy of that drop is their own (Sync.private): what the others take out
-- of it or put into it does not show there, and their package is put in when their
-- story asks for it. Afterwards the drop is shared again.
local function firstDrop()
    if Core.alive(drop.actor) then return drop.actor end
    drop.actor = nil
    if os.clock() < drop.searchAt then return nil end
    drop.searchAt = os.clock() + 15
    for _, d in ipairs(Core.actors(FIRST_DROP.path) or FindAllOf(FIRST_DROP.class) or {}) do
        pcall(function()
            if Core.alive(d) then
                local l = d:K2_GetActorLocation()
                if math.abs(l.X - FIRST_DROP.x) < 60 and math.abs(l.Y - FIRST_DROP.y) < 60 and math.abs(l.Z - FIRST_DROP.z) < 60 then drop.actor = d end
            end
        end)
    end
    if not drop.actor then vlog("Story: the dead drop for the first package was not found") end
    return drop.actor
end

local function holdsDrugs(d)
    local out = {}
    local ok = pcall(function() d:checkNoDrugs(out) end)
    if ok and out.DrugsTaken ~= nil then return out.DrugsTaken ~= true end
    local n = 0
    pcall(function() n = d.InventoryComponent.ItemNames:GetArrayNum() end)
    return n > 0
end

local function ownHas(key)
    for _, rec in pairs(Story.own) do
        if rec.key == key then return true end
    end
    return false
end

-- True while this player still has to fetch their first package (or a package put back
-- by RELOAD of MOD OPTIONS is still in the drop: `drop.again`).
local function packagePending(q)
    if drop.again then return true end
    return q.firstDeadDrop ~= true and (ownHas(FIRST_PACK) or ownHas(FIRST_DAY))
end

local function tendFirstPackage(q)
    -- a package put back for a player who had lost theirs: until they have taken it again
    if drop.again and Core.alive(drop.actor) and not holdsDrugs(drop.actor) and os.clock() > drop.again then
        drop.again = nil
        log("Story: the package that was put back has been taken")
    end
    if not packagePending(q) then
        -- this player has had theirs (or has no such step): the drop is everybody's
        if drop.private then
            drop.private = false
            Sync.setPrivate(drop.key, false)
            vlog("Story: the first package's dead drop is shared again")
        end
        return
    end
    local d = firstDrop()
    if not d then return end
    if not drop.private then
        drop.key = Repl.key(d)
        drop.private = true
        Sync.setPrivate(drop.key, true)
        if World.role == "guest" then
            -- the loaded copy holds what the host's drop held, which is not this player's
            pcall(function() d:clearContainer() end)
            pcall(function() d.firstDeadDrop = false end)
        end
        vlog("Story: the first package's dead drop is this player's own for now")
    end
    if drop.given or not ownHas(FIRST_PACK) then return end
    drop.given = true
    local ok, e = pcall(function()
        local filled = holdsDrugs(d)         -- a new game's own package is already there
        d.firstDeadDrop = true
        if not filled then d:ExecuteUbergraph_dd_wallVentSmall(15) end   -- the part of its start-up that puts the package in
    end)
    if ok then
        log("Story: the first package is waiting in its dead drop")
    else
        log("Story: could not place the first package: %s", tostring(e))
    end
end

-- Sector B: the game opens the wall's checkpoints in the game whose player reaches the
-- level for it, and when a save is loaded. The fact itself is shared (the quest manager's
-- secondMapZoneUnlocked), so every other game opens its checkpoints here as soon as it
-- learns of it.
local function tendWalls(q)
    if q.secondMapZoneUnlocked ~= true or os.clock() < wallsAt then return end
    wallsAt = os.clock() + 4
    local opened = 0
    for _, c in ipairs(Core.actors(WALL) or {}) do
        pcall(function()
            -- `loaded`: the checkpoint has had its own look at the fact (a second after it appears)
            if Core.alive(c) and c.loaded == true and c.checkPointActive ~= true then
                c:openCheckpoint()
                opened = opened + 1
            end
        end)
    end
    if opened > 0 then
        log("Story: sector B is open in this world; %d checkpoint(s) of the wall opened here", opened)
        if not wallsTold then
            wallsTold = true
            Net.notify("Sector B is open.")
        end
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
        elseif id >= length(q) or readKey(q, id) ~= rec.key or isTagged(q, id) ~= (World.role == "guest") then
            -- The row was overwritten: both games added a task at the same moment. (Also
            -- when both added the same step: a guest's rows carry the mark, the host's do not.)
            -- Without the row as it was made there is nothing to put back, and a task that
            -- keeps getting lost is left alone after a few times.
            local back = (rec.back or 0) + 1
            if rec.row and back <= 4 then
                lost[#lost + 1] = { old = id, key = rec.key, row = rec.row, waited = rec.waited, marker = rec.marker, back = back }
            else
                Story.own[id] = nil
                log("Story: own task %d (%s) was overwritten and cannot be put back", id, tostring(rec.key))
            end
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
        for _, t in ipairs(lost) do
            Story.own[t.old] = nil
            -- the row is another player's task now
            if t.old < length(q) and isTagged(q, t.old) ~= (World.role == "guest") then addForeign(t.old, readKey(q, t.old)) end
        end
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
    -- what this game holds only because of another player (coop/facts.lua) is not stored
    if Story.profileFilter then pcall(Story.profileFilter, p) end
    return p
end

-- Sends the story as it stands to the host, when it changed since the last time.
local function saveProfile(q, role)
    if (role or World.role) ~= "guest" or not ready or not q then return end
    local ok, profile = pcall(buildProfile, q)
    if not ok then
        log("Story: could not store the story (%s)", tostring(profile))
        return
    end
    local okText, text = pcall(json.encode, profile)
    if not okText or text == profileText then return end
    if Guests.sendStory(profile) then profileText = text end
end

-- Replaces the story state loaded from the host's save with this player's own.
local function install(q, info)
    local p = Guests.story()
    if type(p) ~= "table" or type(p.vars) ~= "table" then p = nil end
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
        else
            log("Story: %s was not found; its values stay the host's", m.class)
        end
    end
    -- (for reports: what this player has in this world from here on)
    pcall(function()
        local s = Repl.singleton("statisticsManager_C")
        local function n(v) return string.format("%.0f", tonumber(v) or -1) end
        log("Story: your level %s and skills are in place (%s): lock picking %s, pockets %s, stamina %s, runner %s, stealth %s, illusionist %s, salesman %s, quick learner %s; %s point(s) to spend",
            tostring(s.playerLevel), p and (type(p.extra) == "table" and type(p.extra.statisticsManager_C) == "table" and "as the host had them stored" or "the stored character had none: a new game's") or "a new character",
            n(s.skillLevelLockpick), n(s.skillLevelPockets), n(s.skillLevelStamina), n(s.skillLevelRunner), n(s.skillLevelStealth), n(s.skillLevelIllusionist),
            n(s.skillLevelSalesman), n(s.skillLevelQuickLearner), tostring(s.playerSkillPoints))
    end)

    local missing, reopen = {}, {}
    if p and type(p.tasks) == "table" then
        local n = length(q)
        for _, t in ipairs(p.tasks) do
            local id = tonumber(t.i)
            if id and type(t.k) == "string" then
                local failed = false
                pcall(function() failed = q.taskFailed[id + 1] == true end)
                if id < n and readKey(q, id) == t.k and isTagged(q, id) and not failed and not Story.foreign[id] then
                    -- The host's game holds a guest's open task as completed (it is kept out
                    -- of the host's list that way) and saves the world like that: the row is
                    -- this player's own and still open, so it is opened again here.
                    if closed(q, id) then reopen[#reopen + 1] = id end
                    Story.own[id] = { key = t.k, waited = tonumber(t.w) or 0, row = t.r, marker = t.m }
                    Story.keys[id] = t.k
                    if not markerOf(id) then spawnMarker(q, id, t.m) end
                else
                    missing[#missing + 1] = { old = id, key = t.k, row = t.r, waited = tonumber(t.w) or 0, marker = t.m }
                end
            end
        end
    end
    if #reopen > 0 then
        local e = Repl.splitArray(Repl.export(q, { "taskCompleted" }).taskCompleted or "()")
        for _, id in ipairs(reopen) do
            if e[id + 1] then e[id + 1] = "False" end
        end
        applying = true
        Repl.import(q, { taskCompleted = Repl.joinArray(e) })
        applying = false
    end
    appendTasks(q, missing)
    ready = true
    Story.stats.restored = Story.stats.restored + 1

    if info.fp == true and q.firstDeadDrop == true then
        -- This player has had their first package; the loaded copy of its dead drop holds
        -- the host's, which the host still has to fetch.
        local d = firstDrop()
        if d then
            pcall(function() d:clearContainer() end)
            pcall(function() d.firstDeadDrop = false end)
        end
    end

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
    -- fp: the first package's dead drop is the host's own for now (what the saved world
    -- holds in it is not a newcomer's to take)
    return { st = st, sk = sk, dn = dn, fp = drop.private == true or packagePending(q) }
end

local function tellStory(id)
    if World.role == "host" and not enabled() and World.inWorld[id] then
        -- (a guest whose own game has the storylines on would wait for a story for ever)
        Net.send("soff", {}, id)
    end
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
    ready, startedFresh, meetingTried, pendingInfo, installAt = false, false, false, nil, nil
    meetingAt, askAt = nil, nil
    profileText = nil
    plain.ready, plain.text, plain.hostOff = false, nil, false
    drop = { actor = nil, key = nil, private = false, given = false, searchAt = 0 }
    wallsAt, wallsTold = 0, false
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
    if not World.active then return end
    if not enabled() then
        -- One storyline: nothing of the separate stories runs, but a package put back by
        -- RELOAD made the first package's dead drop this player's own, and it has to be
        -- everybody's again once taken (it stayed private, and Eddie's packages put into
        -- that drop, the supermarket's, never showed in this game).
        if drop.private then
            local q = manager()
            if q then
                local ok, e = pcall(tendFirstPackage, q)
                if not ok then log("Story: %s", tostring(e)) end
            end
        end
        return
    end
    local q = manager()
    if not q then return end
    if World.role == "guest" and not ready then
        if plain.hostOff then return end
        if not pendingInfo and os.clock() >= (askAt or 0) then
            -- nothing heard about the story yet (after the first wait): ask the host
            if askAt then Net.send("sreq", {}, World.host or Net.S.owner) end
            askAt = os.clock() + 15
        end
        -- (the host's answer about this player's character must be in as well)
        if pendingInfo and Guests.received and os.clock() >= (installAt or 0) then
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
    ok, e = pcall(tendFirstPackage, q)
    if not ok then log("Story: %s", tostring(e)) end
    ok, e = pcall(tendWalls, q)
    if not ok then log("Story: %s", tostring(e)) end
end)

-- Sent every few seconds: saveProfile sends only when something changed, and a guest
-- that loses the host (or crashes) restarts from what the host had last.
Core.every(5, function()
    if not active() or World.role ~= "guest" or not ready then return end
    local q = manager()
    if q then pcall(saveProfile, q) end
end)

---------------------------------------------------------------- without separate storylines

-- A player's level, experience, skill points and skills are their own whatever the
-- settings say: coop/sync.lua never exchanges them. Everything above puts a guest's own
-- in place and stores them with the host, and all of it is off when Sync.Story (or
-- Sync.Orders) is switched off. A guest then had, in every session anew, what the host's
-- save holds, the host's level and skills, and what they spent was gone with the session.
-- In that
-- case these few variables are kept by themselves: sent to the host when they change,
-- stored in the guest's record beside the host's saves (`sheet`, coop/guests.lua), and put
-- back on arrival. A guest the host has nothing for is at the level the save is at (the
-- storyline is the same for everybody) with every skill as in a new game and all the
-- skill points of that level to spend: the game's points at the start and its points per
-- level for every level after the first. (They used to get the host's skills as well.)
Net.on("soff", function(sender)
    if World.role == "guest" and sender == (World.host or Net.S.owner) and not ready then plain.hostOff = true end
end)

local function plainMode()
    return World.active and World.role == "guest" and not ready and (not enabled() or plain.hostOff)
end

-- True while this game plays one storyline with the others: its own setting, or (a guest)
-- the host's. The whole quest manager is shared then, and what the story does once has to
-- happen in one game only (coop/calls.lua).
function Story.oneStoryline()
    if not World.active then return false end
    return not enabled() or (World.role == "guest" and plain.hostOff == true)
end

local function plainNames(s)
    local out = {}
    for _, name in ipairs(Sync.personalNames("statisticsManager_C", s)) do
        if name:lower() ~= "firstlaunch" then out[#out + 1] = name end
    end
    return out
end

-- A new player in this save: skills as in a new game, the points of the level unspent.
-- Returns the number of points, or nil when the game's defaults could not be read.
local STATS_CDO = "/Game/Interactive/statisticsManager.Default__statisticsManager_C"
local function freshSheet(s)
    local cdo = StaticFindObject(STATS_CDO)
    if not valid(cdo) then return nil end
    local names = {}
    for _, name in ipairs(plainNames(s)) do
        if name:sub(1, 10) == "skillLevel" then names[#names + 1] = name end
    end
    local level = math.floor(tonumber(s.playerLevel) or 1)
    local first = math.floor(tonumber(cdo.playerLevel) or 1)
    local per = math.floor(tonumber(s.playerSkillPointsPerLevel) or tonumber(cdo.playerSkillPointsPerLevel) or 0)
    local points = math.floor(tonumber(cdo.playerSkillPoints) or 0) + math.max(0, level - first) * per
    for _, name in ipairs(names) do s[name] = tonumber(cdo[name]) or 0 end
    s.playerSkillPoints = points
    return points
end

local function tendPlain()
    local s = Repl.singleton("statisticsManager_C")
    if not s then return end
    if not plain.ready then
        -- the host's answer about this player's character must be in
        if not Guests.received then return end
        local stored = Guests.sheet()
        local n = 0
        if type(stored) == "table" then
            local allowed, filtered = {}, {}
            for _, name in ipairs(plainNames(s)) do allowed[name] = true end
            for name, text in pairs(stored) do
                if allowed[name] and type(text) == "string" then filtered[name] = text end
            end
            n = Repl.import(s, filtered)
        end
        local fresh = nil
        if n == 0 then
            local ok, points = pcall(freshSheet, s)
            if ok then fresh = points else log("Story: %s", tostring(points)) end
        end
        plain.ready = true
        local function f(v) return string.format("%.0f", tonumber(v) or -1) end
        log("Story: one storyline for everybody (%s); your level %s and skills are %s: lock picking %s, pockets %s, stamina %s, runner %s, stealth %s, illusionist %s, salesman %s, quick learner %s; %s point(s) to spend",
            ((plain.hostOff and enabled()) or (World.hostSyncInUse and World.hostSyncInUse())) and "the host's setting" or "Sync.Story or Sync.Orders is off", tostring(s.playerLevel),
            n > 0 and "your own again, as the host had them stored" or (fresh and "new: the host had none stored for you, every skill point is yours to spend"
                or "those of the host's save (the host had none stored for you; the game's defaults could not be read)"),
            f(s.skillLevelLockpick), f(s.skillLevelPockets), f(s.skillLevelStamina), f(s.skillLevelRunner), f(s.skillLevelStealth), f(s.skillLevelIllusionist),
            f(s.skillLevelSalesman), f(s.skillLevelQuickLearner), tostring(s.playerSkillPoints))
        return
    end
    local values = Repl.export(s, plainNames(s))
    local ok, text = pcall(json.encode, values)
    if not ok or text == plain.text then return end
    if Guests.sendSheet(values) then plain.text = text end
end

Core.every(2, function()
    if not plainMode() then return end
    local ok, e = xpcall(tendPlain, debug.traceback)
    if not ok then log("Story: %s", tostring(e)) end
end)

Story.firstMeetingSeat, Story.firstMeetingEddie = firstMeetingSeat, firstMeetingEddie

-- The first package's dead drop is everybody's again at once: an order of Eddie's has
-- been put into it (coop/eddie.lua). Left this player's own, the package stayed in the
-- other games only.
function Story.shareDrop(key)
    if not drop.private or (key ~= nil and key ~= drop.key) then return false end
    drop.private, drop.again = false, nil
    Sync.setPrivate(drop.key, false)
    log("Story: the first package's dead drop is shared again (an order of Eddie's is in it)")
    return true
end

---------------------------------------------------------------- reloading a step (coop/options.lua)

local ATM_CLASS = "/Game/Interactive/atmMachine.atmMachine_C"

-- Puts the first package into its dead drop again, as this player's own (the others'
-- games keep theirs). Returns true when it is there.
local function packageAgain(q)
    drop.searchAt = 0
    local d = firstDrop()
    if not d then return false end
    if World.active and not drop.private then
        drop.key = Repl.key(d)
        drop.private = true
        Sync.setPrivate(drop.key, true)
        if World.role == "guest" then pcall(function() d:clearContainer() end) end
    end
    if holdsDrugs(d) then return true end
    local ok = pcall(function()
        d.firstDeadDrop = true
        d:ExecuteUbergraph_dd_wallVentSmall(15)
    end)
    -- (it is taken again by this player alone: the drop stays theirs until it is empty)
    if ok then drop.given, drop.again = true, os.clock() + 5 end
    return ok and holdsDrugs(d)
end

-- (for test scripts) the first package put back as by RELOAD
function Story.packageAgain() local q = manager() return q ~= nil and packageAgain(q) end

-- What the pockets hold of a first package (drugs of the package's kinds).
local function carriesPackage()
    local player = World.player()
    if not player then return false end
    local v = Repl.export(player, { "InventoryComponent.ItemNames" })
    for _, name in ipairs(Repl.splitArray(v["InventoryComponent.ItemNames"] or "()")) do
        local n = tostring(name):gsub('"', "")
        if n == "DRUG-MARIHUANA" or n == "DRUG-AMPHETAMINE" then return true end
    end
    return false
end

-- Sets an open story step up again so that the player can do it: whatever the step needs
-- in the world is put back where the mod knows it, its map marker comes back, a tutorial
-- tip in the way is closed and the task list is drawn again. Nothing is completed.
-- Returns the step's name and a list of what was done, or nil when there is no such step.
function Story.reload(id, expectName)
    local q = manager()
    if not q or type(id) ~= "number" or id < 0 or id >= length(q) or closed(q, id) then return nil end
    local name = ""
    pcall(function() name = q.taskNames[id + 1]:ToString() end)
    if expectName and expectName ~= name then return nil end
    local key = keyOf(q, id)
    local done = {}
    pcall(function()
        if q.tipActive == true then
            pcall(function() if valid(q.curGameTip) then q.curGameTip:killWidget() end end)
            q:gameTipEnd()
            done[#done + 1] = "tip closed"
        end
    end)
    if key == FIRST_DAY then
        local ok = pcall(ensureMeeting, q, true)
        if ok and firstMeetingSeat() and firstMeetingEddie() then done[#done + 1] = "Eddie on his bench" end
    elseif key == FIRST_PACK then
        if packageAgain(q) then done[#done + 1] = "package in the dead drop" end
    elseif key == "TASK-FIRST-CLIENTS-DESC" then
        -- the clients want what the package holds: a player who has none of it gets it back
        if q.firstSalesDone ~= true and not carriesPackage() then
            if packageAgain(q) then done[#done + 1] = "package back in the dead drop" end
        end
        pcall(function()
            local Desk = package.loaded["coop.firstsales"]
            if type(Desk) == "table" and Desk.nudge then Desk.nudge() done[#done + 1] = "orders asked for again" end
        end)
    elseif key == "TASK-BANK-DESC" then
        local n = 0
        for _, m in ipairs(Core.actors(ATM_CLASS) or {}) do
            pcall(function()
                if Core.alive(m) and m.atmActive ~= true then
                    m:unlockAtm()
                    n = n + 1
                end
            end)
        end
        pcall(function() Repl.singleton("mainComputer_C").bankAvailable = true end)
        done[#done + 1] = n .. " ATM(s) switched on"
    end
    -- the step's marker on the map and the compass
    local rec = Story.own[id]
    if rec and type(rec.marker) == "table" and not markerOf(id) then
        spawnMarker(q, id, rec.marker)
        done[#done + 1] = "map marker"
    end
    refreshTaskViews()
    log("Story: step %d (%s) reloaded: %s", id, tostring(key), #done > 0 and table.concat(done, ", ") or "task list drawn again")
    return name ~= "" and name or (key or ("step " .. id)), done
end

-- The story steps that are open in this game's task list (the QUESTS page of
-- coop/options.lua): { id, name, desc, key } each, oldest first. Orders (sale tasks) and Eddie's debt are no
-- story steps; another player's steps read "completed" here and are not listed either,
-- nor are tasks the story does not know (an Eddie package and the like).
function Story.openSteps()
    local q = manager()
    if not q then return {} end
    local eddieCash = nil
    pcall(function()
        for _, e in ipairs(Core.actors("/Game/Temporary/panEddie.panEddie_C") or {}) do
            local id = e.curCashTaskID
            if type(id) == "number" and id >= 0 then eddieCash = id end
        end
    end)
    local out = {}
    for id = 0, length(q) - 1 do
        local sale = true
        pcall(function() sale = q.taskIsSale[id + 1] == true end)
        if not closed(q, id) and not sale and id ~= eddieCash and not Story.foreign[id] and wire[id] == nil then
            local name, desc = "", rowText(q, id) or ""
            pcall(function() name = q.taskNames[id + 1]:ToString() end)
            if desc:sub(-#TAG) == TAG then desc = desc:sub(1, -#TAG - 1) end
            local key = keyOf(q, id)
            if (name ~= "" or desc ~= "") and key and TASKS[key] then
                out[#out + 1] = { id = id, name = name, desc = desc, key = key }
            end
        end
    end
    return out
end

-- For coop/storyworld.lua: the story step a row of the task table is (its key, by what the
-- row says), or nil for an order, a package of Eddie's and whatever else is no step.
function Story.stepKey(q, id)
    local key = keyOf(q, id)
    if key and TASKS[key] then return key end
    return nil
end
Story.refreshTaskViews, Story.removeMarkers, Story.taskMarkers = refreshTaskViews, removeMarkers, markers

function Story.isApplying() return applying end
function Story.hidden() return wire end
-- (true as well once a guest's own level and skills are in place without a story of its own)
function Story.isReady() return ready or plain.ready end
function Story.isFresh() return startedFresh end
function Story.has(key) return ownHas(key) end
function Story.firstDropState() return drop end

return Story
