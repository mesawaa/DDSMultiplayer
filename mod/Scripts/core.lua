-- Shared plumbing for the DDS Multiplayer modules: logging, config, hook registration
-- that survives Blueprint class reloads, and timers driven by the main game-thread tick.

local Core = {}

Core.VERSION = "0.16.1"
Core.config = require("config")
Core.instance = nil      -- set from the command line (-ddsmp=NAME), nil normally
Core.logFile = nil       -- extra log file, set once the ipc directory is known

local function modDir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", ""):gsub("\\", "/")
    local dir = src:match("^(.*)/[Ss]cripts/[^/]+$")
    return dir or "ue4ss/Mods/DDSMultiplayer"
end

Core.MOD_DIR = modDir()

function Core.log(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    if not ok then text = tostring(fmt) end
    print((Core.instance and ("[DDSMP:" .. Core.instance .. "] ") or "[DDSMP] ") .. text .. "\n")
    if Core.logFile then
        local f = io.open(Core.logFile, "ab")
        if f then
            f:write(os.date("%H:%M:%S "), text, "\n")
            f:close()
        end
    end
end

function Core.vlog(fmt, ...)
    if Core.config.Verbose then Core.log(fmt, ...) end
end

function Core.valid(obj)
    return obj ~= nil and type(obj) == "userdata" and obj.IsValid ~= nil and obj:IsValid()
end

-- After a world load the engine keeps the old, destroyed actors around until its next
-- garbage collection, and FindFirstOf can return those. These helpers skip them.
function Core.alive(actor)
    if not Core.valid(actor) then return false end
    -- The flag is reliable; the IsActorBeingDestroyed() function is not (it stays false).
    local ok, dying = pcall(function() return actor.bActorIsBeingDestroyed end)
    return not (ok and dying == true)
end

-- Optional profiler. `Core.profile = {}` switches it on; Core.profileReport() logs what
-- cost the most since then.
function Core.mark(key, seconds)
    local p = Core.profile
    if not p then return end
    local s = p[key]
    if not s then
        s = { n = 0, t = 0, max = 0 }
        p[key] = s
    end
    s.n, s.t = s.n + 1, s.t + seconds
    if seconds > s.max then s.max = seconds end
end

function Core.profileReport(top)
    local p = Core.profile
    if not p then return end
    local rows = {}
    for key, s in pairs(p) do rows[#rows + 1] = { key = key, n = s.n, t = s.t, max = s.max } end
    table.sort(rows, function(a, b) return a.t > b.t end)
    for i = 1, math.min(top or 15, #rows) do
        local r = rows[i]
        Core.log("PROFILE %-34s %7.0f ms total, %5d call(s), %6.2f ms each, worst %5.0f ms", r.key, r.t * 1000, r.n, r.t / r.n * 1000, r.max * 1000)
    end
end

-- Looking an object up by class name (FindFirstOf / FindAllOf) walks the engine's whole
-- object table: about 30 ms a call in this game. Nothing that runs every tick may do
-- that. The player comes from the engine's own "player pawn" query; the world's managers
-- are looked up once and kept for as long as the same player character exists (a load or
-- a return to the menu replaces the character together with them).
local PLAYER_CLASS = "playerCharacterBP_C"
local persistent = {}    -- path -> object that lives as long as the process (native class defaults)
local viewport = nil     -- the game viewport: lives as long as the process, knows the world
local found = {}         -- class name -> { obj, owner = player address, at }
local missing = {}       -- class name -> { owner, at } of the last search that found nothing
local slowPlayer = nil   -- { obj, at } the character while another pawn is controlled
local unsettledUntil = 0 -- a load is replacing the world's objects until then

-- Objects that are never unloaded (class default objects of native classes, native classes).
function Core.object(path)
    local o = persistent[path]
    if o ~= nil and o:IsValid() then return o end
    o = StaticFindObject(path)
    if Core.valid(o) then
        persistent[path] = o
        return o
    end
    return nil
end

-- Everything under "/Script/" is native (classes, their default objects) and is never
-- unloaded, but looking one up by path costs up to a few milliseconds, and building one
-- screen does that dozens of times. Inside this mod such lookups are answered from memory
-- after the first time.
local findObject = StaticFindObject
function StaticFindObject(path, ...)
    if type(path) == "string" and select("#", ...) == 0 and path:sub(1, 8) == "/Script/" then
        local o = persistent[path]
        if o ~= nil and o:IsValid() then return o end
        o = findObject(path)
        if o ~= nil and o:IsValid() then persistent[path] = o end
        return o
    end
    return findObject(path, ...)
end

function Core.statics() return Core.object("/Script/Engine.Default__GameplayStatics") end
function Core.system() return Core.object("/Script/Engine.Default__KismetSystemLibrary") end

-- Where the classes that are looked up by name live. With its path a class's actors are
-- asked from the world's own list (a fraction of a millisecond); searching by name walks
-- every object of the engine (thirty to forty). Paths of other actor classes are learned
-- the first time one is found.
local classPath = {
    playerCharacterBP_C = "/Game/Player/playerCharacterBP.playerCharacterBP_C",
    statisticsManager_C = "/Game/Interactive/statisticsManager.statisticsManager_C",
    mainComputer_C = "/Game/Interactive/mainComputer.mainComputer_C",
    questManager_C = "/Game/WorldControlers/questManager.questManager_C",
    salesManager_C = "/Game/WorldControlers/salesManager.salesManager_C",
    policeManager_C = "/Game/WorldControlers/policeManager.policeManager_C",
    dayTimeControler_C = "/Game/WorldControlers/dayTimeControler.dayTimeControler_C",
    BP_WorldTimeAndConditions_C = "/Game/WorldControlers/BP_WorldTimeAndConditions.BP_WorldTimeAndConditions_C",
    gangManager_C = "/Game/WorldControlers/Gangs/gangManager.gangManager_C",
    ballenaClubManager_C = "/Game/WorldControlers/Gangs/ballenaClubManager.ballenaClubManager_C",
    populationManager_C = "/Game/Skeletal/NPC/StreetPopulation/populationManager.populationManager_C",
    contactsManager_C = "/Game/Player/Telephone/contactsManager.contactsManager_C",
    saleAreaManager_C = "/Game/TerritorySpraying/saleAreaManager.saleAreaManager_C",
    difficultyManager_C = "/Game/Difficulty/difficultyManager.difficultyManager_C",
    psychedelicGangManager_C = "/Game/PsychedelicGang/psychedelicGangManager.psychedelicGangManager_C",
}
local function slowSearch(className)
    local a = Core.profile and os.clock()
    local first = FindFirstOf(className)
    if a then Core.mark("search " .. className, os.clock() - a) end
    if Core.alive(first) then return first end
    for _, obj in ipairs(FindAllOf(className) or {}) do
        if Core.alive(obj) then return obj end
    end
    return nil
end

-- The living actors of a class given by path, without needing to know the player (this
-- is what finds the player). Second result: false when the class is not loaded at all
-- (then nothing of it exists), nil when the question could not be asked.
local gameViewport
local function quickActors(path)
    local class = StaticFindObject(path)
    if not Core.valid(class) then return nil, false end
    local gs, vp = Core.statics(), gameViewport()
    if not gs or not vp then return nil, nil end
    local out = {}
    if not pcall(function() gs:GetAllActorsOfClass(vp, class, out) end) then return nil, nil end
    local raw = out
    if #raw == 0 and type(out.OutActors) == "table" then raw = out.OutActors end
    local list = {}
    for _, a in ipairs(raw) do
        local actor = a
        if type(a) == "userdata" and a.IsValid == nil and a.get then
            local okg, v = pcall(function() return a:get() end)
            actor = okg and v or nil
        end
        if actor ~= nil and Core.alive(actor) then list[#list + 1] = actor end
    end
    return list, true
end

local function search(className)
    local path = classPath[className]
    if path then
        -- By path the answer is that of the world being played. (By name the engine also
        -- hands out what is left of the world before, while a load is under way.)
        local list, asked = quickActors(path)
        if asked ~= nil then return list and list[1] or nil end
    end
    local obj = slowSearch(className)
    if obj and not path then
        pcall(function()
            local actorClass = Core.object("/Script/Engine.Actor")
            if actorClass and obj:IsA(actorClass) then
                local full = obj:GetClass():GetFullName()
                classPath[className] = full:match("%s(/.+)$")
            end
        end)
    end
    return obj
end

gameViewport = function()
    if viewport ~= nil and viewport:IsValid() then return viewport end
    viewport = nil
    local engine = FindFirstOf("GameEngine")
    if not Core.valid(engine) then return nil end
    local ok, vp = pcall(function() return engine.GameViewport end)
    if ok and Core.valid(vp) then viewport = vp end
    return viewport
end
Core.viewport = gameViewport

-- The player's character, or nil at the main menu.
function Core.player()
    local vp, gs = gameViewport(), Core.statics()
    local controlled = 0
    if vp and gs then
        local ok, pawn = pcall(function() return gs:GetPlayerPawn(vp, 0) end)
        if ok and Core.valid(pawn) then
            local okc, name = pcall(function() return pawn:GetClass():GetFName():ToString() end)
            if okc and name == PLAYER_CLASS then
                slowPlayer = nil
                if Core.alive(pawn) then return pawn end
                return nil
            end
            controlled = pawn:GetAddress()
        end
    end
    -- No pawn, or another one is controlled (the intro, sitting on a bench, peeking out of
    -- a sewer exit, the main menu): search. The answer is kept for as long as that same
    -- pawn is controlled, five seconds at most (one second when there is no pawn at all).
    local now = os.clock()
    local s = slowPlayer
    if s and s.controlled == controlled and now - s.at < (controlled ~= 0 and 5 or 1) then
        if s.obj == nil then return nil end
        if Core.alive(s.obj) then return s.obj end
    end
    local obj = search(PLAYER_CLASS)
    slowPlayer = { obj = obj, at = now, controlled = controlled }
    return obj
end

-- Forgets what was looked up; for `seconds` afterwards results are trusted for one second
-- only (a load destroys the managers and creates new ones a few seconds later).
function Core.flush(seconds)
    found, missing, slowPlayer = {}, {}, nil
    if seconds then unsettledUntil = os.clock() + seconds end
end

function Core.find(className)
    if className == PLAYER_CLASS then return Core.player() end
    local now = os.clock()
    local player = Core.player()
    local owner = player and player:GetAddress() or 0
    local c = found[className]
    if c and c.owner == owner then
        local fresh = (owner ~= 0 and now >= unsettledUntil) or now - c.at < 1
        if fresh and Core.alive(c.obj) then return c.obj end
        found[className] = nil
    end
    local m = missing[className]
    if m and m.owner == owner and now - m.at < ((owner ~= 0 and now >= unsettledUntil) and 12 or 2) then return nil end
    local obj = search(className)
    if obj then
        found[className], missing[className] = { obj = obj, owner = owner, at = now }, nil
    else
        found[className], missing[className] = nil, { owner = owner, at = now }
    end
    return obj
end

-- A Blueprint class object, kept for as long as the same player character exists (its
-- class stays loaded while the world that uses it is).
local classes = {}

function Core.class(path)
    local player = Core.player()
    local owner = player and player:GetAddress() or 0
    local c = classes[path]
    if c and c.owner == owner and owner ~= 0 and c.obj:IsValid() then return c.obj end
    local obj = StaticFindObject(path)
    if not Core.valid(obj) then
        classes[path] = nil
        return nil
    end
    classes[path] = { obj = obj, owner = owner }
    return obj
end

-- Every living actor of a class (and its subclasses), asked from the engine's own list of
-- the world's actors: a fraction of a millisecond where FindAllOf takes 40. Returns nil
-- when that is not possible (the caller then falls back to FindAllOf).
function Core.actors(path)
    local class, gs, vp = Core.class(path), Core.statics(), gameViewport()
    if not class or not gs or not vp then return nil end
    local out = {}
    local ok = pcall(function() gs:GetAllActorsOfClass(vp, class, out) end)
    if not ok then return nil end
    local raw = out
    if #raw == 0 and type(out.OutActors) == "table" then raw = out.OutActors end
    local list = {}
    for _, a in ipairs(raw) do
        local actor = a
        if type(a) == "userdata" and a.IsValid == nil and a.get then
            local okg, v = pcall(function() return a:get() end)
            actor = okg and v or nil
        end
        if actor ~= nil and Core.alive(actor) then list[#list + 1] = actor end
    end
    return list
end

-- Switches the profiler on, including the three global lookups.
function Core.profileOn()
    Core.profile = {}
    if Core.profileWrapped then return end
    Core.profileWrapped = true
    for _, name in ipairs({ "FindFirstOf", "FindAllOf", "StaticFindObject" }) do
        local real = _G[name]
        _G[name] = function(...)
            if not Core.profile then return real(...) end
            local a = os.clock()
            local r = real(...)
            local arg = tostring((...))
            local took = os.clock() - a
            Core.mark(name .. " " .. (name == "StaticFindObject" and "(all)" or arg), took)
            if name == "StaticFindObject" then Core.mark("  lookup " .. (arg:match("[^/.:]+$") or arg), took) end
            return r
        end
    end
end

function Core.fileSize(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end") or 0
    f:close()
    return size
end

-- True when the given sync feature is switched on in config.lua (default on).
function Core.enabled(feature)
    local sync = Core.config.Sync
    return not sync or sync[feature] ~= false
end

---------------------------------------------------------------- hooks

-- Blueprint classes can be loaded late and reloaded between sessions, so each hook is
-- (re)registered whenever its function object appears or changes.
local Hooks = { list = {} }
Core.Hooks = Hooks

-- fn(context, params...) is called for every call of the Blueprint function at `path`.
-- UE4SS runs it after the function has returned on this engine version.
function Hooks.add(path, fn, onRegistered)
    Hooks.list[#Hooks.list + 1] = { path = path, fn = fn, onRegistered = onRegistered }
end

local function ensureOne(h)
    local fn = StaticFindObject(h.path)
    if not Core.valid(fn) then return end
    local addr = fn:GetAddress()
    if h.addr == addr then return end
    -- the registration made for the function object of an earlier world goes first
    if h.pre ~= nil and UnregisterHook then pcall(UnregisterHook, h.path, h.pre, h.post) end
    h.pre, h.post = nil, nil
    h.gen = (h.gen or 0) + 1
    local gen = h.gen
    local callback = function(...)
        if h.gen ~= gen then return end
        local ok, e = xpcall(h.fn, debug.traceback, ...)
        if not ok then Core.log("Hook error in %s: %s", h.path, tostring(e)) end
    end
    local ok, pre, post = pcall(RegisterHook, h.path, callback, function() end)
    if ok then
        h.addr = addr
        if type(pre) == "number" then h.pre, h.post = pre, post end
        if h.onRegistered then pcall(h.onRegistered) end
        Core.vlog("Hooked %s", h.path)
    else
        Core.log("Could not hook %s: %s", h.path, tostring(pre))
    end
end

-- Looking a function up costs several milliseconds, so only a few hooks are looked at per
-- call: every hook twice over after the world has changed (classes are loaded again then),
-- otherwise one of the hooks that could not be registered yet.
local cursor, round, lastOwner, lastWaiting = 0, 0, nil, 0

function Hooks.ensure()
    local n = #Hooks.list
    if n == 0 then return end
    local player = Core.player()
    local owner = player and player:GetAddress() or 0
    if owner ~= lastOwner then
        lastOwner = owner
        round = n * 2
    end
    if round > 0 then
        for _ = 1, math.min(2, round) do
            cursor = cursor % n + 1
            round = round - 1
            ensureOne(Hooks.list[cursor])
        end
        return
    end
    local now = os.clock()
    if now - lastWaiting < 4 then return end
    lastWaiting = now
    for _ = 1, n do
        cursor = cursor % n + 1
        local h = Hooks.list[cursor]
        if not h.addr then
            ensureOne(h)
            return
        end
    end
end

---------------------------------------------------------------- timers and tick

local timers = {}
local tickers = {}

function Core.every(seconds, fn)
    timers[#timers + 1] = { interval = seconds, at = os.clock() + seconds, fn = fn }
end

function Core.after(seconds, fn)
    timers[#timers + 1] = { at = os.clock() + seconds, fn = fn }
end

-- fn(dt) runs on every main tick (about 30 times a second) on the game thread.
function Core.onTick(fn)
    tickers[#tickers + 1] = fn
end

local lastTick = os.clock()

function Core.where(fn)
    local i = debug.getinfo(fn, "S")
    return (i.short_src:match("[^/\\]+$") or "?") .. ":" .. tostring(i.linedefined)
end

function Core.runTick()
    local now = os.clock()
    local dt = now - lastTick
    lastTick = now
    local profiling = Core.profile ~= nil
    for _, fn in ipairs(tickers) do
        local a = profiling and os.clock()
        local ok, e = xpcall(fn, debug.traceback, dt)
        if a then Core.mark("tick " .. Core.where(fn), os.clock() - a) end
        if not ok then Core.log("Tick error: %s", tostring(e)) end
    end
    if profiling then Core.mark("WHOLE TICK (tickers)", os.clock() - now) end
    local i = 1
    while i <= #timers do
        local t = timers[i]
        if now >= t.at then
            if t.interval then t.at = now + t.interval else table.remove(timers, i) i = i - 1 end
            local a = profiling and os.clock()
            local ok, e = xpcall(t.fn, debug.traceback)
            if a then Core.mark((t.interval and "every " or "after ") .. Core.where(t.fn), os.clock() - a) end
            if not ok then Core.log("Timer error: %s", tostring(e)) end
        end
        i = i + 1
    end
end

return Core
