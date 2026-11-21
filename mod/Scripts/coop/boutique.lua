-- Vera's Tailoring: the formal clothes shop in the empty south half of the building next to
-- Exclusive furniture (sector B). The game has the room (brick walls, concrete floor, a
-- street door it keeps locked, double height to the roof) but nothing in it. Every game
-- builds its own copy of the shop while a player is near: a wooden floor and a ceiling
-- copied from the office next door (the same modular pieces), lamps, a counter, plants, a
-- picture, suits on display, and Vera behind the counter. Talking to her uses the game's own
-- dialogue screen, like Marco's corner (coop/clerk.lua). Nothing of it is saved; the street
-- door is unlocked in every game.
--
-- The room inside: x 9440..9997, y -3477..-2823 (measured by walking into its walls), the
-- concrete floor's top at z 204; the door is in the west wall at y -3145.

local Core = require("core")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Repl = require("coop.repl")
local Hud = require("coop.hud")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_BOUTIQUE_GEN") or 0) + 1
_G.DDSMP_BOUTIQUE_GEN = GEN
local function live() return rawget(_G, "DDSMP_BOUTIQUE_GEN") == GEN end

local Boutique = { NAME = "Vera", STORE = "Vera's Tailoring", ID = "formal", TITLE = "VERA'S" }

local ROOM = { x0 = 9440, x1 = 9997, y0 = -3477, y1 = -2823 }
local MID = { x = (ROOM.x0 + ROOM.x1) / 2, y = (ROOM.y0 + ROOM.y1) / 2 }
local FLOOR = 205                 -- the top of our wooden floor (the concrete is at 204)
local CEILING = 530               -- the underside of our ceiling: where the brick ends
local STAND = FLOOR + 88          -- where a figure standing on the floor has its centre
local DOOR = { x = 9430, y = -3145 }

-- Vera behind the counter at the east wall, facing the door.
local SPOT = { x = 9958, y = -3150, z = STAND, yaw = 180 }
-- While the clothes screen is open the player stands at VIEWPOINT and looks at a figure
-- dressed like them at FITTING, in front of the south wall under the picture.
local FITTING = { x = MID.x, y = -3320, z = STAND }
-- (as far from the figure as Marco's viewpoint is from his: about 307)
local VIEWPOINT = { x = MID.x, y = FITTING.y + 307 }
local REACH = 230
local BUILD_RANGE = 3500

local VERA = { body = "SK_fe_business_01_c#MI_fe_business_01_blue", head = "SK_fe_head_05", hair = "Hats_Hair/SK_fe_hair_03", glasses = "SK_fe_glass_04", arms = true }
-- Suits on display along the north wall, facing the room.
local DISPLAY = {
    { x = MID.x - 135, look = { body = "SK_ma_business_01#MI_ma_business_01_c", head = "SK_ma_head_02", hair = "", arms = true } },
    { x = MID.x, look = { body = "SK_fe_business_01_c#MI_fe_business_01", head = "SK_fe_head_02_asian", hair = "", arms = true } },
    { x = MID.x + 135, look = { body = "SK_ma_business_01", head = "SK_ma_head_04_dark", hair = "", arms = true } },
}
local DISPLAY_Y = ROOM.y1 - 55

-- Pieces of furniture: mesh, where its pivot goes (bottom centre for these), yaw, scale.
local MESH = {
    floor = "/Game/StaticMeshes/BuildingsModular/d_Floor02.d_Floor02",
    table = "/Game/FreeFurniturePack/Meshes/SM_Modern_Table.SM_Modern_Table",
    monitor = "/Game/ModularBarInterior/Meshes/BarProps/SM_Monitor_1.SM_Monitor_1",
    lamp = "/Game/FreeFurniturePack/Meshes/SM_Table_Lamp.SM_Table_Lamp",
    plant = "/Game/Interactive/FunctionalFurniture/DecorativeFurniture/Plants/StaticMeshes/SM_decoHousePlant2.SM_decoHousePlant2",
    bamboo = "/Game/Interactive/FunctionalFurniture/DecorativeFurniture/Plants/StaticMeshes/SM_decoHousePlant5.SM_decoHousePlant5",
    armchair = "/Game/AssetPacks/Furniture_pack/Props/Sofas_scandi/ArmChair_Scandi.ArmChair_Scandi",
    picture = "/Game/Framed_Oil_Paintings/Meshes/SM_Picture_03.SM_Picture_03",
    coffee = "/Game/FreeFurniturePack/Meshes/SM_Coffee_Table.SM_Coffee_Table",
    decor = "/Game/AssetPacks/Furniture_pack/Props/Decor/Decor_05.Decor_05",
    rackLow = "/Game/StaticMeshes/Interior/Shops/storeRack01-300cm_bottom.storeRack01-300cm_bottom",
    rackHigh = "/Game/StaticMeshes/Interior/Shops/storeRack01-300cm_top.storeRack01-300cm_top",
    chandelier = "/Game/SovietLamps/Meshes/Objects/SM_Chandelier05.SM_Chandelier05",
    cube = "/Engine/BasicShapes/Cube.Cube",
    backDoor = "/Game/AssetPacks/Freebie_01/Meshes/Building_Door_Left.Building_Door_Left",
    painting = "/Game/Framed_Oil_Paintings/Meshes/SM_Picture_05.SM_Picture_05",
    shirtA = "/Game/MiddleEast/Meshes/SM_clothes_A_05.SM_clothes_A_05",
    shirtB = "/Game/MiddleEast/Meshes/SM_clothes_B_03.SM_clothes_B_03",
}
-- d_Floor02's pivot is a corner: its middle is (-300, -475, +15) from the pivot at yaw 0.
-- Scaled to the room (the room is 557 x 654, the piece 560 x 910).
local SLAB = { sx = 1.0, sy = 0.72 }
-- the white block in the north-east corner (its front face at x0, its south side at y0)
-- (its panels t thick; the header from the doors' top, 250 above the floor)
local BACK = { x0 = ROOM.x1 - 45, y0 = -3085, t = 12, top = FLOOR + 250, white = { R = 0.86, G = 0.86, B = 0.84, A = 1 } }
BACK.mid = (BACK.y0 + ROOM.y1) / 2
local RACK_WALL = 15         -- the wall is ~8 past ROOM; the rack's 6-unit back panel and a little more into it
-- the step: 70 deep, 130 wide, its top at the door's sill (the door's bottom is at z 218)
local DOOR_STEP = { x = ROOM.x0 + 35, y = DOOR.y, sx = 70 / 600, sy = 130 / 950, sz = (218 - FLOOR) / 30 }
-- the table tops white like the plant stands (their marble picture is laid out for the
-- stand's own shape and shows as stripes and ovals on anything else)
local TOP_WHITE = { R = 0.86, G = 0.86, B = 0.84, A = 1 }
local PROPS = {
    -- the floor and the ceiling
    { m = "floor", x = MID.x + 300 * SLAB.sx, y = MID.y + 475 * SLAB.sy, z = FLOOR - 30, yaw = 0, s = { X = SLAB.sx, Y = SLAB.sy, Z = 1 }, collide = true },
    -- (the piece has a top face only: the ceiling is one upside down, its pivot moving with it)
    { m = "floor", x = MID.x + 300 * SLAB.sx, y = MID.y - 475 * SLAB.sy, z = CEILING + 30, yaw = 0, roll = 180, s = { X = SLAB.sx, Y = SLAB.sy, Z = 1 }, collide = true,
        paint = { R = 0.82, G = 0.81, B = 0.78, A = 1 } },
    -- a wooden step inside the street door, up to its sill (the door sits above the floor)
    { m = "floor", x = DOOR_STEP.x + 300 * DOOR_STEP.sx, y = DOOR_STEP.y + 475 * DOOR_STEP.sy, z = FLOOR, yaw = 0,
        s = { X = DOOR_STEP.sx, Y = DOOR_STEP.sy, Z = DOOR_STEP.sz }, collide = true },
    -- the counter, long side to the door, and what is on it
    { m = "table", x = 9890, y = -3150, z = FLOOR, yaw = -90, paintSlot = 0, paint = TOP_WHITE },
    -- (the screen turned to Vera; neither stands between her and a customer at the counter)
    { m = "monitor", x = 9900, y = -3080, z = FLOOR + 78, yaw = -40 },
    { m = "lamp", x = 9895, y = -3222, z = FLOOR + 78, yaw = 0 },
    -- plants in three corners (the fourth has the counter)
    { m = "bamboo", x = ROOM.x0 + 45, y = ROOM.y1 - 45, z = FLOOR, yaw = 0 },
    { m = "plant", x = ROOM.x0 + 60, y = ROOM.y0 + 60, z = FLOOR, yaw = 30 },
    { m = "plant", x = ROOM.x1 - 60, y = ROOM.y0 + 60, z = FLOOR, yaw = 200 },
    -- a seat by the west wall, south of the door
    { m = "armchair", x = ROOM.x0 + 70, y = -3330, z = FLOOR, yaw = 270 },
    { m = "coffee", x = ROOM.x0 + 70, y = -3240, z = FLOOR, yaw = 0, s = { X = 0.6, Y = 0.6, Z = 1 }, paintSlot = 0, paint = TOP_WHITE },
    { m = "decor", x = ROOM.x0 + 70, y = -3240, z = FLOOR + 36, yaw = 0 },
    -- Marco's kind of rack against the south wall, behind the fitting spot (it runs from
    -- its pivot along +X, its boards reach 40 into the room); the chandelier in the middle
    -- (ROOM was measured with the player's capsule: the wall itself is RACK_WALL further;
    -- the rack's back panel goes into it, so that only the shelves show)
    -- (its base board, 15 high, sunk into the floor)
    { m = "rackLow", x = MID.x - 150, y = ROOM.y0 - RACK_WALL, z = FLOOR - 17, yaw = 0 },
    { m = "rackHigh", x = MID.x - 150, y = ROOM.y0 - RACK_WALL, z = FLOOR + 133, yaw = 0 },
    { m = "chandelier", x = MID.x, y = MID.y, z = CEILING, yaw = 0 },
    -- the back corner: a white block, floor to ceiling, with a pair of glass doors centred
    -- on its front (a stock room "in the back"; the doors do not open). The door's pivot is
    -- its hinge edge: the second one is the same door mirrored. A painting on the other
    -- side of Vera.
    -- the corner block made a white frame: a front face around the doors, a header above
    -- them, a side towards the counter; behind the glass the brick of the corner
    { m = "cube", x = (BACK.x0 + ROOM.x1 + 15) / 2, y = BACK.y0 + BACK.t / 2, z = (FLOOR + CEILING) / 2,
        s = { X = (ROOM.x1 + 15 - BACK.x0) / 100, Y = BACK.t / 100, Z = (CEILING - FLOOR) / 100 }, collide = true, paint = BACK.white },
    { m = "cube", x = (BACK.x0 + ROOM.x1 + 15) / 2, y = (BACK.y0 + ROOM.y1 + 15) / 2, z = (BACK.top + CEILING) / 2,
        s = { X = (ROOM.x1 + 15 - BACK.x0) / 100, Y = (ROOM.y1 + 15 - BACK.y0) / 100, Z = (CEILING - BACK.top) / 100 }, collide = true, paint = BACK.white },
    { m = "cube", x = BACK.x0 + BACK.t / 2, y = (BACK.y0 + BACK.mid - 80) / 2, z = (FLOOR + BACK.top) / 2,
        s = { X = BACK.t / 100, Y = (BACK.mid - 80 - BACK.y0) / 100, Z = (BACK.top - FLOOR) / 100 }, collide = true, paint = BACK.white },
    { m = "cube", x = BACK.x0 + BACK.t / 2, y = (BACK.mid + 80 + ROOM.y1 + 15) / 2, z = (FLOOR + BACK.top) / 2,
        s = { X = BACK.t / 100, Y = (ROOM.y1 + 15 - BACK.mid - 80) / 100, Z = (BACK.top - FLOOR) / 100 }, collide = true, paint = BACK.white },
    { m = "backDoor", x = BACK.x0 + 2, y = BACK.mid - 80, z = FLOOR, yaw = 90 },
    { m = "backDoor", x = BACK.x0 + 2, y = BACK.mid + 80, z = FLOOR, yaw = 90, s = { X = -1, Y = 1, Z = 1 } },
    { m = "painting", x = ROOM.x1 - 4, y = -3290, z = FLOOR + 165, yaw = 90, s = { X = 1.25, Y = 1.25, Z = 1.25 } },
}
-- The room's walls are the building's outer brick, which the game lets a player tag (its
-- view line hits "outer wall" there). Inside the shop an invisible panel stands just in
-- front of each wall (2 inside the room's edge; the south wall is only 3 beyond it): the view line stops at it and no tagging is offered. The panels stop
-- only lines of sight (players walk as before), and leave the street door free.
local SKIN_T = 2
for _, w in ipairs({
    { x = ROOM.x0 + 2, y0 = ROOM.y0, y1 = DOOR.y - 70 }, { x = ROOM.x0 + 2, y0 = DOOR.y + 70, y1 = ROOM.y1 },
    { x = ROOM.x1 - 2, y0 = ROOM.y0, y1 = ROOM.y1 },
}) do
    PROPS[#PROPS + 1] = { m = "cube", x = w.x, y = (w.y0 + w.y1) / 2, z = (FLOOR + CEILING) / 2, yaw = 0,
        s = { X = SKIN_T / 100, Y = (w.y1 - w.y0) / 100, Z = (CEILING - FLOOR) / 100 }, hidden = true, sightOnly = true }
end
for _, y in ipairs({ ROOM.y0 + 2, ROOM.y1 - 2 }) do
    PROPS[#PROPS + 1] = { m = "cube", x = (ROOM.x0 + ROOM.x1) / 2, y = y, z = (FLOOR + CEILING) / 2, yaw = 0,
        s = { X = (ROOM.x1 - ROOM.x0) / 100, Y = SKIN_T / 100, Z = (CEILING - FLOOR) / 100 }, hidden = true, sightOnly = true }
end

-- The mannequins are figures without collision: an invisible block stands in each. (Off
-- while the clothes screen is open: the player looks on from beside the middle one.)
for _, d in ipairs(DISPLAY) do
    PROPS[#PROPS + 1] = { m = "cube", x = d.x, y = DISPLAY_Y, z = FLOOR + 92.5, yaw = 0, s = { X = 0.55, Y = 0.4, Z = 1.85 }, hidden = true, blocker = true }
end
-- (no shirts on the boards for now)
if false then
-- Folded shirts on two of the rack's boards (board tops measured on Marco's rack, above
-- its floor), four piles to a board, 75 apart, lying with what hung down to the room.
local BOARDS = { 79, 114.5 }
local PILE = { A = { m = "shirtA", len = 47, top = 7, t = 22, s = 0.55, count = 2, step = 6 },
    B = { m = "shirtB", len = 32, top = 6, t = 16, s = 0.62, count = 3, step = 4.5 } }
for b, top in ipairs(BOARDS) do
    for i = 1, 4 do
        local k = ((i + b) % 2 == 0) and PILE.A or PILE.B
        for n = 1, k.count do
            PROPS[#PROPS + 1] = { m = k.m, x = MID.x + (i - 2.5) * 75, y = ROOM.y0 + 6 + k.top * k.s, z = FLOOR + top + k.t * k.s / 2 + (n - 1) * k.step,
                yaw = 90, pitch = 90, s = { X = k.s, Y = k.s, Z = k.s } }
        end
    end
end
end
-- Every pair of glasses of the game on the rack, the men's on two boards and the women's
-- on two, facing the room. The rack is Marco's kind set 17 lower: its boards' tops are
-- these heights above our floor (Marco's measured ones less 17), the boards' middle a
-- little in front of the wall. Each pair stands on the bottom of its own bounds.
local GLASSES_ROWS = {
    { top = 97.5, meshes = { "SK_ma_glass_01", "SK_ma_glass_02", "SK_ma_glass_03", "SK_ma_glass_04", "SK_ma_glass_05" } },
    { top = 137, meshes = { "SK_fe_glass_01_generic", "SK_fe_glass_02_scientist", "SK_fe_glass_03", "SK_fe_glass_04", "SK_fe_glass_05" } },
    { top = 169, meshes = { "SK_ma_glass_05", "SK_ma_glass_04", "SK_ma_glass_03", "SK_ma_glass_02", "SK_ma_glass_01" } },
    { top = 201, meshes = { "SK_fe_glass_05", "SK_fe_glass_04", "SK_fe_glass_03", "SK_fe_glass_02_scientist", "SK_fe_glass_01_generic" } },
}
local GLASSES_Y = ROOM.y0 + 16
local GLASSES_STEP = 52
local LIGHTS = {
    { x = MID.x, y = MID.y, z = CEILING - 80, i = 3500, r = 800 },
    { x = MID.x - 140, y = -2990, z = FLOOR + 300, i = 6000, r = 900 },
    { x = MID.x + 140, y = -2990, z = FLOOR + 300, i = 6000, r = 900 },
    { x = MID.x - 140, y = -3310, z = FLOOR + 300, i = 6000, r = 900 },
    { x = MID.x + 140, y = -3310, z = FLOOR + 300, i = 6000, r = 900 },
}

Boutique.SPOT, Boutique.VIEWPOINT, Boutique.FITTING, Boutique.REACH, Boutique.ROOM = SPOT, VIEWPOINT, FITTING, REACH, ROOM
Boutique.FLOOR, Boutique.PROPS, Boutique.DISPLAY = FLOOR, PROPS, DISPLAY

local built = nil        -- { owner, fig, figs, props, dialogue, todo, blockers }
local solid = true       -- the mannequins' blocks (see PROPS)
local talking = 0
local hidden = false
local door = nil         -- { actor, owner }
local marker = nil

local function clear()
    local b = built
    built = nil
    if not b or World.gone then return end
    pcall(Avatar.destroyStandIn, b.fig)
    for _, f in ipairs(b.figs or {}) do pcall(Avatar.destroyStandIn, f) end
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
    local t = swap(template, '"How can I help you?"', '"Something for an occasion? Take your time."')
    local a, b = t:find('ResponseText_2_3DC4585B4FB4F1C79DACFAA7F3A5BBD7="Show me your products"', 1, true)
    if not a then return nil end
    local close = t:find(")", b, true)
    local answer = t:sub(a, close)
    local changed = answer
    changed = changed:gsub('"Show me your products"', '"Show me the suits"', 1)
    changed = changed:gsub("(ExitsDialogue_8_%x+=)%a+", "%1True", 1)
    changed = changed:gsub("(EntersSale_10_%x+=)%a+", "%1False", 1)
    changed = changed:gsub('(questEventName_14_%x+=)"[^"]*"', '%1"DialogueLoaded"', 1)
    changed = changed:gsub("(LocalFunction_19_%x+=)%a+", "%1True", 1)
    t = t:sub(1, a - 1) .. changed .. t:sub(close + 1)
    return swap(t, '"Just passing, sorry"', '"Just looking, thanks"')
end

local function asset(path) return Avatar.asset(path) end

-- A display figure made a mannequin: skin plain black (the skin material with a black
-- picture), no hair.
local WHITE = "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"
local BLACK = "/Engine/EngineResources/Black.Black"
-- The head: the face hidden, a smooth white egg on the neck in its place (the engine's
-- sphere and cylinder, in the plain basic-shape material made white).
local SPHERE, CYLINDER = "/Engine/BasicShapes/Sphere.Sphere", "/Engine/BasicShapes/Cylinder.Cylinder"
local SHAPE_MAT = "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"
-- black, matching the black skin (the albedo texture of the body is black: a little light
-- still shows its shape)
local MANNEQUIN_COLOUR = { R = 0.012, G = 0.012, B = 0.012, A = 1 }
-- The figures stand still: the egg is put in the world where the head bone is (head
-- 21 wide, 23 deep, 27 high; a neck 9 wide under it).
Boutique.HEAD = { sx = 0.21, sy = 0.23, sz = 0.27, up = 9, neck = 0.09, neckLen = 0.12, neckDown = -9 }
local function egg(f)
    local H = Boutique.HEAD
    local world = World.player():GetWorld()
    local mat = asset(SHAPE_MAT)
    local at = f.comp:GetSocketLocation(FName("head"))
    if not at or (at.X == 0 and at.Y == 0) then return end
    local function shape(path, scale, z)
        local m = asset(path)
        if not m then return end
        local a = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = at.X, Y = at.Y, Z = at.Z + z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(a) then return end
        a:SetMobility(2)
        a:SetActorEnableCollision(false)
        a.StaticMeshComponent:SetStaticMesh(m)
        if mat then
            local d = a.StaticMeshComponent:CreateDynamicMaterialInstance(0, mat, FName("None"))
            if valid(d) then d:SetVectorParameterValue(FName("Color"), MANNEQUIN_COLOUR) end
        end
        a:SetActorScale3D(scale)
        f.actors[#f.actors + 1] = a
        return a
    end
    shape(SPHERE, { X = H.sy, Y = H.sx, Z = H.sz }, H.up)
    shape(CYLINDER, { X = H.neck, Y = H.neck, Z = H.neckLen }, H.neckDown)
end

function Boutique.mannequin(f)
    local white, black = asset(WHITE), asset(BLACK)
    for _, a in ipairs(f.actors or {}) do
        pcall(function()
            local c = a.SkeletalMeshComponent
            if not valid(c) or not valid(c.SkeletalMesh) then return end
            local name = c.SkeletalMesh:GetFName():ToString()
            local head = name:find("_head_", 1, true) ~= nil
            -- the head's own black (its skin slot), put on every slot of it: eyes, lashes, teeth
            local headBlack = nil
            for i = 0, c:GetNumMaterials() - 1 do
                local m = c:GetMaterial(i)
                local mn = valid(m) and m:GetFName():ToString() or ""
                local skin = mn:find("skin", 1, true) or mn:find("_body_", 1, true) or mn:find("_head_", 1, true)
                if head and headBlack and not skin then
                    c:SetMaterial(i, headBlack)
                elseif skin or head or name:find("hands", 1, true) or name:find("_arm", 1, true) then
                    local d = c:CreateDynamicMaterialInstance(i, m, FName("None"))
                    if valid(d) then
                        if black then d:SetTextureParameterValue(FName("Albedo"), black) end
                        if black then d:SetTextureParameterValue(FName("Tint Mask"), black) end
                        if head and skin and not headBlack then headBlack = d end
                    end
                end
            end
            if head and headBlack then
                for i = 0, c:GetNumMaterials() - 1 do
                    if c:GetMaterial(i) ~= headBlack then
                        local mn = c:GetMaterial(i):GetFName():ToString()
                        if not (mn:find("skin", 1, true) or mn:find("_head_", 1, true)) then c:SetMaterial(i, headBlack) end
                    end
                end
            end
        end)
    end
end

local function build(player)
    clear()
    local world = player:GetWorld()
    local b = { owner = player:GetAddress(), props = {}, figs = {}, todo = {}, blockers = {} }
    built = b
    hidden = false
    local function later(fn) b.todo[#b.todo + 1] = fn end
    local function spawn(class, x, y, z, yaw, roll, pitch)
        -- (spawned upright and turned afterwards: a pitch given to SpawnActor turns about the wrong axis)
        local a = world:SpawnActor(StaticFindObject(class), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw or 0, Roll = roll or 0 })
        if valid(a) then
            b.props[#b.props + 1] = a
            if (pitch or 0) ~= 0 then
                a:K2_SetActorRotation({ Pitch = pitch or 0, Yaw = yaw or 0, Roll = roll or 0 }, false)
            end
        end
        return a
    end
    -- the floor first (a player walking in stands on it), then the rest a few at a time
    for n, it in ipairs(PROPS) do
        local fn = function()
            local m = asset(MESH[it.m])
            if not m then
                log("Tailoring: mesh %s is not available", it.m)
                return
            end
            local a = spawn("/Script/Engine.StaticMeshActor", it.x, it.y, it.z, it.yaw, it.roll, it.pitch)
            if not valid(a) then return end
            a:SetMobility(2)
            a.StaticMeshComponent:SetStaticMesh(m)
            if it.s then a:SetActorScale3D(it.s) end
            for slot, path in pairs(it.mats or {}) do
                local mm = asset(path)
                if mm then a.StaticMeshComponent:SetMaterial(slot, mm) end
            end
            if it.paint then
                local base = asset("/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial")
                if base then
                    local d = a.StaticMeshComponent:CreateDynamicMaterialInstance(it.paintSlot or 0, base, FName("None"))
                    if valid(d) then d:SetVectorParameterValue(FName("Color"), it.paint) end
                end
            end
            if it.collide == false then a:SetActorEnableCollision(false) end
            if it.hidden then a:SetActorHiddenInGame(true) end
            if it.sightOnly then
                local c = a.StaticMeshComponent
                c:SetCollisionEnabled(1)                    -- queries only
                c:SetCollisionResponseToAllChannels(0)      -- ignore everything...
                c:SetCollisionResponseToChannel(3, 2)       -- ...but lines of sight (visibility)
                c:SetCollisionResponseToChannel(4, 2)       -- (and camera)
            end
            if it.blocker then
                b.blockers[#b.blockers + 1] = a
                if not solid then a:SetActorEnableCollision(false) end
            end
        end
        if n <= 2 then pcall(fn) else later(fn) end
    end
    for _, row in ipairs(GLASSES_ROWS) do
        for i, name in ipairs(row.meshes) do
            later(function()
                local m = Avatar.mesh(name)
                if not m then return end
                local bounds = m:GetBounds()
                local x = MID.x + (i - (#row.meshes + 1) / 2) * GLASSES_STEP
                local z = FLOOR + row.top - (bounds.Origin.Z - bounds.BoxExtent.Z) + 0.3
                local a = spawn("/Script/Engine.SkeletalMeshActor", x, GLASSES_Y - bounds.Origin.Y, z, 0)
                if not valid(a) then return end
                a:SetActorEnableCollision(false)
                a.SkeletalMeshComponent:SetSkeletalMesh(m, true)
            end)
        end
    end
    for _, it in ipairs(LIGHTS) do
        later(function()
            local l = spawn("/Script/Engine.PointLight", it.x, it.y, it.z)
            if not valid(l) then return end
            local c = l.LightComponent
            c:SetMobility(2)
            c:SetIntensity(it.i)
            c:SetAttenuationRadius(it.r)
            c:SetLightColor({ R = 1, G = 0.9, B = 0.78, A = 1 }, true)
            c:SetCastShadows(false)
        end)
    end
    for _, d in ipairs(DISPLAY) do
        later(function()
            local f = Avatar.buildStandIn(d.look, d.x, DISPLAY_Y, STAND, -90, nil)
            if f then
                b.figs[#b.figs + 1] = f
                pcall(Boutique.mannequin, f)
            end
        end)
    end
    later(function() b.fig = Avatar.buildStandIn(VERA, SPOT.x, SPOT.y, SPOT.z, SPOT.yaw, nil, "idle") end)
    later(function()
        local text = dialogueText()
        local class = StaticFindObject("/Game/Interactive/dialogueInstance.dialogueInstance_C")
        if not text or not valid(class) then
            log("Tailoring: no dialogue (template %s)", tostring(text ~= nil))
            return
        end
        local d = world:SpawnActor(class, { X = SPOT.x, Y = SPOT.y, Z = SPOT.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(d) then return end
        -- this copy is ours alone: it must not be written into anybody's save
        pcall(function() if valid(d.RamaSave) then d.RamaSave:K2_DestroyComponent(d) end end)
        if Repl.importRaw(d, "dialogueLines", text) then b.dialogue = d end
        log("Tailoring: built (%d pieces, Vera %s, dialogue %s)", #b.props, tostring(b.fig ~= nil), tostring(b.dialogue ~= nil))
    end)
end
Boutique.build = build

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
        if not ok then log("Tailoring: %s", tostring(e)) end
    end
end)

function Boutique.distance()
    local player = World.player()
    if not player then return math.huge end
    local l = player:K2_GetActorLocation()
    return math.sqrt((l.X - SPOT.x) ^ 2 + (l.Y - SPOT.y) ^ 2 + ((l.Z - SPOT.z) * 2) ^ 2)
end

-- Talking distance: in front of the counter, within REACH of Vera (the counter is between).
function Boutique.near() return built ~= nil and built.fig ~= nil and Boutique.distance() <= REACH end

-- True while the player is in the shop's room.
function Boutique.inside()
    local player = World.player()
    if not player then return false end
    local l = player:K2_GetActorLocation()
    return l.X > ROOM.x0 and l.X < ROOM.x1 and l.Y > ROOM.y0 and l.Y < ROOM.y1 and l.Z < CEILING
end

function Boutique.solid(on)
    solid = on == true
    for _, a in ipairs(built and built.blockers or {}) do
        pcall(function() if valid(a) then a:SetActorEnableCollision(solid) end end)
    end
end

function Boutique.hide(on)
    on = on == true
    if not built or not built.fig or hidden == on then return end
    hidden = on
    for _, a in ipairs(built.fig.actors or {}) do
        pcall(function() if valid(a) then a:SetActorHiddenInGame(on) end end)
    end
end

function Boutique.talk()
    local player = World.player()
    if not player or not built or not valid(built.dialogue) then return false end
    local ok, e = pcall(function()
        talking = os.clock()
        player:startDialogue(built.dialogue)
        player.focusCamera = false
        player.dialogueWidget.txtTalkerName:SetText(FText(Boutique.NAME))
    end)
    if not ok then log("Tailoring: dialogue failed: %s", tostring(e)) end
    return ok
end

Boutique.onShow = nil    -- set by the clothes screens: called when the player asks to see the suits

Core.Hooks.add("/Game/Interactive/dialogueInstance.dialogueInstance_C:DialogueLoaded", function(ctx)
    if not live() or not built or os.clock() - talking > 600 then return end
    local ok, mine = pcall(function() return ctx:get():GetAddress() == built.dialogue:GetAddress() end)
    if not ok or not mine then return end
    talking = 0
    Core.after(0.25, function()
        if Boutique.onShow then pcall(Boutique.onShow) end
    end)
end)

Boutique.wanted = function() return World.extras() end

-- The street door: the game keeps it locked; here it is open to everybody.
local function tendDoor(player)
    local owner = player:GetAddress()
    if not door or door.owner ~= owner or not Core.alive(door.actor) then
        door = nil
        for _, d in ipairs(Core.actors("/Game/Interactive/doorBase.doorBase_C") or {}) do
            local ok, l = pcall(function() return d:K2_GetActorLocation() end)
            if ok and l and math.abs(l.X - DOOR.x) < 25 and math.abs(l.Y - DOOR.y) < 25 and l.Z < 400 then
                door = { actor = d, owner = owner }
                break
            end
        end
    end
    if door then
        pcall(function() if door.actor.doorLocked == true then door.actor.doorLocked = false end end)
    end
end

Core.every(1, function()
    if not live() then return end
    local player = World.player()
    if not player or not Boutique.wanted() then
        if built then clear() end
        return
    end
    if built and built.owner ~= player:GetAddress() then built = nil end      -- another world: its actors are gone
    local l = player:K2_GetActorLocation()
    local far = (l.X - SPOT.x) ^ 2 + (l.Y - SPOT.y) ^ 2 > BUILD_RANGE * BUILD_RANGE
    local done = built and (built.todo == nil or #built.todo == 0)
    if built and (far or (done and not valid(built.fig and built.fig.body))) then
        clear()
    elseif not built and not far and os.clock() - (Boutique.builtAt or -100) > 10 then
        Boutique.builtAt = os.clock()
        local ok, e = pcall(Avatar.batch, build, player)
        if not ok then log("Tailoring: %s", tostring(e)) end
    end
    if not far then pcall(tendDoor, player) end
    -- the shop on the map (once per world; the marker is never saved: coop/hud.lua)
    if Hud.ready() and (not marker or not Core.alive(marker)) then
        marker = Hud.mapMarker(Boutique.STORE, "Suits and formal wear", MID.x, MID.y, FLOOR, Hud.MARKER_SHOP)
    end
end)

-- A save loaded from inside the game: the level stays, so what was built is taken away
-- (it is built again for the new player).
World.listen("loading", function()
    if not live() or not built then return end
    local player = World.player()
    if player and player:GetAddress() == built.owner then clear() else built = nil end
end)

function Boutique.shutdown()
    clear()
    if marker then pcall(Hud.forgetMarker, marker) end
end
function Boutique.rebuild()
    local player = World.player()
    if player then Avatar.batch(build, player) end
end

return Boutique
