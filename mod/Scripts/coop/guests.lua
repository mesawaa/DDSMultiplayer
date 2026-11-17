-- Every player's character is kept with the host's world.
--
-- A guest's storyline, level, skills, standing and what they carry used to be written to
-- files on the guest's own computer, one per host. That went wrong in two ways: a host who
-- started a new game got guests whose stored story belonged to the old world, and a world
-- put back from an older save kept guests who were ahead of it. Now the host's game holds
-- them:
--
--   * While a guest plays, its game sends its character (story and pockets) to the host
--     every few seconds, when it changed. The host keeps the latest of every player who
--     has been in this world.
--   * Whenever the host's game is saved (a save slot, the co-op autosave), the characters
--     are written next to that save, in a companion file. Loading a save loads its
--     companion: the world and everybody's characters go back together. A new game has
--     no characters.
--   * A guest who arrives gets its character from the host. One the host does not know
--     starts from the beginning.
--   * A guest can ask the host to forget their character (the main menu's panel) and then
--     starts over.
--   * Who each player is (the "who are you" choice, coop/look.lua) is kept the same way:
--     the host's own (also in single player) as `self` in the companion of the save, a
--     guest's in the guest's record. A save or a world without it asks once.
--
-- The files of mod versions before 0.15 (on the guest's computer) are used once, for a
-- world in which guests have played before and whose host has nothing for this guest.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")
local json = require("json")

local log, vlog = Core.log, Core.vlog

local Guests = {
    world = nil,        -- host: { id, players = { [player id] = { name, at, story, pockets } } }
    mine = nil,         -- guest: what the host had for us on arrival: { w, story, pockets }
    received = false,   -- guest: the host has answered
    fresh = false,      -- guest: this player asked to start over
    info = nil,         -- guest at the menu: what the host says it has: { has, level, date, at }
    stats = { written = 0, read = 0, updates = 0 },
}

-- A guest's story tasks end their description with this (see coop/story.lua).
local TAG = "\194\160\194\160"

local function savedDir()
    local base = os.getenv("LOCALAPPDATA")
    return base and (base:gsub("\\", "/") .. "/DrugDealerSimulator/Saved") or Core.MOD_DIR
end

local function suffix() return Core.instance and ("_" .. Core.instance) or "" end

-- The companion of a save file. The game's own slots are in a folder that Steam Cloud
-- synchronises, so theirs are kept in the Saved folder itself; any other save (the co-op
-- autosaves) has its companion beside it.
function World.companion(path)
    if type(path) ~= "string" or path == "" then return nil end
    local p = path:gsub("\\", "/")
    local base = (p:match("([^/]+)$") or p):gsub("%.[^.]*$", "")
    if base == "" then return nil end
    if p:lower():find("/serialized/", 1, true) then
        return string.format("%s/ddsmp_chars_%s%s.json", savedDir(), base, suffix())
    end
    return (p:gsub("%.[^./]*$", "")) .. ".chars.json"
end

local function newId()
    return string.format("%08x%06x", os.time() & 0xFFFFFFFF, math.random(0, 0xFFFFFF))
end

local function readFile(path)
    local f = path and io.open(path, "rb") or nil
    if not f then return nil end
    local text = f:read("a")
    f:close()
    local ok, data = pcall(json.decode, text)
    return ok and type(data) == "table" and data or nil
end

local function writeFile(path, data)
    local ok, text = pcall(json.encode, data)
    if not ok then return false end
    local f = io.open(path .. ".tmp", "wb")
    if not f then return false end
    f:write(text)
    f:close()
    os.remove(path)
    return os.rename(path .. ".tmp", path) ~= nil
end

---------------------------------------------------------------- the host's side

local function ensure()
    if not Guests.world then Guests.world = { id = newId(), players = {} } end
    return Guests.world
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- The host's own game was loaded from `path` (nil: unknown).
World.onLoaded = function(path)
    local data = readFile(World.companion(path))
    if data and type(data.world) == "string" and type(data.players) == "table" then
        Guests.world = { id = data.world, players = data.players, self = type(data.self) == "table" and data.self or nil }
        Guests.stats.read = Guests.stats.read + 1
        log("Characters: %d player(s) of this world loaded with the save", count(data.players))
    else
        Guests.world = { id = newId(), players = {} }
    end
end

-- The host's own game has been saved to `path`.
World.onSaved = function(path)
    local companion = World.companion(path)
    if not companion or World.foreign or World.role == "guest" then return end
    local w = ensure()
    if next(w.players) == nil and not w.self then
        -- a save of a world without guests must not keep the characters of whatever was
        -- in this place before
        os.remove(companion)
        return
    end
    if writeFile(companion, { v = 1, world = w.id, players = w.players, self = w.self }) then
        Guests.stats.written = Guests.stats.written + 1
        vlog("Characters: %d player(s) written with %s", count(w.players), tostring(path):match("[^/\\]+$") or "?")
    else
        log("Characters: could not write %s", companion)
    end
end

-- A new game has no characters (and nothing bought yet: Guests.newGame).
Core.Hooks.add("/Game/MainMenu/mainMenuWidget.mainMenuWidget_C:startNewGame", function()
    Guests.world = { id = newId(), players = {}, newGame = true }
end)

-- True in a world begun with "new game" in this session (not loaded from a save).
function Guests.newGame() return World.role ~= "guest" and Guests.world ~= nil and Guests.world.newGame == true end

-- True when guests have played in this world before (their story tasks are in its table).
local function worldHasGuestTasks()
    local q = Repl.singleton("questManager_C")
    if not q then return false end
    local text = Repl.export(q, { "taskDecriptions" }).taskDecriptions
    return type(text) == "string" and text:find(TAG .. '"', 1, true) ~= nil
end

local function levelOf(record)
    local level = nil
    pcall(function()
        local text = record.story.extra.statisticsManager_C
        for name, value in pairs(text) do
            if name:lower() == "playerlevel" then level = tonumber(tostring(value):match("%d+")) end
        end
    end)
    if level then return level end
    -- (with one storyline for everybody a record holds the level and skills by themselves)
    pcall(function()
        for name, value in pairs(record.sheet) do
            if name:lower() == "playerlevel" then level = tonumber(tostring(value):match("%d+")) end
        end
    end)
    return level
end

local noLegacy = {}     -- player id -> true: asked to start over; the files of old versions do not count either

local function tell(id)
    if World.role ~= "host" or not World.inWorld[id] then return end
    local w = ensure()
    local r = w.players[tostring(id)]
    local known = type(r) == "table" and (type(r.story) == "table" or type(r.pockets) == "table" or type(r.sheet) == "table")
    Repl.send("gch", {
        w = w.id,
        s = known and r.story or nil,
        p = known and r.pockets or nil,
        k = known and type(r.sheet) == "table" and r.sheet or nil,
        lg = (not known) and not noLegacy[tostring(id)] and worldHasGuestTasks(),
        c = type(r) == "table" and type(r.c) == "table" and r.c or nil,
    }, id)
    log("Characters: %s %s", Net.name(id), known and string.format("gets their character of this world back (%s, level %s, last heard of %s)",
        type(r.story) == "table" and "with a story" or (type(r.sheet) == "table" and "level and skills, no story of their own" or "pockets only"), tostring(levelOf(r) or "?"), r.at and os.date("%d %b %H:%M", r.at) or "?") or "is new to this world")
end
World.listen("peer", tell)

Net.on("gchq", function(sender) tell(sender) end)

Repl.on("gup", function(sender, data, name)
    if World.role ~= "host" or not World.inWorld[sender] or type(data) ~= "table" then return end
    local w = ensure()
    local key = tostring(sender)
    local r = type(w.players[key]) == "table" and w.players[key] or {}
    w.players[key] = r
    r.name, r.at = tostring(name or Net.name(sender)), os.time()
    if type(data.s) == "table" then r.story = data.s end
    if type(data.p) == "table" then r.pockets = data.p end
    if type(data.c) == "table" then r.c = data.c end
    if type(data.k) == "table" then r.sheet = data.k end
    noLegacy[key] = nil
    Guests.stats.updates = Guests.stats.updates + 1
end)

local function answer(id)
    if not Net.isHost() then return end
    local w = Guests.world
    local r = w and w.players[tostring(id)] or nil
    local known = type(r) == "table" and (type(r.story) == "table" or type(r.pockets) == "table" or type(r.sheet) == "table")
    Net.send("ga", {
        game = World.player() ~= nil,
        has = known,
        level = known and levelOf(r) or nil,
        date = known and r.at and os.date("%d %b %H:%M", r.at) or nil,
    }, id)
end

-- A lobby member at the main menu asks what this world has for them ...
Net.on("gq", function(sender) answer(sender) end)

-- ... or asks the host to forget their character.
Net.on("gfresh", function(sender, _, name)
    if not Net.isHost() then return end
    local key = tostring(sender)
    noLegacy[key] = true
    local w = Guests.world
    if w and w.players[key] and not World.inWorld[sender] then
        w.players[key] = nil
        log("Characters: %s starts over in this world", tostring(name))
    end
    answer(sender)
end)

---------------------------------------------------------------- the guest's side

-- The files of mod versions before 0.15, per host, on this computer.
local function legacyPath(kind)
    local host = tostring(World.host or Net.S.owner or "x"):gsub("[^%w]", "")
    return string.format("%s/SaveGames/ddsmp_%s_%s%s.json", savedDir(), kind, host, suffix())
end

local function legacy(kind)
    local data = readFile(legacyPath(kind))
    if data and type(data.vars) == "table" then return data end
    return nil
end

local function retireLegacy()
    for _, kind in ipairs({ "story", "pockets" }) do
        local path = legacyPath(kind)
        os.remove(path .. ".old")
        os.rename(path, path .. ".old")
    end
end

local startedAt, askedAt = nil, 0

Repl.on("gch", function(sender, data)
    if World.role ~= "guest" or sender ~= (World.host or Net.S.owner) or Guests.received or type(data) ~= "table" then return end
    local story = type(data.s) == "table" and data.s or nil
    local pockets = type(data.p) == "table" and data.p or nil
    if Guests.fresh then
        story, pockets = nil, nil
    elseif not story and not pockets and data.lg == true then
        story, pockets = legacy("story"), legacy("pockets")
        if story or pockets then log("Characters: your character comes from the files of an older mod version (once)") end
    end
    Guests.mine = { w = data.w, story = story, pockets = pockets, c = (not Guests.fresh) and type(data.c) == "table" and data.c or nil,
        sheet = (not Guests.fresh) and type(data.k) == "table" and data.k or nil }
    Guests.received = true
    Guests.fresh = false
    local ok, e = pcall(World.restorePockets, pockets)
    if not ok then log("Characters: could not put your pockets back: %s", tostring(e)) end
end)

-- The story this guest had in this world: { vars, tasks, extra }, or nil for a new one.
function Guests.story()
    return Guests.mine and Guests.mine.story or nil
end

local function update(part)
    if World.role ~= "guest" or not World.active or not Guests.received then return false end
    Repl.send("gup", part, World.host or Net.S.owner)
    return true
end

function Guests.sendStory(profile) return update({ s = profile }) end

-- A guest's level and skills by themselves, with one storyline for everybody
-- (coop/story.lua, "without separate storylines"): name -> text, or nil.
function Guests.sheet() return Guests.mine and Guests.mine.sheet or nil end
function Guests.sendSheet(values) return update({ k = values }) end

-- Who this player is in this world: { character }, or nil when they have not said yet.
-- (A guest's is known once the host has answered: Guests.ready().)
function Guests.self()
    if World.role == "guest" then return Guests.mine and Guests.mine.c or nil end
    return Guests.world and Guests.world.self or nil
end
function Guests.ready() return World.role ~= "guest" or Guests.received end
-- What other modules keep in that record (the wall quest's step, the Shady Comm picture)
-- stays when the record is written anew as a whole (coop/look.lua does).
Guests.kept = { "wq", "pic" }
function Guests.setSelf(record)
    local old = Guests.self()
    if type(record) == "table" and type(old) == "table" then
        for _, field in ipairs(Guests.kept) do
            if record[field] == nil and old[field] ~= nil then record[field] = old[field] end
        end
    end
    if World.role == "guest" then
        if Guests.mine then Guests.mine.c = record end
        update({ c = record })
    else
        ensure().self = record
    end
end
World.onPockets = function(pockets) return update({ p = pockets }) end

-- Host (and single player): everybody who has played in this world as a guest, by player
-- id: { name, at, c, no, ... }; and the level a record was last at.
function Guests.players()
    if World.role == "guest" then return {} end
    return Guests.world and Guests.world.players or {}
end
Guests.levelOf = levelOf

Core.every(2, function()
    if World.role ~= "guest" or not World.active or Guests.received then return end
    startedAt = startedAt or os.clock()
    -- nothing heard from the host: ask (again)
    if os.clock() - startedAt > 6 and os.clock() - askedAt > 10 then
        askedAt = os.clock()
        Net.send("gchq", {}, World.host or Net.S.owner)
    end
end)

World.listen("start", function(role)
    Guests.mine, Guests.received, startedAt, askedAt = nil, false, nil, 0
    if role == "host" then ensure() end
end)

World.listen("stop", function()
    Guests.mine, Guests.received, startedAt = nil, false, nil
end)

---------------------------------------------------------------- the main menu's panel

-- Asks the host what it has for this player (answered in Guests.info).
function Guests.ask()
    if not Net.isGuest() or World.active then return end
    Net.send("gq", {}, Net.S.owner)
end

Net.on("ga", function(sender, data)
    if sender ~= Net.S.owner or type(data) ~= "table" then return end
    Guests.info = { game = data.game == true, has = data.has == true, level = tonumber(data.level), date = type(data.date) == "string" and data.date or nil,
        at = os.clock(), host = sender }
end)

-- This player's character in the host's world is given up; the next join starts over.
function Guests.startOver()
    if not Net.isGuest() or World.active then return false end
    Guests.fresh = true
    retireLegacy()
    Net.send("gfresh", {}, Net.S.owner)
    return true
end

Net.listen("left", function() Guests.info, Guests.fresh = nil, false end)

return Guests
