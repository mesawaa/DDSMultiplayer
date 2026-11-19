-- Olivia's: the barbershop, in the low building south of the first hideout (West Oldtown),
-- the one with "olivia is a ..." written on its north wall. The game has the room: a door
-- it keeps locked (it can be picked), boxes, a shelf and a rack where it puts water bottles
-- and spray cans. All of that stays. Every game adds its own copy of the shop while a
-- player is near: a stool, a dresser against the brick wall with a mirror above it, two
-- posters, a few bottles, jars and rags on the dresser and the shelves, one light, and Olivia.
-- Inside, the brick cannot be tagged (see the panels below); outside it can, as before. Talking to her uses the game's own dialogue screen
-- (as at Marco's, coop/clerk.lua) and leads to the hair screen (coop/look.lua): the only
-- place where hair and beard are changed. Nothing of it is saved; the door is unlocked in
-- every game.
--
-- The room inside (measured with lines of sight from its middle): x -3272..-2818 between
-- the west wall and the brick block, y -2851..-1944, the floor's top at z 129, the ceiling
-- at 431. North of the brick block (y above -2200) the room goes on east to x -2710. The
-- door is in the west wall at y -2515.

local Core = require("core")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Repl = require("coop.repl")
local Hud = require("coop.hud")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_BARBER_GEN") or 0) + 1
_G.DDSMP_BARBER_GEN = GEN
local function live() return rawget(_G, "DDSMP_BARBER_GEN") == GEN end

local Barber = { NAME = "Olivia", STORE = "Olivia's Barbershop", ID = "barber", TITLE = "OLIVIA'S" }

local ROOM = { x0 = -3272, x1 = -2818, y0 = -2851, y1 = -1944 }
local FLOOR = 129
local CEILING = 431
local STAND = FLOOR + 88          -- where a figure standing on the floor has its centre
local DOOR = { x = -3280, y = -2515 }
local BRICK = ROOM.x1             -- the brick wall's face
local STATION = -2560             -- the middle of the mirror, along the brick wall (between the two piles of boxes)

-- Olivia beside the stool, facing the door.
local SPOT = { x = BRICK - 118, y = STATION + 85, z = STAND, yaw = 180 }
-- While the hair screen is open the player stands at VIEWPOINT and looks at a figure like
-- them at FITTING, in the corner north of the brick block, the plain wall behind it. Nearer
-- than in the clothes shops and through a long lens: the face fills the picture.
local FITTING = { x = -2772, y = -2072, z = STAND }
local VIEWPOINT = { x = FITTING.x - 215, y = FITTING.y }
local REACH = 230
local BUILD_RANGE = 3500

-- (the long-sleeved sweater, and over it the apron of the outfit with the skirt, which she
-- had first: under that one's rolled sleeves the forearms came through at the elbows)
local OLIVIA = { body = "SK_fe_casual_02_a#MI_fe_casual_01_dark", head = "SK_fe_head_02_b", hair = "Hats_Hair/SK_fe_hair_03#MI_fe_hair_04", arms = true,
    over = "SK_fe_clerk_01!apron" }

-- The only things added to the room (it stays the shabby store room it is): a stool for
-- the customer, a dresser in front of it against the brick wall, a mirror above the dresser.
local MESH = {
    mirror = "/Game/ModularBarInterior/Meshes/BarProps/Restroom/SM_Mirror.SM_Mirror",
    dresser = "/Game/StaticMeshes/Furniture/SM_Classic_Commode_2.SM_Classic_Commode_2",
    stool = "/Game/AssetPacks/ModernKitchen/StaticMeshes/CounterStool.CounterStool",
    -- posters the furniture seller of sector C has (80 wide, 112 high, flat, their picture to -X)
    -- (the user's choice: the waterfall and "with a friend" beside the mirror, left to right
    -- as seen from the room; none on the other walls)
    waterfall = "/Game/StaticMeshes/Posters/decoPosterMesh_Poster03.decoPosterMesh_Poster03",
    friend = "/Game/StaticMeshes/Posters/decoPosterMesh_Poster01.decoPosterMesh_Poster01",
    -- supplies: the psychedelics lab's brown bottle, lidded jar, beaker and two flasks, a
    -- white plastic bottle, the game's fluid bottle, two rags
    bottle = "/Game/AbandonedLaboratory/Meshes/SM_Flask_04_SM_Flask_04_LOD0.SM_Flask_04_SM_Flask_04_LOD0",
    jar = "/Game/AbandonedLaboratory/Meshes/SM_Flask_03_SM_Flask_03_LOD0.SM_Flask_03_SM_Flask_03_LOD0",
    beaker = "/Game/AbandonedLaboratory/Meshes/SM_Flask_02_SM_Flask_02_LOD0.SM_Flask_02_SM_Flask_02_LOD0",
    flask = "/Game/AbandonedLaboratory/Meshes/SM_Flask_SM_Flask_LOD0.SM_Flask_SM_Flask_LOD0",
    roundFlask = "/Game/AbandonedLaboratory/Meshes/SM_Flask_01_SM_Flask_01_LOD0.SM_Flask_01_SM_Flask_01_LOD0",
    white = "/Game/RubbleDebrisTrash/Models/SM_BottleD.SM_BottleD",
    fluid = "/Game/Interactive/Additives/FluidBottle.FluidBottle",
    rag = "/Game/RubbleDebrisTrash/Models/SM_Cloth_02.SM_Cloth_02",
    greyRag = "/Game/RubbleDebrisTrash/Models/SM_Cloth_03.SM_Cloth_03",
    cube = "/Engine/BasicShapes/Cube.Cube",
}
-- The brick wall north of the mirror is free from the mirror's edge to the block's corner
-- (its north face is at y -2160): two posters side by side in the middle of that, their
-- lower edges level with the mirror's. Each hangs a little crooked.
local BLOCK_NORTH = -2160            -- the brick block's north face
local CORNER_EAST = -2710            -- the wall east of the corner north of the block
local MIRROR_EDGE, CORNER = STATION + 67.5, BLOCK_NORTH
local PAIR = (MIRROR_EDGE + CORNER) / 2
local POSTER_Z = FLOOR + 152 - 35.5 + 56
-- mesh, where its pivot goes, yaw, scale. The dresser (the game's low chest of drawers, its
-- drawers to +Y) is 170 wide, 44 deep, 86 high (pivot: bottom middle); the mirror 270 x 142 at full size, its back on the wall (pivot: middle);
-- the stool's pivot is 80 above its feet.
Barber.PROPS = {
    { m = "dresser", x = BRICK - 23, y = STATION, z = FLOOR, yaw = 90 },
    { m = "mirror", x = BRICK - 1, y = STATION, z = FLOOR + 152, yaw = 0, s = { X = 1, Y = 0.5, Z = 0.5 } },
    -- (turned a little, as somebody left it)
    { m = "stool", x = BRICK - 112, y = STATION, z = FLOOR + 80, yaw = 22 },
    { m = "waterfall", x = BRICK - 1.5, y = PAIR - 47.5, z = POSTER_Z, yaw = 0, roll = -1.5, collide = false },
    { m = "friend", x = BRICK - 1.5, y = PAIR + 47.5, z = POSTER_Z, yaw = 0, roll = 2, collide = false },
}
-- Supplies, each standing on what it is put on (heights above the floor, measured): the
-- dresser's top 85.5; the racks' boards 80.5 and 115.5 (their middle at y -1962; the lowest
-- board is left to the game, which puts bottles and cans there); the south shelf's upper
-- board 198 (its lower one is the game's too). On the dresser they stand along the back at
-- both ends, the middle in front of the mirror free but for a rag.
local DRESSER_TOP, BACK = FLOOR + 85.5, BRICK - 12
local RACK_Y, SHELF_Y = -1962, -2831
for _, it in ipairs({
    { m = "bottle", x = BACK, y = STATION - 72, z = DRESSER_TOP },
    { m = "jar", x = BACK, y = STATION - 55, z = DRESSER_TOP },
    -- (no glass here: the lab's glassware does not draw properly in front of the brick)
    { m = "rag", x = BRICK - 25, y = STATION + 12, z = DRESSER_TOP, yaw = 90 },
    { m = "fluid", x = BACK, y = STATION + 50, z = DRESSER_TOP, yaw = 15 },
    { m = "white", x = BACK, y = STATION + 66, z = DRESSER_TOP },
    -- the racks on the north wall: a few things on the upper boards
    { m = "white", x = -3232, y = RACK_Y, z = FLOOR + 80.5 },
    { m = "jar", x = -3210, y = RACK_Y - 3, z = FLOOR + 80.5 },
    { m = "beaker", x = -3088, y = RACK_Y, z = FLOOR + 115.5 },
    { m = "greyRag", x = -3058, y = RACK_Y, z = FLOOR + 115.5, yaw = 30 },
    { m = "bottle", x = -2942, y = RACK_Y - 2, z = FLOOR + 80.5 },
    { m = "fluid", x = -2922, y = RACK_Y, z = FLOOR + 80.5, yaw = -20 },
    -- the shelf on the south wall: two flasks on its upper board
    { m = "roundFlask", x = -3206, y = SHELF_Y, z = FLOOR + 198 },
    { m = "flask", x = -3184, y = SHELF_Y + 2, z = FLOOR + 198 },
}) do
    it.collide = false
    Barber.PROPS[#Barber.PROPS + 1] = it
end
-- The game lets a player tag brick (its view line hits "outer wall" there): inside, that is
-- the brick block's west face (the mirror's wall) and its north face. An invisible panel
-- stands just in front of each: the view line stops at it and no tag is offered. The panels
-- stop only lines of sight (players walk as before); the building's outside is as it was.
local SKIN = 2
Barber.PROPS[#Barber.PROPS + 1] = { m = "cube", x = BRICK - SKIN, y = (ROOM.y0 + BLOCK_NORTH) / 2, z = (FLOOR + CEILING) / 2,
    s = { X = SKIN / 100, Y = (BLOCK_NORTH - ROOM.y0) / 100, Z = (CEILING - FLOOR) / 100 }, hidden = true, sightOnly = true }
Barber.PROPS[#Barber.PROPS + 1] = { m = "cube", x = (BRICK + CORNER_EAST) / 2, y = BLOCK_NORTH + SKIN, z = (FLOOR + CEILING) / 2,
    s = { X = (CORNER_EAST - BRICK) / 100, Y = SKIN / 100, Z = (CEILING - FLOOR) / 100 }, hidden = true, sightOnly = true }
Barber.LIGHTS = {
    -- one bare light over the chair
    { x = BRICK - 150, y = STATION + 30, z = FLOOR + 195, i = 2400, r = 560 },
}

Barber.MESH = MESH
Barber.SPOT, Barber.VIEWPOINT, Barber.FITTING, Barber.REACH, Barber.ROOM = SPOT, VIEWPOINT, FITTING, REACH, ROOM
Barber.FLOOR = FLOOR
-- (coop/look.lua: what of the figure the picture is about: this far above its middle, at
-- this height of the picture)
Barber.FOCUS = { up = 70, at = 0.5 }
-- (and the field of view while the hair screen is open: a close-up of the face)
Barber.FOV = 50

local built = nil        -- { owner, fig, props, dialogue, todo }
local talking = 0
local hidden = false
local door = nil         -- { actor, owner }
local marker = nil

local function clear()
    local b = built
    built = nil
    if not b or World.gone then return end
    pcall(Avatar.destroyStandIn, b.fig)
    for _, a in ipairs(b.props or {}) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
    pcall(function() if valid(b.dialogue) then b.dialogue:K2_DestroyActor() end end)
end

-- The dialogue: the furniture shopkeeper's own lines with other words (see coop/clerk.lua).
local function dialogueText()
    local template = nil
    for _, d in ipairs(Core.actors("/Game/Interactive/dialogueInstance.dialogueInstance_C") or {}) do
        if not template and Core.alive(d) then
            local v = Repl.export(d, { "dialogueLines" }).dialogueLines
            if type(v) == "string" and v:find('"Show me your products"', 1, true) and v:find('"How can I help you?"', 1, true) then template = v end
        end
    end
    if not template then return nil end
    local function swap(text, old, new)
        local out, from = {}, 1
        while true do
            local a, b = text:find(old, from, true)
            if not a then break end
            out[#out + 1] = text:sub(from, a - 1) .. new
            from = b + 1
        end
        out[#out + 1] = text:sub(from)
        return table.concat(out)
    end
    local t = swap(template, '"How can I help you?"', '"Never mind the wall outside. What are we doing today?"')
    local a, b = t:find('ResponseText_2_3DC4585B4FB4F1C79DACFAA7F3A5BBD7="Show me your products"', 1, true)
    if not a then return nil end
    local close = t:find(")", b, true)
    local answer = t:sub(a, close)
    local changed = answer
    changed = changed:gsub('"Show me your products"', '"I want a new look"', 1)
    changed = changed:gsub("(ExitsDialogue_8_%x+=)%a+", "%1True", 1)
    changed = changed:gsub("(EntersSale_10_%x+=)%a+", "%1False", 1)
    changed = changed:gsub('(questEventName_14_%x+=)"[^"]*"', '%1"DialogueLoaded"', 1)
    changed = changed:gsub("(LocalFunction_19_%x+=)%a+", "%1True", 1)
    t = t:sub(1, a - 1) .. changed .. t:sub(close + 1)
    return swap(t, '"Just passing, sorry"', '"Just looking, thanks"')
end

local function asset(path) return Avatar.asset(path) end

local function build(player)
    clear()
    local world = player:GetWorld()
    local b = { owner = player:GetAddress(), props = {}, todo = {} }
    built = b
    hidden = false
    local function later(fn) b.todo[#b.todo + 1] = fn end
    local function spawn(class, x, y, z, yaw, roll)
        local a = world:SpawnActor(StaticFindObject(class), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw or 0, Roll = roll or 0 })
        if valid(a) then b.props[#b.props + 1] = a end
        return a
    end
    for _, it in ipairs(Barber.PROPS) do
        later(function()
            local m = asset(MESH[it.m])
            if not m then
                log("Barber: mesh %s is not available", it.m)
                return
            end
            local a = spawn("/Script/Engine.StaticMeshActor", it.x, it.y, it.z, it.yaw, it.roll)
            if not valid(a) then return end
            a:SetMobility(2)
            a.StaticMeshComponent:SetStaticMesh(m)
            if it.s then a:SetActorScale3D(it.s) end
            if it.collide == false then a:SetActorEnableCollision(false) end
            if it.hidden then a:SetActorHiddenInGame(true) end
            if it.sightOnly then
                local c = a.StaticMeshComponent
                c:SetCollisionEnabled(1)                    -- queries only
                c:SetCollisionResponseToAllChannels(0)      -- ignore everything...
                c:SetCollisionResponseToChannel(3, 2)       -- ...but lines of sight (visibility)
                c:SetCollisionResponseToChannel(4, 2)       -- (and camera)
            end
        end)
    end
    for _, it in ipairs(Barber.LIGHTS) do
        later(function()
            local l = spawn("/Script/Engine.PointLight", it.x, it.y, it.z)
            if not valid(l) then return end
            local c = l.LightComponent
            c:SetMobility(2)
            -- no highlights: the bulb's reflection in the mirror was a glaring spot, and the
            -- game's lens flare drew ghosts of it over the wall and the dresser (set before
            -- the rest, which puts the light up anew with it)
            pcall(function() c.SpecularScale = 0 end)
            c:SetIntensity(it.i)
            c:SetAttenuationRadius(it.r)
            c:SetLightColor({ R = 1, G = 0.9, B = 0.78, A = 1 }, true)
            c:SetCastShadows(false)
        end)
    end
    later(function() b.fig = Avatar.buildStandIn(OLIVIA, SPOT.x, SPOT.y, SPOT.z, SPOT.yaw, nil, "idle") end)
    later(function()
        local text = dialogueText()
        local class = StaticFindObject("/Game/Interactive/dialogueInstance.dialogueInstance_C")
        if not text or not valid(class) then
            log("Barber: no dialogue (template %s)", tostring(text ~= nil))
            return
        end
        local d = world:SpawnActor(class, { X = SPOT.x, Y = SPOT.y, Z = SPOT.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(d) then return end
        -- this copy is ours alone: it must not be written into anybody's save
        pcall(function() if valid(d.RamaSave) then d.RamaSave:K2_DestroyComponent(d) end end)
        if Repl.importRaw(d, "dialogueLines", text) then b.dialogue, b.lines = d, text end
        log("Barber: built (%d pieces, Olivia %s, dialogue %s)", #b.props, tostring(b.fig ~= nil), tostring(b.dialogue ~= nil))
    end)
end
Barber.build = build

Core.onTick(function()
    local b = built
    if not live() or not b or not b.todo or #b.todo == 0 then return end
    local player = World.player()
    if not player or player:GetAddress() ~= b.owner then
        b.todo = nil
        return
    end
    for _ = 1, 2 do
        local fn = table.remove(b.todo, 1)
        if not fn then break end
        local ok, e = pcall(fn)
        if not ok then log("Barber: %s", tostring(e)) end
    end
end)

function Barber.distance()
    local player = World.player()
    if not player then return math.huge end
    local l = player:K2_GetActorLocation()
    return math.sqrt((l.X - SPOT.x) ^ 2 + (l.Y - SPOT.y) ^ 2 + ((l.Z - SPOT.z) * 2) ^ 2)
end

-- Talking distance.
function Barber.near() return built ~= nil and built.fig ~= nil and Barber.distance() <= REACH end

-- True while the player is in the shop's room.
function Barber.inside()
    local player = World.player()
    if not player then return false end
    local l = player:K2_GetActorLocation()
    return l.X > ROOM.x0 and l.X < ROOM.x1 + 108 and l.Y > ROOM.y0 and l.Y < ROOM.y1 and l.Z < CEILING
end

function Barber.hide(on)
    on = on == true
    if not built or not built.fig or hidden == on then return end
    hidden = on
    for _, a in ipairs(built.fig.actors or {}) do
        pcall(function() if valid(a) then a:SetActorHiddenInGame(on) end end)
    end
end

function Barber.talk()
    local player = World.player()
    if not player or not built or not valid(built.dialogue) then return false end
    local ok, e = pcall(function()
        talking = os.clock()
        player:startDialogue(built.dialogue)
        player.focusCamera = false
        player.dialogueWidget.txtTalkerName:SetText(FText(Barber.NAME))
    end)
    if not ok then log("Barber: dialogue failed: %s", tostring(e)) end
    return ok
end

-- Olivia's dialogue actor and the lines it was made with (coop/wallquest.lua adds to them:
-- always to these, never to what the actor holds at the moment).
function Barber.dialogue()
    if built and built.lines and Core.alive(built.dialogue) then return built.dialogue, built.lines end
    return nil
end

Barber.onShow = nil    -- set by coop/look.lua: called when the player asks for a new look

Core.Hooks.add("/Game/Interactive/dialogueInstance.dialogueInstance_C:DialogueLoaded", function(ctx)
    if not live() or not built or os.clock() - talking > 600 then return end
    local ok, mine = pcall(function() return ctx:get():GetAddress() == built.dialogue:GetAddress() end)
    if not ok or not mine then return end
    talking = 0
    Core.after(0.25, function()
        if Barber.onShow then pcall(Barber.onShow) end
    end)
end)

Barber.wanted = function() return World.extras() end

-- The street door: the game keeps it locked until somebody picks it; here it is open to
-- everybody.
local function tendDoor(player)
    local owner = player:GetAddress()
    if not door or door.owner ~= owner or not Core.alive(door.actor) then
        door = nil
        for _, d in ipairs(Core.actors("/Game/Interactive/doorBase.doorBase_C") or {}) do
            local ok, l = pcall(function() return d:K2_GetActorLocation() end)
            if ok and l and math.abs(l.X - DOOR.x) < 25 and math.abs(l.Y - DOOR.y) < 25 and l.Z < 300 then
                door = { actor = d, owner = owner }
                break
            end
        end
    end
    if door then
        pcall(function() if door.actor.doorLocked == true then door.actor.doorLocked = false end end)
    end
end
function Barber.door() return door and door.actor end      -- (for test scripts)

Core.every(1, function()
    if not live() then return end
    local player = World.player()
    if not player or not Barber.wanted() then
        if built then clear() end
        return
    end
    if built and built.owner ~= player:GetAddress() then built = nil end      -- another world: its actors are gone
    local l = player:K2_GetActorLocation()
    local far = (l.X - SPOT.x) ^ 2 + (l.Y - SPOT.y) ^ 2 > BUILD_RANGE * BUILD_RANGE
    local done = built and (built.todo == nil or #built.todo == 0)
    if built and (far or (done and not valid(built.fig and built.fig.body))) then
        clear()
    elseif not built and not far and os.clock() - (Barber.builtAt or -100) > 10 then
        Barber.builtAt = os.clock()
        local ok, e = pcall(Avatar.batch, build, player)
        if not ok then log("Barber: %s", tostring(e)) end
    end
    if not far then pcall(tendDoor, player) end
    -- the shop on the map (once per world; the marker is never saved: coop/hud.lua)
    if Hud.ready() and (not marker or not Core.alive(marker)) then
        marker = Hud.mapMarker(Barber.STORE, "Haircuts, colour and beards", (ROOM.x0 + ROOM.x1) / 2, (ROOM.y0 + ROOM.y1) / 2, FLOOR, Hud.MARKER_SHOP)
    end
end)

function Barber.shutdown()
    clear()
    if marker then pcall(Hud.forgetMarker, marker) end
end
function Barber.rebuild()
    local player = World.player()
    if player then Avatar.batch(build, player) end
end

return Barber
