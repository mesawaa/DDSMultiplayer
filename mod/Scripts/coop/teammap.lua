-- The other players on the map and the compass.
--
-- Each player in the world gets a marker of the game's own kind, named after them, that
-- follows where they are. It is the game's person icon in orange: on the map the game
-- draws it that way by itself (a client's marker flagged as a dealer), on the compass the
-- person comes out in the clients' green and is painted over here. (It used to be the
-- icon of a dead drop, which is what a delivery looks like.)

local Core = require("core")
local Net = require("net")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Hud = require("coop.hud")

local valid = Core.valid

local Team = { markers = {} }

local ORANGE = { R = 1.0, G = 0.36, B = 0.0, A = 1.0 }
local recent = {}        -- player id -> the last places of their marker, newest last
local painted = {}       -- player id -> the compass widget painted for them

-- A player's colour on the compass: their own (coop/colours.lua) for whoever has the
-- client marks switched on, otherwise the orange the map draws them in.
local function colourOf(id)
    local Colours = package.loaded["coop.colours"]
    if Core.experimental("ClientMarks") and type(Colours) == "table" then return Colours.of(id), Colours.hexOf(id) end
    return ORANGE, "orange"
end

local function note(id, p)
    local list = recent[id] or {}
    recent[id] = list
    list[#list + 1] = { p.x, p.y, p.z }
    if #list > 5 then table.remove(list, 1) end
end

-- The compass notes where every marker is when it is built and makes a widget for each,
-- in the same order. Ours is found by its place, painted orange and moved along with the
-- player (the game leaves it where the player was when the compass was built).
local function paintCompass()
    local player = World.player()
    local hud = player and player.HUD
    if not valid(hud) or not valid(hud.compasMarkersHolder) then return end
    local places = {}
    hud.compassLocations:ForEach(function(i, v)
        local l = v:get()
        places[i] = { l.X, l.Y }
    end)
    if #places == 0 then return end
    for id, list in pairs(recent) do
        local now = list[#list]
        for i, place in ipairs(places) do
            local ours = false
            for _, r in ipairs(list) do
                if math.abs(place[1] - r[1]) < 2 and math.abs(place[2] - r[2]) < 2 then
                    ours = true
                    break
                end
            end
            if ours then
                local widget = hud.compasMarkersHolder:GetChildAt(i - 1)
                if valid(widget) then
                    local colour, name = colourOf(id)
                    local key = tostring(widget:GetAddress()) .. name
                    if painted[id] ~= key then
                        widget.Image_0:SetColorAndOpacity(colour)
                        painted[id] = key
                    end
                    pcall(function() hud.compassLocations[i] = { X = now[1], Y = now[2], Z = now[3] } end)
                end
                break
            end
        end
    end
end

local function clear()
    for id, marker in pairs(Team.markers) do
        Hud.forgetMarker(marker)
        Team.markers[id] = nil
    end
end

Core.every(1, function()
    if not World.shared() or not Core.enabled("Avatars") or Core.config.ShowPlayersOnMap == false then
        if next(Team.markers) then clear() end
        return
    end
    for id, set in pairs(Avatar.puppets) do
        local marker = Team.markers[id]
        if marker and not Core.alive(marker) then marker = nil end
        local p = set.player
        if not marker then
            marker = Hud.mapMarker(Net.name(id), "Player in your world", p.x, p.y, p.z, Hud.MARKER_PERSON, true)
            Team.markers[id] = marker
        end
        if marker then
            pcall(function() marker:K2_SetActorLocation({ X = p.x, Y = p.y, Z = p.z }, false, {}, true) end)
            note(id, p)
        end
    end
    pcall(paintCompass)
    for id, marker in pairs(Team.markers) do
        if not Avatar.puppets[id] then
            Hud.forgetMarker(marker)
            Team.markers[id], recent[id], painted[id] = nil, nil, nil
        end
    end
end)

World.listen("stop", clear)
World.listen("start", function() Team.markers, recent, painted = {}, {}, {} end)

return Team
