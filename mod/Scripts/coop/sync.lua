-- Keeps a shared co-op world in step.
--
-- Three mechanisms, all built on coop/repl.lua:
--   1. Managers (one instance per world: time, sales, bank, quests, gangs, areas): their
--      saved variables are compared against the last known values on a timer and the
--      changed ones are sent. Variables that tick by themselves are sent by the host only.
--   2. Things near a player (doors, containers, dead drops, stashes, apartments, any
--      other actor the game saves): same comparison, once a second, for actors within
--      reach of the local player. Whatever a player changes by interacting is picked up
--      here without the mod knowing the specific object type.
--   3. Actions that are not stored in saved variables are mirrored as calls: opening and
--      closing doors, and time skips (sleeping, waiting).
--
-- Conflicts: the last change to a variable wins. Two players changing the same variable
-- of the same object within the same second can lose one of the changes.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")
local Dyn = require("coop.dyn")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Sync = { stats = { sent = 0, applied = 0 } }

local NEAR = 700            -- reach (units) around the local player for mechanism 2
local applying = false      -- true while a remote change is being applied locally

---------------------------------------------------------------- policy

-- Each player keeps their own progression and inventory.
local PER_PLAYER = {
    statisticsManager_C = { playerLevel = true, playerExp = true, playerSkillPoints = true, firstLaunch = true,
        skillLevelLockpick = true, skillLevelPockets = true, skillLevelStamina = true, skillLevelRunner = true,
        skillLevelStealth = true, skillLevelIllusionist = true, skillLevelSalesman = true, skillLevelQuickLearner = true },
    -- Whether this game's sales manager makes new orders and clients: on for the host, held
    -- off for a guest (see "one game makes the orders" below).
    salesManager_C = { salesActive = true },
    -- What the apartment manager remembers for its "new apartments" hint goes by the
    -- player's own level (coop/homes.lua); exchanged, one player opening Donald's shop
    -- gave everybody the hint.
    appartmentManager_C = { lastApartmentCount = true },
}

-- The quest manager holds three kinds of state. The task table (parallel arrays indexed
-- by task id) is shared, because orders, dealers, gangs and many placed objects refer to
-- tasks by id. A few facts about the world that other systems read (police, orders,
-- areas) are shared too. Everything else is one player's own storyline and stays in that
-- player's game (coop/story.lua).
local QUEST_CLASS = "questManager_C"
local QUEST_SHARED = {}
for _, name in ipairs({
    "taskNames", "taskDecriptions", "taskExpRewards", "taskCompleted", "taskFailed", "taskIsSale", "taskDisplayed",
    "taskSpecial", "taskCompletesQuest", "taskStringActions",
    "questListName", "questListShort", "questListDescription", "questListExpReward", "questListCashReward",
    "questActivateScript", "questListActive", "questListCompleted",
    "secondMapZoneUnlocked", "SectorCUnlocked", "VillasUnlocked", "EddieRanAway", "EndgameTriggered",
    "NewLaunderPresented", "LaunderDoorsReported", "GreeneContactIndex", "seedGuyContactID",
}) do QUEST_SHARED[name:lower()] = true end

function Sync.questShared(name)
    return QUEST_SHARED[tostring(name):lower()] == true
end

-- With separate storylines each player also has their own standing: how exposed and how
-- reputable they are (the story reads both when it decides which gang approaches you),
-- and their own dealings with whichever gang that turns out to be.
local STORY_STATS = { expofactorlevel = true, reputationfactorlevel = true, riskfactorlevel = true,
    -- exposure is worked out from a player's recent sales and incidents
    exposalesamount = true, exposalesday = true, exposalesnight = true,
    expoeventname = true, expoeventsday = true, expoeventnight = true, deaobservationcountdown = true }

-- What a hideout knows of its drug lab travels by coop/labs.lua, which also does what the
-- game does when a lab comes on or goes off; taken in here as plain values it left a lab
-- switched on in name only.
local LAB_VARS = { labtypeid = true, labcrew = true, labproductiontimer = true, labproducedtotal = true,
    productiononhold = true }

-- True for a variable that is never exchanged between games.
local function personal(className, name)
    local skip = PER_PLAYER[className]
    if skip and skip[name] then return true end
    if LAB_VARS[name:lower()] and Core.enabled("Labs") then return true end
    if not Core.enabled("Story") then return false end
    if className == QUEST_CLASS then return not QUEST_SHARED[name:lower()] end
    if className == "gangManager_C" then return true end
    return className == "statisticsManager_C" and STORY_STATS[name:lower()] == true
end

-- The saved variables of obj that stay in each player's own game.
function Sync.personalNames(className, obj)
    local out = {}
    for _, name in ipairs(Repl.savedVars(obj)) do
        if personal(className, name) then out[#out + 1] = name end
    end
    return out
end

-- Optional per-class rewriting of values between their local form and the form that
-- travels: { out = fn(values), inc = fn(values) }, both changing the table in place.
Sync.transform = {}

local function wire(className, values)
    local t = Sync.transform[className]
    if t then t.out(values) end
    return values
end

-- Variables that change on their own every tick; only the host's copy is sent.
local HOST_ONLY = {
    expoFactorLevel = true, riskFactorLevel = true, reputationFactorLevel = true,
    orderListDeliveryTime = true, cryptoCurrencyPrice = true, drugPrices = true, drugSalePrices = true,
    saleAreaExposure = true, saleAreaClampExposure = true, saleAreaExposureAdd = true, gangSatisfaction = true,
    clientAreaTimeMultiplier = true, badReputationMultiplier = true, nextBenefitPayday = true,
    areaRentedTill = true, LabProducedTotal = true,
    -- The numbers coop/scale.lua raises for more players in the host's game: a guest sent
    -- its own unscaled ones back and the host scaled them again, over and over.
    peopleOnStreetMax = true, maxClientsPerLevel = true, newClientIntervalMin = true, newClientIntervalMax = true,
}

local function hostOnly(name)
    if HOST_ONLY[name] then return true end
    local lower = name:lower()
    return lower:find("countdown", 1, true) ~= nil or lower:find("timer", 1, true) ~= nil
        or lower:find("timeout", 1, true) ~= nil
end

-- Managers: class -> { feature, interval (s), hostOnlyAll, refresh(obj, changedNames) }
local MANAGERS = {}

local function playerWidgets()
    local player = World.player()
    if not player then return nil end
    return player
end

-- The phone app draws its lists when it is opened and when this game itself adds a message.
-- What arrives from another game changes them behind its back: a player with the app open
-- kept looking at the old conversation and at buttons for an order that was gone.
local function refreshPhone(messages)
    pcall(function()
        local computer = Repl.singleton("mainComputer_C")
        local ui = computer and computer.interface
        if not valid(ui) then return end
        Core.callFirst(ui, { "renderContacts", "Render Contacts" })
        local user = ui.curSelectedUser
        if type(user) ~= "number" or user < 0 then return end
        if messages then Core.callFirst(ui, { "renderMessages", "Render Messages" }, user) end
        ui:checkOptionAvailability()
    end)
end

local function has(values, ...)
    if type(values) ~= "table" then return false end
    for _, name in ipairs({ ... }) do
        if values[name] ~= nil then return true end
    end
    return false
end

MANAGERS.statisticsManager_C = { feature = "Managers", interval = 2 }
MANAGERS.mainComputer_C = { feature = "Money", interval = 1, refresh = function(obj, values)
    pcall(function() if valid(obj.interface) then obj.interface:UpdateDesktop() end end)
    if has(values, "messagesList", "messagesUsers", "contactList", "contactNumMessages") then refreshPhone(true) end
end }
MANAGERS.salesManager_C = { feature = "Orders", interval = 1, refresh = function(obj, values)
    pcall(function() obj:ReconstructClientList() end)
    pcall(function() obj:ReconstructClientExpectations() end)
    if has(values, "orderListAccepted", "orderListClosed", "clientAwaitingResponse", "clientsLost", "clientsAvailable") then refreshPhone(false) end
end }
MANAGERS.questManager_C = { feature = "Orders", interval = 1, refresh = function()
    local player = playerWidgets()
    if not player then return end
    pcall(function() if valid(player.InventoryWidget) then player.InventoryWidget:renderTasklist() end end)
    pcall(function() player.HUD:updateMiniTaskList() end)
    pcall(function() player.HUD:refreshCompass() end)
end }
MANAGERS.gangManager_C = { feature = "Orders", interval = 2 }
MANAGERS.saleAreaManager_C = { feature = "Managers", interval = 2 }
MANAGERS.appartmentManager_C = { feature = "Managers", interval = 3 }
MANAGERS.contactsManager_C = { feature = "Managers", interval = 2, refresh = function(_, values)
    if has(values, "charOrderPending", "charIsDead", "characterList") then refreshPhone(false) end
end }
MANAGERS.psychedelicGangManager_C = { feature = "Orders", interval = 3 }

-- Nearby actors of these classes (and their subclasses) are left alone: NPCs run their
-- own AI in each world, the player is per-player, and managers are handled above.
-- A gang's dead drops and its cash deposit belong to one player's dealings with that gang
-- (every player has their own gang state): they are not copied between the games.
local SKIP_BASES = { "/Script/Engine.Pawn", "/Game/Player/playerCharacterBP.playerCharacterBP_C",
    "/Game/WorldControlers/Gangs/gangDeadDropBase.gangDeadDropBase_C",
    "/Game/Interactive/Containers/Special/ContainerMoneyDeposit.ContainerMoneyDeposit_C" }

-- Drug-lab equipment (jars, the metal box, mortars, mills, mixing trays, flasks) draws
-- what it holds only at certain moments of its own: a jar sets the text and the colour of
-- its label one second after it comes to life and when its own player labels it; a mortar
-- or tray shows its heap when its own player changes the amount. Variables that arrive
-- from another game change none of that: a jar a friend had filled and labelled kept its
-- white lid and the word EMPTY here until the game was loaded again, though it held the
-- drugs all along. So after such variables have been put in, the drawing is done here.
-- Nothing below changes a saved variable.
local EQUIPMENT = "/Game/Drugs/DrugLab/workStationEquipmentBase.workStationEquipmentBase_C"
local ADDITIVE = "/Game/Drugs/DrugLab/AdditiveContainers/additiveContainerBase.additiveContainerBase_C"
Sync.stats = Sync.stats or {}

local function refreshEquipment(obj)
    local base = Core.class(EQUIPMENT)
    if not base then return end           -- the class is not even loaded: nothing of the kind exists
    local ok, is = pcall(function() return obj:IsA(base) end)
    if not ok or not is then return end
    Sync.stats.equipment = (Sync.stats.equipment or 0) + 1
    -- mortars, mills, trays, flasks: the heap inside (its own function only shows and sizes it)
    pcall(function() obj:quantityChanged() end)
    local additive = Core.class(ADDITIVE)
    local okA, isA = pcall(function() return additive ~= nil and obj:IsA(additive) end)
    if not okA or not isA then return end
    -- jars and boxes: the lid's colour (a material made for it, as the jar itself makes one)
    pcall(function()
        local material = obj.dynamicMaterial
        if not valid(material) then
            local model = obj.Model
            material = model:CreateDynamicMaterialInstance(0, model:GetMaterial(0), FName("None"))
            obj.dynamicMaterial = material
        end
        if valid(material) then material:SetVectorParameterValue(FName("Color"), obj.labelColor) end
    end)
    -- ... and the word on the label
    pcall(function()
        local widget = obj.labelWidget:GetUserWidgetObject()
        if valid(widget) then widget.txtLabel:SetText(FText(obj.label:ToString())) end
    end)
end
Sync.refreshEquipment = refreshEquipment

-- Called with an object just before a change from another game is put into it.
Sync.beforeApply = {}

-- Called with an object before it is redrawn after a change from another game; one may
-- return a function that is called afterwards. (Redrawing a container also tells whoever
-- listens to it that its contents have changed: coop/labs.lua keeps a lab from taking the
-- cost of a batch out of its cash box because of a change made in another game.)
Sync.refreshGuards = {}

local function refreshNearby(obj)
    local undo = nil
    for _, guard in ipairs(Sync.refreshGuards) do
        local ok, fn = pcall(guard, obj)
        if ok and type(fn) == "function" then
            undo = undo or {}
            undo[#undo + 1] = fn
        end
    end
    -- Containers repaint their open inventory window through this; other classes lack it.
    pcall(function() obj:resetContentSizes() end)
    pcall(function() obj:RamaLoaded() end)
    pcall(refreshEquipment, obj)
    for _, fn in ipairs(undo or {}) do pcall(fn) end
end

---------------------------------------------------------------- container contents

-- A container keeps its contents in parallel arrays: those of its inventory component
-- (item names, quantities, ids, ...), or on older objects items + itemQuantity. Sending
-- the whole arrays would let one player's change overwrite the other's when both use the
-- same container at once. So the rows that were removed and added travel along, and the
-- receiver applies those to whatever it currently has.
local CONTAINER_BASE = "/Game/Interactive/containerBase.containerBase_C"
local ROW_SEP = "\1"
local containerClass = {}   -- class name -> true/false (cached)

local function isContainer(obj, className)
    local cached = containerClass[className]
    if cached ~= nil then return cached end
    local base = StaticFindObject(CONTAINER_BASE)
    local ok, result = pcall(function() return valid(base) and obj:IsA(base) end)
    containerClass[className] = ok and result or false
    return containerClass[className]
end

local INVENTORY = "InventoryComponent."

-- The names of the arrays that together hold the contents, in a fixed order.
local function contentNames(values)
    local names = {}
    for name, text in pairs(values) do
        if type(name) == "string" and name:sub(1, #INVENTORY) == INVENTORY and type(text) == "string" and text:sub(1, 1) == "(" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    if #names == 0 and values.items and values.itemQuantity then names = { "items", "itemQuantity" } end
    return names
end

-- One text per item, made of that item's element in every array.
local function rowsOf(values, names)
    names = names or contentNames(values)
    if #names == 0 then return nil end
    local columns, n = {}, nil
    for i, name in ipairs(names) do
        columns[i] = Repl.splitArray(values[name] or "()")
        if n and #columns[i] ~= n then return nil end
        n = #columns[i]
    end
    local rows = {}
    for r = 1, n do
        local parts = {}
        for i = 1, #names do parts[i] = columns[i][r] end
        rows[r] = table.concat(parts, ROW_SEP)
    end
    return rows, names
end

local function tally(rows)
    local t = {}
    for _, row in ipairs(rows) do t[row] = (t[row] or 0) + 1 end
    return t
end

-- Rows to remove from and add to `before` to get `after` (as multisets).
local function rowDelta(before, after)
    local have, want = tally(before), tally(after)
    local rm, add = {}, {}
    for row, n in pairs(have) do
        for _ = 1, n - (want[row] or 0) do rm[#rm + 1] = row end
    end
    for row, n in pairs(want) do
        for _ = 1, n - (have[row] or 0) do add[#add + 1] = row end
    end
    return rm, add
end

local function sameRows(a, b)
    if #a ~= #b then return false end
    local ta, tb = tally(a), tally(b)
    for row, n in pairs(ta) do
        if tb[row] ~= n then return false end
    end
    return true
end

-- Applies a received row delta to the container and returns the array texts to import.
local function mergeRows(obj, values, delta)
    local names = contentNames(values)
    if #names == 0 then return false end
    local mine = rowsOf(Repl.export(obj, names), names)
    local theirs = rowsOf(values, names)
    if not mine or not theirs or type(delta.rm) ~= "table" or type(delta.add) ~= "table" then return false end
    for _, row in ipairs(delta.rm) do
        for i = 1, #mine do
            if mine[i] == row then
                table.remove(mine, i)
                break
            end
        end
    end
    for _, row in ipairs(delta.add) do mine[#mine + 1] = row end
    if sameRows(mine, theirs) then return false end   -- no conflict: take their arrays as they are
    local columns = {}
    for i = 1, #names do columns[i] = {} end
    for r, row in ipairs(mine) do
        local i = 0
        for part in (row .. ROW_SEP):gmatch("(.-)" .. ROW_SEP) do
            i = i + 1
            if columns[i] then columns[i][r] = part end
        end
    end
    for i, name in ipairs(names) do values[name] = Repl.joinArray(columns[i]) end
    return true
end

---------------------------------------------------------------- manager arrays changed by several games

-- Managers keep most of their state in arrays with one element per client, contact or
-- order, and every game changes them: one player accepts an order (a flag of that order,
-- the pending flag of that contact, a line in the message history) while the host's game
-- makes a new order for somebody else. Sent as whole arrays, whichever arrived last undid
-- the other: an order message was left without its pending flag (nobody could accept it),
-- or a player's answer vanished from the history again.
--   * An array that kept its length travels with the numbers of the elements that changed;
--     the receiver changes those in its own array.
--   * A history that only grows (the phone's messages) travels as rows added and removed.
-- A whole array is still taken as it is when the lengths differ, from a game that sends
-- no such lists (older version), and when a guest asks for the host's state (resync).
local LOGS = {
    mainComputer_C = { { "messagesUsers", "messagesList", "messagesMine" } },
}

-- What to send along with `changed` (name -> text) of a manager: `base` is what the others
-- last had from us. Returns cells (name -> list of changed element numbers) and logs
-- (group number as text -> { rm, add }); either can be nil.
local function managerDeltas(className, base, now, changed)
    local cells, logs = nil, nil
    local inLog = {}
    for g, group in ipairs(LOGS[className] or {}) do
        local touched = false
        for _, name in ipairs(group) do
            inLog[name] = true
            if changed[name] then touched = true end
        end
        if touched then
            local before, after = rowsOf(base, group), rowsOf(now, group)
            if before and after then
                local rm, add = rowDelta(before, after)
                logs = logs or {}
                logs[tostring(g)] = { rm = rm, add = add }
                -- the rows only make sense with all of their columns
                for _, name in ipairs(group) do changed[name] = now[name] end
            end
        end
    end
    for name, text in pairs(changed) do
        local old = base[name]
        if not inLog[name] and not hostOnly(name) and type(old) == "string" and text:sub(1, 1) == "(" and old:sub(1, 1) == "(" then
            local a, b = Repl.splitArray(old), Repl.splitArray(text)
            if #a == #b and #b > 1 then
                local list = {}
                for i = 1, #b do
                    if a[i] ~= b[i] then list[#list + 1] = i end
                end
                if #list > 0 and #list < #b then
                    cells = cells or {}
                    cells[name] = list
                end
            end
        end
    end
    return cells, logs
end

-- Applies the sender's lists to our own arrays and puts the result into `values` (which
-- is then imported). Returns the names where we now hold something the sender does not.
local function mergeManager(obj, className, values, data)
    local kept = {}
    if type(data.lg) == "table" then
        for g, group in ipairs(LOGS[className] or {}) do
            local delta = data.lg[tostring(g)]
            local complete = true
            for _, name in ipairs(group) do
                if type(values[name]) ~= "string" then complete = false end
            end
            if complete and type(delta) == "table" and type(delta.rm) == "table" and type(delta.add) == "table" then
                local mine, theirs = rowsOf(Repl.export(obj, group), group), rowsOf(values, group)
                if mine and theirs then
                    for _, row in ipairs(delta.rm) do
                        for i = 1, #mine do
                            if mine[i] == row then
                                table.remove(mine, i)
                                break
                            end
                        end
                    end
                    for _, row in ipairs(delta.add) do mine[#mine + 1] = row end
                    if not sameRows(mine, theirs) then
                        local columns = {}
                        for i = 1, #group do columns[i] = {} end
                        for r, row in ipairs(mine) do
                            local i = 0
                            for part in (row .. ROW_SEP):gmatch("(.-)" .. ROW_SEP) do
                                i = i + 1
                                if columns[i] then columns[i][r] = part end
                            end
                        end
                        for i, name in ipairs(group) do
                            values[name] = Repl.joinArray(columns[i])
                            kept[name] = true
                        end
                    end
                end
            end
        end
    end
    if type(data.ix) == "table" then
        for name, list in pairs(data.ix) do
            local text = values[name]
            if type(text) == "string" and type(list) == "table" and not hostOnly(name) then
                local theirs = Repl.splitArray(text)
                local own = Repl.export(obj, { name })[name]
                local mine = own and Repl.splitArray(own) or nil
                -- (The lengths can differ: this game has added a client or an order since
                -- the sender last heard from it. The sender changed single elements of the
                -- array as it knew it; those are taken, the length stays ours.)
                if mine and #mine > 0 and #theirs > 0 then
                    for _, i in ipairs(list) do
                        i = tonumber(i)
                        if i and theirs[i] ~= nil and mine[i] ~= nil then mine[i] = theirs[i] end
                    end
                    local merged = Repl.joinArray(mine)
                    if merged ~= text then
                        values[name] = merged
                        kept[name] = true
                    end
                end
            end
        end
    end
    return kept
end

---------------------------------------------------------------- change tracking

local tracked = {}   -- id -> { base = name -> text }
local sentAt = {}    -- id -> when this game last sent a change of it

-- Objects that are one player's own for the time being (the dead drop of the first package
-- while that player still has to fetch theirs: coop/story.lua). Nothing of such an object
-- is sent from this game and nothing that arrives for it is put in. When that is over the
-- object takes the state the others have: this game asks for it.
Sync.private = {}    -- key -> true

function Sync.setPrivate(key, on)
    if type(key) ~= "string" then return end
    if on then
        Sync.private[key] = true
        return
    end
    if not Sync.private[key] then return end
    Sync.private[key] = nil
    tracked[key] = nil
    for _, id in ipairs(World.others()) do Repl.send("opull", { k = key }, id) end
end

-- A container's isOpen says that this game's player has it open right now. Sent across it
-- shut the container in the other game (the game opens nothing that already reads open)
-- and could end up in a save that way, shut for everybody for good (the repair at the end
-- of this file opens such a container again).
local function localOnly(obj, className, name)
    return name == "isOpen" and isContainer(obj, className)
end

local function names(obj, className)
    local list = Repl.savedVars(obj)
    local out = {}
    for _, name in ipairs(list) do
        if not personal(className, name) and not localOnly(obj, className, name) then out[#out + 1] = name end
    end
    return out
end

local function sendTo(targets, messageType, data)
    Repl.sendMany(messageType, data, targets)
end

-- Compares obj with its last known state and sends what changed. `full` forces sending
-- every variable this side may send (used when a guest has just arrived).
local function diff(id, obj, className, allHostOnly, targets, full)
    local now = wire(className, Repl.export(obj, names(obj, className)))
    local t = tracked[id]
    if not t then
        tracked[id] = { base = now }
        if not full then return 0 end
        t = { base = {} }
    end
    local isHost = World.role == "host"
    local changed, count = {}, 0
    for name, text in pairs(now) do
        if t.base[name] ~= text or full then
            if isHost or not (allHostOnly or hostOnly(name)) then
                changed[name] = text
                count = count + 1
            end
        end
    end
    local rows = nil
    if count > 0 and not full then
        local content = contentNames(now)
        local touched = false
        for _, name in ipairs(content) do
            if changed[name] then touched = true end
        end
        if touched and (content[1] ~= "items" or isContainer(obj, className)) then
            local before, after = rowsOf(t.base, content), rowsOf(now, content)
            if before and after then
                local rm, add = rowDelta(before, after)
                rows = { rm = rm, add = add }
                for _, name in ipairs(content) do changed[name] = now[name] end
            end
        end
    end
    local cells, logs = nil, nil
    if count > 0 and not full and MANAGERS[className] then
        local ok, c, l = pcall(managerDeltas, className, t.base, now, changed)
        if ok then cells, logs = c, l end
    end
    tracked[id].base = now
    if count > 0 then
        sentAt[id] = os.clock()
        sendTo(targets, "st", { id = id, c = className, v = changed, rows = rows, ix = cells, lg = logs })
        Sync.stats.sent = Sync.stats.sent + count
        vlog("Sync: sent %d var(s) of %s", count, id)
    end
    return count
end

---------------------------------------------------------------- applying remote state

local function locate(id, className)
    if id:sub(1, 2) == "s:" then return Repl.singleton(className) end
    return Repl.find(id)
end

Repl.on("st", function(sender, data)
    if not World.active or type(data.v) ~= "table" or type(data.id) ~= "string" then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= Net.S.owner then return end
    local className = tostring(data.c)
    local manager = MANAGERS[className]
    if manager and not Core.enabled(manager.feature) then return end
    if Sync.private[data.id] then
        if World.role == "host" then
            for id in pairs(World.inWorld) do
                if id ~= sender then Repl.send("st", { id = data.id, c = className, v = data.v, ix = data.ix, lg = data.lg }, id) end
            end
        end
        return
    end
    local obj = locate(data.id, className)
    if not obj then return end
    local values, count = {}, 0
    for name, text in pairs(data.v) do
        local allowed = type(name) == "string" and type(text) == "string" and not personal(className, name)
            and not localOnly(obj, className, name)
        -- A guest never overrides what the host owns.
        if allowed and World.role == "host" and ((manager and manager.hostOnlyAll) or hostOnly(name)) then allowed = false end
        if allowed then
            values[name] = text
            count = count + 1
        end
    end
    if count == 0 then return end
    -- The sales manager keeps one element per client and per order in dozens of arrays
    -- that only ever grow. A guest that changes one while the host has just added a client
    -- or an order sends a copy that is one short; taken whole it cut the host's array down
    -- and left arrays of different lengths (the game then made orders for a client that
    -- half existed, one every frame). Such a copy is not taken; the guest gets the host's.
    if World.role == "host" and className == "salesManager_C" then
        local back = nil
        for name, text in pairs(values) do
            local lower = name:lower()
            if (lower:sub(1, 6) == "client" or lower:sub(1, 9) == "orderlist") and text:sub(1, 1) == "("
                and not (type(data.ix) == "table" and data.ix[name]) then
                local own = Repl.export(obj, { name })[name]
                if own and #Repl.splitArray(text) < #Repl.splitArray(own) then
                    back = back or {}
                    back[name] = own
                end
            end
        end
        if back then
            for name in pairs(back) do
                values[name] = nil
                count = count - 1
            end
            Repl.send("st", { id = data.id, c = className, v = wire(className, back) }, sender)
            vlog("Sync: %s sent arrays that are shorter than this game's; it gets ours back", Net.name(sender))
            if count <= 0 then return end
        end
    end
    local relay = {}
    for name, text in pairs(values) do relay[name] = text end
    local transform = Sync.transform[className]
    if transform then transform.inc(values) end
    applying = true
    Sync.applyingFrom = sender      -- (for the refresh guards: who made the change)
    local senderRows = nil   -- set when our contents differ from the sender's after merging
    local kept = nil         -- manager arrays where we hold something the sender does not
    local ok, e = pcall(function()
        if type(data.rows) == "table" then
            local theirs = {}
            for _, name in ipairs(contentNames(values)) do theirs[name] = values[name] end
            if mergeRows(obj, values, data.rows) then
                senderRows = theirs
                vlog("Sync: merged container rows of %s", data.id)
            end
        end
        if manager and (type(data.ix) == "table" or type(data.lg) == "table") then
            kept = mergeManager(obj, className, values, data)
        end
        for _, fn in ipairs(Sync.beforeApply) do pcall(fn, obj) end
        Repl.import(obj, values)
        if manager then
            if manager.refresh then manager.refresh(obj, values) end
        else
            refreshNearby(obj)
        end
    end)
    applying = false
    Sync.applyingFrom = nil
    if not ok then log("Sync: applying %s failed: %s", data.id, tostring(e)) end
    -- Our own export of the new values becomes the baseline, so they are not echoed back.
    local t = tracked[data.id] or { base = {} }
    tracked[data.id] = t
    local list = {}
    for name in pairs(values) do list[#list + 1] = name end
    for name, text in pairs(wire(className, Repl.export(obj, list))) do t.base[name] = text end
    if senderRows then
        -- We hold rows the sender does not have yet. Keep the sender's contents as the
        -- baseline so the next comparison sends exactly those rows.
        for name, text in pairs(senderRows) do t.base[name] = text end
    end
    if kept then
        -- The same for manager arrays: what the sender has stays the baseline, so the next
        -- comparison sends the elements and rows that are ours.
        for name in pairs(kept) do
            if relay[name] then t.base[name] = relay[name] end
        end
    end
    Sync.stats.applied = Sync.stats.applied + count
    vlog("Sync: applied %d var(s) to %s from %s", count, data.id, Net.name(sender))
    -- The host passes a guest's change on to the other guests.
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= sender then Repl.send("st", { id = data.id, c = className, v = relay, ix = data.ix, lg = data.lg }, id) end
        end
    end
end)

---------------------------------------------------------------- mechanism 1: managers

local managerDue = {}

local function pollManagers(full, onlyTarget)
    local targets = onlyTarget and { onlyTarget } or World.targets()
    if #targets == 0 then return end
    local now = os.clock()
    -- Comparing a manager means reading every saved variable of it, which takes a while:
    -- on the timer only one manager is looked at per tick, the most overdue first.
    local pick, pickDue = nil, nil
    for className, m in pairs(MANAGERS) do
        local due = managerDue[className] or 0
        if Core.enabled(m.feature) and (full or now >= due) then
            if full then
                managerDue[className] = now + m.interval
                local obj = Repl.singleton(className)
                if obj then
                    local ok, e = pcall(diff, "s:" .. className, obj, className, m.hostOnlyAll, targets, full)
                    if not ok then log("Sync: %s failed: %s", className, tostring(e)) end
                end
            elseif not pick or due < pickDue then
                pick, pickDue = className, due
            end
        end
    end
    if pick then
        local m = MANAGERS[pick]
        managerDue[pick] = now + m.interval
        local obj = Repl.singleton(pick)
        if obj then
            local a = Core.profile and os.clock()
            local ok, e = pcall(diff, "s:" .. pick, obj, pick, m.hostOnlyAll, targets, false)
            if a then Core.mark("manager " .. pick, os.clock() - a) end
            if not ok then log("Sync: %s failed: %s", pick, tostring(e)) end
        end
    end
end

-- Sends pending changes of one manager right away instead of on its timer. Used where a
-- late change could collide with the other game's (two games appending a task).
function Sync.pushNow(className)
    local m = MANAGERS[className]
    local targets = World.targets()
    if not m or #targets == 0 or not Core.enabled(m.feature) then return end
    local obj = Repl.singleton(className)
    if not obj then return end
    managerDue[className] = os.clock() + m.interval
    local ok, e = pcall(diff, "s:" .. className, obj, className, m.hostOnlyAll, targets, false)
    if not ok then log("Sync: %s failed: %s", className, tostring(e)) end
end

---------------------------------------------------------------- repairing drift

-- A change can be lost when two players change the same variable at the same moment.
-- Every few seconds the host sends a checksum of each manager; a guest whose own state
-- has differed twice in a row (and has nothing unsent) asks for the host's full state.
local mismatch = {}

local function checksum(obj, className, m)
    local values = wire(className, Repl.export(obj, names(obj, className)))
    local keys = {}
    for name in pairs(values) do
        if not (m.hostOnlyAll or hostOnly(name)) then keys[#keys + 1] = name end
    end
    table.sort(keys)
    local h = 5381
    for _, name in ipairs(keys) do
        local text = name .. "=" .. values[name]
        for i = 1, #text do h = (h * 33 + text:byte(i)) & 0xFFFFFFFF end
    end
    return h, values
end

local checksumOrder, checksumAt = nil, 0

-- One manager per call, in turn: all of them at once is a visible hitch.
local function sendChecksums()
    if World.role ~= "host" or not World.shared() then return end
    if not checksumOrder then
        checksumOrder = {}
        for className in pairs(MANAGERS) do checksumOrder[#checksumOrder + 1] = className end
        table.sort(checksumOrder)
    end
    checksumAt = checksumAt % #checksumOrder + 1
    local className = checksumOrder[checksumAt]
    local m = MANAGERS[className]
    local obj = Core.enabled(m.feature) and Repl.singleton(className) or nil
    if not obj then return end
    local a = Core.profile and os.clock()
    local ok, h = pcall(checksum, obj, className, m)
    if a then Core.mark("checksum " .. className, os.clock() - a) end
    if not ok then return end
    for _, id in ipairs(World.targets()) do Net.send("ck", { h = { [className] = h } }, id) end
end

Net.on("ck", function(sender, data)
    if World.role ~= "guest" or sender ~= Net.S.owner or type(data.h) ~= "table" then return end
    for className, theirs in pairs(data.h) do
        local m = MANAGERS[className]
        local obj = m and Core.enabled(m.feature) and Repl.singleton(className) or nil
        if obj then
            local ok, mine, values = pcall(checksum, obj, className, m)
            local t = tracked["s:" .. className]
            local unsent = false
            if ok and t then
                for name, text in pairs(values) do
                    if t.base[name] ~= text and not hostOnly(name) then unsent = true end
                end
            end
            if ok and mine ~= theirs and not unsent then
                mismatch[className] = (mismatch[className] or 0) + 1
                if mismatch[className] >= 2 then
                    mismatch[className] = 0
                    Net.send("resync", { c = className }, sender)
                    vlog("Sync: %s differs from the host, asking for its state", className)
                end
            else
                mismatch[className] = 0
            end
        end
    end
end)

Net.on("resync", function(sender, data)
    if World.role ~= "host" or not World.inWorld[sender] then return end
    local className = tostring(data.c)
    local m = MANAGERS[className]
    local obj = m and Repl.singleton(className) or nil
    if not obj then return end
    local values = wire(className, Repl.export(obj, names(obj, className)))
    Repl.send("st", { id = "s:" .. className, c = className, v = values }, sender)
    vlog("Sync: sent full %s to %s", className, Net.name(sender))
end)

Core.every(1.5, sendChecksums)

---------------------------------------------------------------- mechanism 2: things near the player

local skipClass = {}   -- class name -> true/false (cached)

local function skipped(actor, className)
    local cached = skipClass[className]
    if cached ~= nil then return cached end
    local skip = MANAGERS[className] ~= nil
    if not skip then
        for _, base in ipairs(SKIP_BASES) do
            local class = StaticFindObject(base)
            if valid(class) then
                local ok, isA = pcall(function() return actor:IsA(class) end)
                if ok and isA then skip = true end
            end
        end
    end
    skipClass[className] = skip
    return skip
end

-- Comparing one object with its last known state reads all of its saved variables. Doing
-- that for everything around the player in one go froze the game for a quarter of a
-- second every second. Now what the player can touch is looked at every second, the rest
-- within NEAR every few seconds, and only a couple of objects per tick.
local REACH = 280            -- units: what the player can use from where they stand
local SLOW = 6               -- seconds between looks at things further off
local PER_TICK = 2
local urgent, relaxed = {}, {}   -- entries waiting for their look
local lookedAt = {}              -- key -> time of the last look
local scanned = nil              -- the registry list the queues were filled from

local function scheduleNearby()
    if not Core.enabled("Objects") or #World.targets() == 0 then return end
    local player = World.player()
    if not player then return end
    local loc = player:K2_GetActorLocation()
    local list = Repl.registry(90)
    if list ~= scanned then
        scanned, urgent, relaxed = list, {}, {}      -- the world was scanned anew
    end
    local now = os.clock()
    for _, e in ipairs(list) do
        if not e.dead and not e.queued then
            local dx, dy, dz = e.x - loc.X, e.y - loc.Y, e.z - loc.Z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 <= NEAR * NEAR then
                local close = d2 <= REACH * REACH
                if now - (lookedAt[e.key] or -100) >= (close and 1 or SLOW) then
                    e.queued = true
                    local q = close and urgent or relaxed
                    q[#q + 1] = e
                end
            end
        end
    end
end

local function lookAt(e, targets)
    e.queued = false
    lookedAt[e.key] = os.clock()
    if Sync.private[e.key] then return end
    if Core.alive(e.actor) then
        if not skipped(e.actor, e.class) then
            if e.seen == nil then
                e.interactive = Dyn.isInteractive(e.actor)
                -- what a player aims with at a work station is no object of the world
                -- (coop/dyn.lua): nothing of it is sent, and its end is nobody's loss
                e.gizmo = e.interactive and Dyn.isGizmo(e.actor)
            end
            if e.gizmo then return end
            e.seen = true
            local a = Core.profile and os.clock()
            local ok, err = pcall(diff, e.key, e.actor, e.class, false, targets, false)
            if a then Core.mark("object " .. e.class, os.clock() - a) end
            if not ok then log("Sync: %s failed: %s", e.key, tostring(err)) end
        end
    else
        -- It existed next to our player a moment ago and is gone now: picked up,
        -- used up or removed here. Objects created during play are handled in dyn.lua.
        e.dead = true
        if e.seen and e.interactive and e.key:sub(1, 2) ~= "d:" and not Repl.remoteGone[e.key] and Core.enabled("Spawns") then
            Dyn.announceGone(nil, e.key)
        end
    end
end

local function workNearby()
    if #urgent == 0 and #relaxed == 0 then return end
    local targets = World.targets()
    if #targets == 0 then
        urgent, relaxed = {}, {}
        return
    end
    for _ = 1, PER_TICK do
        local e = table.remove(urgent, 1) or table.remove(relaxed, 1)
        if not e then return end
        lookAt(e, targets)
    end
end

---------------------------------------------------------------- containers compared after a join

-- A guest plays the world as it was when the host saved it for them; what the host did to
-- a stash or a drop while the guest was still loading never reached them (things taken out
-- would exist twice). So after a guest has arrived the host goes through every container of
-- the world, a few per tick, and sends a checksum of its contents; the guest compares each
-- with its own and asks for the ones that differ, which the host then sends in full.
local SWEEP_PER_TICK = 8
local sweeps = {}        -- guest id -> { at, list, i, sent }

local function contentHash(obj, className)
    local values = wire(className, Repl.export(obj, names(obj, className)))
    local content = contentNames(values)
    if #content == 0 then return nil end
    local h = 5381
    for _, name in ipairs(content) do
        local text = name .. "=" .. values[name]
        for i = 1, #text do h = (h * 33 + text:byte(i)) & 0xFFFFFFFF end
    end
    return h
end

World.listen("peer", function(id)
    if Core.enabled("Objects") then sweeps[id] = { at = os.clock() + 5, i = 1, sent = 0 } end
end)

local function workSweeps()
    if not next(sweeps) then return end
    local now = os.clock()
    for id, s in pairs(sweeps) do
        if World.role ~= "host" or not World.inWorld[id] then
            sweeps[id] = nil
        elseif now >= s.at then
            if not s.list then
                -- a copy: the registry's own list is replaced when the world is scanned anew
                s.list = {}
                for _, e in ipairs(Repl.registry(90)) do s.list[#s.list + 1] = { actor = e.actor, key = e.key, class = e.class } end
            end
            local out, looked = {}, 0
            while s.i <= #s.list and looked < SWEEP_PER_TICK do
                local e = s.list[s.i]
                s.i = s.i + 1
                if Core.alive(e.actor) and not Sync.private[e.key] and not skipped(e.actor, e.class) and isContainer(e.actor, e.class) then
                    looked = looked + 1
                    local ok, h = pcall(contentHash, e.actor, e.class)
                    if ok and h then out[#out + 1], out[#out + 2] = e.key, h end
                end
            end
            if #out > 0 then
                s.sent = s.sent + #out / 2
                Repl.send("ckb", { l = out }, id)
            end
            if s.i > #s.list then
                log("Sync: %d container(s) compared with %s", s.sent, Net.name(id))
                sweeps[id] = nil
            end
            return          -- one guest per tick
        end
    end
end

Repl.on("ckb", function(sender, data)
    if World.role ~= "guest" or sender ~= (World.host or Net.S.owner) or type(data.l) ~= "table" then return end
    local need, now = {}, os.clock()
    for i = 1, #data.l - 1, 2 do
        local key, h = data.l[i], data.l[i + 1]
        local obj = type(key) == "string" and not Sync.private[key] and Repl.known(key) or nil
        -- what we changed ourselves a moment ago is on its way to the host: not undone
        if obj and now - (sentAt[key] or -100) > 30 then
            local ok, mine = pcall(function() return contentHash(obj, obj:GetClass():GetFName():ToString()) end)
            if ok and mine and mine ~= h then need[#need + 1] = key end
        end
    end
    if #need > 0 then
        log("Sync: %d container(s) differ from the host's, asking for them", #need)
        Repl.send("ckn", { l = need }, sender)
    end
end)

Repl.on("ckn", function(sender, data)
    if World.role ~= "host" or not World.inWorld[sender] or type(data.l) ~= "table" then return end
    local n = 0
    for i, key in ipairs(data.l) do
        if i > 60 then break end
        local obj = type(key) == "string" and not Sync.private[key] and Repl.known(key) or nil
        if obj then
            local ok = pcall(function()
                local className = obj:GetClass():GetFName():ToString()
                Repl.send("st", { id = key, c = className, v = wire(className, Repl.export(obj, names(obj, className))) }, sender)
            end)
            if ok then n = n + 1 end
        end
    end
    log("Sync: %d container(s) sent again to %s (changed while they were loading)", n, Net.name(sender))
end)

-- One object in full, for a game whose own copy of it has just stopped being private.
Repl.on("opull", function(sender, data)
    if not World.active or not World.isPeer(sender) or type(data.k) ~= "string" or Sync.private[data.k] then return end
    local obj = Repl.known(data.k) or Repl.find(data.k)
    if not obj then return end
    pcall(function()
        local className = obj:GetClass():GetFName():ToString()
        Repl.send("st", { id = data.k, c = className, v = wire(className, Repl.export(obj, names(obj, className))) }, sender)
        vlog("Sync: sent %s in full to %s", data.k, Net.name(sender))
    end)
end)

---------------------------------------------------------------- mechanism 3: mirrored actions

local function sendAction(data)
    for _, id in ipairs(World.targets()) do Net.send("act", data, id) end
end

local function doorHook(action)
    return function(ctx)
        if applying or not World.shared() or not Core.enabled("Doors") then return end
        local door = ctx:get()
        if not valid(door) then return end
        sendAction({ a = action, k = Repl.key(door) })
        vlog("Sync: door %s %s", action, Repl.key(door))
    end
end

Core.Hooks.add("/Game/Interactive/doorBase.doorBase_C:openDoor", doorHook("open"))
Core.Hooks.add("/Game/Interactive/doorBase.doorBase_C:closeDoor", doorHook("close"))

---------------------------------------------------------------- the clock

-- Game time lives in a native object (WorldTimeAndConditions); the Blueprint clock only
-- mirrors it. The host's time is the reference: it is sent every few seconds and a guest
-- that has drifted is set to it. A sudden jump on either side (sleeping, waiting) is
-- passed on at once so the other side skips too.
local CLOCK_CLASS = "BP_WorldTimeAndConditions_C"
local DRIFT_LIMIT = 4        -- game minutes a guest may differ before it is corrected
local SKIP_SIZE = 20         -- a jump of this many game minutes in one check is a time skip
local lastMinutes = nil
local clockDue = 0

local function clockNow()
    local clock = Repl.singleton(CLOCK_CLASS)
    if not clock then return nil end
    local ok, total = pcall(function()
        return clock:GetCurrentIntDay() * 1440 + clock:GetCurrentIntHour() * 60 + clock:GetCurrentFloatMinute()
    end)
    if ok and type(total) == "number" then return total, clock end
    return nil
end

local function setClock(clock, total)
    local day = math.floor(total / 1440)
    local hour = math.floor((total - day * 1440) / 60)
    local minute = math.floor(total - day * 1440 - hour * 60)
    clock:SetTime(day, hour, minute)
    lastMinutes = total
end

-- Reports a local time skip (a jump since the last look at the clock). Returns true if
-- there was one, in which case the clock must not be corrected backwards right now.
local function noticeSkip(total)
    local previous = lastMinutes
    lastMinutes = total
    if previous and total - previous >= SKIP_SIZE then
        sendAction({ a = "time", to = total })
        vlog("Sync: time skip of %.0f game minutes sent", total - previous)
        return true
    end
    return false
end

-- The game's own waiting and sleeping do not jump the clock: they run the whole game of the
-- player who waits many times faster until the hour asked for is reached. That game's clock
-- leads then: its time goes to the others every second, and it takes no time from anybody
-- that would put it back (a waiting guest was put back to the host's time every few
-- seconds, so the wait never came to its end). When several players wait at once, each at
-- the speed of their own hideout, all of them go at the speed of the fastest: the speed
-- travels with the time, and a waiting game that is slower takes it over.
local rushing, rushLookAt, rushSentAt, rushRate = false, 0, 0, 1
local RUSH_MAX = 60          -- (no speed from another game above this is taken)

local function rushingNow()
    local now = os.clock()
    if now < rushLookAt then return rushing end
    rushLookAt = now + 0.5
    rushing = false
    pcall(function()
        local player = Core.player()
        rushRate = player ~= nil and Core.statics():GetGlobalTimeDilation(player) or 1
        rushing = rushRate > 1.5
    end)
    return rushing
end

local function pollClock()
    if not Core.enabled("Time") or not World.shared() then return end
    if rushingNow() then
        local now = os.clock()
        if now - rushSentAt < 1 then return end
        rushSentAt = now
        local total = clockNow()
        if not total then return end
        lastMinutes = total
        sendAction({ a = "time", to = total, d = rushRate })
        return
    end
    local total = clockNow()
    if not total then return end
    if noticeSkip(total) then
        return
    elseif World.role == "host" and os.clock() >= clockDue then
        clockDue = os.clock() + 4
        sendAction({ a = "clock", now = total })
    end
end

Net.on("act", function(sender, data)
    if not World.active then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= Net.S.owner then return end
    applying = true
    local ok, e = pcall(function()
        if data.a == "open" or data.a == "close" then
            if not Core.enabled("Doors") then return end
            local door = Repl.find(tostring(data.k))
            if not door then return end
            local wantOpen = data.a == "open"
            if door.doorIsOpen ~= wantOpen then
                if wantOpen then door:openDoor() else door:closeDoor() end
            end
        elseif data.a == "time" or data.a == "clock" then
            if not Core.enabled("Time") then return end
            local total, clock = clockNow()
            local target = tonumber(data.a == "time" and data.to or data.now)
            if not total or not target then return end
            if data.a == "time" then
                -- Somebody who waits faster than this game does: wait as fast.
                local rate = tonumber(data.d)
                if rate and rate <= RUSH_MAX and rushingNow() and rate > rushRate + 0.25 then
                    local player = Core.player()
                    if player then
                        Core.statics():SetGlobalTimeDilation(player, rate)
                        log("Sync: waiting at the speed of %s (%.0f times, was %.0f)", Net.name(sender), rate, rushRate)
                        rushRate = rate
                    end
                end
                -- Somebody skipped ahead: follow, never go back.
                if target - total >= 1 then
                    setClock(clock, target)
                    vlog("Sync: time skip applied (+%.0f game minutes)", target - total)
                end
            elseif World.role == "guest" and not (rushingNow() and target < total) and not noticeSkip(total) and math.abs(target - total) >= DRIFT_LIMIT then
                setClock(clock, target)
                vlog("Sync: clock corrected by %.0f game minutes", target - total)
            end
        end
    end)
    applying = false
    if not ok then log("Sync: action %s failed: %s", tostring(data.a), tostring(e)) end
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= sender then Net.send("act", data, id) end
        end
    end
end)

---------------------------------------------------------------- one game makes the orders

-- Every game ran its own sales manager. The countdowns to a client's next order are the
-- host's (they are sent every second or two), so a guest's game reached zero at almost the
-- same moment and made an order of its own for the same client: another drug, another
-- amount, another message, in the same place of the same arrays. The games then swapped
-- their versions and argued until the guest took the host's whole state again. Now only
-- the host's game makes orders and finds clients; a guest's sales manager is kept switched
-- off (`salesActive` gates both, and nothing else) and gets everything from the host.
local salesHeld = false
local salesTold = false

Core.every(1, function()
    if World.role ~= "guest" or not World.active or not Core.enabled("Orders") then return end
    local sales = Repl.singleton("salesManager_C")
    if not sales then return end
    pcall(function()
        -- the guest's own storyline switches it on when its first sales start
        if sales.salesActive == true then
            sales.salesActive = false
            salesHeld = true
            -- A guest who gets there before the host does (both started a new game): the
            -- world's sales begin then, in the host's game.
            if not salesTold then
                salesTold = true
                Net.send("saleson", {}, World.host or Net.S.owner)
            end
        end
    end)
end)

Net.on("saleson", function(sender)
    if World.role ~= "host" or not World.inWorld[sender] or not Core.enabled("Orders") then return end
    pcall(function()
        local sales = Repl.singleton("salesManager_C")
        if sales and sales.salesActive ~= true then
            sales.salesActive = true
            log("Sync: %s has reached their first sales; orders and new clients start in this game", Net.name(sender))
        end
    end)
end)

World.listen("stop", function()
    -- A guest keeps playing a copy of the world by itself: its own game sells again.
    if salesHeld and not World.gone then
        pcall(function()
            local sales = Repl.singleton("salesManager_C")
            if sales then sales.salesActive = true end
        end)
    end
    salesHeld, salesTold = false, false
end)

---------------------------------------------------------------- lifecycle

World.listen("start", function()
    tracked, managerDue, skipClass, mismatch, containerClass = {}, {}, {}, {}, {}
    urgent, relaxed, lookedAt, scanned = {}, {}, {}, nil
    lastMinutes, clockDue = nil, 0
end)

World.listen("stop", function()
    tracked, managerDue = {}, {}
    sentAt, sweeps = {}, {}
    Sync.private = {}
end)

-- A guest that has just loaded gets the host's current manager state, since the world
-- kept running while the guest was loading.
-- One manager per tick: reading and sending all of them at once stops the host's game for
-- a moment every time somebody arrives.
World.listen("peer", function(id)
    local names = {}
    for className in pairs(MANAGERS) do names[#names + 1] = className end
    table.sort(names)
    for i, className in ipairs(names) do
        Core.after(0.04 * i, function()
            local m = MANAGERS[className]
            if not World.inWorld[id] or not Core.enabled(m.feature) then return end
            local obj = Repl.singleton(className)
            if not obj then return end
            local ok, e = pcall(diff, "s:" .. className, obj, className, m.hostOnlyAll, { id }, true)
            if not ok then log("Sync: %s failed: %s", className, tostring(e)) end
        end)
    end
end)

Core.every(0.5, function()
    if World.shared() then scheduleNearby() end
end)

Core.onTick(function()
    if not World.shared() then return end
    pollManagers(false)
    workNearby()
    workSweeps()
end)

-- The clock is watched every tick so a time skip is noticed before anything else.
Core.onTick(pollClock)

-- Compares one object with what the others last had of it and sends the difference, now
-- and wherever it is. For what the game changes far from every player (a package put into
-- a dead drop): things are otherwise only looked at next to the local player.
function Sync.pushObject(actor)
    local targets = World.targets()
    if #targets == 0 or not Core.alive(actor) then return false end
    if Sync.private[Repl.key(actor)] then return false end
    local ok, err = pcall(function()
        -- in full: a first look at an object only notes its state, and this one has never
        -- been looked at by anybody
        diff(Repl.key(actor), actor, actor:GetClass():GetFName():ToString(), false, targets, true)
    end)
    if not ok then log("Sync: pushing an object failed: %s", tostring(err)) end
    return ok
end

-- The same, but only what has changed since the object was last looked at (the first look
-- only notes its state): for the few things of the story that the game changes far from
-- every player and that coop/storyworld.lua looks at on a timer. Returns how many
-- variables were sent.
function Sync.watchObject(actor)
    local targets = World.targets()
    if #targets == 0 or not Core.alive(actor) then return 0 end
    local key = Repl.key(actor)
    if Sync.private[key] then return 0 end
    local ok, n = pcall(diff, key, actor, actor:GetClass():GetFName():ToString(), false, targets, false)
    if not ok then
        log("Sync: watching an object failed: %s", tostring(n))
        return 0
    end
    return n or 0
end

-- A container that reads open while this game's player has no inventory open is stuck
-- (older versions sent isOpen across, and saved worlds still have it): the game ignores a
-- player who tries to open it. When that happens it is opened properly. In single player
-- too, where such a save may be played.
local reopening = false
Core.Hooks.add(CONTAINER_BASE .. ":openContainer", function(ctx)
    if reopening then return end
    local c = ctx:get()
    local player = World.player()
    if not valid(c) or not player then return end
    local stuck = false
    pcall(function() stuck = c.isOpen == true and player.inventoryOpen ~= true and player.atWorkStation ~= true end)
    if not stuck then return end
    Core.after(0.05, function()
        local p = World.player()
        if reopening or not p or not Core.alive(c) then return end
        local still = false
        pcall(function() still = c.isOpen == true and p.inventoryOpen ~= true and p.atWorkStation ~= true end)
        if not still then return end
        reopening = true
        local ok, e = pcall(function()
            c.isOpen = false
            c:openContainer()
        end)
        reopening = false
        log("Sync: %s read open with nobody at it; opened again%s", c:GetFName():ToString(), ok and "" or (" (failed: " .. tostring(e) .. ")"))
    end)
end)

---------------------------------------------------------------- resync on request (coop/options.lua)

-- Every shared manager in full, one every few tenths of a second (all at once is a hitch),
-- and every container compared, as after a join.
local function sendManagers(to)
    local list = {}
    for className, m in pairs(MANAGERS) do
        if Core.enabled(m.feature) then list[#list + 1] = className end
    end
    table.sort(list)
    for i, className in ipairs(list) do
        Core.after(0.25 * i, function()
            if World.role ~= "host" or not World.inWorld[to] then return end
            local obj = Repl.singleton(className)
            if not obj then return end
            pcall(function()
                Repl.send("st", { id = "s:" .. className, c = className, v = wire(className, Repl.export(obj, names(obj, className))) }, to)
            end)
        end)
    end
    if Core.enabled("Objects") then sweeps[to] = { at = os.clock() + 0.25 * #list + 1, i = 1, sent = 0 } end
    return #list
end

Net.on("rsall", function(sender)
    if World.role ~= "host" or not World.inWorld[sender] then return end
    local n = sendManagers(sender)
    log("Sync: %s asked for everything again: %d managers, then the containers", Net.name(sender), n)
end)

-- A guest asks the host for the whole shared state; the host sends it to every guest.
-- Returns false when there is nobody to sync with.
function Sync.resyncAll()
    if not World.shared() then return false end
    if World.role == "guest" then
        Net.send("rsall", {}, World.host or Net.S.owner)
        log("Sync: asked the host for everything again")
        return true
    end
    for id in pairs(World.inWorld) do sendManagers(id) end
    log("Sync: sending everything again to every guest")
    return true
end

-- Draws again what the drug-lab equipment and the bags on the ground hold (labels, lids,
-- heaps, models). Returns how many things were looked at.
function Sync.redrawAll()
    local n = 0
    for _, a in ipairs(Core.actors(EQUIPMENT) or {}) do
        if Core.alive(a) then
            pcall(refreshEquipment, a)
            n = n + 1
        end
    end
    for _, a in ipairs(Core.actors("/Game/Interactive/pickupItems/drugPickupItem.drugPickupItem_C") or {}) do
        pcall(function()
            if Core.alive(a) and (tonumber(a.baseGramsPerItem) or 0) > 0 and a.SubstanceID:ToString() ~= "None" then
                a:configPackage()
                n = n + 1
            end
        end)
    end
    pcall(function()
        local Dyn = package.loaded["coop.dyn"]
        if type(Dyn) ~= "table" then return end
        for _, a in ipairs(Core.actors("/Game/Interactive/pickupItemBase.pickupItemBase_C") or {}) do
            if Dyn.ensureModel(a) then n = n + 1 end
        end
    end)
    log("Sync: %d drug-lab things and bags drawn again", n)
    return n
end

function Sync.isApplying() return applying end
function Sync.tracked() return tracked end

return Sync
