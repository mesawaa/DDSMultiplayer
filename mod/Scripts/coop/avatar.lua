-- Shows the other players, and the police chasing them, in the shared world.
--
-- Each game publishes its player's position a few times a second (net state stream),
-- followed by the positions of policemen that are alerted near that player. For every
-- other player a "puppet" is spawned: plain skeletal-mesh actors wearing the game's
-- citizen body parts and its citizen walk animation, moved towards the latest received
-- position. Their pursuers get the same treatment in a police uniform. Puppets have no
-- collision and no game logic: police puppets show a chase, they cannot arrest anyone.
--
-- A player's puppet also shows what that player is doing with the phone, using the game's
-- own citizen animations: looking at it (phone stood up in the left hand), talking on it
-- during a call (phone at the ear), and the phone's torch, a real spotlight that lights
-- the world for everybody and points where that player is looking.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")

local log, valid = Core.log, Core.valid

local Avatar = { puppets = {} }   -- peer id -> { player = puppet, police = { [copId] = puppet } }

local MESHES = "/Game/CitizenNPC/CharacterParts/Meshes/"
local LOOKS = {
    player = { body = "SK_ma_casual_jacket_01_a", parts = { "SK_ma_head_01", "Basebody/SK_ma_hands_average", "Hats_Hair/SK_ma_hair_02" } },
    police = { body = "SK_ma_police_01_a", parts = { "SK_ma_head_02", "Basebody/SK_ma_hands_average", "Hats_Hair/SK_ma_hat_cap_01" } },
}
local ANIM_CLASS = "/Game/Animations/CitizenMale01_animBP.CitizenMale01_animBP_C"
local FEET_OFFSET = -90       -- actor positions are capsule centres; meshes stand on their origin
local MESH_YAW = -90          -- character meshes face +Y
local NAME_HEIGHT = 200
local MAX_POLICE = 4
local POLICE_RANGE = 6000
local PHONE_MESH = "/Game/Player/FP_Items/telefon.telefon"
local PHONE_ANIM = "/Game/Animations/CitizenMale_Walk_04_Texting_Loop_IP.CitizenMale_Walk_04_Texting_Loop_IP"
local CALL_ANIM = "/Game/CityAnimations/Retargeted/Talking_2.Talking_2"
local SMOKE_FX = "/Game/AssetPacks/AbandonedFactory/EpicContent/StarterContent/Particles/P_Smoke.P_Smoke"
-- Frame 0 of the citizens' turn-on-the-spot animation: standing relaxed, facing forward.
local STAND_ANIM = "/Game/Animations/CitizenMale_MOB1_Stand_Relaxed_L_90_IPC1.CitizenMale_MOB1_Stand_Relaxed_L_90_IPC1"
-- The joint the game gives its own smokers: a small prop with a thin trail of smoke.
local JOINT_CLASS = "/Game/Skeletal/NPC/EddieReady/Props/ballenaCigarBP.ballenaCigarBP_C"
local WISP_FX = SMOKE_FX
local FLAG_PHONE, FLAG_LIGHT, FLAG_CALL, FLAG_SMOKE = 1, 2, 4, 8

-- Emotes, by number (the number is what travels). All are the game's own citizen
-- animations; a few are single poses.
Avatar.EMOTES = {
    { name = "Talk", anim = "/Game/CityAnimations/Retargeted/Talking_3.Talking_3" },
    { name = "Hands up", anim = "/Game/Animations/PozyEndgame/Retarget/NPC_PoseExport_Anim_root_DeadDealer02.NPC_PoseExport_Anim_root_DeadDealer02" },
    { name = "Sit", anim = "/Game/Animations/NoweMocap/NaCitizen/Dopracowane/shopkeeper_02_desk_laptop.shopkeeper_02_desk_laptop" },
    { name = "Lounge", anim = "/Game/Animations/NoweMocap/NaCitizen/Dopracowane/shopkeeper_04_jay.shopkeeper_04_jay" },
    { name = "Smoke break", anim = "/Game/Animations/NoweMocap/NaCitizen/Sitting_waiting.Sitting_waiting", smoke = true },
    { name = "Crouch", anim = "/Game/Animations/Sebiks_MOB1_Crouch_Idle_V2_IPC.Sebiks_MOB1_Crouch_Idle_V2_IPC" },
    { name = "Play dead", anim = "/Game/Animations/PozyEndgame/Retarget/NPC_PoseExport_Anim_root_DeadDealer01.NPC_PoseExport_Anim_root_DeadDealer01" },
    { name = "Strut", anim = "/Game/Animations/CitizenMale_Walk_08_Listen_Music_Loop_IP.CitizenMale_Walk_08_Listen_Music_Loop_IP" },
}
Avatar.localEmote = 0      -- the emote our own player is doing (0 = none)
Avatar.STAND_ANIM = STAND_ANIM
Avatar.smokeUntil = 0      -- our own player is smoking until this time

function Avatar.setEmote(id)
    Avatar.localEmote = Avatar.EMOTES[id] and id or 0
end

-- Settings that can be tuned while looking at the result (also from the dev console).
Avatar.tune = {
    -- Looking at the phone: the animation holds it in the left palm and taps with the right
    -- hand. The phone stands up from the palm, screen towards the face.
    phoneSocket = "LeftHandSocket",
    phoneLoc = { X = 0, Y = 6, Z = 0 }, phoneRot = { Pitch = 0, Yaw = 55, Roll = 90 }, phoneScale = 1.0,
    -- On a call: the right hand is at the ear.
    callSocket = "RightHandSocket",
    callLoc = { X = 0, Y = 0, Z = 0 }, callRot = { Pitch = 0, Yaw = 0, Roll = 90 },
    standFraction = 0.37,      -- where in the walking-and-texting loop (0..1) a standing player is held: feet together
    walkSpeed = 160,           -- units per second the loop was made for
    lightForward = 40, lightUp = 45,
    -- A spot light only shows where it lands. This small light at the phone falls on the
    -- holder's own hands and chest, so a torch that is on can be seen from any side.
    -- It sits a little in front of the hands: any closer and the palm burns out white.
    glowForward = 62, glowUp = 40, glowIntensity = 900, glowRadius = 200,
    -- The joint, relative to the bone it hangs from.
    jointBone = "head", jointLoc = { X = 0.2, Y = 9.5, Z = 0 }, jointRot = { Pitch = 0, Yaw = 0, Roll = 90 }, jointThin = 0.38, jointLong = 1.1,
    -- The wisp of smoke that rises from its tip.
    wispFx = WISP_FX, wispScale = 0.07, wispAt = 7.3,
}

-- Looking an asset up takes a few milliseconds. While several figures are built in one go
-- (Avatar.batch) each asset is looked up once. The memo lives only for that call: an
-- asset nobody uses any more can be thrown away by the engine between two ticks.
local memo = nil
local function asset(path)
    if memo then
        local hit = memo[path]
        if hit ~= nil then return hit or nil end
    end
    local obj = StaticFindObject(path)
    if not valid(obj) then
        obj = nil
        pcall(function() obj = LoadAsset(path) end)
        if not valid(obj) then obj = nil end
    end
    if memo then memo[path] = obj or false end
    return obj
end

function Avatar.batch(fn, ...)
    local outer = memo
    memo = memo or {}
    local ok, r1, r2 = pcall(fn, ...)
    if not outer then memo = nil end
    if not ok then error(r1, 0) end
    return r1, r2
end
Avatar.asset = asset

-- `name` may include a subfolder ("Basebody/SK_ma_hands_average").
local function mesh(name) return asset(MESHES .. name .. "." .. name:match("[^/]+$")) end
Avatar.mesh = mesh

local function spawn(world, className, pos)
    local class = StaticFindObject(className)
    return world:SpawnActor(class, { X = pos.x, Y = pos.y, Z = pos.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
end

local function destroy(p)
    if not p then return end
    -- when the world itself is gone its actors are too: they are only forgotten
    if not World.gone then
        for _, actor in ipairs(p.actors or {}) do
            pcall(function() if valid(actor) then actor:K2_DestroyActor() end end)
        end
    end
    p.actors = {}
end

-- The skin of body, arms and hands follows the head.
local SKIN = "/Game/CitizenNPC/CharacterParts/Materials/Basebody/"
local SKIN_OF = {
    SK_ma_head_04_dark = "MI_ma_body_01_deep",
    SK_ma_head_05_asian = "MI_ma_skin_body_01_caucasian_yellow",
    SK_ma_head_05_basian = "MI_ma_skin_body_01_caucasian_yellow",
}

local function applySkin(p, head)
    local name = SKIN_OF[head or ""]
    if not name then return end
    local skin = asset(SKIN .. name .. "." .. name)
    if not skin then
        log("Skin material %s is not available", name)
        return
    end
    for _, actor in ipairs(p.actors) do
        pcall(function()
            local c = actor.SkeletalMeshComponent
            for i = 0, c:GetNumMaterials() - 1 do
                local m = c:GetMaterial(i)
                local n = valid(m) and m:GetFName():ToString() or ""
                if n:find("skin_body", 1, true) or n:find("_body_01", 1, true) then c:SetMaterial(i, skin) end
            end
        end)
    end
end

-- Builds one puppet. `name` adds a floating label (players only).
local function build(look, pos, name)
    local player = World.player()
    if not player then return nil end
    local world = player:GetWorld()
    local p = { actors = {}, x = pos.x, y = pos.y, z = pos.z, yaw = pos.yaw, tx = pos.x, ty = pos.y, tz = pos.z, tyaw = pos.yaw, speed = 0 }
    local ok, e = xpcall(function()
        local bodyMesh = mesh(look.body)
        if not bodyMesh then error("body mesh not available") end
        local body = spawn(world, "/Script/Engine.SkeletalMeshActor", pos)
        p.actors[1] = body
        body:SetActorEnableCollision(false)
        local comp = body.SkeletalMeshComponent
        comp:SetSkeletalMesh(bodyMesh, true)
        local anim = asset(ANIM_CLASS)
        if anim then comp:K2_SetAnimInstanceClass(anim) end
        p.body, p.comp = body, comp
        for _, partName in ipairs(look.parts) do
            local m = mesh(partName)
            if not m then log("Puppet part %s is not available", partName) end
            if m then
                local part = spawn(world, "/Script/Engine.SkeletalMeshActor", pos)
                p.actors[#p.actors + 1] = part
                part:SetActorEnableCollision(false)
                part.SkeletalMeshComponent:SetSkeletalMesh(m, true)
                part.SkeletalMeshComponent:SetMasterPoseComponent(comp, false)
                part:K2_AttachToActor(body, FName("None"), 2, 2, 2, false)
            end
        end
        applySkin(p, look.parts[1])
        if name then
            local label = spawn(world, "/Script/Engine.TextRenderActor", pos)
            p.actors[#p.actors + 1] = label
            local text = label.TextRender
            text:K2_SetText(FText(name))
            text:SetWorldSize(22)
            text:SetHorizontalAlignment(1)
            text:SetTextRenderColor({ R = 255, G = 255, B = 255, A = 255 })
            p.label = label
        end
    end, debug.traceback)
    if not ok then
        log("Could not build a puppet: %s", tostring(e))
        destroy(p)
        return nil
    end
    return p
end

-- How each other player looks: peer id -> { body, head, hair, arms }. Unknown players wear
-- the default.
Avatar.looks = {}

-- Turns { body, head, hair, arms } into the body mesh and part list a puppet is built from.
local function partsOf(l)
    if type(l) ~= "table" or type(l.body) ~= "string" then return LOOKS.player end
    local parts = { l.head or "SK_ma_head_01", "Basebody/SK_ma_hands_average" }
    if l.arms then parts[#parts + 1] = "Basebody/SK_ma_arm" end
    if l.hair and l.hair ~= "" then parts[#parts + 1] = l.hair end
    return { body = l.body, parts = parts }
end

local function lookOf(id)
    return partsOf(Avatar.looks[id])
end

local function target(p, s)
    p.tx, p.ty, p.tz, p.tyaw, p.speed = s.x, s.y, s.z, s.yaw, s.speed
    p.flags, p.pitch, p.emote = s.flags or 0, s.pitch or 0, s.emote or 0
end

-- The torch of the local player's own phone, used as the model for the puppets' torches.
local function localTorch()
    local player = World.player()
    local torch = nil
    pcall(function() torch = player.phoneRef.flashlight end)
    if valid(torch) then return torch end
    return nil
end

local function buildPhone(p)
    local world = World.player():GetWorld()
    local m = asset(PHONE_MESH)
    if not m then error("phone mesh not available") end
    local phone = spawn(world, "/Script/Engine.StaticMeshActor", { x = p.x, y = p.y, z = p.z })
    p.actors[#p.actors + 1] = phone
    phone:SetMobility(2)
    phone:SetActorEnableCollision(false)
    phone.StaticMeshComponent:SetStaticMesh(m)
    phone:SetActorHiddenInGame(true)
    p.phone = phone
end

-- Puts the phone in the hand that the current pose ("phone" or "call") holds it with.
local function seatPhone(p, pose)
    if not p.phone or not valid(p.phone) then return end
    local t = Avatar.tune
    local socket, loc, rot = t.phoneSocket, t.phoneLoc, t.phoneRot
    if pose == "call" then socket, loc, rot = t.callSocket, t.callLoc, t.callRot end
    p.phone:K2_AttachToComponent(p.comp, FName(socket), 2, 2, 2, false)
    p.phone:K2_SetActorRelativeLocation(loc, false, {}, true)
    p.phone:K2_SetActorRelativeRotation(rot, false, {}, true)
    p.phone:SetActorRelativeScale3D({ X = t.phoneScale, Y = t.phoneScale, Z = t.phoneScale })
end

local function jointClass()
    local class = StaticFindObject(JOINT_CLASS)
    if valid(class) then return class end
    pcall(function() LoadAsset("/Game/Skeletal/NPC/EddieReady/Props/ballenaCigarBP.ballenaCigarBP") end)
    class = StaticFindObject(JOINT_CLASS)
    if valid(class) then return class end
    return nil
end

local function seatJoint(p)
    if not p.joint or not p.smoke or not valid(p.smoke) then return end
    local t = Avatar.tune
    p.smoke:K2_AttachToComponent(p.comp, FName(t.jointBone), 2, 2, 2, false)
    p.smoke:K2_SetActorRelativeLocation(t.jointLoc, false, {}, true)
    p.smoke:K2_SetActorRelativeRotation(t.jointRot, false, {}, true)
    -- the game's prop is a fat cigar; across its length (its Z) it is thinned to a cigarillo
    p.smoke:SetActorRelativeScale3D({ X = t.jointThin, Y = t.jointThin, Z = t.jointLong })
end

-- What a smoking puppet shows: the joint, or a puff of smoke if the joint is not there.
local function buildSmoke(p)
    local world = World.player():GetWorld()
    local class = jointClass()
    if class then
        local joint = world:SpawnActor(class, { X = p.x, Y = p.y, Z = p.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if valid(joint) then
            p.actors[#p.actors + 1] = joint
            joint:SetActorEnableCollision(false)
            p.smoke, p.joint = joint, true
            seatJoint(p)
            pcall(function()
                local t = Avatar.tune
                local fx = asset(t.wispFx)
                if not fx then return end
                local wisp = spawn(world, "/Script/Engine.Emitter", { x = p.x, y = p.y, z = p.z })
                p.actors[#p.actors + 1] = wisp
                wisp:SetActorEnableCollision(false)
                wisp.ParticleSystemComponent:SetTemplate(fx)
                -- It follows the tip but keeps pointing up.
                wisp:K2_AttachToActor(joint, FName("None"), 2, 1, 1, false)
                wisp:K2_SetActorRelativeLocation({ X = 0, Y = 0, Z = t.wispAt }, false, {}, true)
                wisp:SetActorScale3D({ X = t.wispScale, Y = t.wispScale, Z = t.wispScale })
                p.wisp = wisp
            end)
            return
        end
    end
    local fx = asset(SMOKE_FX)
    if not fx then error("smoke effect not available") end
    local emitter = spawn(world, "/Script/Engine.Emitter", { x = p.x, y = p.y, z = p.z })
    p.actors[#p.actors + 1] = emitter
    emitter:SetActorEnableCollision(false)
    emitter.ParticleSystemComponent:SetTemplate(fx)
    emitter:K2_AttachToComponent(p.comp, FName("head"), 2, 2, 2, false)
    emitter:SetActorRelativeScale3D({ X = 0.22, Y = 0.22, Z = 0.22 })
    p.smoke, p.joint = emitter, false
end

-- Holds every player puppet on one frame of an animation (used while looking for poses).
function Avatar.testPose(path, fraction)
    local anim = path and asset(path) or nil
    for _, set in pairs(Avatar.puppets) do
        local p = set.player
        if anim then
            p.comp:PlayAnimation(anim, false)
            p.comp:SetPlayRate(0)
            p.comp:SetPosition((fraction or 0) * anim:GetPlayLength(), false)
        else
            p.comp:SetAnimationMode(0)
            local class = asset(ANIM_CLASS)
            if class then p.comp:K2_SetAnimInstanceClass(class) end
        end
    end
    return anim ~= nil
end

-- Re-applies Avatar.tune to phones that already exist (used while adjusting).
function Avatar.applyTune()
    local t = Avatar.tune
    for _, set in pairs(Avatar.puppets) do
        local p = set.player
        if p then seatPhone(p, p.pose) end
        if p then seatJoint(p) end
        if p then
            p.standing = false
            pcall(function()
                local g = p.glow.LightComponent
                g:SetIntensity(t.glowIntensity)
                g:SetAttenuationRadius(t.glowRadius)
            end)
        end
    end
end

local function buildTorch(p)
    local world = World.player():GetWorld()
    local light = spawn(world, "/Script/Engine.SpotLight", { x = p.x, y = p.y, z = p.z })
    p.actors[#p.actors + 1] = light
    local comp = light.LightComponent
    comp:SetMobility(2)
    local model = localTorch()
    if model then
        pcall(function() comp:SetIntensity(model.Intensity) end)
        pcall(function() comp:SetAttenuationRadius(model.AttenuationRadius) end)
        pcall(function() comp:SetOuterConeAngle(model.OuterConeAngle) end)
        pcall(function() comp:SetInnerConeAngle(model.InnerConeAngle) end)
        pcall(function() comp:SetLightColor(model:GetLightColor(), true) end)
    else
        pcall(function() comp:SetIntensity(8000) end)
        pcall(function() comp:SetAttenuationRadius(1800) end)
        pcall(function() comp:SetOuterConeAngle(28) end)
    end
    pcall(function() comp:SetCastShadows(false) end)
    light:SetActorHiddenInGame(true)
    p.torch, p.torchComp = light, comp
    pcall(function()
        local glow = spawn(world, "/Script/Engine.PointLight", { x = p.x, y = p.y, z = p.z })
        p.actors[#p.actors + 1] = glow
        local g = glow.LightComponent
        g:SetMobility(2)
        g:SetIntensity(Avatar.tune.glowIntensity)
        g:SetAttenuationRadius(Avatar.tune.glowRadius)
        g:SetCastShadows(false)
        if model then pcall(function() g:SetLightColor(model:GetLightColor(), true) end) end
        glow:SetActorHiddenInGame(true)
        p.glow = glow
    end)
end

-- Shows or hides the phone and the torch, and switches between the normal walk, the
-- looking-at-the-phone animation and the talking-on-the-phone animation.
local function holdThings(p)
    local flags = p.flags or 0
    local wantLight = flags & FLAG_LIGHT ~= 0
    local pose = nil
    local emote = Avatar.EMOTES[p.emote or 0]
    if flags & FLAG_CALL ~= 0 then
        pose = "call"
    elseif emote then
        pose = "emote" .. tostring(p.emote)
    elseif wantLight or flags & FLAG_PHONE ~= 0 then
        pose = "phone"
    end
    if pose ~= p.pose then
        if pose and not p.phone and not p.phoneFailed then
            local ok, e = pcall(buildPhone, p)
            if not ok then
                p.phoneFailed = true
                log("Could not give a puppet its phone: %s", tostring(e))
            end
        end
        local holdsPhone = pose == "call" or pose == "phone"
        if p.phone and valid(p.phone) then p.phone:SetActorHiddenInGame(not holdsPhone) end
        local anim = nil
        if pose == "call" then anim = asset(CALL_ANIM)
        elseif pose == "phone" then anim = asset(PHONE_ANIM)
        elseif emote then anim = asset(emote.anim) end
        if anim then
            p.comp:PlayAnimation(anim, true)
            p.comp:SetPlayRate(1)
            p.phoneAnim = true
            p.standing = false
            pcall(function() p.animLength = anim:GetPlayLength() end)
        elseif p.phoneAnim then
            p.phoneAnim = false
            p.comp:SetAnimationMode(0)
            local class = asset(ANIM_CLASS)
            if class then p.comp:K2_SetAnimInstanceClass(class) end
        end
        p.pose = pose
        if holdsPhone then seatPhone(p, pose) end
    end
    -- Smoke: after a joint, and for as long as the smoke break lasts.
    local wantSmoke = flags & FLAG_SMOKE ~= 0
    -- The game removes every joint in the world when one of its own smokers lights up.
    if p.smoke and not Core.alive(p.smoke) then
        pcall(function() if p.wisp and valid(p.wisp) then p.wisp:K2_DestroyActor() end end)
        p.smoke, p.wisp, p.smoking = nil, nil, false
    end
    if wantSmoke ~= (p.smoking == true) then
        p.smoking = wantSmoke
        if wantSmoke and not p.smoke and not p.smokeFailed then
            local ok, e = pcall(buildSmoke, p)
            if not ok then
                p.smokeFailed = true
                log("Could not show smoke on a puppet: %s", tostring(e))
            end
        end
        if p.smoke and valid(p.smoke) then
            p.smoke:SetActorHiddenInGame(not wantSmoke)
            pcall(function()
                local fx = p.joint and p.smoke.ParticleSystem or p.smoke.ParticleSystemComponent
                if wantSmoke then fx:Activate(true) else fx:Deactivate() end
                if p.wisp and valid(p.wisp) then
                    p.wisp:SetActorHiddenInGame(not wantSmoke)
                    if wantSmoke then p.wisp.ParticleSystemComponent:Activate(true) else p.wisp.ParticleSystemComponent:Deactivate() end
                end
            end)
        end
    end
    if p.phoneAnim and pose == "phone" then
        -- The loop is a walk: run it at the player's pace, hold one frame when standing.
        local speed = Avatar.tune.testSpeed or p.speed or 0
        if speed > 15 then
            p.comp:SetPlayRate(math.max(0.5, math.min(2.2, speed / Avatar.tune.walkSpeed)))
            p.standing = false
        elseif not p.standing then
            p.standing = true
            p.comp:SetPlayRate(0)
            p.comp:SetPosition(Avatar.tune.standFraction * (p.animLength or 1), false)
        end
    end
    if wantLight ~= (p.torchShown == true) then
        if wantLight and not p.torch and not p.torchFailed then
            local ok, e = pcall(buildTorch, p)
            if not ok then
                p.torchFailed = true
                log("Could not give a puppet its torch: %s", tostring(e))
            end
        end
        if p.torch and valid(p.torch) then p.torch:SetActorHiddenInGame(not wantLight) end
        if p.glow and valid(p.glow) then p.glow:SetActorHiddenInGame(not wantLight) end
        p.torchShown = wantLight
    end
    if wantLight and p.torch and valid(p.torch) then
        local t = Avatar.tune
        local yaw = math.rad(p.yaw)
        p.torch:K2_SetActorLocationAndRotation(
            { X = p.x + math.cos(yaw) * t.lightForward, Y = p.y + math.sin(yaw) * t.lightForward, Z = p.z + t.lightUp },
            { Pitch = p.pitch or 0, Yaw = p.yaw, Roll = 0 }, false, {}, true)
        if p.glow and valid(p.glow) then
            p.glow:K2_SetActorLocation({ X = p.x + math.cos(yaw) * t.glowForward, Y = p.y + math.sin(yaw) * t.glowForward, Z = p.z + t.glowUp },
                false, {}, true)
        end
    end
end

local function angleDelta(from, to)
    return ((to - from + 180) % 360) - 180
end

-- Every figure costs a handful of calls into the game per tick, and with four players
-- there are three of them plus their policemen. So: a figure far from our own player is
-- only moved every fourth tick, one that stands where it should is not moved at all, and
-- what it holds and how fast it walks are only set again when they change (and now and
-- then, in case the game has replaced its animation).
local FAR_FIGURE = 4500

local function move(p, dt, camera)
    p.ticks = (p.ticks or 0) + 1
    local cx, cy = camera.X - p.x, camera.Y - p.y
    if cx * cx + cy * cy > FAR_FIGURE * FAR_FIGURE and p.ticks % 4 ~= 0 then
        p.owed = (p.owed or 0) + dt
        return
    end
    dt = dt + (p.owed or 0)
    p.owed = 0
    local k = math.min(1, dt * 12)
    local dx, dy, dz = p.tx - p.x, p.ty - p.y, p.tz - p.z
    local turn = angleDelta(p.yaw, p.tyaw)
    local d2 = dx * dx + dy * dy + dz * dz
    local moving = d2 > 0.25 or math.abs(turn) > 0.3
    if moving then
        if d2 > 600 * 600 then k = 1 end   -- teleport, do not glide
        p.x, p.y, p.z = p.x + dx * k, p.y + dy * k, p.z + dz * k
        p.yaw = p.yaw + turn * k
        p.body:K2_SetActorLocationAndRotation({ X = p.x, Y = p.y, Z = p.z + FEET_OFFSET },
            { Pitch = 0, Yaw = p.yaw + MESH_YAW, Roll = 0 }, false, {}, true)
    end
    local now = p.ticks % 10 == 0
    if not p.phoneAnim and (p.walk ~= p.speed or now) then
        p.walk = p.speed
        pcall(function()
            local anim = p.comp:GetAnimInstance()
            anim.speed = p.speed
            anim.Velocity = p.speed
        end)
    end
    if p.isPlayer then
        local state = (p.flags or 0) * 1000 + (p.emote or 0)
        if state ~= 0 or state ~= p.held or p.pose ~= nil or p.smoke ~= nil or now then
            p.held = state
            local ok, e = pcall(holdThings, p)
            if not ok and not p.holdError then
                p.holdError = true
                log("Showing what a player holds failed: %s", tostring(e))
            end
        end
    end
    if p.label and (moving or p.ticks % 3 == 0) and valid(p.label) then
        local face = math.deg(math.atan(camera.Y - p.y, camera.X - p.x))
        p.label:K2_SetActorLocationAndRotation({ X = p.x, Y = p.y, Z = p.z + FEET_OFFSET + NAME_HEIGHT },
            { Pitch = 0, Yaw = face, Roll = 0 }, false, {}, true)
    end
end

local function parseEntry(text)
    local x, y, z, yaw, speed, rest = text:match("^(-?[%d.]+),(-?[%d.]+),(-?[%d.]+),(-?[%d.]+),(-?[%d.]+)(.*)$")
    if not x then return nil end
    local s = { x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw), speed = tonumber(speed) }
    local flags, pitch, emote = rest:match("^,(%d+),(-?[%d.]+),?(%d*)$")
    if flags then s.flags, s.pitch, s.emote = tonumber(flags), tonumber(pitch), tonumber(emote) or 0 end
    return s
end

-- "x,y,z,yaw,speed,flags,pitch,emote;copId:x,y,z,yaw,speed;..."
-- flags: 1 phone up, 2 torch on, 4 on a call, 8 smoking
local function parse(line)
    local first, rest = line:match("^([^;]*);?(.*)$")
    local player = parseEntry(first or "")
    if not player then return nil end
    local police = {}
    for id, entry in rest:gmatch("(%-?%d+):([^;]+)") do
        local s = parseEntry(entry)
        if s then police[id] = s end
    end
    return player, police
end

local function drop(id)
    local set = Avatar.puppets[id]
    if not set then return end
    destroy(set.player)
    for _, cop in pairs(set.police) do destroy(cop) end
    Avatar.puppets[id] = nil
end

local function clear()
    for id in pairs(Avatar.puppets) do drop(id) end
end

---------------------------------------------------------------- our own state

local pursuers = {}        -- policemen currently alerted near our player
local pursuersDue = 0

-- Looking through every policeman is slow, so the list is refreshed only now and then.
local function refreshPursuers(loc)
    pursuers = {}
    if not Core.enabled("Police") then return end
    local found = {}
    for _, cop in ipairs(Core.actors("/Game/Skeletal/NPC/Policeman/PolicemanBaseClass.PolicemanBaseClass_C") or FindAllOf("PolicemanBaseClass_C") or {}) do
        pcall(function()
            if Core.alive(cop) and (cop.alerted or cop.suspectMode) then
                local c = cop:K2_GetActorLocation()
                local d = (c.X - loc.X) ^ 2 + (c.Y - loc.Y) ^ 2 + (c.Z - loc.Z) ^ 2
                if d <= POLICE_RANGE * POLICE_RANGE then found[#found + 1] = { cop = cop, d = d, id = cop:GetAddress() % 1000000007 } end
            end
        end)
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#found, MAX_POLICE) do pursuers[i] = found[i] end
end

local function describe(actor)
    local loc = actor:K2_GetActorLocation()
    if actor == World.player() then loc.Z = loc.Z + (Avatar.sendZ or 0) end
    local rot = actor:K2_GetActorRotation()
    local vel = actor:GetVelocity()
    return string.format("%.0f,%.0f,%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z, rot.Yaw, math.sqrt(vel.X * vel.X + vel.Y * vel.Y)), loc
end

-- What our own player has in hand, and where the view points up or down.
local function holding(player)
    local flags, pitch = 0, 0
    pcall(function()
        if player.phoneUp == true then flags = flags | FLAG_PHONE end
        if player.phoneRef.callInProgress == true then flags = flags | FLAG_CALL end
        local torch = player.phoneRef.flashlight
        if valid(torch) and torch:IsVisible() and torch.bHiddenInGame ~= true then flags = flags | FLAG_LIGHT end
    end)
    pcall(function()
        pitch = player:GetControlRotation().Pitch
        if pitch > 180 then pitch = pitch - 360 end
    end)
    local emote = Avatar.EMOTES[Avatar.localEmote or 0]
    if os.clock() < (Avatar.smokeUntil or 0) or (emote and emote.smoke) then flags = flags | FLAG_SMOKE end
    return string.format(",%d,%.0f,%d", flags, pitch, Avatar.localEmote or 0)
end

local lastPublish = ""
local repeatAt, repeatAlt = 0, false
local parsed = {}          -- peer -> { text, s, police }: what their last line said
local ownTurn, lastLine, lastLoc = false, nil, nil
local retryAt = 0

Core.onTick(function(dt)
    if not Core.enabled("Avatars") then return end
    if not World.shared() then
        lastLine, lastLoc, parsed = nil, nil, {}
        if next(Avatar.puppets) then clear() end
        if lastPublish ~= "" then
            lastPublish = ""
            Net.setLocalState("-")
        end
        return
    end
    local player = World.player()
    if not player then return end

    -- Publish our own state: every other tick (sixteen times a second), unless policemen
    -- are after us, whose places go out with ours.
    local mark = Core.profile and os.clock()
    ownTurn = not ownTurn
    local line, loc = lastLine, lastLoc
    if ownTurn or not loc or #pursuers > 0 then
        line, loc = describe(player)
        line = line .. holding(player)
        if os.clock() >= pursuersDue then
            pursuersDue = os.clock() + 3
            refreshPursuers(loc)
        end
        for _, p in ipairs(pursuers) do
            pcall(function()
                if Core.alive(p.cop) then line = line .. ";" .. tostring(p.id) .. ":" .. describe(p.cop) end
            end)
        end
        lastLine, lastLoc = line, loc
    end
    -- Sent when it changes, and once a second while it does not (somebody who arrives
    -- while we stand still has to learn where we are). The bridge only sends a line that
    -- differs from the last one, so the repeat is written a little differently: with a
    -- zero in front of the first number, which reads as the same number.
    local now = os.clock()
    if line ~= lastPublish then
        lastPublish, repeatAt, repeatAlt = line, now + 1, false
        Net.setLocalState(line)
    elseif now >= repeatAt then
        repeatAt, repeatAlt = now + 1, not repeatAlt
        Net.setLocalState(repeatAlt and (line:gsub("^(%-?)", "%10", 1)) or line)
    end

    if mark then
        Core.mark("avatar: own state", os.clock() - mark)
        mark = os.clock()
    end

    -- Follow what the others published. A line that has not changed is not taken apart
    -- again, and only one figure is built per tick (building one takes a moment).
    local states = Net.peerStates()
    local building = false
    if states then
        for id, text in pairs(states) do
            local known = parsed[id]
            if not known or known.text ~= text then
                local s0, p0 = parse(text)
                known = { text = text, s = s0, police = p0 }
                parsed[id] = known
            end
            local s, police = known.s, known.police or {}
            local set = Avatar.puppets[id]
            if s and Net.S.members[id] then
                if set and not valid(set.player.body) then
                    drop(id)
                    set = nil
                end
                if not set and os.clock() >= retryAt and not building then
                    building = true
                    local puppet = build(lookOf(id), s, Net.name(id))
                    if puppet then
                        puppet.isPlayer = true
                        set = { player = puppet, police = {} }
                        Avatar.puppets[id] = set
                        log("Avatar spawned for %s", Net.name(id))
                    else
                        retryAt = os.clock() + 5
                    end
                end
                if set then
                    target(set.player, s)
                    for copId, cs in pairs(police) do
                        local cop = set.police[copId]
                        if cop and not valid(cop.body) then cop = nil end
                        if not cop and not building then
                            building = true
                            cop = build(LOOKS.police, cs, nil)
                            set.police[copId] = cop
                        end
                        if cop then target(cop, cs) end
                    end
                    for copId, cop in pairs(set.police) do
                        if not police[copId] then
                            destroy(cop)
                            set.police[copId] = nil
                        end
                    end
                end
            elseif set and not s then
                drop(id)
            end
        end
    end
    if mark then
        Core.mark("avatar: read others", os.clock() - mark)
        mark = os.clock()
    end
    for id, set in pairs(Avatar.puppets) do
        if not Net.S.members[id] or not valid(set.player.body) then
            drop(id)
            parsed[id] = nil
        else
            move(set.player, dt, loc)
            for _, cop in pairs(set.police) do
                if valid(cop.body) then move(cop, dt, loc) end
            end
        end
    end
    if mark then Core.mark("avatar: move figures", os.clock() - mark) end
end)

-- A puppet that is not a player: the wardrobe shows one as a mirror. It stands still.
-- `pose` "idle" leaves it to the citizens' idle animation (it looks around); otherwise it
-- holds one relaxed standing frame.
function Avatar.buildStandIn(look, x, y, z, yaw, name, pose)
    local p = build(partsOf(look), { x = x, y = y, z = z, yaw = yaw }, name)
    if p then
        pcall(function()
            local anim = pose ~= "idle" and asset(STAND_ANIM) or nil
            if anim then
                p.comp:PlayAnimation(anim, false)
                p.comp:SetPlayRate(0)
                p.comp:SetPosition(0, false)
            end
        end)
        p.body:K2_SetActorLocationAndRotation({ X = x, Y = y, Z = z + FEET_OFFSET }, { Pitch = 0, Yaw = yaw + MESH_YAW, Roll = 0 }, false, {}, true)
        if p.label and valid(p.label) then
            p.label:K2_SetActorLocationAndRotation({ X = x, Y = y, Z = z + FEET_OFFSET + NAME_HEIGHT }, { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
        end
    end
    return p
end

-- Plays an animation on a stand-in, looping (nil: back to the idle animation).
function Avatar.poseStandIn(p, path)
    if not p or not valid(p.comp) then return end
    local anim = path and asset(path) or nil
    if anim then
        p.comp:PlayAnimation(anim, true)
        p.comp:SetPlayRate(1)
    else
        p.comp:SetAnimationMode(0)
        local class = asset(ANIM_CLASS)
        if class then p.comp:K2_SetAnimInstanceClass(class) end
    end
end

function Avatar.moveStandIn(p, x, y, z, yaw)
    if not p or not valid(p.body) then return end
    p.body:K2_SetActorLocationAndRotation({ X = x, Y = y, Z = z + FEET_OFFSET }, { Pitch = 0, Yaw = yaw + MESH_YAW, Roll = 0 }, false, {}, true)
end

function Avatar.destroyStandIn(p) destroy(p) end

-- Changes how another player looks; their character is rebuilt on the next tick.
function Avatar.setLook(id, look)
    Avatar.looks[id] = look
    drop(id)
end

-- Last reported position of another player, or nil while unknown.
function Avatar.peerPosition(id)
    local set = id and Avatar.puppets[id]
    if not set then return nil end
    return set.player.tx, set.player.ty, set.player.tz
end

World.listen("stop", clear)
Net.listen("gone", function(id) drop(id) end)

return Avatar
