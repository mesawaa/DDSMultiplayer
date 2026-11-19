-- Emotes.
--
-- The emote key opens a wheel of the emotes (a ring of segments; the one the mouse points
-- at is lit, a click plays it). While an emote plays the player sees themselves from the outside: the
-- third-person view (coop/third.lua) with the figure held where it stands, so that the
-- mouse turns the view around it. Walking off ends the emote. The other players see the
-- emote on the character (coop/avatar.lua).
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

local function busy(player)
    local paused = false
    pcall(function()
        paused = StaticFindObject("/Script/Engine.Default__GameplayStatics"):IsGamePaused(player)
            or player.inventoryOpen == true or player.computerOpen == true or player.inDialogue == true
    end)
    return paused
end

---------------------------------------------------------------- the wheel
-- A ring of as many segments as there are emotes, the first at the top, clockwise. The
-- segment the mouse points at from the middle of the screen is lit (how far out the mouse
-- is does not matter); a click plays it. The middle stops the emote that is playing, or
-- closes the wheel.

local wheel = nil
local SIZE = 620              -- the ring's width in layout units (the screen is 1080 high)
local OUTER, INNER = 250, 120 -- of the 512 picture: the ring's outer and inner edge
local GAP = 5                 -- the line between two segments
local RING_ALPHA, LIGHT_ALPHA = 0.35, 0.3

-- The ring, and one segment of it (the top one) for the light.
local function pictures()
    local Tags = package.loaded["coop.tags"]
    if type(Tags) ~= "table" or not Tags.canvasPicture then return nil, nil end
    local n = #Avatar.EMOTES
    local half = 180 / n
    local function ring(cv, white, size, clear, colour)
        local c = size / 2
        cv:K2_DrawPolygon(white, { X = c, Y = c }, { X = OUTER, Y = OUTER }, 72, colour)
        -- the hole: strips of nothing as wide as the circle is at their height
        local rows = INNER
        local h = 2 * INNER / rows
        for i = 0, rows - 1 do
            local dy = -INNER + (i + 0.5) * h
            local w = math.sqrt(math.max(0, INNER * INNER - dy * dy))
            cv:K2_DrawTexture(white, { X = c - w, Y = c + dy - h / 2 }, { X = 2 * w, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, clear, 0, 0, { X = 0.5, Y = 0.5 })
        end
    end
    local base = Tags.canvasPicture("wheel" .. n, function(cv, white, size, clear)
        local c = size / 2
        ring(cv, white, size, clear, { R = 0.02, G = 0.02, B = 0.025, A = 1 })
        -- the lines between the segments: a thin rectangle of nothing along each edge
        local mid, long = (OUTER + INNER) / 2, OUTER - INNER + 8
        for k = 0, n - 1 do
            local b = math.rad((k + 0.5) * 360 / n)
            cv:K2_DrawTexture(white, { X = c + mid * math.sin(b) - GAP / 2, Y = c - mid * math.cos(b) - long / 2 }, { X = GAP, Y = long }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, clear, 0,
                math.deg(b), { X = 0.5, Y = 0.5 })
        end
    end)
    local light = Tags.canvasPicture("wheelLight" .. n, function(cv, white, size, clear)
        local c = size / 2
        ring(cv, white, size, clear, { R = 1, G = 1, B = 1, A = 1 })
        -- everything but the top segment goes: two half planes, each a large rectangle with
        -- one long side along an edge of the segment
        for _, side in ipairs({ 1, -1 }) do
            local a = math.rad(half)
            local dx, dy = side * math.sin(a), -math.cos(a)        -- along the edge, from the middle
            local nx, ny = side * math.cos(a), math.sin(a)         -- away from the segment
            local far = size / 2 - GAP / 2
            cv:K2_DrawTexture(white, { X = c + nx * far - size, Y = c + ny * far - size / 2 }, { X = 2 * size, Y = size }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, clear, 0,
                math.deg(math.atan(dy, dx)), { X = 0.5, Y = 0.5 })
        end
    end)
    return base, light
end

local function closeWheel()
    local s = wheel
    wheel = nil
    if s then
        s.onClose = nil
        pcall(s.close)
    end
end

-- The segment the mouse points at (nil: the middle).
local function pointed(s)
    local ok, x, y, w, h = pcall(Look.mouse)
    -- (tests: the mouse as fractions of the screen)
    if Emote.testMouse then ok, x, y, w, h = true, Emote.testMouse[1], Emote.testMouse[2], 1, 1 end
    if not ok or not x or not w or w <= 0 then return s.over end
    local unitsWide, unitsHigh = s.units()
    local dx, dy = (x / w - 0.5) * unitsWide, (y / h - 0.5) * unitsHigh
    if dx * dx + dy * dy < (SIZE / 2 * INNER / 256 * 0.8) ^ 2 then return nil end
    local n = #Avatar.EMOTES
    local a = math.deg(math.atan(dx, -dy)) % 360          -- 0 at the top, clockwise
    return math.floor((a + 180 / n) / (360 / n)) % n + 1
end

local function showPointed(s, i)
    s.over = i
    local e = i and Avatar.EMOTES[i] or nil
    pcall(function()
        if s.light then
            s.light:SetVisibility(e and 3 or 1)
            if e then
                -- (the engine of this game calls it SetRenderAngle; later ones SetRenderTransformAngle)
                local angle = (i - 1) * 360 / #Avatar.EMOTES
                if not pcall(function() s.light:SetRenderAngle(angle) end) then s.light:SetRenderTransformAngle(angle) end
            end
        end
    end)
    for k, t in ipairs(s.names) do
        local on = k == s.playing or (Avatar.EMOTES[k] and Avatar.EMOTES[k].strut and Avatar.strut)
        local c = on and Screen.GREEN or Screen.WHITE
        pcall(function() t:SetColorAndOpacity({ SpecifiedColor = c, ColorUseRule = 0 }) end)
    end
    pcall(function() s.middle:SetText(FText(e and e.name or (s.playing and "STOP" or "CLOSE"))) end)
end

-- Plays emote `i` (nil: the middle) as a click on the wheel does.
function Emote.choose(i)
    local playing = (Avatar.localEmote or 0) ~= 0
    closeWheel()
    local e = i and Avatar.EMOTES[i]
    if e and e.strut then Emote.toggleStrut()
    elseif e then Avatar.setEmote(i)
    elseif playing then Avatar.setEmote(0) end
end

---------------------------------------------------------------- the strut
-- A walk of its own (Caps Lock, or Strut on the wheel), switched on until switched off.
-- The other players see the strut animation; the player walks slower while it is on (the
-- game's own top speed is kept and given back).
local strutHeld = nil      -- { owner = player address, speed = the game's top speed }

local function strutSpeed(player, on)
    pcall(function()
        local cm = player.CharacterMovement
        local addr = player:GetAddress()
        if strutHeld and strutHeld.owner ~= addr then strutHeld = nil end
        local cap = Avatar.tune.strutMaxSpeed
        if on then
            local now = cm.MaxWalkSpeed
            -- (the game sets its speed again now and then: traits, skills, sprinting)
            if now > cap + 0.5 then
                strutHeld = { owner = addr, speed = now }
                cm.MaxWalkSpeed = cap
            end
        elseif strutHeld then
            if math.abs(cm.MaxWalkSpeed - cap) < 0.5 then cm.MaxWalkSpeed = strutHeld.speed end
            strutHeld = nil
        end
    end)
end

function Emote.toggleStrut()
    local player = World.player()
    if not player then return end
    Avatar.strut = not Avatar.strut
    strutSpeed(player, Avatar.strut)
    Hud.toast(Avatar.strut and "Strut on" or "Strut off", 2)
end

Core.onTick(function()
    if not live() or not Avatar.strut then return end
    local player = World.player()
    if player then strutSpeed(player, true) end
end)

function Emote.openWheel()
    local player = World.player()
    if not player or busy(player) or Screen.current then return false end
    local s = Screen.open()
    if not s then return false end
    wheel = s
    s.keepView = true       -- (the third-person view stays while the wheel is open)
    s.onClose = function() if wheel == s then wheel = nil end end
    s.names, s.playing = {}, (Avatar.localEmote or 0) ~= 0 and Avatar.localEmote or nil
    local base, light = nil, nil
    pcall(function() base, light = pictures() end)
    local function image(rt, alpha)
        local img = s.new("Image")
        img.Brush.ResourceObject = rt
        img.Brush.ImageSize = { X = SIZE, Y = SIZE }
        img:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = alpha })
        img:SetVisibility(3)
        s.place(s.sized(img, SIZE, SIZE), 0.5, 0.5)
        return img
    end
    -- (faint: the game stays in sight through it; the words carry a shadow instead)
    if base and valid(base) then pcall(image, base, RING_ALPHA) end
    if light and valid(light) then pcall(function() s.light = image(light, LIGHT_ALPHA) end) end
    local function shadow(t)
        pcall(function()
            t:SetShadowOffset({ X = 1.5, Y = 1.5 })
            t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 })
        end)
    end
    local n = #Avatar.EMOTES
    local at = SIZE / 2 * (OUTER + INNER) / 2 / 256
    for i, e in ipairs(Avatar.EMOTES) do
        local a = math.rad((i - 1) * 360 / n)
        local t = s.text(e.name, "button", 19)
        shadow(t)
        s.names[i] = t
        s.place(t, 0.5, 0.5, at * math.sin(a), -at * math.cos(a))
    end
    s.middle = s.text("", "button", 24)
    shadow(s.middle)
    s.place(s.middle, 0.5, 0.5)
    -- one button over everything: where the mouse points when it is pressed decides
    local hit = s.hit("wheel", function() Emote.choose(s.over) end)
    s.fill(hit.widget, 5)
    -- the mouse starts in the middle
    pcall(function()
        local pc = player:GetController()
        local w, h = {}, {}
        pc:GetViewportSize(w, h)
        pc:SetMouseLocation(math.floor(w.SizeX / 2), math.floor(h.SizeY / 2))
    end)
    showPointed(s, nil)
    return true
end

function Emote.toggle()
    if wheel then closeWheel() else Emote.openWheel() end
end

Core.onTick(function()
    if not live() then return end
    local s = wheel
    if not s or not s.open or Screen.current ~= s then return end
    local i = pointed(s)
    if i ~= s.over then showPointed(s, i) end
end)

-- (for test scripts)
function Emote.wheel() return wheel end
function Emote.point(i) if wheel then showPointed(wheel, i) end end

-- A movement key ends an emote at once (the figure is held where it stands, so walking off
-- is only noticed below once the player has got going).
local MOVE_KEYS = { "W", "A", "S", "D" }
Core.onTick(function()
    if not live() or (Avatar.localEmote or 0) == 0 or Screen.current then return end
    local player = World.player()
    if not player or busy(player) then return end
    pcall(function()
        local pc = player:GetController()
        for _, key in ipairs(MOVE_KEYS) do
            if Emote.testKey == key or pc:IsInputKeyDown({ KeyName = FName(key) }) == true then
                Avatar.setEmote(0)
                return
            end
        end
    end)
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
        Core.bindKey(Core.config.StrutKey or "CAPS_LOCK", function()
            local current = package.loaded["coop.emote"]
            local player = World.player()
            if not player or busy(player) or Screen.current then return end
            local ok, e = xpcall(current and current.toggleStrut or Emote.toggleStrut, debug.traceback)
            if not ok then log("Strut: %s", tostring(e)) end
        end)
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
    if Avatar.strut and not World.gone then
        local player = World.player()
        if player then strutSpeed(player, false) end
    end
    Avatar.strut, strutHeld = false, nil
end)

function Emote.shutdown()
    closeWheel()
end

return Emote
