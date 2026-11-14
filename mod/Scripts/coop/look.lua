-- Who you are in co-op: a character (a small set of strengths and weaknesses), and how
-- the others see you (outfit, face, hair).
--
-- The character and a first outfit, face and hair are chosen once, on the "who are you"
-- screen. New outfits and hats are bought at the clothes shop: a counter in the furniture
-- shop, marked on the map; purchases come out of the (shared) bank account. At a wardrobe
-- (the piece of furniture, in any hideout) the wardrobe key opens the same kind of screen
-- with what the player owns. A fugitive who changes clothes at a wardrobe, as the game has
-- it, really does: another outfit and hat of their own, picked at random.
-- Everything is kept in one file per player on that player's computer and applies in any
-- world, hosted or joined.
--
-- The game is first-person, so you do not see your own clothes: the other players do.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Hud = require("coop.hud")
local Screen = require("coop.screen")
local Thumbs = require("coop.thumbs")
local Clerk = require("coop.clerk")
local json = require("json")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Look = { page = nil, index = 1 }

local OUTFITS = {
    { id = "jacket", starter = true, name = "Yellow jacket", body = "SK_ma_casual_jacket_01_a", price = 200 },
    { id = "jacket2", name = "Dark jacket", body = "SK_ma_casual_jacket_01_b", price = 400 },
    { id = "shirt1", starter = true, name = "Shirt, rolled sleeves", body = "SK_ma_casual_02_a", price = 250 },
    { id = "shirt2", name = "Shirt, second cut", body = "SK_ma_casual_02_b", price = 250 },
    { id = "shirt3", name = "Shirt, third cut", body = "SK_ma_casual_02_c", price = 250 },
    { id = "track1", starter = true, name = "Tracksuit", body = "SK_ma_sport_01_a", price = 450 },
    { id = "track2", name = "Tracksuit, second colour", body = "SK_ma_sport_01_b", price = 500 },
    { id = "track3", name = "Tracksuit, third colour", body = "SK_ma_sport_01_c", price = 500 },
    { id = "work1", starter = true, name = "Work clothes", body = "SK_ma_construction_worker_01", price = 300 },
    { id = "work2", name = "Work clothes, second set", body = "SK_ma_construction_worker_01_c", price = 300 },
    { id = "waiter", name = "Waiter", body = "SK_ma_waiter_01", price = 900 },
    { id = "doctor", name = "Doctor's coat", body = "SK_ma_physician_01", price = 1200 },
    { id = "suit1", name = "Suit", body = "SK_ma_business_01", price = 2000 },
    { id = "suit2", name = "Suit, second cut", body = "SK_ma_business_01_b", price = 2000 },
}
local FACES = { "SK_ma_head_01", "SK_ma_head_02", "SK_ma_head_04_dark", "SK_ma_head_05_asian", "SK_ma_head_05_basian" }
local HAIR = {
    { name = "Short", mesh = "Hats_Hair/SK_ma_hair_02" }, { name = "Hair 2", mesh = "Hats_Hair/SK_ma_hair_01" },
    { name = "Hair 3", mesh = "Hats_Hair/SK_ma_hair_03" }, { name = "Hair 4", mesh = "Hats_Hair/SK_ma_hair_04" },
    { name = "Hair 5", mesh = "Hats_Hair/SK_ma_hair_05" }, { name = "Hair 6", mesh = "Hats_Hair/SK_ma_hair_06" },
    { name = "Cap", price = 300, mesh = "Hats_Hair/SK_ma_hat_cap_01" }, { name = "Cap, second", price = 300, mesh = "Hats_Hair/SK_ma_hat_cap_02" },
    { name = "Beanie", price = 200, mesh = "Hats_Hair/SK_ma_hat_casual_set_beanie_01" }, { name = "Flat cap", price = 600, mesh = "Hats_Hair/SK_ma_hat_flatcap_01" },
    { name = "Beret", price = 500, mesh = "Hats_Hair/SK_ma_hat_beret_01" }, { name = "Country hat", price = 1500, mesh = "Hats_Hair/SK_ma_hat_country_02" },
    { name = "Bald", mesh = "" },
}
-- Every number of every kind of character is in this list. stamina and speed multiply the
-- character's base values; seen multiplies how visible the player is to police (lower is
-- harder to spot); pockets adds pocket slots. The others are looked after by
-- coop/traits.lua: tagTime multiplies how long a wall tag takes, drugTime how long a drug
-- works and seenHigh how visible the player is while one does, freePick opens a lock for a
-- bobby pin without the lockpick game and pickHeat is what that counts as with the police
-- (a row of the game's ExpoEventsDatabase), once in every pickHeatEvery locks: the game's
-- list has no row milder than a police search, so half of one is one for every second lock.
local CHARACTERS = {
    { id = "hustler", name = "The Hustler", stamina = 1.0, speed = 1.0, seen = 1.0, pockets = 0 },
    { id = "runner", name = "The Runner", stamina = 1.25, speed = 1.1, seen = 1.12, pockets = 0 },
    { id = "ghost", name = "The Ghost", stamina = 0.8, speed = 1.0, seen = 0.85, pockets = 0 },
    { id = "tagger", name = "The Tagger", stamina = 1.0, speed = 1.0, seen = 1.0, pockets = -1, tagTime = 0.5 },
    { id = "lightweight", name = "The Lightweight", stamina = 1.0, speed = 1.0, seen = 1.0, pockets = 0, drugTime = 2, seenHigh = 1.2 },
    { id = "crook", name = "The Crook", stamina = 1.0, speed = 1.0, seen = 1.0, pockets = 0, freePick = true, pickHeat = "POLICE-SEARCH", pickHeatEvery = 2 },
}
-- Kinds that are gone, and what a player who was one is now.
local FORMER = { athlete = "runner", mule = "hustler" }
-- Goes up when the list changes so much that everybody should choose again: a player who
-- chose under an older list gets the "who are you" screen once more, with what they are
-- now already selected.
local ROSTER = 2
local CHARACTER_CHANGE_PRICE = 300
-- Donald's furniture shop at the Old Market (where the game's own shop actor stands).
local SHOP = { x = -1495, y = -12945, z = 110, reach = 600 }

local byId, bodyAllowed, faceAllowed, hairAllowed = {}, {}, {}, { [""] = true }
for _, o in ipairs(OUTFITS) do byId[o.id] = o; bodyAllowed[o.body] = true end
for _, f in ipairs(FACES) do faceAllowed[f] = true end
for _, h in ipairs(HAIR) do hairAllowed[h.mesh] = true end
local characterById = {}
for _, c in ipairs(CHARACTERS) do characterById[c.id] = c end

local state = { outfit = "jacket", face = 1, hair = 1, character = "hustler", owned = { jacket = true }, ownedHair = {}, characterPicked = false, roster = ROSTER }
local loaded = false
local applyingTraits = false

---------------------------------------------------------------- the player's file

local function filePath()
    local base = os.getenv("LOCALAPPDATA")
    local dir = base and (base:gsub("\\", "/") .. "/DrugDealerSimulator/Saved/SaveGames") or Core.MOD_DIR
    return string.format("%s/ddsmp_player%s.json", dir, Core.instance and ("_" .. Core.instance) or "")
end

local function load()
    if loaded then return end
    loaded = true
    local f = io.open(filePath(), "rb")
    if not f then return end
    local text = f:read("a")
    f:close()
    local ok, data = pcall(json.decode, text)
    if not ok or type(data) ~= "table" then return end
    if byId[data.outfit] then state.outfit = data.outfit end
    if FACES[tonumber(data.face) or 0] then state.face = tonumber(data.face) end
    if HAIR[tonumber(data.hair) or 0] then state.hair = tonumber(data.hair) end
    local kind = FORMER[data.character] or data.character
    if characterById[kind] then state.character = kind end
    state.characterPicked = data.characterPicked == true
    state.roster = tonumber(data.roster) or 1
    state.forced = math.max(0, math.floor(tonumber(data.forced) or 0))
    if state.characterPicked and state.roster < ROSTER then
        -- (A test copy started with -ddsmp=NAME keeps its choice: nobody is there to answer.)
        if Core.instance and not Look.debug then state.roster = ROSTER else state.characterPicked = false end
    end
    if type(data.owned) == "table" then
        for id, v in pairs(data.owned) do
            if byId[id] and v == true then state.owned[id] = true end
        end
    end
    state.owned[state.outfit] = true
    if type(data.ownedHair) == "table" then
        for id, v in pairs(data.ownedHair) do
            if HAIR[tonumber(id) or 0] and v == true then state.ownedHair[tostring(id)] = true end
        end
    end
    if HAIR[state.hair].price then state.ownedHair[tostring(state.hair)] = true end
end

local function save()
    local ok, text = pcall(json.encode, state)
    if not ok then return end
    local f = io.open(filePath(), "wb")
    if not f then
        log("Cannot write %s", filePath())
        return
    end
    f:write(text)
    f:close()
end

---------------------------------------------------------------- how the others see us

function Look.current()
    load()
    return { body = byId[state.outfit].body, head = FACES[state.face], hair = HAIR[state.hair].mesh, arms = true }
end

local function describe(owner)
    local l = Look.current()
    return { b = l.body, h = l.head, r = l.hair, p = owner }
end

-- Tells the other players in the world how we look.
function Look.announce(target)
    if not World.shared() then return end
    local data = describe(nil)
    if target then
        Net.send("look", data, target)
    else
        for _, id in ipairs(World.targets()) do Net.send("look", data, id) end
    end
end

Net.on("look", function(sender, data)
    if not World.active then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= Net.S.owner then return end
    -- A guest hears about the other guests through the host.
    local who = sender
    if World.role == "guest" and data.p ~= nil then who = data.p end
    if who == Net.S.me then return end
    local body, head, hair = tostring(data.b), tostring(data.h), tostring(data.r or "")
    if not bodyAllowed[body] or not faceAllowed[head] or not hairAllowed[hair] then return end
    Avatar.setLook(who, { body = "" .. body, head = head, hair = hair, arms = true })
    vlog("Look: %s wears %s", Net.name(who), body)
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= sender then Net.send("look", { b = body, h = head, r = hair, p = sender }, id) end
        end
    end
end)

---------------------------------------------------------------- character traits

local function character()
    load()
    return characterById[state.character] or CHARACTERS[1]
end

Look.character = character

local function afterSkills(player)
    local c = character()
    local seen = c.seen
    -- coop/traits.lua: more visible for a while (a drug is working)
    if Look.seenNow then
        local ok, factor = pcall(Look.seenNow, c)
        if ok and type(factor) == "number" then seen = seen * factor end
    end
    pcall(function() player.skillStealthMultiplier = player.skillStealthMultiplier * seen end)
end

-- The highest pocket that holds something (-1: all are empty).
local function highestPocket(player)
    local top = -1
    pcall(function()
        player.InventoryComponent.ItemPocketIndex:ForEach(function(_, v)
            local i = tonumber(v:get())
            if i and i > top then top = i end
        end)
    end)
    return top
end

-- How many pockets the character starts from. A kind with fewer pockets does not make
-- anything disappear: the game simply stops showing a pocket that is beyond the count,
-- with what is in it. So a pocket that would go stays for as long as something is in it.
-- Returns the number and how many of them are only there for that reason.
local function pocketBase(player, defaults, c)
    local want = defaults.basePocketCount + c.pockets
    local fromSkill = 0
    pcall(function() fromSkill = math.floor(Core.find("statisticsManager_C").skillLevelPockets / 25 + 0.5) end)
    local need = math.min(highestPocket(player) + 1 - fromSkill, defaults.basePocketCount + 1)
    if need > want then return need, need - want end
    return want, 0
end

Look.pocketsKept = 0

-- Sets the character's base values from the game's defaults and lets the game work out
-- the rest (skills add to these as usual).
function Look.applyTraits()
    local player = World.player()
    if not player then return false end
    local defaults = StaticFindObject("/Game/Player/playerCharacterBP.Default__playerCharacterBP_C")
    if not valid(defaults) then return false end
    local c = character()
    local ok, e = pcall(function()
        player.staminaMaxBase = defaults.staminaMaxBase * c.stamina
        player.baseMaxWalkSpeed = defaults.baseMaxWalkSpeed * c.speed
        player.basePocketCount, Look.pocketsKept = pocketBase(player, defaults, c)
        applyingTraits = true
        player:updateSkillAbilities()
        applyingTraits = false
        afterSkills(player)
    end)
    applyingTraits = false
    if not ok then log("Character traits could not be applied: %s", tostring(e)) end
    return ok
end

-- The game recalculates when a skill is bought; our share goes back on top.
Core.Hooks.add("/Game/Player/playerCharacterBP.playerCharacterBP_C:updateSkillAbilities", function(ctx)
    if applyingTraits then return end
    local player = ctx:get()
    if valid(player) then afterSkills(player) end
end)

---------------------------------------------------------------- the shop

local function bank()
    local computer = Core.find("mainComputer_C")
    local ok, money = pcall(function() return computer.playerBankMoney end)
    if ok and type(money) == "number" then return money, computer end
    return 0, nil
end

local function pay(price)
    if price <= 0 then return true end
    local money, computer = bank()
    if not computer or money < price then return false end
    computer.playerBankMoney = money - price
    pcall(function() if valid(computer.interface) then computer.interface:UpdateDesktop() end end)
    return true
end

-- In the clothes corner (the screen closes when the player is moved out of it).
function Look.atShop() return Clerk.distance() < 520 end

-- Where the figure stands while the shop screen is open.
Look.fitting = Clerk.FITTING

-- The panel covers the left part of the picture; the figure is shown in the middle of
-- what is left.
local PANEL_W, LEFT = 0.68, 0.027
local FIGURE_X = (PANEL_W + 1) / 2

-- The player's eye, and what half the picture's width and height are at distance 1. The
-- eye is taken from where the player stands, not from the camera: right after a dialogue
-- the camera is still on its way back.
local EYE_HEIGHT, CAMERA_FORWARD = 86, 10
-- The field of view is the player's own setting. It is read while nothing else has the
-- camera (a dialogue zooms in).
local seenFov = 90
Core.every(1.5, function()
    local player = World.player()
    if not player or Screen.current then return end
    pcall(function()
        if player.inDialogue == true then return end
        local fov = player:GetController().PlayerCameraManager:GetFOVAngle()
        if fov and fov >= 50 and fov <= 140 then seenFov = fov end
    end)
end)
local function view()
    local player = World.player()
    local at = player:K2_GetActorLocation()
    local _, _, w, h = Look.mouse()
    local tx = math.tan(math.rad(seenFov / 2))
    return { X = at.X, Y = at.Y, Z = at.Z + EYE_HEIGHT }, tx, tx * (h or 9) / (w or 16)
end

-- Next to the clothes shopkeeper.
function Look.atClerk() return Clerk.near() end
Clerk.wanted = function() return World.active or Net.isHost() end

-- A marker on the map, like the game's own shop markers.
local shopMarker = nil
local function ensureMarker()
    if shopMarker and Core.alive(shopMarker) then return end
    -- A little north of the furniture shop's own marker, so that the two names can be read.
    shopMarker = Hud.mapMarker("Marco's Clothing", "Outfits and hats", SHOP.x + 650, SHOP.y, SHOP.z, Hud.MARKER_SHOP)
end

-- The game is first-person, so both screens show the player as a figure dressed like them,
-- standing to the right of the panel and turning slowly.
local mirror, mirrorKey, mirrorAt = nil, nil, nil
local preview = nil      -- something being tried on in the shop: { body = mesh } or { hair = mesh }

local function shownLook()
    local l = Look.current()
    if preview then
        if preview.body then l.body = preview.body end
        if preview.hair ~= nil then l.hair = preview.hair end
    end
    return l
end

local function removeMirror()
    if mirror then Avatar.destroyStandIn(mirror) end
    mirror, mirrorKey, mirrorAt = nil, nil, nil
end

-- The figure turns slowly by itself. Holding the left mouse button on it (the part of the
-- screen right of the panel) stops it, and dragging turns it by hand; a few seconds after
-- the button is let go it turns by itself again.
local SPIN = 12              -- degrees per second
local DRAG = 0.45            -- degrees per pixel dragged
local RESUME = 4             -- seconds after letting go
local spin = { yaw = 0, at = nil, grabbed = false, wasDown = false, lastX = nil, resumeAt = 0 }
Look.spin = spin

local function mouse()
    local player = World.player()
    local pc = player and player:GetController()
    if not pc then return nil end
    local x, y, w, h = {}, {}, {}, {}
    pc:GetMousePosition(x, y)
    pc:GetViewportSize(w, h)
    local down = pc:IsInputKeyDown({ KeyName = FName("LeftMouseButton") }) == true
    return tonumber(x.LocationX), tonumber(y.LocationY), tonumber(w.SizeX), tonumber(h.SizeY), down
end
Look.mouse = mouse

Core.onTick(function()
    if not mirror or not mirrorAt then
        spin.at, spin.grabbed, spin.wasDown = nil, false, false
        return
    end
    local now = os.clock()
    local step = math.min(0.1, now - (spin.at or now))
    spin.at = now
    local ok, x, _, w, _, down = pcall(mouse)
    if ok and x and w and w > 0 then
        if down and not spin.wasDown then spin.grabbed = x / w > 0.69 end
        if not down then
            if spin.grabbed then spin.resumeAt = now + RESUME end
            spin.grabbed = false
        end
        if spin.grabbed and spin.lastX then spin.yaw = spin.yaw - (x - spin.lastX) * DRAG end
        spin.wasDown, spin.lastX = down, x
    end
    if spin.force then spin.yaw, spin.resumeAt = spin.force, now + 1 end     -- tests
    if not spin.grabbed and now >= spin.resumeAt then spin.yaw = spin.yaw + SPIN * step end
    spin.yaw = spin.yaw % 360
    pcall(Avatar.moveStandIn, mirror, mirrorAt.x, mirrorAt.y, mirrorAt.z, mirrorAt.facing + spin.yaw)
end)

local function showMirror()
    local player = World.player()
    if not player then return end
    local l = shownLook()
    local key = l.body .. "|" .. l.head .. "|" .. l.hair
    local loc = player:K2_GetActorLocation()
    local yaw = player:K2_GetActorRotation().Yaw
    pcall(function() yaw = player:GetControlRotation().Yaw end)
    local r = math.rad(yaw)
    local x, y, facing, size
    local spot = Look.page == "shop" and Look.fitting or nil
    if spot then
        -- In the shop the figure stands full size on the floor in front of the rack, like
        -- somebody trying the clothes on; the player has been turned to it.
        x, y, loc.Z, size = spot.x, spot.y, spot.z, 1
        facing = math.deg(math.atan(loc.Y - y, loc.X - x))
    else
        -- Half size and close by (a wall or a lamp post further off cannot hide it), in
        -- the middle of the part of the picture the panel leaves free, between the bar at
        -- the top and the button at the bottom.
        local eye, tx, ty = loc, 1, 0.5625
        local ok, e, a, b = pcall(view)
        if ok and e then eye, tx, ty = e, a, b end
        local F = 125
        local right = (2 * FIGURE_X - 1) * tx * F
        local up = (1 - 2 * 0.475) * ty * F
        -- (the camera is a little in front of where the player stands)
        x = eye.X + math.cos(r) * (F + CAMERA_FORWARD) - math.sin(r) * right
        y = eye.Y + math.sin(r) * (F + CAMERA_FORWARD) + math.cos(r) * right
        facing = math.deg(math.atan(eye.Y - y, eye.X - x))
        size = 0.5
        loc.Z = (ok and e) and (eye.Z + up + 45) or (loc.Z + 100)       -- a half-size figure's middle is 45 below this
    end
    local since = mirrorAt and mirrorAt.since or os.clock()
    if mirror and mirrorKey == key and valid(mirror.body) then
        mirrorAt = { x = x, y = y, z = loc.Z, facing = facing, since = since }
        return
    end
    removeMirror()
    mirror = Avatar.buildStandIn(l, x, y, loc.Z, facing, nil)
    if mirror then pcall(function() mirror.body:SetActorScale3D({ X = size, Y = size, Z = size }) end) end
    mirrorKey = key
    mirrorAt = { x = x, y = y, z = loc.Z, facing = facing, since = since }
    -- A lamp of its own, so that it can be seen at night and indoors.
    if mirror then
        pcall(function()
            local lamp = player:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.PointLight"),
                { X = loc.X + (x - loc.X) * 0.35, Y = loc.Y + (y - loc.Y) * 0.35, Z = loc.Z - 30 }, { Pitch = 0, Yaw = 0, Roll = 0 })
            mirror.actors[#mirror.actors + 1] = lamp
            local c = lamp.LightComponent
            c:SetMobility(2)
            c:SetIntensity(700)
            c:SetAttenuationRadius(240)
            c:SetLightColor({ R = 1, G = 0.93, B = 0.82, A = 1 }, true)
            c:SetCastShadows(false)
        end)
    end
end

---------------------------------------------------------------- the two screens

local function key(name) return tostring(Core.config[name] or "?") end

local PANEL = { R = 0.006, G = 0.006, B = 0.006, A = 0.95 }
local BAR_COLOR = { R = 0, G = 0, B = 0, A = 1 }
local CARD = { R = 0.0, G = 0.0, B = 0.0, A = 1 }
local FRAME_ON = { R = 0.10, G = 0.62, B = 0.18, A = 1 }

local scr = nil          -- the open screen
local pose = nil         -- where the player is held while it is open: { x, y, z, yaw, back }
-- The player stays where they are, looking level, while a screen is open.
local function hold(pitch)
    local player = World.player()
    if not player then return end
    local l = player:K2_GetActorLocation()
    local yaw = player:K2_GetActorRotation().Yaw
    pcall(function() yaw = player:GetControlRotation().Yaw end)
    pose = { x = l.X, y = l.Y, z = l.Z, yaw = yaw, pitch = pitch or 0, owner = player:GetAddress() }
    -- the game's own HUD (hints, compass) is put away while a screen is open
    pcall(function()
        pose.hud = player.HUD.Visibility
        player.HUD:SetVisibility(1)
    end)
    pcall(function() player:GetController():SetControlRotation({ Pitch = pose.pitch, Yaw = yaw, Roll = 0 }) end)
end

local function release()
    local p = pose
    pose = nil
    local player = World.player()
    if p and player and player:GetAddress() == p.owner then
        pcall(function() player.HUD:SetVisibility(p.hud or 4) end)
    end
    if p and p.back and player and player:GetAddress() == p.owner then
        pcall(function() player:K2_SetActorLocation({ X = p.back.x, Y = p.back.y, Z = p.back.z }, false, {}, true) end)
    end
end

Core.onTick(function()
    if not pose then return end
    local player = World.player()
    if not player or player:GetAddress() ~= pose.owner then
        pose = nil
        return
    end
    pcall(function()
        local l = player:K2_GetActorLocation()
        if math.abs(l.X - pose.x) > 3 or math.abs(l.Y - pose.y) > 3 then
            player:K2_SetActorLocation({ X = pose.x, Y = pose.y, Z = l.Z }, false, {}, true)
        end
        player:GetController():SetControlRotation({ Pitch = pose.pitch or 0, Yaw = pose.yaw, Roll = 0 })
    end)
end)
local drawn = {}         -- what the current picture consists of
local shopTab = "all"

local function wipe()
    if scr then
        scr.removeAll(drawn)
    end
    drawn = {}
end

local function put(widget, ax, ay, x, y, alignX, alignY)
    scr.place(widget, ax, ay, x, y, alignX, alignY)
    drawn[#drawn + 1] = widget
    return widget
end

local function closeScreen()
    local s = scr
    scr, drawn = nil, {}
    Look.page = nil
    preview = nil
    removeMirror()
    release()
    if s then
        s.onClose = nil
        pcall(s.close)
    end
end

local function frame(title)
    scr = Screen.open()
    if not scr then return false end
    scr.onClose = function()
        scr, drawn = nil, {}
        Look.page = nil
        preview = nil
        removeMirror()
        release()
    end
    scr.area(scr.box(PANEL), 0, 0, PANEL_W, 1)
    scr.area(scr.box(BAR_COLOR), 0, 0, 1, 0.1)
    scr.place(scr.text(title, "name", 26), LEFT, 0.05, 0, 0, 0, 0.5)
    return true
end

-- One card of a grid, top to bottom: a picture, a price or note (right), a name, lines of
-- small text (a string, or { text, colour }), one or two buttons ({ label, onClick,
-- disabled, colour } each). Any part may be left out.
local function tile(w, h, name, lines, corner, cornerColor, buttons, on, picture, pictureGap)
    local column = scr.new("VerticalBox")
    local function row(widget, top, align, bottom)
        local slot = column:AddChildToVerticalBox(widget)
        slot:SetPadding({ Left = 0, Top = top or 0, Right = 0, Bottom = bottom or 0 })
        slot:SetHorizontalAlignment(align or 2)
        return slot
    end
    if corner then row(scr.text(corner, "price", 16, cornerColor or Screen.GREEN), 0, 3) end
    if picture then row(picture, pictureGap or 0, 2, pictureGap or 0) end
    if name then row(scr.text(name, "name", 15), 8) end
    for _, line in ipairs(lines or {}) do
        if type(line) == "table" then
            row(scr.text(line[1], "button", 13, line[2] or Screen.GREY), 3)
        else
            row(scr.text(line, "small", 11, Screen.GREY), 4)
        end
    end
    local line = scr.new("HorizontalBox")
    for n, def in ipairs(buttons or {}) do
        local b = scr.button(def[1], 1.0, def[2])
        if def[3] then scr.enable(b, false) end
        if def[4] then scr.tint(b, def[4]) end
        local slot = line:AddChildToHorizontalBox(b.widget)
        slot:SetPadding({ Left = n > 1 and 6 or 0, Top = 0, Right = 0, Bottom = 0 })
    end
    row(line, 10)
    local face = scr.box(CARD, column)
    face:SetPadding({ Left = 8, Top = 6, Right = 8, Bottom = 8 })
    -- The one in use has a green frame. The others have the same frame in the card's own
    -- colour, so that every card is laid out alike and the pictures (black) sit on black.
    return scr.sized(scr.box(on and FRAME_ON or CARD, face, 2), w, h)
end

local function texture(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if valid(o) then return o end
    return nil
end

-- The game's own pictograms, one per kind of character.
local ICONS = {
    hustler = { "/Game/GUI/Phone/newIncomeIcon.newIncomeIcon" },
    runner = { "/Game/GUI/shadyComm/Remastered/areaMarkerIcon.areaMarkerIcon", angle = -90 },
    ghost = { "/Game/GUI/WorldMap/mapMarkerClient.mapMarkerClient", opacity = 0.3 },      -- a figure, barely there
    tagger = { "/Game/TerritorySpraying/sprayPaint_Icon.sprayPaint_Icon" },
    lightweight = { "/Game/GUI/shadyComm/addictionIcon.addictionIcon" },
    crook = { "/Game/GUI/shadyComm/Remastered/lockedIcon.lockedIcon" },
}

local function icon(id, size)
    local def = ICONS[id]
    local tex = def and texture(def[1])
    if not tex then return nil end
    local img = scr.new("Image")
    pcall(function() img:SetBrushFromTexture(tex, false) end)
    if def.angle then pcall(function() img:SetRenderTransformAngle(def.angle) end) end
    if def.opacity then pcall(function() img:SetRenderOpacity(def.opacity) end) end
    return scr.sized(img, size, size)
end

-- What a kind of character is better and worse at: green for the one, red for the other.
local function traitLines(c)
    local out = {}
    local function pct(v) return math.floor(math.abs(v - 1) * 100 + 0.5) end
    local function add(v, label)
        if v ~= 1 then out[#out + 1] = { string.format("%s%d%% %s", v > 1 and "+" or "-", pct(v), label), v > 1 and Screen.GREEN or Screen.RED } end
    end
    add(c.stamina, "STAMINA")
    add(c.speed, "SPEED")
    if c.seen ~= 1 then
        out[#out + 1] = { string.format("%d%% %s TO SPOT", pct(c.seen), c.seen < 1 and "HARDER" or "EASIER"), c.seen < 1 and Screen.GREEN or Screen.RED }
    end
    local function times(v) return (string.format("%.1f", v):gsub("%.0$", "")) end
    if c.tagTime and c.tagTime ~= 1 then
        out[#out + 1] = c.tagTime < 1 and { "TAGS " .. times(1 / c.tagTime) .. "X FASTER", Screen.GREEN } or { "TAGS " .. times(c.tagTime) .. "X SLOWER", Screen.RED }
    end
    if c.pockets ~= 0 then out[#out + 1] = { string.format("%+d POCKET", c.pockets), c.pockets > 0 and Screen.GREEN or Screen.RED } end
    if c.drugTime and c.drugTime ~= 1 then out[#out + 1] = { "DRUGS LAST " .. times(c.drugTime) .. "X", c.drugTime > 1 and Screen.GREEN or Screen.RED } end
    if c.seenHigh and c.seenHigh ~= 1 then out[#out + 1] = { (c.seenHigh > 1 and "EASIER" or "HARDER") .. " TO SPOT WHILE HIGH", c.seenHigh > 1 and Screen.RED or Screen.GREEN } end
    if c.freePick then out[#out + 1] = { "NO LOCKPICK MINIGAME", Screen.GREEN } end
    if c.pickHeat then out[#out + 1] = { "FORCED DOORS ADD HEAT", Screen.RED } end
    if #out == 0 then out[1] = { "BALANCED", Screen.GREY } end
    while #out < 3 do out[#out + 1] = { " ", Screen.GREY } end
    return out
end

---------------------------------------------------------------- who are you (once)

local renderStart

-- Everything on the panel is one column: a heading, a row of cards, a heading, a row...
-- Every row is as wide as the panel between its margins, whatever the shape of the
-- window: its cards share that width equally, with the same gap between them, and the
-- distances between the rows are the same.
local GAP = 12
local BUTTON_INSET = 10.5        -- the empty room at either side of the game's button

renderStart = function()
    if not scr then return end
    wipe()
    local U = scr.units()
    local width = (PANEL_W - 2 * LEFT) * U
    local look = Look.current()
    local panel = scr.new("VerticalBox")
    local function heading(str, top)
        local slot = panel:AddChildToVerticalBox(scr.text(str, "button", 16, Screen.GREY))
        slot:SetPadding({ Left = 0, Top = top, Right = 0, Bottom = 8 })
    end
    local function row(count, height, make)
        local line = scr.new("HorizontalBox")
        local w = math.floor((width - (count - 1) * GAP) / count)
        for i = 1, count do
            local slot = line:AddChildToHorizontalBox(make(i, w, height))
            slot:SetPadding({ Left = i > 1 and GAP or 0, Top = 0, Right = 0, Bottom = 0 })
        end
        panel:AddChildToVerticalBox(line)
    end

    heading("CHARACTER", 0)
    row(#CHARACTERS, 208, function(i, w, h)
        local c = CHARACTERS[i]
        local on = c.id == state.character
        return tile(w, h, c.name:upper(), traitLines(c), nil, nil, { { on and "SELECTED" or "SELECT", function()
            state.character = c.id
            renderStart()
        end, false, on and Screen.GREEN or nil } }, on, icon(c.id, 50), 2)
    end)

    local starters = {}
    for _, o in ipairs(OUTFITS) do if o.starter then starters[#starters + 1] = o end end
    heading("OUTFIT", 24)
    row(#starters, 232, function(i, w, h)
        local o = starters[i]
        local on = o.id == state.outfit
        local pic = Thumbs.image(scr, "b|" .. o.body .. "|" .. look.head, { look = { body = o.body, head = look.head, hair = look.hair, arms = true }, shot = "body" }, 100, 150)
        return tile(w, h, o.name, nil, nil, nil, { { on and "WEARING" or "WEAR", function()
            state.outfit = o.id
            renderStart()
        end, false, on and Screen.GREEN or nil } }, on, pic)
    end)

    heading("FACE", 24)
    row(#FACES, 140, function(i, w, h)
        local on = i == state.face
        local pic = Thumbs.image(scr, "f|" .. FACES[i] .. "|" .. look.hair, { look = { body = look.body, head = FACES[i], hair = look.hair, arms = true }, shot = "face" }, 84, 84)
        return tile(w, h, nil, nil, nil, nil, { { "FACE " .. i, function()
            state.face = i
            renderStart()
        end, false, on and Screen.GREEN or nil } }, on, pic)
    end)

    local free = {}
    for i, h in ipairs(HAIR) do if not h.price then free[#free + 1] = i end end
    heading("HAIR", 24)
    row(#free, 140, function(n, w, h)
        local i = free[n]
        local hair = HAIR[i]
        local on = i == state.hair
        local pic = Thumbs.image(scr, "h|" .. hair.mesh .. "|" .. look.head, { look = { body = look.body, head = look.head, hair = hair.mesh, arms = true }, shot = "hair" }, 84, 84)
        return tile(w, h, nil, nil, nil, nil, { { hair.name:upper(), function()
            state.hair = i
            renderStart()
        end, false, on and Screen.GREEN or nil } }, on, pic)
    end)
    put(panel, LEFT, 0.1, 0, 24, 0, 0)

    local start = scr.bigButton("START AS " .. character().name:upper(), 1.7, function()
        state.characterPicked = true
        state.roster = ROSTER
        state.owned[state.outfit] = true
        save()
        Look.applyTraits()
        Look.announce()
        Hud.toast("You are " .. character().name, 4)
        closeScreen()
    end)
    put(start.box, FIGURE_X, 0.9)
    pcall(showMirror)
end

-- A screen that was taken away with its world (a load, the main menu) is forgotten
-- without touching it.
local function stale()
    if scr and Screen.current ~= scr then
        scr, drawn, pose = nil, {}, nil
        Look.page, preview = nil, nil
        mirror, mirrorKey, mirrorAt = nil, nil, nil
    end
end

function Look.openStart()
    stale()
    if scr or not World.player() then return false end
    load()
    if HAIR[state.hair] and HAIR[state.hair].price and not state.ownedHair[tostring(state.hair)] then state.hair = 1 end
    if not byId[state.outfit].starter and not state.owned[state.outfit] then state.outfit = "jacket" end
    if not frame("WHO ARE YOU?") then return false end
    hold()
    Look.page = "start"
    renderStart()
    return true
end

---------------------------------------------------------------- the clothes shop

local renderShop

local function changed()
    save()
    Look.announce()
end

local shopScroll = 0

-- What the grid shows: everything there is at the shop, what the player owns at a wardrobe.
local function shopItems()
    local items = {}
    local mine = Look.page == "wardrobe"
    if shopTab ~= "hats" then
        for _, o in ipairs(OUTFITS) do
            local owned = state.owned[o.id] == true
            if owned or not mine then
                items[#items + 1] = { name = o.name, kind = "Outfit", body = o.body, price = o.price, owned = owned, on = state.outfit == o.id,
                    tried = preview ~= nil and preview.body == o.body,
                    try = function() preview = { body = o.body } end,
                    take = function() state.outfit = o.id end, own = function() state.owned[o.id] = true end }
            end
        end
    end
    if shopTab ~= "outfits" then
        for i, h in ipairs(HAIR) do
            local price = h.price or 0
            local owned = price == 0 or state.ownedHair[tostring(i)] == true
            if owned or not mine then
                items[#items + 1] = { name = h.name, kind = h.price and "Hat" or "Hair", hair = h.mesh, price = price, owned = owned,
                    on = state.hair == i, tried = preview ~= nil and preview.hair == h.mesh,
                    try = function() preview = { hair = h.mesh } end,
                    take = function() state.hair = i end, own = function() state.ownedHair[tostring(i)] = true end }
            end
        end
    end
    return items
end

renderShop = function()
    if not scr then return end
    for _, w in ipairs(drawn) do
        if w == scr.shopList then pcall(function() shopScroll = w:GetScrollOffset() end) end
    end
    wipe()
    local money = math.floor(bank())
    local mine = Look.page == "wardrobe"
    local U = scr.units()
    -- top bar, from the right margin: close, then (at the shop) the balance
    local top = scr.new("HorizontalBox")
    if not mine then
        local balance = top:AddChildToHorizontalBox(scr.text(string.format("your account balance: $%d", money), "price", 18))
        balance:SetVerticalAlignment(2)
        balance:SetPadding({ Left = 0, Top = 0, Right = 28, Bottom = 0 })
    end
    local x = scr.bigButton("X", 1.5, closeScreen)
    scr.tint(x, Screen.RED)
    top:AddChildToHorizontalBox(x.box):SetVerticalAlignment(2)
    put(top, 1 - LEFT, 0.05, BUTTON_INSET * 1.5, 0, 1, 0.5)
    -- the tabs: one row starting at the left margin, the same distance between them
    local tabs = { { "all", "ALL" }, { "outfits", "OUTFITS" }, { "hats", "HATS AND HAIR" } }
    local bar = scr.new("HorizontalBox")
    for i, t in ipairs(tabs) do
        local b = scr.bigButton(t[2], 1.3, function()
            shopTab, shopScroll = t[1], 0
            renderShop()
        end)
        if shopTab == t[1] then scr.tint(b, Screen.GREEN) end
        bar:AddChildToHorizontalBox(b.box):SetPadding({ Left = i > 1 and 36 or 0, Top = 0, Right = 0, Bottom = 0 })
    end
    put(bar, LEFT, 0.14, -BUTTON_INSET * 1.3, 0, 0, 0.5)
    -- The grid: as many columns as fit, each as wide as it takes to fill the panel from
    -- the left margin to the scroll bar.
    local x0, x1 = LEFT, PANEL_W - 0.012
    local available = (x1 - x0) * U - 34 - GAP        -- the scroll bar, and the gap after the last card of a row
    local columns = math.max(2, math.floor((available + GAP) / (224 + GAP)))
    local tileW = math.floor((available - (columns - 1) * GAP) / columns)
    local list, wrap = scr.new("ScrollBox"), scr.new("WrapBox")
    list:AddChild(wrap)
    scr.area(list, x0, 0.18, x1, 0.98)
    scr.shopList = list
    drawn[#drawn + 1] = list
    for _, it in ipairs(shopItems()) do
        local label, corner, color = "BUY", "$ " .. it.price, Screen.GREEN
        if it.on then label, corner, color = "WEARING", "yours", Screen.GREY
        elseif it.owned then label, corner, color = "WEAR", it.price > 0 and "yours" or "free", Screen.GREY end
        if mine then corner = nil end
        local buttons = {}
        if not it.on and not mine then
            buttons[1] = { it.tried and "PREVIEWING" or "PREVIEW", function()
                if it.tried then preview = nil else it.try() end
                renderShop()
            end, false, it.tried and Screen.GREEN or nil }
        end
        buttons[#buttons + 1] = { label, function()
            if not it.owned then
                if not pay(it.price) then
                    Hud.toast(string.format("Not enough money in the bank for this ($%d)", it.price), 4)
                    return
                end
                it.own()
            end
            it.take()
            preview = nil
            changed()
            renderShop()
        end, it.on or (not it.owned and money < it.price) }
        local now = Look.current()
        local pic, gap
        if it.body then
            pic = Thumbs.image(scr, "b|" .. it.body .. "|" .. now.head, { look = { body = it.body, head = now.head, hair = now.hair, arms = true }, shot = "body" }, 120, 180)
        else
            pic, gap = Thumbs.image(scr, "h|" .. it.hair .. "|" .. now.head, { look = { body = now.body, head = now.head, hair = it.hair, arms = true }, shot = "hair" }, 120, 120), 30
        end
        local cell = tile(tileW, mine and 306 or 330, it.name, { it.kind }, corner, color, buttons, it.on, pic, gap)
        local slot = wrap:AddChild(cell)
        pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = GAP, Bottom = GAP }) end)
    end
    local offset = shopScroll
    pcall(function() list:SetScrollOffset(offset) end)
    Core.after(0.05, function() pcall(function() if scr and scr.shopList == list then list:SetScrollOffset(offset) end end) end)
    if preview then put(scr.text("PREVIEW", "button", 18, Screen.GREEN), FIGURE_X, 0.14) end
    pcall(showMirror)
end

function Look.openShop()
    stale()
    if scr or not World.player() then return false end
    load()
    if not Look.atShop() then return false end
    if not frame("CLOTHES") then return false end
    -- The player is put at the viewpoint and turned so that the figure in front of the
    -- rack is in the middle of the part of the picture the panel leaves free, between the
    -- bar at the top and the bottom edge. Closing the screen puts the player back.
    local pitch, back = 0, nil
    pcall(function()
        local p = World.player()
        local l = p:K2_GetActorLocation()
        back = { x = l.X, y = l.Y, z = l.Z }
        p:K2_SetActorLocation({ X = Clerk.VIEWPOINT.x, Y = Clerk.VIEWPOINT.y, Z = l.Z }, false, {}, true)
        local spot = Clerk.FITTING
        local eye, tx, ty = view()
        local dx, dy = spot.x - eye.X, spot.y - eye.Y
        local aside = math.atan((2 * FIGURE_X - 1) * tx)
        local depth = math.max(60, math.sqrt(dx * dx + dy * dy) * math.cos(aside))
        local down = math.atan((1 - 2 * 0.55) * ty)
        pitch = math.deg(math.atan((spot.z - eye.Z) / depth) - down)
        p:GetController():SetControlRotation({ Pitch = pitch, Yaw = math.deg(math.atan(dy, dx)) - math.deg(aside), Roll = 0 })
    end)
    hold(pitch)
    if pose then pose.back = back end
    Look.page = "shop"
    renderShop()
    return true
end

-- Next to a wardrobe (the game's piece of furniture; a hideout can have several). The
-- places are looked up every few seconds: furniture is bought, moved and sold.
local WARDROBE = "/Game/Interactive/FunctionalFurniture/clothesWardrobeBP.clothesWardrobeBP_C"
local WARDROBE_REACH = 230
local wardrobes, wardrobesAt = {}, -100
local function wardrobeNear()
    local player = World.player()
    if not player then return nil end
    local now = os.clock()
    if now - wardrobesAt > 4 then
        wardrobesAt, wardrobes = now, {}
        for _, a in ipairs(Core.actors(WARDROBE) or {}) do
            local ok, l = pcall(function() return a:K2_GetActorLocation() end)
            if ok and l then wardrobes[#wardrobes + 1] = { x = l.X, y = l.Y, z = l.Z } end
        end
    end
    local l = player:K2_GetActorLocation()
    for _, w in ipairs(wardrobes) do
        local dx, dy = w.x - l.X, w.y - l.Y
        if math.abs(w.z - l.Z) < 170 and dx * dx + dy * dy < WARDROBE_REACH * WARDROBE_REACH then return w end
    end
    return nil
end
function Look.atWardrobe() return wardrobeNear() ~= nil end

-- The wardrobe at home: what the player owns, nothing to buy.
function Look.openWardrobe()
    stale()
    if scr or not World.player() then return false end
    load()
    local w = wardrobeNear()
    if not w then return false end
    if not frame("WARDROBE") then return false end
    -- The figure stands in front of the player: with their back to the wardrobe it is in
    -- the room, not inside the furniture.
    pcall(function()
        local p = World.player()
        local l = p:K2_GetActorLocation()
        p:GetController():SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(l.Y - w.y, l.X - w.x)), Roll = 0 })
    end)
    hold()
    Look.page = "wardrobe"
    shopTab, shopScroll = "all", 0
    renderShop()
    return true
end

function Look.close() closeScreen() end

-- The interaction key: the blackjack table at the club, the clothes shop at Donald's, a
-- wardrobe at home.
function Look.toggle()
    if scr then
        if Look.page == "shop" or Look.page == "wardrobe" then closeScreen() end
        return
    end
    if Look.atClerk() then
        -- the shopkeeper's dialogue leads to the screen; without it the screen opens directly
        if not Clerk.talk() then Look.openShop() end
    elseif Look.atWardrobe() then
        Look.openWardrobe()
    end
end

-- A fugitive who changes clothes at a wardrobe (the game's own way of shaking off the
-- police) comes out in another outfit of their own, and another hat if they have one.
-- With nothing else to wear nothing happens. Returns what was put on.
function Look.disguise()
    load()
    local outfits, hats = {}, {}
    for _, o in ipairs(OUTFITS) do
        if state.owned[o.id] and o.id ~= state.outfit then outfits[#outfits + 1] = o end
    end
    for i, h in ipairs(HAIR) do
        if h.price and state.ownedHair[tostring(i)] and i ~= state.hair then hats[#hats + 1] = i end
    end
    if #outfits == 0 and #hats == 0 then return nil end
    local worn = {}
    if #outfits > 0 then
        local o = outfits[math.random(#outfits)]
        state.outfit = o.id
        worn[#worn + 1] = o.name
    end
    if #hats > 0 then
        local i = hats[math.random(#hats)]
        state.hair = i
        worn[#worn + 1] = HAIR[i].name
    end
    save()
    Look.announce()
    if scr and (Look.page == "shop" or Look.page == "wardrobe") then pcall(renderShop) end
    if Hud.ready() then Hud.toast("You changed into: " .. table.concat(worn, ", "), 4) end
    return worn
end

-- The wardrobe calls this (and nothing else does) at the moment the fugitive stops being one.
Core.Hooks.add(WARDROBE .. ":endCopAlert", function()
    local ok, e = pcall(Look.disguise)
    if not ok then log("Wardrobe: change of clothes failed: %s", tostring(e)) end
end)
Clerk.onShow = function() Look.openShop() end

if Core.bindKey then
    Core.bindKey(Core.config.WardrobeKey or "U", function()
        local ok, e = xpcall(function()
            local t = Look.takeover
            if t and (t.isOpen() or (not scr and t.near())) then t.toggle() else Look.toggle() end
        end, debug.traceback)
        if not ok then log("Wardrobe: %s", tostring(e)) end
    end)
end

---------------------------------------------------------------- upkeep

local traitsFor = nil
local startedAt = 0

Core.every(1, function()
    local player = World.player()
    -- A host is asked who they are as soon as they have a lobby, not only once somebody
    -- has joined.
    local hosting = Net.isHost()
    if not player or not (World.active or hosting) then
        traitsFor = nil
        return
    end
    load()
    -- A new character object after every load: give it the traits again.
    local address = player:GetAddress()
    if traitsFor ~= address and Core.find("statisticsManager_C") then
        if Look.applyTraits() then traitsFor = address end
    elseif Look.pocketsKept > 0 then
        -- a pocket that is only still there because of what was in it: gone once it is empty
        local c = character()
        local defaults = StaticFindObject("/Game/Player/playerCharacterBP.Default__playerCharacterBP_C")
        if valid(defaults) then
            local _, kept = pocketBase(player, defaults, c)
            if kept ~= Look.pocketsKept then Look.applyTraits() end
        end
    end
    if not Hud.ready() then return end
    ensureMarker()
    if scr then pcall(showMirror) end
    local t = Look.takeover
    if scr or (t and t.isOpen()) then
        Hud.prompt(nil)
    elseif t and t.near() then
        Hud.prompt(t.prompt())
    elseif Look.atClerk() then
        local talking = false
        pcall(function() talking = player.inDialogue == true end)
        if talking then Hud.prompt(nil) else Hud.prompt(key("WardrobeKey"), "Talk") end
    elseif Look.atWardrobe() then
        Hud.prompt(key("WardrobeKey"), "Wardrobe")
    else
        Hud.prompt(nil)
        -- Once, at the start: who the player is.
        if not state.characterPicked and not Core.server and (World.shared() or hosting or Look.debug) and not Screen.current and os.clock() - startedAt > 8 then
            local q = Core.find("questManager_C")
            local busy = false
            pcall(function() busy = q.tipActive == true end)
            -- not on top of the pause menu (the lobby is made from there)
            pcall(function() busy = busy or Core.statics():IsGamePaused(player) == true end)
            if not busy then Look.openStart() end
        end
    end
end)

World.listen("start", function()
    startedAt = os.clock()
    load()
    Avatar.looks = {}
    Core.after(4, function() Look.announce() end)
end)

-- The host tells a newcomer how everybody already there looks.
World.listen("peer", function(id)
    Net.send("look", describe(nil), id)
    for other, l in pairs(Avatar.looks) do
        if other ~= id and type(l) == "table" then
            Net.send("look", { b = l.body, h = l.head, r = l.hair or "", p = other }, id)
        end
    end
end)

World.listen("stop", function()
    traitsFor = nil
    closeScreen()
end)

-- The kind of character whose traits are on the player right now (nil outside co-op).
function Look.active()
    local player = World.player()
    if not player or traitsFor ~= player:GetAddress() then return nil end
    return character()
end

function Look.state() return state end

-- coop/traits.lua: one more lock forced by this player, ever (kept in the player's file so
-- that "every second one" does not start again with every session). Returns the count.
function Look.forcedLock()
    load()
    state.forced = (tonumber(state.forced) or 0) + 1
    save()
    return state.forced
end
Look.OUTFITS, Look.CHARACTERS, Look.SHOP = OUTFITS, CHARACTERS, SHOP

return Look
