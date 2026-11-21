-- The dance floor in the night club's basement.
--
-- On the raised floor north of the card table: seven tiles across, six deep, from the
-- railing's corner back to the card table's end (the lounge's third pair of sofas and the
-- table between them stood there; the card room takes them away). The floor is a chess
-- board: black tiles and white ones. For a player who has switched DANCE FLOOR LIGHTS on
-- (MOD OPTIONS, EXPERIMENTAL) the white ones light up in colours that change in slow
-- patterns as soon as somebody stands on the floor, and go white again when the last one
-- has stepped off; a lamp above takes the colour of the moment. Every game builds its own
-- copy and runs its own patterns, nothing of it is saved. It follows the card room's
-- switches (`Casino`, `SoloExtras`).

local Core = require("core")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Casino = require("coop.casino")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_DANCE_GEN") or 0) + 1
_G.DDSMP_DANCE_GEN = GEN
local function live() return rawget(_G, "DDSMP_DANCE_GEN") == GEN end

local Dance = {}

-- The raised floor is at -185. A tile is 50 across with 2 between two; the first tile's
-- middle (by the railing's corner post), and how many there are.
local FLOOR = -185
local TILE, STEP = 50, 52
local X0, Y0 = 15184, -7862
local COLS, ROWS = 7, 6
-- The colours (the screens' kind of material: they show the same whatever the light).
local COLOURS = {
    { 0.62, 0.05, 0.32 }, { 0.04, 0.4, 0.58 }, { 0.62, 0.46, 0.05 },
    { 0.3, 0.09, 0.56 }, { 0.64, 0.24, 0.03 }, { 0.1, 0.5, 0.18 },
}
local BLACK, WHITE = { 0.012, 0.012, 0.014 }, { 0.5, 0.5, 0.47 }
local BEAT = 0.6                  -- seconds a picture of the floor stays
local PATTERN_BEATS = 24          -- beats before the next kind of pattern
Dance.tune = { beat = BEAT, lamp = 220, lampIdle = 60 }

local floor = nil        -- { actors, owner, tiles, mats, white, lamp, beat, at, picks, lit }

local function asset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if valid(o) then return o end
    return nil
end

local function clear()
    if not floor then return end
    for _, a in ipairs(floor.actors) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
    floor = nil
end

local function build()
    local player = World.player()
    local world = player:GetWorld()
    floor = { actors = {}, owner = player:GetAddress(), tiles = {}, mats = {}, beat = 0, at = 0, picks = {}, lit = false }
    local cube = asset("/Engine/BasicShapes/Cube.Cube")
    local base = asset("/Paper2D/OpaqueUnlitSpriteMaterial.OpaqueUnlitSpriteMaterial")
    if not cube or not base then error("the floor's shape or material is not available") end
    local KRL = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local KML = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    local class = StaticFindObject("/Script/Engine.StaticMeshActor")
    local function block(x, y, z, sx, sy, sz)
        local a = world:SpawnActor(class, { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        floor.actors[#floor.actors + 1] = a
        a:SetMobility(2)
        a.StaticMeshComponent:SetStaticMesh(cube)
        a:SetActorScale3D({ X = sx, Y = sy, Z = sz })
        a:SetActorEnableCollision(false)
        pcall(function() a.StaticMeshComponent:SetCastShadow(false) end)
        return a
    end
    -- A colour as a material. Each is worn by a small unseen block under the floor for as
    -- long as the floor is there: a colour no tile shows at the moment would otherwise be
    -- thrown away at the engine's next clean-up, and using it afterwards crashes the game.
    local function colour(c)
        local target = KRL:CreateRenderTarget2D(player, 4, 4, 2)
        KRL:ClearRenderTarget2D(player, target, { R = c[1], G = c[2], B = c[3], A = 1 })
        local m = KML:CreateDynamicMaterialInstance(player, base, FName("None"))
        m:SetTextureParameterValue(FName("SpriteTexture"), target)
        local keeper = block(X0, Y0, FLOOR - 300, 0.01, 0.01, 0.01)
        keeper:SetActorHiddenInGame(true)
        keeper.StaticMeshComponent:SetMaterial(0, m)
        return m
    end
    for i, c in ipairs(COLOURS) do floor.mats[i] = colour(c) end
    floor.white = colour(WHITE)
    local black = colour(BLACK)
    -- one black plate (the black tiles and the lines between all of them), and on it the
    -- tiles that can light up: every second one, like a chess board's white squares
    block(X0 + (COLS - 1) / 2 * STEP, Y0 - (ROWS - 1) / 2 * STEP, FLOOR + 0.4, (COLS * STEP + 2) / 100, (ROWS * STEP + 2) / 100, 0.008)
        .StaticMeshComponent:SetMaterial(0, black)
    for j = 1, ROWS do
        for i = 1, COLS do
            if (i + j) % 2 == 0 then
                local a = block(X0 + (i - 1) * STEP, Y0 - (j - 1) * STEP, FLOOR + 0.9, TILE / 100, TILE / 100, 0.008)
                a.StaticMeshComponent:SetMaterial(0, floor.white)
                floor.tiles[#floor.tiles + 1] = { actor = a, i = i, j = j }
            end
        end
    end
    -- the lamp over the middle
    pcall(function()
        local l = world:SpawnActor(StaticFindObject("/Script/Engine.PointLight"), { X = X0 + (COLS - 1) / 2 * STEP, Y = Y0 - (ROWS - 1) / 2 * STEP, Z = FLOOR + 215 }, { Pitch = 0, Yaw = 0, Roll = 0 })
        floor.actors[#floor.actors + 1] = l
        local c = l.LightComponent
        c:SetMobility(2)
        c:SetIntensity(Dance.tune.lampIdle)
        c:SetAttenuationRadius(480)
        c:SetCastShadows(false)
        floor.lamp = c
    end)
    log("Dance: the dance floor is set up (%d tiles that light up)", #floor.tiles)
end

-- Is somebody standing on the floor: our own player or one of the others?
local function onFloor(x, y, z)
    return x > X0 - STEP / 2 and x < X0 + (COLS - 0.5) * STEP and y < Y0 + STEP / 2 and y > Y0 - (ROWS - 0.5) * STEP
        and math.abs(z - (FLOOR + 90)) < 90
end

local function somebodyOn(player)
    local l = player:K2_GetActorLocation()
    if onFloor(l.X, l.Y, l.Z) then return true end
    for _, set in pairs(Avatar.puppets) do
        local p = set.player
        if p and p.x and onFloor(p.x, p.y, p.z or (FLOOR + 90)) then return true end
    end
    return false
end
Dance.somebodyOn = function() local p = World.player() return p ~= nil and somebodyOn(p) end

-- Everything white again.
local function rest()
    local f = floor
    f.lit, f.picks = false, {}
    for _, t in ipairs(f.tiles) do
        if valid(t.actor) then t.actor.StaticMeshComponent:SetMaterial(0, f.white) end
    end
    if f.lamp and valid(f.lamp) then
        f.lamp:SetIntensity(Dance.tune.lampIdle)
        f.lamp:SetLightColor({ R = 1, G = 0.96, B = 0.88, A = 1 }, true)
    end
end

-- The floor's next picture in colours.
local function beat()
    local f = floor
    if not f.lit then
        f.lit = true
        if f.lamp and valid(f.lamp) then f.lamp:SetIntensity(Dance.tune.lamp) end
    end
    f.beat = f.beat + 1
    local n = #f.mats
    local kind = math.floor(f.beat / PATTERN_BEATS) % 3
    local lead = (math.floor(f.beat / 4) % n) + 1
    for _, t in ipairs(f.tiles) do
        local pick
        if kind == 0 then
            pick = ((math.floor((t.i + t.j) / 2) + f.beat) % n) + 1                -- stripes that walk across
        elseif kind == 1 then
            pick = ((t.j + f.beat) % 2 == 0) and lead or ((lead + 2) % n) + 1      -- rows that swap
        else
            pick = f.picks[t]
            if not pick or math.random() < 0.35 then pick = math.random(1, n) end   -- some tiles change
        end
        if pick ~= f.picks[t] and valid(t.actor) then
            f.picks[t] = pick
            t.actor.StaticMeshComponent:SetMaterial(0, f.mats[pick])
        end
    end
    if f.lamp and valid(f.lamp) and f.beat % 4 == 0 then
        local c = COLOURS[lead]
        f.lamp:SetLightColor({ R = math.min(1, c[1] + 0.35), G = math.min(1, c[2] + 0.35), B = math.min(1, c[3] + 0.35), A = 1 }, true)
    end
end

Core.onTick(function()
    if not live() or not floor then return end
    local now = os.clock()
    if now < floor.at then return end
    floor.at = now + (Dance.tune.beat or BEAT)
    local player = World.player()
    if not player or player:GetAddress() ~= floor.owner then return end
    local ok, e = pcall(function()
        if Core.experimental("DanceFloor") and somebodyOn(player) then
            beat()
        elseif floor.lit then
            rest()
        end
    end)
    if not ok and not floor.failed then
        floor.failed = true
        log("Dance: %s", tostring(e))
    end
end)

Core.every(1, function()
    if not live() then return end
    local player = World.player()
    if not player then return end
    if floor and (floor.owner ~= player:GetAddress() or not valid(floor.actors[1])) then
        floor = nil      -- another world: its actors went with it
    end
    if not floor and Casino.active() and Casino.nearClub() then
        local ok, e = xpcall(build, debug.traceback)
        if not ok then
            log("Dance: could not set up the dance floor: %s", tostring(e))
            clear()
        end
    end
end)

-- A save loaded from inside the game: the level stays, so the floor is taken away (and
-- built again for the new player).
World.listen("loading", function()
    local player = World.player()
    if live() and floor and player and floor.owner == player:GetAddress() then clear() end
end)

-- For reloading the module while developing.
function Dance.shutdown() clear() end
Dance.state = function() return floor end
return Dance
