-- The card room in the basement of the night club.
--
-- A felt table, chairs, hanging lamps and a dealer are put into the club's basement lounge
-- (every game builds its own copy; nothing of it is saved). At the club's door a player
-- can go down to the table: they are seated in front of the dealer and play blackjack for
-- cash from their pockets with the mouse. The dealer draws to 17 and stands on every 17,
-- a blackjack pays 3 to 2, a double takes exactly one more card, no splitting. Winnings
-- are cash in the pockets (in the bank when the pockets are full).

local Core = require("core")
local Net = require("net")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Hud = require("coop.hud")
local Look = require("coop.look")
local Screen = require("coop.screen")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_CASINO_GEN") or 0) + 1
_G.DDSMP_CASINO_GEN = GEN
local function live() return rawget(_G, "DDSMP_CASINO_GEN") == GEN end

local Casino = { seated = false, debug = false }

-- The club's door (where the game's own "Night Club" marker is).
local DOOR = { x = 14430, y = -7850, z = 100, reach = 700 }
-- The basement lounge: the raised floor along its far wall.
local FLOOR = -185
local TX, TY = 15370, -8375                   -- centre of the table
local TOP = FLOOR + 80                        -- height of the felt
-- Places at the table, on the room's side of it. Each looks at the middle of the felt.
local SEATS = {
    { x = TX - 108, y = TY, yaw = 0 },
    { x = TX - 90, y = TY - 122, yaw = 28 },
    { x = TX - 90, y = TY + 122, yaw = -28 },
}
local SEAT_NAMES = { "middle seat", "left seat", "right seat" }      -- seen from the room
-- The lounge around the table is a level of the game's own, loaded while a player with
-- collision is in the club's basement and thrown away when none is. Two of its tables and
-- a plate are where the card table stands; they are known by name.
local LOUNGE = "/Game/Levels/stream_ballenaClub.stream_ballenaClub:PersistentLevel."
local IN_THE_WAY = { "SM_Table_4", "SM_Table_5", "SM_Plate_4" }
-- Its furniture next to the seats, as boxes around the table's centre (measured in the
-- running game): the sofas on the room's side, those along the wall, the third table.
local BOOTHS = {
    { x0 = -225, x1 = -128, y0 = -135, y1 = 375 },
    { x0 = 63, x1 = 160, y0 = -135, y1 = 375 },
    { x0 = -85, x1 = 25, y0 = 202, y1 = 358 },
}
local EYE = FLOOR + 122       -- where a seated player's view is held
local SIT = FLOOR + 90        -- where the others see them (on the chair)
local PITCH = -32
local SEAT = SEATS[1]
local DEFAULT_BETS = { 50, 100, 250, 500, 1000, 2500 }
local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
local SUITS = { "\226\153\160", "\226\153\165", "\226\153\166", "\226\153\163" }   -- spade heart diamond club
local BAR = "/Game/ModularBarInterior/"

-- In co-op, and in single player too unless SoloExtras is false (World.extras).
local function active() return (World.extras() or Casino.debug) and Core.config.Casino ~= false end
local function key(name) return tostring(Core.config[name] or "?") end

---------------------------------------------------------------- the room

local room = nil     -- { actors, dealer, owner }

local function asset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if valid(o) then return o end
    return nil
end

local function clearRoom()
    if not room then return end
    for _, a in ipairs(room.actors) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
    if room.dealer then pcall(Avatar.destroyStandIn, room.dealer) end
    for _, a in ipairs(room.hidden or {}) do
        pcall(function()
            if valid(a) then
                a:SetActorHiddenInGame(false)
                a:SetActorEnableCollision(true)
            end
        end)
    end
    room = nil
end

local function buildRoom()
    local player = World.player()
    local world = player:GetWorld()
    room = { actors = {}, owner = player:GetAddress() }
    local function spawn(class, x, y, z, yaw)
        local a = world:SpawnActor(StaticFindObject(class), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw or 0, Roll = 0 })
        room.actors[#room.actors + 1] = a
        return a
    end
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
    local MAT = {
        -- matte: a shiny felt turns into a brown mirror of the lamps when seen from standing height
        felt = dyed("Fabric/MI_Velvet_Blue", { ["Color 1"] = col(0.003, 0.036, 0.012), ["Color 2"] = col(0.005, 0.055, 0.02),
            ["Specular"] = 0, ["Metallic"] = 0, ["Roughness Intensity"] = 6, ["Use Wear"] = 0, ["Use Dirt"] = 0 }),
        rim = dyed("MeshMaterials/MI_Sofa_1_Leather", { ["Color"] = col(0.045, 0.018, 0.009), ["Specular"] = 0.05, ["Specular Max"] = 0.05,
            ["Roughness Min"] = 0.85, ["Roughness Max"] = 1, ["Metallic"] = 0 }),
        wood = dyed("Wood/MI_Wood_4", {}),
        white = plastic(0.9, 0.9, 0.86), red = plastic(0.55, 0.02, 0.02), blue = plastic(0.02, 0.06, 0.4),
        black = plastic(0.015, 0.015, 0.015), green = plastic(0.02, 0.3, 0.05),
    }
    room.mat = MAT
    local function shape(kind, x, y, z, sx, sy, sz, yaw, mat)
        local a = spawn("/Script/Engine.StaticMeshActor", x, y, z, yaw)
        a:SetMobility(2)
        a.StaticMeshComponent:SetStaticMesh(asset("/Engine/BasicShapes/" .. kind .. "." .. kind))
        a:SetActorScale3D({ X = sx, Y = sy, Z = sz })
        if mat then a.StaticMeshComponent:SetMaterial(0, mat) end
        a:SetActorEnableCollision(false)
        return a
    end
    local function mesh(path, x, y, z, yaw)
        local m = asset(path)
        if not m then
            log("Casino: mesh %s is not available", path)
            return nil
        end
        local a = spawn("/Script/Engine.StaticMeshActor", x, y, z, yaw)
        a:SetMobility(2)
        a.StaticMeshComponent:SetStaticMesh(m)
        return a
    end
    local function bar(name, x, y, z, yaw) return mesh(BAR .. "Meshes/" .. name .. "." .. name:match("[^/]+$"), x, y, z, yaw) end
    local function lamp(x, y, z)
        local l = spawn("/Script/Engine.PointLight", x, y, z)
        local c = l.LightComponent
        c:SetMobility(2)
        c:SetIntensity(520)
        c:SetAttenuationRadius(420)
        c:SetLightColor({ R = 1, G = 0.74, B = 0.42, A = 1 }, true)
        c:SetCastShadows(false)
    end

    -- the table: two wooden pedestals, a leather rim, a felt top
    shape("Cylinder", TX, TY - 70, FLOOR + 37, 0.34, 0.34, 0.74, 0, MAT.wood)
    shape("Cylinder", TX, TY + 70, FLOOR + 37, 0.34, 0.34, 0.74, 0, MAT.wood)
    shape("Cylinder", TX, TY, TOP - 4, 1.56, 2.72, 0.07, 0, MAT.rim)
    shape("Cylinder", TX, TY, TOP - 2.6, 1.36, 2.52, 0.058, 0, MAT.felt)
    -- chips: loose stacks at the sides, the dealer's rack
    local colors = { MAT.red, MAT.blue, MAT.white, MAT.black, MAT.green }
    local seed = 7
    local function rnd()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    local function stack(x, y, n, mat) shape("Cylinder", x, y, TOP + 0.3 + n * 0.165, 0.04, 0.04, n * 0.0033, 0, mat) end
    for i = 1, 16 do
        local side = (i % 2 == 0) and 1 or -1
        stack(TX - 25 + rnd() * 55, TY + side * (55 + rnd() * 50), 3 + math.floor(rnd() * 10), colors[1 + math.floor(rnd() * 5)])
    end
    for i = 0, 4 do stack(TX + 48, TY - 10.4 + i * 5.2, 14, colors[i + 1]) end
    shape("Cube", TX + 40, TY + 34, TOP + 1.2, 0.063, 0.088, 0.016, 80, MAT.blue)        -- the deck
    for i = 1, 3 do shape("Cube", TX - 10 + rnd() * 20, TY + 92 + i * 9, TOP + 0.45, 0.063, 0.088, 0.0012, 60 + rnd() * 60, MAT.white) end
    -- chairs
    local chair = "/Game/FreeFurniturePack/Meshes/SM_Classic_chair.SM_Classic_chair"
    mesh(chair, TX - 104, TY, FLOOR, 0)
    mesh(chair, TX - 84, TY - 124, FLOOR, 28)
    mesh(chair, TX - 84, TY + 124, FLOOR, -28)
    mesh(chair, TX + 10, TY + 168, FLOOR, -90)
    mesh(chair, TX + 10, TY - 168, FLOOR, 90)
    -- lamps over the table
    bar("Lights/SM_CeilingLight_4", TX, TY - 60, 78, 0)
    bar("Lights/SM_CeilingLight_4", TX, TY + 60, 78, 0)
    lamp(TX, TY - 60, TOP + 110)
    lamp(TX, TY + 60, TOP + 110)
    -- the corners
    bar("BarProps/SM_Barrel", TX + 120, TY - 260, FLOOR, 0)
    bar("BarProps/SM_Bottle_1", TX + 120, TY - 262, FLOOR + 85, 0)
    bar("BarProps/SM_Glass_2", TX + 108, TY - 250, FLOOR + 85, 0)
    bar("BarProps/SM_Barrel", TX + 150, TY + 300, FLOOR, 0)
    bar("BarProps/SM_Bottle_5", TX + 150, TY + 300, FLOOR + 85, 0)
    bar("BarProps/SM_Bottle_4", TX - 30, TY + 100, TOP + 0.4, 0)
    bar("BarProps/SM_Glass_1", TX - 22, TY + 88, TOP + 0.4, 0)
    bar("BarProps/SM_Painting_1", TX + 160, TY - 150, FLOOR + 150, 90)
    bar("BarProps/SM_Painting_2", TX + 160, TY + 150, FLOOR + 150, 90)
    room.own = {}
    for _, a in ipairs(room.actors) do pcall(function() room.own[a:GetAddress()] = true end) end
    room.hidden = {}
    -- the dealer
    room.dealer = Avatar.buildStandIn({ body = "SK_ma_waiter_01", head = "SK_ma_head_02", hair = "Hats_Hair/SK_ma_hair_03", arms = true },
        TX + 112, TY, FLOOR + 90, 180, nil, "idle")
    log("Casino: the card room is set up (%d pieces)", #room.actors)
end

-- The lounge has a table of its own where the card table stands. It and whatever furniture
-- is inside the card table's footprint are hidden (and put back when the card room is
-- removed); its glasses and bottles go onto the felt. The lounge's furniture is not there
-- yet when a player first comes near, so this is done again and again.
local function putAway()
    if not room then return end
    local now = os.clock()
    if now < (room.putAwayAt or 0) then return end
    room.putAwayAt = now + (#room.hidden > 0 and 60 or 3)
    for _, a in ipairs(FindAllOf("StaticMeshActor") or {}) do
        pcall(function()
            if room.own[a:GetAddress()] or not Core.alive(a) or a.bHidden == true then return end
            local l = a:K2_GetActorLocation()
            if math.abs(l.X - TX) > 135 or math.abs(l.Y - TY) > 215 or l.Z < FLOOR - 8 or l.Z > TOP + 45 then return end
            local name = a.StaticMeshComponent.StaticMesh:GetFName():ToString()
            local lower = name:lower()
            if lower:find("table", 1, true) or lower:find("plate", 1, true) or lower:find("seat", 1, true) or lower:find("chair", 1, true) or lower:find("sofa", 1, true) then
                a:SetActorHiddenInGame(true)
                a:SetActorEnableCollision(false)
                room.hidden[#room.hidden + 1] = a
                log("Casino: put away the lounge's %s", name)
            elseif (lower:find("glass", 1, true) or lower:find("bottle", 1, true)) and math.abs(l.Z - (TOP + 0.4)) > 1 then
                a:SetMobility(2)
                a:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = TOP + 0.4 }, false, {}, true)
            end
        end)
    end
end

---------------------------------------------------------------- the lounge's level

-- Every time the lounge's level is loaded its furniture is made anew, so what was hidden
-- is back. The level is watched: the tables under the card table are hidden by name as
-- soon as the level is loaded (before it is shown), and the rest is looked through the
-- moment it is shown.
local lounge = nil      -- { owner, level, loaded, visible }
local hold = nil        -- after standing up: { owner, till }

local function loungeLevel(player)
    local address = player:GetAddress()
    if lounge and lounge.owner == address then return lounge.level end
    lounge = { owner = address, loaded = false, visible = false }
    pcall(function()
        local list = player:GetWorld().StreamingLevels
        for i = 1, list:GetArrayNum() do
            local l = list[i]
            if l:GetWorldAssetPackageFName():ToString():match("stream_ballenaClub$") then
                lounge.level = l
                break
            end
        end
    end)
    return lounge.level
end

local function hideInTheWay()
    local n = 0
    for _, name in ipairs(IN_THE_WAY) do
        local a = StaticFindObject(LOUNGE .. name)
        if Core.alive(a) then
            n = n + 1
            if a.bHidden ~= true then
                a:SetActorHiddenInGame(true)
                a:SetActorEnableCollision(false)
                room.hidden[#room.hidden + 1] = a
            end
        end
    end
    return n
end

-- Is this place inside the lounge's furniture (with room for a body)?
local function inBooth(l)
    if l.Z > FLOOR + 220 then return false end
    local dx, dy = l.X - TX, l.Y - TY
    for _, b in ipairs(BOOTHS) do
        if dx > b.x0 - 45 and dx < b.x1 + 45 and dy > b.y0 - 45 and dy < b.y1 + 45 then return true end
    end
    return false
end

local loungeError = nil
Core.onTick(function()
    if not live() or not room then return end
    local player = World.player()
    if not player then return end
    local level = loungeLevel(player)
    if not level then return end
    local ok, e = pcall(function()
        if hold then
            -- A player who got up stands where a sofa belongs. The lounge is kept from
            -- showing for a while, and for as long as they are still inside its furniture;
            -- after half a minute of that they are set beside the sofa.
            local now = os.clock()
            local done = hold.owner ~= player:GetAddress() or Casino.seated
            if not done and now >= hold.till then
                local l = player:K2_GetActorLocation()
                if not inBooth(l) then
                    done = true
                elseif now >= hold.till + 30 then
                    player:K2_SetActorLocation({ X = TX - 275, Y = l.Y, Z = FLOOR + 100 }, false, {}, true)
                    done = true
                end
            end
            if done then
                hold = nil
                if level.bShouldBeLoaded == true then level:SetShouldBeVisible(true) end
            elseif level.bShouldBeVisible == true then
                level:SetShouldBeVisible(false)
            end
        end
        local loaded, visible = level:IsLevelLoaded() == true, level:IsLevelVisible() == true
        if loaded and not lounge.loaded then
            room.hidden = {}        -- what was hidden before went with the level before
            hideInTheWay()
        end
        if visible and not lounge.visible then
            hideInTheWay()
            room.putAwayAt = 0
            putAway()
        end
        lounge.loaded, lounge.visible = loaded, visible
    end)
    if not ok and loungeError ~= tostring(e) then
        loungeError = tostring(e)
        log("Casino: the lounge's level: %s", loungeError)
    end
end)
Casino.lounge = function() return lounge, hold end

local function nearClub()
    local player = World.player()
    if not player then return false end
    local l = player:K2_GetActorLocation()
    return math.abs(l.X - 14900) < 7000 and math.abs(l.Y + 8300) < 7000
end

local function ensureRoom()
    local player = World.player()
    if not player then return end
    if room and (room.owner ~= player:GetAddress() or not valid(room.actors[1])) then
        room = nil      -- another world: its actors went with it
    end
    if not room and nearClub() then
        local ok, e = xpcall(buildRoom, debug.traceback)
        if not ok then
            log("Casino: could not set up the card room: %s", tostring(e))
            clearRoom()
        end
    end
end

---------------------------------------------------------------- the club's door

-- The game opens the club's doors from 20:00 to 05:00, but keeps an unseen barrier and a
-- bodyguard in the doorway for everybody who is not on La Ballena's storyline. In a co-op
-- world the mod lets everybody in during those hours (always, with CardRoomAlwaysOpen),
-- and never shuts the club on a player who is still inside.
local opening = false

local function insideClub(player)
    local l = player:K2_GetActorLocation()
    return l.X > 14250 and l.X < 15620 and l.Y > -9100 and l.Y < -7650 and l.Z < 420
end

local function clubShouldBeOpen()
    local player = World.player()
    if not player or not active() then return false end
    if Core.config.CardRoomAlwaysOpen == true then return true end
    local hour = 12
    pcall(function() hour = Core.find("dayTimeControler_C").curHour end)
    if hour >= 20 or hour < 5 then return true end
    return insideClub(player)
end

---------------------------------------------------------------- the club's music

-- The club has one speaker (ballenaClubManager.music) on which the game loops a single
-- track. In a shared world it plays the whole ambient soundtrack instead, one track after
-- another in random order. The host picks, so that everybody at the table hears the same
-- song; each game plays it on its own speaker, and only while its player is in the club.
local MUSIC = "/Game/Audio/Music/MuzykaOtoczenia/"
local TRACKS = {
    "BallenaClub/artlistBallenaBlues-bruiser", "BallenaClub/artlistBallenaBones", "BallenaClub/artlistBallenaCrankshaft",
    "BallenaClub/artlistBallenaDouble-espresso", "BallenaClub/artlistBallenaFeeling-mean", "BallenaClub/artlistBallenaIt-aint-cheap-being-poor",
    "BallenaClub/artlistBallenaIt-blows-my-mind", "BallenaClub/artlistBallenaRuby-blues", "BallenaClub/artlistBallenaSwampy",
    "BallenaClub/artlistBallenaThe-other-side-of-wrong", "BallenaClub/artlistBallenaThe-outsider", "Dark/artlistDarkBreakthrough",
    "Dark/artlistDarkEyes-closed", "Dark/artlistDarkGotta-eat-no-sleep", "Dark/artlistDarkGrind",
    "Dark/artlistDarkMake-my-move", "Dark/artlistDarkNightime-manuveurs", "Dark/artlistDarkOmf",
    "Dark/artlistDarkPoppin-really", "Dark/artlistDarkTake-it-to-the-limit", "Dark/artlistDarkTerra",
    "Dark/artlistDarkVanglorius", "Dark/artlistDarkWhat-you-want", "Medium/artlistMediumchillBack-then",
    "Medium/artlistMediumchillBrujita", "Medium/artlistMediumchillOnce-again", "Medium/artlistMediumchillOpen-house",
    "Medium/artlistMediumchillRetrospect", "Medium/artlistMediumchillSidez", "Medium/artlistMediumchillSlavin",
    "Medium/artlistMediumcommercialAll-i-do", "Medium/artlistMediumcommercialCoke-and-patron", "Medium/artlistMediumcommercialDevils-in-my-dm",
    "Medium/artlistMediumcommercialGo", "Medium/artlistMediumcommercialOn-top", "Medium/artlistMediumtrapGo-get-the-money",
    "Medium/artlistMediumtrapMinutes", "Medium/artlistMediumtrapNon-stop", "Medium/artlistMediumtrapNotice-now",
    "Medium/artlistMediumtrapOdmfw", "Medium/artlistMediumtrapPhew", "Medium/artlistMediumtrapPicture-this-ponder-that",
    "Medium/artlistMediumtrapStigmata", "Medium/artlistMediumtrapThats-a-bet", "Medium/artlistMediumtrapWorship",
    "Oldschool/artlistOldschoolGold-chain", "Oldschool/artlistOldschoolHere-we-go", "Oldschool/artlistOldschoolLiquid",
    "Oldschool/artlistOldschoolMichrophone-fiend", "Oldschool/artlistOldschoolRemember-when", "Oldschool/artlistOldschoolStandoffish",
    "Oldschool/artlistOldschoolThings-end", "Oldschool/artlistOldschoolThought", "Oldschool/artlistOldschoolToxic",
    "TwoTowers/DDS_Psst_Police", "TwoTowers/HardcoreDrugs", "TwoTowers/HardcoreHard-CoCo",
    "TwoTowers/HardcoreHard_01_KosmaDDS", "TwoTowers/HardcoreHard_02_KosmaDDS", "TwoTowers/HardcoreHard_04_KosmaDDS",
    "TwoTowers/HardcoreHard_05_KosmaDDS", "TwoTowers/HardcoreHard_10_KosmaDDS", "TwoTowers/HardcoreMedium_01_KosmaDDS",
    "TwoTowers/HardcoreMedium_02_KosmaDDS", "TwoTowers/HardcoreMedium_03_KosmaDDS", "TwoTowers/HardcoreMedium_08_KosmaDDS",
    "TwoTowers/HardcoreMedium_09_KosmaDDS",
}
local dj = { index = nil, startedAt = 0, length = 0, playing = nil }

local function clubSpeaker()
    local speaker = nil
    pcall(function()
        local manager = Core.find("ballenaClubManager_C")
        if manager and valid(manager.music) and valid(manager.music.AudioComponent) then speaker = manager.music.AudioComponent end
    end)
    return speaker
end

local function track(i)
    local name = TRACKS[i]
    if not name then return nil end
    local path = MUSIC .. name .. "." .. name:match("[^/]+$")
    local wave = StaticFindObject(path)
    if valid(wave) then return wave end
    pcall(function() LoadAsset(MUSIC .. name) end)
    wave = StaticFindObject(path)
    if valid(wave) then return wave end
    return nil
end

-- Starts the current track on our speaker, `offset` seconds in.
local function playTrack(offset)
    local speaker, wave = clubSpeaker(), track(dj.index)
    if not speaker or not wave then return end
    speaker:SetSound(wave)
    speaker:Play(math.max(0, offset or 0))
    dj.playing = dj.index
end

local function tellTrack(target)
    local data = { i = dj.index, e = math.floor(os.clock() - dj.startedAt) }
    if target then
        Net.send("dj", data, target)
    else
        for _, id in ipairs(World.targets()) do Net.send("dj", data, id) end
    end
end

Core.every(1, function()
    if not live() or not active() or not World.player() then return end
    local now = os.clock()
    if World.role ~= "guest" and (not dj.index or now >= dj.startedAt + dj.length) then
        local pick = math.random(#TRACKS)
        if pick == dj.index then pick = pick % #TRACKS + 1 end
        local wave = track(pick)
        local length = 180
        pcall(function() if wave and wave.Duration > 10 then length = wave.Duration end end)
        dj.index, dj.startedAt, dj.length = pick, now, length - 1
        tellTrack()
    end
    if not dj.index then return end
    local inside = false
    pcall(function() inside = insideClub(World.player()) end)
    if not inside then
        dj.playing = nil          -- coming back in, the track is picked up where it is by then
    elseif dj.playing ~= dj.index then
        local ok, e = pcall(playTrack, now - dj.startedAt)
        if not ok then log("Casino: the club's music: %s", tostring(e)) end
    end
end)

Net.on("dj", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) then return end
    local i, e = tonumber(data.i), tonumber(data.e) or 0
    if not i or not TRACKS[i] then return end
    dj.index, dj.startedAt, dj.playing = math.floor(i), os.clock() - e, nil
end)

World.listen("peer", function(id)
    if live() and World.role == "host" and dj.index then tellTrack(id) end
end)
World.listen("start", function() if live() then dj.index, dj.playing = nil, nil end end)
World.listen("stop", function() if live() then dj.index, dj.playing = nil, nil end end)

local function letIn(context)
    if opening or not live() then return end
    if not clubShouldBeOpen() then return end
    local manager = context:get()
    if not valid(manager) then return end
    opening = true
    pcall(function() manager:openClub(true) end)
    opening = false
end

local CLUB = "/Game/WorldControlers/Gangs/ballenaClubManager.ballenaClubManager_C"
Core.Hooks.add(CLUB .. ":openClub", function(context, allow)
    local allowed = false
    pcall(function() allowed = allow:get() == true end)
    if not allowed then letIn(context) end
end)
Core.Hooks.add(CLUB .. ":closeClub", function(context) letIn(context) end)

---------------------------------------------------------------- money

local function cash()
    local out = {}
    local ok = pcall(function() World.player():countAllMoney(out) end)
    if ok and type(out.allMoneyCount) == "number" then return out.allMoneyCount end
    return 0
end

-- Takes the stake out of the pockets. True only if the cash really went down by it.
local function take(amount)
    local before = cash()
    if before < amount then return false end
    local player = World.player()
    pcall(function() player:chargeMoney(amount, true) end)
    if cash() > before - amount then
        pcall(function() player.InventoryComponent:DrawInventoryMoney(amount, {}) end)
    end
    return cash() <= before - amount
end

-- Pays into the pockets; what does not fit goes to the bank account.
local function pay(amount)
    if amount <= 0 then return "" end
    local before = cash()
    pcall(function() World.player():addMoney(amount, true, {}) end)
    local missing = amount - (cash() - before)
    if missing <= 0 then return "" end
    local banked = false
    pcall(function()
        local computer = Core.find("mainComputer_C")
        computer.playerBankMoney = computer.playerBankMoney + missing
        banked = true
    end)
    if banked then return string.format("$%d went to your bank account: your pockets are full", missing) end
    log("Casino: could not pay out $%d", missing)
    return ""
end

---------------------------------------------------------------- cards

local seeded = false
local function draw()
    if not seeded then
        math.randomseed(os.time() + math.floor(os.clock() * 1000))
        seeded = true
    end
    return { rank = math.random(1, 13), suit = math.random(1, 4) }
end

local function total(hand)
    local sum, aces = 0, 0
    for _, c in ipairs(hand) do
        if c.rank == 1 then
            aces = aces + 1
            sum = sum + 11
        else
            sum = sum + math.min(c.rank, 10)
        end
    end
    while sum > 21 and aces > 0 do
        sum = sum - 10
        aces = aces - 1
    end
    return sum
end

local function natural(hand) return #hand == 2 and total(hand) == 21 end

Casino.total, Casino.natural = total, natural

---------------------------------------------------------------- telling the others

local function tell(text)
    if not World.shared() then return end
    for _, id in ipairs(World.targets()) do Net.send("csn", { x = text }, id) end
end

Net.on("csn", function(sender, data)
    if not live() then return end
    if not World.active or type(data.x) ~= "string" or #data.x > 80 then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= Net.S.owner then return end
    local who = sender
    if World.role == "guest" and data.p ~= nil then who = data.p end
    if who == Net.S.me then return end
    Hud.toast(Net.name(who) .. " " .. data.x, 5)
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= sender then Net.send("csn", { x = data.x, p = sender }, id) end
        end
    end
end)

---------------------------------------------------------------- cards on the felt

-- The other players' hands lie on the table in front of their seats, and the dealer's cards
-- in the middle, for everybody who is not looking at them on their own screen: a seated
-- player has their own hand and the dealer's large on screen instead. A card is a thin
-- white block with its rank on it (red for hearts and diamonds), lying the way it faces
-- its owner.
local felt = {}          -- seat index or "dealer" -> actors
local seatOf = {}        -- player id -> seat index (the others at the table)
local seat = nil         -- the seat we have taken: { place, index, owner, hud }
local announceRound = nil
local CARD_W, CARD_H, CARD_STEP = 9.0, 12.6, 9.8

local function clearFelt(key)
    if not World.gone then
        for _, a in ipairs(felt[key] or {}) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
    end
    felt[key] = nil
end

-- The direction in which we look at the table.
local function viewerYaw()
    if seat and seat.place then return seat.place.yaw end
    local l = World.player():K2_GetActorLocation()
    return math.deg(math.atan(TY - l.Y, TX - l.X))
end

-- A row of cards centred on (cx, cy), running across the direction `yaw`. A code is
-- rank * 10 + suit, 0 for a card lying face down.
local function layCards(key, codes, cx, cy, yaw)
    local player = World.player()
    if not player or not room or not room.mat then return end
    local world = player:GetWorld()
    local list = felt[key] or {}
    felt[key] = list
    local r = math.rad(yaw)
    local rx, ry = -math.sin(r), math.cos(r)
    local cube = asset("/Engine/BasicShapes/Cube.Cube")
    local facing = yaw
    for i, c in ipairs(codes) do
        local off = (i - (#codes + 1) / 2) * CARD_STEP
        local x, y, z = cx + rx * off, cy + ry * off, TOP + 0.5 + #list * 0.02
        local a = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw, Roll = 0 })
        list[#list + 1] = a
        a:SetMobility(2)
        a.StaticMeshComponent:SetStaticMesh(cube)
        a:SetActorScale3D({ X = CARD_H / 100, Y = CARD_W / 100, Z = 0.0012 })
        a:SetActorEnableCollision(false)
        local rank, suit = math.floor(c / 10), c % 10
        a.StaticMeshComponent:SetMaterial(0, c == 0 and room.mat.blue or room.mat.white)
        if c ~= 0 and RANKS[rank] then
            -- Made upright and laid flat afterwards: a text made lying down comes out tilted
            -- by the angle it was meant to be turned by (flat only when that angle is 0), and
            -- at the side seats most of each rank was under the card.
            local t = world:SpawnActor(StaticFindObject("/Script/Engine.TextRenderActor"), { X = x, Y = y, Z = z + 0.25 }, { Pitch = 0, Yaw = 0, Roll = 0 })
            t:K2_SetActorRotation({ Pitch = 90, Yaw = facing + 180, Roll = 0 }, false)
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

-- view: { h = { { codes }, ... } }
local function layFelt(index, view)
    clearFelt(index)
    local st = SEATS[index]
    if not view or not st then return end
    if seat and seat.index == index then return end      -- our own hand is on our screen
    local ok, e = pcall(function()
        local r = math.rad(st.yaw)
        local fx, fy, rx, ry = math.cos(r), math.sin(r), -math.sin(r), math.cos(r)
        local hands = view.h or {}
        for h, codes in ipairs(hands) do
            local side = (h - (#hands + 1) / 2) * (CARD_STEP * 2.3)
            layCards(index, codes, st.x + fx * 100 + rx * side, st.y + fy * 100 + ry * side, st.yaw)
        end
    end)
    if not ok then log("Casino: cards on the table: %s", tostring(e)) end
end

local function code(c) return c.rank * 10 + c.suit end

Net.on("tbl", function(sender, data)
    if not live() or not World.active then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= Net.S.owner then return end
    local who = sender
    if World.role == "guest" and data.p ~= nil then who = data.p end
    if who == Net.S.me then return end
    local index = tonumber(data.s) or 0
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= sender then Net.send("tbl", { s = data.s, v = data.v, p = sender }, id) end
        end
    end
    local before = seatOf[who]
    if before and before ~= index then clearFelt(before) end
    if not SEATS[index] then
        if before then clearFelt(before) end
        seatOf[who] = nil
        return
    end
    seatOf[who] = index
    if room then layFelt(index, type(data.v) == "table" and data.v or nil) end
    -- somebody new at the table hears where the round stands
    if not before and World.role == "host" and announceRound then pcall(announceRound) end
end)

---------------------------------------------------------------- the round: one dealer for the table

-- A round belongs to the table, not to a player. The host's game keeps it: when everybody
-- seated has bet (or a few seconds after the first bet) it deals the dealer's two cards and
-- every player who bet gets a hand; each plays their own hand at their own pace; when all
-- are finished the dealer turns the hidden card and draws once, and every hand is settled
-- against those same cards. Players' own cards are drawn by their own game.
local function me() return Net.S.me or "me" end
local function authority() return not World.shared() or World.role == "host" end
local function cardOf(c) return { rank = math.floor(c / 10), suit = c % 10 } end
local function cardsOf(codes)
    local out = {}
    for i, c in ipairs(codes or {}) do out[i] = cardOf(c) end
    return out
end

local round = { n = 0, phase = "bet", dealer = {}, into = {} }    -- what every game knows
local host = { bets = {}, done = {}, alive = false }               -- what only the host's game keeps

local g = nil          -- our own play: { state, bet, base, round, hands, active, shown, note, good }
local scr = nil        -- the screen
local shown = {}       -- widgets of the current picture
local render, onRound, reveal

local function layDealer()
    clearFelt("dealer")
    if Casino.seated then return end         -- seated, we have them on our screen
    if not room or not room.mat or round.phase == "bet" or #round.dealer == 0 then return end
    local codes = {}
    for i, c in ipairs(round.dealer) do codes[i] = (round.phase == "play" and i == 2) and 0 or c end
    layCards("dealer", codes, TX + 20, TY, 0)
end

local function sendRound()
    local into = {}
    for id in pairs(round.into) do into[#into + 1] = id end
    local left = host.startAt and math.max(0, math.ceil(host.startAt - os.clock())) or nil
    local data = { r = round.n, ph = round.phase, d = round.dealer, i = into, c = left, u = round.turn }
    if World.shared() then
        for _, id in ipairs(World.targets()) do Net.send("trd", data, id) end
    end
    onRound(data)
end

local function everybodyBet()
    local n = 0
    for id in pairs(seatOf) do
        n = n + 1
        if not host.bets[id] then return false end
    end
    if Casino.seated then
        n = n + 1
        if not host.bets[me()] then return false end
    end
    return n > 0
end

-- Players act one after the other, as at a real table: the seat furthest to the right
-- (seen from the players' side) first, then the next one to its left.
local TURN_RANK = { [3] = 1, [1] = 2, [2] = 3 }
local TURN_SECONDS = 60

-- Gives the turn to the next player who has not finished. False when nobody is left.
local function passTurn()
    for _, entry in ipairs(host.order or {}) do
        if not host.done[entry.id] then
            round.turn = entry.id
            host.turnUntil = os.clock() + TURN_SECONDS
            return true
        end
    end
    round.turn = nil
    return false
end

local function startRound()
    host.startAt = nil
    round.n = round.n + 1
    round.phase = "play"
    round.dealer = { code(draw()), code(draw()) }
    round.into = host.bets
    host.bets, host.done, host.alive = {}, {}, false
    host.order = {}
    for id in pairs(round.into) do
        local index = seatOf[id]
        if id == me() then index = seat and seat.index end
        host.order[#host.order + 1] = { id = id, rank = TURN_RANK[index or 0] or 9 }
    end
    table.sort(host.order, function(a, b) return a.rank < b.rank end)
    passTurn()
    sendRound()
    if natural(cardsOf(round.dealer)) then reveal() end       -- the dealer has blackjack: the round is over
end

reveal = function()
    if round.phase ~= "play" then return end
    round.phase, round.turn = "dealer", nil
    local hand = cardsOf(round.dealer)
    while host.alive and total(hand) < 17 do
        local c = draw()
        hand[#hand + 1] = c
        round.dealer[#round.dealer + 1] = code(c)
    end
    sendRound()
    local n = round.n
    Core.after(1 + #round.dealer * 0.7 + 4, function()
        if not live() or round.n ~= n then return end
        round.phase, round.into = "bet", {}
        if next(host.bets) then host.startAt = os.clock() + 6 end
        sendRound()
    end)
end

local function hostBet(id)
    host.bets[id] = true
    if round.phase ~= "bet" then return end
    if everybodyBet() then
        startRound()
    else
        host.startAt = host.startAt or (os.clock() + 8)
        sendRound()
    end
end

local function hostDone(id, alive)
    if round.phase ~= "play" or not round.into[id] then return end
    host.done[id] = true
    if alive then host.alive = true end
    if round.turn == id or round.turn == nil or host.done[round.turn] then
        if not passTurn() then return reveal() end
    end
    sendRound()
end

local function hostGone(id)
    host.bets[id] = nil
    if round.phase == "play" and round.into[id] then hostDone(id, false) end
end

Core.every(0.5, function()
    if not live() or not authority() or not active() then return end
    -- players who got up
    for id in pairs(round.into) do
        if id ~= me() and not seatOf[id] and not host.done[id] then hostGone(id) end
    end
    for id in pairs(host.bets) do
        if id ~= me() and not seatOf[id] then host.bets[id] = nil end
    end
    if round.phase == "bet" and host.startAt then
        if not next(host.bets) then
            host.startAt = nil
        elseif os.clock() >= host.startAt or everybodyBet() then
            startRound()
        else
            sendRound()         -- the countdown
        end
    elseif round.phase == "play" and round.turn and os.clock() > (host.turnUntil or 0) then
        hostDone(round.turn, true)      -- took too long: the hand stands as it is
    end
end)

Net.on("tbt", function(sender, data)
    if not live() or World.role ~= "host" or not World.inWorld[sender] then return end
    if data.a == "bet" then hostBet(sender)
    elseif data.a == "done" then hostDone(sender, data.alive == true)
    elseif data.a == "gone" then hostGone(sender) end
end)

Net.on("trd", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= Net.S.owner then return end
    if type(data.d) ~= "table" or type(data.i) ~= "table" then return end
    onRound(data)
end)

local function toHost(action, alive)
    if authority() then
        if action == "bet" then hostBet(me())
        elseif action == "done" then hostDone(me(), alive)
        else hostGone(me()) end
    else
        Net.send("tbt", { a = action, alive = alive }, Net.S.owner)
    end
end

---------------------------------------------------------------- the table screen

local INK = { R = 0.03, G = 0.03, B = 0.03, A = 1 }
local CARD_RED = { R = 0.72, G = 0.03, B = 0.03, A = 1 }
local PAPER = { R = 0.93, G = 0.92, B = 0.88, A = 1 }

local function bets()
    local list = Core.config.CasinoBets
    if type(list) ~= "table" or #list == 0 then list = DEFAULT_BETS end
    return list
end

-- Our hand, on the felt and for the others.
local function publish()
    if not seat then return end
    local view = false
    if g and g.hands then
        view = { h = {}, a = g.active }
        for h, hand in ipairs(g.hands) do
            view.h[h] = {}
            for i, c in ipairs(hand.cards) do view.h[h][i] = code(c) end
        end
    end
    layFelt(seat.index, view or nil)
    if World.shared() then
        for _, id in ipairs(World.targets()) do Net.send("tbl", { s = g and seat.index or 0, v = view }, id) end
    end
end

local function card(c, width, faceDown)
    local face
    if faceDown then
        face = scr.box({ R = 0.05, G = 0.1, B = 0.42, A = 1 }, scr.box({ R = 0.1, G = 0.2, B = 0.62, A = 1 }), 6)
    else
        local ink = (c.suit == 2 or c.suit == 3) and CARD_RED or INK
        local column = scr.new("VerticalBox")
        column:AddChildToVerticalBox(scr.text(RANKS[c.rank], "hud", width * 0.25, ink))
        column:AddChildToVerticalBox(scr.text(SUITS[c.suit], "hud", width * 0.2, ink))
        local big = column:AddChildToVerticalBox(scr.text(SUITS[c.suit], "hud", width * 0.4, ink))
        big:SetHorizontalAlignment(2)
        face = scr.box(PAPER, column)
        face:SetPadding({ Left = 7, Top = 2, Right = 7, Bottom = 2 })
    end
    return scr.sized(scr.box({ R = 0.04, G = 0.04, B = 0.04, A = 1 }, face, 2), width, width * 1.4)
end

local function put(widget, ax, ay, x, y)
    scr.place(widget, ax, ay, x, y)
    shown[#shown + 1] = widget
    return widget
end

local function button(label, scale, ax, ay, x, y, fn)
    local b = scr.button(label, scale, fn)
    put(b.widget, ax, ay, x, y)
    return b
end

local function staked()
    local sum = 0
    for _, hand in ipairs(g.hands or {}) do sum = sum + hand.bet end
    if sum == 0 and g.state == "ready" then sum = g.bet or 0 end
    return sum
end

-- Back to betting: the cards go, the outcome stays as one line until the next bet.
local function clearHand()
    g.last, g.lastGood = g.note, g.good
    g.state, g.hands, g.final = "bet", nil, nil
end

local function finish(note, paid, good)
    local extra = pay(paid)
    g.state, g.note, g.good = "done", note, good
    if extra ~= "" then Hud.toast(extra, 6) end
    render()
    local game, n = g, g.round
    Core.after(5, function()
        if g ~= game or not live() or g.state ~= "done" or g.round ~= n then return end
        clearHand()
        render()
    end)
end

-- Every hand of ours against the dealer's cards.
local function settleNow(dealer)
    local house, houseNatural = total(dealer), natural(dealer)
    local paid, notes, big = 0, {}, false
    for h, hand in ipairs(g.hands) do
        local mine = total(hand.cards)
        local mineNatural = #g.hands == 1 and not g.wasSplit and natural(hand.cards)
        local name = #g.hands > 1 and ("HAND " .. h .. ":  ") or ""
        if mine > 21 then
            notes[#notes + 1] = name .. string.format("BUST, YOU LOSE $%d", hand.bet)
        elseif mineNatural and not houseNatural then
            local win = math.floor(hand.bet * 1.5)
            paid = paid + hand.bet + win
            big = true
            notes[#notes + 1] = string.format("BLACKJACK!  YOU WIN $%d", win)
        elseif houseNatural and not mineNatural then
            notes[#notes + 1] = name .. string.format("DEALER HAS BLACKJACK, YOU LOSE $%d", hand.bet)
        elseif house > 21 or mine > house then
            paid = paid + hand.bet * 2
            notes[#notes + 1] = name .. (house > 21 and "DEALER BUSTS, " or "") .. string.format("YOU WIN $%d", hand.bet)
        elseif mine == house then
            paid = paid + hand.bet
            notes[#notes + 1] = name .. "PUSH"
        else
            notes[#notes + 1] = name .. string.format("DEALER WINS, YOU LOSE $%d", hand.bet)
        end
    end
    local net = paid - staked()
    if big then tell(string.format("hit a blackjack for $%d", net))
    elseif net >= 500 then tell(string.format("won $%d at blackjack", net)) end
    local good = nil
    if net > 0 then good = true elseif net < 0 then good = false end
    g.final = dealer
    finish(table.concat(notes, "      "), paid, good)
end

-- The dealer's cards are turned one at a time, then our hands are settled.
local function showdown()
    g.state, g.shown = "showdown", 1
    local game, n = g, round.n
    local final = cardsOf(round.dealer)
    local function step()
        if g ~= game or not live() or g.state ~= "showdown" then return end
        if g.shown < #final then
            g.shown = g.shown + 1
            render()
            Core.after(0.7, step)
        else
            settleNow(final)
        end
    end
    render()
    Core.after(0.8, step)
end

local function handsDone()
    g.state = "waiting"
    local alive = false
    for _, hand in ipairs(g.hands) do if total(hand.cards) <= 21 then alive = true end end
    render()
    toHost("done", alive)
end

-- On to the next hand (after a split), or we are finished and wait for the dealer.
local function advance()
    g.active = g.active + 1
    local hand = g.hands[g.active]
    if not hand then
        g.active = #g.hands
        return handsDone()
    end
    if total(hand.cards) >= 21 then return advance() end
    render()
end

local function placeBet(bet)
    if not take(bet) then
        Hud.toast(string.format("You need $%d in cash for this bet", bet), 3)
        g.state = "bet"
        render()
        return
    end
    g.state, g.bet, g.base, g.note, g.hands, g.final, g.last = "ready", bet, bet, nil, nil, nil, nil
    render()
    toHost("bet")
end

local function dealMine()
    g.round, g.state, g.active, g.wasSplit = round.n, "play", 1, false
    g.hands = { { cards = { draw(), draw() }, bet = g.bet } }
    if natural(g.hands[1].cards) then
        handsDone()
    else
        render()
    end
end

local function myTurn() return round.phase == "play" and round.turn == me() end

local function hit()
    if not g or g.state ~= "play" or not myTurn() then return end
    local hand = g.hands[g.active]
    hand.cards[#hand.cards + 1] = draw()
    if total(hand.cards) >= 21 then advance() else render() end
end

local function stand()
    if g and g.state == "play" and myTurn() then advance() end
end

local function double()
    if not g or g.state ~= "play" or not myTurn() then return end
    local hand = g.hands[g.active]
    if #hand.cards ~= 2 then return end
    if not take(hand.bet) then
        Hud.toast("Not enough cash to double", 3)
        return
    end
    hand.bet = hand.bet * 2
    hand.cards[#hand.cards + 1] = draw()
    advance()
end

-- A pair (two cards of the same value) can be split into two hands, each with its own bet,
-- and a pair dealt to one of those again, up to four hands. A 21 on a split hand is 21, not
-- a blackjack.
local MAX_HANDS = 4

local function canSplit()
    if not g or g.state ~= "play" or #g.hands >= MAX_HANDS then return false end
    local hand = g.hands[g.active]
    local c = hand and hand.cards or {}
    return #c == 2 and math.min(c[1].rank, 10) == math.min(c[2].rank, 10)
end

local function split()
    if not canSplit() or not myTurn() then return end
    local hand = g.hands[g.active]
    if not take(hand.bet) then
        Hud.toast("Not enough cash to split", 3)
        return
    end
    g.hands[g.active] = { cards = { hand.cards[1], draw() }, bet = hand.bet }
    table.insert(g.hands, g.active + 1, { cards = { hand.cards[2], draw() }, bet = hand.bet })
    g.wasSplit = true
    g.active = g.active - 1
    advance()
end

-- News of the round (from the host's game, or our own when we are the host).
onRound = function(data)
    if not authority() then
        local into = {}
        for _, id in ipairs(data.i) do into[id] = true end
        round = { n = tonumber(data.r) or 0, phase = tostring(data.ph), dealer = data.d, into = into, turn = data.u }
    end
    round.left = tonumber(data.c)
    pcall(layDealer)
    if not g then return end
    if round.phase == "play" and round.into[me()] and g.state == "ready" then
        dealMine()
    elseif round.phase == "dealer" and g.round == round.n and (g.state == "play" or g.state == "waiting") then
        showdown()
    elseif round.phase == "play" and g.state == "done" and g.round ~= round.n then
        clearHand()
        render()
    else
        render()
    end
end

render = function()
    if not scr or not scr.open or not g then return end
    scr.removeAll(shown)
    shown = {}
    local money = cash()
    put(scr.text(string.format("CASH  $%d", money), "button", 18), 0.86, 0.47)
    if g.state ~= "bet" then put(scr.text(string.format("BET  $%d", staked()), "price", 24, Screen.GREEN), 0.86, 0.52) end

    -- the dealer's cards: the round's, or the ones our last hand was settled against
    local dealer, hide, upTo = nil, false, nil
    if g.state == "done" and g.final then
        dealer = g.final
    elseif g.hands and g.round == round.n and #round.dealer > 0 then
        dealer = cardsOf(round.dealer)
        if g.state == "showdown" then upTo = g.shown else hide = true end
    elseif round.phase ~= "bet" and #round.dealer > 0 then
        dealer = cardsOf(round.dealer)      -- a round we are not in
        hide = round.phase == "play"
    end
    if dealer then
        local count = upTo and math.max(upTo, 2) or #dealer
        for i = 1, count do
            local down = (hide and i == 2) or (upTo ~= nil and i > upTo)
            put(card(dealer[i], 84, down), 0.5, 0.55, (i - (count + 1) / 2) * 96, 0)
        end
        local known = {}
        for i = 1, count do
            if not ((hide and i == 2) or (upTo ~= nil and i > upTo)) then known[#known + 1] = dealer[i] end
        end
        put(scr.text(string.format("DEALER  %d", total(known)), "button", 18), 0.5, 0.435)
    end

    if g.state == "bet" then
        local waiting = round.phase ~= "bet"
        put(scr.text(waiting and "PLACE YOUR BET FOR THE NEXT ROUND" or "PLACE YOUR BET", "button", waiting and 24 or 30), 0.5, 0.66)
        if g.last then
            local color = g.lastGood == true and Screen.GREEN or (g.lastGood == false and Screen.RED or Screen.WHITE)
            put(scr.text(g.last, "button", 17, color), 0.5, 0.33)
        end
        -- somebody has bet already: how long the others have left to join this round
        if not waiting and round.left then
            put(scr.text(string.format("THE ROUND STARTS IN %d", round.left), "button", 26, Screen.RED), 0.5, 0.585)
        end
        local list = bets()
        for i, b in ipairs(list) do
            local btn = button(string.format("$%d", b), 1.7, 0.5, 0.76, (i - (#list + 1) / 2) * 150, 0, function() placeBet(b) end)
            if money < b then scr.enable(btn, false) end
        end
    elseif g.state == "ready" then
        local line = "WAITING FOR THE DEAL"
        if round.phase ~= "bet" then line = "ROUND IN PROGRESS.  YOU ARE IN THE NEXT ONE"
        elseif round.left then line = string.format("THE ROUND STARTS IN %d", round.left) end
        put(scr.text(line, "button", 26), 0.5, 0.7)
    elseif g.hands then
        local n = #g.hands
        local two = n > 1
        local spacing = ({ 0, 460, 330, 250 })[n] or 250
        local width = ({ 120, 96, 80, 66 })[n] or 66
        for h, hand in ipairs(g.hands) do
            local centre = (h - (n + 1) / 2) * spacing
            local step = width + 12
            if two and #hand.cards > 1 then step = math.min(width + 10, (spacing - 16 - width) / (#hand.cards - 1)) end
            for i, c in ipairs(hand.cards) do
                put(card(c, width), 0.5, 0.82, centre + (i - (#hand.cards + 1) / 2) * step, 0)
            end
            local mine = g.state == "play" and h == g.active
            local label = (two and ("HAND " .. h .. "   ") or "YOU   ") .. total(hand.cards)
            put(scr.text(label, "button", two and 18 or 22, (two and mine) and Screen.GREEN or Screen.WHITE), 0.5, 0.665, centre, 0)
        end
    end

    -- Whose turn it is has to be seen at a glance from any seat: twice the size of the rest.
    local TURN_SIZE = 46
    local function turnName()
        if not round.turn then return "THE DEALER" end
        return tostring(Net.name(round.turn)):upper()
    end
    if g.state == "play" and not myTurn() then
        put(scr.text("WAITING FOR " .. turnName(), "button", TURN_SIZE), 0.5, 0.325)
    elseif g.state == "play" then
        local hand = g.hands[g.active]
        put(scr.text("YOUR TURN", "button", TURN_SIZE, Screen.GREEN), 0.5, 0.325)
        button("HIT", 1.7, 0.86, 0.6, 0, 0, hit)
        button("STAND", 1.7, 0.86, 0.675, 0, 0, stand)
        local d = button(string.format("DOUBLE  ($%d)", hand.bet), 1.7, 0.86, 0.75, 0, 0, double)
        if #hand.cards ~= 2 or money < hand.bet then scr.enable(d, false) end
        local s = button(string.format("SPLIT  ($%d)", hand.bet), 1.7, 0.86, 0.825, 0, 0, split)
        if not canSplit() or money < hand.bet then scr.enable(s, false) end
    elseif g.state == "waiting" then
        put(scr.text("WAITING FOR " .. turnName(), "button", TURN_SIZE), 0.5, 0.325)
    elseif g.state == "done" then
        local color = g.good == true and Screen.GREEN or (g.good == false and Screen.RED or Screen.WHITE)
        put(scr.text(g.note or "", "button", ({ 30, 22, 17, 14 })[#g.hands] or 14, color), 0.5, 0.33)
        if round.phase == "bet" and round.left then
            put(scr.text(string.format("THE ROUND STARTS IN %d", round.left), "button", 26, Screen.RED), 0.5, 0.4)
        end
        local again = button(string.format("BET AGAIN  ($%d)", g.base), 1.7, 0.86, 0.62, 0, 0, function() placeBet(g.base) end)
        if money < g.base then scr.enable(again, false) end
        button("CHANGE BET", 1.7, 0.86, 0.7, 0, 0, function()
            g.state, g.hands, g.final = "bet", nil, nil
            render()
        end)
    end
    if g.state ~= "showdown" then button("LEAVE TABLE", 1.4, 0.86, 0.93, 0, 0, function() Casino.leave() end) end
    publish()
end

-- Getting up: a bet that was not dealt comes back; a hand in play is stood on and settled
-- against the dealer's two cards and whatever our own game draws for the dealer.
local function cashOut()
    if not g then return end
    if g.state == "ready" then
        pay(g.bet)
    elseif g.state == "play" or g.state == "waiting" or g.state == "showdown" then
        local dealer = cardsOf(round.dealer)
        local alive = false
        for _, hand in ipairs(g.hands) do if total(hand.cards) <= 21 then alive = true end end
        if round.phase == "play" then
            while alive and total(dealer) < 17 do dealer[#dealer + 1] = draw() end
        end
        pcall(settleNow, dealer)
        if g.note then Hud.toast(g.note, 5) end
    end
    toHost("gone")
end

announceRound = sendRound
Casino.layDealer = layDealer
Casino.layFelt = layFelt
Casino.music = function() return dj end
Casino.refresh = function() render() end
Casino.round = function() return round end

---------------------------------------------------------------- sitting down and getting up

local function nearTable()
    local player = World.player()
    if not player or not active() then return false end
    local l = player:K2_GetActorLocation()
    local dx, dy = l.X - (TX - 60), l.Y - TY
    return dx * dx + dy * dy < 400 * 400 and math.abs(l.Z - (FLOOR + 90)) < 160
end

-- The free seat for the player: the one they look at (the free seat least off their view,
-- if that is within 25 degrees), otherwise the nearest. So a seat can be picked by looking
-- at it from wherever the lounge's furniture lets one stand. A seat is taken when another
-- player is on it.
local function freeSeat()
    local player = World.player()
    local l = player:K2_GetActorLocation()
    local view = nil
    pcall(function() view = player:GetController():GetControlRotation().Yaw end)
    local near, nearD, nearIndex = nil, nil, nil
    local seen, seenOff, seenIndex = nil, nil, nil
    for index, st in ipairs(SEATS) do
        local taken = false
        for _, other in pairs(seatOf) do if other == index then taken = true end end
        for _, set in pairs(Avatar.puppets) do
            local p = set.player
            if p and (p.x - st.x) ^ 2 + (p.y - st.y) ^ 2 < 70 * 70 then taken = true end
        end
        if not taken then
            local d = (l.X - st.x) ^ 2 + (l.Y - st.y) ^ 2
            if not nearD or d < nearD then near, nearD, nearIndex = st, d, index end
            if view then
                local off = math.abs(((math.deg(math.atan(st.y - l.Y, st.x - l.X)) - view + 180) % 360) - 180)
                -- of two seats in line the nearer one: 40 units count like a degree
                local score = off + math.sqrt(d) / 40
                if off < 25 and (not seenOff or score < seenOff) then seen, seenOff, seenIndex = st, score, index end
            end
        end
    end
    if seen then return seen, seenIndex end
    return near, nearIndex
end

function Casino.enter()
    if Casino.seated then return true end
    local player = World.player()
    if not player or not active() then return false end
    ensureRoom()
    if not room then
        Hud.toast("The card room is closed", 3)
        return false
    end
    local place, index = freeSeat()
    if not place then
        Hud.toast("Every seat at the table is taken", 3)
        return false
    end
    seat = { place = place, index = index, owner = player:GetAddress() }
    pcall(function() seat.hud = player.HUD.Visibility end)
    scr = Screen.open()
    if not scr then
        Hud.toast("The card table could not be shown", 3)
        seat = nil
        return false
    end
    pcall(function()
        player:SetActorEnableCollision(false)
        player.CharacterMovement:SetMovementMode(5, 0)       -- flying: nothing pulls the seated player down
        player.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 }
        player:K2_SetActorLocation({ X = place.x, Y = place.y, Z = EYE }, false, {}, true)
        player:GetController():SetControlRotation({ Pitch = PITCH, Yaw = place.yaw, Roll = 0 })
    end)
    pcall(function() player.HUD:SetVisibility(1) end)
    Avatar.noEmoteView, Avatar.sendZ = true, SIT - EYE
    pcall(Avatar.setEmote, 3)
    Casino.seated = true
    scr.onClose = function() if Casino.seated then Casino.leave() end end
    g = { state = "bet" }
    shown = {}
    pcall(layDealer)
    render()
    return true
end

function Casino.leave()
    if not Casino.seated then return end
    Casino.seated = false
    pcall(cashOut)
    g = nil
    pcall(publish)          -- our cards leave the table
    local s = scr
    scr, shown = nil, {}
    if s then
        s.onClose = nil
        pcall(s.close)
    end
    local player = World.player()
    if player and seat and seat.owner == player:GetAddress() then
        pcall(function()
            -- standing behind the chair
            local r = math.rad(seat.place.yaw)
            player:K2_SetActorLocation({ X = seat.place.x - math.cos(r) * 75, Y = seat.place.y - math.sin(r) * 75, Z = FLOOR + 100 }, false, {}, true)
            player:SetActorEnableCollision(true)
            player.CharacterMovement:SetMovementMode(3, 0)
            player:GetController():ResetIgnoreLookInput()
        end)
        pcall(function() player.HUD:SetVisibility(seat.hud or 4) end)
        -- the lounge's furniture stays away for a moment (see the lounge's level above)
        local seconds = tonumber(Core.config.CardRoomStandUpSeconds) or 3
        if seconds > 0 then
            hold = { owner = player:GetAddress(), till = os.clock() + seconds }
            pcall(function()
                local level = loungeLevel(player)
                if level and level.bShouldBeVisible == true then level:SetShouldBeVisible(false) end
            end)
        end
    end
    Avatar.noEmoteView, Avatar.sendZ = nil, nil
    pcall(Avatar.setEmote, 0)
    seat = nil
    pcall(layDealer)
end

function Casino.state() return g end

-- The seated player stays put and looks at the table. Holding the left mouse button lets
-- them look around; letting go turns the view back.
local LMB = nil
local looking = false

local function turn(from, to, k)
    return from + (((to - from + 180) % 360) - 180) * k
end

Core.onTick(function()
    if not live() or not Casino.seated then return end
    local player = World.player()
    if not player or not seat or seat.owner ~= player:GetAddress() then
        Casino.seated, g, scr, seat = false, nil, nil, nil
        Avatar.noEmoteView, Avatar.sendZ = nil, nil
        return
    end
    pcall(function()
        local place = seat.place
        player:K2_SetActorLocation({ X = place.x, Y = place.y, Z = EYE }, false, {}, true)
        local pc = player:GetController()
        LMB = LMB or { KeyName = FName("LeftMouseButton") }
        local held = false
        pcall(function() held = pc:IsInputKeyDown(LMB) == true end)
        if held ~= looking then
            looking = held
            pc:SetIgnoreLookInput(not held)
        end
        if not held then
            local r = pc:GetControlRotation()
            local pitch = r.Pitch > 180 and r.Pitch - 360 or r.Pitch
            pc:SetControlRotation({ Pitch = turn(pitch, PITCH, 0.25), Yaw = turn(r.Yaw, place.yaw, 0.25), Roll = 0 })
        end
    end)
end)

-- The wardrobe key lets a player at the club's door go down to the table.
Look.takeover = {
    isOpen = function() return live() and Casino.seated end,
    near = function() return live() and nearTable() end,
    prompt = function()
        local index = nil
        pcall(function() local _, i = freeSeat() index = i end)
        return key("WardrobeKey"), index and ("Sit down, " .. SEAT_NAMES[index]) or "Sit down"
    end,
    toggle = function() if Casino.seated then Casino.leave() else Casino.enter() end end,
    move = function() end,
    choose = function() end,
}

-- In single player no "stop" comes when the world goes (back to the main menu, another
-- save loaded): a seat in a world that is gone is only forgotten. Its actors went with
-- it; nothing of them may be touched.
local function forgetGoneWorld()
    Casino.seated, g = false, nil
    local s = scr
    scr, shown = nil, {}
    if s then
        s.onClose = nil
        pcall(s.close)          -- (a screen whose world is gone is only forgotten, see screen.lua)
    end
    seat = nil
    Avatar.noEmoteView, Avatar.sendZ = nil, nil
    for key in pairs(felt) do felt[key] = nil end
    for id in pairs(seatOf) do seatOf[id] = nil end
end

local marker = nil
Core.every(1, function()
    if not live() then return end
    if seat and not World.active then
        local player = World.player()
        if not player or player:GetAddress() ~= seat.owner then forgetGoneWorld() end
    end
    if not World.player() or not active() then return end
    ensureRoom()
    if room then
        local l = World.player():K2_GetActorLocation()
        if math.abs(l.X - TX) < 2500 and math.abs(l.Y - TY) < 2500 and l.Z < 420 then pcall(putAway) end
    end
    -- The game only looks at the club's door now and then; near the club the mod does too.
    if nearClub() and clubShouldBeOpen() and not opening then
        pcall(function()
            local manager = Core.find("ballenaClubManager_C")
            if manager and manager.Box:GetCollisionEnabled() ~= 0 then
                opening = true
                pcall(function() manager:openClub(true) end)
                opening = false
            end
        end)
    end
    -- the cards of players who have left the world go off the table
    for id, index in pairs(seatOf) do
        if not Avatar.puppets[id] then
            clearFelt(index)
            seatOf[id] = nil
        end
    end
    if not Hud.ready() then return end
    if not marker or not Core.alive(marker) then
        marker = Hud.mapMarker("Card room", "Blackjack in the club's basement, from 8 pm", DOOR.x + 500, DOOR.y, DOOR.z, Hud.MARKER_PIN)
    end
end)

-- Now and then again, for players who came in later.
Core.every(4, function()
    if live() and Casino.seated and g then pcall(publish) end
end)

World.listen("stop", function()
    if not live() then return end
    if Casino.seated then pcall(Casino.leave) end
    for index in pairs(felt) do clearFelt(index) end
    for id in pairs(seatOf) do seatOf[id] = nil end
end)

-- For reloading the module while developing.
function Casino.shutdown()
    if Casino.seated then pcall(Casino.leave) end
    for index in pairs(felt) do clearFelt(index) end
    clearRoom()
    if marker then pcall(Hud.forgetMarker, marker) end
end

Casino.DOOR, Casino.SEAT, Casino.SEATS, Casino.TABLE = DOOR, SEAT, SEATS, { x = TX, y = TY, floor = FLOOR }
Casino.enterNearest, Casino.nearTable, Casino.clubShouldBeOpen = Casino.enter, nearTable, clubShouldBeOpen
Casino.freeSeat = freeSeat
return Casino
