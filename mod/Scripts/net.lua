-- Networking for DDS Multiplayer: talks to the bridge DLL through files (see
-- steam-bridge/src/lib.rs for the protocol) and offers typed messages, file transfer and
-- a small per-player state stream to the rest of the mod.
--
-- Everything here runs on the game thread (Net.poll is called from the main tick).

local json = require("json")

local Net = {}

local PROTOCOL = 28         -- 28: v0.19.6 drug labs are one for everybody (a game without that would run its own)
local VERSION = "?"
pcall(function() VERSION = require("core").VERSION end)

-- Shared session state, also read by the UI.
local S = {
    ready = false,
    me = nil,            -- our id as a string
    myName = "?",
    lobby = nil,
    owner = nil,         -- id of the lobby owner (the host)
    members = {},        -- id -> name, includes us
    memberCount = 0,
    links = {},          -- peer id -> "p2p" | "lobby" | "local"
    peerProto = {},      -- peer id -> protocol number from its hello
    peerVersion = {},    -- peer id -> mod version from its hello (nil before v0.8.5)
    notice = nil,        -- { text, at } last user-facing message
    banned = {},         -- host: id -> name of the players removed from this lobby
    kickedFrom = {},     -- lobby id -> true: the host of that lobby removed us
}
Net.S = S
Net.json = json
Net.PROTOCOL, Net.VERSION = PROTOCOL, VERSION

-- false when a peer is known to run another protocol, true when known to match, nil
-- before its hello has arrived.
function Net.compatible(id)
    local p = S.peerProto[id]
    if p == nil then return nil end
    return p == PROTOCOL
end

local dir, cmdPath, evtPath, posOutPath, posInPath
local evtOffset = 0
local log = function() end
local handlers = {}        -- message type -> fn(senderId, data, senderName)
local fileHandlers = {}    -- tag prefix -> fn(senderId, path, tag)
local listeners = { lobby = {}, left = {}, joined = {}, gone = {}, notice = {}, ready = {} }
local lastPosOut = nil
local fileSeq = 0

local function fire(kind, ...)
    for _, fn in ipairs(listeners[kind]) do
        local ok, e = pcall(fn, ...)
        if not ok then log("Listener %s failed: %s", kind, tostring(e)) end
    end
end

local function split(s, sep)
    local out = {}
    local pattern = "(.-)" .. sep:gsub("%p", "%%%0")
    for part in (s .. sep):gmatch(pattern) do out[#out + 1] = part end
    return out
end

-- The link's four files are kept open. Opening and closing them a hundred times a second
-- is what a virus scanner looks at every time; with an eager one that alone slows the game
-- down. A handle is renewed every few seconds, in case the file was replaced.
local handles = {}     -- path -> { f = file, at = when it was opened }

local function handle(path, mode, fallback)
    local now = os.clock()
    local h = handles[path]
    if h and now - h.at < 5 then return h.f end
    if h then pcall(function() h.f:close() end) end
    handles[path] = nil
    local f = io.open(path, mode)
    if not f and fallback then f = io.open(path, fallback) end
    if not f then return nil end
    handles[path] = { f = f, at = now }
    return f
end

local function closeHandles()
    for _, h in pairs(handles) do pcall(function() h.f:close() end) end
    handles = {}
end

function Net.command(line)
    if not cmdPath then return false end
    local f = handle(cmdPath, "ab")
    if not f then return false end
    local ok = pcall(function()
        f:write(line, "\n")
        f:flush()
    end)
    if not ok then handles[cmdPath] = nil end
    return ok
end

local function readEvents()
    local f = handle(evtPath, "rb")
    if not f then return {} end
    local size = f:seek("end") or 0
    if size < evtOffset then evtOffset = 0 end
    if size == evtOffset then return {} end
    f:seek("set", evtOffset)
    local data = f:read(size - evtOffset) or ""
    local lastNl = data:match(".*()\n")
    if not lastNl then return {} end
    evtOffset = evtOffset + lastNl
    local lines = {}
    for line in data:sub(1, lastNl):gmatch("([^\r\n]+)") do lines[#lines + 1] = line end
    return lines
end

---------------------------------------------------------------- public API

function Net.on(messageType, fn) handlers[messageType] = fn end
function Net.onFile(tagPrefix, fn) fileHandlers[tagPrefix] = fn end
-- Other events of the bridge (the music player's: coop/music.lua): fn(fields), fields[1]
-- being the event's name.
local eventHandlers = {}
function Net.onEvent(kind, fn) eventHandlers[kind] = fn end
-- kinds: "ready"(), "lobby"(kind), "left"(), "joined"(id, name), "gone"(id, name), "notice"(text)
function Net.listen(kind, fn) table.insert(listeners[kind], fn) end

function Net.inLobby() return S.lobby ~= nil end
function Net.isHost() return S.lobby ~= nil and S.owner ~= nil and S.owner == S.me end
function Net.isGuest() return S.lobby ~= nil and S.owner ~= nil and S.owner ~= S.me end

function Net.peers()
    local out = {}
    for id in pairs(S.members) do
        if id ~= S.me then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

function Net.hasPeers() return S.lobby ~= nil and S.memberCount > 1 end

function Net.name(id) return S.members[id] or tostring(id) end

-- Sends a typed message to one peer (id) or to everyone (target nil). Messages must stay
-- small (a few kB); use sendFile for anything bigger.
function Net.send(messageType, data, target)
    if not S.lobby then return false end
    data = data or {}
    data.t = messageType
    return Net.command("MSG " .. (target or "*") .. " " .. json.encode(data))
end

-- Sends a file; the receiver's handler for the tag prefix gets the path of its copy.
function Net.sendFile(tagPrefix, path, target)
    if not S.lobby then return false end
    fileSeq = fileSeq + 1
    return Net.command(string.format("FILE %s %s-%d %s", target or "*", tagPrefix, fileSeq, path))
end

-- Publishes this player's state line (position etc.); sent unreliably when it changes.
function Net.setLocalState(line)
    if line == lastPosOut or not posOutPath then return end
    -- written over the line before; the bridge reads up to the first line end
    local f = handle(posOutPath, "r+b", "wb")
    if not f then return end
    local ok = pcall(function()
        f:seek("set", 0)
        f:write(line, "\n")
        f:flush()
    end)
    if not ok then
        handles[posOutPath] = nil
        return
    end
    lastPosOut = line
end

-- Returns id -> latest state line for every peer, or nil if nothing readable right now.
function Net.peerStates()
    local f = handle(posInPath, "rb")
    if not f then return nil end
    f:seek("set", 0)
    local data = f:read("a") or ""
    if not data:find("END\n$") then return nil end
    local out = {}
    for id, line in data:gmatch("(%d+)\t([^\n]*)\n") do out[id] = line end
    return out
end

function Net.notify(text)
    log("%s", text)
    S.notice = { text = text, at = os.time() }
    fire("notice", text)
end

function Net.ipcDir() return dir end

---------------------------------------------------------------- removing a player

-- Host: removes a player from the lobby. Everybody is told: the player's own game leaves,
-- the others stop listening to it. (BAN is for a bridge that can stop listening to a
-- player; the installed one ignores it, and then the message alone does it.) An older
-- version of the mod does not leave by itself.
function Net.kick(id)
    id = tostring(id)
    if not Net.isHost() or id == S.me or not S.members[id] or S.banned[id] then return false end
    local name = S.members[id]
    local lobby = S.lobby
    S.banned[id] = name
    Net.send("kick", { id = id })
    local ok, Core = pcall(require, "core")
    if ok and type(Core) == "table" and Core.after then
        Core.after(1.5, function()
            if S.lobby == lobby and S.banned[id] then Net.command("BAN " .. id) end
        end)
    else
        Net.command("BAN " .. id)
    end
    Net.notify(name .. " was removed from the lobby")
    return true
end

---------------------------------------------------------------- events from the bridge

local function onMessage(senderId, senderName, payload)
    local data, e = json.decode(payload)
    if type(data) ~= "table" or type(data.t) ~= "string" then
        log("Bad message from %s: %s", senderName, tostring(e))
        return
    end
    local fn = handlers[data.t]
    if not fn then return end
    local ok, err = xpcall(fn, debug.traceback, senderId, data, senderName)
    if not ok then log("Handler %s failed: %s", data.t, tostring(err)) end
end

local function onEvent(line)
    local f = split(line, "\t")
    local kind = f[1]
    if kind == "READY" then
        local first = not S.ready
        S.ready, S.me, S.myName = true, f[2], f[3] or "?"
        if first then
            log("Bridge ready as %s", S.myName)
            fire("ready")
        end
    elseif kind == "LOBBY" then
        local isNew = S.lobby ~= f[2]
        S.lobby, S.owner = f[2], f[4]
        if isNew then
            S.banned = {}
            fire("lobby", f[3])
            -- (a Steam invite or "Join game" leads past Net.joinLobby: a lobby whose host
            -- removed us is left again at once)
            if f[3] == "joined" and S.kickedFrom[f[2]] then
                Net.command("LEAVE")
                Net.notify("The host removed you from that lobby.")
            end
        end
    elseif kind == "MEMBERS" then
        local old = S.members
        S.members, S.memberCount = {}, tonumber(f[2]) or 0
        for i = 4, #f do
            local id, name = f[i]:match("^(%d+)=(.*)$")
            if id then S.members[id] = name end
        end
        -- Who left is told first, while the lobby's owner is still the one it was: when
        -- the host goes, Steam hands the lobby to somebody else in the same breath, and
        -- "the host left" must not be mistaken for "a guest left".
        for id, name in pairs(old) do
            if not S.members[id] and id ~= S.me then
                S.links[id], S.peerProto[id], S.peerVersion[id] = nil, nil, nil
                fire("gone", id, name)
            end
        end
        S.owner = f[3] or S.owner
        for id, name in pairs(S.members) do
            if not old[id] and id ~= S.me then
                Net.send("hello", { proto = PROTOCOL, v = VERSION }, id)
                -- a newcomer learns whom the host has removed (they may still be in the
                -- Steam lobby, and nobody is to listen to them)
                if Net.isHost() and next(S.banned) then
                    local ids = {}
                    for b in pairs(S.banned) do ids[#ids + 1] = b end
                    Net.send("bans", { ids = ids }, id)
                end
                fire("joined", id, name)
            end
        end
    elseif kind == "MSG" then
        onMessage(f[2] or "?", f[3] or "?", f[4] or "")
    elseif kind == "FILE" then
        local tag = f[3] or ""
        local prefix = tag:match("^(.-)%-%d+$") or tag
        local fn = fileHandlers[prefix]
        if fn then
            local ok, err = xpcall(fn, debug.traceback, f[2], f[4], tag)
            if not ok then log("File handler %s failed: %s", prefix, tostring(err)) end
        end
        if f[4] then os.remove(f[4]) end
    elseif kind == "LINK" then
        S.links[f[2] or "?"] = f[3]
        log("Link to %s: %s", Net.name(f[2]), tostring(f[3]))
    elseif kind == "LEFT" then
        local was = S.lobby
        local old = S.members
        S.lobby, S.owner, S.members, S.memberCount, S.links = nil, nil, {}, 0, {}
        S.peerProto, S.peerVersion = {}, {}
        S.banned = {}
        if was then
            for id, name in pairs(old) do
                if id ~= S.me then fire("gone", id, name) end
            end
            fire("left")
            -- (said after everything leaving says, so that it is what stays on screen)
            if S.kickedAt and os.time() - S.kickedAt < 10 then
                S.kickedAt = nil
                Net.notify("The host removed you from the lobby.")
            end
        end
    elseif kind == "ERR" then
        Net.notify("Error: " .. (f[2] or "?"))
    elseif kind == "INFO" then
        Net.notify(f[2] or "")
    elseif eventHandlers[kind] then
        local ok, err = xpcall(eventHandlers[kind], debug.traceback, f)
        if not ok then log("Event %s failed: %s", kind, tostring(err)) end
    end
end

Net.on("hello", function(sender, data, name)
    S.peerProto[sender] = tonumber(data.proto) or 0
    S.peerVersion[sender] = type(data.v) == "string" and data.v or nil
    if data.proto ~= PROTOCOL then
        Net.notify(string.format("%s has mod version %s, you have %s: both players need the same version",
            name, S.peerVersion[sender] or "older", VERSION))
    end
end)

-- The host removes a player: that player's game leaves the lobby, everybody else stops
-- listening to it.
Net.on("kick", function(sender, data)
    if sender ~= S.owner or sender == S.me then return end
    local id = tostring(data.id or "")
    if id == S.me then
        S.kickedAt = os.time()
        if S.lobby then S.kickedFrom[S.lobby] = true end
        Net.command("LEAVE")
    elseif id:match("^%d+$") then
        Net.command("BAN " .. id)
    end
end)

-- Whom the host removed before we came.
Net.on("bans", function(sender, data)
    if sender ~= S.owner or sender == S.me or type(data.ids) ~= "table" then return end
    for _, id in ipairs(data.ids) do
        id = tostring(id)
        if id ~= S.me and id:match("^%d+$") then Net.command("BAN " .. id) end
    end
end)

---------------------------------------------------------------- lifecycle

-- Loads the bridge. `instance` selects the ipc directory (nil for the default).
function Net.start(modDir, instance, logger)
    log = logger or log
    dir = modDir .. "/" .. (instance and ("ipc_" .. instance) or "ipc")
    cmdPath, evtPath = dir .. "/cmd.txt", dir .. "/evt.txt"
    posOutPath, posInPath = dir .. "/pos_out.txt", dir .. "/pos_in.txt"
    closeHandles()
    local loaded, err = package.loadlib(modDir .. "/bin/ddsmp_steam.dll", "*")
    if not loaded then
        log("Could not load the bridge: %s", tostring(err))
        return false
    end
    -- On a fresh load the bridge has just emptied its files. After a Lua hot reload it is
    -- still running, so skip old events and ask it to repeat its state.
    local f = io.open(evtPath, "rb")
    if f then
        evtOffset = f:seek("end") or 0
        f:close()
    end
    Net.command("STATE")
    return true
end

-- What arrives is worked through in order, a few milliseconds' worth per tick: a burst
-- (a guest arriving, a crowd of NPCs announced at once) is spread over the next ticks
-- instead of stopping the game for its whole length.
local backlog = {}
Net.BUDGET = 0.006

function Net.poll()
    if not evtPath then return end
    for _, line in ipairs(readEvents()) do backlog[#backlog + 1] = line end
    local count = #backlog
    if count == 0 then return end
    local budget = count > 600 and 0.03 or Net.BUDGET        -- far behind: catch up
    local started, done = os.clock(), 0
    for i = 1, count do
        local ok, e = xpcall(onEvent, debug.traceback, backlog[i])
        if not ok then log("Event failed: %s", tostring(e)) end
        done = i
        if os.clock() - started >= budget then break end
    end
    if done >= count then
        backlog = {}
    else
        local rest = {}
        for i = done + 1, count do rest[#rest + 1] = backlog[i] end
        backlog = rest
    end
end

function Net.backlog() return #backlog end

return Net
