-- Standing on other players (EXPERIMENTAL "PlayerStacking"): to reach higher up a wall,
-- one player crouches, the other jumps onto them, and the one below stands up.
--
-- The other players are figures without collision (coop/avatar.lua). Here every one of
-- them gets an invisible block in this game, 70 across, with its top at that player's
-- head: 180 above their feet, 90 while they crouch (a jump goes 88 high: just short of a crouching player, so
-- the block lifts a jump that comes within 12 of its top; never onto a standing one). A
-- block is solid only for a player above it: it is switched on once this player's feet
-- are near its top (and stays on while they stand on it), so nobody is ever
-- in anybody's way when walking. The block follows its figure every tick; the game itself
-- carries a player standing on it when it moves or rises (the engine's moving bases).
--
-- Only the game of the player on top needs this switched on; the one below only sends
-- that they crouch (every v0.19 game does).

local Core = require("core")
local World = require("coop.world")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_STACK_GEN") or 0) + 1
_G.DDSMP_STACK_GEN = GEN
local function live() return rawget(_G, "DDSMP_STACK_GEN") == GEN end

local Stack = { KEY = "PlayerStacking", stats = { built = 0, stood = 0 } }

local CYLINDER = "/Engine/BasicShapes/Cylinder.Cylinder"     -- 100 across, 100 high, its middle at its place
local RADIUS = 35            -- as a player's capsule
local STAND_H, CROUCH_H = 180, 90
local REACH = RADIUS + 35 + 5        -- this player's middle is over the block (both capsules' radii)
local ON_FROM, KEEP_TO = 12, 20       -- solid from this far below the top on (a jump goes 88, a crouching player is 90), and while not further below
local BLOCK_H = CROUCH_H     -- the block's own height (only its top matters: it is solid only for a player above it)
local TURN = 1.5             -- seconds a player takes to crouch or to stand up

local blocks = {}            -- player id -> { actor, h, on }
local owner = nil            -- the character the blocks were made for (another world: forgotten)

local function enabled() return Core.experimental(Stack.KEY) == true end

-- Forgets the blocks; `destroy` also takes them out of the world (only while it is the
-- world they were made in: an actor of a world that is gone is never touched).
local function clear(destroy)
    if destroy then
        for _, b in pairs(blocks) do pcall(function() if valid(b.actor) then b.actor:K2_DestroyActor() end end) end
    end
    blocks = {}
end

local function mesh()
    local m = StaticFindObject(CYLINDER)
    if not valid(m) then pcall(function() m = LoadAsset(CYLINDER) end) end
    return valid(m) and m or nil
end

local function build(player)
    local m = mesh()
    if not m then return nil end
    local l = player:K2_GetActorLocation()
    local a = player:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = l.X, Y = l.Y, Z = l.Z - 5000 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(a) then return nil end
    a:SetMobility(2)
    a.StaticMeshComponent:SetStaticMesh(m)
    pcall(function() a.StaticMeshComponent:SetCollisionProfileName(FName("BlockAll"), true) end)
    pcall(function() a.StaticMeshComponent:SetCastShadow(false) end)
    a:SetActorHiddenInGame(true)
    a:SetActorEnableCollision(false)
    Stack.stats.built = Stack.stats.built + 1
    return a
end

Core.onTick(function()
    if not live() then return end
    local player = World.player()
    local Avatar = package.loaded["coop.avatar"]
    if not player or type(Avatar) ~= "table" or not enabled() or not World.shared() then
        if next(blocks) then clear(player ~= nil and owner == (player and player:GetAddress())) end
        return
    end
    local address = player:GetAddress()
    if owner ~= address then
        clear(false)
        owner = address
    end
    local ok, err = pcall(function()
        local l = player:K2_GetActorLocation()
        local half = 90
        pcall(function() half = player.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
        local feet = l.Z - half
        local seen = {}
        for id, set in pairs(Avatar.puppets) do
            local p = set.player
            if p and p.isPlayer and valid(p.body) and p.x then
                seen[id] = true
                local b = blocks[id]
                if not b then
                    local a = build(player)
                    if a then
                        b = { actor = a, on = false }
                        blocks[id] = b
                    end
                end
                if b then
                    -- Their feet: below the place sent for them (the capsule's middle) by half
                    -- of a standing or a crouching player. The crouching is told at once, the
                    -- body takes a moment to get there: meanwhile the feet stay where they were
                    -- and the height is what the middle says (twice its height above the feet).
                    local now = os.clock()
                    local crouched = (p.flags or 0) & (Avatar.FLAG_CROUCH or 256) ~= 0
                    if crouched ~= b.crouched then
                        b.crouched, b.changedAt = crouched, now
                    end
                    local theirs = p.z - (crouched and CROUCH_H or STAND_H) / 2
                    local h = crouched and CROUCH_H or STAND_H
                    if b.feet and now - (b.changedAt or -10) < TURN then
                        theirs = b.feet
                        h = math.max(CROUCH_H, math.min(STAND_H, 2 * (p.z - theirs)))
                    end
                    b.feet = theirs
                    local top = theirs + h
                    -- A block of one size that stands with its top at their head: rising is
                    -- moving (which the engine carries a player along with), not growing.
                    if not b.sized then
                        b.sized = true
                        b.actor:SetActorScale3D({ X = RADIUS * 2 / 100, Y = RADIUS * 2 / 100, Z = BLOCK_H / 100 })
                    end
                    b.actor:K2_SetActorLocation({ X = p.x, Y = p.y, Z = top - BLOCK_H / 2 }, false, {}, true)
                    local dx, dy = l.X - p.x, l.Y - p.y
                    local over = dx * dx + dy * dy < REACH * REACH
                    local want = over and feet >= top - (b.on and KEEP_TO or ON_FROM)
                    if want ~= b.on then
                        b.on = want
                        b.actor:SetActorEnableCollision(want)
                        if want then Stack.stats.stood = Stack.stats.stood + 1 end
                    end
                    b.top = top
                end
            end
        end
        for id, b in pairs(blocks) do
            if not seen[id] then
                pcall(function() if valid(b.actor) then b.actor:K2_DestroyActor() end end)
                blocks[id] = nil
            end
        end
    end)
    if not ok and not Stack.failed then
        Stack.failed = true
        log("Stack: %s", tostring(err))
    end
end)

World.listen("stop", function()
    if not live() then return end
    -- (a world that is gone takes its actors with it)
    clear(not World.gone)
end)

-- The experimental switch: off takes the blocks away at once.
function Stack.apply(on)
    if not on then
        local player = World.player()
        clear(player ~= nil and owner == player:GetAddress())
    end
end

function Stack.shutdown()
    local player = World.player()
    clear(player ~= nil and owner == player:GetAddress())
end

-- (tests)
Stack.blocks = function() return blocks end

return Stack
