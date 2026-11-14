-- Tags: every player's own mark on the walls.
--
-- The game has twelve wall symbols and one number that says which of them the player
-- uses (questManager.chosenSpraySymbol); every sprayed wall (wallSprayMarking_C) shows
-- that one. Here a player can draw a tag of their own instead: the drawing is a list of
-- strokes, painted into a texture that one of the game's mural materials shows on the
-- wall. In a shared world every wall shows the tag of the player who sprayed it, a wall
-- sprayed in one game appears in the others, and the host keeps who sprayed what (and
-- their tags) for when those players are away.
--
-- The editor: the view moves to a camera in front of a brick wall put up well below the
-- ground, the drawing is on that wall, the tools are a panel on the right. It is opened
-- from the game's own symbol choice (the first time spraying becomes available, later
-- from Shady Comm's territory page), which gets one more button.

local Core = require("core")
local Net = require("net")
local json = require("json")
local World = require("coop.world")
local Screen = require("coop.screen")
local Look = require("coop.look")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_TAGS_GEN") or 0) + 1
_G.DDSMP_TAGS_GEN = GEN
local function live() return rawget(_G, "DDSMP_TAGS_GEN") == GEN end

local Tags = { stats = { sprayed = 0, mirrored = 0, dressed = 0, rendered = 0, sent = 0, received = 0 } }

local SIZE = 512                 -- the drawing is SIZE x SIZE
local MAX_POINTS = 3000          -- in one tag
local MAX_STROKES = 300
local MIN_W, MAX_W = 4, 80       -- stroke width, in the drawing's pixels
local CHUNK = 2400               -- characters of a drawing per message

local MARK = "/Game/TerritorySpraying/wallSprayMarking.wallSprayMarking_C"
local GIZMO = "/Game/TerritorySpraying/sprayPlacementGizmo.sprayPlacementGizmo_C"
local AREA = "/Game/TerritorySpraying/sprayAreaGizmo.sprayAreaGizmo_C"
local CHOICE = "/Game/GUI/symbolChoiceWidget.symbolChoiceWidget_C"
local CHOICE_USE = CHOICE .. ":BndEvt__btnUseSelected_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature"
local CHOICE_CLOSE = "BndEvt__btnClose_K2Node_ComponentBoundEvent_9_OnButtonClickedEvent__DelegateSignature"
local TAB = "/Game/GUI/EquipmentShopping/EquipmentShopCatFilter.EquipmentShopCatFilter_C"
local TAB_CLICK = TAB .. ":BndEvt__btnShowFunctional_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local PAINT_MAT = "/Game/Textures/Decals/MuraleGraffiti/WallGraffiti/wallGraffiti-01_Mat.wallGraffiti-01_Mat"
local SYMBOL_MAT = "/Game/Textures/Decals/WallSpraySymbols/wallSprayedSymbol-%02d_Decal.wallSprayedSymbol-%02d_Decal"
local WHITE = "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"
local BRICK = "/Game/AbandonedBuilding/TexturesResized/bricks01Mat.bricks01Mat"
local CUBE = "/Engine/BasicShapes/Cube.Cube"
local SPRAY_SOUND = "/Game/Audio/SFX/SprayingWalls/sprayingGrafiti-01.sprayingGrafiti-01"

-- The paints. Index 0 in a stroke is the eraser.
local PAINTS = {
    { "WHITE", 1, 1, 1 }, { "BLACK", 0.01, 0.01, 0.01 }, { "RED", 0.85, 0.03, 0.03 }, { "ORANGE", 1, 0.32, 0 },
    { "YELLOW", 1, 0.82, 0 }, { "GREEN", 0.1, 0.75, 0.08 }, { "TEAL", 0, 0.7, 0.62 }, { "BLUE", 0.03, 0.2, 0.95 },
    { "PURPLE", 0.42, 0.06, 0.8 }, { "PINK", 1, 0.08, 0.5 }, { "BROWN", 0.3, 0.13, 0.04 }, { "SILVER", 0.55, 0.57, 0.6 },
}
Tags.PAINTS = PAINTS
local CLEAR = { R = 0, G = 0, B = 0, A = 0 }

local function asset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if valid(o) then return o end
    pcall(function() LoadAsset((path:gsub("%.[^%.]+$", ""))) end)
    o = StaticFindObject(path)
    if valid(o) then return o end
    return nil
end

local function rendering() return Core.object("/Script/Engine.Default__KismetRenderingLibrary") end

-- A copy of the game that draws nothing (-nullrhi: the hosting-only mode, tests) keeps
-- the books and paints nothing.
local function canPaint() return not tostring(Core.commandLine or ""):lower():find("-nullrhi", 1, true) end

---------------------------------------------------------------- a drawing as text

-- "1|paint.width.points;paint.width.points": points are three characters each (nine bits
-- across, nine down).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64I = {}
for i = 1, #B64 do B64I[B64:byte(i)] = i - 1 end

local function encode(strokes)
    local out = {}
    for _, s in ipairs(strokes) do
        local p = {}
        for i = 1, #s.p, 2 do
            local v = (s.p[i] << 9) | s.p[i + 1]
            local a, b, c = (v >> 12) + 1, ((v >> 6) & 63) + 1, (v & 63) + 1
            p[#p + 1] = B64:sub(a, a) .. B64:sub(b, b) .. B64:sub(c, c)
        end
        out[#out + 1] = string.format("%d.%d.%s", s.c, s.w, table.concat(p))
    end
    return "1|" .. table.concat(out, ";")
end

-- The strokes of a drawing, or nil when the text is not one. Whatever comes from another
-- game is cut down to the limits here.
local function decode(text)
    if type(text) ~= "string" or text:sub(1, 2) ~= "1|" then return nil end
    local strokes, points = {}, 0
    for part in text:sub(3):gmatch("[^;]+") do
        local c, w, p = part:match("^(%d+)%.(%d+)%.([%w%-_]*)$")
        c, w = tonumber(c), tonumber(w)
        if not c or not w or c > #PAINTS or #strokes >= MAX_STROKES then return strokes end
        local s = { c = c, w = math.max(MIN_W, math.min(MAX_W, w)), p = {} }
        for i = 1, #p - 2, 3 do
            if points >= MAX_POINTS then break end
            local a, b, d = B64I[p:byte(i)], B64I[p:byte(i + 1)], B64I[p:byte(i + 2)]
            local v = (a << 12) | (b << 6) | d
            s.p[#s.p + 1] = (v >> 9) & 511
            s.p[#s.p + 1] = v & 511
            points = points + 1
        end
        if #s.p >= 2 then strokes[#strokes + 1] = s end
    end
    return strokes
end
Tags.encode, Tags.decode = encode, decode

local function countPoints(strokes)
    local n = 0
    for _, s in ipairs(strokes) do n = n + #s.p // 2 end
    return n
end

---------------------------------------------------------------- what is kept on disk

local function savedDir(sub)
    local base = os.getenv("LOCALAPPDATA")
    return base and (base:gsub("\\", "/") .. "/DrugDealerSimulator/Saved" .. (sub or "")) or Core.MOD_DIR
end
local function suffix() return Core.instance and ("_" .. Core.instance) or "" end
local function myPath() return string.format("%s/ddsmp_tag%s.json", savedDir("/SaveGames"), suffix()) end
local function wallsPath() return string.format("%s/ddsmp_walls%s.json", savedDir(), suffix()) end

local function readJson(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    local ok, data = pcall(json.decode, text)
    return ok and type(data) == "table" and data or nil
end

local function writeJson(path, data)
    local ok, text = pcall(json.encode, data)
    if not ok then return false end
    local f = io.open(path, "wb")
    if not f then
        log("Tags: cannot write %s", path)
        return false
    end
    f:write(text)
    f:close()
    return true
end

-- This player's tag: the drawing, whether it is in use (otherwise the game's symbol is),
-- and the tools last used in the editor.
local my = { use = false, d = "", w = 22, c = 3 }
-- The world's walls (this game's own worlds): who sprayed which wall, when it was not the
-- world's owner, and those players' tags as last heard.
local kept = { owners = {}, tags = {}, seen = {} }
local loaded = false
local keptDirty = false

local function load()
    if loaded then return end
    loaded = true
    local data = readJson(myPath())
    if data then
        if type(data.d) == "string" and decode(data.d) then my.d = data.d end
        my.use = data.use == true and my.d ~= ""
        if tonumber(data.w) then my.w = math.max(MIN_W, math.min(MAX_W, math.floor(tonumber(data.w)))) end
        if PAINTS[tonumber(data.c) or 0] then my.c = tonumber(data.c) end
    end
    data = readJson(wallsPath())
    if data then
        if type(data.owners) == "table" then
            for k, v in pairs(data.owners) do if type(k) == "string" and type(v) == "string" then kept.owners[k] = v end end
        end
        if type(data.tags) == "table" then
            for k, v in pairs(data.tags) do
                if type(k) == "string" and type(v) == "table" then
                    if type(v.d) == "string" and decode(v.d) then kept.tags[k] = { d = v.d }
                    elseif tonumber(v.s) then kept.tags[k] = { s = math.floor(tonumber(v.s)) } end
                end
            end
        end
        if type(data.seen) == "table" then
            for k, v in pairs(data.seen) do if type(k) == "string" and tonumber(v) then kept.seen[k] = tonumber(v) end end
        end
    end
end

local function saveMine() writeJson(myPath(), my) end

---------------------------------------------------------------- who is who

local function me() return tostring(Net.S.me or "me") end

-- The player whose world this is: walls nobody is noted for are theirs.
local function worldOwner()
    if World.active and World.role == "guest" then return tostring(World.host or Net.S.owner or "host") end
    return me()
end

-- In a guest's game what the host told us; in our own world what is kept on disk.
local session = { owners = {}, tags = {} }
local function ownWorld() return not (World.active and World.role == "guest") end
local function owners() return ownWorld() and kept.owners or session.owners end
local function tagsOfOthers() return ownWorld() and kept.tags or session.tags end

local version = {}          -- player -> number, raised when their tag changes
local function bump(pid) version[pid] = (version[pid] or 0) + 1 end

local function chosenSymbol()
    local n = 0
    pcall(function() n = tonumber(Core.find("questManager_C").chosenSpraySymbol) or 0 end)
    return n
end

local function myTag()
    load()
    if my.use and my.d ~= "" then return { d = my.d } end
    return { s = chosenSymbol() }
end

local function tagOf(pid)
    if pid == me() then return myTag() end
    return tagsOfOthers()[pid]
end
Tags.tagOf = tagOf

local function wallKey(x, y, z)
    return string.format("%d_%d_%d", math.floor(x / 5 + 0.5), math.floor(y / 5 + 0.5), math.floor(z / 5 + 0.5))
end
local function keyOf(marking)
    local l = marking:K2_GetActorLocation()
    return wallKey(l.X, l.Y, l.Z), l
end

---------------------------------------------------------------- painting

local white = nil        -- the plain texture strokes are stamped with

-- Per world (its actors and textures go with it): the textures, the materials showing
-- them, and which marking wears what.
local W = nil
local function world()
    local player = World.player()
    if not player then return nil end
    local a = player:GetAddress()
    -- (a new world's character can be at the address the last one had)
    if not W or W.owner ~= a or W.load ~= World.loadStartedAt then
        W = { owner = a, load = World.loadStartedAt, slots = {}, symbols = {}, dressed = {}, jobs = {}, look = {} }
        white = nil
    end
    return W, player
end

-- A texture to paint into and a material that shows it. The material belongs to a decal
-- of its own, hidden far below the ground: that actor is what keeps both alive.
local function slotFor(key)
    local w, player = world()
    if not w then return nil end
    local s = w.slots[key]
    if s then return s end
    local ok, made = pcall(function()
        local base = asset(PAINT_MAT)
        if not base then error("material missing") end
        local l = player:K2_GetActorLocation()
        local holder = player:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.DecalActor"),
            { X = l.X, Y = l.Y, Z = l.Z - 9000 }, { Pitch = 0, Yaw = 0, Roll = 0 })
        holder:SetActorHiddenInGame(true)
        local rt = rendering():CreateRenderTarget2D(player, SIZE, SIZE, 2)
        local d = holder.Decal
        d:SetDecalMaterial(base)
        local mid = d:CreateDynamicMaterialInstance()
        mid:SetTextureParameterValue(FName("Diffuse"), rt)
        rendering():ClearRenderTarget2D(player, rt, CLEAR)
        return { rt = rt, mid = mid, holder = holder, text = nil }
    end)
    if not ok or not made then
        log("Tags: no texture for %s: %s", tostring(key), tostring(made))
        return nil
    end
    w.slots[key] = made
    return made
end

local function withCanvas(player, rt, fn)
    local canvas, size, ctx = {}, {}, {}
    rendering():BeginDrawCanvasToRenderTarget(player, rt, canvas, size, ctx)
    local ok, e = pcall(fn, canvas.Canvas)
    rendering():EndDrawCanvasToRenderTarget(player, ctx)
    if not ok then error(e, 0) end
end

local function colour(c)
    local p = PAINTS[c]
    return { R = p[2], G = p[3], B = p[4], A = 1 }
end

-- A round patch of paint.
local function disc(cv, x, y, w, c)
    cv:K2_DrawPolygon(white, { X = x, Y = y }, { X = w / 2, Y = w / 2 }, w > 48 and 28 or (w > 24 and 20 or 12), c)
end

-- A round patch of nothing. Only a rectangle can write "no paint" (it is drawn opaque;
-- lines and polygons are blended, and blending nothing changes nothing), so the patch is
-- made of strips two pixels high, each as wide as the circle is at its height.
local function rubOut(cv, x, y, w)
    local r = w / 2
    local n = math.max(4, math.min(40, math.ceil(w / 2)))
    local h = w / n
    for i = 0, n - 1 do
        local dy = -r + (i + 0.5) * h
        local half = math.sqrt(math.max(0, r * r - dy * dy))
        cv:K2_DrawTexture(white, { X = x - half, Y = y + dy - h / 2 }, { X = half * 2, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, CLEAR, 0, 0, { X = 0.5, Y = 0.5 })
    end
end

-- One piece of a stroke: from (x0, y0) to (x1, y1), or a single dab when x0 is nil.
-- Every point of a stroke is a disc as wide as the stroke: that makes its ends and its
-- corners round. Between two points lies a line. The engine's thick line reaches half
-- its width past both of its ends (square ends that would bury the discs), so the line is
-- drawn that much shorter at each end; where two points are closer together than the
-- stroke is wide there is no room for a line and discs fill the way.
local function segment(cv, s, x0, y0, x1, y1)
    local w = s.w
    local dx, dy, len = 0, 0, 0
    if x0 then
        dx, dy = x1 - x0, y1 - y0
        len = math.sqrt(dx * dx + dy * dy)
    end
    if s.c == 0 then
        -- the way between the two points: a rectangle turned along it; a round patch at the end
        if len > 0.5 then
            cv:K2_DrawTexture(white, { X = (x0 + x1) / 2 - len / 2, Y = (y0 + y1) / 2 - w / 2 }, { X = len, Y = w }, { X = 0, Y = 0 }, { X = 1, Y = 1 },
                CLEAR, 0, math.deg(math.atan(dy, dx)), { X = 0.5, Y = 0.5 })
        end
        rubOut(cv, x1, y1, w)
        return
    end
    local c = colour(s.c)
    if len > w + 1 then
        local k = (w / 2) / len
        cv:K2_DrawLine({ X = x0 + dx * k, Y = y0 + dy * k }, { X = x1 - dx * k, Y = y1 - dy * k }, w, c)
    elseif len > 0 then
        local n = math.ceil(len / math.max(1.5, w / 5))
        for i = 1, n - 1 do disc(cv, x0 + dx * i / n, y0 + dy * i / n, w, c) end
    end
    disc(cv, x1, y1, w, c)
end

-- Paints strokes[si] from its point pi on, at most `budget` points; returns where it
-- stopped (nil when everything is painted).
local function paintSome(cv, strokes, si, pi, budget)
    while strokes[si] do
        local s = strokes[si]
        local n = #s.p // 2
        while pi <= n do
            if budget <= 0 then return si, pi end
            local x, y = s.p[pi * 2 - 1], s.p[pi * 2]
            if pi == 1 then segment(cv, s, nil, nil, x, y) else segment(cv, s, s.p[pi * 2 - 3], s.p[pi * 2 - 2], x, y) end
            pi = pi + 1
            budget = budget - (s.c == 0 and 6 or 1)      -- a point of the eraser is many strips
        end
        si, pi = si + 1, 1
    end
    return nil
end

-- Paints a whole drawing into a slot, a part of it per tick (a long one takes a few).
local function startRender(slot, strokes)
    local w, player = world()
    if not w or not slot then return end
    white = white or asset(WHITE)
    pcall(function() rendering():ClearRenderTarget2D(player, slot.rt, CLEAR) end)
    for i = #w.jobs, 1, -1 do if w.jobs[i].slot == slot then table.remove(w.jobs, i) end end
    if strokes and #strokes > 0 then w.jobs[#w.jobs + 1] = { slot = slot, strokes = strokes, si = 1, pi = 1 } end
    Tags.stats.rendered = Tags.stats.rendered + 1
end

local function renderNow(slot, strokes)
    local w, player = world()
    if not w or not slot then return end
    white = white or asset(WHITE)
    for i = #w.jobs, 1, -1 do if w.jobs[i].slot == slot then table.remove(w.jobs, i) end end
    pcall(function()
        rendering():ClearRenderTarget2D(player, slot.rt, CLEAR)
        if #strokes > 0 then withCanvas(player, slot.rt, function(cv) paintSome(cv, strokes, 1, 1, MAX_POINTS + 1) end) end
    end)
end

Core.onTick(function()
    if not live() or not W or #W.jobs == 0 then return end
    local w, player = world()
    if not w or #w.jobs == 0 then return end
    local job = w.jobs[1]
    local ok, e = pcall(function()
        withCanvas(player, job.slot.rt, function(cv)
            job.si, job.pi = paintSome(cv, job.strokes, job.si, job.pi, 220)
        end)
    end)
    if not ok then
        log("Tags: painting failed: %s", tostring(e))
        job.si = nil
    end
    if not job.si then table.remove(w.jobs, 1) end
end)

---------------------------------------------------------------- the walls

local function symbolMaterial(n)
    local w = world()
    if not w or n < 1 or n > 12 then return nil end
    if w.symbols[n] == nil then w.symbols[n] = asset(string.format(SYMBOL_MAT, n, n)) or false end
    return w.symbols[n] or nil
end

-- Gives a wall the tag of whoever sprayed it.
local function dress(marking, address, early)
    local w = world()
    if not w then return end
    address = address or marking:GetAddress()
    local key = keyOf(marking)
    local pid = owners()[key] or worldOwner()
    local tag = tagOf(pid)
    w.look[address] = tag and (tag.d and ("drawing of " .. pid .. " (" .. #tag.d .. ")") or ("symbol " .. tostring(tag.s) .. " of " .. pid)) or ("nothing known of " .. pid)
    if tag then
        if tag.d then
            local slot = canPaint() and slotFor(pid) or nil
            if slot then
                if slot.text ~= tag.d then
                    slot.text = tag.d
                    startRender(slot, decode(tag.d) or {})
                end
                marking.Decal:SetDecalMaterial(slot.mid)
            end
        else
            local m = symbolMaterial(tonumber(tag.s) or 0)
            if m then marking.Decal:SetDecalMaterial(m) end
        end
        Tags.stats.dressed = Tags.stats.dressed + 1
    end
    if early == nil then early = (w.dressed[address] or ""):sub(-1) == "e" end
    w.dressed[address] = pid .. "#" .. (version[pid] or 0) .. (early and "e" or "")
    if ownWorld() and owners()[key] then kept.seen[key] = os.time() end
end

-- The game sets its own symbol when a wall appears and a second later; ours goes back on
-- top right away.
Core.Hooks.add(MARK .. ":setSpraySymbol", function(ctx)
    if not live() or not Core.enabled("Tags") then return end
    pcall(function()
        local m = ctx:get()
        if valid(m) then dress(m) end
    end)
end)

local lastSig, sentSig = nil, nil
local sendMine      -- defined below
local firstSeen = {}    -- marking address -> when it was first looked at

-- Looks at every wall once a second: a wall whose sprayer's tag has changed (or that has
-- none yet) is dressed. Also notices when this player's tag is another one.
Core.every(1, function()
    if not live() or not Core.enabled("Tags") then return end
    local w = world()
    if not w or not Core.find("questManager_C") then return end
    load()
    local tag = myTag()
    local sig = tag.d or ("s" .. tostring(tag.s))
    if sig ~= lastSig then
        lastSig = sig
        bump(me())
    end
    if World.shared() and sentSig ~= sig then
        sentSig = sig
        sendMine()
    end
    local list = Core.actors(MARK)
    if not list then return end
    local still, seen, now = {}, {}, os.clock()
    for _, m in ipairs(list) do
        pcall(function()
            local address = m:GetAddress()
            seen[address] = firstSeen[address] or now
            -- the game puts its own symbol on a wall a second after it appears: a wall is
            -- dressed when first seen and once more after that
            local early = now - seen[address] < 2.5
            local key = keyOf(m)
            local pid = owners()[key] or worldOwner()
            local want = pid .. "#" .. (version[pid] or 0) .. (early and "e" or "")
            if w.dressed[address] ~= want then dress(m, address, early) end
            still[address] = w.dressed[address]
        end)
    end
    w.dressed, firstSeen = still, seen
    for address in pairs(w.look) do if not still[address] then w.look[address] = nil end end
end)

---------------------------------------------------------------- between the games

local function sendTag(pid, tag, target)
    if not tag then return end
    if tag.d then
        local n = math.max(1, math.ceil(#tag.d / CHUNK))
        local id = os.time() % 100000 * 10 + math.random(0, 9)
        for i = 1, n do
            Net.send("tagme", { p = pid, n = id, i = i, k = n, d = tag.d:sub((i - 1) * CHUNK + 1, i * CHUNK) }, target)
        end
    else
        Net.send("tagme", { p = pid, s = tonumber(tag.s) or 0 }, target)
    end
    Tags.stats.sent = Tags.stats.sent + 1
end

sendMine = function()
    for _, id in ipairs(World.targets()) do sendTag(me(), myTag(), id) end
end

local function setTag(pid, tag)
    local t = tagsOfOthers()
    local old = t[pid]
    if old and old.d == tag.d and old.s == tag.s then return end
    t[pid] = tag
    bump(pid)
    if ownWorld() then keptDirty = true end
end

local parts = {}        -- sender|player|id -> { k, got, list }
Net.on("tagme", function(sender, data)
    if not live() or not Core.enabled("Tags") or not World.isPeer(sender) then return end
    local host = World.role == "guest" and sender == (World.host or Net.S.owner)
    local pid = host and type(data.p) == "string" and data.p or tostring(sender)
    if pid == me() then return end
    local tag = nil
    if type(data.d) == "string" then
        local k, i = tonumber(data.k) or 1, tonumber(data.i) or 1
        if k < 1 or k > 8 or i < 1 or i > k or #data.d > CHUNK then return end
        local id = tostring(sender) .. "|" .. pid .. "|" .. tostring(data.n)
        local e = parts[id] or { k = k, got = 0, list = {} }
        parts[id] = e
        if not e.list[i] then
            e.list[i] = data.d
            e.got = e.got + 1
        end
        if e.got < e.k then return end
        parts[id] = nil
        local text = table.concat(e.list)
        local strokes = decode(text)
        if not strokes then return end
        tag = { d = encode(strokes) }
    else
        tag = { s = math.max(0, math.min(12, math.floor(tonumber(data.s) or 0))) }
    end
    Tags.stats.received = Tags.stats.received + 1
    setTag(pid, tag)
    -- the host tells the other guests
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= sender then sendTag(pid, tag, id) end
        end
    end
end)

local function distance2(l, x, y, z) return (l.X - x) ^ 2 + (l.Y - y) ^ 2 + (l.Z - z) ^ 2 end

local function markingAt(x, y, z, reach)
    local best, bestD = nil, (reach or 8) ^ 2
    for _, m in ipairs(Core.actors(MARK) or {}) do
        local ok, d = pcall(function() return distance2(m:K2_GetActorLocation(), x, y, z) end)
        if ok and d <= bestD then best, bestD = m, d end
    end
    return best
end

-- A wall sprayed in another game. The copy is made the way a loaded one is: the game then
-- only shows it, it does not count it as this player's work.
local function mirror(data, pid)
    local w, player = world()
    if not w then return nil end
    local m = markingAt(data.x, data.y, data.z)
    if not m then
        local class = Core.class(MARK)
        if not class then return nil end
        m = player:GetWorld():SpawnActor(class, { X = data.x, Y = data.y, Z = data.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(m) then return nil end
        m.spawned = true
        if tonumber(data.l) and data.l > 0 then m.Lifetime = data.l end
        m:K2_SetActorRotation({ Pitch = tonumber(data.a) or 0, Yaw = tonumber(data.b) or 0, Roll = tonumber(data.c) or 0 }, false)
        Tags.stats.mirrored = Tags.stats.mirrored + 1
    end
    local key = wallKey(data.x, data.y, data.z)
    if pid ~= worldOwner() then
        owners()[key] = pid
        if ownWorld() then
            kept.seen[key] = os.time()
            keptDirty = true
        end
    end
    dress(m)
    return m
end

-- What spraying does to the area (the game does it in the sprayer's own game, where the
-- shared numbers are the host's): done once more in the host's game for a guest's wall.
local function areaEffect(marking)
    pcall(function()
        local effect = marking.defExposureEffect
        local hour = Core.find("dayTimeControler_C").curHour
        if hour >= 22 or hour <= 6 then effect = effect * 1.2 end
        for _, g in ipairs(Core.actors(AREA) or {}) do
            if marking:IsOverlappingActor(g) and valid(g.saleAreaManager) then
                g.saleAreaManager:addAreaExposure(g.saleAreaAffected:ToString(), effect)
                return
            end
        end
    end)
end

Net.on("tagwall", function(sender, data)
    if not live() or not Core.enabled("Tags") or not World.isPeer(sender) then return end
    if type(data.x) ~= "number" or type(data.y) ~= "number" or type(data.z) ~= "number" then return end
    local host = World.role == "guest" and sender == (World.host or Net.S.owner)
    local pid = host and type(data.p) == "string" and data.p or tostring(sender)
    if pid == me() then return end
    local ok, m = pcall(mirror, data, pid)
    if not ok then
        log("Tags: a wall sprayed by another player could not be shown: %s", tostring(m))
        return
    end
    if World.role == "host" then
        if m then Core.after(0.6, function() if Core.alive(m) then areaEffect(m) end end) end
        for id in pairs(World.inWorld) do
            if id ~= sender then
                Net.send("tagwall", { p = pid, x = data.x, y = data.y, z = data.z, a = data.a, b = data.b, c = data.c, l = data.l }, id)
            end
        end
    end
end)

-- Which walls are whose: the host to a guest.
Net.on("tagwalls", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) then return end
    if type(data.o) ~= "table" then return end
    for k, v in pairs(data.o) do
        if type(k) == "string" and type(v) == "string" then session.owners[k] = v end
    end
    if W then W.dressed = {} end
end)

-- This player has just sprayed a wall (the game's own function has put it up).
Core.Hooks.add(GIZMO .. ":PutSpraySymbol", function(ctx)
    if not live() or not Core.enabled("Tags") then return end
    pcall(function()
        local g = ctx:get()
        if not valid(g) then return end
        local l, r = g:K2_GetActorLocation(), g:K2_GetActorRotation()
        local m = markingAt(l.X, l.Y, l.Z, 4)
        if not m then return end
        Tags.stats.sprayed = Tags.stats.sprayed + 1
        local key = wallKey(l.X, l.Y, l.Z)
        if me() ~= worldOwner() then owners()[key] = me() else owners()[key] = nil end
        dress(m)
        if World.shared() then
            local life = 0
            pcall(function() life = m.Lifetime end)
            for _, id in ipairs(World.targets()) do
                Net.send("tagwall", { p = me(), x = l.X, y = l.Y, z = l.Z, a = r.Pitch, b = r.Yaw, c = r.Roll, l = life }, id)
            end
        end
    end)
end)

-- A guest has arrived: everybody's tag and the list of walls that are not the host's.
World.listen("peer", function(id)
    if not live() or not Core.enabled("Tags") then return end
    load()
    sendTag(me(), myTag(), id)
    local sent = { [me()] = true, [tostring(id)] = true }
    local list, n = {}, 0
    local present = {}
    for _, m in ipairs(Core.actors(MARK) or {}) do pcall(function() present[keyOf(m)] = true end) end
    for key, pid in pairs(kept.owners) do
        if present[key] then
            list[key] = pid
            n = n + 1
            if not sent[pid] and kept.tags[pid] then
                sent[pid] = true
                sendTag(pid, kept.tags[pid], id)
            end
            if n >= 40 then
                Net.send("tagwalls", { o = list }, id)
                list, n = {}, 0
            end
        end
    end
    if n > 0 then Net.send("tagwalls", { o = list }, id) end
    for other in pairs(World.inWorld) do
        local pid = tostring(other)
        if not sent[pid] and kept.tags[pid] then
            sent[pid] = true
            sendTag(pid, kept.tags[pid], id)
        end
    end
end)

World.listen("start", function(role)
    if not live() then return end
    session = { owners = {}, tags = {} }
    parts = {}
    sentSig = nil           -- the next look sends this player's tag to the others
    if W then W.dressed = {} end
end)

World.listen("stop", function()
    if not live() then return end
    session = { owners = {}, tags = {} }
    parts = {}
    sentSig = nil
    if W then W.dressed = {} end
end)

-- The walls file is written a few seconds after something in it changed. Walls not seen
-- for a long time are dropped when the list gets long.
Core.every(5, function()
    if not live() or not keptDirty or not loaded then return end
    keptDirty = false
    local n = 0
    for _ in pairs(kept.owners) do n = n + 1 end
    if n > 1500 then
        local now = os.time()
        for key in pairs(kept.owners) do
            if now - (kept.seen[key] or 0) > 30 * 86400 then kept.owners[key], kept.seen[key] = nil, nil end
        end
    end
    writeJson(wallsPath(), kept)
end)

---------------------------------------------------------------- the editor

local ed = nil
local TILE, HALF = 160, 50           -- brick tile and half the side of the drawing on the wall
local CAM_BACK, CAM_SIDE, CAM_FOV = 205, 34, 60
local PANEL = { x0 = 0.685, x1 = 0.975, cx = 0.83 }

local function destroyAll(list)
    for _, a in ipairs(list or {}) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
end

local function closeEditor(save)
    local e = ed
    if not e then return end
    ed = nil
    if save then
        my.d = encode(e.strokes)
        my.use = #e.strokes > 0
        log("Tags: tag saved (%d stroke(s), %d point(s))", #e.strokes, countPoints(e.strokes))
    end
    my.w, my.c = e.width, e.paint
    saveMine()
    local s = e.s
    s.onClose = nil
    pcall(s.close)
    local player = World.player()
    if not World.gone and player and player:GetAddress() == e.owner then
        pcall(function()
            local pc = player:GetController()
            pc:SetViewTargetWithBlend(player, 0.25, 0, 0, false)
            pc:SetIgnoreMoveInput(false)
            pc:SetIgnoreLookInput(false)
            player.disableWorldInteraction = e.interaction == true
            player.HUD:SetVisibility(e.hud or 4)
        end)
        destroyAll(e.actors)
    end
end
Tags.closeEditor = closeEditor

-- Mouse position in the picture's pixels and in the units the screen is laid out in.
local function pointer(e)
    local ok, x, y, w, h, down = pcall(Look.mouse)
    if not ok or not w or w <= 0 or not h or h <= 0 then return nil end
    if not x or not y then return nil, nil, nil, nil, false, w, h end
    local uw, uh = e.s.units()
    return x, y, x / w * uw, y / h * uh, down, w, h
end

-- Where the drawing's square is in the picture (pixels), from the camera.
local function findSquare(e)
    local player = World.player()
    local pc = player and player:GetController()
    if not valid(pc) then return end
    local a, b = {}, {}
    local o = e.at
    local okA = pc:ProjectWorldLocationToScreen({ X = o.x, Y = o.y - HALF, Z = o.z + HALF }, a, false)
    local okB = pc:ProjectWorldLocationToScreen({ X = o.x, Y = o.y + HALF, Z = o.z - HALF }, b, false)
    if okA and okB and tonumber(a.X) and tonumber(b.X) and b.X - a.X > 20 and b.Y - a.Y > 20 then
        e.rect = { x0 = a.X, y0 = a.Y, x1 = b.X, y1 = b.Y }
    end
end

local function slotPos(slot, x, y) pcall(function() slot:SetPosition({ X = x, Y = y }) end) end

-- The sample of the stroke in the panel: round, like a dab on the wall. A widget has no
-- round shape of its own, so a white disc is painted once into a small picture and an
-- Image shows it in the paint's colour. Returns the widget and whether it is that Image
-- (if the picture cannot be made, a plain square as before).
local function sample(s, player)
    local image = nil
    local ok = pcall(function()
        white = white or asset(WHITE)
        local rt = rendering():CreateRenderTarget2D(player, 128, 128, 2)
        rendering():ClearRenderTarget2D(player, rt, CLEAR)
        withCanvas(player, rt, function(cv)
            cv:K2_DrawPolygon(white, { X = 64, Y = 64 }, { X = 63, Y = 63 }, 48, { R = 1, G = 1, B = 1, A = 1 })
        end)
        local i = s.new("Image")
        i.Brush.ResourceObject = rt
        i.Brush.ImageSize = { X = 128, Y = 128 }
        i:SetVisibility(3)
        image = i
    end)
    if ok and valid(image) then return image, true end
    return s.box(Screen.WHITE), false
end

local function refreshTools(e)
    local s = e.s
    local uw, uh = s.units()
    local sw = e.swatches[e.paint]
    if sw and not e.eraser then
        slotPos(e.frameSlot, sw.x - PANEL.cx * uw, sw.y - 0.5 * uh)
        pcall(function() e.frame:SetVisibility(3) end)
    else
        pcall(function() e.frame:SetVisibility(1) end)
    end
    local f = (e.width - MIN_W) / (MAX_W - MIN_W)
    slotPos(e.knobSlot, e.track.x0 + f * (e.track.x1 - e.track.x0) - PANEL.cx * uw, e.track.y - 0.5 * uh)
    -- the dab: the stroke's width as it is on the wall
    local px = e.rect and (e.rect.x1 - e.rect.x0) or 300
    local _, _, _, _, _, w = pointer(e)
    local side = math.max(4, e.width / SIZE * px * (uw / (w or 1920)))
    pcall(function()
        e.dab:SetWidthOverride(side)
        e.dab:SetHeightOverride(side)
        local p = PAINTS[e.paint]
        local c = e.eraser and { R = 0.2, G = 0.2, B = 0.2, A = 1 } or { R = p[2], G = p[3], B = p[4], A = 1 }
        if e.dabRound then e.dabBox:SetColorAndOpacity(c) else e.dabBox:SetBrushColor(c) end
    end)
    s.tint(e.eraserButton, e.eraser and Screen.GREEN or Screen.WHITE)
    local left = MAX_POINTS - countPoints(e.strokes) - (e.cur and #e.cur.p // 2 or 0)
    -- how much is left is not shown (nobody gets near the limit); only that it is used up
    pcall(function() e.left:SetText(FText(left <= 0 and "OUT OF PAINT" or "")) end)
end

local function repaint(e) renderNow(e.slot, e.strokes) end

-- The studio: a brick wall, two lamps, the drawing and its outline on the wall, a camera.
local function buildStudio(e, player)
    local l = player:K2_GetActorLocation()
    local ox, oy, oz = l.X, l.Y, l.Z - 6000
    e.at = { x = ox, y = oy, z = oz }
    local world = player:GetWorld()
    local function spawn(class, x, y, z)
        local a = world:SpawnActor(StaticFindObject(class), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        e.actors[#e.actors + 1] = a
        return a
    end
    local cube, brick = asset(CUBE), asset(BRICK)
    if not cube or not brick then error("wall parts missing") end
    for iy = -4, 4 do
        for iz = -3, 3 do
            local a = spawn("/Script/Engine.StaticMeshActor", ox + 10, oy + iy * TILE, oz + iz * TILE)
            a:SetMobility(2)
            a.StaticMeshComponent:SetStaticMesh(cube)
            a:SetActorScale3D({ X = 0.2, Y = TILE / 100, Z = TILE / 100 })
            a.StaticMeshComponent:SetMaterial(0, brick)
            pcall(function() a.StaticMeshComponent:SetCastShadow(false) end)
        end
    end
    for _, side in ipairs({ -1, 1 }) do
        local c = spawn("/Script/Engine.PointLight", ox - 260, oy + side * 190 + CAM_SIDE, oz + 110).LightComponent
        c:SetMobility(2)
        c:SetIntensity(9000)
        c:SetAttenuationRadius(1100)
        c:SetLightColor({ R = 1, G = 0.95, B = 0.88, A = 1 }, true)
        c:SetCastShadows(false)
    end
    local function decal(mid, half, order)
        local a = spawn("/Script/Engine.DecalActor", ox - 2, oy, oz)
        local d = a.Decal
        d.DecalSize = { X = 30, Y = half, Z = half }
        d:K2_SetWorldRotation({ Pitch = 0, Yaw = 0, Roll = 90 }, false, {}, true)
        d:SetDecalMaterial(mid)
        pcall(function() d:SetSortOrder(order) end)
        pcall(function() d:MarkRenderStateDirty() end)
        return a
    end
    -- the outline: only here, to show where the tag is; half see-through
    local outline = slotFor("outline")
    if outline and not outline.drawn then
        outline.drawn = true
        white = white or asset(WHITE)
        pcall(function()
            withCanvas(player, outline.rt, function(cv)
                local c, t, n = { R = 1, G = 1, B = 1, A = 0.5 }, 3, SIZE
                local inset = math.floor((1 - HALF / (HALF + 3)) * n / 2)
                local a, b = inset - t, n - inset
                for _, r in ipairs({ { a, a, b - a + t, t }, { a, b, b - a + t, t }, { a, a, t, b - a + t }, { b, a, t, b - a + t } }) do
                    cv:K2_DrawTexture(white, { X = r[1], Y = r[2] }, { X = r[3], Y = r[4] }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, c, 0, 0, { X = 0.5, Y = 0.5 })
                end
            end)
        end)
    end
    if outline then decal(outline.mid, HALF + 3, 1) end
    decal(e.slot.mid, HALF, 2)
    local cam = spawn("/Script/Engine.CameraActor", ox - CAM_BACK, oy + CAM_SIDE, oz)
    pcall(function()
        cam.CameraComponent:SetConstraintAspectRatio(false)
        cam.CameraComponent:SetFieldOfView(CAM_FOV)
    end)
    e.camera = cam
    -- the can, heard while a stroke is drawn
    pcall(function()
        local sound = asset(SPRAY_SOUND)
        if not sound then return end
        local a = spawn("/Script/Engine.AmbientSound", ox - CAM_BACK, oy + CAM_SIDE, oz)
        a.AudioComponent:Stop()
        a.AudioComponent:SetSound(sound)
        e.sound = a
    end)
end

local function hiss(e, on)
    if e.hissing == on or not e.sound then return end
    e.hissing = on
    pcall(function()
        if not valid(e.sound) then return end
        if on then e.sound.AudioComponent:Play(0) else e.sound.AudioComponent:Stop() end
    end)
end

function Tags.openEditor()
    if ed or Screen.current or not Core.enabled("Tags") then return false end
    local w, player = world()
    if not w then return false end
    load()
    local slot = canPaint() and slotFor("edit") or nil
    if not slot then return false end
    local e = { owner = player:GetAddress(), actors = {}, slot = slot, strokes = decode(my.d) or {}, paint = my.c, width = my.w, eraser = false,
        swatches = {}, wasDown = false }
    local ok, err = xpcall(function() buildStudio(e, player) end, debug.traceback)
    if not ok then
        log("Tags: the editor could not be set up: %s", tostring(err))
        destroyAll(e.actors)
        return false
    end
    local s = Screen.open()
    if not s then
        destroyAll(e.actors)
        return false
    end
    e.s = s
    ed = e
    s.onClose = function() if ed == e then closeEditor(false) end end
    pcall(function()
        local pc = player:GetController()
        pc:SetViewTargetWithBlend(e.camera, 0.2, 0, 0, false)
        pc:SetIgnoreMoveInput(true)
        pc:SetIgnoreLookInput(true)
        e.interaction = player.disableWorldInteraction
        player.disableWorldInteraction = true
        e.hud = player.HUD.Visibility
        player.HUD:SetVisibility(1)
    end)
    repaint(e)

    -- the panel (everything in it hangs on the panel's middle line). The game's units
    -- are not the same number across at every window size: sizes go by k.
    local uw, uh = s.units()
    local k = math.min(uw / 1920, uh / 1080)
    e.k = k
    s.area(s.box({ R = 0, G = 0, B = 0, A = 0.8 }), PANEL.x0, 0.05, PANEL.x1, 0.95)
    local function put(widget, x, y) return s.place(widget, PANEL.cx, 0.5, x, y) end
    local top = -0.5 * uh
    put(s.text("YOUR TAG", "name", 40 * k), 0, top + 0.115 * uh)
    put(s.text("PAINT", "small", 20 * k, Screen.GREY), 0, top + 0.19 * uh)
    e.frame = s.sized(s.box(Screen.WHITE), 74 * k, 74 * k)
    e.frameSlot = put(e.frame, 0, 0)
    for i, p in ipairs(PAINTS) do
        local col, row = (i - 1) % 6, (i - 1) // 6
        local x, y = (col - 2.5) * 80 * k, top + 0.255 * uh + row * 80 * k
        put(s.sized(s.box({ R = p[2], G = p[3], B = p[4], A = 1 }), 64 * k, 64 * k), x, y)
        e.swatches[i] = { x = PANEL.cx * uw + x, y = 0.5 * uh + y, r = 38 * k }
    end
    put(s.text("THICKNESS", "small", 20 * k, Screen.GREY), 0, top + 0.43 * uh)
    local trackW, trackY = 400 * k, top + 0.48 * uh
    put(s.sized(s.box({ R = 0.45, G = 0.45, B = 0.45, A = 1 }), trackW, 6 * k), 0, trackY)
    e.track = { x0 = PANEL.cx * uw - trackW / 2, x1 = PANEL.cx * uw + trackW / 2, y = 0.5 * uh + trackY, reach = 34 * k }
    e.knobSlot = put(s.sized(s.box(Screen.WHITE), 18 * k, 44 * k), 0, trackY)
    e.dabBox, e.dabRound = sample(s, player)
    e.dab = s.sized(e.dabBox, 20, 20)
    put(e.dab, 0, top + 0.575 * uh)
    e.left = s.text("", "small", 18 * k, Screen.GREY)
    put(e.left, 0, top + 0.655 * uh)
    local gap = math.max(128, 150 * k)
    e.eraserButton = s.button("ERASER", nil, function()
        e.eraser = not e.eraser
        refreshTools(e)
    end)
    put(e.eraserButton.widget, -gap, top + 0.715 * uh)
    put(s.button("UNDO", nil, function()
        if #e.strokes > 0 then
            table.remove(e.strokes)
            repaint(e)
            refreshTools(e)
        end
    end).widget, 0, top + 0.715 * uh)
    put(s.button("CLEAR", nil, function()
        e.strokes = {}
        repaint(e)
        refreshTools(e)
    end).widget, gap, top + 0.715 * uh)
    put(s.bigButton("SAVE", 1.5, function() closeEditor(true) end).box, 0, top + 0.805 * uh)
    put(s.button("CANCEL", nil, function() closeEditor(false) end).widget, 0, top + 0.89 * uh)
    refreshTools(e)
    return true
end

-- Adds a point to the stroke being drawn and paints the new piece.
local function strokeTo(e, cx, cy)
    local s = e.cur
    local n = #s.p
    cx, cy = math.max(0, math.min(SIZE - 1, math.floor(cx + 0.5))), math.max(0, math.min(SIZE - 1, math.floor(cy + 0.5)))
    local x0, y0 = s.p[n - 1], s.p[n]
    if n > 0 and (cx - x0) ^ 2 + (cy - y0) ^ 2 < 9 then return end
    if countPoints(e.strokes) + n // 2 >= MAX_POINTS then return end
    s.p[n + 1], s.p[n + 2] = cx, cy
    local player = World.player()
    pcall(function()
        withCanvas(player, e.slot.rt, function(cv)
            if n == 0 then segment(cv, s, nil, nil, cx, cy) else segment(cv, s, x0, y0, cx, cy) end
        end)
    end)
end

-- The editor's own mouse handling: drawing in the square, the paints, the slider. `at`
-- (tests) is { x, y, down } in the picture's pixels instead of the real mouse.
local function editorTick(at)
    local e = ed
    if not e then return end
    local player = World.player()
    if not player or player:GetAddress() ~= e.owner or not valid(e.s.widget) then
        ed = nil
        return
    end
    local now = os.clock()
    if not e.rect or now - (e.rectAt or 0) > 0.5 then
        e.rectAt = now
        local before = e.rect and (e.rect.x1 - e.rect.x0) or 0
        findSquare(e)
        if e.rect and math.abs(e.rect.x1 - e.rect.x0 - before) > 1 then refreshTools(e) end
    end
    local x, y, ux, uy, down, w, h = pointer(e)
    if at and w then
        local uw, uh = e.s.units()
        if at.ux then at.x, at.y = at.ux / uw * w, at.uy / uh * h end
        x, y, down = at.x, at.y, at.down
        ux, uy = x / w * uw, y / h * uh
    end
    if not x or not e.rect then return end
    local r = e.rect
    local cx, cy = (x - r.x0) / (r.x1 - r.x0) * SIZE, (y - r.y0) / (r.y1 - r.y0) * SIZE
    local inside = cx >= 0 and cx < SIZE and cy >= 0 and cy < SIZE
    if down and not e.wasDown then
        e.drag = nil
        if inside then
            if #e.strokes < MAX_STROKES then
                e.cur = { c = e.eraser and 0 or e.paint, w = e.width, p = {} }
                strokeTo(e, cx, cy)
                hiss(e, not e.eraser)
            end
        elseif math.abs(uy - e.track.y) < e.track.reach and ux > e.track.x0 - e.track.reach and ux < e.track.x1 + e.track.reach then
            e.drag = "width"
        else
            for i, sw in ipairs(e.swatches) do
                if math.abs(ux - sw.x) <= sw.r and math.abs(uy - sw.y) <= sw.r then
                    e.paint, e.eraser = i, false
                    refreshTools(e)
                    break
                end
            end
        end
    end
    if down and e.cur then strokeTo(e, cx, cy) end
    if down and e.drag == "width" then
        local f = math.max(0, math.min(1, (ux - e.track.x0) / (e.track.x1 - e.track.x0)))
        local width = math.floor(MIN_W + f * (MAX_W - MIN_W) + 0.5)
        if width ~= e.width then
            e.width = width
            refreshTools(e)
        end
    end
    if not down then
        if e.cur then
            if #e.cur.p >= 2 then e.strokes[#e.strokes + 1] = e.cur end
            e.cur = nil
            hiss(e, false)
            refreshTools(e)
        end
        e.drag = nil
    end
    e.wasDown = down
end
Tags.editorTick = editorTick
Tags.editor = function() return ed end

Core.onTick(function()
    if not live() or not ed or ed.scripted then return end
    local ok, err = xpcall(editorTick, debug.traceback)
    if not ok then log("Tags: editor: %s", tostring(err)) end
end)

---------------------------------------------------------------- the way in

-- The game's symbol choice gets a button of ours while it is open.
local choice = nil      -- { widget, button, address, owner }

local function drawOwn()
    local c = choice
    choice = nil
    if not c then return end
    local player = World.player()
    if not player or player:GetAddress() ~= c.owner then return end
    local fromShady = false
    pcall(function() fromShady = c.widget.fromShady == true end)
    -- the game's own way out of the choice (it also lets the game run again)
    pcall(function() c.widget[CHOICE_CLOSE](c.widget) end)
    if fromShady then pcall(function() player:quitComputer() end) end
    Core.after(0.25, function()
        if not Tags.openEditor() then log("Tags: the editor did not open") end
    end)
end
Tags.drawOwn = drawOwn

-- Gives the shorter of the two buttons more padding, so that both want the same width,
-- and lets each have the width it wants. True once done (the sizes are only known after
-- the first layout).
local function sameWidth(c)
    local e = c and c.equal
    if not e then return true end
    local done = false
    pcall(function()
        local a, b = e.use:GetDesiredSize().X, e.mine:GetDesiredSize().X
        if a <= 0 or b <= 0 then return end
        if a > b + 1 then
            local side = 40 + (a - b) / 2
            e.inner:SetPadding({ Left = side, Top = 8, Right = side, Bottom = 8 })
        end
        for _, slot in ipairs(e.slots) do slot:SetSize({ SizeRule = 0, Value = 1 }) end
        done = true
    end)
    if done then c.equal = nil end
    return done
end

-- DRAW YOUR OWN next to the game's USE SELECTED SYMBOL: a button of the same make (style,
-- colour, font, padding), both in one row where the game's button was, equally wide.
-- Returns the new button and what sameWidth() needs.
local function buttonBeside(w)
    local tree = w.WidgetTree
    local use = w.btnUseSelected
    local column = use:GetParent()
    if not valid(column) or column:GetClass():GetFName():ToString() ~= "VerticalBox" then
        error("the choice is not laid out as expected")
    end
    local function new(kind) return StaticConstructObject(StaticFindObject("/Script/UMG." .. kind), tree) end
    local mine = new("Button")
    mine:SetStyle(use.WidgetStyle)
    mine:SetBackgroundColor(use.BackgroundColor)
    local text = new("TextBlock")
    local label = nil
    pcall(function() label = use:GetChildAt(0) end)
    if valid(label) then text:SetFont(label.Font) end
    text:SetColorAndOpacity({ SpecifiedColor = Screen.WHITE, ColorUseRule = 0 })
    text:SetText(FText("DRAW YOUR OWN"))
    local inner = mine:AddChild(text)
    inner:SetPadding({ Left = 40, Top = 8, Right = 40, Bottom = 8 })
    inner:SetHorizontalAlignment(2)
    inner:SetVerticalAlignment(2)
    local row = new("HorizontalBox")
    local slots = {}
    -- from here on the game's button is out of its place; it is put back if anything fails
    local ok, err = pcall(function()
        column:RemoveChild(use)
        for i, button in ipairs({ use, mine }) do
            local s = row:AddChildToHorizontalBox(button)
            s:SetPadding({ Left = i == 1 and 0 or 12, Top = 0, Right = i == 1 and 12 or 0, Bottom = 0 })
            s:SetSize({ SizeRule = 1, Value = 1 })
            s:SetHorizontalAlignment(0)
            slots[i] = s
        end
        local slot = column:AddChildToVerticalBox(row)
        slot:SetPadding({ Left = 30, Top = 0, Right = 30, Bottom = 30 })
        slot:SetHorizontalAlignment(2)
    end)
    if not ok then
        pcall(function()
            local parent = use:GetParent()
            if not valid(parent) or parent:GetAddress() ~= row:GetAddress() or not valid(row:GetParent()) then
                if valid(parent) then parent:RemoveChild(use) end
                local slot = column:AddChildToVerticalBox(use)
                slot:SetPadding({ Left = 30, Top = 0, Right = 30, Bottom = 30 })
                slot:SetHorizontalAlignment(2)
            end
        end)
        error(err)
    end
    pcall(function() row:ForceLayoutPrepass() end)
    return mine, { use = use, mine = mine, inner = inner, slots = slots }
end

-- The way it was before v0.14.2, for a choice that is laid out differently: a button below
-- the panel.
local function buttonBelow(w, player)
    local root = w.WidgetTree.RootWidget
    local class = asset(TAB)
    if not valid(root) or not class then return nil end
    local b = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(player, class, player:GetController())
    b.txtBtnName:SetText(FText("DRAW YOUR OWN"))
    b.btnShow:SetRenderOpacity(1)
    pcall(function() b.txtBtnName:SetColorAndOpacity({ SpecifiedColor = Screen.WHITE, ColorUseRule = 0 }) end)
    b:SetRenderScale({ X = 1.8, Y = 1.8 })
    local slot = root:AddChildToCanvas(b)
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 1 }, Maximum = { X = 0.5, Y = 1 } })
    slot:SetAlignment({ X = 0.5, Y = 0.5 })
    slot:SetAutoSize(true)
    slot:SetPosition({ X = 0, Y = -70 })
    slot:SetZOrder(50)
    return b
end

Core.Hooks.add(CHOICE .. ":Construct", function(ctx)
    if not live() or not Core.enabled("Tags") then return end
    local ok, err = pcall(function()
        local w = ctx:get()
        local player = World.player()
        if not valid(w) or not player then return end
        local button, pressed, equal = nil, nil, nil
        local okb, eb = pcall(function() button, equal = buttonBeside(w) end)
        if okb and valid(button) then
            pressed = button
        else
            log("Tags: the symbol choice's buttons could not be put side by side: %s", tostring(eb))
            button = buttonBelow(w, player)
            if not button then return end
            pressed = button.btnShow
        end
        choice = { widget = w, button = button, pressed = pressed, beside = okb, equal = equal, tries = 0,
            address = button:GetAddress(), owner = player:GetAddress(), at = os.clock() }
        sameWidth(choice)
    end)
    if not ok then log("Tags: the symbol choice did not get its button: %s", tostring(err)) end
end)
Tags.choice = function() return choice end

-- A symbol of the game's was picked: that is the tag from now on.
Core.Hooks.add(CHOICE_USE, function()
    if not live() then return end
    choice = nil
    load()
    if my.use then
        my.use = false
        saveMine()
    end
end)
Core.Hooks.add(CHOICE .. ":" .. CHOICE_CLOSE, function()
    if live() then choice = nil end
end)
Core.Hooks.add("/Game/GUI/shadyComm/saleAreaManagementWidget.saleAreaManagementWidget_C:Destruct", function()
    if live() then choice = nil end
end)

Core.Hooks.add(TAB_CLICK, function(ctx)
    if not live() or not choice then return end
    local w = ctx:get()
    if valid(w) and w:GetAddress() == choice.address then drawOwn() end
end)

Core.onTick(function()
    if not live() or not choice then return end
    local player = World.player()
    if not player or player:GetAddress() ~= choice.owner then
        choice = nil
        return
    end
    if choice.equal then
        choice.tries = choice.tries + 1
        if not sameWidth(choice) and choice.tries > 60 then choice.equal = nil end
    end
    local down = false
    pcall(function() down = choice.pressed:IsPressed() == true end)
    if down then drawOwn() end
end)

World.listen("stop", function()
    if not live() then return end
    choice = nil
    if ed then closeEditor(false) end
end)

function Tags.shutdown()
    choice = nil
    if ed then closeEditor(false) end
end

-- Tests.
Tags.my = function() load() return my end
Tags.kept = function() load() return kept end
Tags.session = function() return session end
Tags.myTag = myTag
Tags.wallKey = wallKey
Tags.ownerOf = function(marking) return owners()[keyOf(marking)] or worldOwner() end
Tags.lookOf = function(marking) return W and W.look[marking:GetAddress()] or nil end
Tags.me = me
Tags.setMine = function(text, use)
    load()
    my.d, my.use = text, use
    saveMine()
end

return Tags
