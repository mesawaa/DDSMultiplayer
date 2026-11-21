-- The clothes corner in Donald's furniture shop: a second shopkeeper at the shop's own
-- white rack, just right of the entrance, with hats and folded clothes on its boards.
-- Talking to him uses the game's own dialogue screen, like Donald's ("Show me what you
-- have" opens the clothes screen). Every game builds its own copy; nothing of it is saved.
--
-- The shop's furniture (this rack, the desks under the windows, the lamps) only exists
-- while a player stands in the shop: the level takes it away otherwise. Whatever is
-- tested or measured here has to be looked at through the eyes of a player standing in it.

local Core = require("core")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Repl = require("coop.repl")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_CLERK_GEN") or 0) + 1
_G.DDSMP_CLERK_GEN = GEN
local function live() return rawget(_G, "DDSMP_CLERK_GEN") == GEN end

local Clerk = { NAME = "Marco", TITLE = "MARCO'S" }

-- The shop's floor is x -2110..-850, y -13130..-11970, its top at z 110. The door and the
-- windows are in the wall at y -11970; Donald's desk is at the far end. The rack stands
-- against the west wall between the windows and the sofa display: y -12280..-11980, two
-- bays of 150 with a divider at y -12130; its boards reach from x -2105 to -2072 and
-- their tops are at the heights below (measured on a photograph taken straight on).
local FLOOR = 110
local STAND = FLOOR + 88         -- where a figure standing on the floor has its centre
local RACK = { back = -2104, middle = -2088, front = -2072, y0 = -12280, y1 = -11980,
    boards = { 125, 189, 224.5, 264, 296, 328, 360 } }
-- Marco stands at the end of the rack next to the sofa display, turned to the room.
local SPOT = { x = -1996, y = -12246, z = STAND, yaw = 20 }
-- While the clothes screen is open the player looks on from VIEWPOINT at a figure dressed
-- like them standing at FITTING, in front of the rack: far enough for the whole figure to
-- be in the picture, whatever the shape of the window.
local VIEWPOINT = { x = -1690, y = -12175 }
local FITTING = { x = -1990, y = -12110, z = STAND }
local REACH = 230
local BUILD_RANGE = 3500
local LOOK = { body = "SK_ma_casual_02_b", head = "SK_ma_head_02", hair = "Hats_Hair/SK_ma_hair_04", arms = true }
local CLOTHES = "/Game/MiddleEast/Meshes/"
local HAT_DROP = 173             -- a hat's underside is this far above its mesh's origin (the feet)

-- The game's pieces of hanging laundry, measured: how far a piece hangs below its origin,
-- how far it reaches above it, its width and its thickness. Laid on a board (turned onto
-- its back, made smaller) a few of them on top of each other are a pile of folded clothes.
local PIECES = {
    SM_clothes_B_03 = { len = 32, top = 6, w = 92, t = 16 },      -- brown shirt
    SM_clothes_A_05 = { len = 47, top = 7, w = 70, t = 22 },      -- beige shirt
}
-- Four piles to a board, 75 apart, the same on both boards; six hats, 50 apart. All of it
-- centred on the rack.
local function across(count, step)
    local out, middle = {}, (RACK.y0 + RACK.y1) / 2
    for i = 1, count do out[i] = middle + (i - (count + 1) / 2) * step end
    return out
end
local PILE_Y, HAT_Y = across(4, 75), across(6, 50)
local LAYOUT = {
    hats = {
        { board = 5, meshes = { "Hats_Hair/SK_ma_hat_beret_01", "Hats_Hair/SK_ma_hat_cap_02", "Hats_Hair/SK_ma_hat_casual_set_beanie_01",
            "Hats_Hair/SK_ma_hat_cap_01", "Hats_Hair/SK_ma_hat_flatcap_01", "Hats_Hair/SK_ma_hat_country_02" } },
        { board = 4, meshes = { "Hats_Hair/SK_ma_hat_cap_01", "Hats_Hair/SK_ma_hat_flatcap_01", "Hats_Hair/SK_ma_hat_country_02",
            "Hats_Hair/SK_ma_hat_beret_01", "Hats_Hair/SK_ma_hat_casual_set_beanie_01", "Hats_Hair/SK_ma_hat_cap_02" } },
    },
    piles = {
        { board = 3, mesh = "SM_clothes_B_03", scale = 0.62, count = 3, step = 4.5 },
        { board = 3, mesh = "SM_clothes_A_05", scale = 0.55, count = 2, step = 6 },
        { board = 3, mesh = "SM_clothes_B_03", scale = 0.62, count = 3, step = 4.5 },
        { board = 3, mesh = "SM_clothes_A_05", scale = 0.55, count = 2, step = 6 },
        { board = 2, mesh = "SM_clothes_A_05", scale = 0.55, count = 2, step = 6 },
        { board = 2, mesh = "SM_clothes_B_03", scale = 0.62, count = 3, step = 4.5 },
        { board = 2, mesh = "SM_clothes_A_05", scale = 0.55, count = 2, step = 6 },
        { board = 2, mesh = "SM_clothes_B_03", scale = 0.62, count = 3, step = 4.5 },
    },
    lamp = { x = -1960, y = -12130, z = FLOOR + 250, intensity = 2600, radius = 520 },
}
Clerk.SPOT, Clerk.FITTING, Clerk.VIEWPOINT, Clerk.LAYOUT, Clerk.RACK = SPOT, FITTING, VIEWPOINT, LAYOUT, RACK

local built = nil        -- { owner, fig, props = {}, dialogue }
local talking = 0        -- time the dialogue was started
local hidden = false

local function asset(path) return Avatar.asset(path) end

local function clear()
    local b = built
    built = nil
    if not b or World.gone then return end
    pcall(Avatar.destroyStandIn, b.fig)
    for _, a in ipairs(b.props or {}) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
    pcall(function() if valid(b.dialogue) then b.dialogue:K2_DestroyActor() end end)
end

-- The dialogue: the furniture shopkeeper's own lines with other words. The first answer
-- ends the dialogue and has the dialogue actor's (empty) DialogueLoaded event called,
-- which is how this module hears of it.
local function dialogueText()
    local template = nil
    for _, d in ipairs(Core.actors("/Game/Interactive/dialogueInstance.dialogueInstance_C") or FindAllOf("dialogueInstance_C") or {}) do
        if not template and Core.alive(d) then
            local v = Repl.export(d, { "dialogueLines" }).dialogueLines
            if type(v) == "string" and v:find('"Show me your products"', 1, true) and v:find('"How can I help you?"', 1, true) then template = v end
        end
    end
    if not template then return nil end
    -- plain text replacement (the texts hold characters that mean something in a pattern)
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
    local t = swap(template, '"How can I help you?"', '"Looking for something to wear? Try anything on."')
    -- the answer that opened the furniture catalogue: ends the talk and raises the event
    local a, b = t:find('ResponseText_2_3DC4585B4FB4F1C79DACFAA7F3A5BBD7="Show me your products"', 1, true)
    if not a then return nil end
    local close = t:find(")", b, true)
    local answer = t:sub(a, close)
    local changed = answer
    changed = changed:gsub('"Show me your products"', '"Show me what you have"', 1)
    changed = changed:gsub("(ExitsDialogue_8_%x+=)%a+", "%1True", 1)
    changed = changed:gsub("(EntersSale_10_%x+=)%a+", "%1False", 1)
    changed = changed:gsub('(questEventName_14_%x+=)"[^"]*"', '%1"DialogueLoaded"', 1)
    changed = changed:gsub("(LocalFunction_19_%x+=)%a+", "%1True", 1)
    t = t:sub(1, a - 1) .. changed .. t:sub(close + 1)
    return swap(t, '"Just passing, sorry"', '"Just looking, thanks"')
end

local function build(player)
    clear()
    local world = player:GetWorld()
    local b = { owner = player:GetAddress(), props = {} }
    built = b
    hidden = false
    b.fig = Avatar.buildStandIn(LOOK, SPOT.x, SPOT.y, SPOT.z, SPOT.yaw, nil, "idle")
    local function put(class, x, y, z, rotation)
        local a = world:SpawnActor(StaticFindObject(class), { X = x, Y = y, Z = z }, rotation or { Pitch = 0, Yaw = 0, Roll = 0 })
        a:SetActorEnableCollision(false)
        b.props[#b.props + 1] = a
        return a
    end
    -- The things on the rack are put up over the next ticks, a few at a time: all of them
    -- at once stops the game for a moment when a player comes near the shop.
    b.todo = {}
    local function later(fn) b.todo[#b.todo + 1] = fn end
    -- Hats: each a part of a character, which alone floats at head height above its actor.
    -- The figures face +Y, so a quarter turn has the hat face the room.
    for _, row in ipairs(LAYOUT.hats) do
        local top = RACK.boards[row.board]
        for i, name in ipairs(row.meshes) do
            later(function()
                local m = Avatar.mesh(name)
                if not m or not HAT_Y[i] then return end
                local a = put("/Script/Engine.SkeletalMeshActor", RACK.middle, HAT_Y[i], top - HAT_DROP, { Pitch = 0, Yaw = -90, Roll = 0 })
                a.SkeletalMeshComponent:SetSkeletalMesh(m, true)
            end)
        end
    end
    -- Piles: a piece lies on its back (what hung down points to the room), a few of them
    -- on top of each other.
    local slot = {}
    for _, it in ipairs(LAYOUT.piles) do
        slot[it.board] = (slot[it.board] or 0) + 1
        local y = PILE_Y[slot[it.board]]
        local piece = PIECES[it.mesh]
        later(function()
            local m = asset(CLOTHES .. it.mesh .. "." .. it.mesh)
            if not m or not y or not piece then return end
            local s = it.scale
            for n = 1, it.count do
                local z = RACK.boards[it.board] + piece.t * s / 2 + (n - 1) * it.step
                local a = put("/Script/Engine.StaticMeshActor", RACK.back + piece.top * s, y, z, { Pitch = 90, Yaw = 0, Roll = 0 })
                a:SetMobility(2)
                a.StaticMeshComponent:SetStaticMesh(m)
                a:SetActorScale3D({ X = s, Y = s, Z = s })
            end
        end)
    end
    -- a lamp on what is for sale
    later(function()
        local it = LAYOUT.lamp
        local l = put("/Script/Engine.PointLight", it.x, it.y, it.z)
        local c = l.LightComponent
        c:SetMobility(2)
        c:SetIntensity(it.intensity)
        c:SetAttenuationRadius(it.radius)
        c:SetLightColor({ R = 1, G = 0.95, B = 0.88, A = 1 }, true)
        c:SetCastShadows(false)
    end)
    pcall(function()
        local text = dialogueText()
        local class = StaticFindObject("/Game/Interactive/dialogueInstance.dialogueInstance_C")
        if not text or not valid(class) then return end
        local d = world:SpawnActor(class, { X = SPOT.x, Y = SPOT.y, Z = SPOT.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(d) then return end
        -- this copy is ours alone: it must not be written into anybody's save
        pcall(function() if valid(d.RamaSave) then d.RamaSave:K2_DestroyComponent(d) end end)
        if Repl.importRaw(d, "dialogueLines", text) then b.dialogue = d end
    end)
    log("Clothes corner: shopkeeper %s, dialogue %s, %d thing(s) for the rack to follow", tostring(b.fig ~= nil), tostring(b.dialogue ~= nil), #b.todo)
end

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
        pcall(fn)
    end
end)

function Clerk.distance()
    local player = World.player()
    if not player then return math.huge end
    local l = player:K2_GetActorLocation()
    return math.sqrt((l.X - SPOT.x) ^ 2 + (l.Y - SPOT.y) ^ 2 + ((l.Z - SPOT.z) * 2) ^ 2)
end

function Clerk.near() return built ~= nil and built.fig ~= nil and Clerk.distance() <= REACH end

-- Takes the shopkeeper out of the picture while the clothes screen shows the customer in
-- front of the rack, and puts him back.
function Clerk.hide(on)
    on = on == true
    if not built or not built.fig or hidden == on then return end
    hidden = on
    for _, a in ipairs(built.fig.actors or {}) do
        pcall(function() if valid(a) then a:SetActorHiddenInGame(on) end end)
    end
end

-- Starts the dialogue. Returns false when it cannot (the clothes screen is opened
-- directly then).
function Clerk.talk()
    local player = World.player()
    if not player or not built or not valid(built.dialogue) then return false end
    local ok, e = pcall(function()
        talking = os.clock()
        player:startDialogue(built.dialogue)
        -- there is no game NPC to turn the camera to or to name
        player.focusCamera = false
        player.dialogueWidget.txtTalkerName:SetText(FText(Clerk.NAME))
    end)
    if not ok then log("Clothes corner: dialogue failed: %s", tostring(e)) end
    return ok
end

Clerk.onShow = nil       -- set by the clothes screens: called when the player asks to see the clothes

Core.Hooks.add("/Game/Interactive/dialogueInstance.dialogueInstance_C:DialogueLoaded", function(ctx)
    if not live() or not built or os.clock() - talking > 600 then return end
    local ok, mine = pcall(function() return ctx:get():GetAddress() == built.dialogue:GetAddress() end)
    if not ok or not mine then return end
    talking = 0
    Core.after(0.25, function()
        if Clerk.onShow then pcall(Clerk.onShow) end
    end)
end)

Clerk.wanted = function() return World.active end    -- replaced by the clothes module

Core.every(1, function()
    if not live() then return end
    local player = World.player()
    if not player or not Clerk.wanted() then
        if built then clear() end
        return
    end
    if built and built.owner ~= player:GetAddress() then built = nil end      -- another world: its actors are gone
    local l = player:K2_GetActorLocation()
    local far = (l.X - SPOT.x) ^ 2 + (l.Y - SPOT.y) ^ 2 > BUILD_RANGE * BUILD_RANGE
    if built and (far or not valid(built.fig and built.fig.body)) then
        clear()
    elseif not built and not far then
        local ok, e = pcall(Avatar.batch, build, player)
        if not ok then log("Clothes corner: %s", tostring(e)) end
    end
end)

-- A save loaded from inside the game: the level stays, so what was built is taken away
-- (it is built again for the new player).
World.listen("loading", function()
    if not live() or not built then return end
    local player = World.player()
    if player and player:GetAddress() == built.owner then clear() else built = nil end
end)

function Clerk.shutdown() clear() end
function Clerk.rebuild()
    local player = World.player()
    if player then Avatar.batch(build, player) end
end

return Clerk
