-- No tags inside the mod's places.
--
-- The game lets a player tag a wall when the view line hits its "outer wall" surface, and
-- the brick inside many of the city's buildings is that surface. A building the mod turns
-- into a shop or a home for someone (the barber's, the boutique, the trash man's) is not
-- to be tagged inside: an invisible panel stands just in front of each of its walls. It
-- stops only lines of sight (the view line the game looks along, the camera), so players
-- walk and see as before, nothing can be tagged inside, and the outside is as it was.
-- Doors are left free (a gap in the panel), so that what is beyond them is seen and used
-- as before.
--
-- Every place the mod builds into a building calls NoTag.panels with its room.

local Core = require("core")

local valid = Core.valid

local NoTag = {}

local CUBE = "/Engine/BasicShapes/Cube.Cube"     -- 100 units on each side, its middle at the origin
local THICK = 2                                  -- the panel's thickness
local INSET = 2                                  -- how far inside the room's edge it stands

local function cube()
    local m = StaticFindObject(CUBE)
    if not valid(m) then pcall(function() m = LoadAsset(CUBE) end) end
    return valid(m) and m or nil
end

local function panel(world, mesh, x, y, z, sx, sy, sz)
    local a = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(a) then return nil end
    a:SetMobility(2)
    a.StaticMeshComponent:SetStaticMesh(mesh)
    a:SetActorScale3D({ X = sx / 100, Y = sy / 100, Z = sz / 100 })
    a:SetActorHiddenInGame(true)
    local c = a.StaticMeshComponent
    c:SetCollisionEnabled(1)                    -- queries only
    c:SetCollisionResponseToAllChannels(0)      -- ignore everything...
    c:SetCollisionResponseToChannel(3, 2)       -- ...but lines of sight (visibility)
    c:SetCollisionResponseToChannel(4, 2)       -- (and camera)
    return a
end

-- Puts the panels up in `world` for a room `{ x0, x1, y0, y1, floor, ceiling }` (the faces
-- of its walls, the floor's top, the ceiling's underside). `doors` = { { wall = "x0" | "x1"
-- | "y0" | "y1", at = the door's middle along that wall, half = half its width } }.
-- Returns the panels (the caller takes them away with its own things).
function NoTag.panels(world, room, doors)
    local mesh = cube()
    if not mesh then return {} end
    local out = {}
    local h = room.ceiling - room.floor
    local z = (room.floor + room.ceiling) / 2
    -- each wall as stretches along it, the doors cut out
    local function wall(name, from, to, place)
        local cuts = {}
        for _, d in ipairs(doors or {}) do
            if d.wall == name then cuts[#cuts + 1] = { d.at - d.half, d.at + d.half } end
        end
        table.sort(cuts, function(a, b) return a[1] < b[1] end)
        local at = from
        local stretches = {}
        for _, c in ipairs(cuts) do
            if c[1] > at then stretches[#stretches + 1] = { at, c[1] } end
            at = math.max(at, c[2])
        end
        if to > at then stretches[#stretches + 1] = { at, to } end
        for _, s in ipairs(stretches) do
            local a = place(s[1], s[2])
            if a then out[#out + 1] = a end
        end
    end
    wall("x0", room.y0, room.y1, function(a, b) return panel(world, mesh, room.x0 + INSET, (a + b) / 2, z, THICK, b - a, h) end)
    wall("x1", room.y0, room.y1, function(a, b) return panel(world, mesh, room.x1 - INSET, (a + b) / 2, z, THICK, b - a, h) end)
    wall("y0", room.x0, room.x1, function(a, b) return panel(world, mesh, (a + b) / 2, room.y0 + INSET, z, b - a, THICK, h) end)
    wall("y1", room.x0, room.x1, function(a, b) return panel(world, mesh, (a + b) / 2, room.y1 - INSET, z, b - a, THICK, h) end)
    return out
end

return NoTag
