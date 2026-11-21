-- Small pictures of a dressed figure for the clothes screens (the game has icons for its
-- furniture, none for clothes).
--
-- The game renders them itself: a figure is put up well below the ground with three lamps,
-- a scene-capture camera that shows nothing but that figure draws it into a texture, and
-- the figure is taken down again. The texture is shown by an Image widget straight away
-- (dark until its picture is taken, a fraction of a second later).
--
-- Every picture keeps its capture actor: that actor is what holds the texture, so the
-- texture lives exactly as long as the world does. Nothing of an earlier world is touched
-- again: the list is dropped when the player's character is another one.

local Core = require("core")
local World = require("coop.world")
local Avatar = require("coop.avatar")

local valid = Core.valid

local Thumbs = { made = 0 }

local RGBA8, FINAL_COLOUR, SHOW_ONLY_LIST = 2, 2, 2
-- body: the whole figure. face: the face and nothing else. hair: hair or hat, seen a
-- little from above. wrist: the left wrist (a watch); `bone`: the camera stands in front of
-- that bone of the figure and not at a fixed height.
local SHOTS = {
    body = { dist = 236, up = 0, fov = 30, w = 192, h = 288 },
    head = { dist = 95, up = 72, fov = 30, w = 192, h = 192 },
    face = { dist = 50, up = 76, fov = 28, w = 192, h = 192 },
    hair = { dist = 58, up = 105, fov = 30, pitch = -18, w = 192, h = 192 },
    wrist = { dist = 40, up = 1, fov = 28, w = 192, h = 192, bone = "hand_l" },
}
Thumbs.SHOTS = SHOTS
-- Women are shorter: a face, head or hair picture is taken this much lower.
Thumbs.FEMALE_DROP = { face = 6, head = 9, hair = 12 }
function Thumbs.lower(spec)
    local body = spec and spec.look and spec.look.body
    if type(body) == "string" and body:sub(1, 6) == "SK_fe_" then return -(Thumbs.FEMALE_DROP[spec.shot or "body"] or 0) end
    return 0
end
local BATCH = 2              -- figures put up at the same time (building one takes a while)
Thumbs.depth = 4000          -- how far below the player the pictures are taken
Thumbs.tune = nil            -- tests: called with every new capture component

local owner = 0              -- address of the player character the pictures belong to
local cache = {}             -- key -> { rt, cam, spec, done }
local queue = {}             -- entries waiting for their picture
local job = nil              -- { x, y, z, lamps, items = { { entry, fig } }, stage, at }

local function reset()
    owner, cache, queue, job = 0, {}, {}, nil
end

local function asset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if valid(o) then return o end
    return nil
end

local function lamp(world, x, y, z, intensity)
    local l = world:SpawnActor(StaticFindObject("/Script/Engine.PointLight"), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    local c = l.LightComponent
    c:SetMobility(2)
    c:SetIntensity(intensity)
    c:SetAttenuationRadius(440)
    c:SetLightColor({ R = 1, G = 0.96, B = 0.9, A = 1 }, true)
    c:SetCastShadows(false)
    return l
end

-- The texture for `key` (made on first use). `spec` is { look = { body, head, hair, arms },
-- shot = "body" | "head" }.
function Thumbs.get(key, spec)
    local player = World.player()
    if not player then return nil end
    local address = player:GetAddress()
    if address ~= owner then
        reset()
        owner = address
    end
    local e = cache[key]
    if e then return e end
    local shot = SHOTS[spec.shot] or SHOTS.body
    local ok, made = pcall(function()
        local KRL = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
        local rt = KRL:CreateRenderTarget2D(player, shot.w, shot.h, RGBA8)
        local l = player:K2_GetActorLocation()
        local cam = player:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.SceneCapture2D"),
            { X = l.X, Y = l.Y, Z = l.Z - Thumbs.depth }, { Pitch = 0, Yaw = 0, Roll = 0 })
        local comp = cam.CaptureComponent2D
        comp.TextureTarget = rt
        comp.bCaptureEveryFrame = false
        comp.bCaptureOnMovement = false
        comp.FOVAngle = shot.fov
        comp.CaptureSource = FINAL_COLOUR
        comp.PrimitiveRenderMode = SHOW_ONLY_LIST
        if Thumbs.tune then pcall(Thumbs.tune, comp) end
        return { rt = rt, cam = cam, comp = comp, spec = spec, shot = shot, done = false }
    end)
    if not ok or not made or not valid(made.rt) then return nil end
    cache[key] = made
    queue[#queue + 1] = made
    Thumbs.made = Thumbs.made + 1
    return made
end

-- An Image widget of the given size showing the picture for `key`, or nil.
function Thumbs.image(scr, key, spec, w, h)
    local e = Thumbs.get(key, spec)
    if not e then return nil end
    local img = scr.new("Image")
    local ok = pcall(function()
        img.Brush.ResourceObject = e.rt
        img.Brush.ImageSize = { X = w, Y = h }
    end)
    if not ok then return nil end
    return scr.sized(img, w, h)
end

function Thumbs.pending() return #queue + (job and #job.items or 0) end

-- Forgets every picture (they are made again when next asked for).
function Thumbs.forget() owner = -1 end

local function finish()
    for _, l in ipairs(job.lamps) do pcall(function() l:K2_DestroyActor() end) end
    job = nil
end

Core.onTick(function()
    if not job and #queue == 0 then return end
    local player = World.player()
    if not player or player:GetAddress() ~= owner then
        reset()
        return
    end
    local now = os.clock()
    if not job then
        local l = player:K2_GetActorLocation()
        local world = player:GetWorld()
        job = { x = l.X, y = l.Y, z = l.Z - Thumbs.depth, items = {}, stage = "idle", at = 0 }
        local ok = pcall(function()
            job.lamps = { lamp(world, job.x - 180, job.y - 115, job.z + 55, 15000), lamp(world, job.x - 150, job.y + 150, job.z + 20, 7500),
                lamp(world, job.x - 45, job.y, job.z + 210, 4500) }
        end)
        if not ok then job.lamps = job.lamps or {} end
        -- A black wall behind the figure: without one the background is the sky and the
        -- fog, bright by day and black at night. Its material takes no light at all: a
        -- lit one glows behind the figure, and even a black glossy one mirrors the sky.
        pcall(function()
            local wall = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = job.x + 70, Y = job.y, Z = job.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
            wall:SetMobility(2)
            wall.StaticMeshComponent:SetStaticMesh(asset("/Engine/BasicShapes/Cube.Cube"))
            wall:SetActorScale3D({ X = 0.1, Y = 8, Z = 8 })
            wall:SetActorEnableCollision(false)
            job.wall = wall
            job.lamps[#job.lamps + 1] = wall
            local KML = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
            local unlit, black = asset("/Paper2D/OpaqueUnlitSpriteMaterial.OpaqueUnlitSpriteMaterial"), asset("/Engine/EngineResources/Black.Black")
            if unlit and black then
                local m = KML:CreateDynamicMaterialInstance(player, unlit, FName("None"))
                m:SetTextureParameterValue(FName("SpriteTexture"), black)
                wall.StaticMeshComponent:SetMaterial(0, m)
                Thumbs.wall = "unlit"
            else
                local m = KML:CreateDynamicMaterialInstance(player, asset("/Game/ModularBarInterior/Materials/Plastic/MI_Plastic_White.MI_Plastic_White"), FName("None"))
                local dark = { R = 0, G = 0, B = 0, A = 1 }
                m:SetVectorParameterValue(FName("Base Color"), dark)
                m:SetVectorParameterValue(FName("Noise Color"), dark)
                m:SetScalarParameterValue(FName("Color Intensity"), 1)
                m:SetScalarParameterValue(FName("Dirt Intensity"), 0)
                wall.StaticMeshComponent:SetMaterial(0, m)
                Thumbs.wall = "dyed"
            end
        end)
    end
    if job.stage == "idle" then
        if #queue == 0 then
            finish()
            return
        end
        -- put the next few figures up, each in front of its own camera
        pcall(Avatar.batch, function()
        for _ = 1, BATCH do
            local e = table.remove(queue, 1)
            if not e then break end
            local ok, fig = pcall(Avatar.buildStandIn, e.spec.look, job.x, job.y, job.z, 180, nil)
            if ok and fig then
                pcall(function()
                    e.cam:K2_SetActorLocationAndRotation({ X = job.x - e.shot.dist, Y = job.y, Z = job.z + e.shot.up + Thumbs.lower(e.spec) }, { Pitch = e.shot.pitch or 0, Yaw = 0, Roll = 0 }, false, {}, true)
                    for _, a in ipairs(fig.actors) do e.comp:ShowOnlyActorComponents(a) end
                    if job.wall then e.comp:ShowOnlyActorComponents(job.wall) end
                end)
                job.items[#job.items + 1] = { entry = e, fig = fig }
            else
                e.done = true
            end
        end
        end)
        job.stage, job.at = "posed", now + 0.15
    elseif job.stage == "posed" and now >= job.at then
        for _, it in ipairs(job.items) do
            pcall(function()
                local e = it.entry
                if e.shot.bone then
                    -- (now that the figure stands in its pose)
                    local b = it.fig.comp:GetSocketLocation(FName(e.shot.bone))
                    e.cam:K2_SetActorLocationAndRotation({ X = b.X - e.shot.dist, Y = b.Y, Z = b.Z + e.shot.up }, { Pitch = e.shot.pitch or 0, Yaw = 0, Roll = 0 }, false, {}, true)
                end
                e.comp:CaptureScene()
            end)
        end
        job.stage, job.at = "shot", now + 0.06
    elseif job.stage == "shot" and now >= job.at then
        for _, it in ipairs(job.items) do
            pcall(function() it.entry.comp:ClearShowOnlyComponents() end)
            pcall(Avatar.destroyStandIn, it.fig)
            it.entry.done = true
        end
        job.items, job.stage = {}, "idle"
    end
end)

World.listen("stop", function() end)

return Thumbs
