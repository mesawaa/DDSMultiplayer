-- Co-op world: the lobby owner's world is the shared one.
--
-- Joining: a guest at the main menu asks the host for the world. The host saves its game
-- to a temporary file with the game's own save system and sends it. The guest then runs
-- the game's normal "Continue" flow, with the save-slot lookup answered by a substitute
-- slot that points at the received file, so loading works exactly like loading a save.
-- Nothing is written to either player's own save slots.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")

local log, valid = Core.log, Core.valid

local World = {
    active = false,        -- true while this game is part of a shared world
    role = nil,            -- "host" | "guest" while active
    inWorld = {},          -- host: peer ids that have loaded our world
    joining = nil,         -- guest: { path, difficulty, startedAt, stage }
    foreign = false,       -- the loaded world is a received one (stays true after the
                           -- shared world ends, until the main menu or another load)
    host = nil,            -- guest: the id of the player whose world this is
    roster = {},           -- guest: the ids of the guests in the world, as the host told us
    epoch = 0,             -- host: counts the games loaded; a guest's world belongs to one
    gone = false,          -- true while "stop" is told because the world itself is gone:
                           -- nothing of it may be touched then, only forgotten
    menu = nil,            -- the main menu widget, as last seen ticking: { widget, at }
    loadStartedAt = -1000, -- when this game last started loading a save
    savedFor = {},         -- host: when the world was saved for a player who is on the way in
    listeners = {},
}

local SLOT_CLASS = "/Game/SaveGame/saveGameSlot.saveGameSlot_C"
local CONTINUE_EVENT = "BndEvt__btnContinue_K2Node_ComponentBoundEvent_17_OnButtonClickedEvent__DelegateSignature"

local function fire(kind, ...)
    for _, l in ipairs(World.listeners) do
        if l.kind == kind then
            local ok, e = xpcall(l.fn, debug.traceback, ...)
            if not ok then log("World listener %s failed: %s", kind, tostring(e)) end
        end
    end
end

-- kinds: "start"(role) when this game enters a shared world, "stop"() when it ends,
-- "peer"(id) on the host when a guest has finished loading, "peerjoined"(id) on a guest
-- when another guest has, "peerleft"(id) on everybody when a player has left the world.
function World.listen(kind, fn)
    World.listeners[#World.listeners + 1] = { kind = kind, fn = fn }
end

function World.player()
    return Core.player()
end

-- True when state should be exchanged right now.
function World.shared()
    if not World.active or not Net.hasPeers() or not Core.player() then return false end
    if World.role == "host" then return next(World.inWorld) ~= nil end
    return true
end

-- The other players in the world (for a guest: the host and the other guests the host has
-- told us about). What is exchanged between any two games directly goes to these.
function World.others()
    local out = {}
    if not World.active then return out end
    if World.role == "host" then
        for id in pairs(World.inWorld) do out[#out + 1] = id end
    else
        local host = World.host or Net.S.owner
        if host then out[1] = host end
        for id in pairs(World.roster) do
            if id ~= Net.S.me and id ~= host then out[#out + 1] = id end
        end
    end
    return out
end

-- True when `id` is a player in this world (somebody whose messages count).
function World.isPeer(id)
    if not World.active or id == nil or id == Net.S.me then return false end
    if World.role == "host" then return World.inWorld[id] == true end
    return id == (World.host or Net.S.owner) or World.roster[id] == true
end

-- Peers that should receive world state from us.
function World.targets()
    if not World.shared() then return {} end
    if World.role == "guest" then return { World.host or Net.S.owner } end
    local out = {}
    for id in pairs(World.inWorld) do out[#out + 1] = id end
    return out
end

-- Listeners are told the role the game had. While they run, World.gone says whether the
-- world's objects are already gone (back at the main menu): calling anything on one of
-- those crashes the game, so a listener then only forgets what it knew.
local function stop(reason)
    if not World.active and not World.joining then return end
    local role = World.role
    -- a join that is already loading cannot be called back: the world it loads stays a
    -- received one (see World.foreign), it is just not shared
    local loading = World.joining and World.joining.stage ~= "requested" and World.joining or nil
    World.active, World.role, World.inWorld, World.joining = false, nil, {}, nil
    World.roster = {}
    if loading then loading.abandoned = true end
    if reason then Net.notify(reason) end
    World.gone = Core.player() == nil
    fire("stop", role)
    World.gone = false
end

---------------------------------------------------------------- host side

local function fileSize(path) return Core.fileSize(path) end

-- One save at a time, each into a file of its own: two guests may ask in the same moment.
local sending, sendQueue = false, {}

local function sendWorld(target)
    local player = World.player()
    if not player then
        Net.send("world_no", { reason = "The host is not in a game yet." }, target)
        return
    end
    if sending then
        for _, id in ipairs(sendQueue) do if id == target then return end end
        sendQueue[#sendQueue + 1] = target
        return
    end
    sending = true
    local function done()
        sending = false
        local nextTarget = table.remove(sendQueue, 1)
        if nextTarget and Net.S.members[nextTarget] and Net.isHost() then sendWorld(nextTarget) end
    end
    local path = Net.ipcDir() .. "/world_out_" .. tostring(target):gsub("%W", "") .. ".save"
    os.remove(path)
    local lib = StaticFindObject("/Script/RamaSaveSystem.Default__RamaSaveLibrary")
    local okOut, allOut = {}, {}
    World.savedFor[target] = os.clock()
    local ok, e = pcall(function() lib:RamaSave_SaveToFile(player, path, okOut, allOut, "", false, nil) end)
    if not ok then
        log("World save failed: %s", tostring(e))
        Net.send("world_no", { reason = "The host could not save the world." }, target)
        done()
        return
    end
    -- The save may finish a few frames later; send once the file has stopped growing.
    local lastSize, stable, waited = -1, 0, 0
    local function check()
        waited = waited + 1
        local size = fileSize(path)
        if size > 0 and size == lastSize then stable = stable + 1 else stable = 0 end
        lastSize = size
        if stable >= 2 then
            local difficulty = 0
            pcall(function() difficulty = Core.find("difficultyManager_C").curDifficulty end)
            Net.send("world_info", { difficulty = difficulty, size = size, proto = Net.PROTOCOL, v = Net.VERSION, epoch = World.epoch }, target)
            Net.sendFile("world", path, target)
            log("World sent to %s (%d bytes)", Net.name(target), size)
            done()
        elseif waited < 40 then
            Core.after(0.5, check)
        else
            Net.send("world_no", { reason = "The host could not save the world." }, target)
            done()
        end
    end
    Core.after(0.5, check)
end

-- Host: every guest in the world is told who the guests are.
local function tellRoster()
    local ids = {}
    for id in pairs(World.inWorld) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do Net.send("world_roster", { ids = ids }, id) end
end

Net.on("world_req", function(sender, data, name)
    if not Net.isHost() then return end
    if not Core.enabled("World") then
        Net.send("world_no", { reason = "The host has co-op worlds switched off." }, sender)
        return
    end
    if data.proto ~= Net.PROTOCOL then
        Net.send("world_no", { reason = string.format("Different mod versions: the host has %s, you have %s. Both players need the same version.",
            Net.VERSION, type(data.v) == "string" and data.v or "an older one") }, sender)
        Net.notify(name .. " has a different mod version and was not let into the world")
        return
    end
    -- A game that is still loading is not saved for anybody: its managers are replaced a
    -- few seconds into the load. The request is answered when that is over.
    local wait = 25 - (os.clock() - World.loadStartedAt)
    if wait > 0 then
        log("%s asked for the world while it is still loading: answered in %d s", name, math.ceil(wait))
        Core.after(wait, function()
            if Net.isHost() and Net.S.members[sender] then sendWorld(sender) end
        end)
        return
    end
    log("%s asked for the world", name)
    sendWorld(sender)
end)

Net.on("world_joined", function(sender, data, name)
    if not Net.isHost() then return end
    -- The world the guest loaded is no longer the one being played (another game was
    -- loaded meanwhile, or the host went back to the menu): tell the guest so.
    if not World.player() or (type(data) == "table" and data.epoch ~= nil and data.epoch ~= World.epoch) then
        Net.send("world_end", {}, sender)
        return
    end
    World.inWorld[sender] = true
    if not World.active then
        World.active, World.role = true, "host"
        Repl.reset()
        fire("start", "host")
    end
    Net.notify(name .. " is now in your world")
    fire("peer", sender)
    World.savedFor[sender] = nil
    tellRoster()
end)

-- A guest learns who else is in the world from the host.
Net.on("world_roster", function(sender, data)
    if World.role ~= "guest" or sender ~= (World.host or Net.S.owner) or type(data.ids) ~= "table" then return end
    local new = {}
    for _, id in ipairs(data.ids) do new[tostring(id)] = true end
    local old = World.roster
    World.roster = new
    for id in pairs(old) do
        if not new[id] and id ~= Net.S.me then fire("peerleft", id) end
    end
    for id in pairs(new) do
        if not old[id] and id ~= Net.S.me then fire("peerjoined", id) end
    end
end)

---------------------------------------------------------------- guest side

local pendingInfo = nil
local emptyGuestInventory, restorePockets   -- defined further down

local function otherVersion(v)
    World.joining = nil
    Net.notify(string.format("The host has mod version %s, you have %s: both players need the same version.",
        type(v) == "string" and v or "older", Net.VERSION))
end

Net.on("world_info", function(sender, data)
    pendingInfo = data
    if World.joining and sender == Net.S.owner and data.proto ~= Net.PROTOCOL then otherVersion(data.v) end
end)

Net.on("world_no", function(_, data)
    -- only an open request can be refused; a world that is already loading goes on
    if not World.joining or World.joining.stage ~= "requested" then return end
    World.joining = nil
    Net.notify(tostring(data.reason or "The host refused."))
end)

-- The main menu, when it is on screen. It tells us itself every frame it is (main.lua
-- hooks its Tick), so nothing has to be searched for.
local function menuWidget()
    local seen = World.menu
    if not seen or os.clock() - seen.at > 1 then return nil end
    local ok, shown = pcall(function() return valid(seen.widget) and seen.widget:IsInViewport() end)
    if ok and shown then return seen.widget end
    World.menu = nil
    return nil
end

-- Runs the main menu's own Continue (the last saved game). False when the menu is not up.
function World.continueGame()
    local menu = menuWidget()
    if not menu then return false end
    menu[CONTINUE_EVENT](menu)
    return true
end

-- True when this game can ask to join the host's world right now.
function World.canJoin()
    return Net.isGuest() and not World.active and not World.joining and menuWidget() ~= nil
end

function World.requestJoin()
    if not Net.isGuest() then return end
    if not menuWidget() then
        Net.notify("Go to the main menu to join the host's world.")
        return
    end
    if Net.compatible(Net.S.owner) == false then
        otherVersion(Net.S.peerVersion[Net.S.owner])
        return
    end
    pendingInfo = nil
    World.host = Net.S.owner
    World.joining = { startedAt = os.time(), stage = "requested" }
    Net.send("world_req", { proto = Net.PROTOCOL, v = Net.VERSION }, Net.S.owner)
    Net.notify("Asking " .. Net.name(Net.S.owner) .. " for the world...")
end

local function copyFile(from, to)
    local src = io.open(from, "rb")
    if not src then return false end
    local data = src:read("a")
    src:close()
    local dst = io.open(to, "wb")
    if not dst then return false end
    dst:write(data)
    dst:close()
    return true
end

local foreignAt = nil     -- when the Continue flow was started on a received world

Net.onFile("world", function(sender, path)
    if sender ~= Net.S.owner or not World.joining then return end
    -- One request, one world: a second file (the answer to a request that had timed out)
    -- must not restart a load that is under way.
    if World.joining.stage ~= "requested" then
        log("A second world file is ignored (the join is %s)", tostring(World.joining.stage))
        return
    end
    if (pendingInfo and pendingInfo.proto ~= Net.PROTOCOL) or (not pendingInfo and Net.compatible(sender) == false) then
        otherVersion(pendingInfo and pendingInfo.v or Net.S.peerVersion[sender])
        return
    end
    local menu = menuWidget()
    if not menu then
        World.joining = nil
        Net.notify("World received, but you left the main menu. Ask again from the main menu.")
        return
    end
    local target = Net.ipcDir() .. "/coop_world.save"
    if not copyFile(path, target) then
        World.joining = nil
        Net.notify("Could not store the received world.")
        return
    end
    World.joining.path = target
    World.joining.difficulty = pendingInfo and tonumber(pendingInfo.difficulty) or 0
    World.joining.stage = "loading"
    World.joining.startedAt = os.time()
    World.joining.epoch = pendingInfo and pendingInfo.epoch or nil
    -- From here on what gets loaded is somebody else's world, whatever happens to the
    -- join: nothing this game saves may reach the player's own slots.
    World.foreign, foreignAt = true, os.time()
    log("World received (%d bytes), loading", Core.fileSize(target))
    -- Run the game's own Continue flow; the slot lookup below points it at our file.
    menu.continueSlotID = 0
    menu[CONTINUE_EVENT](menu)
end)

-- Answers the Continue flow's save-slot lookup while a join is loading.
-- The slot name is read before the call: after it, UE4SS may hand a hook parameters that are
-- no longer there (a hook that read one after the call crashed the game, v0.8.7).
local slotListAsked = false

-- What the Continue flow is to load instead of the player's own slot: the world of a
-- join in progress, or the co-op autosave asked for a moment ago.
local function substitute()
    local j = World.joining
    if j and j.stage == "loading" and j.path then return j end
    local r = World.restoring and World.restoring()
    if r and os.time() - r.at < 60 then return r end
    return nil
end

pcall(RegisterHook, "/Script/Engine.GameplayStatics:LoadGameFromSlot", function(_, slot)
    slotListAsked = false
    if not substitute() then return end
    pcall(function() slotListAsked = slot:get():ToString() == "saveSlotsFull" end)
end, function(_, ret)
    local j = substitute()
    if not slotListAsked or not j then return end
    slotListAsked = false
    local ok, e = pcall(function()
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local fake = statics:CreateSaveGameObject(StaticFindObject(SLOT_CLASS))
        Repl.import(fake, {
            fullFilePath = '("' .. j.path .. '")',
            saveDifficulty = "(" .. tostring(j.difficulty or 0) .. ")",
            pitcoinWallet = "(0)", gangLevel = "(0)", slotOccupied = "(True)", lastSavedGame = "0",
        })
        ret:set(fake)
        log("Continue flow pointed at %s", j == World.joining and "the received world" or "the co-op autosave")
    end)
    if not ok then log("Slot substitution failed: %s", tostring(e)) end
end)

-- The save system loads asynchronously: managers are destroyed and respawned a few
-- seconds after this call returns. Remember the old one so the swap can be detected.
-- Whether a file is one of ours (a received world, or what a guest saved while in one).
local function ourFile(name)
    local a = tostring(name):gsub("\\", "/"):lower()
    local b = tostring(Net.ipcDir()):gsub("\\", "/"):lower()
    return a:find(b, 1, true) ~= nil or a:find("coop_world.save", 1, true) ~= nil or a:find("guest_scratch.save", 1, true) ~= nil
end

pcall(RegisterHook, "/Script/RamaSaveSystem.RamaSaveLibrary:RamaSave_LoadFromFile", function(_, ...)
    local j = World.joining
    Core.flush(15)                               -- the world's objects are being replaced
    World.epoch = World.epoch + 1
    World.loadStartedAt = os.clock()
    -- Whose world is it? The file's name says so (read here, before the call).
    local name = nil
    for _, a in ipairs({ ... }) do
        pcall(function()
            local v = a:get()
            local s = type(v) == "string" and v or v:ToString()
            if type(s) == "string" and s:lower():find(".save", 1, true) then name = s end
        end)
    end
    if name then
        World.foreign = ourFile(name)
    elseif not j and not (foreignAt and os.time() - foreignAt < 300) then
        World.foreign = false                    -- the player's own game replaces the world
    end
    log("Loading %s (%s)", name and name:match("[^/\\]+$") or "a game", World.foreign and "a received world: saving is redirected" or "the player's own")
    if World.clearRestore then World.clearRestore() end
    if World.active and not j then
        -- Loading a different game replaces the world; the shared one is over for us.
        if World.role == "host" then
            for id in pairs(World.inWorld) do Net.send("world_end", {}, id) end
        else
            Net.send("world_left", {}, World.host or Net.S.owner)
        end
        stop("Co-op world ended: another game was loaded.")
        return
    end
    if not j or j.stage ~= "loading" then return end
    j.stage = "applying"
    World.foreign = true
    j.appliedAt = os.time()
    j.oldStats = nil
    pcall(function() j.oldStats = FindFirstOf("statisticsManager_C"):GetAddress() end)
    log("World load started")
end, function() end)

-- Watches a join in progress until the world is up.
Core.every(1, function()
    local j = World.joining
    if not j then return end
    local age = os.time() - j.startedAt
    if j.stage == "requested" and age > 60 then
        World.joining = nil
        Net.notify("The host did not answer.")
    elseif j.stage == "loading" and age > 120 then
        World.joining = nil
        Net.notify("Loading the host's world did not start.")
    elseif j.stage == "applying" then
        local stats = Core.find("statisticsManager_C")
        local swapped = stats ~= nil and stats:GetAddress() ~= j.oldStats
        if os.time() - j.appliedAt >= 5 and swapped and World.player() then
            -- Drop the pre-load actors now instead of at the engine's next collection.
            pcall(function() StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage() end)
            World.joining = nil
            World.active, World.role = true, "guest"
            Repl.reset()
            emptyGuestInventory()
            restorePockets()
            Net.send("world_joined", { epoch = j.epoch }, World.host or Net.S.owner)
            Net.notify("You are in " .. Net.name(Net.S.owner) .. "'s world")
            fire("start", "guest")
        elseif age > 180 then
            World.joining = nil
            Net.notify("Loading the host's world took too long.")
        end
    end
end)

-- The loaded world contains a copy of the host's character. A guest keeps the keys but
-- starts with empty pockets, otherwise every join would duplicate the host's goods.
emptyGuestInventory = function()
    local player = World.player()
    if not player or Core.config.GuestKeepsInventoryCopy then return end
    local ok, e = pcall(function()
        Repl.import(player, {
            pocketItems = "()", pocketItemQuantity = "()", pocketItemVendor = "()", pocketItemVendorPrice = "()",
            backpackItems = "()", backpackItemQuantity = "()", backpackItemVendor = "()", backpackItemVendorPrice = "()",
            quickUseSlots = "()", quickUseIndex = "()", quickUseGuids = "()", quickUseData = "()",
            illegalFoundPockets = "()", illegalFoundBackpack = "()",
            curBackpackSize = "0", curBackpackWeight = "0", hasDrugs = "False", hasIllegalItems = "False",
        })
        Repl.importRaw(player, "backpackItemContents", "()")
        -- What the character carries is held by its inventory component: one row per
        -- item across several arrays. Every row goes except keys.
        local names = {}
        for _, name in ipairs(Repl.savedVars(player)) do
            if name:sub(1, 19) == "InventoryComponent." then names[#names + 1] = name end
        end
        local values = Repl.export(player, names)
        local itemNames = Repl.splitArray(values["InventoryComponent.ItemNames"] or "()")
        local keep, removed = {}, 0
        for i, item in ipairs(itemNames) do
            if item:upper():find("KEY", 1, true) then keep[#keep + 1] = i else removed = removed + 1 end
        end
        if removed > 0 then
            local out = {}
            for name, text in pairs(values) do
                local e = text:sub(1, 1) == "(" and Repl.splitArray(text) or {}
                if text:sub(1, 1) == "(" and #e == #itemNames then
                    local kept = {}
                    for _, i in ipairs(keep) do kept[#kept + 1] = e[i] end
                    out[name] = Repl.joinArray(kept)
                end
            end
            Repl.import(player, out)
            log("Guest starts with empty pockets (%d item(s) of the host's character removed)", removed)
        end
        pcall(function() player:refreshBackpackData() end)
    end)
    if not ok then log("Could not empty the guest inventory: %s", tostring(e)) end
end

-- What a guest carries is theirs, and the loaded world does not have it: it is written
-- down every few seconds (when it changed) and put back when the guest joins this host
-- again. Without that every disconnect would cost a guest their cash and goods.
local POCKET_VARS = { "pocketItems", "pocketItemQuantity", "pocketItemVendor", "pocketItemVendorPrice",
    "backpackItems", "backpackItemQuantity", "backpackItemVendor", "backpackItemVendorPrice",
    "quickUseSlots", "quickUseIndex", "quickUseGuids", "quickUseData",
    "curBackpackSize", "curBackpackWeight", "hasDrugs", "hasIllegalItems" }
local pocketsText = nil

local function pocketsPath()
    local base = os.getenv("LOCALAPPDATA")
    local dir = base and (base:gsub("\\", "/") .. "/DrugDealerSimulator/Saved/SaveGames") or Core.MOD_DIR
    return string.format("%s/ddsmp_pockets_%s%s.json", dir, tostring(World.host or "x"):gsub("[^%w]", ""), Core.instance and ("_" .. Core.instance) or "")
end

local function inventoryNames(player)
    local names = {}
    for _, name in ipairs(Repl.savedVars(player)) do
        if name:sub(1, 19) == "InventoryComponent." then names[#names + 1] = name end
    end
    return names
end

-- The gangs' dead drops and cash deposit are each player's own (they are not copied
-- between the games). A guest's are written down with the pockets once a gang deals with
-- them, and when a guest joins, the loaded copies, which hold what the host has in them,
-- are emptied and given the guest's own contents.
local GANG_CLASSES = { "/Game/WorldControlers/Gangs/gangDeadDropBase.gangDeadDropBase_C",
    "/Game/Interactive/Containers/Special/ContainerMoneyDeposit.ContainerMoneyDeposit_C" }

local function gangContainers()
    local out = {}
    for _, path in ipairs(GANG_CLASSES) do
        for _, actor in ipairs(Core.actors(path) or {}) do out[#out + 1] = actor end
    end
    return out
end

local function gangState()
    local gang = Core.find("gangManager_C")
    local dealing = false
    pcall(function() dealing = gang.ballenaUnlocked == true or gang.keijiUnlocked == true end)
    if not dealing then return nil end
    local out = {}
    for _, actor in ipairs(gangContainers()) do
        pcall(function()
            local entry = { vars = Repl.export(actor, inventoryNames(actor)) }
            pcall(function() entry.expecting = actor.expectingDrop == true end)
            pcall(function() entry.task = actor.RetrieveCashTaskID end)
            out[Repl.key(actor)] = entry
        end)
    end
    return out
end

local function restoreGang(saved)
    local emptied, given = 0, 0
    for _, actor in ipairs(gangContainers()) do
        pcall(function()
            local mine = type(saved) == "table" and saved[Repl.key(actor)] or nil
            local now = Repl.export(actor, inventoryNames(actor))
            local rows = #Repl.splitArray(now["InventoryComponent.ItemNames"] or "()")
            local out = {}
            for name, text in pairs(now) do
                if mine and type(mine.vars) == "table" and type(mine.vars[name]) == "string" then
                    out[name] = mine.vars[name]
                elseif rows > 0 and text:sub(1, 1) == "(" and #Repl.splitArray(text) == rows then
                    out[name] = "()"
                end
            end
            if next(out) then Repl.import(actor, out) end
            if mine then given = given + 1 elseif rows > 0 then emptied = emptied + 1 end
            pcall(function() Repl.import(actor, { expectingDrop = (mine and mine.expecting) and "True" or "False" }) end)
            pcall(function() Repl.import(actor, { RetrieveCashTaskID = tostring(mine and tonumber(mine.task) or -1) }) end)
        end)
    end
    if emptied > 0 or given > 0 then
        log("Gang drops and deposit are the guest's own: %d emptied of the host's contents, %d given back", emptied, given)
    end
    -- the guest's own gang state is put in place a few seconds after joining (story.lua);
    -- then the gang is pointed at the drop it is waiting at
    Core.after(9, function()
        if World.role ~= "guest" then return end
        pcall(function()
            local gang = Core.find("gangManager_C")
            if gang then gang:reconstructDropRef() end
        end)
    end)
end

local function savePockets()
    local player = World.player()
    if World.role ~= "guest" or not player or not World.host then return end
    local ok, text = pcall(function()
        local names = inventoryNames(player)
        for _, v in ipairs(POCKET_VARS) do names[#names + 1] = v end
        local values = Repl.export(player, names)
        local raw = nil
        pcall(function() raw = Repl.export(player, { "backpackItemContents" }).backpackItemContents end)
        return Net.json.encode({ v = 1, vars = values, contents = raw, gang = gangState() })
    end)
    if not ok or type(text) ~= "string" or text == pocketsText then return end
    local f = io.open(pocketsPath(), "wb")
    if not f then return end
    f:write(text)
    f:close()
    pocketsText = text
end

restorePockets = function()
    pocketsText = nil
    local player = World.player()
    if not player or Core.config.GuestKeepsInventoryCopy then return end
    local f = io.open(pocketsPath(), "rb")
    local text = f and f:read("a") or nil
    if f then f:close() end
    local stored = nil
    if text then pcall(function() stored = Net.json.decode(text) end) end
    pcall(restoreGang, type(stored) == "table" and stored.gang or nil)
    if not text then return end
    local ok, e = pcall(function()
        local p = stored
        if type(p) ~= "table" or type(p.vars) ~= "table" then return end
        -- The keys the host's character has now stay (a door may have been added since):
        -- they are the rows that are in the pockets at this moment.
        local names = inventoryNames(player)
        local now = Repl.export(player, names)
        local keyNames = Repl.splitArray(now["InventoryComponent.ItemNames"] or "()")
        local saved = Repl.splitArray(p.vars["InventoryComponent.ItemNames"] or "()")
        local have = {}
        for _, item in ipairs(saved) do have[item] = true end
        local out = {}
        for name, value in pairs(p.vars) do
            if type(value) == "string" then out[name] = value end
        end
        for _, name in ipairs(names) do
            local mine = out[name]
            if type(mine) == "string" and mine:sub(1, 1) == "(" then
                local rows, theirs = Repl.splitArray(mine), Repl.splitArray(now[name] or "()")
                if #rows == #saved and #theirs == #keyNames then
                    for i, item in ipairs(keyNames) do
                        if not have[item] then rows[#rows + 1] = theirs[i] end
                    end
                    out[name] = Repl.joinArray(rows)
                end
            end
        end
        Repl.import(player, out)
        if type(p.contents) == "string" then Repl.importRaw(player, "backpackItemContents", p.contents) end
        pcall(function() player:refreshBackpackData() end)
        log("Guest gets back what they carried when they last left this host (%d item row(s))", #saved)
    end)
    if not ok then log("Could not put the guest's pockets back: %s", tostring(e)) end
end

Core.every(3, function()
    if World.role ~= "guest" or not World.active then return end
    local ok, e = pcall(savePockets)
    if not ok then log("Pockets: %s", tostring(e)) end
end)

---------------------------------------------------------------- the host's autosave

-- The game only saves when the player does. A host that crashes would take everybody's
-- hours with it, so while guests are in the world it is saved every few minutes into a
-- file of the mod's own (never one of the player's slots), keeping the one before. The
-- main menu's multiplayer panel offers to load it.
local function autosaveDir()
    local base = os.getenv("LOCALAPPDATA")
    -- the game's Saved folder itself: its SaveGames and Serialized folders are synchronised
    -- by Steam Cloud, and this file is not one of the game's saves
    return base and (base:gsub("\\", "/") .. "/DrugDealerSimulator/Saved") or Core.MOD_DIR
end
local function autosaveName(kind) return string.format("%s/ddsmp_autosave%s%s.save", autosaveDir(), Core.instance and ("_" .. Core.instance) or "", kind or "") end
local function autosaveMeta() return autosaveName():gsub("%.save$", ".json") end
local autosaveBusy, autosaveAt = false, nil

function World.autosaveInfo()
    local f = io.open(autosaveMeta(), "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    local ok, m = pcall(Net.json.decode, text)
    if not ok or type(m) ~= "table" or Core.fileSize(autosaveName()) <= 0 then return nil end
    return m
end

function World.autosave(reason)
    local player = World.player()
    if autosaveBusy or not player or World.foreign or World.role ~= "host" then return false end
    autosaveBusy = true
    local fresh = autosaveName("_new")
    os.remove(fresh)
    local lib = StaticFindObject("/Script/RamaSaveSystem.Default__RamaSaveLibrary")
    local ok, e = pcall(function() lib:RamaSave_SaveToFile(player, fresh, {}, {}, "", false, nil) end)
    if not ok then
        autosaveBusy = false
        log("Autosave failed: %s", tostring(e))
        return false
    end
    local lastSize, stable, waited = -1, 0, 0
    local function check()
        waited = waited + 1
        local size = Core.fileSize(fresh)
        if size > 0 and size == lastSize then stable = stable + 1 else stable = 0 end
        lastSize = size
        if stable >= 2 then
            -- the one before is kept: a crash while writing must not cost both
            os.remove(autosaveName("_prev"))
            os.rename(autosaveName(), autosaveName("_prev"))
            local moved = os.rename(fresh, autosaveName())
            local meta = { at = os.time(), date = os.date("%d %b %H:%M"), difficulty = 0, players = 1 }
            pcall(function() meta.difficulty = Core.find("difficultyManager_C").curDifficulty end)
            pcall(function() meta.day = Core.find("BP_WorldTimeAndConditions_C"):GetCurrentIntDay() end)
            for _ in pairs(World.inWorld) do meta.players = meta.players + 1 end
            local f = io.open(autosaveMeta(), "wb")
            if f then
                f:write(Net.json.encode(meta))
                f:close()
            end
            autosaveBusy = false
            log("Autosave written (%d bytes, %s)%s", size, tostring(reason or "timer"), moved and "" or " - could not be put in place")
        elseif waited < 40 then
            Core.after(0.5, check)
        else
            autosaveBusy = false
            log("Autosave did not finish")
        end
    end
    Core.after(0.5, check)
    return true
end

Core.every(10, function()
    local minutes = tonumber(Core.config.AutosaveMinutes) or 5
    if minutes <= 0 or World.role ~= "host" or not World.active then
        autosaveAt = nil
        return
    end
    local now = os.clock()
    autosaveAt = autosaveAt or (now + math.min(120, minutes * 60))       -- the first one soon after somebody joined
    if now < autosaveAt then return end
    -- not in the middle of something: a dialogue, a pause, the save about to go to a guest
    local player = World.player()
    local busy = false
    pcall(function() busy = player.inDialogue == true or Core.statics():IsGamePaused(player) == true end)
    if busy then return end
    if World.autosave() then autosaveAt = now + minutes * 60 end
end)

-- Loads the autosave through the game's own Continue flow (from the main menu). It is the
-- player's own world: what they save afterwards goes to their slots as usual.
local restoring = nil
World.restoring = function() return restoring end
World.clearRestore = function() restoring = nil end
function World.loadAutosave()
    local menu = menuWidget()
    local meta = World.autosaveInfo()
    if not menu or not meta or World.joining or World.active then return false end
    restoring = { path = autosaveName(), difficulty = tonumber(meta.difficulty) or 0, at = os.time() }
    log("Loading the co-op autosave of %s", tostring(meta.date))
    menu.continueSlotID = 0
    menu[CONTINUE_EVENT](menu)
    return true
end

-- While a guest is in the host's world, anything the game saves goes to a scratch file
-- and a scratch slot list, never to the guest's own save slots. This also holds after the
-- shared world has ended (the host left, the lobby dropped): the guest then plays on in a
-- copy of the host's world, and the slot list that copy would save has one slot, the host's.
local function scratch() return World.role == "guest" or World.foreign or World.joining ~= nil end
World.scratch = scratch

pcall(RegisterHook, "/Script/RamaSaveSystem.RamaSaveLibrary:RamaSave_SaveToFile", function(_, _, filename)
    if not scratch() then return end
    local ok, e = pcall(function() filename:set(Net.ipcDir() .. "/guest_scratch.save") end)
    log("Guest save redirected: %s %s", tostring(ok), tostring(e or ""))
end, function() end)

pcall(RegisterHook, "/Script/Engine.GameplayStatics:SaveGameToSlot", function(_, _, slotName)
    if not scratch() then return end
    pcall(function()
        if slotName:get():ToString() == "saveSlotsFull" then slotName:set("ddsmp_guest_scratch") end
    end)
end, function() end)

---------------------------------------------------------------- lifecycle

Net.listen("left", function() stop(World.active and "Co-op world ended: you left the lobby." or nil) end)

Net.listen("gone", function(id, name)
    if (World.role == "guest" or World.joining) and id == (World.host or Net.S.owner) then
        local message = "Co-op world ended: " .. name .. " left. You keep playing a copy of their world; it is not saved."
        stop(message)
        -- The lobby was the host's. Steam has just made somebody else its owner; nobody
        -- should find and join a lobby without its host, so we leave it.
        Net.command("LEAVE")
        -- (leaving has a notice of its own; what matters to the player is said again after it)
        Core.after(1.5, function() Net.notify(message) end)
    elseif World.role == "host" then
        local was = World.inWorld[id]
        World.inWorld[id] = nil
        if was then
            fire("peerleft", id)
            tellRoster()
        end
        if next(World.inWorld) == nil and World.active then
            World.active, World.role = false, nil
            fire("stop", "host")
        end
    end
end)

-- The world ends for us when we return to the main menu. Looked at often: until it is
-- noticed, everything that runs "while in a shared world" would touch a world that is gone.
Core.every(0.25, function()
    -- Back at the main menu the received world is gone, and saving is the player's own again.
    if World.foreign and not World.joining and not World.player() and menuWidget() then World.foreign = false end
    if World.active and not World.player() then
        if World.role == "guest" then
            Net.send("world_left", {}, World.host or Net.S.owner)
        else
            for id in pairs(World.inWorld) do Net.send("world_end", {}, id) end
        end
        stop("Co-op world ended.")
    end
end)

Net.on("world_end", function(sender, _, name)
    if World.role == "guest" and sender == (World.host or Net.S.owner) then
        stop("Co-op world ended: " .. name .. " is no longer in that game. You keep playing a copy; it is not saved.")
    end
end)

Net.on("world_left", function(sender, _, name)
    if World.role ~= "host" then return end
    local was = World.inWorld[sender]
    World.inWorld[sender] = nil
    Net.notify(name .. " left your world")
    if was then
        fire("peerleft", sender)
        tellRoster()
    end
    if next(World.inWorld) == nil then
        World.active, World.role = false, nil
        fire("stop", "host")
    end
end)

return World
