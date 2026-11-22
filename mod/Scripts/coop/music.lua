-- The music addon (an optional download of its own: this file and bin/ddsmp_audio.dll), on
-- whenever it is installed: the player's own music files (mp3, wav) in the mod's Music
-- folder join the game's music: the street music of the city's areas and the club's. Files
-- in a folder named after an area ("Stink", "Bad asia", ...) play in that area only.
--
-- The game cannot load a sound file while it runs, so the addon's DLL (audio-addon in the
-- source) decodes and plays them; this module places the sound: each area plays one
-- track at a time on one of its street speakers (musicAreaPlaylist), and a track of ours
-- that an area picks is heard from that speaker, as loud as the game's own would be there
-- (the speaker's own fall-off, the area's loudness, the game's music volume), louder in the
-- ear on the speaker's side.
--
-- Nothing of the game's is replaced: when an area starts a track, one of ours takes its
-- place with the chance one more track in its list would have. Each track can be given to
-- some areas only (the MUSIC page of MOD OPTIONS); a track nobody has set goes to all.
-- The club's music (coop/casino.lua) is picked by the host from the game's tracks and the
-- host's own; Edwin (coop/edwin.lua) can put one of the host's on.
--
-- In co-op the guests get the host's files (once, into Music/_from_host): the host's
-- tracks are then in their areas too, with the host's choice of areas, and the club plays
-- the same song for everybody. A guest's own files play in the guest's own game.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")
local Hud = require("coop.hud")
local Screen = require("coop.screen")
local json = require("json")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_MUSIC_GEN") or 0) + 1
_G.DDSMP_MUSIC_GEN = GEN
local function live() return rawget(_G, "DDSMP_MUSIC_GEN") == GEN end

local Music = {}

local DIR = Core.MOD_DIR .. "/Music"
local CACHE = DIR .. "/_from_host"
local SETTINGS = DIR .. "/music.json"
Music.DIR = DIR

-- How loud a file plays at full VOLUME (the MUSIC page's slider) against the game's own
-- tracks at the same place. The slider counts squared, as the ear hears: half way is a
-- quarter of this.
Music.LEVEL = 0.5
local DEFAULT_VOLUME = 0.35

local CLUB = "PLAYLIST-BALLENA"
-- The game's music areas, named as Shady Comm names the places, with how many tracks of
-- the game's each has (PlaylistDatabase), and the folder names that mean them. The game has
-- one music area for the old town (West and East) and one for the three parts of deadtown;
-- the Eastern slums have none.
Music.AREAS = {
    { id = "PLAYLIST-EASTOLD", name = "OLD TOWN", games = 10, folders = { "Old town", "West old town", "East old town", "Oldtown" } },
    { id = "PLAYLIST-TWOTOWERS", name = "TWO TOWERS", games = 13, folders = { "Two towers" } },
    { id = "PLAYLIST-STINK", name = "STINK", games = 11, folders = { "Stink" } },
    { id = "PLAYLIST-DOWNTOWN", name = "DOWNTOWN", games = 13, folders = { "Downtown" } },
    { id = "PLAYLIST-DEADTOWN", name = "DEADTOWN", games = 11, folders = { "Deadtown", "West deadtown", "Mid deadtown", "East deadtown" } },
    { id = "PLAYLIST-BADCHINA", name = "BAD ASIA", games = 12, folders = { "Bad asia" } },
    { id = "PLAYLIST-BLOCKS", name = "TOWER BLOCKS", games = 9, folders = { "Tower blocks", "Blocks" } },
    { id = "PLAYLIST-COMMUNE", name = "COMMUNE", games = 6, folders = { "Commune" } },
    { id = "PLAYLIST-FANCYHILL", name = "FANCY HILL", games = 5, folders = { "Fancy hill" } },
    { id = CLUB, name = "THE CLUB", games = 58, folders = { "The club", "Club", "Night club" } },
}
local AREA_BY_ID, AREA_BY_FOLDER = {}, {}
local function folderKey(name) return tostring(name or ""):lower():gsub("[^%w]", "") end
for _, a in ipairs(Music.AREAS) do
    AREA_BY_ID[a.id] = a
    for _, f in ipairs(a.folders) do AREA_BY_FOLDER[folderKey(f)] = a.id end
end

local AREA_CLASS = "/Game/Audio/Music/MuzykaOtoczenia/musicAreaPlaylist.musicAreaPlaylist_C"
local MUSIC_CLASS = "/Game/Audio/soundClasses/environmentMusic.environmentMusic"

-- The addon's DLL and its two files (music_cmd.txt, music_evt.txt) in the ipc directory.
local DLL = Core.MOD_DIR .. "/bin/ddsmp_audio.dll"
local ipc = { loaded = nil, cmd = nil, evt = nil, off = 0, rest = "", handlers = {} }

-- (the bridge's ipc directory: known once the mod has started its bridge and read which
-- copy of the game this is)
local function ipcDir() return Net.ipcDir() end

local function ready()
    if ipc.loaded ~= nil then return ipc.loaded end
    if not ipcDir() then return false end      -- (too early: asked again later)
    -- (loaded once per game: a second load, after a hot reload of the scripts, finds it
    -- running and keeps its files)
    local was = rawget(_G, "DDSMP_AUDIO_LOADED") == true
    local fn, err = package.loadlib(DLL, "*")
    if not fn then
        ipc.loaded = false
        log("Music: the addon's DLL could not be loaded (%s): %s", DLL, tostring(err))
        return false
    end
    _G.DDSMP_AUDIO_LOADED = true
    ipc.loaded = true
    -- (after a reload the events of before are passed over: from where the file ends now,
    -- before this module has asked anything)
    ipc.evt = io.open(ipcDir() .. "/music_evt.txt", "rb")
    if ipc.evt and was then ipc.off = ipc.evt:seek("end") or 0 end
    return true
end
Music.ready = ready
-- (on whenever the addon is installed: its DLL is there)
local function on() return ready() end
Music.enabled = on

local function cmd(line)
    if not ready() then return false end
    if not ipc.cmd then
        ipc.cmd = io.open(ipcDir() .. "/music_cmd.txt", "ab")
        if not ipc.cmd then return false end
    end
    ipc.cmd:write(line, "\n")
    ipc.cmd:flush()
    return true
end

local function onEvent(kind, fn) ipc.handlers[kind] = fn end

local function pollEvents()
    if not ipc.loaded then return end
    if not ipc.evt then
        ipc.evt = io.open(ipcDir() .. "/music_evt.txt", "rb")
        if not ipc.evt then return end
    end
    local size = ipc.evt:seek("end") or 0
    if size < ipc.off then ipc.off, ipc.rest = 0, "" end
    if size == ipc.off then return end
    ipc.evt:seek("set", ipc.off)
    local data = ipc.evt:read(size - ipc.off) or ""
    ipc.off = ipc.off + #data
    data = ipc.rest .. data
    local last = 0
    for line, stop in data:gmatch("([^\n]*)\n()") do
        last = stop
        local f = {}
        for part in (line:gsub("\r$", "") .. "\t"):gmatch("(.-)\t") do f[#f + 1] = part end
        local fn = ipc.handlers[f[1] or ""]
        if fn then
            local ok, e = xpcall(fn, debug.traceback, f)
            if not ok then log("Music: event %s: %s", tostring(f[1]), tostring(e)) end
        end
    end
    ipc.rest = data:sub(last > 0 and last or 1)
    if last == 0 then ipc.rest = data end
end

Core.onTick(function()
    if not live() then return end
    local ok, e = pcall(pollEvents)
    if not ok then log("Music: %s", tostring(e)) end
end)

-- A file name as shown: without its ending, and with plain letters only (the game's text
-- refuses a character cut in half, and its fonts have no others anyway).
local function title(name)
    local t = tostring(name or ""):gsub("^.*/", ""):gsub("%.[^.]+$", ""):gsub("_", " ")
    t = t:gsub("[\128-\255]", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then t = "Song" end
    return t
end

-- A song's own name out of a file name like "Artist - Album - 06 Song": what comes after
-- the last " - ", without a track number.
local function songTitle(name)
    local t = title(name)
    local last = t:match(".*%s%-%s(.+)$") or t
    last = last:gsub("^%d+[%s%.%-]+", "")
    if last == "" then last = t end
    return last:upper()
end

local function clock(ms)
    local s = math.floor((ms or 0) / 1000)
    return string.format("%d:%02d", s // 60, s % 60)
end

---------------------------------------------------------------- the library

-- entry: { name, size, id, path, ms (nil: not read yet, 0: cannot be played), host = true for
-- the host's (guests), areas = list of area ids or nil (all) for the host's }
local own = { list = {}, byId = {} }
local host = { list = {}, byId = {}, pages = nil }
-- areas: file -> area ids; len: id -> ms; volume: the slider, 0..1; replace: REPLACE THE
-- GAME'S MUSIC
local settings = { areas = {}, len = {}, volume = DEFAULT_VOLUME, replace = false }

local function readSettings()
    local f = io.open(SETTINGS, "rb")
    if not f then return end
    local text = f:read("*a")
    f:close()
    local ok, t = pcall(json.decode, text)
    if ok and type(t) == "table" then
        settings.areas = type(t.areas) == "table" and t.areas or {}
        settings.len = type(t.len) == "table" and t.len or {}
        settings.volume = type(t.volume) == "number" and math.max(0, math.min(1, t.volume)) or DEFAULT_VOLUME
        settings.replace = t.replace == true
    end
end

local function saveSettings()
    local f = io.open(SETTINGS, "wb")
    if not f then
        log("Music: %s could not be written", SETTINGS)
        return false
    end
    f:write(json.encode({ areas = settings.areas, len = settings.len, volume = settings.volume, replace = settings.replace }))
    f:close()
    return true
end

-- "Stink/a.mp3": the area of the folder (nil for a file not in a folder; false for a
-- folder that names no area).
local function folderOf(name)
    local dir = tostring(name or ""):match("^(.-)/")
    if not dir then return nil end
    return AREA_BY_FOLDER[folderKey(dir)] or false
end
Music.folderOf = folderOf

local function areasOf(e)
    if e.folder then return { e.folder } end
    if e.host then return e.areas end
    local a = settings.areas[e.name]
    return type(a) == "table" and a or nil
end
Music.areasOf = areasOf

local function inArea(e, areaId)
    local a = areasOf(e)
    if not a then return true end
    for _, id in ipairs(a) do if id == areaId then return true end end
    return false
end

local function playable(e) return e and e.path and type(e.ms) == "number" and e.ms > 5000 end

-- The tracks an area can pick from in this game: our own, and (a guest) the host's that are
-- here. `ownOnly`: only our own (the host picking for the club). An area with a folder of
-- its own picks from that folder alone. The second result is true when they replace the
-- game's songs there (REPLACE THE GAME'S MUSIC on); otherwise they join them.
function Music.pool(areaId, ownOnly)
    local only, mixed, seen = {}, {}, {}
    if not on() then return mixed, false end
    local replace = settings.replace == true
    local function add(e)
        if seen[e.id] or not playable(e) or e.folder == false then return end
        if e.folder then
            if e.folder == areaId then only[#only + 1] = e end
        elseif inArea(e, areaId) then
            mixed[#mixed + 1] = e
        end
        seen[e.id] = true
    end
    -- (the host's folder for an area counts before a guest's own)
    if not ownOnly and World.role == "guest" then
        for _, e in ipairs(host.list) do if e.have then add(e) end end
    end
    for _, e in ipairs(own.list) do add(e) end
    if #only > 0 then return only, replace end
    return mixed, replace and #mixed > 0
end

-- A track by its id (name|size): ours or the host's.
function Music.entry(id)
    return own.byId[id] or host.byId[id]
end

function Music.title(id)
    local e = Music.entry(id)
    if e then return songTitle(e.name) end
    local name = tostring(id or ""):match("^(.*)|%d+$")
    return name and songTitle(name) or nil
end

-- True when the track can be played in this game now.
function Music.has(id)
    local e = Music.entry(id)
    if not e or not on() then return false end
    if e.host then return e.have == true and playable(e) end
    return playable(e)
end

-- Edwin's list: what the host has (in the host's game, ours).
function Music.hostTracks()
    local out = {}
    if not on() then return out end
    local list = World.role == "guest" and host.list or own.list
    for _, e in ipairs(list) do
        if type(e.ms) == "number" and e.ms > 5000 and e.folder ~= false then out[#out + 1] = { id = e.id, title = songTitle(e.name), ms = e.ms } end
    end
    return out
end

---------------------------------------------------------------- scanning

local scan = nil          -- { target = "own" | "cache", found = {} }
local scanQueue = {}
local lengths = { waiting = {}, busy = 0 }

local function startScan(target)
    if scan then
        scanQueue[#scanQueue + 1] = target
        return
    end
    scan = { target = target, found = {} }
    cmd("MSCAN " .. (target == "cache" and CACHE or DIR))
end

local announce          -- (below)
local cachedFiles = {}  -- file name -> size
local function cacheName(name) return tostring(name):gsub("/", "~") end

local function askLengths()
    while lengths.busy < 2 and #lengths.waiting > 0 do
        local e = table.remove(lengths.waiting, 1)
        lengths.busy = lengths.busy + 1
        e.asked = true
        cmd("MLEN " .. e.path)
    end
end

onEvent("MFILE", function(f)
    if not live() or not scan then return end
    scan.found[#scan.found + 1] = { name = f[2] or "", size = tonumber(f[3]) or 0 }
end)

onEvent("MSCANEND", function()
    if not live() or not scan then return end
    local done = scan
    scan = nil
    if done.target == "cache" then
        cachedFiles = {}
        for _, x in ipairs(done.found) do cachedFiles[x.name] = x.size end
        for _, e in ipairs(host.list) do
            e.have = cachedFiles[cacheName(e.name)] == e.size
        end
    else
        local list, byId = {}, {}
        for _, x in ipairs(done.found) do
            local id = x.name .. "|" .. x.size
            local e = own.byId[id] or { name = x.name, size = x.size, id = id, path = DIR .. "/" .. x.name, folder = folderOf(x.name) }
            if e.ms == nil and settings.len[id] then e.ms = tonumber(settings.len[id]) end
            list[#list + 1] = e
            byId[id] = e
            if e.ms == nil and not e.asked then lengths.waiting[#lengths.waiting + 1] = e end
        end
        -- (the songs of folders first, folder by folder: they are found at a glance)
        local folders, loose = {}, {}
        for _, e in ipairs(list) do
            if e.folder ~= nil then folders[#folders + 1] = e else loose[#loose + 1] = e end
        end
        for _, e in ipairs(loose) do folders[#folders + 1] = e end
        list = folders
        own.list, own.byId = list, byId
        askLengths()
        log("Music: %d files in %s", #list, DIR)
        if announce then announce() end
    end
    Music.refreshPage()
    if #scanQueue > 0 then startScan(table.remove(scanQueue, 1)) end
end)

onEvent("MLEN", function(f)
    if not live() then return end
    lengths.busy = math.max(0, lengths.busy - 1)
    local path, ms = f[2] or "", tonumber(f[3]) or 0
    for _, e in ipairs(own.list) do
        if e.path == path then
            e.ms = ms
            settings.len[e.id] = ms
            if ms == 0 then log("Music: %s cannot be played", e.name) end
        end
    end
    for _, e in ipairs(host.list) do
        if e.path == path and ms > 0 then e.ms = e.ms or ms end
    end
    askLengths()
    if lengths.busy == 0 and #lengths.waiting == 0 then
        saveSettings()
        if announce then announce() end
    end
    Music.refreshPage()
end)

function Music.rescan()
    readSettings()
    startScan("own")
    startScan("cache")
end

---------------------------------------------------------------- where the sound comes from

local listener = { x = 0, y = 0, z = 0, yaw = 0, at = 0 }

local function readListener()
    local player = World.player()
    if not player then return false end
    local ok = pcall(function()
        local cam = player:GetController().PlayerCameraManager
        local l, r = cam:GetCameraLocation(), cam:GetCameraRotation()
        listener.x, listener.y, listener.z, listener.yaw = l.X, l.Y, l.Z, r.Yaw
    end)
    if not ok then
        local l = player:K2_GetActorLocation()
        listener.x, listener.y, listener.z = l.X, l.Y, l.Z
    end
    return true
end

-- The game's music volume (its SETTINGS screen) and the loudness of the class of sound the
-- area music is in.
local volume = { music = 1, class = nil, at = -100, paused = false }

-- The game's MUSIC slider counts only once its settings screen has been opened (the saved
-- value is applied from there): until then the music plays at full loudness, whatever the
-- saved number says. So: full until the slider is moved, then the slider.
Core.Hooks.add("/Game/GUI/settingsWidget.settingsWidget_C:BndEvt__sliderMusicVol_K2Node_ComponentBoundEvent_5_OnFloatValueChangedEvent__DelegateSignature", function(_, value)
    if not live() then return end
    pcall(function()
        local v = value:get()
        if type(v) == "number" then volume.music = math.max(0, math.min(1, v)) end
    end)
end)

local function readVolume()
    if os.clock() - volume.at < 4 then return end
    volume.at = os.clock()
    if type(Music.forceVolume) == "number" then volume.music = Music.forceVolume end      -- (tests)
    if volume.class == nil then
        volume.class = 1
        pcall(function()
            local c = StaticFindObject(MUSIC_CLASS)
            if valid(c) and type(c.Properties.Volume) == "number" then volume.class = c.Properties.Volume end
        end)
    end
end

-- How far a speaker carries: full loudness within `inner`, none past inner + falloff.
local function attenuationOf(ac)
    local inner, falloff = 400, 3600
    pcall(function()
        local s = nil
        if ac.bOverrideAttenuation then
            s = ac.AttenuationOverrides
        elseif valid(ac.AttenuationSettings) then
            s = ac.AttenuationSettings.Attenuation
        elseif valid(ac.Sound) and valid(ac.Sound.AttenuationSettings) then
            s = ac.Sound.AttenuationSettings.Attenuation
        end
        if s then
            local i, f = s.AttenuationShapeExtents.X, s.FalloffDistance
            if type(i) == "number" and i >= 0 then inner = i end
            if type(f) == "number" and f > 0 then falloff = f end
        end
    end)
    return inner, falloff
end
Music.attenuationOf = attenuationOf

-- voice: { slot, entry, x, y, z, inner, falloff, base, fadeFrom, fadeTo, fadeAt, fadeFor,
-- startedAt, l, r, stopAt }
local voices = {}

local function fadeValue(v, now)
    if not v.fadeFor or v.fadeFor <= 0 then return v.fadeTo or 1 end
    local t = math.max(0, math.min(1, (now - v.fadeAt) / v.fadeFor))
    return v.fadeFrom + (v.fadeTo - v.fadeFrom) * t
end

local function setFade(v, to, seconds)
    local now = os.clock()
    v.fadeFrom, v.fadeTo, v.fadeAt, v.fadeFor = fadeValue(v, now), to, now, seconds
end

-- Starts `entry` on `slot` at `offset` seconds, heard from `place` ({ x, y, z, inner,
-- falloff, base }).
local function startVoice(slot, entry, offset, place, fadeIn)
    if not playable(entry) then return false end
    offset = math.max(0, offset or 0)
    if offset * 1000 >= entry.ms - 1000 then return false end
    local v = { slot = slot, entry = entry, startedAt = os.clock() - offset, l = -1, r = -1,
        x = place.x, y = place.y, z = place.z, inner = place.inner or 400, falloff = place.falloff or 3600,
        base = place.base or 0.3, fadeFrom = 0, fadeTo = 1, fadeAt = os.clock(), fadeFor = fadeIn or 0 }
    voices[slot] = v
    cmd(string.format("MPLAY %s %d %s", slot, math.floor(offset * 1000), entry.path))
    if Core.vlog then Core.vlog("Music: %s plays %s from %ds", slot, entry.name, math.floor(offset)) end
    return true
end

local function stopVoice(slot, fade)
    local v = voices[slot]
    if not v then return end
    if fade and fade > 0 then
        if not v.stopAt then
            setFade(v, 0, fade)
            v.stopAt = os.clock() + fade
        end
    else
        voices[slot] = nil
        cmd("MSTOP " .. slot)
    end
end
Music.stop = stopVoice
function Music.playing(slot) return voices[slot] ~= nil and not voices[slot].stopAt end

local function stopAll()
    for slot in pairs(voices) do voices[slot] = nil end
    cmd("MSTOPALL")
end

-- Sends each voice's loudness for the two ears.
local function placeVoices()
    if not next(voices) then return end
    local now = os.clock()
    if now - listener.at > 0.05 then
        listener.at = now
        if not readListener() then return end
    end
    readVolume()
    local paused = false
    pcall(function() paused = Core.statics():IsGamePaused(World.player()) == true end)
    local yaw = math.rad(listener.yaw or 0)
    local rx, ry = -math.sin(yaw), math.cos(yaw)
    for slot, v in pairs(voices) do
        if v.stopAt and now >= v.stopAt then
            voices[slot] = nil
            cmd("MSTOP " .. slot)
        else
            local dx, dy, dz = v.x - listener.x, v.y - listener.y, v.z - listener.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            local near = 1
            if d > v.inner then near = math.max(0, 1 - (d - v.inner) / v.falloff) end
            local gain = (v.base or 0.3) * near * fadeValue(v, now) * volume.music * (volume.class or 1) * Music.LEVEL * settings.volume * settings.volume
            if paused then gain = 0 end
            -- (louder in the ear on the speaker's side; close by, from all around)
            local side = 0
            local flat = math.sqrt(dx * dx + dy * dy)
            if flat > 1 then side = (dx * rx + dy * ry) / flat end
            side = side * math.min(1, flat / 600) * 0.8
            -- (equal power, as the engine pans its own: 0.71 to each ear from straight ahead)
            local theta = (side + 1) * math.pi / 4
            local l = math.min(1, gain * math.cos(theta))
            local r = math.min(1, gain * math.sin(theta))
            if math.abs(l - v.l) > 0.003 or math.abs(r - v.r) > 0.003 then
                v.l, v.r = l, r
                cmd(string.format("MVOL %s %.4f %.4f", slot, l, r))
            end
        end
    end
end

Core.onTick(function()
    if not live() then return end
    local ok, e = pcall(placeVoices)
    if not ok then log("Music: %s", tostring(e)) end
end)

local ended = {}         -- slot -> fn() when the bridge says the file has ended
onEvent("MEND", function(f)
    if not live() then return end
    local slot = f[2] or ""
    voices[slot] = nil
    local fn = ended[slot]
    if fn then pcall(fn) end
end)

onEvent("MERR", function(f)
    if not live() then return end
    local slot = f[2] or ""
    local v = voices[slot]
    log("Music: %s: %s%s", slot, tostring(f[3]), v and (" (" .. v.entry.name .. ")") or "")
    if v then v.entry.ms = 0 end
    voices[slot] = nil
end)

---------------------------------------------------------------- the street areas

local areas = { list = {}, at = -100, owner = nil }
local state = {}          -- area address -> { was, custom, recent }

local function areaId(a)
    local id = nil
    pcall(function() id = a.PlaylistID:ToString() end)
    return id
end

local function slotOf(id) return "a" .. tostring(id):gsub("[^%w]", ""):gsub("^PLAYLIST", "") end

local function clubTaken()
    -- (the club's area is coop/casino.lua's while it plays the club's music)
    local Casino = package.loaded["coop.casino"]
    return type(Casino) == "table" and Casino.active and Casino.active() and Core.config.Casino ~= false
end

local function refreshAreas(player)
    local owner = player:GetAddress()
    if areas.owner ~= owner then
        areas.owner, areas.list, areas.at = owner, {}, -100
        for slot in pairs(voices) do if slot:sub(1, 1) == "a" then stopVoice(slot) end end
        state = {}
    end
    if os.clock() - areas.at < 10 then return end
    areas.at = os.clock()
    local list = {}
    for _, a in ipairs(Core.actors(AREA_CLASS) or {}) do
        local id = areaId(a)
        if id and AREA_BY_ID[id] then list[#list + 1] = { actor = a, id = id, address = a:GetAddress() } end
    end
    areas.list = list
end

-- An area has just started a track of the game's: perhaps one of ours plays instead.
local function takeOver(rec)
    local a = rec.actor
    if rec.id == CLUB and clubTaken() then return end
    local pool, only = Music.pool(rec.id)
    if #pool == 0 then return end
    local info = AREA_BY_ID[rec.id]
    if not only and math.random() >= #pool / (#pool + (info and info.games or 10)) then return end
    local s = state[rec.address]
    -- (not one of the last few again)
    local choices = {}
    for _, e in ipairs(pool) do
        local recent = false
        for _, r in ipairs(s.recent) do if r == e.id then recent = true end end
        if not recent then choices[#choices + 1] = e end
    end
    if #choices == 0 then choices = pool end
    local entry = choices[math.random(#choices)]
    local speaker, ac = nil, nil
    pcall(function()
        speaker = a.ambientSoundPoints[(a.curPlayerID or 0) + 1]
        ac = speaker.AudioComponent
    end)
    if not valid(speaker) or not valid(ac) then return end
    local l = speaker:K2_GetActorLocation()
    local inner, falloff = attenuationOf(ac)
    local base = 0.3
    pcall(function() if type(a.randVolume) == "number" and a.randVolume > 0 then base = a.randVolume end end)
    pcall(function() ac:Stop() end)
    local slot = slotOf(rec.id)
    if not startVoice(slot, entry, 0, { x = l.X, y = l.Y, z = l.Z, inner = inner, falloff = falloff, base = base }, 3) then return end
    s.custom = { slot = slot, entry = entry, ac = ac, endsAt = os.clock() + entry.ms / 1000 - 2 }
    table.insert(s.recent, 1, entry.id)
    while #s.recent > 3 do table.remove(s.recent) end
    log("Music: %s plays %s (%s, falloff %d+%d)", rec.id, entry.name, clock(entry.ms), math.floor(inner), math.floor(falloff))
    ended[slot] = function()
        local st = state[rec.address]
        if st and st.custom and st.custom.slot == slot then
            pcall(function() a:endMusic() end)
        end
    end
end

local function manageArea(rec)
    local a = rec.actor
    if not Core.alive(a) then return end
    local s = state[rec.address]
    if not s then
        s = { was = a.musicIsPlaying == true, recent = {} }
        state[rec.address] = s
        return
    end
    local playing = a.musicIsPlaying == true
    if playing and not s.was and not s.custom then
        local ok, e = pcall(takeOver, rec)
        if not ok then log("Music: %s: %s", rec.id, tostring(e)) end
    end
    local c = s.custom
    if c then
        if not playing then
            -- (the game ended the area's music: a chase, the night, our own end)
            stopVoice(c.slot, 2)
            s.custom = nil
        else
            -- the game's track stays off, and its own end timer with it
            pcall(function() if c.ac:IsPlaying() then c.ac:Stop() end end)
            pcall(function() Core.system():K2_ClearTimer(a, "endMusic") end)
            if os.clock() >= c.endsAt then
                pcall(function() a:endMusic() end)
                stopVoice(c.slot, 2)
                s.custom = nil
                playing = false
            end
        end
    end
    s.was = playing
end

Core.every(0.25, function()
    if not live() then return end
    local player = World.player()
    if not on() or not player or World.gone then
        if next(voices) then stopAll() end
        state, areas.owner = {}, nil
        return
    end
    local ok, e = pcall(refreshAreas, player)
    if not ok then log("Music: areas: %s", tostring(e)) end
    for _, rec in ipairs(areas.list) do
        local ok2, e2 = pcall(manageArea, rec)
        if not ok2 then log("Music: %s: %s", rec.id, tostring(e2)) end
    end
end)

-- (at once when an area starts its music, so the game's track is not heard first)
Core.Hooks.add(AREA_CLASS .. ":ActivateMusicInArea", function(ctx)
    if not live() or not on() then return end
    local a = ctx:get()
    if not valid(a) then return end
    local address = a:GetAddress()
    for _, rec in ipairs(areas.list) do
        if rec.address == address then
            pcall(manageArea, rec)
            return
        end
    end
end)

---------------------------------------------------------------- the club (coop/casino.lua)

-- Plays track `id` in the club from `offset` seconds, from the club's speaker.
function Music.playClub(id, offset, speaker, base)
    if not Music.has(id) or not valid(speaker) then return false end
    local e = Music.entry(id)
    local place = { base = base or 0.3 }
    local ok = pcall(function()
        local owner = speaker:GetOwner()
        local l = valid(owner) and owner:K2_GetActorLocation() or speaker:K2_GetComponentLocation()
        place.x, place.y, place.z = l.X, l.Y, l.Z
        place.inner, place.falloff = attenuationOf(speaker)
    end)
    if not ok then return false end
    return startVoice("club", e, offset, place, 0.5)
end

---------------------------------------------------------------- the host's files for the guests

local download = nil       -- { e, at } the file asked for
local function hostId() return World.host or Net.S.owner end

local function sendLibrary(target)
    if not live() or World.role ~= "host" then return end
    local list = {}
    if on() then
        for _, e in ipairs(own.list) do
            if type(e.ms) == "number" and e.ms > 5000 and e.folder ~= false then
                list[#list + 1] = { n = e.name, s = e.size, m = e.ms, a = (not e.folder) and areasOf(e) or nil }
            end
        end
    end
    local pages = math.max(1, math.ceil(#list / 12))
    for p = 1, pages do
        local k = {}
        for i = (p - 1) * 12 + 1, math.min(#list, p * 12) do k[#k + 1] = list[i] end
        local data = { p = p, n = pages, k = k }
        if target then
            Net.send("mlib", data, target)
        else
            for _, id in ipairs(World.targets()) do Net.send("mlib", data, id) end
        end
    end
end

local announceAt = nil
announce = function()
    if World.role ~= "host" then return end
    announceAt = os.clock() + 1.5
end

Core.every(0.5, function()
    if live() and announceAt and os.clock() >= announceAt then
        announceAt = nil
        sendLibrary()
    end
end)

World.listen("peer", function(id)
    if live() and World.role == "host" and on() then sendLibrary(id) end
end)

local function nextDownload()
    if download or World.role ~= "guest" or not on() then return end
    local h = hostId()
    if not h or Net.S.links[h] == "lobby" then return end      -- (not through the lobby chat)
    local want = nil
    -- the club's song first
    local Casino = package.loaded["coop.casino"]
    pcall(function()
        local dj = Casino.music()
        local e = dj and dj.custom and host.byId[dj.custom]
        if e and not e.have and not e.failed then want = e end
    end)
    if not want then
        for _, e in ipairs(host.list) do
            if not e.have and not e.failed then
                want = e
                break
            end
        end
    end
    if not want then return end
    download = { e = want, at = os.clock() }
    Net.send("mget", { n = want.name, s = want.size }, h)
    log("Music: asked the host for %s (%d kB)", want.name, math.floor(want.size / 1024))
    Music.refreshPage()
end

Core.every(2, function()
    if not live() then return end
    if download and os.clock() - download.at > 240 then
        log("Music: %s did not come", download.e.name)
        download.e.failed = true
        download = nil
    end
    pcall(nextDownload)
end)

Net.on("mlib", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= hostId() then return end
    local p, n = tonumber(data.p) or 1, tonumber(data.n) or 1
    if p == 1 or not host.pages then host.pages = { got = 0, n = n, k = {} } end
    host.pages.got = host.pages.got + 1
    for _, x in ipairs(type(data.k) == "table" and data.k or {}) do host.pages.k[#host.pages.k + 1] = x end
    if host.pages.got < host.pages.n then return end
    local list, byId = {}, {}
    for _, x in ipairs(host.pages.k) do
        local name, size = tostring(x.n or ""), tonumber(x.s) or 0
        -- (a file name, at most one folder down: nothing that leads out of the folder)
        local _, slashes = name:gsub("/", "")
        if name ~= "" and slashes <= 1 and not name:find("[\\:]") and not name:find("%.%.") and size > 0 then
            local id = name .. "|" .. size
            local old = host.byId[id]
            local e = { name = name, size = size, id = id, host = true, path = CACHE .. "/" .. cacheName(name),
                ms = tonumber(x.m), areas = type(x.a) == "table" and x.a or nil, folder = folderOf(name) }
            e.have = (old and old.have) or cachedFiles[cacheName(name)] == size
            e.failed = old and old.failed or nil
            list[#list + 1] = e
            byId[id] = e
        end
    end
    host.list, host.byId, host.pages = list, byId, nil
    log("Music: the host has %d tracks", #list)
    Music.refreshPage()
end)

Net.on("mget", function(sender, data)
    if not live() or World.role ~= "host" or not World.inWorld[sender] or not on() then return end
    local e = own.byId[tostring(data.n) .. "|" .. tostring(data.s)]
    if not e then return end
    Net.sendFile("mus", e.path, sender)
end)

Net.onFile("mus", function(sender, path)
    if not live() or sender ~= hostId() or not download then return end
    local e = download.e
    download = nil
    if Core.fileSize(path) ~= e.size then
        log("Music: %s arrived with the wrong size", e.name)
        e.failed = true
        return
    end
    -- (the received file has a plain name; the DLL gives it its own, which may hold any
    -- letters, and Lua's own file calls cannot)
    local part = CACHE .. "/incoming.part"
    os.remove(part)
    if not os.rename(path, part) then
        log("Music: %s could not be put into %s", e.name, CACHE)
        e.failed = true
        return
    end
    download = { e = e, at = os.clock(), moving = true }
    cmd(string.format("MMOVE %d|%s|%s", e.size, part, e.path))
end)

onEvent("MMOVED", function(f)
    if not live() or not download or download.e.path ~= f[2] then return end
    local e = download.e
    download = nil
    e.have, cachedFiles[cacheName(e.name)] = true, e.size
    log("Music: %s is here", e.name)
    Music.refreshPage()
end)

onEvent("MMOVEFAIL", function(f)
    if not live() or not download or download.e.path ~= f[2] then return end
    log("Music: %s could not be put into %s", download.e.name, CACHE)
    download.e.failed = true
    download = nil
end)

World.listen("stop", function()
    if not live() then return end
    host.list, host.byId, host.pages, download = {}, {}, nil, nil
end)

---------------------------------------------------------------- switching

function Music.apply(enabled)
    if enabled then
        if not ready() then
            pcall(Hud.toast, "The music addon's DLL is missing: bin/ddsmp_audio.dll", 5)
            return
        end
        Music.rescan()
    else
        stopAll()
        state = {}
    end
    if World.role == "host" then sendLibrary() end
end

---------------------------------------------------------------- the MUSIC page of MOD OPTIONS

local page = nil          -- the ui of the page while it shows
local expanded = nil      -- the file whose areas are shown

function Music.refreshPage()
    if page and page.render then
        local r = page.render
        Core.after(0.05, function() pcall(r) end)
    end
end

local function setAreas(e, list)
    if list then
        local all = true
        for _, a in ipairs(Music.AREAS) do
            local found = false
            for _, id in ipairs(list) do if id == a.id then found = true end end
            if not found then all = false end
        end
        if all then list = nil end
    end
    settings.areas[e.name] = list
    saveSettings()
    announce()
end

local function areaNames(e)
    local a = areasOf(e)
    if not a then return "All areas" end
    if #a == 0 then return "No areas" end
    local names = {}
    for _, id in ipairs(a) do
        local info = AREA_BY_ID[id]
        if info then names[#names + 1] = info.name:sub(1, 1) .. info.name:sub(2):lower() end
    end
    return table.concat(names, ", ")
end

-- ui: what coop/options.lua draws its pages with (scr, inner, row, put, emptyLine, render,
-- YELLOW, group).
function Music.page(ui)
    page = ui
    local scr, inner = ui.scr, ui.inner
    local folder = DIR:gsub("/", "\\")
    local open = scr.button("OPEN FOLDER", nil, function() cmd("MOPEN " .. folder) end)
    local again = scr.button("RESCAN", nil, function() Music.rescan() end)
    local short = folder:match("([^\\]+\\[^\\]+\\[^\\]+)$") or folder
    ui.row(inner, "Your music folder", short .. "   (mp3, wav)", { open.widget, again.widget })
    -- the loudness of your songs: a slider and its number (read while it is dragged, without
    -- drawing the page again, which would drop the drag)
    local bar = scr.new("Slider")
    pcall(function() bar:SetStepSize(0.01) end)
    pcall(function() bar:SetSliderBarColor({ R = 0.75, G = 0.75, B = 0.72, A = 1 }) end)
    pcall(function() bar:SetSliderHandleColor(Screen.GREEN) end)
    pcall(function() bar.WidgetStyle.BarThickness = 6 end)
    pcall(function() bar.WidgetStyle.NormalThumbImage.ImageSize = { X = 16, Y = 34 } end)
    pcall(function() bar.WidgetStyle.HoveredThumbImage.ImageSize = { X = 16, Y = 34 } end)
    bar:SetValue(settings.volume)
    local number = scr.text(string.format("%d%%", math.floor(settings.volume * 100 + 0.5)), "button", 20)
    ui.row(inner, "Volume of your songs", nil, { scr.sized(number, 70, 40), scr.sized(bar, 300, 40) })
    page.slider = { bar = bar, number = number, value = settings.volume }
    local replace = scr.button(settings.replace and "ON" or "OFF", nil, function()
        settings.replace = not settings.replace
        saveSettings()
        ui.render()
    end)
    scr.tint(replace, settings.replace and Screen.GREEN or Screen.GREY)
    ui.row(inner, "Replace the game's music", "Off: your songs play along with the game's. On: where you have songs, only yours play.", { replace.widget })
    if World.role == "guest" then
        local have = 0
        for _, e in ipairs(host.list) do if e.have then have = have + 1 end end
        local sub = string.format("%d of %d of the host's tracks are here", have, #host.list)
        if download then sub = sub .. ". Loading " .. title(download.e.name) end
        ui.row(inner, "The host's music", sub, {})
    end
    if #own.list == 0 then
        ui.emptyLine(inner, "No mp3 or wav files in the folder.")
        return
    end
    for _, e in ipairs(own.list) do
        local sub, color = nil, nil
        local dir = e.name:match("^(.-)/")
        if e.ms == nil then
            sub = "Reading..."
        elseif e.ms <= 5000 then
            sub, color = "Cannot be played", ui.YELLOW
        elseif e.folder == false then
            sub, color = string.format('No area is called "%s": the folder plays nowhere', dir), ui.YELLOW
        elseif e.folder then
            local info = AREA_BY_ID[e.folder]
            sub = string.format("%s   %s only (folder %s)", clock(e.ms), info.name:sub(1, 1) .. info.name:sub(2):lower(), dir)
        else
            sub = clock(e.ms) .. "   " .. areaNames(e)
        end
        if e.folder ~= nil then
            -- (a folder decides the area: no buttons)
            ui.row(inner, title(e.name), sub, {}, color)
            goto continue
        end
        local all = areasOf(e) == nil
        local bAll = scr.button("ALL AREAS", nil, function()
            setAreas(e, nil)
            ui.render()
        end)
        scr.tint(bAll, all and Screen.GREEN or Screen.WHITE)
        local bPick = scr.button(expanded == e.name and "CLOSE" or "AREAS", nil, function()
            expanded = expanded ~= e.name and e.name or nil
            ui.render()
        end)
        ui.row(inner, title(e.name), sub, { bAll.widget, bPick.widget }, color)
        if expanded == e.name then
            -- the areas in a panel of their own under the track: five to a line, in columns
            -- of one width
            local lines = scr.new("VerticalBox")
            local line = nil
            for i, a in ipairs(Music.AREAS) do
                if (i - 1) % 5 == 0 then
                    line = scr.new("HorizontalBox")
                    lines:AddChildToVerticalBox(line):SetPadding({ Left = 0, Top = i > 1 and 4 or 0, Right = 0, Bottom = 0 })
                end
                local isOn = inArea(e, a.id)
                local b = scr.button(a.name, nil, function()
                    local list = {}
                    for _, other in ipairs(Music.AREAS) do
                        local keep = inArea(e, other.id)
                        if other.id == a.id then keep = not isOn end
                        if keep then list[#list + 1] = other.id end
                    end
                    setAreas(e, list)
                    ui.render()
                end)
                scr.tint(b, isOn and Screen.GREEN or Screen.GREY)
                local slot = line:AddChildToHorizontalBox(b.widget)
                slot:SetSize({ SizeRule = 1, Value = 1 })
                slot:SetHorizontalAlignment(1)
            end
            if ui.panel then ui.panel(lines) else ui.put(inner, lines, 6) end
        end
        ::continue::
    end
end

function Music.leavePage() page = nil end

-- The volume slider while the page shows: the new loudness counts at once, and is written
-- a moment after the last move.
local saveAt = nil
Core.onTick(function()
    if not live() then return end
    if saveAt and os.clock() >= saveAt then
        saveAt = nil
        saveSettings()
    end
    local s = page and page.slider
    if not s then return end
    if not valid(s.bar) then
        page.slider = nil
        return
    end
    local ok, v = pcall(function() return s.bar:GetValue() end)
    if not ok or type(v) ~= "number" then
        page.slider = nil          -- (the page is gone)
        return
    end
    if math.abs(v - s.value) < 0.004 then return end
    s.value = v
    settings.volume = math.max(0, math.min(1, v))
    pcall(function() s.number:SetText(FText(string.format("%d%%", math.floor(settings.volume * 100 + 0.5)))) end)
    saveAt = os.clock() + 1
end)

-- (tests) what plays: slot -> { file, seconds in, left, right }; the library sizes
function Music.debug()
    local out = {}
    for slot, v in pairs(voices) do
        out[slot] = { file = v.entry.name, at = os.clock() - v.startedAt, l = v.l, r = v.r, x = v.x, y = v.y, z = v.z, inner = v.inner, falloff = v.falloff, base = v.base }
    end
    return out, { own = #own.list, host = #host.list, download = download and download.e.name or nil, music = volume.music, class = volume.class }
end
Music.hostList = function() return host.list end
Music.ownList = function() return own.list end
Music.areaList = function() return areas.list end

---------------------------------------------------------------- start

-- (the first look into the folder, once the mod has started)
local started = false
Core.every(2, function()
    if started or not live() then return end
    if on() then
        started = true
        Music.rescan()
    end
end)

return Music
