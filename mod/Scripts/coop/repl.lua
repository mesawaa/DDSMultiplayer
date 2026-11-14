-- State replication primitives for co-op.
--
-- The game marks every piece of persistent state: each stateful actor carries a
-- RamaSaveComponent listing the variables its save file stores. This module can
--   * export those variables as Unreal property text (written here, type by type),
--   * import such text on the other side through the engine's own ImportText,
--   * name an actor in a way both games agree on (save GUID, else class + position).
-- Higher layers (coop/sync.lua) decide when to send what.

local Core = require("core")
local Net = require("net")

local log, valid = Core.log, Core.valid

local Repl = {}

-- Keys of objects this game destroyed because another game said so (not to be reported back).
Repl.remoteGone = {}

local RAMA_CLASS = "/Script/RamaSaveSystem.RamaSaveComponent"

---------------------------------------------------------------- property text export

local function typeName(prop)
    return prop:GetClass():GetFName():ToString()
end

local function quote(s)
    return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

local function number(v)
    if type(v) ~= "number" then return "0" end
    if v ~= v or v == math.huge or v == -math.huge then return "0" end
    if math.type(v) == "integer" or v % 1 == 0 and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.9g", v)
end

-- Only assets can be named across machines; references to live actors or widgets cannot.
local function assetPath(obj)
    if not valid(obj) then return "None" end
    local full = obj:GetFullName()
    local class, path = full:match("^(%S+)%s+(.+)$")
    if not path or path:find(":", 1, true) or not (path:find("^/Game/") or path:find("^/Script/") or path:find("^/Engine/")) then
        return nil
    end
    return class .. "'" .. path .. "'"
end

local exporterFor   -- forward

local structExporters = {}

local function structExporter(struct)
    local key = struct:GetFullName()
    local cached = structExporters[key]
    if cached ~= nil then return cached or nil end
    local fields = {}
    local supported = true
    struct:ForEachProperty(function(p)
        local ex = exporterFor(p)
        if not ex then supported = false end
        fields[#fields + 1] = { name = p:GetFName():ToString(), ex = ex }
    end)
    local fn = supported and function(v)
        local parts = {}
        for i, f in ipairs(fields) do
            local text = f.ex(v[f.name])
            if text == nil then return nil end
            -- "()" would import as one default element (engine quirk); a field left out
            -- of the text keeps its default, which for a fresh element is the empty array.
            if text ~= "()" then parts[#parts + 1] = f.name .. "=" .. text end
        end
        return "(" .. table.concat(parts, ",") .. ")"
    end or false
    structExporters[key] = fn
    return fn or nil
end

-- Returns a function value -> text for the property, or nil if the type is unsupported.
exporterFor = function(prop)
    local t = typeName(prop)
    if t == "IntProperty" or t == "FloatProperty" or t == "ByteProperty" or t == "Int64Property"
        or t == "UInt32Property" or t == "Int16Property" or t == "UInt16Property" or t == "Int8Property"
        or t == "DoubleProperty" or t == "EnumProperty" then
        return number
    elseif t == "BoolProperty" then
        return function(v) return v and "True" or "False" end
    elseif t == "StrProperty" or t == "NameProperty" or t == "TextProperty" then
        return function(v) return quote(v:ToString()) end
    elseif t == "ObjectProperty" or t == "ClassProperty" then
        return assetPath
    elseif t == "StructProperty" then
        return structExporter(prop:GetStruct())
    elseif t == "ArrayProperty" then
        local inner = exporterFor(prop:GetInner())
        if not inner then return nil end
        return function(arr)
            local parts, bad = {}, false
            arr:ForEach(function(_, elem)
                local text = inner(elem:get())
                if text == nil then bad = true else parts[#parts + 1] = text end
            end)
            if bad then return nil end
            return "(" .. table.concat(parts, ",") .. ")"
        end
    end
    return nil
end

---------------------------------------------------------------- per-class property tables

local classProps = {}   -- class address -> name -> { prop, export }

local function propsOf(obj)
    local class = obj:GetClass()
    local addr = class:GetAddress()
    local className = class:GetFName():ToString()
    local cached = classProps[addr]
    if cached and cached.class == className then return cached.map end
    local map = {}
    local c = class
    for _ = 1, 12 do
        if not valid(c) then break end
        pcall(function()
            c:ForEachProperty(function(p)
                local name = p:GetFName():ToString()
                local key = name:lower()
                if not map[key] then
                    local ok, ex = pcall(exporterFor, p)
                    map[key] = { prop = p, name = name, export = ok and ex or nil }
                end
            end)
        end)
        local ok, super = pcall(function() return c:GetSuperStruct() end)
        if not ok then break end
        c = super
    end
    classProps[addr] = { class = className, map = map }
    return map
end

-- A name of the form "Component.Variable" refers to a variable of one of the actor's
-- components. Returns the object that holds the variable and the variable's own name.
local function resolve(obj, name)
    local comp, var = name:match("^([%w_]+)%.([%w_]+)$")
    if not comp then return obj, name end
    local ok, sub = pcall(function() return obj[comp] end)
    if ok and valid(sub) then return sub, var end
    return nil, var
end

-- Exports the named variables of obj. Returns name -> text; unsupported or unreadable
-- variables are left out. Names are matched without regard to case, like the game's own
-- save system does (its lists say "quantity" where the property is "Quantity").
function Repl.export(obj, names)
    local out = {}
    for _, name in ipairs(names) do
        local holder, var = resolve(obj, name)
        local entry = holder and propsOf(holder)[var:lower()] or nil
        if entry and entry.export then
            local ok, text = pcall(function() return entry.export(holder[entry.name]) end)
            if ok and text ~= nil then out[name] = text end
        end
    end
    return out
end

-- Sets variables of obj from name -> text. Returns how many were applied.
function Repl.import(obj, values)
    local applied = 0
    for name, text in pairs(values) do
        local holder, var = nil, nil
        if type(name) == "string" then holder, var = resolve(obj, name) end
        local entry = holder and propsOf(holder)[var:lower()] or nil
        if entry and type(text) == "string" then
            local ok, e = pcall(function()
                if text == "()" then
                    holder[entry.name]:Empty()   -- importing "()" would leave one default element
                else
                    -- 2 = PPF_Delimited: top-level strings are quoted like nested ones
                    entry.prop:ImportText(text, entry.prop:ContainerPtrToValuePtr(holder), 2, holder)
                end
            end)
            if ok then applied = applied + 1 else log("Import of %s failed: %s", name, tostring(e)) end
        end
    end
    return applied
end

-- Imports text into one variable exactly as given (also works for maps and sets).
function Repl.importRaw(obj, name, text)
    local entry = propsOf(obj)[name:lower()]
    if not entry then return false end
    return pcall(function() entry.prop:ImportText(text, entry.prop:ContainerPtrToValuePtr(obj), 2, obj) end)
end

---------------------------------------------------------------- save component helpers

local ramaClass = nil

function Repl.ramaComponent(actor)
    if not valid(ramaClass) then ramaClass = StaticFindObject(RAMA_CLASS) end
    local comp = actor:GetComponentByClass(ramaClass)
    if valid(comp) then return comp end
    return nil
end

local varListCache = {}   -- class address -> list of saved variable names

-- Components that keep saved state of their own. Each lists its variables in "RamaVars".
-- What a container holds lives in its inventory component, not on the container itself.
local STATEFUL_COMPONENTS = { "InventoryComponent" }

-- The variables the game's save system stores for this actor.
function Repl.savedVars(actor)
    local class = actor:GetClass()
    local addr = class:GetAddress()
    local className = class:GetFName():ToString()
    local cached = varListCache[addr]
    if cached and cached.class == className then return cached.list end
    local list = {}
    local comp = Repl.ramaComponent(actor)
    if comp then
        local seen = {}
        comp.RamaSave_OwningActorVarsToSave:ForEach(function(_, e)
            local name = e:get():ToString()
            if not seen[name] then
                seen[name] = true
                list[#list + 1] = name
            end
        end)
    end
    if comp then
        for _, compName in ipairs(STATEFUL_COMPONENTS) do
            pcall(function()
                local sub = actor[compName]
                if not valid(sub) then return end
                sub.RamaVars:ForEach(function(_, e)
                    local name = compName .. "." .. e:get():ToString()
                    if not list.seen then list.seen = {} end
                    if not list.seen[name] then
                        list.seen[name] = true
                        list[#list + 1] = name
                    end
                end)
            end)
        end
        list.seen = nil
    end
    -- An actor that is still being set up has no save component yet; ask again later.
    if comp then varListCache[addr] = { class = className, list = list } end
    return list
end

---------------------------------------------------------------- actor identity

local keyOf = setmetatable({}, { __mode = "k" })   -- address -> key (per world)
local forcedKey = {}    -- address -> key given by Repl.adopt (objects created during play)
local byKey = {}
local entries = {}      -- list of { actor, key, class, x, y, z } from the last scan
local registryWorld = nil
local lastScan = 0

local function positionKey(actor)
    local loc = actor:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", actor:GetClass():GetFName():ToString(),
        math.floor(loc.X + 0.5), math.floor(loc.Y + 0.5), math.floor(loc.Z + 0.5))
end

-- A name for the actor that is the same in both games: the save system's persistent GUID
-- when it has one, else class and position (level-placed actors do not move).
function Repl.key(actor)
    local addr = actor:GetAddress()
    local forced = forcedKey[addr]
    if forced then return forced end
    local cached = keyOf[addr]
    if cached then return cached end
    local key
    local comp = Repl.ramaComponent(actor)
    if comp then
        local g = comp.RamaSave_PersistentActorUniqueID
        if g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0 then
            key = string.format("g:%x-%x-%x-%x", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
        end
    end
    key = key or ("p:" .. positionKey(actor))
    keyOf[addr] = key
    return key
end

-- The key an actor has by itself (what a game that loads it from a save calls it),
-- whatever key it was given during play.
function Repl.naturalKey(actor)
    local comp = Repl.ramaComponent(actor)
    if comp then
        local g = comp.RamaSave_PersistentActorUniqueID
        if g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0 then
            return string.format("g:%x-%x-%x-%x", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
        end
    end
    return "p:" .. positionKey(actor)
end

-- The actors that were given a key during play: a flat list natural key, given key, ...
function Repl.aliases()
    local out = {}
    for key, actor in pairs(byKey) do
        if key:sub(1, 2) == "d:" and Core.alive(actor) and forcedKey[actor:GetAddress()] == key then
            local ok, natural = pcall(Repl.naturalKey, actor)
            if ok and natural then out[#out + 1], out[#out + 2] = natural, key end
        end
    end
    return out
end

local missing = {}      -- key -> when a rescan last failed to find it

local function rescan()
    local started = Core.profile and os.clock()
    byKey, entries = {}, {}
    keyOf = setmetatable({}, { __mode = "k" })
    local comps = FindAllOf("RamaSaveComponent") or {}
    for _, comp in ipairs(comps) do
        pcall(function()
            local owner = comp:GetOwner()
            if Core.alive(owner) then
                local key = Repl.key(owner)
                local loc = owner:K2_GetActorLocation()
                byKey[key] = owner
                entries[#entries + 1] = { actor = owner, key = key, class = owner:GetClass():GetFName():ToString(),
                    x = loc.X, y = loc.Y, z = loc.Z }
            end
        end)
    end
    lastScan = os.clock()
    if started then Core.mark("registry rescan (" .. #entries .. " objects)", os.clock() - started) end
    return #entries
end

-- Gives an actor created during play the key both games agreed on, and makes it known
-- to the registry right away.
function Repl.adopt(actor, key)
    local address = actor:GetAddress()
    forcedKey[address] = key
    byKey[key] = actor
    missing[key] = nil
    -- an actor the registry knows already (one loaded from a save) just changes its name
    for _, e in ipairs(entries) do
        local same = false
        pcall(function() same = e.actor:GetAddress() == address end)
        if same then
            e.key = key
            return
        end
    end
    local loc = actor:K2_GetActorLocation()
    entries[#entries + 1] = { actor = actor, key = key, class = actor:GetClass():GetFName():ToString(),
        x = loc.X, y = loc.Y, z = loc.Z }
end

-- Splits the text of an array property "(a,b,(c,d),"e,f")" into its element texts.
function Repl.splitArray(text)
    local out = {}
    if type(text) ~= "string" or #text < 2 or text == "()" then return out end
    local depth, inQuote, start = 0, false, 2
    local i, n = 2, #text - 1
    while i <= n do
        local c = text:sub(i, i)
        if inQuote then
            if c == "\\" then i = i + 1 elseif c == '"' then inQuote = false end
        elseif c == '"' then
            inQuote = true
        elseif c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
        elseif c == "," and depth == 0 then
            out[#out + 1] = text:sub(start, i - 1)
            start = i + 1
        end
        i = i + 1
    end
    out[#out + 1] = text:sub(start, n)
    return out
end

function Repl.joinArray(elements)
    return "(" .. table.concat(elements, ",") .. ")"
end

-- Every actor with saved state found by the last scan (rescans when stale).
function Repl.registry(maxAge)
    if #entries == 0 or os.clock() - lastScan > (maxAge or 20) then rescan() end
    return entries
end

-- Finds the local actor for a key, rescanning the world when it is not known yet. A key
-- that a rescan did not find is not searched for again for a while: a rescan walks every
-- saved object of the world.
function Repl.find(key)
    local actor = byKey[key]
    if Core.alive(actor) then return actor end
    local now = os.clock()
    if now - lastScan > 3 and (not missing[key] or now - missing[key] > 20) then
        rescan()
        actor = byKey[key]
        if Core.alive(actor) then
            missing[key] = nil
            return actor
        end
        missing[key] = now
    end
    return nil
end

-- The local actor for a key if the registry has it (never searches).
function Repl.known(key)
    local actor = byKey[key]
    if Core.alive(actor) then return actor end
    return nil
end

-- Singletons (managers) are found by class instead of key.
local singletons = {}
function Repl.singleton(className)
    local obj = singletons[className]
    if Core.alive(obj) then return obj end
    obj = Core.find(className)
    singletons[className] = obj
    return obj
end

-- Call when a new world has been loaded.
function Repl.reset()
    byKey, singletons, lastScan, entries, forcedKey = {}, {}, 0, {}, {}
    keyOf = setmetatable({}, { __mode = "k" })
    missing = {}
    -- what was learned about the classes of the world before goes too: after a load a
    -- class can be another object at the same address
    classProps = {}
end

function Repl.rescan() return rescan() end

---------------------------------------------------------------- big messages

-- Like Net.send, but payloads too large for one frame travel as a file.
-- The same message to several players: put into words once.
function Repl.sendMany(messageType, data, targets)
    if #targets == 0 then return end
    if #targets == 1 then return Repl.send(messageType, data, targets[1]) end
    data.t = messageType
    local text = Net.json.encode(data)
    if #text <= 2400 then
        for _, id in ipairs(targets) do Net.command("MSG " .. id .. " " .. text) end
        return true
    end
    for _, id in ipairs(targets) do Repl.send(messageType, data, id) end
    return true
end

function Repl.send(messageType, data, target)
    data.t = messageType
    local text = Net.json.encode(data)
    if #text <= 2400 then
        return Net.command("MSG " .. (target or "*") .. " " .. text)
    end
    local path = Net.ipcDir() .. "/out_" .. tostring(os.clock()):gsub("%.", "") .. "_" .. tostring(math.random(1e6)) .. ".json"
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    Net.sendFile("big", path, target)
    Core.after(30, function() os.remove(path) end)
    return true
end

local bigHandlers = {}

-- Registers a handler that receives the message whether it came small or as a file.
function Repl.on(messageType, fn)
    bigHandlers[messageType] = fn
    Net.on(messageType, fn)
end

Net.onFile("big", function(sender, path)
    local f = io.open(path, "rb")
    if not f then return end
    local text = f:read("a")
    f:close()
    local data = Net.json.decode(text)
    if type(data) ~= "table" or not bigHandlers[data.t] then return end
    bigHandlers[data.t](sender, data, Net.name(sender))
end)

return Repl
