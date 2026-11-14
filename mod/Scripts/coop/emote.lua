-- Emotes.
--
-- The emote key opens a wheel of eight emotes (buttons in a circle, picked with the
-- mouse). While an emote plays the player sees themselves from the outside: a figure
-- dressed like them does the emote where they stand, and the view moves to a camera in
-- front of it. Walking off ends the emote and puts the view back. The other players see
-- the emote on the character (coop/avatar.lua).
--
-- Smoking in the game (using a joint) also shows on the character for a few seconds.

local Core = require("core")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Hud = require("coop.hud")
local Screen = require("coop.screen")
local Look = require("coop.look")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_EMOTE_GEN") or 0) + 1
_G.DDSMP_EMOTE_GEN = GEN
local function live() return rawget(_G, "DDSMP_EMOTE_GEN") == GEN end

local Emote = {}

local SMOKE_SECONDS = 9
local RADIUS = 250

local function busy(player)
    local paused = false
    pcall(function()
        paused = StaticFindObject("/Script/Engine.Default__GameplayStatics"):IsGamePaused(player)
            or player.inventoryOpen == true or player.computerOpen == true or player.inDialogue == true
    end)
    return paused
end

---------------------------------------------------------------- the wheel

local wheel = nil

local function closeWheel()
    local s = wheel
    wheel = nil
    if s then
        s.onClose = nil
        pcall(s.close)
    end
end

function Emote.openWheel()
    local player = World.player()
    if not player or busy(player) or Screen.current then return false end
    local s = Screen.open()
    if not s then return false end
    wheel = s
    s.onClose = function() wheel = nil end
    s.place(s.sized(s.box({ R = 0, G = 0, B = 0, A = 0.72 }), 2 * RADIUS + 330, 2 * RADIUS + 190), 0.5, 0.5)
    s.place(s.text("EMOTE", "name", 26), 0.5, 0.5, 0, -22)
    local current = Avatar.EMOTES[Avatar.localEmote or 0]
    for i, e in ipairs(Avatar.EMOTES) do
        local a = math.rad((i - 1) * 45)
        local b = s.button(e.name, 1.5, function()
            closeWheel()
            Avatar.setEmote(i)
        end)
        if current == e then s.tint(b, Screen.GREEN) end
        s.place(b.widget, 0.5, 0.5, RADIUS * math.sin(a) * 1.25, -RADIUS * math.cos(a))
    end
    local stop = s.button(current and "STOP" or "CLOSE", 1.2, function()
        closeWheel()
        if current then Avatar.setEmote(0) end
    end)
    s.place(stop.widget, 0.5, 0.5, 0, 26)
    return true
end

function Emote.toggle()
    if wheel then closeWheel() else Emote.openWheel() end
end

---------------------------------------------------------------- seeing yourself

local view = nil       -- { id, figure, camera, lamp, owner }

local function endView()
    local v = view
    view = nil
    if not v or World.gone then return end
    local player = World.player()
    pcall(function()
        if player and player:GetAddress() == v.owner then
            player:GetController():SetViewTargetWithBlend(player, 0.25, 0, 0, false)
            player:SetActorHiddenInGame(false)
        end
    end)
    if v.figure then pcall(Avatar.destroyStandIn, v.figure) end
    for _, a in ipairs({ v.camera, v.lamp }) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
end

local function startView(id)
    local player = World.player()
    local emote = Avatar.EMOTES[id]
    if not player or not emote then return end
    local ok, e = xpcall(function()
        local l = player:K2_GetActorLocation()
        local yaw = player:K2_GetActorRotation().Yaw
        pcall(function() yaw = player:GetControlRotation().Yaw end)
        local r = math.rad(yaw)
        local world = player:GetWorld()
        local v = { id = id, owner = player:GetAddress() }
        view = v
        v.figure = Avatar.buildStandIn(Look.current(), l.X, l.Y, l.Z, yaw, nil, "idle")
        if not v.figure then error("no figure") end
        Avatar.poseStandIn(v.figure, emote.anim)
        local cx, cy = l.X + math.cos(r) * 270, l.Y + math.sin(r) * 270
        v.camera = world:SpawnActor(StaticFindObject("/Script/Engine.CameraActor"), { X = cx, Y = cy, Z = l.Z + 25 }, { Pitch = -4, Yaw = yaw + 180, Roll = 0 })
        pcall(function()
            v.camera.CameraComponent:SetConstraintAspectRatio(false)
            v.camera.CameraComponent:SetFieldOfView(75)
        end)
        v.lamp = world:SpawnActor(StaticFindObject("/Script/Engine.PointLight"), { X = l.X + math.cos(r) * 150, Y = l.Y + math.sin(r) * 150, Z = l.Z + 60 }, { Pitch = 0, Yaw = 0, Roll = 0 })
        pcall(function()
            local c = v.lamp.LightComponent
            c:SetMobility(2)
            c:SetIntensity(500)
            c:SetAttenuationRadius(380)
            c:SetLightColor({ R = 1, G = 0.93, B = 0.82, A = 1 }, true)
            c:SetCastShadows(false)
        end)
        player:SetActorHiddenInGame(true)
        player:GetController():SetViewTargetWithBlend(v.camera, 0.35, 0, 0, false)
    end, debug.traceback)
    if not ok then
        log("Emote view: %s", tostring(e))
        endView()
    end
end

Core.every(0.1, function()
    if not live() then return end
    local player = World.player()
    local want = Avatar.localEmote or 0
    if Avatar.noEmoteView or Core.config.EmoteThirdPerson == false then want = 0 end
    if view and (not player or player:GetAddress() ~= view.owner) then
        view = nil      -- another world: its actors went with it
    end
    if (view and view.id or 0) ~= want then
        endView()
        if want ~= 0 and player then startView(want) end
    end
end)

-- Walking off ends an emote.
Core.every(0.3, function()
    if not live() then return end
    if (Avatar.localEmote or 0) == 0 or Avatar.noEmoteView then return end
    local player = World.player()
    if not player then return end
    local v = player:GetVelocity()
    if v.X * v.X + v.Y * v.Y > 60 * 60 then
        Avatar.setEmote(0)
    end
end)

-- The game plays one of three sounds when a drug is used; the smoking one marks a joint.
if GEN == 1 then
    -- A player who uses weed from a quick slot is shown with a joint for a while. The game
    -- runs useDrugDose for every drug used; drug form 3 is the smoked kind (marijuana, mix
    -- id "MJ"). Up to v0.8.6 this listened to GameplayStatics:PlaySound2D for a smoking
    -- sound instead: that sound is only played by a function the game never calls, and
    -- touching the hook's parameters crashed the game whenever an item was dragged in an
    -- inventory. Do not hook PlaySound2D again.
    Core.Hooks.add("/Game/Player/playerCharacterBP.playerCharacterBP_C:useDrugDose", function(_, drugData)
        local ok, smoked = pcall(function()
            local d = drugData:get()
            if tonumber(d["drugForm_19_B94E64C64B0B81B32236CCBA49100E18"]) == 3 then return true end
            local weed = false
            d["MixStringIDs_41_539D03C54BF6480E05C4DCA079BEC14A"]:ForEach(function(_, v)
                if v:get():ToString() == "MJ" then weed = true end
            end)
            return weed
        end)
        if ok and smoked then Avatar.smokeUntil = os.clock() + SMOKE_SECONDS end
    end)
    if Core.bindKey then
        Core.bindKey(Core.config.EmoteKey or "V", function()
            local current = package.loaded["coop.emote"]
            local ok, e = xpcall(current and current.toggle or Emote.toggle, debug.traceback)
            if not ok then log("Emote wheel: %s", tostring(e)) end
        end)
    end
end

World.listen("stop", function()
    if not live() then return end
    closeWheel()
    Avatar.setEmote(0)
    endView()
end)

function Emote.shutdown()
    closeWheel()
    endView()
end

return Emote
