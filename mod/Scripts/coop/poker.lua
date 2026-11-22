-- Poker with La Ballena, at his own table in the night club's basement.
--
-- La Ballena sits at the round table in the corner of the lounge. The mod lays a felt on it,
-- and up to three players take the armchairs round it for Texas hold'em, no limit, with him
-- as the player who never gets up: the dealer's button goes round the table and the two
-- seats after it post the blinds, so with one player it is heads up against him. A player
-- buys chips for cash from the pockets and gets what the chips are worth back on getting up
-- (in the middle of a hand that is a fold: what was bet stays in the pot). La Ballena puts
-- as much on the table as the player with the most chips has.
-- The host's game runs the table (coop/holdem.lua has the rules and how La Ballena plays);
-- everybody is told what all can see, and each player their own two cards.
-- La Ballena brings a fixed sum every night. When he has lost it he plays no more that
-- night. On a night on which he had also won at least that sum from the players (so that
-- he lost twice the sum in all), he closes the club instead: everybody in it stands in
-- front of the door.
-- The first meeting of his storyline uses this table and one of its armchairs: in a game in
-- which that meeting is still to come, the table is left to it.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Hud = require("coop.hud")
local Look = require("coop.look")
local Screen = require("coop.screen")
local Third = require("coop.third")
local Casino = require("coop.casino")
local Holdem = require("coop.holdem")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_POKER_GEN") or 0) + 1
_G.DDSMP_POKER_GEN = GEN
local function live() return rawget(_G, "DDSMP_POKER_GEN") == GEN end

local Poker = { seated = false }

---------------------------------------------------------------- where everything is

local FLOOR = -185
local SMOKE_BREAK, LOUNGE_POSE = 5, 4       -- (Avatar.EMOTES: the two seated poses used here)
local CX, CY = 15340, -8820          -- the middle of La Ballena's table
local TOP = -104.4                   -- its top (the table is 90 across from the middle)
local FELT = 77                      -- how far the felt reaches
local LOUNGE = "/Game/Levels/stream_ballenaClub.stream_ballenaClub:PersistentLevel."
local CITY = "/Game/Levels/theCity.theCity:PersistentLevel."
local BAR = "/Game/ModularBarInterior/"
-- What stood on the table: the plate and the glasses in the middle go; one glass is set
-- beside La Ballena's ashtray.
local AWAY = { LOUNGE .. "SM_Plate_3", CITY .. "SM_Glass_250", CITY .. "SM_Glass_9" }
local HIS_GLASS = { path = CITY .. "SM_Glass_254", x = CX + 46, y = CY - 56 }
-- His ashtray stands on the wood: it is lifted onto the felt (which is this thick).
local FELT_THICK = 0.6
local ASHTRAY = LOUNGE .. "popielniczka2_2"
-- The seats in the order of the deal (clockwise seen from above): La Ballena's armchair,
-- then the three armchairs of the lounge. `x`, `y` is where the chair stands.
local HOUSE = 1
local SEATS = {
    { x = 15478.8, y = -8817.0, chips = 26 },
    { x = 15439.8, y = -8673.2, stand = { x = 15440, y = -8580 }, pose = SMOKE_BREAK },
    { x = 15299.0, y = -8668.6, stand = { x = 15215, y = -8720 } },
    { x = 15352.4, y = -8988.2, stand = { x = 15257, y = -8978 } },
}
for _, s in ipairs(SEATS) do
    s.angle = math.deg(math.atan(s.y - CY, s.x - CX))
    s.yaw = s.angle + 180                       -- looking at the middle of the table
    local r = math.rad(s.angle)
    s.ux, s.uy = math.cos(r), math.sin(r)       -- from the middle towards the seat
    s.vx, s.vy = -s.uy, s.ux                    -- to the left of whoever sits there
end
-- A point on the felt in front of a seat: `out` from the middle, `left` to the sitter's left.
local function spot(index, out, left)
    local s = SEATS[index]
    return CX + s.ux * out + s.vx * (left or 0), CY + s.uy * out + s.vy * (left or 0)
end

-- How a player sits. The armchairs stand well back from the table, so the figure sits in
-- one of two of the emote wheel's poses instead of the card table's: on the edge of the seat
-- (Smoke break) or leaning back (Lounge), one of them by chance; the armchair by the column
-- always the first (a keg stands against its side). Both poses set the figure behind where
-- the player is (Avatar.EMOTES: back, side), so the player is held that far in front of the
-- armchair, which is also where the view from the seat is: at the table's edge.
-- `pose[id]`: where the hips go, from the armchair's middle towards the table (fwd) and to
-- the sitter's right, and how much higher than the pose's own height.
local tune = { sit = 90, eye = 120, pitch = -30,
    pose = { [SMOKE_BREAK] = { fwd = 12, right = 0, up = 0 }, [LOUNGE_POSE] = { fwd = 8, right = 0, up = 0 } } }
Poker.tune = tune
-- The view from behind: the figure sits well behind where the player is held, so the view
-- is that much further back than at the card table (about 85 behind the figure's head and
-- 110 above it, the view turned 30 degrees down). The leaning pose holds the player to
-- one side of the armchair: its view is moved back over the armchair's middle.
Third.tune.armchair = { back = 214, side = 0, up = 31 }
Third.tune.armchairLounge = { back = 214, side = 34, up = 31 }
local function viewShape(pose) return pose == LOUNGE_POSE and "armchairLounge" or "armchair" end

local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
local SUITS = { "\226\153\160", "\226\153\165", "\226\153\166", "\226\153\163" }   -- spade heart diamond club
local TURN_SECONDS = 45
local DEFAULT_BUYINS = { 500, 1000, 2500, 5000 }

local function active() return Casino.active() and Core.config.Poker ~= false end
local function key(name) return tostring(Core.config[name] or "?") end
local function me() return Net.S.me or "me" end
local function authority() return not World.shared() or World.role == "host" end
local function blinds()
    local b = Core.config.PokerBlinds
    local sb, bb = 25, 50
    if type(b) == "table" and tonumber(b[1]) and tonumber(b[2]) and b[1] > 0 and b[2] >= b[1] then sb, bb = math.floor(b[1]), math.floor(b[2]) end
    return sb, bb
end
local function buyIns()
    local list = Core.config.PokerBuyIns
    if type(list) ~= "table" or #list == 0 then list = DEFAULT_BUYINS end
    return list
end
local function nightLimit()
    local v = tonumber(Core.config.PokerNightLimit)
    if not v or v <= 0 then v = 5000 end
    return math.floor(v)
end

local function asset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if valid(o) then return o end
    return nil
end

---------------------------------------------------------------- the table's things

local set = nil          -- { owner, actors, mat, button }
local laid = {}          -- key -> { sig, actors }: cards and chips that come and go
local found = {}

local missed = {}
local function lookup(path)
    local a = found[path]
    if a and Core.alive(a) then return a end
    found[path] = nil
    if os.clock() < (missed[path] or 0) then return nil end
    -- (a piece of the lounge is only there while the lounge's level is: looking for it by
    -- name costs tens of milliseconds, so not while it cannot be there)
    if path:sub(1, #LOUNGE) == LOUNGE then
        local lounge = Casino.lounge and Casino.lounge() or nil
        if not lounge or not lounge.loaded then return nil end
    end
    a = StaticFindObject(path)
    if Core.alive(a) then
        found[path] = a
        return a
    end
    missed[path] = os.clock() + 10
    return nil
end

local function clearLaid(k)
    local cur = laid[k]
    laid[k] = nil
    if not cur or World.gone then return end
    for _, a in ipairs(cur.actors) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
end

local function clearSet()
    for k in pairs(laid) do clearLaid(k) end
    if not set then return end
    for _, a in ipairs(set.actors) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
    for _, path in ipairs(AWAY) do
        local a = found[path]
        pcall(function() if a and Core.alive(a) then a:SetActorHiddenInGame(false) end end)
    end
    pcall(function()
        local a = found[HIS_GLASS.path]
        if a and Core.alive(a) and set.glassWas then a:K2_SetActorLocation(set.glassWas, false, {}, true) end
    end)
    pcall(function()
        local a = found[ASHTRAY]
        if a and Core.alive(a) then
            local l = a:K2_GetActorLocation()
            a:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = TOP }, false, {}, true)
        end
    end)
    set = nil
end

local function buildSet()
    local player = World.player()
    local world = player:GetWorld()
    set = { actors = {}, owner = player:GetAddress() }
    local KML = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    local function col(r, g, b) return { R = r, G = g, B = b, A = 1 } end
    local function dyed(parent, params)
        local base = asset(BAR .. "Materials/" .. parent .. "." .. parent:match("[^/]+$"))
        if not base then return nil end
        local m = KML:CreateDynamicMaterialInstance(player, base, FName("None"))
        for name, v in pairs(params) do
            if type(v) == "table" then m:SetVectorParameterValue(FName(name), v) else m:SetScalarParameterValue(FName(name), v) end
        end
        return m
    end
    local function plastic(r, g, b)
        return dyed("Plastic/MI_Plastic_White", { ["Base Color"] = col(r, g, b), ["Noise Color"] = col(r, g, b), ["Color Intensity"] = 1, ["Dirt Intensity"] = 0 })
    end
    -- (the card table's felt and chips)
    local MAT = {
        felt = dyed("Fabric/MI_Velvet_Blue", { ["Color 1"] = col(0.003, 0.036, 0.012), ["Color 2"] = col(0.005, 0.055, 0.02),
            ["Specular"] = 0, ["Metallic"] = 0, ["Roughness Intensity"] = 6, ["Use Wear"] = 0, ["Use Dirt"] = 0 }),
        white = plastic(0.9, 0.9, 0.86), red = plastic(0.55, 0.02, 0.02), blue = plastic(0.02, 0.06, 0.4),
        black = plastic(0.015, 0.015, 0.015),
    }
    set.mat = MAT
    local function shape(kind, x, y, z, sx, sy, sz, yaw, mat)
        local a = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw or 0, Roll = 0 })
        set.actors[#set.actors + 1] = a
        a:SetMobility(2)
        a.StaticMeshComponent:SetStaticMesh(asset("/Engine/BasicShapes/" .. kind .. "." .. kind))
        a:SetActorScale3D({ X = sx, Y = sy, Z = sz })
        if mat then a.StaticMeshComponent:SetMaterial(0, mat) end
        a:SetActorEnableCollision(false)
        return a
    end
    shape("Cylinder", CX, CY, TOP + FELT_THICK / 2, FELT * 2 / 100, FELT * 2 / 100, FELT_THICK / 100, 0, MAT.felt)
    -- the deck, at La Ballena's left hand
    local dx, dy = spot(HOUSE, 44, 46)
    shape("Cube", dx, dy, TOP + 1.9, 0.063, 0.088, 0.026, SEATS[HOUSE].angle + 12, MAT.blue)
    -- the dealer's button: a white disc with a black middle (out of sight until a hand is dealt)
    set.button = shape("Cylinder", CX, CY, TOP - 30, 0.07, 0.07, 0.008, 0, MAT.white)
    set.buttonDot = shape("Cylinder", CX, CY, TOP - 30, 0.034, 0.034, 0.0085, 0, MAT.black)
    -- every colour stays worn by something for as long as the table stands (a material
    -- nothing wears is thrown away by the engine): a few loose chips by the deck
    local lx, ly = spot(HOUSE, 52, 54)
    shape("Cylinder", lx, ly, TOP + 0.6 + 0.33, 0.04, 0.04, 0.0066, 0, MAT.red)
    log("Poker: La Ballena's table is laid (%d pieces)", #set.actors)
end

-- What stood on the table is put away, again and again (the lounge's own pieces are made
-- anew every time its level is loaded).
local function putAway()
    if not set then return end
    for _, path in ipairs(AWAY) do
        local a = lookup(path)
        if a then pcall(function() if a.bHidden ~= true then a:SetActorHiddenInGame(true) end end) end
    end
    local g = lookup(HIS_GLASS.path)
    if g then
        pcall(function()
            local l = g:K2_GetActorLocation()
            if math.abs(l.X - HIS_GLASS.x) > 1 or math.abs(l.Y - HIS_GLASS.y) > 1 or l.Z < TOP + FELT_THICK then
                set.glassWas = set.glassWas or { X = l.X, Y = l.Y, Z = l.Z }
                g:SetMobility(2)
                g:K2_SetActorLocation({ X = HIS_GLASS.x, Y = HIS_GLASS.y, Z = TOP + FELT_THICK + 0.08 }, false, {}, true)
            end
        end)
    end
    -- (a piece of the lounge: back on the wood every time the lounge's level is loaded)
    local ash = lookup(ASHTRAY)
    if ash then
        pcall(function()
            local l = ash:K2_GetActorLocation()
            if l.Z < TOP + FELT_THICK - 0.05 then
                ash:SetMobility(2)
                ash:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = TOP + FELT_THICK + 0.05 }, false, {}, true)
            end
        end)
    end
end

local function ensureSet()
    local player = World.player()
    if not player then return end
    if set and (set.owner ~= player:GetAddress() or not valid(set.actors[1])) then
        set = nil       -- another world: its actors went with it
        for k in pairs(laid) do laid[k] = nil end
        for k in pairs(found) do found[k] = nil end
    end
    if not set and Casino.nearClub() then
        local ok, e = xpcall(buildSet, debug.traceback)
        if not ok then
            log("Poker: could not lay the table: %s", tostring(e))
            clearSet()
        end
    end
end

-- Lays what `build` makes under a name, unless what lies there already is the same.
local function lay(k, sig, build)
    local cur = laid[k]
    if cur and cur.sig == sig then return end
    clearLaid(k)
    if sig == nil or not set then return end
    local list = {}
    laid[k] = { sig = sig, actors = list }
    local ok, e = pcall(build, list)
    if not ok then log("Poker: laying %s: %s", tostring(k), tostring(e)) end
end

local CARD_W, CARD_H, CARD_STEP = 9.0, 12.6, 9.8

-- A row of cards centred on (cx, cy), to be read by somebody looking in the direction
-- `yaw`. A code is rank * 10 + suit, 0 for a card lying face down.
local function cardsAt(list, codes, cx, cy, yaw)
    local world = World.player():GetWorld()
    local r = math.rad(yaw)
    local rx, ry = -math.sin(r), math.cos(r)
    local cube = asset("/Engine/BasicShapes/Cube.Cube")
    for i, c in ipairs(codes) do
        local off = (i - (#codes + 1) / 2) * CARD_STEP
        local x, y, z = cx + rx * off, cy + ry * off, TOP + 0.75 + i * 0.02
        local a = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw, Roll = 0 })
        list[#list + 1] = a
        a:SetMobility(2)
        a.StaticMeshComponent:SetStaticMesh(cube)
        a:SetActorScale3D({ X = CARD_H / 100, Y = CARD_W / 100, Z = 0.0012 })
        a:SetActorEnableCollision(false)
        local rank, suit = c // 10, c % 10
        a.StaticMeshComponent:SetMaterial(0, c == 0 and set.mat.blue or set.mat.white)
        if c ~= 0 and RANKS[rank] then
            -- (made upright and laid flat afterwards, as at the card table)
            local t = world:SpawnActor(StaticFindObject("/Script/Engine.TextRenderActor"), { X = x, Y = y, Z = z + 0.25 }, { Pitch = 0, Yaw = 0, Roll = 0 })
            t:K2_SetActorRotation({ Pitch = 90, Yaw = yaw + 180, Roll = 0 }, false)
            list[#list + 1] = t
            local text = t.TextRender
            text:K2_SetText(FText(RANKS[rank]))
            text:SetWorldSize(rank == 10 and 6.8 or 8.6)
            text:SetHorizontalAlignment(1)
            pcall(function() text:SetVerticalAlignment(1) end)
            local red = suit == 2 or suit == 3
            text:SetTextRenderColor(red and { R = 190, G = 10, B = 10, A = 255 } or { R = 8, G = 8, B = 8, A = 255 })
        end
    end
end

-- Chips worth `amount` as stacks side by side (white 25, red 100, blue 500, black 1000),
-- centred on (cx, cy), the row running along (rx, ry).
local function chipsAt(list, amount, cx, cy, rx, ry)
    local world = World.player():GetWorld()
    local left = math.floor(amount / 25) * 25
    if left <= 0 and amount > 0 then left = 25 end
    local n25 = (left % 100) // 25
    left = left - n25 * 25
    if left >= 200 then n25, left = n25 + 4, left - 100 end
    local n100 = (left % 500) // 100
    left = left - n100 * 100
    if left >= 1000 then n100, left = n100 + 5, left - 500 end
    local n500 = (left % 1000) // 500
    left = left - n500 * 500
    if left >= 2000 then n500, left = n500 + 2, left - 1000 end
    local stacks = {}
    local n1000 = left // 1000
    while n1000 > 0 do
        local n = math.min(n1000, 12)
        stacks[#stacks + 1] = { n, set.mat.black }
        n1000 = n1000 - n
        if #stacks >= 4 then break end
    end
    if n500 > 0 then stacks[#stacks + 1] = { n500, set.mat.blue } end
    if n100 > 0 then stacks[#stacks + 1] = { n100, set.mat.red } end
    if n25 > 0 then stacks[#stacks + 1] = { n25, set.mat.white } end
    local cyl = asset("/Engine/BasicShapes/Cylinder.Cylinder")
    for i, st in ipairs(stacks) do
        local off = (i - (#stacks + 1) / 2) * 5.0
        local n = st[1]
        local a = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"),
            { X = cx + rx * off, Y = cy + ry * off, Z = TOP + 0.6 + n * 0.165 }, { Pitch = 0, Yaw = 0, Roll = 0 })
        list[#list + 1] = a
        a:SetMobility(2)
        a.StaticMeshComponent:SetStaticMesh(cyl)
        a:SetActorScale3D({ X = 0.04, Y = 0.04, Z = n * 0.0033 })
        a.StaticMeshComponent:SetMaterial(0, st[2])
        a:SetActorEnableCollision(false)
    end
end

---------------------------------------------------------------- what everybody knows of the table

local view = nil         -- the table as the host last told it (see publicState)
local viewAt = 0
local mine = nil         -- our own two cards: { n = hand, c = { code, code } }
local seat = nil         -- the armchair we have taken: { index, place, owner, hud, behind, z }
local my = { state = nil, stack = 0 }       -- "buyin" (no chips yet), "asked", "in"
local scr, shown = nil, {}
local render

local function emptyView()
    local sb, bb = blinds()
    local v = { n = 0, ph = "idle", bt = 0, u = 0, bd = {}, pt = 0, cu = 0, sb = sb, bb = bb, s = {} }
    for i = 1, #SEATS do v.s[i] = { i = "", k = 0, b = 0, f = 0, a = 0, h = 0 } end
    v.s[HOUSE].i = "B"
    return v
end

local function nameOf(id)
    if id == "B" then return "LA BALLENA" end
    if id == me() then return "YOU" end
    return tostring(Net.name(id)):upper()
end

-- The direction in which we look at the table.
local function viewerYaw()
    if seat then return SEATS[seat.index].yaw end
    local l = World.player():K2_GetActorLocation()
    return math.deg(math.atan(CY - l.Y, CX - l.X))
end

-- The cards and chips on the felt, from what the host told.
local function drawTable()
    if not set or not World.player() then return end
    local v = view or emptyView()
    local facing = math.floor(viewerYaw() / 20 + 0.5) * 20
    local streetBets = 0
    for i, s in ipairs(v.s) do
        local own = seat ~= nil and seat.index == i
        -- the two cards: face down, or turned over at the end; our own are on our screen
        local codes = nil
        if s.h == 1 and s.f ~= 1 and not own and v.ph ~= "idle" then
            codes = (type(s.c) == "table" and #s.c == 2) and s.c or { 0, 0 }
        end
        local st = SEATS[i]
        local x, y = spot(i, 56)
        local turned = codes and codes[1] ~= 0
        lay("hole" .. i, codes and (table.concat(codes, ",") .. (turned and ("/" .. facing) or "")) or nil, function(list)
            cardsAt(list, codes, x, y, turned and facing or SEATS[i].yaw)
        end)
        -- the chips they have, and what they have bet in this round
        local sx, sy = spot(i, 62, st.chips or -24)
        lay("stack" .. i, (s.i ~= "" and s.k > 0) and tostring(s.k) or nil, function(list) chipsAt(list, s.k, sx, sy, st.vx, st.vy) end)
        local bx, by = spot(i, 40)
        lay("bet" .. i, (s.b or 0) > 0 and tostring(s.b) or nil, function(list) chipsAt(list, s.b, bx, by, st.vx, st.vy) end)
        streetBets = streetBets + (s.b or 0)
    end
    local middle = (v.pt or 0) - streetBets
    if v.ph == "showdown" then middle = 0 end       -- (it has gone to the winner's chips)
    lay("pot", middle > 0 and tostring(middle) or nil, function(list) chipsAt(list, middle, CX - 24, CY, 0, 1) end)
    -- the cards in the middle: seated we have them on our screen
    local board = (not Poker.seated and type(v.bd) == "table" and #v.bd > 0) and v.bd or nil
    lay("board", board and table.concat(board, ",") or nil, function(list) cardsAt(list, board, CX, CY, 0) end)
    -- the dealer's button
    pcall(function()
        local at = SEATS[v.bt or 0]
        if at and v.ph ~= "idle" then
            local x, y = spot(v.bt, 62, (at.chips or -24) > 0 and -22 or 22)
            if set.buttonAt ~= v.bt then
                set.buttonAt = v.bt
                set.button:K2_SetActorLocation({ X = x, Y = y, Z = TOP + 1.0 }, false, {}, true)
                set.buttonDot:K2_SetActorLocation({ X = x, Y = y, Z = TOP + 1.03 }, false, {}, true)
            end
        elseif set.buttonAt ~= 0 then
            set.buttonAt = 0
            set.button:K2_SetActorLocation({ X = CX, Y = CY, Z = TOP - 30 }, false, {}, true)
            set.buttonDot:K2_SetActorLocation({ X = CX, Y = CY, Z = TOP - 30 }, false, {}, true)
        end
    end)
end

---------------------------------------------------------------- La Ballena's night

-- What he has left of tonight's money, and whether he has shut the club. Kept through a
-- reload of the same night (a save loaded again gives him nothing back).
local night = rawget(_G, "DDSMP_POKER_NIGHT") or {}
_G.DDSMP_POKER_NIGHT = night

-- The club's night runs past midnight: the hours before noon belong to the evening before.
local function nightKey()
    local day, hour = nil, nil
    pcall(function() day = Core.find("BP_WorldTimeAndConditions_C"):GetCurrentIntDay() end)
    pcall(function() hour = Core.find("dayTimeControler_C").curHour end)
    if type(day) ~= "number" or type(hour) ~= "number" then return nil end
    return hour >= 12 and day or day - 1
end

local closedSeen = false     -- this game has acted on the club being shut
local refusedSeen = false    -- ... and on La Ballena playing no more tonight

function Poker.closed()
    if authority() then return night.closed == true and (night.key == nil or night.key == nightKey()) end
    return view ~= nil and view.cl == 1
end
Casino.closed = Poker.closed

-- He is out of money for tonight and plays no more (the club stays open).
function Poker.refuses()
    if authority() then return night.out == true and (night.key == nil or night.key == nightKey()) end
    return view ~= nil and view.rf == 1
end

local FRONT = { x = 14210, y = -7640, z = 200, yaw = -45 }
Poker.FRONT = FRONT

local function ballenaSays(words, seconds)
    local ok = pcall(function()
        local player = World.player()
        local class = StaticFindObject("/Game/GUI/narratorSubtitlesWidget.narratorSubtitlesWidget_C")
        if not valid(class) then error("no subtitles") end
        local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(player, class, nil)
        w:Setup(FText(words), seconds, FText("LA BALLENA"))
        w:AddToViewport(0)
    end)
    if not ok then Hud.toast("La Ballena: " .. words, seconds) end
end

-- The club is shut: whoever sits anywhere in it gets up (and is paid what is theirs), and
-- whoever is inside stands in front of the door.
local function throwOut()
    local player = World.player()
    if not player then return end
    pcall(function() if Poker.seated then Poker.leave() end end)
    pcall(function() if Casino.seated then Casino.leave() end end)
    pcall(function()
        local Slots = package.loaded["coop.slots"]
        if type(Slots) == "table" and Slots.seated then Slots.leave() end
    end)
    local inside = false
    pcall(function() inside = Casino.insideClub(player) end)
    if inside then
        pcall(function()
            player:K2_SetActorLocation({ X = FRONT.x, Y = FRONT.y, Z = FRONT.z }, false, {}, true)
            player.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 }
            player:GetController():SetControlRotation({ Pitch = 0, Yaw = FRONT.yaw, Roll = 0 })
        end)
        ballenaSays("That was my money for tonight. The club is closed. Everybody out.", 6)
    end
    pcall(function()
        local manager = Core.find("ballenaClubManager_C")
        if manager then manager:closeClub() end
    end)
end

-- The game opens the club's doors by its own clock (and the card room lets everybody in):
-- on a night La Ballena has shut it, they close again at once.
local CLUB = "/Game/WorldControlers/Gangs/ballenaClubManager.ballenaClubManager_C"
local shutting = false
Core.Hooks.add(CLUB .. ":openClub", function(context)
    if not live() or shutting or not Poker.closed() then return end
    local manager = context:get()
    if not valid(manager) then return end
    shutting = true
    pcall(function() manager:closeClub() end)
    shutting = false
end)

---------------------------------------------------------------- the host's side

local tbl = nil          -- the table (coop/holdem.lua), in the game that runs it
local ctl = {}           -- when the next thing happens
local publish
-- Chips of players who dropped out of the world while they sat at the table: theirs again
-- when they are back. And what a player took along on getting up, should they ask twice.
local owed = rawget(_G, "DDSMP_POKER_OWED") or {}
_G.DDSMP_POKER_OWED = owed
local lastLeft = {}

local function seatOfId(id)
    if not tbl then return nil end
    for i, s in ipairs(tbl.seats) do if s.id == id then return i end end
    return nil
end

local function ensureTable()
    if tbl then return end
    local sb, bb = blinds()
    tbl = Holdem.new({ seats = #SEATS, sb = sb, bb = bb, random = math.random })
    local k = nightKey()
    if night.stack == nil or (k ~= nil and night.key ~= k) then
        night.key, night.stack, night.closed, night.out, night.won, night.lost = k, nightLimit(), false, false, 0, 0
    end
    tbl:sit(HOUSE, "B", 0)
    ctl = { serial = 0 }
end

-- La Ballena puts as much on the table as the player with the most chips has (and no more
-- than he has left of tonight's money). Between two hands. True when it changed.
local function matchHouse()
    local t = tbl
    if not t or t.phase ~= "idle" then return false end
    local top = 0
    for i, s in ipairs(t.seats) do
        if i ~= HOUSE and s.id ~= nil and not s.leaving then top = math.max(top, s.stack) end
    end
    if top == 0 then return false end
    local want = math.min(night.stack or 0, top)
    if t.seats[HOUSE].stack == want then return false end
    t.seats[HOUSE].stack = want
    return true
end

local function publicState()
    local t = tbl
    local v = { n = t.hand, ph = t.phase, bt = t.button, u = t.turn or 0, bd = t.board, pt = t:pot(), cu = t.current,
        sb = t.sb, bb = t.bb, s = {}, cl = Poker.closed() and 1 or 0, rf = Poker.refuses() and 1 or 0 }
    if t.phase == "showdown" then v.pt = 0 end
    local showing = t.open or (t.phase == "showdown" and t.result and t.result.showdown)
    for i, s in ipairs(t.seats) do
        local e = { i = s.id or "", k = s.stack, b = s.bet or 0, f = s.folded and 1 or 0, a = s.allin and 1 or 0, h = s.inHand and 1 or 0, l = s.last }
        if showing and s.inHand and not s.folded and s.cards then e.c = { s.cards[1], s.cards[2] } end
        if t.phase == "showdown" then e.w, e.nm = s.won, s.name end
        v.s[i] = e
    end
    if t.turn then
        local legal = t:legal(t.turn)
        v.lg = { c = legal.call, k = legal.check and 1 or 0, r = legal.raise and 1 or 0, lo = legal.minTo, hi = legal.maxTo }
        if ctl.turnMark == t.hand * 1000000 + (ctl.serial or 0) and ctl.turnUntil then
            v.tl = math.max(0, math.ceil(ctl.turnUntil - os.clock()))
        end
    end
    if t.result and t.phase == "showdown" then v.sd = t.result.showdown and 1 or 0 end
    return v
end

local onView

publish = function()
    if not tbl then return end
    local v = publicState()
    if World.shared() then
        for _, id in ipairs(World.targets()) do Net.send("pks", v, id) end
    end
    ctl.sentAt = os.clock()
    onView(v)
end

-- The cards of a new hand: each player is told their own.
local function tellCards()
    for i, s in ipairs(tbl.seats) do
        if i ~= HOUSE and s.inHand and s.cards then
            if s.id == me() then
                mine = { n = tbl.hand, c = { s.cards[1], s.cards[2] } }
            elseif World.shared() and World.inWorld[s.id] then
                Net.send("pkh", { n = tbl.hand, c = { s.cards[1], s.cards[2] } }, s.id)
            end
        end
    end
end

local function answer(id, data)
    if id == me() then
        Poker.reply(data)
    elseif World.shared() then
        Net.send("pkr", data, id)
    end
end

local function hostSit(id, index, amount)
    ensureTable()
    amount = math.floor(tonumber(amount) or 0)
    index = math.floor(tonumber(index) or 0)
    local ok = amount > 0 and amount <= 1000000 and index ~= HOUSE and SEATS[index] ~= nil and not Poker.closed() and not Poker.refuses() and seatOfId(id) == nil
    if ok then ok = tbl:sit(index, id, amount) end
    if not ok then return answer(id, { r = "seat", v = amount }) end
    publish()
end

local function hostAdd(id, amount)
    amount = math.floor(tonumber(amount) or 0)
    local index = seatOfId(id)
    local s = index and tbl.seats[index]
    local ok = s ~= nil and amount > 0 and amount <= 1000000 and s.stack == 0 and not Poker.closed() and not Poker.refuses()
        and (not s.inHand or tbl.phase == "idle")
    if ok then ok = tbl:add(index, amount) end
    if not ok then return answer(id, { r = "add", v = amount }) end
    publish()
end

local function hostLeave(id)
    local index = seatOfId(id)
    if not index then
        -- (asked again: the answer to the first time, once more)
        local was = lastLeft[id]
        return answer(id, { r = "left", v = (was and os.clock() - was.at < 60) and was.v or 0 })
    end
    local chips = tbl:leave(index)
    lastLeft[id] = { v = chips, at = os.clock() }
    ctl.serial = (ctl.serial or 0) + 1
    answer(id, { r = "left", v = chips })
    publish()
end

local function hostAct(id, kind, amount)
    local index = seatOfId(id)
    if not index or tbl.turn ~= index then return end
    if kind ~= "fold" and kind ~= "check" and kind ~= "call" and kind ~= "raise" then return end
    if tbl:act(index, kind, amount) then
        ctl.serial = ctl.serial + 1
        publish()
    end
end

local function toHost(data)
    if authority() then
        ensureTable()
        local id = me()
        if data.a == "sit" then hostSit(id, data.s, data.v)
        elseif data.a == "add" then hostAdd(id, data.v)
        elseif data.a == "leave" then hostLeave(id)
        else hostAct(id, data.a, data.v) end
    else
        Net.send("pka", data, World.host or Net.S.owner)
    end
end

Net.on("pka", function(sender, data)
    if not live() or World.role ~= "host" or not World.inWorld[sender] or not active() then return end
    ensureTable()
    if data.a == "sit" then hostSit(sender, data.s, data.v)
    elseif data.a == "add" then hostAdd(sender, data.v)
    elseif data.a == "leave" then hostLeave(sender)
    else hostAct(sender, data.a, data.v) end
end)

-- The table's clock, in the game that runs it.
Core.every(0.25, function()
    if not live() or not authority() or not active() or not World.player() then return end
    if not tbl and not Casino.nearClub() and not World.shared() then return end
    ensureTable()
    local t, now = tbl, os.clock()
    -- a new night: he comes with the same sum as every night (whatever he won the night
    -- before is not added to it), and the club is open again
    local k = nightKey()
    if k ~= nil and k ~= night.key and t.phase == "idle" then
        night.key, night.stack, night.closed, night.out, night.won, night.lost = k, nightLimit(), false, false, 0, 0
        t.seats[HOUSE].stack = 0
        matchHouse()
        closedSeen, refusedSeen = false, false
        publish()
    end
    -- players who are gone
    for i, s in ipairs(t.seats) do
        if i ~= HOUSE and s.id ~= nil then
            local gone = (s.id == me()) and not Poker.seated or (s.id ~= me() and not World.inWorld[s.id])
            if gone then
                local id = s.id
                local chips = t:leave(i)
                if id ~= me() and chips > 0 then owed[id] = (owed[id] or 0) + chips end
                ctl.serial = ctl.serial + 1
                publish()
            end
        end
    end
    if Poker.closed() or Poker.refuses() then return end
    if t.phase == "idle" then
        local ready, humans = t:ready(), 0
        for _, i in ipairs(ready) do if i ~= HOUSE then humans = humans + 1 end end
        if (night.stack or 0) <= 0 then
            -- He has lost what he brought: no more cards tonight. If he had won at least
            -- that much from the players before (and so lost twice as much in all), he
            -- shuts the club as well.
            local limit = nightLimit()
            night.stack, night.out = 0, true
            t.seats[HOUSE].stack = 0
            night.closed = (night.won or 0) >= limit and (night.lost or 0) >= limit * 2
            log("Poker: La Ballena is out of money (won $%d, lost $%d tonight): %s", night.won or 0, night.lost or 0,
                night.closed and "the club closes for the night" or "he plays no more tonight")
            publish()
            return
        end
        if matchHouse() then
            publish()
            return
        end
        if humans >= 1 and #ready >= 2 then
            ctl.startAt = ctl.startAt or (now + 3)
            if now >= ctl.startAt then
                ctl.startAt = nil
                ctl.houseBefore = t.seats[HOUSE].stack
                if t:start() then
                    ctl.serial = ctl.serial + 1
                    tellCards()
                    publish()
                end
            end
        else
            ctl.startAt = nil
        end
    elseif t.phase == "showdown" then
        ctl.clearAt = ctl.clearAt or (now + (t.result and t.result.showdown and 7 or 3.5))
        if now >= ctl.clearAt then
            ctl.clearAt = nil
            -- what the hand made or cost him
            local change = t.seats[HOUSE].stack - (ctl.houseBefore or t.seats[HOUSE].stack)
            ctl.houseBefore = nil
            night.stack = math.max(0, (night.stack or 0) + change)
            if change > 0 then night.won = (night.won or 0) + change else night.lost = (night.lost or 0) - change end
            t:clear()
            ctl.startAt = now + 1.5
            publish()
        end
    elseif t.pending then
        ctl.stepAt = ctl.stepAt or (now + (t.open and 2.2 or 1.0))
        if now >= ctl.stepAt then
            ctl.stepAt = nil
            t:proceed()
            ctl.serial = ctl.serial + 1
            publish()
        end
    elseif t.turn then
        local mark = t.hand * 1000000 + ctl.serial
        if ctl.turnMark ~= mark then
            ctl.turnMark = mark
            ctl.thinkAt = now + 1.3 + math.random() * 2.2
            ctl.turnUntil = now + TURN_SECONDS
            if t.turn ~= HOUSE then publish() end       -- (the time the player has)
        end
        if t.turn == HOUSE then
            if now >= ctl.thinkAt then
                local kind, amount = Holdem.decide(t, HOUSE)
                if not (kind and t:act(HOUSE, kind, amount)) then
                    local legal = t:legal(HOUSE)
                    t:act(HOUSE, (legal and legal.check) and "check" or "fold")
                end
                ctl.serial = ctl.serial + 1
                publish()
            end
        elseif now > ctl.turnUntil then
            -- took too long: a check where that is free, otherwise the hand is given up
            local legal = t:legal(t.turn)
            t:act(t.turn, (legal and legal.check) and "check" or "fold")
            ctl.serial = ctl.serial + 1
            publish()
        end
    end
    -- now and then again, for players who came in later
    if World.shared() and now - (ctl.sentAt or 0) > 4 then publish() end
end)

World.listen("peer", function(id)
    if not live() or World.role ~= "host" then return end
    if tbl then pcall(function() Net.send("pks", publicState(), id) end) end
    if owed[id] then
        Core.after(10, function()
            if not live() or World.role ~= "host" or not World.inWorld[id] or not owed[id] then return end
            local chips = owed[id]
            owed[id] = nil
            Net.send("pkr", { r = "owed", v = chips }, id)
        end)
    end
end)

---------------------------------------------------------------- the screen of a seated player

local INK = { R = 0.03, G = 0.03, B = 0.03, A = 1 }
local CARD_RED = { R = 0.72, G = 0.03, B = 0.03, A = 1 }
local PAPER = { R = 0.93, G = 0.92, B = 0.88, A = 1 }
local timer = nil        -- the line that counts our seconds down: { widget, till }
local raising = false    -- the slider for a bet or raise is on the screen
local wager = nil        -- what it stands at: { n, ph, lo, hi, to }
local slider = nil       -- { widget, edit, confirm, value, label, step, typing }
local typingBet = false  -- the number under the slider has the keyboard (Core.typing is ours)
local AMBER = { R = 1, G = 0.78, B = 0.25, A = 1 }

-- (the card table's card)
local function card(code, width)
    local face
    if not code or code == 0 then
        face = scr.box({ R = 0.05, G = 0.1, B = 0.42, A = 1 }, scr.box({ R = 0.1, G = 0.2, B = 0.62, A = 1 }), math.max(3, width / 14))
    else
        local rank, suit = code // 10, code % 10
        local ink = (suit == 2 or suit == 3) and CARD_RED or INK
        local column = scr.new("VerticalBox")
        column:AddChildToVerticalBox(scr.text(RANKS[rank], "hud", width * 0.25, ink))
        column:AddChildToVerticalBox(scr.text(SUITS[suit], "hud", width * 0.2, ink))
        local big = column:AddChildToVerticalBox(scr.text(SUITS[suit], "hud", width * 0.4, ink))
        big:SetHorizontalAlignment(2)
        face = scr.box(PAPER, column)
        local pad = width / 12
        face:SetPadding({ Left = pad, Top = 2, Right = pad, Bottom = 2 })
    end
    return scr.sized(scr.box({ R = 0.04, G = 0.04, B = 0.04, A = 1 }, face, 2), width, width * 1.4)
end

local function put(widget, ax, ay, x, y, alignX)
    scr.place(widget, ax, ay, x, y, alignX)
    shown[#shown + 1] = widget
    return widget
end

local function button(label, scale, ax, ay, x, y, fn)
    local b = scr.button(label, scale, fn)
    put(b.widget, ax, ay, x, y)
    return b
end

local function act(kind, amount)
    if not Poker.seated or my.state ~= "in" or not view or view.u ~= seat.index then return end
    raising = false
    toHost({ a = kind, v = amount })
end
Poker.act = act

local function buy(amount)
    if not Poker.seated or (my.state ~= "buyin" and my.state ~= "in") then return end
    if not Casino.take(amount) then
        Hud.toast(string.format("You need $%d in cash for these chips", amount), 3)
        return render()
    end
    if my.state == "buyin" then
        my.state, my.asked, my.askedAt = "asked", amount, os.clock()
        toHost({ a = "sit", s = seat.index, v = amount })
    else
        my.added, my.addedAt = amount, os.clock()
        my.stack = my.stack + amount
        toHost({ a = "add", v = amount })
    end
    render()
end
Poker.buy = buy

-- What the host answered: a seat or chips that could not be had (the cash comes back), or
-- the chips we take along from the table.
function Poker.reply(data)
    local amount = math.max(0, math.floor(tonumber(data.v) or 0))
    if data.r == "seat" then
        if my.state == "asked" then
            Casino.pay(my.asked or amount)
            my.state, my.asked = "buyin", nil
            Hud.toast((view and view.cl == 1 and "La Ballena has closed the club for tonight")
                or (view and view.rf == 1 and "La Ballena plays no more tonight") or "This seat was just taken", 3)
            if Poker.seated then Poker.leave() end
        elseif my.due and my.due.asked then
            local due = my.due
            my.due = nil
            Casino.pay(due.amount)
        end
    elseif data.r == "add" then
        if my.added then
            Casino.pay(my.added)
            my.stack = math.max(0, my.stack - my.added)
            my.added = nil
            if render then render() end
        end
    elseif data.r == "left" then
        local due = my.due
        my.due = nil
        if due then
            local extra = Casino.pay(amount)
            if amount > 0 then Hud.toast(string.format("You take $%d from the table", amount), 4) end
            if extra ~= "" then Hud.toast(extra, 6) end
        end
    elseif data.r == "owed" then
        if amount > 0 then
            local extra = Casino.pay(amount)
            Hud.toast(string.format("You get the $%d you left at La Ballena's table", amount), 6)
            if extra ~= "" then Hud.toast(extra, 6) end
        end
    end
end

Net.on("pkr", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) then return end
    Poker.reply(data)
end)

Net.on("pkh", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) then return end
    if type(data.c) ~= "table" or #data.c ~= 2 then return end
    mine = { n = tonumber(data.n) or 0, c = { tonumber(data.c[1]) or 0, tonumber(data.c[2]) or 0 } }
    if render then render() end
end)

Net.on("pks", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) then return end
    if type(data.s) ~= "table" or #data.s ~= #SEATS or type(data.bd) ~= "table" then return end
    for _, s in ipairs(data.s) do
        if type(s) ~= "table" then return end
        s.i, s.k, s.b = tostring(s.i or ""), tonumber(s.k) or 0, tonumber(s.b) or 0
    end
    onView(data)
end)

onView = function(v)
    view, viewAt = v, os.clock()
    if seat and my.state then
        local s = v.s[seat.index]
        local own = s.i == me()
        if my.state == "asked" and own then
            my.state, my.asked = "in", nil
        elseif my.state == "in" and not own and not authority() then
            -- the table no longer has us (the game that ran it is another now): what we
            -- had comes back
            local extra = Casino.pay(my.stack)
            if my.stack > 0 then Hud.toast(string.format("You take $%d from the table", my.stack), 4) end
            if extra ~= "" then Hud.toast(extra, 6) end
            my.state, my.stack = "buyin", 0
        end
        if my.state == "in" and own then
            my.stack = s.k
            if s.k > 0 then my.added = nil end
        end
    end
    if v.u ~= (seat and seat.index or -1) then raising = false end
    if v.cl == 1 then
        if not closedSeen then
            closedSeen = true
            local ok, e = pcall(throwOut)
            if not ok then log("Poker: closing the club: %s", tostring(e)) end
        end
    else
        closedSeen = false
    end
    if v.rf == 1 then
        if not refusedSeen then
            refusedSeen = true
            -- he is done for tonight: whoever sits at his table gets up with their chips
            if v.cl ~= 1 then
                local sat = Poker.seated
                pcall(function() if Poker.seated then Poker.leave() end end)
                if sat then ballenaSays("That is enough for tonight. No more cards.", 5) end
            end
        end
    else
        refusedSeen = false
    end
    pcall(drawTable)
    if render then
        local ok, e = xpcall(render, debug.traceback)
        if not ok then log("Poker: the screen: %s", tostring(e)) end
    end
end

-- One line for a seat, in the top left corner of the screen: who, what they have, what they did.
local function seatLine(v, i, y)
    local s = v.s[i]
    if s.i == "" then return end
    local grey = s.f == 1 or (v.ph ~= "idle" and s.h ~= 1)
    local color = grey and Screen.GREY or Screen.WHITE
    if v.u == i then color = Screen.GREEN end
    local name = nameOf(s.i)
    if v.bt == i and v.ph ~= "idle" then name = name .. "   (D)" end
    -- beside the name: what they did last in this round of betting (or what they won)
    local did, didColor = nil, AMBER
    local won = v.ph == "showdown" and (s.w or 0) > 0
    if won then
        did, didColor = string.format("WINS $%d", s.w), Screen.GREEN
    elseif s.l then
        did = s.l .. ((s.b > 0 and s.l ~= "CHECK" and s.l ~= "FOLD") and string.format(" $%d", s.b) or "")
        if s.l == "FOLD" then didColor = Screen.GREY end
    end
    local row = scr.new("HorizontalBox")
    row:AddChildToHorizontalBox(scr.text(name, "button", 20, color))
    if did then
        local slot = row:AddChildToHorizontalBox(scr.text(did, "button", 20, didColor))
        pcall(function() slot:SetPadding({ Left = 26, Top = 0, Right = 0, Bottom = 0 }) end)
    end
    row:SetVisibility(3)
    put(row, 0.03, 0, 0, y - 15, 0)
    put(scr.text(string.format("$%d", s.k), "button", 15, grey and Screen.GREY or Screen.WHITE), 0.03, 0, 0, y + 12, 0)
    if s.h == 1 and s.f ~= 1 and v.ph ~= "idle" and not (seat and seat.index == i) then
        local codes = (type(s.c) == "table" and #s.c == 2) and s.c or { 0, 0 }
        local w = codes[1] ~= 0 and 54 or 34
        put(card(codes[1], w), 0.03, 0, 470, y, 0)
        put(card(codes[2], w), 0.03, 0, 476 + w, y, 0)
    end
end

render = function()
    if not scr or not scr.open or not Poker.seated or not seat then return end
    local v = view or emptyView()
    -- The slider is being used and nothing it depends on has changed: everything stays as
    -- it is (made anew, the slider would be torn out of the player's hand).
    if raising and slider and wager and v.u == seat.index and v.n == wager.n and v.ph == wager.ph and v.lg
        and v.lg.lo == wager.lo and v.lg.hi == wager.hi and v.lg.r == 1 then
        return
    end
    timer, slider = nil, nil
    if typingBet then typingBet, Core.typing = false, nil end
    scr.removeAll(shown)
    shown = {}
    local money = Casino.cash()
    local index = seat.index
    local s = v.s[index]
    local inSeat = my.state == "in" and s.i == me()
    put(scr.text(string.format("CASH  $%d", money), "button", 18), 0.86, 0.47)
    if inSeat then put(scr.text(string.format("CHIPS  $%d", s.k), "price", 24, Screen.GREEN), 0.86, 0.52) end

    -- everybody at the table
    local rows = {}
    for i = 1, #SEATS do if v.s[i].i ~= "" then rows[#rows + 1] = i end end
    -- (in the top left corner: La Ballena and the table stay in view)
    for n, i in ipairs(rows) do seatLine(v, i, 62 + (n - 1) * 96) end

    -- the cards in the middle and the pot
    local board = v.bd or {}
    for i, c in ipairs(board) do put(card(c, 84), 0.5, 0.55, (i - (#board + 1) / 2) * 96, 0) end
    if (v.pt or 0) > 0 then put(scr.text(string.format("POT  $%d", v.pt), "button", 18), 0.5, 0.435) end

    local dealtIn = inSeat and s.h == 1 and v.ph ~= "idle"
    local needChips = my.state == "buyin" or (inSeat and s.k == 0 and not dealtIn)
    if my.state == "asked" then
        put(scr.text("TAKING YOUR SEAT", "button", 26), 0.5, 0.7)
    elseif needChips then
        put(scr.text(my.state == "buyin" and "BUY IN" or "BUY MORE CHIPS", "button", 30), 0.5, 0.66)
        put(scr.text(string.format("BLINDS  $%d / $%d", v.sb or 0, v.bb or 0), "button", 18), 0.5, 0.71)
        local list = buyIns()
        for i, b in ipairs(list) do
            local btn = button(string.format("$%d", b), 1.7, 0.5, 0.78, (i - (#list + 1) / 2) * 170, 0, function() buy(b) end)
            if money < b or my.added then scr.enable(btn, false) end
        end
    elseif dealtIn then
        if s.f == 1 then
            put(scr.text("YOU FOLDED", "button", 22, Screen.GREY), 0.5, 0.8)
        elseif mine and mine.n == v.n then
            put(card(mine.c[1], 120), 0.5, 0.82, -66, 0)
            put(card(mine.c[2], 120), 0.5, 0.82, 66, 0)
            local label = "YOU"
            if #board >= 3 then
                local all = { mine.c[1], mine.c[2] }
                for _, c in ipairs(board) do all[#all + 1] = c end
                label = "YOU   " .. Holdem.name(all)
            end
            if s.a == 1 then label = label .. "   (ALL IN)" end
            put(scr.text(label, "button", 22), 0.5, 0.665)
        end
    elseif inSeat then
        put(scr.text(v.ph == "idle" and "THE NEXT HAND IS DEALT IN A MOMENT" or "HAND IN PROGRESS.  YOU ARE IN THE NEXT ONE", "button", 24), 0.5, 0.7)
    end

    -- whose turn, or how the hand ended
    local TURN_SIZE = 46
    if v.ph == "showdown" then
        local parts, iWon, iLost = {}, false, false
        for i = 1, #SEATS do
            local e = v.s[i]
            if (e.w or 0) > 0 then
                local who = nameOf(e.i ~= "" and e.i or "?")
                parts[#parts + 1] = string.format("%s %s $%d", who, who == "YOU" and "WIN" or "WINS", e.w)
                    .. ((v.sd == 1 and e.nm) and (" WITH " .. e.nm) or "")
                if i == index and inSeat then iWon = true end
            end
        end
        if inSeat and s.h == 1 and not iWon then iLost = true end
        local color = iWon and Screen.GREEN or (iLost and Screen.RED or Screen.WHITE)
        put(scr.text(table.concat(parts, "      "), "button", ({ 30, 20, 16 })[#parts] or 16, color), 0.5, 0.33)
    elseif v.u ~= 0 and v.s[v.u] then
        if v.u == index and inSeat then
            put(scr.text("YOUR TURN", "button", TURN_SIZE, Screen.GREEN), 0.5, 0.325)
            local lg = v.lg or { c = 0, k = 1, r = 0, lo = 0, hi = 0 }
            if v.tl then
                local till = viewAt + v.tl
                local w = put(scr.text("", "button", 22, Screen.RED), 0.5, 0.385)
                timer = { widget = w, till = till, shownLeft = nil }
            end
            if raising and lg.r == 1 then
                -- How much: a slider from the least allowed (far left) to everything (far
                -- right), and one number under it. The number follows the slider and can be
                -- typed over; the button under it places the bet.
                local lo, hi = lg.lo, lg.hi
                local step = math.max(1, v.sb or 25)
                local word = v.cu > 0 and "RAISE" or "BET"
                if not wager or wager.n ~= v.n or wager.ph ~= v.ph or wager.lo ~= lo or wager.hi ~= hi then
                    wager = { n = v.n, ph = v.ph, lo = lo, hi = hi, to = lo }
                end
                local function label(to) return to >= hi and "ALL IN" or word end
                local bar, value = nil, 0
                if hi > lo then
                    bar = scr.new("Slider")
                    value = (wager.to - lo) / (hi - lo)
                    pcall(function() bar:SetStepSize(math.min(1, step / (hi - lo))) end)
                    pcall(function() bar:SetSliderBarColor({ R = 0.75, G = 0.75, B = 0.72, A = 1 }) end)
                    pcall(function() bar:SetSliderHandleColor(Screen.GREEN) end)
                    -- (the engine's own slider is a hairline with a small handle: a bar and
                    -- a handle that can be seen and caught)
                    pcall(function() bar.WidgetStyle.BarThickness = 6 end)
                    pcall(function() bar.WidgetStyle.NormalThumbImage.ImageSize = { X = 16, Y = 34 } end)
                    pcall(function() bar.WidgetStyle.HoveredThumbImage.ImageSize = { X = 16, Y = 34 } end)
                    bar:SetValue(value)
                    put(scr.sized(bar, 300, 40), 0.86, 0.6)
                end
                local edit = scr.new("EditableText")
                pcall(function()
                    local style = edit.WidgetStyle
                    style.Font = scr.text("0", "button", 30).Font
                    style.ColorAndOpacity = { SpecifiedColor = Screen.GREEN, ColorUseRule = 0 }
                end)
                pcall(function() edit.SelectAllTextWhenFocused = true end)
                pcall(function() edit.Justification = 1 end)
                edit:SetText(FText(string.format("$%d", wager.to)))
                put(scr.sized(edit, 300, 44), 0.86, 0.655)
                local confirm = button(label(wager.to), 1.7, 0.86, 0.73, 0, 0, function() act("raise", wager.to) end)
                slider = { widget = bar, edit = edit, confirm = confirm, value = value, label = label, step = step }
                button("BACK", 1.4, 0.86, 0.8, 0, 0, function() raising = false render() end)
            else
                local fold = button("FOLD", 1.7, 0.86, 0.6, 0, 0, function() act("fold") end)
                if lg.k == 1 then
                    scr.enable(fold, false)
                    button("CHECK", 1.7, 0.86, 0.675, 0, 0, function() act("check") end)
                else
                    button(string.format(lg.c >= s.k and "CALL ALL IN  ($%d)" or "CALL  ($%d)", lg.c), 1.7, 0.86, 0.675, 0, 0, function() act("call") end)
                end
                local r = button(v.cu > 0 and "RAISE" or "BET", 1.7, 0.86, 0.75, 0, 0, function() raising = true render() end)
                if lg.r ~= 1 then scr.enable(r, false) end
            end
        else
            put(scr.text("WAITING FOR " .. nameOf(v.s[v.u].i), "button", TURN_SIZE), 0.5, 0.325)
        end
    end
    button("LEAVE TABLE", 1.4, 0.86, 0.93, 0, 0, function() Poker.leave() end)
end

-- The slider and the number under it, read while they are on the screen (neither tells
-- anybody when it is used). Moving the slider writes the number; typing a number moves the
-- slider (when the typing ends, with Enter or a click elsewhere, the number is brought into
-- what is allowed).
local function showWager(to, keepText)
    wager.to = to
    if slider.widget and wager.hi > wager.lo then
        slider.value = (to - wager.lo) / (wager.hi - wager.lo)
        pcall(function() slider.widget:SetValue(slider.value) end)
    end
    if not keepText then pcall(function() slider.edit:SetText(FText(string.format("$%d", to))) end) end
    scr.label(slider.confirm, slider.label(to))
end

Core.onTick(function()
    if not live() then return end
    if not slider or not raising or not wager or not scr or not scr.open then
        if typingBet then typingBet, Core.typing = false, nil end
        return
    end
    pcall(function()
        local lo, hi = wager.lo, wager.hi
        local focused = slider.edit:HasKeyboardFocus() == true
        if focused then
            if not typingBet then typingBet, Core.typing = true, true end
            local digits = slider.edit:GetText():ToString():gsub("%D", "")
            local n = tonumber(digits)
            if n and n ~= slider.typed then
                slider.typed = n
                if n >= lo and n <= hi then showWager(math.floor(n), true) end
            end
            return
        end
        if typingBet then
            -- the typing is over: the number that was typed, within what is allowed
            typingBet, Core.typing = false, nil
            local n = slider.typed or wager.to
            slider.typed = nil
            showWager(math.max(lo, math.min(hi, math.floor(n))))
            return
        end
        if not slider.widget then return end
        local value = slider.widget:GetValue()
        if math.abs(value - slider.value) < 0.0005 then return end
        slider.value = value
        local to = hi
        if value < 0.999 then
            to = math.floor((lo + (hi - lo) * value) / slider.step + 0.5) * slider.step
            to = math.max(lo, math.min(hi, to))
        end
        if to ~= wager.to then
            wager.to = to
            pcall(function() slider.edit:SetText(FText(string.format("$%d", to))) end)
            scr.label(slider.confirm, slider.label(to))
        end
    end)
end)
Poker.slider = function() return slider, wager end

-- The seconds a player has left, counted down in the last part of their time.
Core.every(0.5, function()
    if not live() or not timer or not scr or not scr.open then return end
    local left = math.max(0, math.ceil(timer.till - os.clock()))
    if left ~= timer.shownLeft then
        timer.shownLeft = left
        pcall(function() timer.widget:SetText(FText(left <= 20 and string.format("%d", left) or "")) end)
    end
end)

Poker.refresh = function() if render then render() end end
Poker.view = function() return view, mine, my, seat end
Poker.host = function() return tbl, ctl, night end

---------------------------------------------------------------- sitting down and getting up

-- While La Ballena's first meeting is still to come in this game (he waits for the player
-- at this table, and the player sits down in one of these armchairs for it), the table is
-- the story's.
local function meetingToCome()
    local yes = false
    pcall(function()
        local gang = Core.find("gangManager_C")
        yes = gang.ballenaUnlocked == true and gang.ballenaVisited ~= true
    end)
    return yes
end

local function turnedFrom(player, l, x, y)
    local at = nil
    pcall(function() at = player:GetController():GetControlRotation().Yaw end)
    if not at then return 0 end
    return math.abs(((math.deg(math.atan(y - l.Y, x - l.X)) - at + 180) % 360) - 180)
end

local function nearTable()
    local player = World.player()
    if not player or not active() or not set or Poker.closed() then return false end
    local l = player:K2_GetActorLocation()
    if math.abs(l.Z - (FLOOR + 90)) > 160 then return false end
    local d = (l.X - CX) ^ 2 + (l.Y - CY) ^ 2
    if d > 300 * 300 then return false end
    -- (away from the armchairs, only with the table in view: the card table is behind)
    if d > 150 * 150 and turnedFrom(player, l, CX, CY) > 80 then return false end
    return not meetingToCome()
end

local placeOf

-- The free armchair for the player: the one they look at (within 25 degrees), otherwise
-- the nearest. An armchair is taken when the table has somebody on it, or another player
-- sits in it (is where one of the two poses holds its sitter; standing beside it is not).
local function freeSeat()
    local player = World.player()
    local l = player:K2_GetActorLocation()
    local at = nil
    pcall(function() at = player:GetController():GetControlRotation().Yaw end)
    local v = view or emptyView()
    local near, nearD, seen, seenScore = nil, nil, nil, nil
    for index, st in ipairs(SEATS) do
        local taken = index == HOUSE or v.s[index].i ~= ""
        if not taken then
            for _, puppet in pairs(Avatar.puppets) do
                local p = puppet.player
                for _, pose in ipairs({ SMOKE_BREAK, LOUNGE_POSE }) do
                    local at = placeOf(index, pose)
                    if p and (p.x - at.x) ^ 2 + (p.y - at.y) ^ 2 < 40 * 40 then taken = true end
                end
            end
        end
        if not taken then
            local d = (l.X - st.x) ^ 2 + (l.Y - st.y) ^ 2
            if not nearD or d < nearD then near, nearD = index, d end
            if at then
                local off = math.abs(((math.deg(math.atan(st.y - l.Y, st.x - l.X)) - at + 180) % 360) - 180)
                local score = off + math.sqrt(d) / 40
                if off < 25 and (not seenScore or score < seenScore) then seen, seenScore = index, score end
            end
        end
    end
    return seen or near
end
Poker.freeSeat = freeSeat

-- Where the player is held to sit in an armchair in a pose: the pose sets the figure
-- behind (and beside) that place, onto the seat.
placeOf = function(index, pose)
    local st = SEATS[index]
    local e = Avatar.EMOTES[pose] or {}
    local t = tune.pose[pose] or { fwd = 0, right = 0, up = 0 }
    -- towards the table, and to the sitter's right
    local fx, fy, rx, ry = -st.ux, -st.uy, -st.vx, -st.vy
    local fwd, right = t.fwd + (e.back or 0), t.right - (e.side or 0)
    return { x = st.x + fx * fwd + rx * right, y = st.y + fy * fwd + ry * right, yaw = st.yaw, up = t.up or 0 }
end

-- The two views of a seated player, as at the card table: the wheel turned towards the
-- player moves the view out behind the armchair, turned away it moves in to the seat.
local viewChoice = nil

local function setView(behind)
    if not Poker.seated or not seat or not scr or seat.behind == behind then return false end
    local player = World.player()
    if not player or seat.owner ~= player:GetAddress() then return false end
    seat.behind, seat.z = behind, FLOOR + (behind and tune.sit or tune.eye)
    Avatar.noEmoteView = not behind       -- (from behind, the own figure is held in its pose: coop/third.lua)
    viewChoice = behind
    scr.keepView = behind
    Avatar.sendZ = FLOOR + tune.sit + seat.place.up - seat.z
    Third.force = behind and viewShape(seat.pose) or nil
    pcall(function() player:K2_SetActorLocation({ X = seat.place.x, Y = seat.place.y, Z = seat.z }, false, {}, true) end)
    return true
end
Poker.setView = setView

if LoopInGameThreadWithDelay then
    local UP, DOWN = nil, nil
    LoopInGameThreadWithDelay(1, function()
        if not live() then return true end
        if not Poker.seated or not seat then return false end
        pcall(function()
            local pc = World.player():GetController()
            UP = UP or { KeyName = FName("MouseScrollUp") }
            DOWN = DOWN or { KeyName = FName("MouseScrollDown") }
            if pc:WasInputKeyJustPressed(UP) == true then
                setView(false)
            elseif pc:WasInputKeyJustPressed(DOWN) == true then
                setView(true)
            end
        end)
        return false
    end)
end

function Poker.enter()
    if Poker.seated then return true end
    local player = World.player()
    if not player or not active() then return false end
    ensureSet()
    if not set or Poker.closed() then
        Hud.toast("La Ballena is not playing tonight", 3)
        return false
    end
    if Poker.refuses() then
        ballenaSays("No more cards tonight.", 4)
        return false
    end
    local index = freeSeat()
    if not index then
        Hud.toast("Every armchair at the table is taken", 3)
        return false
    end
    local behind = viewChoice
    if behind == nil then behind = Core.config.CardRoomBehindView ~= false end
    local pose = SEATS[index].pose or Poker.pose or (math.random(2) == 1 and SMOKE_BREAK or LOUNGE_POSE)
    seat = { index = index, pose = pose, place = placeOf(index, pose), owner = player:GetAddress(), behind = behind,
        z = FLOOR + (behind and tune.sit or tune.eye) }
    pcall(function() seat.hud = player.HUD.Visibility end)
    scr = Screen.open()
    if not scr then
        Hud.toast("The poker table could not be shown", 3)
        seat = nil
        return false
    end
    scr.keepView = behind
    Casino.standUp(player)
    pcall(function()
        Casino.ghost(player, true)
        player.CharacterMovement:SetMovementMode(5, 0)       -- flying: nothing pulls the seated player down
        player.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 }
        player:K2_SetActorLocation({ X = seat.place.x, Y = seat.place.y, Z = seat.z }, false, {}, true)
        player:GetController():SetControlRotation({ Pitch = tune.pitch, Yaw = seat.place.yaw, Roll = 0 })
    end)
    pcall(function() player.HUD:SetVisibility(1) end)
    Avatar.noEmoteView, Avatar.sendZ = not behind, FLOOR + tune.sit + seat.place.up - seat.z
    -- (the figure sits where the armchair is and faces the table, wherever the player stood
    -- and looked before, and whatever they look at from the seat)
    Avatar.seatedAt = { x = seat.place.x, y = seat.place.y, yaw = seat.place.yaw }
    Third.force = behind and viewShape(seat.pose) or nil
    pcall(Avatar.setEmote, seat.pose)
    Poker.seated = true
    my = { state = "buyin", stack = 0 }
    raising, mine, wager, slider = false, nil, nil, nil
    scr.onClose = function() if Poker.seated then Poker.leave() end end
    shown = {}
    pcall(drawTable)
    render()
    return true
end

function Poker.leave()
    if not Poker.seated then return end
    Poker.seated = false
    -- the chips: the table says what we take along (a hand in play is given up). We are
    -- no player of the table from here on: what it tells next is not about our chips.
    local was = my.state
    my.state = nil
    if was == "in" or was == "asked" then
        if was == "asked" and not authority() then
            -- (the seat was asked for and not yet given: taken or refused, the money returns)
            my.due = { at = os.clock(), amount = my.asked or 0, asked = true }
        else
            my.due = { at = os.clock(), amount = my.stack }
        end
        toHost({ a = "leave" })
    end
    my.asked, my.added = nil, nil
    raising, timer, slider, wager = false, nil, nil, nil
    local s = scr
    scr, shown = nil, {}
    if s then
        s.onClose = nil
        pcall(s.close)
    end
    local player = World.player()
    if player and seat and seat.owner == player:GetAddress() then
        local stand = SEATS[seat.index].stand
        pcall(function()
            player:K2_SetActorLocation({ X = stand.x, Y = stand.y, Z = FLOOR + 100 }, false, {}, true)
            Casino.ghost(player, false)
            player.CharacterMovement:SetMovementMode(3, 0)
            player:GetController():ResetIgnoreLookInput()
            player:GetController():SetControlRotation({ Pitch = -8, Yaw = math.deg(math.atan(CY - stand.y, CX - stand.x)), Roll = 0 })
        end)
        pcall(function() player.HUD:SetVisibility(seat.hud or 4) end)
    end
    Avatar.noEmoteView, Avatar.sendZ, Avatar.seatedAt = nil, nil, nil
    Third.force = nil
    pcall(Avatar.setEmote, 0)
    seat = nil
    pcall(drawTable)
end

-- The table has not said yet what we take along: asked again every few seconds. A table
-- that never answers pays what we knew we had.
Core.every(1, function()
    if not live() or not my.due then return end
    local due = my.due
    local waited = os.clock() - due.at
    if waited > 20 then
        my.due = nil
        local extra = Casino.pay(due.amount)
        if due.amount > 0 then Hud.toast(string.format("You take $%d from the table", due.amount), 4) end
        if extra ~= "" then Hud.toast(extra, 6) end
    elseif waited > (due.asks or 1) * 4 and not authority() and World.active then
        due.asks = (due.asks or 1) + 1
        toHost({ a = "leave" })
    end
end)

-- The seated player stays put and looks at the table. Holding the left mouse button lets
-- them look around; letting go turns the view back.
local LMB = nil
local looking = false

local function turn(from, to, k)
    return from + (((to - from + 180) % 360) - 180) * k
end

local function forget()
    Poker.seated, scr, seat, shown, timer, slider = false, nil, nil, {}, nil, nil
    my = { state = nil, stack = 0 }
    Avatar.noEmoteView, Avatar.sendZ, Avatar.seatedAt = nil, nil, nil
    Third.force = nil
end

Core.onTick(function()
    if not live() or not Poker.seated then return end
    local player = World.player()
    if not player or not seat or seat.owner ~= player:GetAddress() then
        forget()
        return
    end
    pcall(function()
        local place = seat.place
        player:K2_SetActorLocation({ X = place.x, Y = place.y, Z = seat.z }, false, {}, true)
        local pc = player:GetController()
        LMB = LMB or { KeyName = FName("LeftMouseButton") }
        local held = false
        pcall(function() held = pc:IsInputKeyDown(LMB) == true end)
        if held and slider and raising then
            -- (the button is down on the slider: that is a bet being set, not a look around)
            local onIt = false
            pcall(function() onIt = slider.edit:IsHovered() == true end)
            pcall(function() if slider.widget then onIt = onIt or slider.widget:HasMouseCapture() == true or slider.widget:IsHovered() == true end end)
            if onIt then held = false end
        end
        if held ~= looking then
            looking = held
            pc:SetIgnoreLookInput(not held)
        end
        if not held then
            local r = pc:GetControlRotation()
            local pitch = r.Pitch > 180 and r.Pitch - 360 or r.Pitch
            pc:SetControlRotation({ Pitch = turn(pitch, tune.pitch, 0.25), Yaw = turn(r.Yaw, place.yaw, 0.25), Roll = 0 })
        end
    end)
end)

-- The sit-down key: at La Ballena's table it is poker, anywhere else in the club whatever
-- answered the key before (the slot machines, the card table).
local UNDER = rawget(_G, "DDSMP_POKER_UNDER") or Look.takeover
_G.DDSMP_POKER_UNDER = UNDER
Poker.takeover = {
    isOpen = function() return (live() and Poker.seated) or UNDER.isOpen() end,
    near = function() return (live() and not UNDER.isOpen() and nearTable()) or UNDER.near() end,
    prompt = function()
        if live() and nearTable() then return key("WardrobeKey"), "Play poker with La Ballena" end
        return UNDER.prompt()
    end,
    toggle = function()
        if live() and Poker.seated then
            Poker.leave()
        elseif live() and not UNDER.isOpen() and nearTable() then
            Poker.enter()
        else
            UNDER.toggle()
        end
    end,
    move = function() end,
    choose = function() end,
}
Look.takeover = Poker.takeover

---------------------------------------------------------------- keeping it all in order

Core.every(1, function()
    if not live() then return end
    if seat and not World.active then
        local player = World.player()
        if not player or player:GetAddress() ~= seat.owner then
            -- (single player: the world went without a word; its things went with it)
            local s = scr
            forget()
            if s then
                s.onClose = nil
                pcall(s.close)
            end
            for k in pairs(laid) do laid[k] = nil end
        end
    end
    local player = World.player()
    if not player or not active() then return end
    ensureSet()
    if not set then return end
    local l = player:K2_GetActorLocation()
    if math.abs(l.X - CX) < 2500 and math.abs(l.Y - CY) < 2500 and l.Z < 420 then
        pcall(putAway)
        pcall(drawTable)        -- (turned-over cards face whoever walks round the table)
    end
    -- the club stays shut for the night, whatever the game's own clock says about its door
    if Poker.closed() and Casino.nearClub() then
        local inside = false
        pcall(function() inside = Casino.insideClub(player) end)
        if not closedSeen or inside then
            closedSeen = true
            pcall(throwOut)
        end
        pcall(function()
            local manager = Core.find("ballenaClubManager_C")
            if manager and manager.SM_Door_2_L.RelativeRotation.Yaw ~= 0 then manager:closeClub() end
        end)
    end
    -- the cash shown follows what is in the pockets
    if Poker.seated and scr and scr.open and my.state == "buyin" then
        local money = Casino.cash()
        if money ~= my.cashShown then
            my.cashShown = money
            pcall(render)
        end
    end
end)

World.listen("start", function(role)
    if not live() or role == "host" then return end        -- (the host's table goes on as it is)
    tbl, ctl, view, mine, closedSeen, refusedSeen = nil, {}, nil, nil, false, false
end)

World.listen("stop", function(role)
    if not live() then return end
    if Poker.seated then
        if role == "guest" then
            -- the table is in a game we have left: it keeps our chips for when we are back
            my.state = nil
        end
        pcall(Poker.leave)
    end
    if my.due and role == "guest" then
        -- (we had got up and the table had not answered yet)
        local due = my.due
        my.due = nil
        if due.amount > 0 and not World.gone then pcall(Casino.pay, due.amount) end
    end
    if role ~= "host" then tbl, ctl = nil, {} end
    for id in pairs(owed) do owed[id] = nil end
    view, mine, closedSeen, refusedSeen = nil, nil, false, false
    for k in pairs(laid) do clearLaid(k) end
end)

-- A save loaded from inside the game: the level stays, so the table's things are taken
-- away (and laid again for the new player).
World.listen("loading", function()
    local player = World.player()
    if not live() then return end
    if Poker.seated then pcall(Poker.leave) end
    tbl, ctl, view, mine, closedSeen, refusedSeen = nil, {}, nil, nil, false, false
    if set and player and set.owner == player:GetAddress() then clearSet() end
end)

-- For reloading the module while developing.
function Poker.shutdown()
    if Poker.seated then pcall(Poker.leave) end
    clearSet()
    if Look.takeover == Poker.takeover then Look.takeover = UNDER end
    Casino.closed = nil
end

Poker.SEATS, Poker.TABLE = SEATS, { x = CX, y = CY, top = TOP }
Poker.nearTable, Poker.throwOut, Poker.meetingToCome = nearTable, throwOut, meetingToCome
return Poker
