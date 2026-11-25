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
local FLAG_STRUT = 128      -- (16..64 are the bag)
-- The player crouches: the game halves the capsule (its middle is 45 above the feet
-- instead of 90), so the figure stands that much higher than a standing one, in its
-- crouching pose. (Builds before v0.19 do not send it: their figures sink in.)
local FLAG_CROUCH = 256
Avatar.FLAG_CROUCH = FLAG_CROUCH
local CROUCH_FEET = -45
local CROUCH_POSE = "/Game/Animations/Sebiks_MOB1_Crouch_Idle_V2_IPC.Sebiks_MOB1_Crouch_Idle_V2_IPC"
-- Where a figure's feet are below the place sent for it (the capsule's middle).
local function feetOffset(p)
    if not p.own and (p.flags or 0) & FLAG_CROUCH ~= 0 then return CROUCH_FEET end
    return FEET_OFFSET
end
Avatar.feetOffset = feetOffset
-- The strut: a walk of the game's citizens (listening to music), played instead of the
-- normal walk while the player has it switched on (coop/emote.lua: Caps Lock or the wheel).
local STRUT_ANIM = "/Game/Animations/CitizenMale_Walk_08_Listen_Music_Loop_IP.CitizenMale_Walk_08_Listen_Music_Loop_IP"
-- The backpack a player wears travels in the next three bits of the flags: a number of
-- BAGS, 0 for none (and for a bag not in the list). Versions that do not know it look at
-- their own bits only. The models are the game's own worn backpacks, the ones its
-- inventory screen hangs on the figure there.
local BAG_SHIFT, BAG_MASK = 4, 7
local BAG_DIR = "/Game/GUI/Inventory/InventoryCharacter/"
-- Each may have its own `scale`, `loc`, `locFemale`, `rot` and `rotFemale` (otherwise
-- Avatar.tune's). The duffle bag is the game's own mesh (the worn model the game has for it
-- is small and hangs off the back). Men carry it level at the hips, handles up and turned
-- a little outward; women across the back at 45 degrees, the way a slung rifle hangs, its
-- dark underside outward.
-- The suitcase has no worn model in the game: its own mesh, carried in the right hand
-- (`hand`: put away while that hand is busy with the phone or an emote).
local BAGS = {
    { item = "ITEM-SMALL-BACKPACK", class = "backpackRepr_Small", scale = 1.3 },
    { item = "ITEM-MEDIUM-BACKPACK", class = "backpackRepr_Medium", scale = 1.25 },
    { item = "ITEM-LARGE-BACKPACK", class = "backpackRepr_Large", scale = 1.25 },
    { item = "ITEM-DUFFLEBAG", mesh = "/Game/Interactive/Backpacks/duffleBag.duffleBag", scale = 0.76,
        rot = { Pitch = 79.26, Yaw = 6.76, Roll = 158.77 }, loc = { X = -48.54, Y = -28.62, Z = 0.95 },
        rotFemale = { Pitch = 44.27, Yaw = 3.83, Roll = 90.98 }, locFemale = { X = -10.36, Y = -31.84, Z = 0.53 } },
    -- The briefcase hangs upright from the fingers whatever the wrist does (the women's
    -- standing animation turns the wrist: a case fixed to the hand lay across her forearm).
    -- Its rotation is the world's, its handle is kept at the middle finger's knuckle (see
    -- hangBag); the model's origin is the middle of its bottom, `drop` below the grip.
    { item = "ITEM-SUITCASE", mesh = "/Game/Interactive/Backpacks/Suitcase2.Suitcase2", hand = true, bone = "middle_01_r", scale = 0.8,
        hang = { drop = 33, out = 2, down = 2 } },
}
Avatar.BAGS = BAGS
local BAG_OF = {}
for i, b in ipairs(BAGS) do BAG_OF[b.item] = i end

-- Emotes, by number (the number is what travels). All are the game's own citizen
-- animations; a few are single poses. The seated ones were made for somebody behind a desk:
-- `yaw` turns the figure so that it faces where the player faces, `back` and `side` put its
-- hips about 70 units behind where the player stands: backed against the hideout couch the
-- player stops 32 in front of the cushion edge, and the hips land 38 into the seat.
Avatar.EMOTES = {
    { name = "Talk", anim = "/Game/CityAnimations/Retargeted/Talking_3.Talking_3" },
    { name = "Hands up", anim = "/Game/Animations/PozyEndgame/Retarget/NPC_PoseExport_Anim_root_DeadDealer02.NPC_PoseExport_Anim_root_DeadDealer02" },
    { name = "Sit", anim = "/Game/Animations/NoweMocap/NaCitizen/Dopracowane/shopkeeper_02_desk_hands.shopkeeper_02_desk_hands", back = 90, side = -5, yaw = 6 },
    { name = "Lounge", anim = "/Game/Animations/NoweMocap/NaCitizen/Dopracowane/shopkeeper_04_jay.shopkeeper_04_jay", back = 81, side = 34, yaw = -77 },
    -- (its hips are on the standing spot and 8 lower than Sit's: moved back 70, raised 8)
    { name = "Smoke break", anim = "/Game/Animations/NoweMocap/NaCitizen/Sitting_waiting.Sitting_waiting", smoke = true, back = 70, side = 0, yaw = 2, up = 8 },
    { name = "Crouch", anim = "/Game/Animations/Sebiks_MOB1_Crouch_Idle_V2_IPC.Sebiks_MOB1_Crouch_Idle_V2_IPC" },
    { name = "Play dead", anim = "/Game/Animations/PozyEndgame/Retarget/NPC_PoseExport_Anim_root_DeadDealer01.NPC_PoseExport_Anim_root_DeadDealer01" },
    -- (not an emote: switches the strut walk on and off; kept last so the numbers above stay)
    { name = "Strut", strut = true },
}
-- Poses that are not on the wheel, by numbers the wheel never reaches. The card table's
-- seat: the figure sits exactly where the player is (the table's seats were measured for
-- this animation without any shift; the wheel's Sit moves the figure back onto a seat).
Avatar.TABLE_SEAT = 50
local POSES = {
    [50] = { name = "Table seat", calm = true, anim = "/Game/Animations/NoweMocap/NaCitizen/Dopracowane/shopkeeper_02_desk_laptop.shopkeeper_02_desk_laptop" },
}
local function emoteOf(id) return Avatar.EMOTES[id] or POSES[id] end

-- Sitting at a table. The game's animation for it is a shopkeeper typing at a desk without
-- a pause, which is too busy for somebody who sits at a card table or a slot machine. So
-- the figure mostly sits: the animation creeps forth and back over a short stretch of
-- itself, slowly enough to pass for breathing. Now and then it runs at its own speed for a
-- few seconds (the hands move), and where it stops is the next stretch to sit in.
local sitters = {}       -- figure -> { from, dir, typeAt, typingTill }
local SIT_STRETCH, SIT_RATE = 0.45, 0.1         -- seconds of the animation, and how fast it creeps
local SIT_EVERY, SIT_FOR = { 20, 45 }, { 2.5, 4.5 }       -- seconds between two spells of moving hands; how long one lasts

local function sitCalm(p)
    if not p or not valid(p.comp) then return end
    local from = 0
    pcall(function() from = p.comp:GetPosition() end)
    sitters[p] = { from = from, dir = 1, typeAt = os.clock() + math.random(SIT_EVERY[1], SIT_EVERY[2]) }
    pcall(function() p.comp:SetPlayRate(SIT_RATE) end)
end

-- The hands move for `seconds` now (a dealer at the end of a round).
local function sitBusy(p, seconds)
    local s = sitters[p]
    if not s or not valid(p.comp) then return end
    s.typingTill = os.clock() + (seconds or 3)
    pcall(function() p.comp:SetPlayRate(1) end)
end
Avatar.sitCalm, Avatar.sitBusy = sitCalm, sitBusy

Core.onTick(function()
    local now = os.clock()
    for p, s in pairs(sitters) do
        if not valid(p.comp) or not valid(p.body) then
            sitters[p] = nil
        else
            pcall(function()
                local c = p.comp
                if s.typingTill then
                    if now >= s.typingTill then
                        s.typingTill = nil
                        s.from, s.dir = c:GetPosition(), 1
                        s.typeAt = now + math.random(SIT_EVERY[1], SIT_EVERY[2])
                        c:SetPlayRate(SIT_RATE)
                    end
                    return
                end
                local at = c:GetPosition()
                if at < s.from - 1 then s.from = at end         -- (the animation came round)
                if s.dir == 1 and at >= s.from + SIT_STRETCH then
                    s.dir = -1
                    c:SetPlayRate(-SIT_RATE)
                elseif s.dir == -1 and at <= s.from then
                    s.dir = 1
                    c:SetPlayRate(SIT_RATE)
                end
                if now >= s.typeAt then
                    s.typingTill = now + SIT_FOR[1] + math.random() * (SIT_FOR[2] - SIT_FOR[1])
                    c:SetPlayRate(1)
                end
            end)
        end
    end
end)
Avatar.localEmote = 0      -- the emote our own player is doing (0 = none)
Avatar.STAND_ANIM = STAND_ANIM
Avatar.smokeUntil = 0      -- our own player is smoking until this time
Avatar.strut = false       -- our own player walks with the strut

function Avatar.setEmote(id)
    local e = emoteOf(id)
    Avatar.localEmote = (e and not e.strut) and id or 0
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
    strutSpeed = 175,          -- the same for the strut loop (its feet measured against the texting loop's)
    strutMaxSpeed = 250,       -- the player's top speed while strutting (the game's walk is about 900; 190 was too slow)
    femaleJogFrom = 260,       -- a woman faster than this jogs (her blueprint has a walk only)
    femaleJogSpeed = 380,      -- units per second the women's jog was made for
    maleRunFrom = 330,         -- a man faster than this runs (his blueprint has a walk only)
    maleRunSpeed = 600,        -- units per second the run is played at its own pace
    lightForward = 40, lightUp = 45,
    -- A spot light only shows where it lands. This small light at the phone falls on the
    -- holder's own hands and chest, so a torch that is on can be seen from any side.
    -- It sits a little in front of the hands: any closer and the palm burns out white.
    glowForward = 62, glowUp = 40, glowIntensity = 900, glowRadius = 200,
    -- The joint, relative to the bone it hangs from.
    jointBone = "head", jointLoc = { X = 0.2, Y = 9.5, Z = 0 }, jointRot = { Pitch = 0, Yaw = 0, Roll = 90 }, jointThin = 0.65, jointLong = 1.35,
    -- The wisp of smoke that rises from its tip.
    wispFx = WISP_FX, wispScale = 0.07, wispAt = 7.3,
    -- The backpack: where the game's inventory figure has its "backpackSocket" (same bone,
    -- same place on the citizens' skeletons). The women's back is nearer to the bone.
    bagBone = "spine_03", bagLoc = { X = 0, Y = -18.04, Z = 0 }, bagLocFemale = { X = 0, Y = -12, Z = 0 },
    bagRot = { Pitch = 0, Yaw = -80, Roll = 90 }, bagScale = 1.0,
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
    -- women's: every face has one (the outfits come with mismatched skins, one of them
    -- partly see-through)
    SK_fe_head_01 = "MI_fe_skin_body_caucasian_01",
    SK_fe_head_01_dark = "MI_fe_skin_deep",
    SK_fe_head_02_asian = "MI_fe_skin_body_caucasian_yellow",
    SK_fe_head_02_b = "MI_fe_skin_body_caucasian_01",
    SK_fe_head_03 = "MI_fe_skin_body_caucasian_brown",
    SK_fe_head_05 = "MI_fe_skin_deep",
}

-- Women. The female meshes have a skeleton of their own with hardly any animations; every
-- animation the mod plays is the men's. A female figure is driven by SK_fe_casual_02_d, a
-- female outfit the game made on the male skeleton: it runs the men's animation blueprint
-- and every other part (outfit, head, hair, hands, arms) follows its pose, keeping female
-- proportions. With another outfit it is hidden but keeps animating.
local FEMALE_DRIVER = "SK_fe_casual_02_d"
-- ...but only for the men's animations a woman has no own of (emotes, the phone, a call).
-- Otherwise a female figure is driven by the female base body (the women's skeleton) and
-- the women's animation blueprint (standing, walking), the women's jog when running, and a
-- frame of the women's standing fidget when it stands still: the men's skeleton gives the
-- women a man's stance. Both skeletons have the same bone names, so every part follows
-- either driver.
local FEMALE_BASE = "Basebody/SK_fe_body_average"
local FEMALE_ANIM_BP = "/Game/Animations/CitizenFemale01_AnimBP"
local FEMALE_STAND = "/Game/Animations/CitizenFemale_MOB1_Stand_Relaxed_Fgt_v1_IPC.CitizenFemale_MOB1_Stand_Relaxed_Fgt_v1_IPC"
local FEMALE_JOG = "/Game/Animations/CitizenFemale_MOB1_Jog_F_IPC.CitizenFemale_MOB1_Jog_F_IPC"
-- outfits with rolled sleeves: the forearms are a part of their own
local FEMALE_ARMS = { SK_fe_casual_02_b = true, SK_fe_casual_02_c = true, SK_fe_casual_02_d = true, SK_fe_clerk_01 = true, SK_fe_sport_02_a = true }
local function isFemale(meshName) return tostring(meshName):sub(1, 6) == "SK_fe_" end
-- outfits that are a whole person, face and hands and all (the jogging set): the chosen
-- face and the hands are left off (the face would stick through at the hairline, the ears
-- and the neck) and the outfit's own skin takes the chosen face's tone (OUTFIT_SKIN)
local OWN_FACE = { SK_fe_sport_01 = true }

-- Outfits whose bare skin is painted into the outfit itself (the jogging set's belly, arms
-- and legs): the skin channel of its material ("A: Details 3 / Skin") takes the face's
-- tone. Faces not listed keep the outfit's own (light) skin.
-- (measured: the outfit's face brought to the colour of the same face in a default outfit,
-- side by side in screenshots)
local OUTFIT_SKIN = {
    SK_fe_head_05 = { R = 0.532, G = 0.253, B = 0.138, A = 1 },
    SK_fe_head_01_dark = { R = 0.93, G = 0.464, B = 0.229, A = 1 },
    SK_fe_head_03 = { R = 1.499, G = 0.768, B = 0.49, A = 1 },
    SK_fe_head_02_asian = { R = 1.102, G = 0.64, B = 0.432, A = 1 },
    SK_fe_head_01 = { R = 1.239, G = 0.721, B = 0.489, A = 1 },
    SK_fe_head_02_b = { R = 1.239, G = 0.721, B = 0.489, A = 1 },
}
local PAINTED_SKIN = { MI_fe_sport_01 = true }

-- The women's animation blueprint is looked up by its path every time (within one Avatar.batch: once). The engine
-- throws it away when no figure uses it any more (between two worlds), and a pointer kept from the world before
-- still answers IsValid: giving that to a figure crashed the game on the next world's first woman (v0.16.0).
local FEMALE_ANIM_CLASS = FEMALE_ANIM_BP .. "." .. FEMALE_ANIM_BP:match("[^/]+$") .. "_C"
local function animClass(female)
    if not female then return asset(ANIM_CLASS) end
    if memo then
        local hit = memo[FEMALE_ANIM_CLASS]
        if hit ~= nil then return hit or nil end
    end
    local class = StaticFindObject(FEMALE_ANIM_CLASS)
    if not valid(class) then
        pcall(function() LoadAsset(FEMALE_ANIM_BP) end)
        class = StaticFindObject(FEMALE_ANIM_CLASS)
    end
    if not valid(class) then class = nil end
    if memo then memo[FEMALE_ANIM_CLASS] = class or false end
    return class
end

-- A female figure's driver on the men's skeleton (`male`) or the women's. The driver is
-- hidden; the parts are told to follow it again.
local function setSkeleton(p, male)
    if not p or not p.female then return end
    local want = male and "m" or "f"
    if p.skel == want then return end
    local m = mesh(male and FEMALE_DRIVER or FEMALE_BASE)
    if not m then return end
    p.comp:SetSkeletalMesh(m, true)
    p.comp:SetVisibility(false, false)
    p.skel = want
    for _, part in ipairs(p.followers or {}) do
        pcall(function() part:SetMasterPoseComponent(p.comp, true) end)
    end
end
Avatar.setSkeleton = setSkeleton

-- Back to the figure's own animation blueprint (a woman's: on the women's skeleton).
local function toBlueprint(p)
    setSkeleton(p, false)
    p.comp:SetAnimationMode(0)
    local class = animClass(p.female and p.skel == "f")
    if class then p.comp:K2_SetAnimInstanceClass(class) end
end

-- Men running. The citizens have a walk and nothing faster; the policemen have a run, and
-- their skeleton has the citizens' bones by the same names. So a hidden policeman's body
-- hangs on the figure and plays the run, and the figure's body and parts take their pose
-- from it for as long as the man runs.
local RUN_MESH = "/Game/Skeletal/NPC/Policeman/patrolPolice_NPC.patrolPolice_NPC"
local RUN_ANIM = "/Game/Policeman_RunTemp.Policeman_RunTemp"
local function setRun(p, on)
    if on then
        if p.runFailed then return end
        local ok, e = pcall(function()
            if not (p.runner and valid(p.runner)) then
                local m = asset(RUN_MESH)
                if not m then error("the policeman's body is not available") end
                local l = p.body:K2_GetActorLocation()
                local a = p.body:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.SkeletalMeshActor"), { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
                p.actors[#p.actors + 1] = a
                a:SetActorEnableCollision(false)
                local c = a.SkeletalMeshComponent
                c:SetSkeletalMesh(m, true)
                c:SetVisibility(false, false)
                pcall(function() c.VisibilityBasedAnimTickOption = 0 end)       -- always tick pose and bones
                a:K2_AttachToActor(p.body, FName("None"), 2, 2, 2, false)
                p.runner, p.runComp = a, c
            end
            local anim = asset(RUN_ANIM)
            if not anim then error("the run is not available") end
            p.runComp:PlayAnimation(anim, true)
            p.comp:SetMasterPoseComponent(p.runComp, true)
            for _, part in ipairs(p.followers or {}) do part:SetMasterPoseComponent(p.runComp, true) end
        end)
        if not ok then
            p.runFailed = true
            log("A figure cannot run: %s", tostring(e))
            return
        end
        p.running = true
    elseif p.running then
        p.running = false
        local ok, e = pcall(function()
            p.comp:SetMasterPoseComponent(nil, true)
            for _, part in ipairs(p.followers or {}) do part:SetMasterPoseComponent(p.comp, true) end
            if valid(p.runComp) then p.runComp:Stop() end
        end)
        if not ok then
            p.runFailed = true
            log("A figure cannot stop running: %s", tostring(e))
        end
    end
end

local function applySkin(p, head)
    local tone = OUTFIT_SKIN[head or ""]
    if tone then
        for _, actor in ipairs(p.actors) do
            pcall(function()
                local c = actor.SkeletalMeshComponent
                for i = 0, c:GetNumMaterials() - 1 do
                    local m = c:GetMaterial(i)
                    local n = valid(m) and m:GetFName():ToString() or ""
                    if PAINTED_SKIN[n] then
                        local d = c:CreateDynamicMaterialInstance(i, m, FName("None"))
                        if valid(d) then d:SetVectorParameterValue(FName("A: Details 3 / Skin"), tone) end
                    end
                end
            end)
        end
    end
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
                if n:find("skin_body", 1, true) or n:find("_body_01", 1, true) or n:find("fe_skin", 1, true) then c:SetMaterial(i, skin) end
            end
        end)
    end
end

-- A colour of an outfit: the body name "MESH#MATERIAL" puts the game's material MATERIAL
-- (one of CitizenNPC/CharacterParts/Materials) on every slot of the mesh that is not skin.
local CLOTH = "/Game/CitizenNPC/CharacterParts/Materials/"
local function splitBody(body)
    local meshName, colour = tostring(body):match("^([^#]+)#?(.*)$")
    return meshName, colour ~= "" and colour or nil
end
Avatar.splitBody = splitBody

-- A hair colour ("Hats_Hair/SK_ma_hair_01#MI_hair_02_blond", the same for a beard): one of
-- the game's hair materials (CitizenNPC/CharacterParts/Materials/Eye_hair), which all use
-- the same pictures, so that every one of them fits every hairstyle and both beards. It
-- goes on the part's hair (or beard) slots only: a hairstyle with glasses keeps its glasses.
local HAIR_MATERIALS = {}
for _, n in ipairs({ "MI_hair", "MI_hairJay", "MI_hair_01_dark", "MI_hair_02_blond", "MI_hair_02_brown", "MI_hair_02_dark", "MI_ma_hair_03_amy",
    "MI_ma_hair_03_asian", "MI_ma_hair_03_dark1", "MI_ma_hair_05_short", "MI_ma_hair_06_gel", "MI_fe_hair_01_dark", "MI_fe_hair_02_dark",
    "MI_fe_hair_02_diana", "MI_fe_hair_02_grey", "MI_fe_hair_04", "hairSicarioWife", "MI_beard_rough", "MI_beard_psych" }) do
    HAIR_MATERIALS[n] = true
end
Avatar.HAIR_MATERIALS = HAIR_MATERIALS

-- Colours the game has no material for: a game material (`from`) with other tint values
-- (M_Base_GlobalTint's channels, linear colour), made per slot as a dynamic instance.
local TINTS = {
    -- the yellow sports sunglasses (MI_glass_dark2) in purple; its A channel is red and
    -- shows through, so both are set
    MI_glass_purple = { from = "MI_glass_dark2", vectors = {
        ["R: Primary"] = { R = 0.05, G = 0.0, B = 0.25, A = 1 }, ["A: Details 3 / Skin"] = { R = 0.05, G = 0.0, B = 0.25, A = 1 } } },
}
Avatar.TINTS = TINTS

local function applyColour(comp, colour)
    if not colour then return end
    local hair = HAIR_MATERIALS[colour] == true
    -- (a glasses frame's colour, "SK_ma_glass_03#MI_glass_dark2": on the frame's slots only,
    -- the lenses keep their glass)
    local frame = colour:sub(1, 8) == "MI_glass"
    local tint = TINTS[colour]
    local base = tint and tint.from or colour
    local m = asset(CLOTH .. (hair and "Eye_hair/" or "") .. base .. "." .. base)
    if not m then
        log("Outfit colour %s is not available", colour)
        return
    end
    local function put(i)
        if not tint then return comp:SetMaterial(i, m) end
        local d = comp:CreateDynamicMaterialInstance(i, m, FName("None"))
        if not valid(d) then return end
        for name, v in pairs(tint.vectors or {}) do d:SetVectorParameterValue(FName(name), v) end
    end
    for i = 0, comp:GetNumMaterials() - 1 do
        local cur = comp:GetMaterial(i)
        local n = valid(cur) and cur:GetFName():ToString() or ""
        if hair then
            local low = n:lower()
            if low:find("hair", 1, true) or low:find("beard", 1, true) then put(i) end
        elseif frame then
            if n:sub(1, 8) == "MI_glass" then put(i) end
        elseif not n:find("skin", 1, true) and not n:find("_body_", 1, true) and not n:find("vest", 1, true) and not n:find("apron", 1, true)
            and not n:find("hair", 1, true) and not n:find("eye", 1, true) then put(i) end
    end
end

-- Builds one puppet. `name` adds a floating label (players only).
local function setWatch(p, code) return Avatar.setWatch(p, code) end
local function build(look, pos, name)
    local player = World.player()
    if not player then return nil end
    local world = player:GetWorld()
    local p = { actors = {}, x = pos.x, y = pos.y, z = pos.z, yaw = pos.yaw, tx = pos.x, ty = pos.y, tz = pos.z, tyaw = pos.yaw, speed = 0 }
    local ok, e = xpcall(function()
        local meshName, colour = splitBody(look.body)
        local female = isFemale(meshName)
        p.female, p.skel, p.followers = female, female and "f" or nil, {}
        p.bodyMesh = meshName
        local bodyMesh = mesh(female and FEMALE_BASE or meshName)
        if not bodyMesh then error("body mesh not available") end
        local body = spawn(world, "/Script/Engine.SkeletalMeshActor", pos)
        p.actors[1] = body
        body:SetActorEnableCollision(false)
        local comp = body.SkeletalMeshComponent
        comp:SetSkeletalMesh(bodyMesh, true)
        local anim = animClass(female)
        if anim then comp:K2_SetAnimInstanceClass(anim) end
        p.body, p.comp = body, comp
        if female then
            comp:SetVisibility(false, false)
            pcall(function() comp.VisibilityBasedAnimTickOption = 0 end)     -- always tick pose and bones
            local outfit = mesh(meshName)
            if not outfit then error("outfit mesh not available") end
            local part = spawn(world, "/Script/Engine.SkeletalMeshActor", pos)
            p.actors[#p.actors + 1] = part
            part:SetActorEnableCollision(false)
            part.SkeletalMeshComponent:SetSkeletalMesh(outfit, true)
            part.SkeletalMeshComponent:SetMasterPoseComponent(comp, false)
            part:K2_AttachToActor(body, FName("None"), 2, 2, 2, false)
            p.followers[#p.followers + 1] = part.SkeletalMeshComponent
            pcall(applyColour, part.SkeletalMeshComponent, colour)
        else
            pcall(applyColour, comp, colour)
        end
        for _, partName in ipairs(look.parts) do
            -- a part may come in another colour too ("Hats_Hair/SK_ma_hat_cap_01#MI_hat_cap_01_darkblue")
            -- ("MESH!word": of that mesh only the pieces whose material has the word in its
            -- name are shown, e.g. an outfit's apron over another outfit)
            local only = nil
            partName, only = tostring(partName):match("^([^!]+)!?(.*)$")
            local partMesh, partColour = splitBody(partName)
            local m = mesh(partMesh)
            if not m then log("Puppet part %s is not available", partName) end
            if m then
                local part = spawn(world, "/Script/Engine.SkeletalMeshActor", pos)
                p.actors[#p.actors + 1] = part
                part:SetActorEnableCollision(false)
                part.SkeletalMeshComponent:SetSkeletalMesh(m, true)
                part.SkeletalMeshComponent:SetMasterPoseComponent(comp, false)
                part:K2_AttachToActor(body, FName("None"), 2, 2, 2, false)
                p.followers[#p.followers + 1] = part.SkeletalMeshComponent
                if partColour then pcall(applyColour, part.SkeletalMeshComponent, partColour) end
                if only and only ~= "" then
                    local c = part.SkeletalMeshComponent
                    for i = 0, c:GetNumMaterials() - 1 do
                        local cur = c:GetMaterial(i)
                        local n = valid(cur) and cur:GetFName():ToString():lower() or ""
                        if not n:find(only, 1, true) then
                            for lod = 0, 3 do pcall(function() c:ShowMaterialSection(i, false, lod) end) end
                        end
                    end
                end
            end
        end
        applySkin(p, look.face or look.parts[1])
        if look.watch then setWatch(p, look.watch) end
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

-- A hat that hides the hair under it (set by coop/look.lua).
Avatar.hidesHair = function() return false end

-- How each other player looks: peer id -> { body, head, hair, arms }. Unknown players wear
-- the default.
Avatar.looks = {}

-- Watches are EXPERIMENTAL ("Watches", coop/experimental.lua): a figure wears one only in
-- the game of a player who has switched them on. (What a look says is kept as it came.)
local function watchWorn(l)
    if not Core.experimental("Watches") then return nil end
    return l.watch
end

-- Turns { body, head, hair, arms } into the body mesh and part list a puppet is built from.
local function partsOf(l)
    if type(l) ~= "table" or type(l.body) ~= "string" then return LOOKS.player end
    local meshName = splitBody(l.body)
    if isFemale(meshName) then
        local face = l.head or "SK_fe_head_01"
        local parts = { face, "Basebody/SK_fe_hands_average" }
        if OWN_FACE[meshName] then parts = {} end           -- (its own hands too)
        if FEMALE_ARMS[meshName] then parts[#parts + 1] = "Basebody/SK_fe_arm_average" end
        if l.hair and l.hair ~= "" and not Avatar.hidesHair(l.hat) then parts[#parts + 1] = l.hair end
        if type(l.hat) == "string" and l.hat ~= "" then parts[#parts + 1] = l.hat end
        if type(l.glasses) == "string" and l.glasses ~= "" then parts[#parts + 1] = l.glasses end
        -- (a piece of another outfit worn over this one: "MESH!word", see build)
        if type(l.over) == "string" and l.over ~= "" then parts[#parts + 1] = l.over end
        return { body = l.body, parts = parts, face = face, watch = watchWorn(l) }
    end
    local parts = { l.head or "SK_ma_head_01", "Basebody/SK_ma_hands_average" }
    if l.arms then parts[#parts + 1] = "Basebody/SK_ma_arm" end
    if l.hair and l.hair ~= "" and not Avatar.hidesHair(l.hat) then parts[#parts + 1] = l.hair end
    if type(l.hat) == "string" and l.hat ~= "" then parts[#parts + 1] = l.hat end
    if type(l.glasses) == "string" and l.glasses ~= "" then parts[#parts + 1] = l.glasses end
    if type(l.beard) == "string" and l.beard ~= "" then parts[#parts + 1] = l.beard end
    return { body = l.body, parts = parts, watch = watchWorn(l) }
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
    -- (not thinner: from where the emote view stands a real joint's width is under a pixel)
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
            setSkeleton(p, true)
            p.comp:PlayAnimation(anim, false)
            p.comp:SetPlayRate(0)
            p.comp:SetPosition((fraction or 0) * anim:GetPlayLength(), false)
        else
            toBlueprint(p)
        end
    end
    return anim ~= nil
end

-- The backpack on a figure's back.
-- A bag that hangs (BAGS `hang`): upright, turned with the body, its grip at the bone.
-- The bone turns with the wrist, so the offset to the bag's origin is worked out again in
-- the bone's own axes every tick (from the bone's rotation of the frame before).
local function hangBag(p)
    local b = BAGS[p.bagCode]
    local h = b and b.hang
    if not h or not p.bag or p.bagAway then return end
    local r = p.comp:GetSocketRotation(FName(b.bone))
    local yaw = p.yaw or 0
    local ry = math.rad(yaw)
    -- (world offset: `out` to the figure's right, `drop` + `down` straight down)
    local vx, vy, vz = -math.sin(ry) * h.out, math.cos(ry) * h.out, -(h.drop + h.down)
    local cp, sp = math.cos(math.rad(r.Pitch)), math.sin(math.rad(r.Pitch))
    local cy, sy = math.cos(math.rad(r.Yaw)), math.sin(math.rad(r.Yaw))
    local cr, sr = math.cos(math.rad(r.Roll)), math.sin(math.rad(r.Roll))
    local X = { cp * cy, cp * sy, sp }
    local Y = { sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp }
    local Z = { -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp }
    local function dot(a) return a[1] * vx + a[2] * vy + a[3] * vz end
    p.bag:K2_SetActorRelativeLocation({ X = dot(X), Y = dot(Y), Z = dot(Z) }, false, {}, true)
    if not p.bagYaw or math.abs(((yaw - p.bagYaw + 180) % 360) - 180) > 0.3 then
        p.bagYaw = yaw
        p.bag:K2_SetActorRelativeRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
    end
end

local function seatBag(p)
    if not p.bag or not valid(p.bag) then return end
    local t, b = Avatar.tune, BAGS[p.bagCode] or {}
    local scale = b.scale or t.bagScale
    p.bag:K2_AttachToComponent(p.comp, FName(b.bone or t.bagBone), 2, 2, 2, false)
    if b.hang then
        p.bag.RootComponent:SetAbsolute(false, true, false)
        p.bagYaw = nil
        p.bag:SetActorRelativeScale3D({ X = scale, Y = scale, Z = scale })
        hangBag(p)
        return
    end
    p.bag:K2_SetActorRelativeLocation(p.female and (b.locFemale or t.bagLocFemale) or (b.loc or t.bagLoc), false, {}, true)
    p.bag:K2_SetActorRelativeRotation(p.female and b.rotFemale or b.rot or t.bagRot, false, {}, true)
    p.bag:SetActorRelativeScale3D({ X = scale, Y = scale, Z = scale })
end

-- Gives a figure the backpack number `code` of BAGS (0 or unknown: none).
local function wearBag(p, code)
    code = BAGS[code] and code or 0
    if (p.bagCode or 0) == code then return end
    p.bagCode = code
    if p.bag then
        local old = p.bag
        p.bag = nil
        for i = #p.actors, 1, -1 do
            if p.actors[i] == old then table.remove(p.actors, i) end
        end
        pcall(function() if valid(old) then old:K2_DestroyActor() end end)
    end
    if code == 0 then return end
    local b = BAGS[code]
    local world, at = p.body:GetWorld(), { X = p.x, Y = p.y, Z = p.z }
    local bag
    if b.mesh then
        local m = asset(b.mesh)
        if not m then error("model " .. b.mesh .. " is not available") end
        bag = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), at, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(bag) then error("model " .. b.mesh .. " could not be made") end
        bag:SetMobility(2)
        bag.StaticMeshComponent:SetStaticMesh(m)
    else
        local classPath = BAG_DIR .. b.class .. "." .. b.class .. "_C"
        local class = StaticFindObject(classPath)
        if not valid(class) then
            pcall(function() LoadAsset(BAG_DIR .. b.class) end)
            class = StaticFindObject(classPath)
        end
        if not valid(class) then error("backpack model " .. b.class .. " is not available") end
        bag = world:SpawnActor(class, at, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(bag) then error("backpack model " .. b.class .. " could not be made") end
    end
    bag:SetActorEnableCollision(false)
    p.actors[#p.actors + 1] = bag
    p.bag, p.bagAway = bag, false
    seatBag(p)
end

-- A watch on the left wrist: the game's two watch models (made for its women, never worn
-- by anybody in the game). Neither model has a place on the skeleton to go to, so where
-- the band's ring lies was measured from the model's points and laid round the wrist
-- (tools/rig/watch_5.lua); what is below is the result, relative to the forearm's twist
-- bone, for each body. A man's wrist is thicker: the same watch, larger.
local WATCH_DIR = "/Game/CitizenNPC/CharacterParts/Meshes/Staticmeshes/"
local WATCH_BONE = "lowerarm_twist_01_l"
local WATCHES = {
    analog = { mesh = "SM_fe_watch_analog_01",
        f = { loc = { X = 22.184, Y = 0.920, Z = -4.788 }, rot = { Pitch = 40.73, Yaw = -89.63, Roll = 47.01 }, scale = 1.108 },
        m = { loc = { X = 25.799, Y = 2.582, Z = -3.207 }, rot = { Pitch = 36.49, Yaw = -92.51, Roll = 44.71 }, scale = 1.55 } },
    digital = { mesh = "SM_fe_watch_digital_01",
        f = { loc = { X = 22.886, Y = 0.466, Z = -2.746 }, rot = { Pitch = -5.21, Yaw = -100.06, Roll = 50.96 }, scale = 1.108 },
        m = { loc = { X = 26.670, Y = 1.285, Z = -0.845 }, rot = { Pitch = 5.03, Yaw = -101.23, Roll = 46.95 }, scale = 1.55 } },
}
Avatar.WATCHES = WATCHES
-- Outfits with a sleeve down to the hand: the watch is worn this much lower, below the
-- cuff (at the wrist it would stick out through the cloth).
local WATCH_LOWER = {
    SK_ma_casual_jacket_01_a = 4, SK_ma_casual_jacket_01_b = 4, SK_ma_casual_02_b = 4, SK_ma_casual_02_c = 4, SK_ma_sport_01_a = 4, SK_ma_sport_01_c = 4,
    SK_ma_construction_worker_01 = 4, SK_ma_construction_worker_01_c = 4, SK_ma_construction_worker_02_b = 4, SK_ma_waiter_01 = 4,
    SK_ma_business_01 = 4, SK_ma_business_01_b = 4, SK_ma_physician_01 = 6.8,
    SK_fe_casual_02_a = 5.6, SK_fe_sport_02_b = 4, SK_fe_business_01_a = 4.6, SK_fe_business_01_b = 4.6, SK_fe_business_01_c = 4.6,
}
Avatar.WATCH_LOWER = WATCH_LOWER
local function wearWatch(p, code)
    local w = WATCHES[code]
    code = w and code or ""
    if (p.watchCode or "") == code then return end
    p.watchCode = code
    if p.watch then
        local old = p.watch
        p.watch = nil
        for i = #p.actors, 1, -1 do
            if p.actors[i] == old then table.remove(p.actors, i) end
        end
        pcall(function() if valid(old) then old:K2_DestroyActor() end end)
    end
    if not w then return end
    local m = asset(WATCH_DIR .. w.mesh .. "." .. w.mesh)
    if not m then error("model " .. w.mesh .. " is not available") end
    local watch = p.body:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = p.x, Y = p.y, Z = p.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(watch) then error("model " .. w.mesh .. " could not be made") end
    watch:SetMobility(2)
    watch:SetActorEnableCollision(false)
    watch.StaticMeshComponent:SetStaticMesh(m)
    p.actors[#p.actors + 1] = watch
    p.watch = watch
    local s = p.female and w.f or w.m
    local lower = WATCH_LOWER[p.bodyMesh or ""] or 0
    watch:K2_AttachToComponent(p.comp, FName(WATCH_BONE), 2, 2, 2, false)
    watch:K2_SetActorRelativeLocation({ X = s.loc.X + lower, Y = s.loc.Y, Z = s.loc.Z }, false, {}, true)
    watch:K2_SetActorRelativeRotation(s.rot, false, {}, true)
    watch:SetActorRelativeScale3D({ X = s.scale, Y = s.scale, Z = s.scale })
end

-- (also for stand-ins) "analog", "digital", or anything else for none. A failure is logged
-- once per figure and leaves it without a watch.
function Avatar.setWatch(p, code)
    if not p or not valid(p.body) then return end
    local ok, e = pcall(wearWatch, p, code)
    if not ok and not p.watchFailed then
        p.watchFailed = true
        log("Could not give a figure its watch: %s", tostring(e))
    end
end

-- (also for stand-ins) A failure is logged once per figure and leaves it without a bag.
function Avatar.setBag(p, code)
    if not p or not valid(p.body) then return end
    local ok, e = pcall(wearBag, p, code or 0)
    if not ok and not p.bagFailed then
        p.bagFailed = true
        log("Could not give a figure its backpack: %s", tostring(e))
    end
end

-- The number (of BAGS) of the backpack our own player wears; looked up once a second.
local ownBagCode, ownBagAt = 0, -10
function Avatar.ownBag()
    local now = os.clock()
    if now - ownBagAt >= 1 then
        ownBagAt = now
        local code = 0
        pcall(function()
            local player = World.player()
            if player then code = BAG_OF[player.InventoryComponent.CurBackpackID:ToString()] or 0 end
        end)
        ownBagCode = code
    end
    return ownBagCode
end

-- Re-applies Avatar.tune to phones that already exist (used while adjusting).
function Avatar.applyTune()
    local t = Avatar.tune
    for _, set in pairs(Avatar.puppets) do
        local p = set.player
        if p then seatPhone(p, p.pose) end
        if p then seatBag(p) end
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

-- Where a figure's body goes: where the player is and faces, moved and turned by what the
-- emote it plays asks for (`back` and `side` in units from the standing spot, `yaw` degrees).
local function bodyPlace(p, z)
    local back, side = p.offBack or 0, p.offSide or 0
    local yaw = math.rad(p.yaw)
    return { X = p.x - math.cos(yaw) * back - math.sin(yaw) * side, Y = p.y - math.sin(yaw) * back + math.cos(yaw) * side, Z = z + (p.offUp or 0) },
        { Pitch = 0, Yaw = p.yaw + MESH_YAW + (p.offYaw or 0), Roll = 0 }
end
Avatar.bodyPlace = bodyPlace

-- Shows or hides the phone and the torch, and switches between the normal walk, the
-- looking-at-the-phone animation and the talking-on-the-phone animation.
local function holdThings(p)
    local flags = p.flags or 0
    local wantLight = flags & FLAG_LIGHT ~= 0
    local pose = nil
    local emote = emoteOf(p.emote or 0)
    if flags & FLAG_CALL ~= 0 then
        pose = "call"
    elseif emote then
        pose = "emote" .. tostring(p.emote)
    elseif wantLight or flags & FLAG_PHONE ~= 0 then
        pose = "phone"
    elseif flags & FLAG_STRUT ~= 0 then
        -- (only while walking; standing still is the normal standing)
        local speed = Avatar.tune.testSpeed or p.speed or 0
        if speed > 25 or (p.pose == "strut" and speed > 8) then pose = "strut" end
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
        elseif pose == "strut" then anim = asset(STRUT_ANIM)
        elseif emote and emote.anim then anim = asset(emote.anim) end
        if anim then
            setSkeleton(p, true)
            p.comp:PlayAnimation(anim, true)
            p.comp:SetPlayRate(1)
            p.phoneAnim = true
            p.jogging = false
            p.standing = false
            pcall(function() p.animLength = anim:GetPlayLength() end)
        elseif p.phoneAnim then
            p.phoneAnim = false
            toBlueprint(p)
        end
        p.pose = pose
        -- (a seat at a table: mostly sitting still, see sitCalm)
        if anim and emote and emote.calm and pose and pose:sub(1, 5) == "emote" then sitCalm(p) else sitters[p] = nil end
        if holdsPhone then seatPhone(p, pose) end
        -- An emote may stand the figure elsewhere than the player (see Avatar.EMOTES). The
        -- own figure only while it is held where it stands (otherwise it hangs on the player).
        local shift = (pose and pose:sub(1, 5) == "emote" and emote) or {}
        local back, side, turn, up = shift.back or 0, shift.side or 0, shift.yaw or 0, shift.up or 0
        if back ~= (p.offBack or 0) or side ~= (p.offSide or 0) or turn ~= (p.offYaw or 0) or up ~= (p.offUp or 0) then
            local wasUp = p.offUp or 0
            p.offBack, p.offSide, p.offYaw, p.offUp = back, side, turn, up
            if not p.own then
                local at, rot = bodyPlace(p, p.z + feetOffset(p))
                p.body:K2_SetActorLocationAndRotation(at, rot, false, {}, true)
            elseif p.heldStill then
                local at, rot = bodyPlace(p, p.body:K2_GetActorLocation().Z - wasUp)
                p.body:K2_SetActorLocationAndRotation(at, rot, false, {}, true)
            end
        end
    end
    local bag = (flags >> BAG_SHIFT) & BAG_MASK
    if bag ~= (p.bagCode or 0) then Avatar.setBag(p, bag) end
    -- (a bag carried in the hand is put away while the hands do something else)
    if p.bag and BAGS[p.bagCode] and BAGS[p.bagCode].hand then
        local away = p.pose ~= nil or (flags & FLAG_STRUT ~= 0)
        if away ~= (p.bagAway == true) then
            p.bagAway = away
            pcall(function() if valid(p.bag) then p.bag:SetActorHiddenInGame(away) end end)
        end
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
    if p.phoneAnim and pose == "strut" then
        local speed = Avatar.tune.testSpeed or p.speed or 0
        p.comp:SetPlayRate(math.max(0.4, math.min(2.5, speed / Avatar.tune.strutSpeed)))
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
    local moving = not p.own and (d2 > 0.25 or math.abs(turn) > 0.3)
    if moving then
        if d2 > 600 * 600 then k = 1 end   -- teleport, do not glide
        p.x, p.y, p.z = p.x + dx * k, p.y + dy * k, p.z + dz * k
        p.yaw = p.yaw + turn * k
        local at, rot = bodyPlace(p, p.z + feetOffset(p))
        p.body:K2_SetActorLocationAndRotation(at, rot, false, {}, true)
    end
    local now = p.ticks % 10 == 0
    if p.female and not p.phoneAnim then
        local run = (p.speed or 0) > Avatar.tune.femaleJogFrom
        if run ~= (p.jogging == true) then
            p.jogging = run
            if run then
                local jog = asset(FEMALE_JOG)
                if jog then
                    p.comp:PlayAnimation(jog, true)
                else
                    p.jogging = false
                end
            else
                toBlueprint(p)
                p.walk = nil
            end
        end
        if p.jogging then
            p.comp:SetPlayRate(math.max(0.6, math.min(1.8, (p.speed or 0) / Avatar.tune.femaleJogSpeed)))
        end
    end
    if not p.female then
        local speed = Avatar.tune.testSpeed or p.speed or 0
        -- (not while the hands or the body do something else: phone, call, strut, an emote, crouching)
        local run = not p.phoneAnim and not p.crouched and (p.emote or 0) == 0
            and speed > Avatar.tune.maleRunFrom - (p.running and 40 or 0)
        if run ~= (p.running == true) then setRun(p, run) end
        if p.running then
            pcall(function() p.runComp:SetPlayRate(math.max(0.7, math.min(1.6, speed / Avatar.tune.maleRunSpeed))) end)
        end
    end
    if not p.phoneAnim and not p.jogging and (p.walk ~= p.speed or now) then
        p.walk = p.speed
        pcall(function()
            local anim = p.comp:GetAnimInstance()
            anim.speed = p.speed
            anim.Velocity = p.speed
        end)
    end
    -- another player crouching: the citizens' crouching pose (as the own figure has it; not
    -- while the hands or the body do something else: phone, call, strut, an emote)
    if p.isPlayer and not p.own then
        local f = p.flags or 0
        local crouch = f & FLAG_CROUCH ~= 0 and (p.emote or 0) == 0 and f & (FLAG_PHONE | FLAG_CALL | FLAG_STRUT) == 0
        if crouch ~= (p.crouched == true) then
            p.crouched = crouch
            pcall(function()
                if crouch then
                    local anim = asset(CROUCH_POSE)
                    if anim then
                        setSkeleton(p, true)
                        p.comp:PlayAnimation(anim, true)
                        p.comp:SetPlayRate(1)
                        p.phoneAnim, p.jogging = true, false
                    end
                else
                    p.phoneAnim = false
                    p.pose = false          -- (holdThings puts the right animation back)
                    toBlueprint(p)
                    p.walk = nil
                end
            end)
        end
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
    if p.bag and p.bagCode and BAGS[p.bagCode] and BAGS[p.bagCode].hang and not p.bagAway then
        pcall(hangBag, p)
    end
    if p.label and (moving or p.ticks % 3 == 0) and valid(p.label) then
        local face = math.deg(math.atan(camera.Y - p.y, camera.X - p.x))
        p.label:K2_SetActorLocationAndRotation({ X = p.x, Y = p.y, Z = p.z + feetOffset(p) + NAME_HEIGHT - (feetOffset(p) == CROUCH_FEET and 90 or 0) },
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

local function describe(actor, own)
    local loc = actor:K2_GetActorLocation()
    if actor == World.player() then
        loc.Z = loc.Z + (Avatar.sendZ or 0)
        -- (seated at a slot machine the view is held behind the stool the figure sits on)
        if Avatar.sendXY then loc.X, loc.Y = Avatar.sendXY.x, Avatar.sendXY.y end
    end
    local rot = actor:K2_GetActorRotation()
    local yaw = rot.Yaw
    if own and Avatar.seatedAt then
        -- (in a seat that turns the figure its own way: looking around does not turn it)
        yaw = Avatar.seatedAt.yaw
    elseif own and Avatar.sendYaw then
        yaw = Avatar.sendYaw
    end
    local vel = actor:GetVelocity()
    return string.format("%.0f,%.0f,%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z, yaw, math.sqrt(vel.X * vel.X + vel.Y * vel.Y)), loc
end

-- What our own player has in hand, and where the view points up or down.
local function held(player)
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
    local emote = emoteOf(Avatar.localEmote or 0)
    if os.clock() < (Avatar.smokeUntil or 0) or (emote and emote.smoke) then flags = flags | FLAG_SMOKE end
    if Avatar.strut then flags = flags | FLAG_STRUT end
    pcall(function() if player.isCrouching == true and not Avatar.sendZ then flags = flags | FLAG_CROUCH end end)
    flags = flags | (Avatar.ownBag() << BAG_SHIFT)
    return flags, pitch
end

local function holding(player)
    local flags, pitch = held(player)
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
        line, loc = describe(player, true)
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

-- Standing about: the citizens' calm standing loop, and only now and then (every 45 to 65
-- seconds) their fidget, which looks over the shoulder. (The citizens' own animation
-- plays the fidget on every loop.) Both start and end in the same pose, so the fidget
-- starts when the loop comes round and the loop again when the fidget is over.
local IDLE_ANIM = "/Game/Animations/Citizen_MOB1_Stand_Relaxed_Idle_v2_IPC.Citizen_MOB1_Stand_Relaxed_Idle_v2_IPC"
local FIDGET_ANIM = "/Game/Animations/Citizen_MOB1_Stand_Relaxed_Fgt_v1_IPC.Citizen_MOB1_Stand_Relaxed_Fgt_v1_IPC"
local idlers = {}

local function femaleStill(p)
    local stand = asset(FEMALE_STAND)
    if not stand then return false end
    setSkeleton(p, false)
    p.comp:PlayAnimation(stand, false)
    p.comp:SetPlayRate(0)
    p.comp:SetPosition(0, false)
    return true
end

-- A woman standing about: the women's only standing clip is their fidget; its last second
-- (where it also ends) keeps the head within a few degrees of straight ahead, so she sways
-- back and forth in that second, slowly, and (not `calm`) does the whole fidget now and then.
local SWAY_FROM, SWAY_TO, SWAY_RATE = 4.0, 4.95, 0.45

local function startIdle(p, calm)
    if p.female then
        if not femaleStill(p) then return false end
        p.comp:SetPosition(SWAY_TO, false)
        p.comp:SetPlayRate(-SWAY_RATE)
        p.idleCycle = { female = true, calm = calm == true, at = os.clock() + math.random(45, 65), fidget = false }
        idlers[p] = true
        return true
    end
    local idle = asset(IDLE_ANIM)
    if not idle then return false end
    p.comp:PlayAnimation(idle, true)
    p.comp:SetPlayRate(1)
    -- (calm: the standing loop only, never the fidget)
    if calm then return true end
    p.idleCycle = { loops = math.random(7, 10), last = 0, fidget = false }
    idlers[p] = true
    return true
end

Core.onTick(function()
    for p in pairs(idlers) do
        local c = p.idleCycle
        if not c or not valid(p.comp) then
            idlers[p] = nil
        else
            pcall(function()
                if c.female then
                    -- (a woman: swaying, the whole fidget now and then, swaying again)
                    if c.fidget then
                        if not p.comp:IsPlaying() or p.comp:GetPosition() >= SWAY_TO then
                            c.fidget = false
                            c.at = os.clock() + math.random(45, 65)
                            p.comp:PlayAnimation(asset(FEMALE_STAND), false)
                            p.comp:SetPosition(SWAY_TO, false)
                            p.comp:SetPlayRate(-SWAY_RATE)
                        end
                        return
                    end
                    if not c.calm and os.clock() >= c.at then
                        p.comp:SetPosition(0, false)
                        p.comp:SetPlayRate(1)
                        c.fidget = true
                        return
                    end
                    local at = p.comp:GetPosition()
                    if at >= SWAY_TO then
                        p.comp:SetPosition(SWAY_TO, false)
                        p.comp:SetPlayRate(-SWAY_RATE)
                    elseif at <= SWAY_FROM then
                        p.comp:SetPosition(SWAY_FROM, false)
                        p.comp:SetPlayRate(SWAY_RATE)
                    end
                    if not p.comp:IsPlaying() then p.comp:Play(false) end
                    return
                end
                if c.fidget then
                    if not p.comp:IsPlaying() then startIdle(p) end
                    return
                end
                local at = p.comp:GetPosition()
                if at + 0.05 < c.last then
                    -- the loop came round
                    c.loops = c.loops - 1
                    if c.loops <= 0 then
                        local fidget = asset(FIDGET_ANIM)
                        if fidget then
                            p.comp:PlayAnimation(fidget, false)
                            p.comp:SetPlayRate(1)
                            c.fidget = true
                        else
                            c.loops = 10
                        end
                    end
                end
                c.last = at
            end)
        end
    end
end)

-- A puppet that is not a player: the wardrobe shows one as a mirror. It stands still.
-- `pose` "idle" has it stand about (see startIdle), "calm" the same without the fidget;
-- otherwise it holds one relaxed standing frame.
function Avatar.buildStandIn(look, x, y, z, yaw, name, pose)
    local p = build(partsOf(look), { x = x, y = y, z = z, yaw = yaw }, name)
    if p then
        pcall(function()
            if (pose == "idle" or pose == "calm") and startIdle(p, pose == "calm") then return end
            if p.female and femaleStill(p) then return end
            local anim = asset(STAND_ANIM)
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
    p.idleCycle = nil
    if anim then
        setSkeleton(p, true)
        p.comp:PlayAnimation(anim, true)
        p.comp:SetPlayRate(1)
    elseif startIdle(p) then
        return
    else
        toBlueprint(p)
    end
end

function Avatar.moveStandIn(p, x, y, z, yaw)
    if not p or not valid(p.body) then return end
    p.body:K2_SetActorLocationAndRotation({ X = x, Y = y, Z = z + FEET_OFFSET }, { Pitch = 0, Yaw = yaw + MESH_YAW, Roll = 0 }, false, {}, true)
end

function Avatar.destroyStandIn(p) destroy(p) end

-- The figure of our own player, for the third-person view (coop/third.lua): dressed like
-- the player, hung on the player's own actor (the engine moves it, every frame), animated
-- like the figures of the other players from what the player does.
local CROUCH_ANIM = "/Game/Animations/Sebiks_MOB1_Crouch_Idle_V2_IPC.Sebiks_MOB1_Crouch_Idle_V2_IPC"

local function seatOwn(p, player)
    local l = player:K2_GetActorLocation()
    local yaw = player:K2_GetActorRotation().Yaw
    local half = 90
    pcall(function() half = player.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    p.half = half
    p.body:K2_SetActorLocationAndRotation({ X = l.X, Y = l.Y, Z = l.Z - half }, { Pitch = 0, Yaw = yaw + MESH_YAW, Roll = 0 }, false, {}, true)
    p.body:K2_AttachToActor(player, FName("None"), 1, 1, 1, false)
    p.x, p.y, p.z, p.yaw = l.X, l.Y, l.Z, yaw
end

function Avatar.buildOwn(look, player)
    local l = player:K2_GetActorLocation()
    local p = build(partsOf(look), { x = l.X, y = l.Y, z = l.Z, yaw = player:K2_GetActorRotation().Yaw }, nil)
    if not p then return nil end
    p.isPlayer, p.own = true, true
    local ok, e = pcall(seatOwn, p, player)
    if not ok then
        log("Own figure: %s", tostring(e))
        destroy(p)
        return nil
    end
    return p
end

-- Holds the own figure where it stands (an emote: the view turns around it), or hangs it on
-- the player again.
function Avatar.holdOwn(p, player, hold)
    if not p or not valid(p.body) or (p.heldStill == true) == hold then return end
    p.heldStill = hold
    if hold then
        p.body:K2_DetachFromActor(1, 1, 1)
    else
        seatOwn(p, player)
    end
end

function Avatar.showOwn(p, show)
    if not p or (p.shown ~= false) == show then return end
    p.shown = show
    for _, a in ipairs(p.actors) do
        pcall(function() if valid(a) then a:SetActorHiddenInGame(not show) end end)
    end
    if show then
        -- (what was put away stays away)
        p.pose, p.torchShown, p.smoking, p.bagAway = false, nil, nil, nil
        pcall(function() if p.phone and valid(p.phone) then p.phone:SetActorHiddenInGame(true) end end)
        pcall(function() if p.smoke and valid(p.smoke) then p.smoke:SetActorHiddenInGame(true) end end)
        pcall(function() if p.wisp and valid(p.wisp) then p.wisp:SetActorHiddenInGame(true) end end)
    end
end

function Avatar.stepOwn(p, player, dt)
    if not p or not valid(p.body) then return false end
    local l = player:K2_GetActorLocation()
    local v = player:GetVelocity()
    local flags, pitch = held(player)
    -- (the player's own torch is the game's; the phone is used in the first-person view)
    flags = flags & ~FLAG_LIGHT & ~FLAG_PHONE
    p.flags, p.pitch, p.emote = flags, pitch, Avatar.localEmote or 0
    p.speed = math.sqrt(v.X * v.X + v.Y * v.Y)
    if not p.heldStill then
        p.x, p.y, p.z, p.yaw = l.X, l.Y, l.Z, player:K2_GetActorRotation().Yaw
        -- crouching: the game lowers the capsule; the feet stay on the ground
        local half = p.half
        pcall(function() half = player.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
        if math.abs(half - p.half) > 0.5 then
            p.half = half
            p.body:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = l.Z - half }, false, {}, true)
        end
    elseif Avatar.seatedAt then
        -- Held in a seat whose pose sets the figure elsewhere than the player (the poker
        -- table's armchairs): the figure is placed from the seat, not from where the player
        -- stood and faced before sitting down. (holdThings adds the pose's own shift.)
        local s = Avatar.seatedAt
        local half = p.half
        pcall(function() half = player.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
        if p.x ~= s.x or p.y ~= s.y or p.yaw ~= s.yaw or p.z ~= l.Z or math.abs(half - p.half) > 0.5 then
            p.x, p.y, p.z, p.yaw, p.half = s.x, s.y, l.Z, s.yaw, half
            local at, rot = bodyPlace(p, l.Z - half)
            p.body:K2_SetActorLocationAndRotation(at, rot, false, {}, true)
        end
    end
    local crouch = false
    pcall(function() crouch = player.isCrouching == true end)
    if p.emote ~= 0 or flags & FLAG_CALL ~= 0 then crouch = false end
    if crouch ~= (p.crouched == true) then
        p.crouched = crouch
        if crouch then
            local anim = asset(CROUCH_ANIM)
            if anim then
                setSkeleton(p, true)
                p.comp:PlayAnimation(anim, true)
                p.comp:SetPlayRate(1)
                p.phoneAnim, p.jogging = true, false
            end
        else
            p.phoneAnim = false
            p.pose = false          -- (holdThings puts the right animation back)
            toBlueprint(p)
            p.walk = nil
        end
    end
    move(p, dt, l)
    return true
end
-- (for test scripts) one step of another player's figure
function Avatar.stepPuppet(p, dt, camera) move(p, dt, camera) end

-- Lights a stand-in from a light of its own that reaches nothing else: the figure's parts
-- are also on lighting channel 2, the light on that channel alone. The light is one of
-- the figure's actors (it goes with it).
local function channels(c, a, b, z)
    local ok = pcall(function() c:SetLightingChannels(a, b, z) end)
    if not ok then
        pcall(function()
            c.LightingChannels = { bChannel0 = a, bChannel1 = b, bChannel2 = z }
            c:MarkRenderStateDirty()
        end)
    end
end
function Avatar.lightFromAbove(p, x, y, z, radius, intensity)
    if not p or not valid(p.body) then return nil end
    for _, a in ipairs(p.actors or {}) do
        pcall(function() if valid(a.SkeletalMeshComponent) then channels(a.SkeletalMeshComponent, true, false, true) end end)
    end
    local world = p.body:GetWorld()
    local light = world:SpawnActor(StaticFindObject("/Script/Engine.PointLight"), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(light) then return nil end
    local c = light.LightComponent
    c:SetMobility(2)
    c:SetIntensity(intensity or 5000)
    c:SetAttenuationRadius(radius or 400)
    c:SetLightColor({ R = 1, G = 0.95, B = 0.88, A = 1 }, true)
    c:SetCastShadows(false)
    channels(c, false, false, true)
    p.actors[#p.actors + 1] = light
    return light
end

-- Changes how another player looks; their character is rebuilt on the next tick.
-- A plain lamp that goes with a stand-in (taken down with it). Unlike lightFromAbove it
-- lights whatever is near, the figure among it.
function Avatar.lamp(p, x, y, z, radius, intensity)
    if not p or not valid(p.body) then return nil end
    local light = p.body:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.PointLight"), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(light) then return nil end
    local c = light.LightComponent
    c:SetMobility(2)
    -- (no highlights: so close, the sheen on hair and beard turned black to grey)
    pcall(function() c.SpecularScale = 0 end)
    c:SetIntensity(intensity or 4000)
    c:SetAttenuationRadius(radius or 400)
    c:SetLightColor({ R = 1, G = 0.95, B = 0.88, A = 1 }, true)
    c:SetCastShadows(false)
    p.actors[#p.actors + 1] = light
    return light
end

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
