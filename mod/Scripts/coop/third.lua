-- Third person.
--
-- A key switches between the game's first-person view and a view from close behind the
-- player's own figure, dressed and animated the way the other players see it. The
-- distance is fixed (no zoom). An emote shows the same view by itself, with the figure
-- held where it stands and the view turning around it with the mouse.
--
-- How: the game's own camera stays at the head and keeps doing what the game uses it for
-- (what the player aims at, what can be used). A second camera becomes the view. It hangs
-- on the player controller, which is hung on the player for the time: the controller
-- turns with the mouse and the engine moves both every frame, so nothing here has to keep
-- up with the frame rate. Each tick only pulls the camera in where a wall is in the way.
--
-- The view goes back to first person by itself while the phone, the inventory, a talk, a
-- work station or one of the mod's screens is in use, and comes back afterwards.

local Core = require("core")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Screen = require("coop.screen")
local Look = require("coop.look")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_THIRD_GEN") or 0) + 1
_G.DDSMP_THIRD_GEN = GEN
local function live() return rawget(_G, "DDSMP_THIRD_GEN") == GEN end

local Third = { on = false }

-- Where the camera sits, from a point above the middle of the player: this far behind,
-- to the right and up. `emote` is the view while an emote plays (the whole figure, from
-- any side). Can be tuned in a running game.
Third.tune = {
    walk = { back = 165, side = 40, up = 80 },
    emote = { back = 235, side = 0, up = 35 },
    -- seated at the card table: from behind and above the own chair, far enough back for
    -- the players on the seats to the left and right to be in the picture
    seat = { back = 130, side = 0, up = 65 },
    wall = 14,          -- kept between the camera and what is in its way
    hideUnder = 95,     -- nearer than this to the figure, the figure is not drawn (its head would fill the view)
    ease = 6,           -- how fast the camera goes back out once the way is free
}

local rig = nil     -- { owner, pc, camera, cameraAddr, figure, back, since, arms }
local KSL = nil

local function address(o)
    local a = nil
    pcall(function() if o and o:IsValid() then a = o:GetAddress() end end)
    return a
end

-- States of the game in which the player needs the first-person view.
local FLAGS = { "phoneUp", "inventoryOpen", "computerOpen", "inDialogue", "atWorkStation", "inAppartmentMode",
    "RenovationMode", "mapOpen", "isLockpicking", "isTrading", "saveScreenOpen", "equipmentShopOpen", "beenCaught",
    "waiting", "sleepDialogue" }

local function occupied(player)
    local yes = false
    pcall(function()
        for _, f in ipairs(FLAGS) do
            if player[f] == true then yes = true return end
        end
    end)
    if yes then return true end
    local s = Screen.current
    if s and not s.keepView then return true end
    return false
end

local function emoting()
    return (Avatar.localEmote or 0) ~= 0 and not Avatar.noEmoteView
end

local function wanted(player)
    -- (Third.force: a place of the mod's own asks for the view from behind, by the name of
    -- its shape in Third.tune; its screen has `keepView`)
    if Third.force then return not occupied(player) end
    if Avatar.noEmoteView then return false end
    if not Third.on and not (emoting() and Core.config.EmoteThirdPerson ~= false) then return false end
    return not occupied(player)
end

local function viewTarget(pc)
    local t = nil
    pcall(function() t = pc:GetViewTarget() end)
    return address(t)
end

-- How far the camera can go along its arm before something is in the way (0..1).
local function freeShare(player, from, to)
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local function blocked(share)
        local hit = {}
        local ok, yes = pcall(function()
            return KSL:LineTraceSingle(player, from, { X = from.X + (to.X - from.X) * share, Y = from.Y + (to.Y - from.Y) * share,
                Z = from.Z + (to.Z - from.Z) * share }, 0, false, {}, 0, hit, true,
                { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
        end)
        return ok and yes == true
    end
    if not blocked(1) then return 1 end
    local low, high = 0, 1
    for _ = 1, 5 do
        local mid = (low + high) / 2
        if blocked(mid) then high = mid else low = mid end
    end
    return low
end

local function place(r, player, dt, snap)
    local t = Third.tune
    local shape = (Third.force and t[Third.force]) or (emoting() and t.emote or t.walk)
    local l = player:K2_GetActorLocation()
    local rot = r.pc:GetControlRotation()
    local pitch, yaw = math.rad(rot.Pitch), math.rad(rot.Yaw)
    local fx, fy, fz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
    local rx, ry = -math.sin(yaw), math.cos(yaw)
    local from = { X = l.X, Y = l.Y, Z = l.Z + shape.up }
    local to = { X = from.X - fx * shape.back + rx * shape.side, Y = from.Y - fy * shape.back + ry * shape.side, Z = from.Z - fz * shape.back }
    local length = math.sqrt(shape.back * shape.back + shape.side * shape.side)
    local share = freeShare(player, from, to)
    if share < 1 then share = math.max(0, share - t.wall / length) end
    -- in at once, out slowly
    local now = r.share or share
    if share < now or snap then now = share else now = now + (share - now) * math.min(1, dt * t.ease) end
    if math.abs(now - (r.set or -1)) > 0.004 or r.shape ~= shape then
        r.set, r.shape = now, shape
        r.camera:K2_SetActorRelativeLocation({ X = -shape.back * now, Y = shape.side * now, Z = shape.up }, false, {}, true)
    end
    r.share = now
    Avatar.showOwn(r.figure, length * now >= t.hideUnder)
end

local function hideArms(r, player)
    pcall(function()
        local arms = player.fpsArms
        if valid(arms) and arms:IsVisible() then
            arms:SetVisibility(false, true)
            r.arms = true
        end
    end)
end

-- The phone is an actor of its own in the hand of the first-person body, and hiding or
-- showing that body does the same to the phone.
local function showPhone(player, show)
    pcall(function()
        local root = player.phoneRef.DefaultSceneRoot
        if valid(root) then root:SetVisibility(show, true) end
    end)
end

-- `quick`: the way back to the head is short (the phone comes up: its hand is already rising)
local function leave(giveViewBack, quick)
    local r = rig
    rig = nil
    if not r then return end
    Avatar.sendYaw = nil
    if World.gone then return end
    local player = World.player()
    local same = player and address(player) == r.owner
    local blend = quick and 0.1 or 0.2
    pcall(function()
        if same and giveViewBack and viewTarget(r.pc) == r.cameraAddr then
            r.pc:SetViewTargetWithBlend(player, blend, 0, 0, false)
        end
    end)
    -- (the phone, which the game has just shown, waits for the hand that holds it)
    if same and r.arms then showPhone(player, false) end
    pcall(function() if valid(r.pc) then r.pc:K2_DetachFromActor(1, 1, 1) end end)
    local camera, figure = r.camera, r.figure
    -- The game's first-person body (a whole figure, of which the player sees the arms) is
    -- shown again only when the view is back at the head: on the way there it would be
    -- seen from outside, standing in the player's own figure.
    local function showArms()
        if not (same and r.arms) then return end
        if rig then
            rig.arms = true     -- third person again already: this one puts them back
            return
        end
        pcall(function()
            local now = World.player()
            if now and address(now) == r.owner then
                now.fpsArms:SetVisibility(true, true)
                showPhone(now, now.phoneUp == true)
            end
        end)
    end
    local function clear()
        if World.gone then return end
        showArms()
        pcall(Avatar.destroyStandIn, figure)
        pcall(function() if valid(camera) then camera:K2_DestroyActor() end end)
    end
    -- (the view is still on its way back to the head)
    if same and giveViewBack then Core.after(blend + 0.05, clear) else clear() end
end

local function enter(player)
    local ok, e = xpcall(function()
        local pc = player:GetController()
        local l = player:K2_GetActorLocation()
        local r = { owner = address(player), pc = pc, since = os.clock() }
        rig = r
        r.figure = Avatar.buildOwn(Look.current(), player)
        if not r.figure then error("no figure") end
        r.camera = player:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.CameraActor"), { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        r.cameraAddr = address(r.camera)
        pcall(function()
            r.camera.CameraComponent:SetConstraintAspectRatio(false)
            r.camera.CameraComponent:SetFieldOfView(player.Camera.FieldOfView)
        end)
        -- the controller goes where the player goes and turns with the mouse; the camera hangs on it
        pc:K2_AttachToActor(player, FName("None"), 2, 1, 1, false)
        r.camera:K2_AttachToActor(pc, FName("None"), 2, 2, 2, false)
        place(r, player, 0, true)
        hideArms(r, player)
        pc:SetViewTargetWithBlend(r.camera, 0.25, 0, 0, false)
    end, debug.traceback)
    if not ok then
        log("Third person: %s", tostring(e))
        leave(true)
        Third.on = false
    end
end

Core.onTick(function(dt)
    if not live() then return end
    local player = World.player()
    if rig and (not player or address(player) ~= rig.owner) then
        rig = nil               -- another world: its actors went with it
        Avatar.sendYaw = nil
    end
    if not player then return end
    local r = rig
    if not r then
        if not wanted(player) then return end
        local pc = nil
        pcall(function() pc = player:GetController() end)
        if not pc or not valid(pc) then return end
        -- only from the game's own view (something else may be showing a view of its own)
        if viewTarget(pc) ~= address(player) then return end
        enter(player)
        return
    end
    if not valid(r.camera) or not valid(r.figure.body) or not valid(r.pc) then
        leave(true)
        return
    end
    if os.clock() - r.since > 0.5 and viewTarget(r.pc) ~= r.cameraAddr then
        leave(false)            -- the game (or another part of the mod) took the view
        return
    end
    if not wanted(player) then
        leave(true, player.phoneUp == true)
        return
    end
    local ok, e = xpcall(function()
        -- an emote: the figure stays as it stands, the view turns around it
        local hold = emoting()
        if hold ~= (r.held == true) then
            r.held = hold
            Avatar.holdOwn(r.figure, player, hold)
            Avatar.sendYaw = hold and r.figure.yaw or nil
        end
        hideArms(r, player)
        local fov = player.Camera.FieldOfView
        if math.abs(fov - (r.fov or 0)) > 0.05 then
            r.fov = fov
            r.camera.CameraComponent:SetFieldOfView(fov)
        end
        place(r, player, dt, false)
        Avatar.stepOwn(r.figure, player, dt)
    end, debug.traceback)
    if not ok then
        log("Third person: %s", tostring(e))
        leave(true)
        Third.on = false
    end
end)

-- (the key does nothing while the keyboard is for something else: a screen, the phone)
function Third.toggle()
    local player = World.player()
    if not player or occupied(player) then return Third.on end
    Third.on = not Third.on
    return Third.on
end

function Third.active() return rig ~= nil end
function Third.rig() return rig end

if GEN == 1 and Core.bindKey then
    Core.bindKey(Core.config.ThirdPersonKey or "P", function()
        local current = package.loaded["coop.third"]
        local ok, e = xpcall(current and current.toggle or Third.toggle, debug.traceback)
        if not ok then log("Third person key: %s", tostring(e)) end
    end)
end

World.listen("stop", function()
    if not live() then return end
    leave(true)
    Third.on = false        -- (every world starts in the game's own view)
end)

-- (a save loaded from inside the game: the level stays, the player is replaced)
World.listen("loading", function()
    if live() then leave(true) end
end)

function Third.shutdown() leave(true) end

return Third
