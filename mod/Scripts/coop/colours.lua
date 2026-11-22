-- A colour for every player, and this player's small choices that are kept between games.
--
--   * Every player in the lobby has a colour: the name in the chat is written in it, and
--     the clients a player has marked carry it (coop/marks.lua). Without a choice it is one
--     of six, by the player's place in the lobby's list.
--   * A player can choose any colour (six hex digits, RRGGBB). The choice is kept in a file
--     of this player's own and told to the lobby ("col"); an older version ignores it and
--     keeps showing the colour by place.
--   * Colours.pref / Colours.setPref keep other small choices in the same file.

local Core = require("core")
local Net = require("net")
local json = require("json")

local log = Core.log

local GEN = (rawget(_G, "DDSMP_COLOURS_GEN") or 0) + 1
_G.DDSMP_COLOURS_GEN = GEN
local function live() return rawget(_G, "DDSMP_COLOURS_GEN") == GEN end

local Colours = {}

-- one colour per place in the lobby's list (as the screen takes them: linear)
local PLACES = {
    { R = 1.0, G = 0.55, B = 0.10, A = 1 },
    { R = 0.30, G = 0.75, B = 1.0, A = 1 },
    { R = 0.45, G = 0.90, B = 0.35, A = 1 },
    { R = 1.0, G = 0.45, B = 0.75, A = 1 },
    { R = 1.0, G = 0.90, B = 0.30, A = 1 },
    { R = 0.70, G = 0.55, B = 1.0, A = 1 },
}

---------------------------------------------------------------- hex and back

local function toLinear(v)
    v = v / 255
    return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
end

local function toByte(v)
    v = math.max(0, math.min(1, v))
    local s = v <= 0.0031308 and v * 12.92 or (1.055 * v ^ (1 / 2.4) - 0.055)
    return math.floor(s * 255 + 0.5)
end

-- "RRGGBB" from what somebody typed or sent ("#rgb" and "#rrggbb" too); nil when it is no colour.
function Colours.clean(text)
    if type(text) ~= "string" then return nil end
    local h = text:gsub("[^%x]", ""):upper()
    if #h == 3 then h = h:sub(1, 1):rep(2) .. h:sub(2, 2):rep(2) .. h:sub(3, 3):rep(2) end
    return #h == 6 and h or nil
end

function Colours.fromHex(hex)
    hex = Colours.clean(hex)
    if not hex then return nil end
    return { R = toLinear(tonumber(hex:sub(1, 2), 16)), G = toLinear(tonumber(hex:sub(3, 4), 16)), B = toLinear(tonumber(hex:sub(5, 6), 16)), A = 1 }
end

function Colours.toHex(c)
    return string.format("%02X%02X%02X", toByte(c.R), toByte(c.G), toByte(c.B))
end

-- The six colours by place, as hex (what the colour screen offers first).
function Colours.places()
    local out = {}
    for i, c in ipairs(PLACES) do out[i] = Colours.toHex(c) end
    return out
end

---------------------------------------------------------------- this player's file

local function path()
    local base = os.getenv("LOCALAPPDATA")
    local dir = base and (base:gsub("\\", "/") .. "/DrugDealerSimulator/Saved/SaveGames") or Core.MOD_DIR
    return string.format("%s/ddsmp_prefs%s.json", dir, Core.instance and ("_" .. Core.instance) or "")
end

local prefs = nil

local function load()
    if prefs then return prefs end
    prefs = {}
    local f = io.open(path(), "rb")
    if f then
        local text = f:read("a")
        f:close()
        local ok, data = pcall(json.decode, text)
        if ok and type(data) == "table" then prefs = data end
    end
    return prefs
end

local function save()
    local ok, text = pcall(json.encode, load())
    if not ok then return false end
    local p = path()
    local f = io.open(p .. ".tmp", "wb")
    if not f then
        log("Colours: cannot write %s", p)
        return false
    end
    f:write(text)
    f:close()
    os.remove(p)
    os.rename(p .. ".tmp", p)
    return true
end

function Colours.pref(key) return load()[key] end

function Colours.setPref(key, value)
    if load()[key] == value then return end
    prefs[key] = value
    save()
end

---------------------------------------------------------------- who has which colour

local chosen = {}          -- player id (as text) -> "RRGGBB", as their games said
local listeners = {}
local told, toldAt = nil, 0

local function me() return tostring(Net.S.me or "me") end

local function changed(id)
    for _, fn in ipairs(listeners) do pcall(fn, id) end
end

-- fn(id) is called when the colour of the player with that id (as text) has changed.
function Colours.onChange(fn) listeners[#listeners + 1] = fn end

-- The player's own choice: "RRGGBB", or nil while the colour by place counts.
function Colours.mine() return Colours.clean(load().colour) end

local function byPlace(id)
    local ids = {}
    for member in pairs(Net.S.members or {}) do ids[#ids + 1] = member end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    for i, member in ipairs(ids) do
        if tostring(member) == id then return PLACES[(i - 1) % #PLACES + 1] end
    end
    return PLACES[1]
end

-- The colour of a player (nil: this player), "RRGGBB".
function Colours.hexOf(id)
    id = id == nil and me() or tostring(id)
    if id == me() then
        local mine = Colours.mine()
        if mine then return mine end
    elseif chosen[id] then
        return chosen[id]
    end
    return Colours.toHex(byPlace(id))
end

-- The colour of a player (nil: this player), as the screen takes it.
function Colours.of(id)
    id = id == nil and me() or tostring(id)
    local hex = nil
    if id == me() then hex = Colours.mine() else hex = chosen[id] end
    return hex and Colours.fromHex(hex) or byPlace(id)
end

-- Chooses this player's colour ("RRGGBB"; nil goes back to the colour by place).
function Colours.set(hex)
    hex = Colours.clean(hex)
    if hex == Colours.mine() then return end
    load().colour = hex
    save()
    told = nil
    log("Colours: own colour %s", hex and ("#" .. hex) or "by place")
    changed(me())
end

Net.on("col", function(sender, data)
    if not live() or type(data) ~= "table" then return end
    local id = tostring(sender)
    local hex = Colours.clean(data.c)
    if chosen[id] == hex then return end
    chosen[id] = hex
    changed(id)
end)

-- The lobby is told when the choice changes, when somebody new is there, and now and then.
Core.every(2, function()
    if not live() or not Net.inLobby() then
        told = nil
        return
    end
    local ids = {}
    for member in pairs(Net.S.members or {}) do ids[#ids + 1] = tostring(member) end
    table.sort(ids)
    local sig = table.concat(ids, ",") .. "|" .. tostring(Colours.mine())
    if sig == told and os.clock() - toldAt < 60 then return end
    told, toldAt = sig, os.clock()
    -- (nobody has chosen and nobody was told otherwise: nothing to say)
    if Colours.mine() or Colours.saidOnce then
        Colours.saidOnce = true
        Net.send("col", { c = Colours.mine() or "" })
    end
    -- those who have left are forgotten
    local here = {}
    for _, id in ipairs(ids) do here[id] = true end
    for id in pairs(chosen) do if not here[id] then chosen[id] = nil end end
end)

return Colours
