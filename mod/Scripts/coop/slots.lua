-- The slot machines in the night club's basement.
--
-- A row of three machines stands against the wall across the floor from the card table
-- (its pieces: coop/slotrow.lua; every game builds its own copy, nothing of it is saved).
-- A player sits down on a stool with the wardrobe key, picks a bet and spins with the
-- mouse. Each machine has three reels of 28 stops and shows three rows of them on its
-- screen; the middle row counts. Three of a kind pay (see PAYS), two cigars pay a
-- little; over time a machine gives back about 92 of every 100 dollars. The player's own
-- game draws the stops and pays; the others see the player on the stool and the same
-- reels turning on the machine.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Hud = require("coop.hud")
local Look = require("coop.look")
local Screen = require("coop.screen")
local Casino = require("coop.casino")
local ROW = require("coop.slotrow")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_SLOTS_GEN") or 0) + 1
_G.DDSMP_SLOTS_GEN = GEN
local function live() return rawget(_G, "DDSMP_SLOTS_GEN") == GEN end

local Slots = { seated = false }

---------------------------------------------------------------- numbers

-- The pictures on the reels (assets/slots/NAME.png, drawn by tools/slots_art.py). Every
-- machine has its own set, one for each of the town's crowds; the reels and what pays are
-- the same on all three (a set's first picture is the one that pays in twos, its last the
-- big one): the hippies' on the left, La Ballena's own in the middle (the club is his;
-- "the whale"), Keiji's dragons on the right.
local THEMES = {
    { "daisy", "peace", "leaf", "shroom", "blotter", "eye" },
    { "cigar", "fedora", "cash", "brick", "tommy", "whale" },
    { "sakura", "coin", "lantern", "katana", "cat", "dragon" },
}
local LOW = 1
-- What three of a kind on the middle row pay, in bets (the bet itself is not given back).
local PAYS = { 10, 8, 12, 25, 75, 500 }
local TWO_LOW = 3
-- The three reels: 6 of the first picture, then 7, 6, 5, 3 and 1 of the last each, in a
-- different order, no picture next to itself or one stop apart.
local STRIPS = {
    { 2, 1, 3, 2, 5, 4, 1, 2, 3, 4, 5, 3, 2, 1, 3, 6, 2, 1, 4, 5, 2, 1, 3, 4, 2, 3, 1, 4 },
    { 4, 5, 3, 4, 1, 2, 3, 4, 2, 1, 3, 5, 1, 2, 3, 6, 1, 2, 4, 3, 2, 5, 1, 2, 4, 1, 3, 2 },
    { 5, 4, 2, 6, 4, 5, 1, 3, 4, 2, 3, 1, 2, 4, 3, 5, 2, 1, 4, 2, 1, 3, 2, 1, 3, 2, 1, 3 },
}
local STOPS = #STRIPS[1]
local DEFAULT_BETS = { 10, 25, 50, 100, 250, 500 }
-- A spin: how many stops go by in a second, and when each reel comes to rest.
local SPEED = 18
local REST = { 0.9, 1.45, 2.0 }
-- A win this many bets or larger is told to the other players.
local BIG = 25
Slots.THEMES, Slots.PAYS, Slots.STRIPS = THEMES, PAYS, STRIPS

-- The middle row for three stops, and what it pays in bets.
local function line(stops)
    return STRIPS[1][stops[1]], STRIPS[2][stops[2]], STRIPS[3][stops[3]]
end

local function payout(stops)
    local a, b, c = line(stops)
    if a == b and b == c then return PAYS[a] end
    local low = (a == LOW and 1 or 0) + (b == LOW and 1 or 0) + (c == LOW and 1 or 0)
    if low == 2 then return TWO_LOW end
    return 0
end
Slots.payout = payout

local function bets()
    local list = Core.config.SlotBets
    if type(list) ~= "table" or #list == 0 then list = DEFAULT_BETS end
    return list
end

---------------------------------------------------------------- the row

-- Where things are, measured on the pieces: the screens are 45 across and stand upright
-- facing the room (+X); a player sits on the stool in front of one.
local FLOOR = -195
local SCREEN = 45
local TILE, GAP = 13, 0.8            -- a picture on the screen, and the room between two
local SIGN = { w = 59, h = 20 }      -- the board with the machine's name on its top
-- How a seated player is held and shown (Slots.tune for trying things out):
--   back, up, pitch  the view: this far in front of the screen, this far above its middle
--   sit              the figure on the stool, above where it would sit on a chair
--   roll             turns the pictures upright on the blocks they are drawn on
--   pull             how far a stool is drawn back from the machine while somebody sits on it
local tune = { back = 100, up = 2, pitch = -13, sit = 28, roll = 0, pull = 38 }
Slots.tune = tune
-- (what the board on each machine says)
local NAMES = { "Flower Power", "La Ballena", "Lucky Dragon" }

local row = nil          -- { actors, owner, machines = { { screen, stool, tiles, marks, pos, spin } } }

local function asset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if valid(o) then return o end
    return nil
end

local DIR = Core.MOD_DIR .. "/assets/slots/"

-- A picture, read from its file every time it is asked for. It must not be kept here for
-- later: the engine throws a picture away at its next clean-up once nothing of the game's
-- own holds it (a screen that was closed, a material nothing wears), a pointer kept in Lua
-- still looks valid afterwards, and using it crashes the game.
local function texture(name)
    local ok, made = pcall(function()
        local KRL = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
        return KRL:ImportFileAsTexture2D(World.player() or KRL, DIR .. name .. ".png")
    end)
    if ok and valid(made) then
        return made
    end
    log("Slots: picture %s could not be loaded: %s", name, tostring(made))
    return nil
end
Slots.texture = texture

-- Materials that show a picture or one colour whatever the light: a screen glows.
local UNLIT = "/Paper2D/OpaqueUnlitSpriteMaterial.OpaqueUnlitSpriteMaterial"

local function pictureMaterial(player, pic)
    local base = asset(UNLIT)
    if not base or not pic then return nil end
    local m = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary"):CreateDynamicMaterialInstance(player, base, FName("None"))
    if not valid(m) then return nil end
    m:SetTextureParameterValue(FName("SpriteTexture"), pic)
    return m
end

local function colourMaterial(player, r, g, b)
    local KRL = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local target = KRL:CreateRenderTarget2D(player, 4, 4, 2)
    KRL:ClearRenderTarget2D(player, target, { R = r, G = g, B = b, A = 1 })
    return pictureMaterial(player, target), target
end

local function clearRow()
    if not row then return end
    for _, a in ipairs(row.actors) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
    row = nil
end

-- The three pictures a reel shows when it rests at (or passes) a stop: the stop above, the
-- stop itself on the middle row, the stop below.
local function showReel(m, reel)
    local strip, at = STRIPS[reel], m.pos[reel]
    for r = 1, 3 do
        local stop = ((at + r - 3) % STOPS) + 1
        local tile = m.tiles[reel][r]
        -- (the row that counts is the bright one; above and below it the paper is dull)
        local mat = (r == 2 and row.pictures or row.dim)[m.theme][strip[stop]]
        if mat and valid(tile) then tile.StaticMeshComponent:SetMaterial(0, mat) end
    end
end

local function buildRow()
    local player = World.player()
    local world = player:GetWorld()
    row = { actors = {}, owner = player:GetAddress(), machines = { {}, {}, {} }, pictures = {}, dim = {}, keep = {} }
    local class = StaticFindObject("/Script/Engine.StaticMeshActor")
    local function put(meshPath, x, y, z, rot, sx, sy, sz)
        local mesh = asset(meshPath)
        if not mesh then
            log("Slots: mesh %s is not available", meshPath)
            return nil
        end
        local a = world:SpawnActor(class, { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        row.actors[#row.actors + 1] = a
        a:SetMobility(2)
        a.StaticMeshComponent:SetStaticMesh(mesh)
        a:K2_SetActorLocationAndRotation({ X = x, Y = y, Z = z }, rot, false, {}, true)
        a:SetActorScale3D({ X = sx, Y = sy, Z = sz })
        return a
    end
    for _, p in ipairs(ROW) do
        if p.tag == "screen" then
            row.machines[p.n].screen = { x = p.x, y = p.y, z = p.z }
        else
            local a = put(p.mesh, p.x, p.y, p.z, { Pitch = p.pitch or 0, Yaw = p.yaw or 0, Roll = p.roll or 0 }, p.sx or 1, p.sy or 1, p.sz or 1)
            if a and p.solid == false then a:SetActorEnableCollision(false) end
            if p.tag == "stool" then
                row.machines[p.n].stool = { x = p.x, y = p.y, z = p.z }
                row.machines[p.n].stoolActor = a
            end
        end
    end
    -- the screens: a dark glass, nine pictures on it, a mark in the machine's colour at each
    -- end of the row that counts (purple, blue, red)
    local CUBE = "/Engine/BasicShapes/Cube.Cube"
    local glass, glassTarget = colourMaterial(player, 0.004, 0.004, 0.006)
    local MARKS = { { 0.3, 0.03, 0.7 }, { 0.01, 0.13, 0.8 }, { 0.9, 0.03, 0.03 } }
    row.keep = { glassTarget }
    -- Every material is worn by a small unseen block under the floor for as long as the row
    -- stands: one that no reel shows at the moment would otherwise be thrown away at the
    -- engine's next clean-up (see `texture`).
    local function kept(mat)
        if not mat then return nil end
        local a = put(CUBE, ROW[1].x, ROW[1].y, FLOOR - 400, { Pitch = 0, Yaw = 0, Roll = 0 }, 0.01, 0.01, 0.01)
        if a then
            a:SetActorEnableCollision(false)
            a:SetActorHiddenInGame(true)
            a.StaticMeshComponent:SetMaterial(0, mat)
        end
        return mat
    end
    for t, names in ipairs(THEMES) do
        row.pictures[t], row.dim[t] = {}, {}
        for i, name in ipairs(names) do
            row.pictures[t][i] = kept(pictureMaterial(player, texture(name)))
            row.dim[t][i] = kept(pictureMaterial(player, texture(name .. "_dim"))) or row.pictures[t][i]
        end
    end
    local step = TILE + GAP
    local upright = { Pitch = 0, Yaw = 0, Roll = tune.roll }
    for n, m in ipairs(row.machines) do
        local s = m.screen
        m.theme = n
        if s then
            local function flat(x, y, z, w, h, mat)
                local a = put(CUBE, x, y, z, upright, 0.002, w / 100, h / 100)
                if a then
                    a:SetActorEnableCollision(false)
                    if mat then a.StaticMeshComponent:SetMaterial(0, mat) end
                    pcall(function() a.StaticMeshComponent:SetCastShadow(false) end)
                end
                return a
            end
            flat(s.x + 0.3, s.y, s.z, SCREEN + 1, SCREEN + 1, glass)
            m.tiles = {}
            -- (seen from the stool the first reel is on the left: towards +Y)
            for reel = 1, 3 do
                m.tiles[reel] = {}
                for r = 1, 3 do
                    m.tiles[reel][r] = flat(s.x + 0.6, s.y + (2 - reel) * step, s.z + (2 - r) * step, TILE, TILE, nil)
                end
            end
            local edge = step * 1.5 + 0.9
            local c = MARKS[n] or MARKS[3]
            local mark = colourMaterial(player, c[1], c[2], c[3])
            m.marks = { flat(s.x + 0.6, s.y + edge, s.z, 1.4, 3.2, mark), flat(s.x + 0.6, s.y - edge, s.z, 1.4, 3.2, mark) }
            -- the machine's name on a small lit board standing on its top (the top is
            -- 78 across at 9.5, its front edge 16 behind the screen)
            local sign = put(CUBE, s.x - 22, s.y, 9.5 + SIGN.h / 2, upright, 0.012, SIGN.w / 100, SIGN.h / 100)
            if sign then
                sign:SetActorEnableCollision(false)
                local words = pictureMaterial(player, texture("sign_" .. n))
                if words then sign.StaticMeshComponent:SetMaterial(0, words) end
                pcall(function() sign.StaticMeshComponent:SetCastShadow(false) end)
            end
            m.pos = { (n * 5) % STOPS + 1, (n * 11) % STOPS + 1, (n * 17) % STOPS + 1 }
            for reel = 1, 3 do showReel(m, reel) end
        end
    end
    log("Slots: the slot machines are set up (%d pieces)", #row.actors)
end

local function ensureRow()
    local player = World.player()
    if not player then return end
    if row and (row.owner ~= player:GetAddress() or not valid(row.actors[1])) then
        row = nil      -- another world: its actors went with it
    end
    if not row and Casino.nearClub() then
        local ok, e = xpcall(buildRow, debug.traceback)
        if not ok then
            log("Slots: could not set up the slot machines: %s", tostring(e))
            clearRow()
        end
    end
end

---------------------------------------------------------------- the reels turning

-- The game's own sounds: a button of its cash machines for a reel coming to rest, its
-- "cash received" for a win. A machine somebody else plays is heard from close by only.
local CLICK = "/Game/Audio/GUI/atmButtonClick.atmButtonClick"
local CASH = "/Game/Audio/GUI/popupCashRecieved_SFX.popupCashRecieved_SFX"
local ownMachine = nil       -- the machine our own player sits at

local function sound(m, path, volume, pitch)
    pcall(function()
        local player = World.player()
        if not player then return end
        if m ~= ownMachine then
            local l, s = player:K2_GetActorLocation(), m.screen
            if (l.X - s.x) ^ 2 + (l.Y - s.y) ^ 2 > 500 * 500 or math.abs(l.Z - s.z) > 250 then return end
            volume = volume * 0.4
        end
        local cue = asset(path)
        if cue then StaticFindObject("/Script/Engine.Default__GameplayStatics"):PlaySound2D(player, cue, volume, pitch, 0, nil, nil) end
    end)
end

-- Starts a machine's reels towards three stops; `done` is called when the last one rests.
local function start(m, stops, done)
    if not m or not m.tiles then
        if done then done() end
        return
    end
    m.spin = { t0 = os.clock(), stops = stops, from = { m.pos[1], m.pos[2], m.pos[3] }, rested = {}, done = done }
    m.flash = nil
    for _, a in ipairs(m.marks or {}) do pcall(function() if valid(a) then a:SetActorHiddenInGame(false) end end) end
    sound(m, CLICK, 0.8, 1.3)
end

-- Brings a turning machine to its stops at once.
local function rest(m)
    local spin = m and m.spin
    if not spin then return end
    m.spin = nil
    for reel = 1, 3 do
        m.pos[reel] = spin.stops[reel]
        pcall(showReel, m, reel)
    end
    sound(m, CLICK, 0.9, 0.8)
    if payout(spin.stops) > 0 then
        m.flash = os.clock() + 2.4
        sound(m, CASH, 1, 1)
    end
    if spin.done then spin.done() end
end

Core.onTick(function()
    if not live() or not row then return end
    local now = os.clock()
    for _, m in ipairs(row.machines) do
        local spin = m.spin
        if spin then
            local ok, e = pcall(function()
                local elapsed = now - spin.t0
                if elapsed >= REST[3] then
                    rest(m)
                    return
                end
                for reel = 1, 3 do
                    if not spin.rested[reel] then
                        local at
                        if elapsed >= REST[reel] then
                            spin.rested[reel] = true
                            at = spin.stops[reel]
                            sound(m, CLICK, 0.9, 0.8)
                        else
                            -- (the reels turn downwards: the stop above comes to the middle)
                            at = ((spin.from[reel] - 1 - math.floor(elapsed * SPEED)) % STOPS) + 1
                        end
                        if at ~= m.pos[reel] then
                            m.pos[reel] = at
                            showReel(m, reel)
                        end
                    end
                end
            end)
            if not ok then
                log("Slots: a spin: %s", tostring(e))
                m.spin = nil
                if spin.done then pcall(spin.done) end
            end
        elseif m.flash then
            -- a win: the red marks blink
            local over = now >= m.flash
            local hide = not over and math.floor((m.flash - now) * 5) % 2 == 1
            for _, a in ipairs(m.marks or {}) do pcall(function() if valid(a) then a:SetActorHiddenInGame(hide) end end) end
            if over then m.flash = nil end
        end
    end
end)

---------------------------------------------------------------- telling the others

local seatOf = {}        -- player id -> machine (the others on the stools)
local seat = nil         -- the stool we have taken: { index, owner, hud, at, cam }

local function relayed(sender, data)
    if not live() or not World.active then return nil end
    if World.role == "host" and not World.inWorld[sender] then return nil end
    if World.role == "guest" and sender ~= Net.S.owner then return nil end
    local who = sender
    if World.role == "guest" and data.p ~= nil then who = data.p end
    if who == Net.S.me then return nil end
    return who
end

-- Who sits where.
Net.on("sls", function(sender, data)
    local who = relayed(sender, data)
    if not who then return end
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= sender then Net.send("sls", { m = data.m, p = sender }, id) end
        end
    end
    local index = tonumber(data.m) or 0
    seatOf[who] = (index >= 1 and index <= 3) and index or nil
end)

-- A spin on somebody's machine.
Net.on("slt", function(sender, data)
    local who = relayed(sender, data)
    if not who then return end
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= sender then Net.send("slt", { m = data.m, a = data.a, b = data.b, c = data.c, p = sender }, id) end
        end
    end
    local index = tonumber(data.m) or 0
    local stops = { tonumber(data.a) or 0, tonumber(data.b) or 0, tonumber(data.c) or 0 }
    for reel = 1, 3 do
        if stops[reel] < 1 or stops[reel] > STOPS or stops[reel] % 1 ~= 0 then return end
    end
    if not row or not row.machines[index] then return end
    if seat and seat.index == index then return end        -- that is our own machine
    local m = row.machines[index]
    pcall(rest, m)
    pcall(start, m, stops, nil)
end)

-- A stool somebody sits on stands drawn back from the machine (pushed in, the sitter's
-- face would be at the screen); a free one is pushed in again.
Core.onTick(function()
    if not live() or not row then return end
    for index, m in ipairs(row.machines) do
        local out = seat ~= nil and seat.index == index
        if not out then
            for _, other in pairs(seatOf) do if other == index then out = true end end
        end
        if out ~= (m.out == true) and m.stool then
            m.out = out
            pcall(function()
                if valid(m.stoolActor) then
                    m.stoolActor:K2_SetActorLocation({ X = m.stool.x + (out and tune.pull or 0), Y = m.stool.y, Z = m.stool.z }, false, {}, true)
                end
            end)
        end
    end
end)

local function tellSeat()
    if not World.shared() then return end
    for _, id in ipairs(World.targets()) do Net.send("sls", { m = seat and seat.index or 0 }, id) end
end

---------------------------------------------------------------- the screen of a seated player

-- The player keeps looking at the machine in the room: its reels are the game. The words
-- and buttons are the card table's, in the card table's places and sizes: the cash and the
-- bet in a column on the right with the spin button under them and the way out at the
-- bottom, the bets in a row along the bottom, the outcome above the cash. What pays is
-- down the left side. The machines are bright, so the view is shaded towards its sides
-- and bottom (assets/slots/shade.png, clear around the machine's screen).
local scr = nil
local shown = {}
local game = nil         -- { bet (which of the bets), spinning, win, short }
local render

local function put(widget, ax, ay, x, y, alignX)
    scr.place(widget, ax, ay, x, y, alignX)
    shown[#shown + 1] = widget
    return widget
end

local function button(label, scale, ax, ay, x, y, fn)
    local b = scr.button(label, scale, fn)
    put(b.widget, ax, ay, x, y)
    return b
end

-- what pays, best first: three pictures and what they pay in bets (the last: two of the first)
local TABLE_ROWS = { { 6, 6, 6 }, { 5, 5, 5 }, { 4, 4, 4 }, { 3, 3, 3 }, { 1, 1, 1 }, { 2, 2, 2 }, { 1, 1 } }

-- What stays for as long as the player sits: the shade and the list of what pays.
local function layBack()
    local shade = scr.new("Image")
    pcall(function() shade:SetBrushFromTexture(texture("shade"), false) end)
    shade:SetVisibility(3)
    scr.fill(shade, 0)
    local SIZE, STEP, LINE = 44, 52, 60
    local icons = {}
    for i, name in ipairs(THEMES[seat.index] or THEMES[2]) do icons[i] = texture(name .. "_icon") end
    for i, r in ipairs(TABLE_ROWS) do
        local y = (i - (#TABLE_ROWS + 1) / 2) * LINE
        for k, symbol in ipairs(r) do
            local img = scr.new("Image")
            pcall(function() img:SetBrushFromTexture(icons[symbol], false) end)
            img:SetVisibility(3)
            scr.place(scr.sized(img, SIZE, SIZE), 0.14, 0.5, (k - 2) * STEP - 44, y)
        end
        local pays = #r == 2 and TWO_LOW or PAYS[r[1]]
        scr.place(scr.text("x" .. pays, "button", 22), 0.14, 0.5, STEP + 6, y, 0)
    end
end

local seeded = false
local function stop()
    if not seeded then
        math.randomseed(os.time() + math.floor(os.clock() * 1000))
        seeded = true
    end
    return math.random(1, STOPS)
end

-- Spins by themselves. Every press of AUTO adds ten of them, up to as many as the cash
-- pays for at the bet chosen (enough for 47: 10, 20, 30, 40, 47). They stop when they are
-- used up, when the cash runs out, at STOP, and when the player gets up.
local AUTO_STEP = 10
local AUTO_PAUSE, AUTO_PAUSE_WIN = 0.5, 1.5      -- seconds between two spins (after a win: to see it)

-- How many spins a press of AUTO would add now.
local function autoMore()
    if not game then return 0 end
    local bet = bets()[game.bet] or bets()[1]
    local left = game.auto or 0
    return math.max(0, math.min(AUTO_STEP, math.floor(Casino.cash() / bet) - left))
end

local function spin()
    if not seat or not game or game.spinning or not row then return end
    local m = row.machines[seat.index]
    local bet = bets()[game.bet] or bets()[1]
    game.nextAt = nil
    if not Casino.take(bet) then
        game.short, game.win, game.auto = true, nil, nil
        render()
        return
    end
    if game.auto then game.auto = game.auto - 1 end
    local stops = { stop(), stop(), stop() }
    game.spinning, game.win, game.short = true, nil, nil
    local owner = seat.owner
    start(m, stops, function()
        if not game then return end
        game.spinning = false
        local player = World.player()
        if not player or player:GetAddress() ~= owner then return end
        local times = payout(stops)
        if times > 0 then
            local win = times * bet
            local extra = Casino.pay(win)
            game.win = win
            if extra ~= "" then Hud.toast(extra, 6) end
            if times >= BIG then pcall(Casino.tell, string.format("won $%d at the slot machines", win)) end
        end
        -- the next of the spins that go by themselves
        if game.auto and game.auto > 0 and Casino.cash() >= bet then
            game.nextAt = os.clock() + (game.win and AUTO_PAUSE_WIN or AUTO_PAUSE)
        else
            game.auto = nil
        end
        if render then pcall(render) end
    end)
    if World.shared() then
        for _, id in ipairs(World.targets()) do Net.send("slt", { m = seat.index, a = stops[1], b = stops[2], c = stops[3] }, id) end
    end
    render()
end
Slots.spin = spin

local function addAuto()
    if not seat or not game then return end
    local more = autoMore()
    if more <= 0 then return end
    game.auto = (game.auto or 0) + more
    if game.spinning or game.nextAt then render() else spin() end
end

local function stopAuto()
    if not game then return end
    game.auto, game.nextAt = nil, nil
    render()
end
Slots.addAuto, Slots.stopAuto = addAuto, stopAuto

Core.onTick(function()
    if not live() or not Slots.seated or not game or not game.nextAt then return end
    if game.spinning or os.clock() < game.nextAt then return end
    game.nextAt = nil
    if game.auto and game.auto > 0 then
        local ok, e = pcall(spin)
        if not ok then
            log("Slots: a spin by itself: %s", tostring(e))
            game.auto = nil
        end
    end
end)

render = function()
    if not scr or not scr.open or not game then return end
    scr.removeAll(shown)
    shown = {}
    local money = Casino.cash()
    game.cashShown = money
    local list = bets()
    if game.bet > #list then game.bet = 1 end
    local bet = list[game.bet]
    if game.win then
        put(scr.text(string.format("YOU WIN  $%d", game.win), "button", 30, Screen.GREEN), 0.86, 0.4)
    elseif game.short then
        put(scr.text("NOT ENOUGH CASH", "button", 22, Screen.RED), 0.86, 0.4)
    end
    put(scr.text(string.format("CASH  $%d", money), "button", 18), 0.86, 0.47)
    put(scr.text(string.format("BET  $%d", bet), "price", 24, Screen.GREEN), 0.86, 0.52)
    -- (the spins that go by themselves: STOP where SPIN is, and how many are left)
    local auto = game.auto ~= nil
    if auto then
        button("STOP", 1.7, 0.86, 0.6, 0, 0, stopAuto)
    else
        local go = button("SPIN", 1.7, 0.86, 0.6, 0, 0, spin)
        if game.spinning or money < bet then scr.enable(go, false) end
    end
    local more = autoMore()
    local add = button(auto and string.format("AUTO  +%d", math.max(more, 0)) or string.format("AUTO  x%d", math.max(more, AUTO_STEP)),
        1.7, 0.86, 0.675, 0, 0, addAuto)
    if more <= 0 or (game.spinning and not auto) then scr.enable(add, false) end
    if auto then put(scr.text(string.format("%d  LEFT", game.auto), "button", 18), 0.86, 0.74) end
    local busy = game.spinning or auto
    for i, b in ipairs(list) do
        local btn = button(string.format("$%d", b), 1.7, 0.5, 0.88, (i - (#list + 1) / 2) * 150, 0, function()
            if game.spinning or game.auto or game.bet == i then return end
            game.bet, game.short = i, nil
            render()
        end)
        if i == game.bet then scr.tint(btn, Screen.GREEN) end
        if busy or money < b then scr.enable(btn, false) end
    end
    -- (getting up is always there: it ends the spins that go by themselves, and a spin
    -- still turning comes to rest and is paid)
    button("LEAVE MACHINE", 1.4, 0.86, 0.93, 0, 0, function() Slots.leave() end)
end
Slots.refresh = function() if render then render() end end

---------------------------------------------------------------- sitting down and getting up

-- How far the player's view is turned away from a place, in degrees (0 when there is no
-- view to ask).
local function turnedFrom(player, l, x, y)
    local view = nil
    pcall(function() view = player:GetController():GetControlRotation().Yaw end)
    if not view then return 0 end
    return math.abs(((math.deg(math.atan(y - l.Y, x - l.X)) - view + 180) % 360) - 180)
end

-- At the row: right at a stool, or up to 2.3 m from one and turned towards it. (The card
-- table across the floor answers the same key from 4 m, which reaches to the stools.)
local function nearRow()
    local player = World.player()
    if not player or not Casino.active() or not row then return false end
    local l = player:K2_GetActorLocation()
    if math.abs(l.Z - (FLOOR + 96)) > 120 then return false end
    for _, m in ipairs(row.machines) do
        local st = m.stool
        if st and m.screen then
            local d = (l.X - st.x) ^ 2 + (l.Y - st.y) ^ 2
            if d < 110 * 110 or (d < 230 * 230 and turnedFrom(player, l, m.screen.x, m.screen.y) < 80) then return true end
        end
    end
    return false
end

-- Standing on the row's side of the floor with the back to the card table: the table's
-- "sit down" is not meant.
local function tableBehind()
    local player = World.player()
    if not player then return false end
    local l = player:K2_GetActorLocation()
    local t = Casino.TABLE
    return l.X < t.x - 310 and turnedFrom(player, l, t.x, t.y) > 90
end

-- The free stool for the player: the one they look at (the free stool least off their
-- view, if that is within 25 degrees), otherwise the nearest. A stool is taken when
-- another player is on it.
local function freeStool()
    local player = World.player()
    if not player or not row then return nil end
    local l = player:K2_GetActorLocation()
    local view = nil
    pcall(function() view = player:GetController():GetControlRotation().Yaw end)
    local near, nearD = nil, nil
    local seen, seenScore = nil, nil
    for index, m in ipairs(row.machines) do
        local st = m.stool
        local taken = st == nil or m.screen == nil
        for _, other in pairs(seatOf) do if other == index then taken = true end end
        if not taken then
            for _, set in pairs(Avatar.puppets) do
                local p = set.player
                if p and (p.x - st.x - tune.pull / 2) ^ 2 + (p.y - st.y) ^ 2 < 60 * 60 then taken = true end
            end
        end
        if not taken then
            local d = (l.X - st.x) ^ 2 + (l.Y - st.y) ^ 2
            if not nearD or d < nearD then near, nearD = index, d end
            if view then
                local off = math.abs(((math.deg(math.atan(st.y - l.Y, st.x - l.X)) - view + 180) % 360) - 180)
                local score = off + math.sqrt(d) / 40
                if off < 25 and (not seenScore or score < seenScore) then seen, seenScore = index, score end
            end
        end
    end
    return seen or near
end
Slots.freeStool = freeStool

function Slots.enter()
    if Slots.seated then return true end
    local player = World.player()
    if not player or not Casino.active() then return false end
    ensureRow()
    if not row then return false end
    local index = freeStool()
    if not index then
        Hud.toast("Every slot machine is taken", 3)
        return false
    end
    local m = row.machines[index]
    -- (how high the eyes are above the player's middle: the same standing and crouching)
    local eye = 64
    pcall(function() eye = player.Camera:K2_GetComponentLocation().Z - player:K2_GetActorLocation().Z end)
    Casino.standUp(player)
    seat = {
        index = index, owner = player:GetAddress(),
        -- where the player is held (the view), and where the others see the figure
        at = { x = m.screen.x + tune.back, y = m.screen.y, z = m.screen.z + tune.up - eye },
        sit = { x = m.stool.x + tune.pull, y = m.stool.y, z = FLOOR + 90 + tune.sit },
    }
    pcall(function() seat.hud = player.HUD.Visibility end)
    scr = Screen.open()
    if not scr then
        Hud.toast("The slot machine could not be shown", 3)
        seat = nil
        return false
    end
    pcall(function()
        Casino.ghost(player, true)       -- (nothing stops at a seated player: see the card room)
        player.CharacterMovement:SetMovementMode(5, 0)       -- flying: nothing pulls the seated player down
        player.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 }
        player:K2_SetActorLocation({ X = seat.at.x, Y = seat.at.y, Z = seat.at.z }, false, {}, true)
        player:GetController():SetControlRotation({ Pitch = tune.pitch, Yaw = 180, Roll = 0 })
    end)
    pcall(function() player.HUD:SetVisibility(1) end)
    Avatar.noEmoteView, Avatar.sendZ, Avatar.sendXY, Avatar.sendYaw = true, seat.sit.z - seat.at.z, seat.sit, 180
    pcall(Avatar.setEmote, Avatar.TABLE_SEAT)
    Slots.seated = true
    ownMachine = m
    scr.onClose = function() if Slots.seated then Slots.leave() end end
    game = { bet = (game and game.bet) or 1 }
    shown = {}
    local ok, e = xpcall(layBack, debug.traceback)
    if not ok then log("Slots: the screen: %s", tostring(e)) end
    tellSeat()
    render()
    return true
end

local function release()
    ownMachine = nil
    Avatar.noEmoteView, Avatar.sendZ, Avatar.sendXY, Avatar.sendYaw = nil, nil, nil, nil
end

function Slots.leave()
    if not Slots.seated then return end
    Slots.seated = false
    -- a spin that is still turning comes to rest now and is paid
    if row and seat and row.machines[seat.index] then pcall(rest, row.machines[seat.index]) end
    local kept = game and game.bet
    game = { bet = kept or 1 }
    local s = scr
    scr, shown = nil, {}
    if s then
        s.onClose = nil
        pcall(s.close)
    end
    local player = World.player()
    if player and seat and seat.owner == player:GetAddress() then
        pcall(function()
            -- standing behind the stool
            player:K2_SetActorLocation({ X = seat.sit.x + 70, Y = seat.sit.y, Z = FLOOR + 100 }, false, {}, true)
            Casino.ghost(player, false)
            player.CharacterMovement:SetMovementMode(3, 0)
            player:GetController():ResetIgnoreLookInput()
        end)
        pcall(function() player.HUD:SetVisibility(seat.hud or 4) end)
    end
    release()
    pcall(Avatar.setEmote, 0)
    seat = nil
    tellSeat()
end

-- The seated player stays put and looks at the machine. Holding the left mouse button
-- lets them look around; letting go turns the view back.
local LMB = nil
local looking = false

local function turn(from, to, k)
    return from + (((to - from + 180) % 360) - 180) * k
end

Core.onTick(function()
    if not live() or not Slots.seated then return end
    local player = World.player()
    if not player or not seat or seat.owner ~= player:GetAddress() then
        Slots.seated, scr, seat = false, nil, nil
        release()
        return
    end
    pcall(function()
        player:K2_SetActorLocation({ X = seat.at.x, Y = seat.at.y, Z = seat.at.z }, false, {}, true)
        Avatar.sendYaw = 180
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
            pc:SetControlRotation({ Pitch = turn(pitch, tune.pitch, 0.25), Yaw = turn(r.Yaw, 180, 0.25), Roll = 0 })
        end
    end)
end)

-- The wardrobe key sits a player down: at a slot machine when they stand at the row,
-- otherwise at the card table (the card room's own answer to the key).
local TABLE = Casino.takeover
Look.takeover = {
    isOpen = function() return (live() and Slots.seated) or TABLE.isOpen() end,
    near = function() return (live() and nearRow()) or (TABLE.near() and not (live() and tableBehind())) end,
    prompt = function()
        if not (live() and nearRow()) then return TABLE.prompt() end
        local index = nil
        pcall(function() index = freeStool() end)
        return tostring(Core.config.WardrobeKey or "?"), index and ("Play " .. NAMES[index]) or "Play slots"
    end,
    toggle = function()
        if live() and Slots.seated then
            Slots.leave()
        elseif live() and not Casino.seated and nearRow() then
            Slots.enter()
        elseif Casino.seated or not (live() and tableBehind()) then
            TABLE.toggle()
        end
    end,
    move = function() end,
    choose = function() end,
}

---------------------------------------------------------------- keeping it all in order

-- In single player no "stop" comes when the world goes (back to the main menu, another
-- save loaded): a seat in a world that is gone is only forgotten.
local function forgetGoneWorld()
    Slots.seated = false
    local s = scr
    scr, shown = nil, {}
    if s then
        s.onClose = nil
        pcall(s.close)
    end
    seat = nil
    release()
    for id in pairs(seatOf) do seatOf[id] = nil end
end

Core.every(1, function()
    if not live() then return end
    if seat and not World.active then
        local player = World.player()
        if not player or player:GetAddress() ~= seat.owner then forgetGoneWorld() end
    end
    if not World.player() or not Casino.active() then return end
    ensureRow()
    for id in pairs(seatOf) do
        if not Avatar.puppets[id] then seatOf[id] = nil end
    end
    -- the cash shown follows what is in the pockets
    if Slots.seated and game and not game.spinning and scr and scr.open then
        local money = Casino.cash()
        if money ~= game.cashShown then
            game.cashShown = money
            pcall(render)
        end
    end
end)

-- Now and then again, for players who came in later.
Core.every(4, function()
    if live() and Slots.seated then pcall(tellSeat) end
end)

World.listen("stop", function()
    if not live() then return end
    if Slots.seated then pcall(Slots.leave) end
    for id in pairs(seatOf) do seatOf[id] = nil end
end)

-- A save loaded from inside the game: the level stays, so the row is taken away (and
-- built again for the new player).
World.listen("loading", function()
    local player = World.player()
    if live() and row and player and row.owner == player:GetAddress() then
        if Slots.seated then pcall(Slots.leave) end
        clearRow()
    end
end)

-- For reloading the module while developing.
function Slots.shutdown()
    if Slots.seated then pcall(Slots.leave) end
    clearRow()
end

Slots.state = function() return game, seat, row end
Slots.rebuild = function() clearRow() ensureRow() end
return Slots
