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
--
-- Since v0.19: a player keeps up to three tags and uses one of them at a time (a key
-- goes to the next one while the spray marker is out); a wall keeps the tag it was sprayed
-- with. A tag is square or twice as wide as high (two squares side by side: it takes two
-- sprays of the can and twice the time). A wall can be sprayed with one, two or three
-- times the paint (another key) and then lasts that many times as long. Besides the
-- twelve paints a stroke can have any colour, given as RRGGBB.

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

local SIZE = 512                 -- a square drawing is SIZE x SIZE, a wide one twice as wide
local MAX_POINTS = 3000          -- in one tag, for each of its squares
local MAX_STROKES = 300
local MIN_W, MAX_W = 4, 80       -- stroke width, in the drawing's pixels
local CHUNK = 2400               -- characters of a drawing per message
local MAX_CHUNKS = 14            -- messages one drawing may come in
local SLOTS = 3                  -- tags a player keeps
local OWN = 6                    -- colours of their own kept in the editor
local MAX_PAINT = 3              -- times the paint (and the time a wall lasts)
local SPRAY_ITEM = "ITEM-SPRAYPAINT"

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
local ACTION = "/Game/TerritorySpraying/sprayActionWidget.sprayActionWidget_C"

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

-- "2s|paint.width.points;paint.width.points" (square) or "2w|..." (wide). A paint is one
-- of the twelve by its number (0: the eraser) or "x" and RRGGBB; a point is four
-- characters (twelve bits across, twelve down). "1|..." is how a drawing was written
-- before v0.19: square, the twelve paints, three characters a point (nine bits each).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64I = {}
for i = 1, #B64 do B64I[B64:byte(i)] = i - 1 end

-- A colour as it is written (0-255) to what the canvas paints with.
local function linear(v)
    v = v / 255
    return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
end

-- A paint of the player's own from "RRGGBB" (or "#RRGGBB"); nil for anything else.
local function ownPaint(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("^#", ""):upper()
    if not hex:match("^%x%x%x%x%x%x$") then return nil end
    return { linear(tonumber(hex:sub(1, 2), 16)), linear(tonumber(hex:sub(3, 4), 16)), linear(tonumber(hex:sub(5, 6), 16)), hex = hex }
end
Tags.ownPaint = ownPaint

local function isWide(text) return type(text) == "string" and text:sub(1, 3) == "2w|" end
Tags.isWide = isWide

local function encode(strokes, wide)
    local out = {}
    for _, s in ipairs(strokes) do
        local p = {}
        for i = 1, #s.p, 2 do
            local v = (s.p[i] << 12) | s.p[i + 1]
            local a, b, c, d = (v >> 18) + 1, ((v >> 12) & 63) + 1, ((v >> 6) & 63) + 1, (v & 63) + 1
            p[#p + 1] = B64:sub(a, a) .. B64:sub(b, b) .. B64:sub(c, c) .. B64:sub(d, d)
        end
        local paint = type(s.c) == "table" and ("x" .. s.c.hex) or string.format("%d", s.c)
        out[#out + 1] = string.format("%s.%d.%s", paint, s.w, table.concat(p))
    end
    return (wide and "2w|" or "2s|") .. table.concat(out, ";")
end

-- The strokes of a drawing and whether it is a wide one, or nil when the text is not a
-- drawing. Whatever comes from another game is cut down to the limits here.
local function decode(text)
    if type(text) ~= "string" then return nil end
    local head = text:match("^(%d%a?)|")
    local per, wide = 4, false
    if head == "1" then per = 3
    elseif head == "2w" then wide = true
    elseif head ~= "2s" then return nil end
    local maxX, limit = (wide and 2 or 1) * SIZE - 1, MAX_POINTS * (wide and 2 or 1)
    local strokes, points = {}, 0
    for part in text:sub(#head + 2):gmatch("[^;]+") do
        local c, w, p = part:match("^(x?%x+)%.(%d+)%.([%w%-_]*)$")
        w = tonumber(w)
        if c and c:sub(1, 1) == "x" then
            c = per == 4 and ownPaint(c:sub(2)) or nil
        elseif c then
            c = c:match("^%d+$") and math.tointeger(tonumber(c)) or nil
        end
        if not c or not w or (type(c) == "number" and c > #PAINTS) or #strokes >= MAX_STROKES then return strokes, wide end
        local s = { c = c, w = math.max(MIN_W, math.min(MAX_W, w)), p = {} }
        for i = 1, #p - per + 1, per do
            if points >= limit then break end
            local v = 0
            for j = 0, per - 1 do v = (v << 6) | B64I[p:byte(i + j)] end
            local x, y
            if per == 3 then x, y = (v >> 9) & 511, v & 511 else x, y = (v >> 12) & 4095, v & 4095 end
            s.p[#s.p + 1] = math.min(maxX, x)
            s.p[#s.p + 1] = math.min(SIZE - 1, y)
            points = points + 1
        end
        if #s.p >= 2 then strokes[#strokes + 1] = s end
    end
    return strokes, wide
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
-- Since v0.19 files of their own: the build before (one tag, no wide ones) keeps its files
-- and still reads them; the old ones are only read here, once, when there are no new ones.
local function myPath() return string.format("%s/ddsmp_tags%s.json", savedDir("/SaveGames"), suffix()) end
local function wallsPath() return string.format("%s/ddsmp_tagwalls%s.json", savedDir(), suffix()) end
local function oldMyPath() return string.format("%s/ddsmp_tag%s.json", savedDir("/SaveGames"), suffix()) end
local function oldWallsPath() return string.format("%s/ddsmp_walls%s.json", savedDir(), suffix()) end

-- The data, or nil and whether the file is there (but not readable).
local function readJson(path)
    local f = io.open(path, "rb")
    if not f then
        -- (a write cut off after the old file was removed: the new one is still under .tmp)
        f = io.open(path .. ".tmp", "rb")
        if not f then return nil, false end
    end
    local text = f:read("a")
    f:close()
    local ok, data = pcall(json.decode, text)
    if ok and type(data) == "table" then return data end
    return nil, true
end

-- Written beside the old file first, then put in its place.
local function writeJson(path, data)
    local ok, text = pcall(json.encode, data)
    if not ok then return false end
    local f = io.open(path .. ".tmp", "wb")
    if not f then
        log("Tags: cannot write %s", path)
        return false
    end
    f:write(text)
    f:close()
    os.remove(path)
    os.rename(path .. ".tmp", path)
    return true
end

-- This player's tags: the drawings (g; "" where there is none), which of them is the one
-- in use (a) and whether one is in use at all (otherwise the game's symbol is); the tools
-- last used in the editor (width, paint: c one of the twelve, cx a colour of the player's
-- own) and the colours of their own they made (own, the newest first).
local my = { use = false, a = 1, g = { "", "", "" }, w = 22, c = 3, own = {} }
-- The world's walls (this game's own worlds): who sprayed which wall, when it was not the
-- world's owner; with which of the sprayer's tags and whether as a wide one (how: "2w" is
-- tag 2, wide; "0" the game's symbol); and the other players' tags as last heard.
local kept = { owners = {}, how = {}, tags = {}, seen = {} }
local loaded = false
local keptDirty = false

local function emptyBook() return { s = 0, a = 0, g = { "", "", "" } } end

-- Another player's tags as kept or as they arrive: nil when it is nothing of the kind.
-- (Before v0.19 a player had one tag: { d = drawing } or { s = symbol }.)
local function cleanBook(v)
    if type(v) ~= "table" then return nil end
    local b = emptyBook()
    if type(v.g) == "table" then
        for n = 1, SLOTS do
            if type(v.g[n]) == "string" and decode(v.g[n]) then b.g[n] = v.g[n] end
        end
        b.a = math.max(0, math.min(SLOTS, math.tointeger(tonumber(v.a) or 0) or 0))
    elseif type(v.d) == "string" and decode(v.d) then
        b.g[1], b.a = v.d, 1
    elseif not tonumber(v.s) then
        return nil
    end
    b.s = math.max(0, math.min(12, math.floor(tonumber(v.s) or 0)))
    return b
end

-- A file that is there but cannot be read is put aside, never written over; without one of
-- its own the file of the build before is read (and left as it is).
local function readKept(path, old)
    local data, there = readJson(path)
    if data then return data end
    if there then
        os.remove(path .. ".bad")
        os.rename(path, path .. ".bad")
        log("Tags: %s could not be read; it is kept as .bad", path)
        return nil
    end
    return (readJson(old))
end

local function load()
    if loaded then return end
    loaded = true
    local data = readKept(myPath(), oldMyPath())
    if data then
        local g = type(data.g) == "table" and data.g or { data.d }      -- (one tag, "d", before v0.19)
        for n = 1, SLOTS do
            if type(g[n]) == "string" and decode(g[n]) then my.g[n] = g[n] end
        end
        local a = math.tointeger(tonumber(data.a) or 1) or 1
        if a >= 1 and a <= SLOTS then my.a = a end
        my.use = data.use == true and my.g[my.a] ~= ""
        if tonumber(data.w) then my.w = math.max(MIN_W, math.min(MAX_W, math.floor(tonumber(data.w)))) end
        if PAINTS[tonumber(data.c) or 0] then my.c = math.tointeger(tonumber(data.c)) or my.c end
        local cx = ownPaint(data.cx)
        my.cx = cx and cx.hex or nil
        if type(data.own) == "table" then
            for _, hex in ipairs(data.own) do
                local p = ownPaint(hex)
                if p and #my.own < OWN then my.own[#my.own + 1] = p.hex end
            end
        end
    end
    data = readKept(wallsPath(), oldWallsPath())
    if data then
        if type(data.owners) == "table" then
            for k, v in pairs(data.owners) do if type(k) == "string" and type(v) == "string" then kept.owners[k] = v end end
        end
        if type(data.how) == "table" then
            for k, v in pairs(data.how) do
                if type(k) == "string" and type(v) == "string" and v:match("^[0-3]w?$") then kept.how[k] = v end
            end
        end
        if type(data.tags) == "table" then
            for k, v in pairs(data.tags) do
                if type(k) == "string" then kept.tags[k] = cleanBook(v) end
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
local session = { owners = {}, how = {}, tags = {} }
local function ownWorld() return not (World.active and World.role == "guest") end
local function owners() return ownWorld() and kept.owners or session.owners end
local function hows() return ownWorld() and kept.how or session.how end
local function tagsOfOthers() return ownWorld() and kept.tags or session.tags end

local version = {}          -- player -> number, raised when their tag changes
local function bump(pid) version[pid] = (version[pid] or 0) + 1 end

local function chosenSymbol()
    local n = 0
    pcall(function() n = tonumber(Core.find("questManager_C").chosenSpraySymbol) or 0 end)
    return n
end

-- A player's tags: { s = the game's symbol they chose, a = which tag they use (0: the
-- symbol), g = the drawings }.
local function myBook()
    load()
    return { s = chosenSymbol(), a = (my.use and my.g[my.a] ~= "") and my.a or 0, g = my.g }
end

local function bookOf(pid)
    if pid == me() then return myBook() end
    return tagsOfOthers()[pid]
end

-- A player's tag: number n of theirs (0: the symbol; when they have no such tag any more,
-- or n is nil, the one they use now). { d = drawing, n = its number } or { s = symbol }.
local function tagFor(pid, n)
    local b = bookOf(pid)
    if not b then return nil end
    if n ~= 0 then
        for _, k in ipairs({ n or b.a, b.a }) do
            if k >= 1 and b.g[k] and b.g[k] ~= "" then return { d = b.g[k], n = k } end
        end
    end
    return { s = b.s or 0 }
end

local function myTag() return tagFor(me()) end
local function tagOf(pid) return tagFor(pid) end
Tags.tagOf, Tags.tagFor = tagOf, tagFor

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
local function slotFor(key, wide)
    local w, player = world()
    if not w then return nil end
    wide = wide == true
    local s = w.slots[key]
    if s and s.wide == wide then return s end
    if s then
        -- the same thing in the other shape: a texture of its own (what still shows the old
        -- one keeps it alive until it is dressed again)
        w.slots[key] = nil
        for i = #w.jobs, 1, -1 do if w.jobs[i].slot == s then table.remove(w.jobs, i) end end
        pcall(function() if valid(s.holder) then s.holder:K2_DestroyActor() end end)
    end
    local ok, made = pcall(function()
        local base = asset(PAINT_MAT)
        if not base then error("material missing") end
        local l = player:K2_GetActorLocation()
        local holder = player:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.DecalActor"),
            { X = l.X, Y = l.Y, Z = l.Z - 9000 }, { Pitch = 0, Yaw = 0, Roll = 0 })
        holder:SetActorHiddenInGame(true)
        local rt = rendering():CreateRenderTarget2D(player, wide and SIZE * 2 or SIZE, SIZE, 2)
        local d = holder.Decal
        d:SetDecalMaterial(base)
        local mid = d:CreateDynamicMaterialInstance()
        mid:SetTextureParameterValue(FName("Diffuse"), rt)
        rendering():ClearRenderTarget2D(player, rt, CLEAR)
        return { rt = rt, mid = mid, holder = holder, text = nil, wide = wide }
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
    -- (a paint of its own, { r, g, b }: coop/wallquest.lua's wall paint)
    if type(c) == "table" then return { R = c[1], G = c[2], B = c[3], A = 1 } end
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
        if #strokes > 0 then withCanvas(player, slot.rt, function(cv) paintSome(cv, strokes, 1, 1, math.huge) end) end
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

-- The texture and material of a player's tag number n (painted when it is another drawing
-- than the one there).
local function slotOfTag(pid, tag)
    local slot = canPaint() and slotFor(pid .. ":" .. tag.n, isWide(tag.d)) or nil
    if slot and slot.text ~= tag.d then
        slot.text = tag.d
        startRender(slot, decode(tag.d) or {})
    end
    return slot
end

-- How a wall was sprayed: which of the sprayer's tags (nil: not known, a wall of before
-- v0.19) and whether as a wide one.
local function howOf(key)
    local h = hows()[key]
    if not h then return nil, false end
    return tonumber(h:sub(1, 1)), h:sub(2, 2) == "w"
end

-- The size of a wall's tag. The marking's picture lies turned on its side: its own Z runs
-- along the wall, its Y up the wall. A wide tag on a wall sprayed wide is twice as wide; on
-- a wall sprayed square (its tag was redrawn wide since) it keeps the width and is half as
-- high; a square tag is the square it always was. (The spray marker hands its own size on
-- to the marking; that is taken off again: it would stretch the picture the wrong way.)
local function shape(marking, wallWide, tagWide)
    local y, z = 1, 1
    if tagWide then
        if wallWide then z = 2 else y = 0.5 end
    end
    pcall(function()
        local a = marking:GetActorScale3D()
        if math.abs(a.X - 1) + math.abs(a.Y - 1) + math.abs(a.Z - 1) > 0.01 then marking:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end
        local d = marking.Decal
        local r = d.RelativeScale3D
        if math.abs(r.Y - y) > 0.01 or math.abs(r.Z - z) > 0.01 then d:SetRelativeScale3D({ X = r.X, Y = y, Z = z }) end
    end)
end

-- Gives a wall the tag it was sprayed with.
local function dress(marking, address, early)
    local w = world()
    if not w then return end
    address = address or marking:GetAddress()
    local key = keyOf(marking)
    local pid = owners()[key] or worldOwner()
    local n, wallWide = howOf(key)
    local tag = tagFor(pid, n)
    w.look[address] = tag and (tag.d and ("drawing " .. tag.n .. " of " .. pid .. " (" .. #tag.d .. ")") or ("symbol " .. tostring(tag.s) .. " of " .. pid)) or ("nothing known of " .. pid)
    if tag then
        if tag.d then
            local slot = slotOfTag(pid, tag)
            if slot then marking.Decal:SetDecalMaterial(slot.mid) end
        else
            local m = symbolMaterial(tonumber(tag.s) or 0)
            if m then marking.Decal:SetDecalMaterial(m) end
        end
        Tags.stats.dressed = Tags.stats.dressed + 1
    end
    shape(marking, wallWide, tag ~= nil and isWide(tag.d))
    if early == nil then early = (w.dressed[address] or ""):sub(-1) == "e" end
    w.dressed[address] = pid .. "#" .. (version[pid] or 0) .. (early and "e" or "")
    if ownWorld() and (owners()[key] or hows()[key]) then kept.seen[key] = os.time() end
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

local lastSig = nil
local sent = { g = {} }     -- what the other games have of this player's tags: the head and each drawing
local sendMine      -- defined below
local firstSeen = {}    -- marking address -> when it was first looked at

-- Looks at every wall once a second: a wall whose sprayer's tag has changed (or that has
-- none yet) is dressed. Also notices when this player's tag is another one.
Core.every(1, function()
    if not live() or not Core.enabled("Tags") then return end
    local w = world()
    if not w or not Core.find("questManager_C") then return end
    load()
    local b = myBook()
    local l = lastSig
    if not l or l.a ~= b.a or l.s ~= b.s or l[1] ~= b.g[1] or l[2] ~= b.g[2] or l[3] ~= b.g[3] then
        lastSig = { a = b.a, s = b.s, b.g[1], b.g[2], b.g[3] }
        bump(me())
    end
    if World.shared() then sendMine(b) end
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

-- "tagme" is a player's tags, in pieces. The head: { p = player, s = symbol, a = the tag in
-- use }. A drawing: { p, g = its number, n = an id, i = piece, k = pieces, d = text }, or
-- { p, g, e = 1 } when there is none.
local function sendHead(pid, b, target)
    Net.send("tagme", { p = pid, s = tonumber(b.s) or 0, a = tonumber(b.a) or 0 }, target)
    Tags.stats.sent = Tags.stats.sent + 1
end

local function sendDrawing(pid, n, text, target)
    if not text or text == "" then
        Net.send("tagme", { p = pid, g = n, e = 1 }, target)
    else
        local k = math.max(1, math.ceil(#text / CHUNK))
        local id = os.time() % 100000 * 10 + math.random(0, 9)
        for i = 1, k do
            Net.send("tagme", { p = pid, g = n, n = id, i = i, k = k, d = text:sub((i - 1) * CHUNK + 1, i * CHUNK) }, target)
        end
    end
    Tags.stats.sent = Tags.stats.sent + 1
end

-- All of a player's tags to one game (drawings they do not have are not sent: a game
-- that knows nothing of a player takes them for none).
local function sendBook(pid, b, target)
    if not b then return end
    for n = 1, SLOTS do
        if b.g[n] and b.g[n] ~= "" then sendDrawing(pid, n, b.g[n], target) end
    end
    sendHead(pid, b, target)
end

-- What has changed of this player's tags since it was last sent, to everybody.
sendMine = function(b)
    b = b or myBook()
    local targets = nil
    for n = 1, SLOTS do
        if sent.g[n] ~= b.g[n] then
            -- (an empty one is said too: the host may still keep one this player has deleted)
            targets = targets or World.targets()
            for _, id in ipairs(targets) do sendDrawing(me(), n, b.g[n], id) end
            sent.g[n] = b.g[n]
        end
    end
    local head = b.a .. "|" .. b.s
    if sent.head ~= head then
        sent.head = head
        for _, id in ipairs(targets or World.targets()) do sendHead(me(), b, id) end
    end
end

local parts = {}        -- sender|player|tag|id -> { k, got, list }
Net.on("tagme", function(sender, data)
    if not live() or not Core.enabled("Tags") or not World.isPeer(sender) then return end
    local host = World.role == "guest" and sender == (World.host or Net.S.owner)
    local pid = host and type(data.p) == "string" and data.p or tostring(sender)
    if pid == me() then return end
    local books = tagsOfOthers()
    local n = math.tointeger(tonumber(data.g) or 0) or 0
    local text = nil
    if n >= 1 and n <= SLOTS then
        if type(data.d) == "string" then
            local k, i = tonumber(data.k) or 1, tonumber(data.i) or 1
            if k < 1 or k > MAX_CHUNKS or i < 1 or i > k or #data.d > CHUNK then return end
            local id = tostring(sender) .. "|" .. pid .. "|" .. n .. "|" .. tostring(data.n)
            local e = parts[id] or { k = k, got = 0, list = {} }
            parts[id] = e
            if not e.list[i] then
                e.list[i] = data.d
                e.got = e.got + 1
            end
            if e.got < e.k then return end
            parts[id] = nil
            local strokes, wide = decode(table.concat(e.list))
            if not strokes then return end
            text = encode(strokes, wide)
        else
            text = ""
        end
        local b = books[pid] or emptyBook()
        if b.g[n] ~= text then
            b.g[n] = text
            books[pid] = b
            bump(pid)
            if ownWorld() then keptDirty = true end
        end
    elseif data.g == nil then
        local s = math.max(0, math.min(12, math.floor(tonumber(data.s) or 0)))
        local a = math.max(0, math.min(SLOTS, math.floor(tonumber(data.a) or 0)))
        local b = books[pid] or emptyBook()
        if b.s ~= s or b.a ~= a or not books[pid] then
            b.s, b.a = s, a
            books[pid] = b
            bump(pid)
            if ownWorld() then keptDirty = true end
        end
    else
        return
    end
    Tags.stats.received = Tags.stats.received + 1
    -- the host tells the other guests
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= sender then
                if text then sendDrawing(pid, n, text, id) else sendHead(pid, books[pid], id) end
            end
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
    owners()[key] = pid ~= worldOwner() and pid or nil
    local n = math.tointeger(tonumber(data.g) or -1) or -1
    hows()[key] = (n >= 0 and n <= SLOTS) and (n .. (data.w == 1 and "w" or "")) or nil
    if ownWorld() then
        kept.seen[key] = os.time()
        keptDirty = true
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
                Net.send("tagwall", { p = pid, x = data.x, y = data.y, z = data.z, a = data.a, b = data.b, c = data.c, l = data.l, g = data.g, w = data.w }, id)
            end
        end
    end
end)

-- Which walls are whose (o) and how they were sprayed (h): the host to a guest.
Net.on("tagwalls", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) then return end
    if type(data.o) == "table" then
        for k, v in pairs(data.o) do
            if type(k) == "string" and type(v) == "string" then session.owners[k] = v end
        end
    end
    if type(data.h) == "table" then
        for k, v in pairs(data.h) do
            if type(k) == "string" and type(v) == "string" and v:match("^[0-3]w?$") then session.how[k] = v end
        end
    end
    if W then W.dressed = {} end
end)

---------------------------------------------------------------- the can

-- What the player sprays with while the game's spray marker is out: the tag in use (a
-- wide one makes the marker twice as wide: the game's own four checks of the wall then
-- stand at the wide tag's corners) and how many times the paint. A wide tag is two squares
-- and takes a spray of the can for each; twice the paint is twice that again and makes
-- the wall last twice as long.
local spray = { want = 1, sections = 1, wide = false, uses = 0, at = 0, on = false }

-- Sprays left in all the cans the player carries.
local function sprayUses(player)
    local n = 0
    pcall(function()
        local out = {}
        player.InventoryComponent:CountItemsOfType(FName(SPRAY_ITEM), true, out)
        n = math.tointeger(tonumber(out.OutItems) or 0) or 0
    end)
    return n
end

-- Times the paint the next spray gets: what was asked for as far as the cans go; 0 when
-- there is not enough for the tag at all.
local function paintLevel(uses, sections)
    return math.max(0, math.min(spray.want, MAX_PAINT, uses // sections))
end

-- The player's spray marker, when it is out.
local function marker(player)
    local g = nil
    pcall(function() g = player.sprayGizmo end)
    return valid(g) and g or nil
end

-- The tags the player has drawn, by number.
local function savedTags()
    load()
    local list = {}
    for n = 1, SLOTS do if my.g[n] ~= "" then list[#list + 1] = n end end
    return list
end

-- Two lines under the game's own "HOLD F spray symbol": the key for the next tag and the
-- key for more coats of paint, each written as the game writes its line. They are a part
-- of the game's prompt (so they show and hide with it) and are made anew for every marker.
-- (Nothing here keeps a widget of a marker that is gone: the engine frees those.)
local row = nil

local function buildRow(player, g)
    local gizmo = g:GetAddress()
    if row and row.gizmo == gizmo then return row end
    row = nil
    local w = g.Widget:GetUserWidgetObject()
    if not valid(w) then return nil end
    local tree, root = w.WidgetTree, w.WidgetTree.RootWidget
    local theirs = root:GetChildAt(0):GetChildAt(1)       -- the game's line: its key and its words
    local keyFont, wordFont = theirs:GetChildAt(0).Font, w.txtAction.Font
    local keyColour = { R = 0.37, G = 0, B = 0, A = 1 }
    pcall(function()
        local c = theirs:GetChildAt(0).ColorAndOpacity.SpecifiedColor
        keyColour = { R = c.R, G = c.G, B = c.B, A = c.A }
    end)
    local function new(kind) return StaticConstructObject(StaticFindObject("/Script/UMG." .. kind), tree) end
    local column = new("VerticalBox")
    local r = { gizmo = gizmo, lines = {}, shown = {} }
    for i = 1, 2 do
        local key, words = new("TextBlock"), new("TextBlock")
        key:SetFont(keyFont)
        key:SetColorAndOpacity({ SpecifiedColor = keyColour, ColorUseRule = 0 })
        words:SetFont(wordFont)
        words:SetColorAndOpacity({ SpecifiedColor = Screen.WHITE, ColorUseRule = 0 })
        local line = new("HorizontalBox")
        line:AddChildToHorizontalBox(key):SetPadding({ Left = 10, Top = 5, Right = 5, Bottom = 5 })
        line:AddChildToHorizontalBox(words):SetPadding({ Left = 5, Top = 5, Right = 10, Bottom = 5 })
        local box = new("Border")
        box:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.85 })
        box:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        box:AddChild(line)
        box:SetVisibility(1)
        local s = column:AddChildToVerticalBox(box)
        pcall(function()
            s:SetHorizontalAlignment(2)
            s:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 0 })
        end)
        r.lines[i] = { box = box, key = key, words = words }
    end
    column:SetVisibility(3)
    local slot = root:AddChildToCanvas(column)
    slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    slot:SetAlignment({ X = 0.5, Y = 0 })
    slot:SetAutoSize(true)
    -- right below the game's line (which stands with its middle on the marker)
    local half = 15
    pcall(function()
        local h = root:GetChildAt(0):GetDesiredSize().Y
        if h > 10 and h < 80 then half = h / 2 end
    end)
    slot:SetPosition({ X = 0, Y = half })
    r.column = column
    row = r
    return r
end

-- (a config.lua from before v0.19 has no such keys)
local DEFAULT_KEYS = { TagNextKey = "R", TagPaintKey = "C" }
local function keyName(name) return tostring(Core.config[name] or DEFAULT_KEYS[name] or ""):upper() end

local function fillRow(r)
    local saved = savedTags()
    local texts = {}
    if #saved >= 2 or (#saved == 1 and not my.use) then
        local label = "use own tag"
        if my.use then
            local at = 1
            for i, n in ipairs(saved) do if n == my.a then at = i end end
            label = string.format("next tag (%d of %d)", at, #saved)
        end
        texts[#texts + 1] = { keyName("TagNextKey"), label }
    end
    local level = paintLevel(spray.uses, spray.sections)
    if level == 0 then
        texts[#texts + 1] = { "", string.format("this tag needs %d sprays", spray.sections) }
    else
        local cost = level * spray.sections
        texts[#texts + 1] = { keyName("TagPaintKey"), string.format("lasts %dx (%d spray%s)", level, cost, cost == 1 and "" or "s") }
    end
    for i, line in ipairs(r.lines) do
        local t = texts[i]
        local sig = t and (t[1] .. "|" .. t[2]) or ""
        if r.shown[i] ~= sig then
            r.shown[i] = sig
            if t then
                line.key:SetText(FText(t[1]))
                line.words:SetText(FText(t[2]))
                line.key:SetVisibility(t[1] ~= "" and 3 or 1)
                -- (a line without a key starts as far in as one with a key)
                pcall(function() line.words.Slot:SetPadding({ Left = t[1] == "" and 10 or 5, Top = 5, Right = 10, Bottom = 5 }) end)
            end
            line.box:SetVisibility(t and 3 or 1)
        end
    end
end

Core.onTick(function()
    if not live() then return end
    local player = World.player()
    local g = player and Core.enabled("Tags") and marker(player) or nil
    if not g then
        spray.on, spray.sections, row = false, 1, nil
        return
    end
    if row and row.gizmo ~= g:GetAddress() then row = nil end
    local now = os.clock()
    if not spray.on or now - spray.at > 0.25 then
        spray.at = now
        spray.uses = sprayUses(player)
        local tag = myTag()
        spray.wide = tag ~= nil and isWide(tag.d)
    end
    spray.on = true
    local ok, e = pcall(function()
        local sections = 1
        -- (the wall of coop/wallquest.lua is painted over, not tagged: as the game has it, one
        -- spray, no tag, no coats)
        local claimed = Tags.claim and Tags.claim(g:K2_GetActorLocation()) or false
        if spray.wide and not claimed then sections = 2 end
        spray.sections = sections
        local a = g:GetActorScale3D()
        if math.abs(a.Y - sections) > 0.01 then g:SetActorScale3D({ X = 1, Y = sections, Z = 1 }) end
        if canPaint() then
            local r = buildRow(player, g)
            -- (while F is held the game's progress bar stands where the lines are; the keys do
            -- nothing then anyway)
            local hide = claimed or g.actionHeld == true
            if r and r.hidden ~= hide then
                r.hidden = hide
                pcall(function() r.column:SetVisibility(hide and 1 or 3) end)
            end
            if r and not hide then fillRow(r) end
        end
    end)
    if not ok and not spray.failed then
        spray.failed = true
        log("Tags: the spray marker: %s", tostring(e))
    end
end)

-- For coop/traits.lua: a wide tag takes twice as long.
function Tags.holdFactor() return spray.on and spray.sections or 1 end

-- The player's own keys, while the marker is out and nothing else has the keys.
local function sprayPlayer()
    if not live() or not Core.enabled("Tags") then return nil end
    local player = World.player()
    local g = player and marker(player) or nil
    if not g then return nil end
    local free = false
    pcall(function()
        free = player.hasSprayPaint == true and g.actionHeld ~= true and player.phoneUp ~= true and player.inventoryOpen ~= true
            and player.mapOpen ~= true and player.computerOpen ~= true
    end)
    if not free or Screen.current then return nil end
    return player
end

-- The next of the player's tags is the one in use.
function Tags.nextTag()
    if not sprayPlayer() then return false end
    local saved = savedTags()
    if #saved == 0 then return false end
    if not my.use then
        if my.g[my.a] == "" then my.a = saved[1] end
        my.use = true
    else
        local at = 1
        for i, n in ipairs(saved) do if n == my.a then at = i end end
        if #saved < 2 then return false end
        my.a = saved[at % #saved + 1]
    end
    saveMine()
    spray.at = 0
    return true
end

-- One more time the paint, as far as the cans go; after the most, once again.
function Tags.morePaint()
    local player = sprayPlayer()
    if not player then return false end
    spray.uses = sprayUses(player)
    local most = math.min(MAX_PAINT, spray.uses // math.max(1, spray.sections))
    local level = math.min(spray.want, most)
    spray.want = level + 1 > most and 1 or level + 1
    return true
end

if Core.bindKey then
    for name, fn in pairs({ TagNextKey = function() if live() then Tags.nextTag() end end, TagPaintKey = function() if live() then Tags.morePaint() end end }) do
        local key = keyName(name)
        if key ~= "" and key ~= "NONE" then Core.bindKey(key, fn) end
    end
end

-- The key was pressed with less paint in the cans than the tag takes: nothing is sprayed.
Core.Hooks.add(GIZMO .. ":ActionPress", function(ctx)
    if not live() or not Core.enabled("Tags") or not spray.on or spray.sections < 2 then return end
    pcall(function()
        local g = ctx:get()
        local player = World.player()
        if not valid(g) or not player or g.actionHeld ~= true then return end
        spray.uses = sprayUses(player)
        if spray.uses >= spray.sections then return end
        g:ActionRelease()
        local Hud = package.loaded["coop.hud"]
        if type(Hud) == "table" and Hud.toast then Hud.toast(string.format("A tag this wide takes %d sprays", spray.sections)) end
    end)
end)

-- This player has just sprayed a wall (the game's own function has put it up and taken
-- one spray out of the can).
Core.Hooks.add(GIZMO .. ":PutSpraySymbol", function(ctx)
    if not live() or not Core.enabled("Tags") then return end
    pcall(function()
        local g = ctx:get()
        if not valid(g) then return end
        local l, r = g:K2_GetActorLocation(), g:K2_GetActorRotation()
        -- (a spray that is not a wall marking: coop/wallquest.lua answers for it)
        if Tags.claim and Tags.claim(l) then return end
        local m = markingAt(l.X, l.Y, l.Z, 4)
        if not m then return end
        Tags.stats.sprayed = Tags.stats.sprayed + 1
        local tag = myTag()
        -- (as the marker was: that is what the wall was checked for)
        local wide = spray.on and spray.sections == 2
        -- the rest of the paint: a wide tag's second square, and everything again for
        -- each time more
        local player = World.player()
        local sections = wide and 2 or 1
        local level = 1
        if player then
            level = math.max(1, paintLevel(sprayUses(player) + 1, sections))
            pcall(function()
                for _ = 2, level * sections do
                    player.InventoryComponent:UseInventoryItem(1, { A = 0, B = 0, C = 0, D = 0 }, FName(SPRAY_ITEM), {}, {})
                end
                if level * sections > 1 then player:refreshBackpackData() end
            end)
            if level > 1 then pcall(function() m.Lifetime = m.Lifetime * level end) end
        end
        Tags.stats.paint = level
        local key = wallKey(l.X, l.Y, l.Z)
        owners()[key] = me() ~= worldOwner() and me() or nil
        hows()[key] = (tag.n or 0) .. (wide and "w" or "")
        if ownWorld() then
            kept.seen[key] = os.time()
            keptDirty = true
        end
        dress(m)
        if World.shared() then
            local life = 0
            pcall(function() life = m.Lifetime end)
            for _, id in ipairs(World.targets()) do
                Net.send("tagwall", { p = me(), x = l.X, y = l.Y, z = l.Z, a = r.Pitch, b = r.Yaw, c = r.Roll, l = life, g = tag.n or 0, w = wide and 1 or 0 }, id)
            end
        end
    end)
end)

-- A guest has arrived: everybody's tags, and for the walls there are which are not the
-- host's and with which tag each was sprayed.
World.listen("peer", function(id)
    if not live() or not Core.enabled("Tags") then return end
    load()
    sendBook(me(), myBook(), id)
    local told = { [me()] = true, [tostring(id)] = true }
    local function tell(pid)
        if pid and not told[pid] and kept.tags[pid] then
            told[pid] = true
            sendBook(pid, kept.tags[pid], id)
        end
    end
    local o, h, n = {}, {}, 0
    local function flush()
        if n > 0 then Net.send("tagwalls", { o = o, h = h }, id) end
        o, h, n = {}, {}, 0
    end
    local present = {}
    for _, m in ipairs(Core.actors(MARK) or {}) do pcall(function() present[keyOf(m)] = true end) end
    for key in pairs(present) do
        local pid, how = kept.owners[key], kept.how[key]
        if pid or how then
            o[key], h[key] = pid, how
            n = n + 1
            tell(pid)
            if n >= 40 then flush() end
        end
    end
    flush()
    for other in pairs(World.inWorld) do tell(tostring(other)) end
end)

World.listen("start", function(role)
    if not live() then return end
    session = { owners = {}, how = {}, tags = {} }
    parts = {}
    sent = { g = {} }       -- the next look sends this player's tags to the others
    if W then W.dressed = {} end
end)

World.listen("stop", function()
    if not live() then return end
    session = { owners = {}, how = {}, tags = {} }
    parts = {}
    sent = { g = {} }
    if W then W.dressed = {} end
end)

-- The walls file is written a few seconds after something in it changed. Walls not seen
-- for a long time are dropped when the list gets long.
Core.every(5, function()
    if not live() or not keptDirty or not loaded then return end
    keptDirty = false
    local keys, n = {}, 0
    for _, list in ipairs({ kept.owners, kept.how }) do
        for key in pairs(list) do
            if not keys[key] then
                keys[key] = true
                n = n + 1
            end
        end
    end
    if n > 1500 then
        local now = os.time()
        for key in pairs(keys) do
            if now - (kept.seen[key] or 0) > 30 * 86400 then kept.owners[key], kept.how[key], kept.seen[key] = nil, nil, nil end
        end
    end
    -- the tags of players who have no wall here any more and are not here are not kept (they
    -- send them again when they come)
    local needed = {}
    for _, pid in pairs(kept.owners) do needed[pid] = true end
    for id in pairs(World.inWorld or {}) do needed[tostring(id)] = true end
    for pid in pairs(kept.tags) do
        if not needed[pid] then kept.tags[pid] = nil end
    end
    writeJson(wallsPath(), kept)
end)

---------------------------------------------------------------- the editor

local ed = nil
local TILE, HALF = 160, 50           -- brick tile and half the height of the drawing on the wall
local CAM_FOV = 60
-- The camera: in front of a square drawing, and further back for one twice as wide (that
-- one then fits left of the panel as well).
local CAMS = { [false] = { back = 205, side = 34 }, [true] = { back = 289, side = 53 } }
local PANEL = { x0 = 0.685, x1 = 0.975, cx = 0.83 }
local GRID = 464                     -- what everything in the panel lines up with (k units)
-- (the colours of the switches of coop/look.lua)
local SWITCH_ON = { R = 0.36, G = 0.78, B = 0.45, A = 1 }
local SWITCH_OFF = { R = 0.03, G = 0.03, B = 0.03, A = 1 }
local SWITCH_TEXT_ON = { R = 0, G = 0, B = 0, A = 1 }
local SWITCH_EDGE = { R = 0.25, G = 0.25, B = 0.25, A = 1 }
-- a place for a colour of the player's own while there is none: an empty frame
local UNUSED, UNUSED_EDGE = { R = 0.003, G = 0.003, B = 0.003, A = 1 }, { R = 0.045, G = 0.045, B = 0.045, A = 1 }
local FIELD = { R = 0.1, G = 0.1, B = 0.1, A = 1 }
local STRIP_W, STRIP_H, STRIP_CELL = 96, 12, 4               -- the strip of colours: its cells, their pixels

local function pixelsAcross(wide) return wide and 2 * SIZE or SIZE end
local function pointLimit(wide) return MAX_POINTS * (wide and 2 or 1) end

-- A linear colour (what the canvas paints with) as it is written (0-255).
local function written(v)
    v = math.max(0, math.min(1, v))
    v = v <= 0.0031308 and v * 12.92 or 1.055 * v ^ (1 / 2.4) - 0.055
    return math.floor(v * 255 + 0.5)
end

-- A paint written out, RRGGBB.
local function hexOf(paint)
    if type(paint) == "table" then return paint.hex end
    local p = PAINTS[paint] or PAINTS[1]
    return string.format("%02X%02X%02X", written(p[2]), written(p[3]), written(p[4]))
end
Tags.hexOf = hexOf

-- A typed colour: six digits, or three (each one doubled); nil for anything else.
local function typedHex(text)
    local h = tostring(text or ""):gsub("[^%x]", ""):upper()
    if #h == 3 then h = h:sub(1, 1):rep(2) .. h:sub(2, 2):rep(2) .. h:sub(3, 3):rep(2) end
    return #h == 6 and h or nil
end
Tags.typedHex = typedHex

-- The strip of colours to pick from: every hue across, light at the top, dark at the
-- bottom (fx, fy from 0 to 1). RRGGBB.
local function stripColour(fx, fy)
    local h = math.max(0, math.min(0.9999, fx)) * 6
    local l = 0.88 - math.max(0, math.min(1, fy)) * 0.76
    local c = 1 - math.abs(2 * l - 1)
    local x = c * (1 - math.abs(h % 2 - 1))
    local r, g, b
    if h < 1 then r, g, b = c, x, 0
    elseif h < 2 then r, g, b = x, c, 0
    elseif h < 3 then r, g, b = 0, c, x
    elseif h < 4 then r, g, b = 0, x, c
    elseif h < 5 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    local m = l - c / 2
    local function byte(v) return math.floor(math.max(0, math.min(1, v + m)) * 255 + 0.5) end
    return string.format("%02X%02X%02X", byte(r), byte(g), byte(b))
end
Tags.stripColour = stripColour

local function destroyAll(list)
    for _, a in ipairs(list or {}) do pcall(function() if valid(a) then a:K2_DestroyActor() end end) end
end

local function library() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end

-- The tag shown in the editor: its working copy.
local function cur(e) return e.work[e.n] end

-- A tag as the editor works on it: its strokes, its shape, what UNDO goes back through,
-- and whether it is another than the one kept.
local function workOf(text)
    local strokes, wide = decode(text)
    return { strokes = strokes or {}, wide = wide == true, undo = {}, changed = false }
end

-- Typing a colour. The field has the keyboard (the game gets no keys meanwhile, as with
-- the chat line) until Enter, or a click somewhere else.
local function startTyping(e)
    if e.typing or Core.typing or not valid(e.hex) then return end
    local player = World.player()
    local pc = player and player:GetController()
    if not valid(pc) then return end
    -- (set: what the typing itself has made the tools; a button pressed meanwhile wins)
    e.typing = { at = os.clock(), paint = e.paint, eraser = e.eraser, set = { e.paint, e.eraser } }
    pcall(function()
        e.hex:SetHintText(FText(hexOf(e.paint)))
        e.hex:SetText(FText(""))
        e.hex:SetVisibility(0)
    end)
    local ok = pcall(function()
        library():SetInputMode_UIOnlyEx(pc, e.hex, 2)
        e.hex:SetKeyboardFocus()
    end)
    if not ok then
        e.typing = nil
        return
    end
    Core.typing = true
end

-- keep: what was typed is the paint from now on (when it is a colour)
local function stopTyping(e, keep)
    local t = e.typing
    if not t then return end
    e.typing = nil
    Core.typing = nil
    local text = ""
    pcall(function() text = e.hex:GetText():ToString() end)
    local hex = keep and typedHex(text) or nil
    if e.paint == t.set[1] and e.eraser == t.set[2] then
        if hex then
            e.paint, e.eraser = ownPaint(hex), false
        else
            e.paint, e.eraser = t.paint, t.eraser
        end
    end
    e.hexShown = nil
    pcall(function() e.hex:SetVisibility(3) end)
    -- the mouse back to the screen (as the screen takes it)
    local player = World.player()
    local pc = player and player:GetController()
    local s = e.s
    if valid(pc) and s and valid(s.widget) then
        pcall(function()
            library():SetInputMode_GameAndUIEx(pc, s.widget, 0, false)
            pc.bShowMouseCursor = true
        end)
        s.mouseAt = os.clock() + 0.5
    end
end

local function closeEditor(save)
    local e = ed
    if not e then return end
    ed = nil
    if e.typing then stopTyping(e, true) end
    if save then
        local changed = 0
        for n = 1, SLOTS do
            local wk = e.work[n]
            if wk.changed then
                my.g[n] = #wk.strokes > 0 and encode(wk.strokes, wk.wide) or ""
                changed = changed + 1
            end
        end
        -- the tag shown is the one in use from now on; when it is empty, one drawn now (the
        -- first), else the one in use stays (or, when that one is empty too, the first there
        -- is, or the game's symbol)
        local drawn = nil
        for n = 1, SLOTS do
            if not drawn and e.work[n].changed and my.g[n] ~= "" then drawn = n end
        end
        if my.g[e.n] ~= "" then
            my.a, my.use = e.n, true
        elseif drawn then
            my.a, my.use = drawn, true
        elseif my.g[my.a] == "" then
            my.use = false
            for n = 1, SLOTS do
                if my.g[n] ~= "" then
                    my.a, my.use = n, true
                    break
                end
            end
        end
        local wk = cur(e)
        log("Tags: tags saved (%d changed; tag %d shown, %s, %d stroke(s), %d point(s); tag %d in use: %s)", changed, e.n,
            wk.wide and "wide" or "square", #wk.strokes, countPoints(wk.strokes), my.a, tostring(my.use))
    end
    my.w = e.width
    if type(e.paint) == "table" then my.cx = e.paint.hex else my.c, my.cx = e.paint, nil end
    my.own = e.own
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

local function inRect(r, ux, uy) return r ~= nil and ux ~= nil and ux >= r.x0 and ux <= r.x1 and uy >= r.y0 and uy <= r.y1 end

-- Where the drawing is in the picture (pixels), from the camera.
local function findSquare(e)
    local player = World.player()
    local pc = player and player:GetController()
    if not valid(pc) then return end
    local a, b = {}, {}
    local o = e.at
    local hw = cur(e).wide and 2 * HALF or HALF
    local okA = pc:ProjectWorldLocationToScreen({ X = o.x, Y = o.y - hw, Z = o.z + HALF }, a, false)
    local okB = pc:ProjectWorldLocationToScreen({ X = o.x, Y = o.y + hw, Z = o.z - HALF }, b, false)
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

-- The strip of colours as a picture (painted once).
local function strip(s, player)
    local image = nil
    pcall(function()
        white = white or asset(WHITE)
        local w, h = STRIP_W * STRIP_CELL, STRIP_H * STRIP_CELL
        local rt = rendering():CreateRenderTarget2D(player, w, h, 2)
        rendering():ClearRenderTarget2D(player, rt, CLEAR)
        withCanvas(player, rt, function(cv)
            for x = 0, STRIP_W - 1 do
                for y = 0, STRIP_H - 1 do
                    local c = colour(ownPaint(stripColour((x + 0.5) / STRIP_W, (y + 0.5) / STRIP_H)))
                    cv:K2_DrawTexture(white, { X = x * STRIP_CELL, Y = y * STRIP_CELL }, { X = STRIP_CELL, Y = STRIP_CELL }, { X = 0, Y = 0 }, { X = 1, Y = 1 },
                        c, 0, 0, { X = 0.5, Y = 0.5 })
                end
            end
        end)
        local i = s.new("Image")
        i.Brush.ResourceObject = rt
        i.Brush.ImageSize = { X = w, Y = h }
        i:SetVisibility(3)
        image = i
    end)
    return valid(image) and image or nil
end

-- A row of equal cells, the chosen one green (as the switches of the "who are you"
-- screen). Returns the row and show(chosen, dim): dim[i] greys the words of cell i.
local function switchRow(s, labels, width, height, size, onPick)
    local row = s.new("HorizontalBox")
    local n = #labels
    local cw = math.floor((width - 4 - (n - 1) * 2) / n)
    local cells = {}
    for i, label in ipairs(labels) do
        local words = s.text(label, "button", size, Screen.WHITE)
        local inner = s.new("SizeBox")
        inner:SetWidthOverride(cw)
        inner:SetHeightOverride(height - 4)
        local slot = inner:AddChild(words)
        pcall(function()
            slot:SetHorizontalAlignment(2)
            slot:SetVerticalAlignment(2)
        end)
        local face = s.box(SWITCH_OFF, inner, 0)
        pcall(function()
            face:SetVisibility(4)
            inner:SetVisibility(4)
        end)
        local hit = s.hit(label, function() onPick(i) end)
        local cell = s.new("Overlay")
        cell:AddChildToOverlay(s.sized(hit.widget, cw, height - 4))
        cell:AddChildToOverlay(face)
        row:AddChildToHorizontalBox(cell):SetPadding({ Left = i > 1 and 2 or 0, Top = 0, Right = 0, Bottom = 0 })
        cells[i] = { face = face, words = words }
    end
    local shown = {}
    local function show(on, dim)
        for i, c in ipairs(cells) do
            local state = i == on and "on" or ((dim and dim[i]) and "dim" or "off")
            if shown[i] ~= state then
                shown[i] = state
                pcall(function()
                    c.face:SetBrushColor(state == "on" and SWITCH_ON or SWITCH_OFF)
                    local t = state == "on" and SWITCH_TEXT_ON or (state == "dim" and Screen.GREY or Screen.WHITE)
                    c.words:SetColorAndOpacity({ SpecifiedColor = t, ColorUseRule = 0 })
                end)
            end
        end
    end
    return s.box(SWITCH_EDGE, row, 2), show
end

local function paintColour(e)
    if e.eraser then return { R = 0.2, G = 0.2, B = 0.2, A = 1 } end
    return colour(e.paint)
end

local function refreshTools(e)
    local s = e.s
    local uw, uh = s.units()
    local wk = cur(e)
    -- the frame behind the paint in use: one of the twelve, or one of the player's own
    local at = nil
    if not e.eraser then
        if type(e.paint) == "number" then
            at = e.swatches[e.paint]
        else
            for i, hex in ipairs(e.own) do
                if hex == e.paint.hex then
                    at = e.ownSwatches[i]
                    break
                end
            end
        end
    end
    if at then
        slotPos(e.frameSlot, at.x - PANEL.cx * uw, at.y - 0.5 * uh)
        pcall(function() e.frame:SetVisibility(3) end)
    else
        pcall(function() e.frame:SetVisibility(1) end)
    end
    for i, sw in ipairs(e.ownSwatches) do
        local hex = e.own[i] or ""
        if sw.shown ~= hex then
            sw.shown = hex
            local c = hex ~= "" and colour(ownPaint(hex)) or nil
            pcall(function()
                sw.box:SetBrushColor(c or UNUSED_EDGE)
                sw.fill:SetBrushColor(c or UNUSED)
            end)
        end
    end
    -- the paint written out (not while it is being typed)
    if not e.typing then
        local hex = hexOf(e.paint)
        if e.hexShown ~= hex then
            e.hexShown = hex
            pcall(function() e.hex:SetText(FText(hex)) end)
        end
    end
    pcall(function() e.chip:SetBrushColor(colour(e.paint)) end)
    local f = (e.width - MIN_W) / (MAX_W - MIN_W)
    slotPos(e.knobSlot, e.track.x0 + f * (e.track.x1 - e.track.x0) - PANEL.cx * uw, e.track.y - 0.5 * uh)
    -- the dab: the stroke's width as it is on the wall
    local px = e.rect and (e.rect.x1 - e.rect.x0) or 300
    local _, _, _, _, _, w = pointer(e)
    -- (no larger than the room between the slider's row and the buttons)
    local side = math.min(96 * (e.k or 1), math.max(4, e.width / pixelsAcross(wk.wide) * px * (uw / (w or 1920))))
    pcall(function()
        e.dab:SetWidthOverride(side)
        e.dab:SetHeightOverride(side)
        local c = paintColour(e)
        if e.dabRound then e.dabBox:SetColorAndOpacity(c) else e.dabBox:SetBrushColor(c) end
    end)
    s.tint(e.eraserButton, e.eraser and Screen.GREEN or Screen.WHITE)
    local left = pointLimit(wk.wide) - countPoints(wk.strokes) - (e.stroke and #e.stroke.p // 2 or 0)
    -- how much is left is not shown (nobody gets near the limit); only that it is used up
    pcall(function() e.left:SetText(FText(left <= 0 and "OUT OF PAINT" or "")) end)
    local empty = {}
    for n = 1, SLOTS do empty[n] = #e.work[n].strokes == 0 end
    e.showTabs(e.n, empty)
    e.showShape(wk.wide and 2 or 1)
end

local function repaint(e) renderNow(e.slot, cur(e).strokes) end

-- The frame around the drawing, half see-through (only in the editor, to show where the
-- tag is).
local function drawOutline(player, slot, wide)
    if slot.drawn then return end
    slot.drawn = true
    white = white or asset(WHITE)
    local across = pixelsAcross(wide)
    local hw = wide and 2 * HALF or HALF
    local insetX = math.floor((1 - hw / (hw + 3)) * across / 2)
    local insetY = math.floor((1 - HALF / (HALF + 3)) * SIZE / 2)
    local c, t = { R = 1, G = 1, B = 1, A = 0.5 }, 3
    local x0, x1, y0, y1 = insetX - t, across - insetX, insetY - t, SIZE - insetY
    pcall(function()
        withCanvas(player, slot.rt, function(cv)
            for _, r in ipairs({ { x0, y0, x1 - x0 + t, t }, { x0, y1, x1 - x0 + t, t }, { x0, y0, t, y1 - y0 + t }, { x1, y0, t, y1 - y0 + t } }) do
                cv:K2_DrawTexture(white, { X = r[1], Y = r[2] }, { X = r[3], Y = r[4] }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, c, 0, 0, { X = 0.5, Y = 0.5 })
            end
        end)
    end)
end

-- The drawing on the wall and the camera, for the shape of the tag shown.
local function arrange(e)
    local player = World.player()
    local wide = cur(e).wide
    local slot = slotFor(wide and "edit:w" or "edit", wide)
    local outline = slotFor(wide and "outline:w" or "outline", wide)
    if not slot then error("no texture to draw on") end
    e.slot = slot
    local hw = wide and 2 * HALF or HALF
    pcall(function()
        local d = e.drawDecal.Decal
        d.DecalSize = { X = 30, Y = HALF, Z = hw }
        d:SetDecalMaterial(slot.mid)
        pcall(function() d:MarkRenderStateDirty() end)
    end)
    if outline then
        drawOutline(player, outline, wide)
        pcall(function()
            local d = e.outlineDecal.Decal
            d.DecalSize = { X = 30, Y = HALF + 3, Z = hw + 3 }
            d:SetDecalMaterial(outline.mid)
            pcall(function() d:MarkRenderStateDirty() end)
        end)
    end
    local o, cam = e.at, CAMS[wide]
    pcall(function() e.camera:K2_SetActorLocation({ X = o.x - cam.back, Y = o.y + cam.side, Z = o.z }, false, {}, true) end)
    -- (the view follows the camera a frame later: the drawing's place is found after that)
    e.rect, e.rectAt, e.movedAt = nil, nil, os.clock()
end

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
        local c = spawn("/Script/Engine.PointLight", ox - 260, oy + side * 190 + CAMS[false].side, oz + 110).LightComponent
        c:SetMobility(2)
        c:SetIntensity(9000)
        c:SetAttenuationRadius(1100)
        c:SetLightColor({ R = 1, G = 0.95, B = 0.88, A = 1 }, true)
        c:SetCastShadows(false)
    end
    local function decal(order)
        local a = spawn("/Script/Engine.DecalActor", ox - 2, oy, oz)
        local d = a.Decal
        d:K2_SetWorldRotation({ Pitch = 0, Yaw = 0, Roll = 90 }, false, {}, true)
        pcall(function() d:SetSortOrder(order) end)
        return a
    end
    e.outlineDecal = decal(1)
    e.drawDecal = decal(2)
    local cam = spawn("/Script/Engine.CameraActor", ox - CAMS[false].back, oy + CAMS[false].side, oz)
    pcall(function()
        cam.CameraComponent:SetConstraintAspectRatio(false)
        cam.CameraComponent:SetFieldOfView(CAM_FOV)
    end)
    e.camera = cam
    -- the can, heard while a stroke is drawn
    pcall(function()
        local sound = asset(SPRAY_SOUND)
        if not sound then return end
        local a = spawn("/Script/Engine.AmbientSound", ox - CAMS[false].back, oy + CAMS[false].side, oz)
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

-- Another of the three tags in the editor.
local function showTag(e, n)
    if n == e.n or e.stroke or n < 1 or n > SLOTS then return end
    e.n = n
    arrange(e)
    repaint(e)
    refreshTools(e)
end
Tags.showTag = function(n) if ed then showTag(ed, n) end end

local function toast(text)
    local Hud = package.loaded["coop.hud"]
    if type(Hud) == "table" and Hud.toast then pcall(Hud.toast, text) end
end

-- The tag shown square or twice as wide. A square drawing goes into the middle of the wide
-- one; a wide one becomes square as it is when it lies within the middle square, else half
-- as large. UNDO goes back.
local function reshape(e, wide)
    local wk = cur(e)
    if wk.wide == wide or e.stroke then return end
    local strokes = {}
    if wide then
        for _, s in ipairs(wk.strokes) do
            local p = {}
            for i = 1, #s.p, 2 do p[i], p[i + 1] = s.p[i] + SIZE // 2, s.p[i + 1] end
            strokes[#strokes + 1] = { c = s.c, w = s.w, p = p }
        end
    else
        if countPoints(wk.strokes) > MAX_POINTS then
            toast("Too much is drawn for a square tag")
            return
        end
        -- (by the points: paint over the edge of a square is cut off there as it always was)
        local lo, hi = math.huge, -math.huge
        for _, s in ipairs(wk.strokes) do
            for i = 1, #s.p, 2 do
                lo = math.min(lo, s.p[i])
                hi = math.max(hi, s.p[i])
            end
        end
        local fits = lo >= SIZE // 2 and hi <= SIZE // 2 + SIZE - 1
        for _, s in ipairs(wk.strokes) do
            local p = {}
            for i = 1, #s.p, 2 do
                if fits then
                    p[i], p[i + 1] = s.p[i] - SIZE // 2, s.p[i + 1]
                else
                    p[i], p[i + 1] = math.min(SIZE - 1, math.floor(s.p[i] / 2 + 0.5)), math.floor(s.p[i + 1] / 2 + SIZE / 4 + 0.5)
                end
            end
            strokes[#strokes + 1] = { c = s.c, w = fits and s.w or math.max(MIN_W, math.floor(s.w / 2 + 0.5)), p = p }
        end
    end
    wk.undo[#wk.undo + 1] = { strokes = wk.strokes, wide = wk.wide }
    wk.strokes, wk.wide, wk.changed = strokes, wide, true
    arrange(e)
    repaint(e)
    refreshTools(e)
end
Tags.reshape = function(wide) if ed then reshape(ed, wide) end end

local function undo(e)
    local wk = cur(e)
    local last = table.remove(wk.undo)
    if last and not last.stroke then
        local reshaped = last.wide ~= wk.wide
        wk.strokes, wk.wide = last.strokes, last.wide
        if reshaped then arrange(e) end
    elseif #wk.strokes > 0 then
        -- (a stroke of this session, or one of the tag as it was kept)
        table.remove(wk.strokes)
    else
        return
    end
    wk.changed = true
    repaint(e)
    refreshTools(e)
end

local function clear(e)
    local wk = cur(e)
    if #wk.strokes == 0 then return end
    wk.undo[#wk.undo + 1] = { strokes = wk.strokes, wide = wk.wide }
    wk.strokes, wk.changed = {}, true
    repaint(e)
    refreshTools(e)
end

-- A colour of the player's own that a stroke was drawn with goes first in their list.
local function remember(e, hex)
    for i = #e.own, 1, -1 do
        if e.own[i] == hex then table.remove(e.own, i) end
    end
    table.insert(e.own, 1, hex)
    while #e.own > OWN do table.remove(e.own) end
end

-- n: the tag to show first (the one in use when not given)
function Tags.openEditor(n)
    if ed or Screen.current or Core.typing or not Core.enabled("Tags") or not canPaint() then return false end
    local w, player = world()
    if not w then return false end
    load()
    local e = { owner = player:GetAddress(), actors = {}, work = {}, own = {}, swatches = {}, ownSwatches = {},
        n = math.max(1, math.min(SLOTS, math.tointeger(tonumber(n) or my.a) or 1)),
        paint = (my.cx and ownPaint(my.cx)) or my.c, width = my.w, eraser = false, wasDown = false }
    for i = 1, SLOTS do e.work[i] = workOf(my.g[i]) end
    for _, hex in ipairs(my.own) do e.own[#e.own + 1] = hex end
    local ok, err = xpcall(function()
        buildStudio(e, player)
        arrange(e)
    end, debug.traceback)
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

    -- The panel: one column on the panel's middle line, everything as wide as the grid of
    -- paints, the whole column in the middle of the panel. The game's units are not the
    -- same number across at every window size: sizes go by k.
    local uw, uh = s.units()
    local k = math.min(uw / 1920, uh / 1080)
    e.k = k
    local G2 = GRID * k / 2
    s.area(s.box({ R = 0, G = 0, B = 0, A = 0.8 }), PANEL.x0, 0.05, PANEL.x1, 0.95)
    local function put(widget, x, y, ax, ay) return s.place(widget, PANEL.cx, 0.5, x, y, ax, ay) end
    -- (x, y as put() takes them to units on the screen)
    local function abs(x, y) return PANEL.cx * uw + x, 0.5 * uh + y end
    local y = -868 * k / 2
    local function row(h, gap)
        local c = y + h * k / 2
        y = y + (h + gap) * k
        return c
    end
    local yTitle, yTabs, yShape, yPaint = row(48, 18), row(44, 12), row(40, 22), row(24, 8)
    local yGrid, yStrip, yHex, yThick = row(224, 14), row(44, 12), row(40, 22), row(24, 8)
    local yTrack, yButtons, ySave, yCancel = row(44, 30), row(44, 22), row(66, 14), row(44, 0)

    put(s.text("YOUR TAGS", "name", 40 * k), 0, yTitle)
    local tabs, showTabs = switchRow(s, { "TAG 1", "TAG 2", "TAG 3" }, GRID * k, 44 * k, 18 * k, function(i) showTag(e, i) end)
    put(tabs, 0, yTabs)
    e.showTabs = showTabs
    local shape, showShape = switchRow(s, { "1x1", "2x1" }, GRID * k, 40 * k, 18 * k, function(i) reshape(e, i == 2) end)
    put(shape, 0, yShape)
    e.showShape = showShape

    put(s.text("PAINT", "small", 20 * k, Screen.GREY), -G2, yPaint, 0, 0.5)
    e.frame = s.sized(s.box(Screen.WHITE), 74 * k, 74 * k)
    e.frameSlot = put(e.frame, 0, 0)
    for i, p in ipairs(PAINTS) do
        local col, line = (i - 1) % 6, (i - 1) // 6
        local x, yy = (col - 2.5) * 80 * k, yGrid + (line - 1) * 80 * k
        put(s.sized(s.box({ R = p[2], G = p[3], B = p[4], A = 1 }), 64 * k, 64 * k), x, yy)
        local ax, ay = abs(x, yy)
        e.swatches[i] = { x = ax, y = ay, r = 38 * k }
    end
    for i = 1, OWN do
        local x, yy = (i - 3.5) * 80 * k, yGrid + 80 * k
        local fill = s.box(UNUSED)
        local box = s.box(UNUSED_EDGE, fill, math.max(1, math.floor(2 * k + 0.5)))
        put(s.sized(box, 64 * k, 64 * k), x, yy)
        local ax, ay = abs(x, yy)
        e.ownSwatches[i] = { x = ax, y = ay, r = 38 * k, box = box, fill = fill }
    end
    local picture = strip(s, player)
    if picture then
        put(s.sized(picture, GRID * k, 44 * k), 0, yStrip)
        local x0, y0 = abs(-G2, yStrip - 22 * k)
        local x1, y1 = abs(G2, yStrip + 22 * k)
        e.strip = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    end
    -- the paint written out: a chip of it, "#" and the six digits (typed into)
    local field = s.new("HorizontalBox")
    e.chip = s.box(colour(e.paint))
    local cs = field:AddChildToHorizontalBox(s.sized(e.chip, 26 * k, 26 * k))
    pcall(function()
        cs:SetPadding({ Left = 7 * k, Top = 0, Right = 10 * k, Bottom = 0 })
        cs:SetVerticalAlignment(2)
    end)
    local hs = field:AddChildToHorizontalBox(s.text("#", "button", 20 * k, Screen.GREY))
    pcall(function()
        hs:SetPadding({ Left = 0, Top = 0, Right = 4 * k, Bottom = 0 })
        hs:SetVerticalAlignment(2)
    end)
    local edit = s.new("EditableText")
    pcall(function()
        local style = edit.WidgetStyle
        style.Font = s.text("", "button", 20 * k).Font
        style.Font.Size = math.floor(20 * k + 0.5)
    end)
    pcall(function() edit:SetVisibility(3) end)
    local es = field:AddChildToHorizontalBox(edit)
    pcall(function()
        es:SetSize({ SizeRule = 1, Value = 1 })
        es:SetVerticalAlignment(2)
    end)
    e.hex = edit
    local fieldBox = s.box(FIELD, field, 0)
    put(s.sized(fieldBox, GRID * k, 40 * k), 0, yHex)
    do
        local x0, y0 = abs(-G2, yHex - 20 * k)
        local x1, y1 = abs(G2, yHex + 20 * k)
        e.hexRect = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    end

    put(s.text("THICKNESS", "small", 20 * k, Screen.GREY), -G2, yThick, 0, 0.5)
    local trackW = (GRID - 140) * k
    put(s.sized(s.box({ R = 0.45, G = 0.45, B = 0.45, A = 1 }), trackW, 6 * k), -G2 + trackW / 2, yTrack)
    do
        local x0, ty = abs(-G2, yTrack)
        e.track = { x0 = x0, x1 = x0 + trackW, y = ty, reach = 34 * k }
    end
    e.knobSlot = put(s.sized(s.box(Screen.WHITE), 18 * k, 44 * k), 0, yTrack)
    e.dabBox, e.dabRound = sample(s, player)
    e.dab = s.sized(e.dabBox, 20, 20)
    put(e.dab, G2 - 70 * k, yTrack)
    e.left = s.text("", "small", 18 * k, Screen.GREY)
    put(e.left, 0, yTrack + 37 * k)

    local bar = s.new("HorizontalBox")
    e.eraserButton = s.button("ERASER", nil, function()
        e.eraser = not e.eraser
        refreshTools(e)
    end)
    local undoButton = s.button("UNDO", nil, function() undo(e) end)
    local clearButton = s.button("CLEAR", nil, function() clear(e) end)
    for i, b in ipairs({ e.eraserButton, undoButton, clearButton }) do
        bar:AddChildToHorizontalBox(b.widget):SetPadding({ Left = i > 1 and 36 * k or 0, Top = 0, Right = 0, Bottom = 0 })
    end
    put(bar, 0, yButtons)
    put(s.bigButton("SAVE", 1.5, function() closeEditor(true) end).box, 0, ySave)
    put(s.button("CANCEL", nil, function() closeEditor(false) end).widget, 0, yCancel)
    refreshTools(e)
    return true
end

-- Adds a point to the stroke being drawn and paints the new piece.
local function strokeTo(e, cx, cy)
    local s = e.stroke
    local wk = cur(e)
    local n = #s.p
    cx = math.max(0, math.min(pixelsAcross(wk.wide) - 1, math.floor(cx + 0.5)))
    cy = math.max(0, math.min(SIZE - 1, math.floor(cy + 0.5)))
    local x0, y0 = s.p[n - 1], s.p[n]
    if n > 0 and (cx - x0) ^ 2 + (cy - y0) ^ 2 < 9 then return end
    if countPoints(wk.strokes) + n // 2 >= pointLimit(wk.wide) then return end
    s.p[n + 1], s.p[n + 2] = cx, cy
    local player = World.player()
    pcall(function()
        withCanvas(player, e.slot.rt, function(cv)
            if n == 0 then segment(cv, s, nil, nil, cx, cy) else segment(cv, s, x0, y0, cx, cy) end
        end)
    end)
end

-- While a colour is typed: only what a colour is written with stays in the field, the
-- paint is that colour as soon as it is one, and Enter or a click elsewhere ends it.
-- True when it ended with a press of the mouse (that press then counts as usual).
local function typingTick(e, ux, uy, down)
    local t = e.typing
    local focused = false
    pcall(function() focused = e.hex:HasKeyboardFocus() == true end)
    local fresh = os.clock() - t.at < 0.3
    local text = ""
    pcall(function() text = e.hex:GetText():ToString() end)
    local clean = text:gsub("[^%x]", ""):upper():sub(1, 6)
    if clean ~= text then pcall(function() e.hex:SetText(FText(clean)) end) end
    local hex = typedHex(clean)
    if hex ~= t.shown then
        t.shown = hex
        if e.paint == t.set[1] and e.eraser == t.set[2] then
            if hex then e.paint, e.eraser = ownPaint(hex), false else e.paint, e.eraser = t.paint, t.eraser end
            t.set = { e.paint, e.eraser }
        end
        refreshTools(e)
    end
    local pressed = down and not e.wasDown and not inRect(e.hexRect, ux, uy)
    if pressed or (not focused and not fresh) then
        stopTyping(e, true)
        refreshTools(e)
        return pressed
    end
    if not focused then pcall(function() e.hex:SetKeyboardFocus() end) end
    return false
end

-- The editor's own mouse handling: drawing, the paints, the strip, the colour field, the
-- slider. `at` (tests) is { x, y, down } in the picture's pixels (or ux, uy in units)
-- instead of the real mouse.
local function editorTick(at)
    local e = ed
    if not e then return end
    local player = World.player()
    if not player or player:GetAddress() ~= e.owner or not valid(e.s.widget) then
        ed = nil
        if e.typing then
            e.typing = nil
            Core.typing = nil
        end
        return
    end
    local now = os.clock()
    if now - (e.movedAt or -1) < 0.15 then
        e.wasDown = true      -- (a press meanwhile does not count)
        return
    end
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
    if e.typing and not typingTick(e, ux, uy, down) then
        e.wasDown = down
        return
    end
    if not x or not e.rect then
        e.wasDown = down
        return
    end
    local r = e.rect
    local wk = cur(e)
    local across = pixelsAcross(wk.wide)
    local cx, cy = (x - r.x0) / (r.x1 - r.x0) * across, (y - r.y0) / (r.y1 - r.y0) * SIZE
    local inside = cx >= 0 and cx < across and cy >= 0 and cy < SIZE
    if down and not e.wasDown then
        e.drag = nil
        if inside then
            if #wk.strokes < MAX_STROKES then
                e.stroke = { c = e.eraser and 0 or e.paint, w = e.width, p = {} }
                strokeTo(e, cx, cy)
                hiss(e, not e.eraser)
            end
        elseif math.abs(uy - e.track.y) < e.track.reach and ux > e.track.x0 - e.track.reach and ux < e.track.x1 + e.track.reach then
            e.drag = "width"
        elseif inRect(e.strip, ux, uy) then
            e.drag = "strip"
        elseif inRect(e.hexRect, ux, uy) then
            startTyping(e)
        else
            for i, sw in ipairs(e.swatches) do
                if math.abs(ux - sw.x) <= sw.r and math.abs(uy - sw.y) <= sw.r then
                    e.paint, e.eraser = i, false
                    refreshTools(e)
                    break
                end
            end
            for i, sw in ipairs(e.ownSwatches) do
                if e.own[i] and math.abs(ux - sw.x) <= sw.r and math.abs(uy - sw.y) <= sw.r then
                    e.paint, e.eraser = ownPaint(e.own[i]), false
                    refreshTools(e)
                    break
                end
            end
        end
    end
    if down and e.stroke then strokeTo(e, cx, cy) end
    if down and e.drag == "width" then
        local f = math.max(0, math.min(1, (ux - e.track.x0) / (e.track.x1 - e.track.x0)))
        local width = math.floor(MIN_W + f * (MAX_W - MIN_W) + 0.5)
        if width ~= e.width then
            e.width = width
            refreshTools(e)
        end
    end
    if down and e.drag == "strip" then
        local s = e.strip
        local hex = stripColour((ux - s.x0) / (s.x1 - s.x0), (uy - s.y0) / (s.y1 - s.y0))
        if e.eraser or type(e.paint) ~= "table" or e.paint.hex ~= hex then
            e.paint, e.eraser = ownPaint(hex), false
            refreshTools(e)
        end
    end
    if not down then
        if e.stroke then
            local st = e.stroke
            e.stroke = nil
            if #st.p >= 2 then
                wk.strokes[#wk.strokes + 1] = st
                wk.undo[#wk.undo + 1] = { stroke = true }
                wk.changed = true
                if type(st.c) == "table" then remember(e, st.c.hex) end
            end
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
    -- (a shared world that ends can leave this game's world as it is: the editor stays open;
    -- one that is gone takes the editor with it, nothing of it is touched)
    if ed and World.gone then closeEditor(false) end
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
-- n: which of the three (the one in use when not given); it is the one in use afterwards
Tags.setMine = function(text, use, n)
    load()
    n = math.max(1, math.min(SLOTS, math.tointeger(tonumber(n) or my.a) or 1))
    my.g[n], my.a = text or "", n
    my.use = use == true and my.g[n] ~= ""
    saveMine()
end
Tags.useTag = function(n)
    load()
    if my.g[n] and my.g[n] ~= "" then
        my.a, my.use = n, true
        saveMine()
        return true
    end
    return false
end
Tags.spray = function() return spray end

-- For coop/wallquest.lua, which paints a wall of its own.
-- The material that shows a player's tag (the drawing they use, or the symbol they chose);
-- nil for a player without one, or where nothing can be painted.
function Tags.materialOf(pid)
    pid = pid or me()
    local tag = tagOf(pid)
    if not tag then return nil end
    if tag.d then
        local slot = slotOfTag(pid, tag)
        return slot and slot.mid or nil
    end
    return symbolMaterial(tonumber(tag.s) or 0)
end
-- For coop/shady.lua: a player's tag as a picture for a screen (a texture that can be put
-- on an image): their drawing, or the symbol of the game's they chose, on a dark disc.
-- nil for a player without a tag, or where nothing can be painted.
local SYMBOL_TEX = { "/Game/Textures/Decals/WallSpraySymbols/wallSprayedSymbol-%02d.wallSprayedSymbol-%02d",
    "/Game/Textures/Decals/WallSpraySymbols/wallSpraySymbol-%02d.wallSpraySymbol-%02d" }
local DISC = { w = 500, c = { 0.035, 0.035, 0.045 }, p = { 256, 256 } }
local WIDE_FIT = 0.45       -- a wide tag on the round picture: this much of its size, in the middle
function Tags.pictureOf(pid)
    pid = tostring(pid or me())
    local tag = tagOf(pid)
    if not tag or not canPaint() then return nil end
    local symbol = (not tag.d) and (tonumber(tag.s) or 0) or nil
    if symbol and (symbol < 1 or symbol > 12) then return nil end
    local slot = slotFor("pic:" .. pid)
    if not slot then return nil end
    local key = tag.d or ("s" .. symbol)
    if slot.text ~= key then
        slot.text = key
        if tag.d then
            local strokes = { DISC }
            local drawn, wide = decode(tag.d)
            for _, s in ipairs(drawn or {}) do
                if wide then
                    local p = {}
                    for i = 1, #s.p, 2 do
                        p[i] = (s.p[i] - SIZE) * WIDE_FIT + SIZE / 2
                        p[i + 1] = (s.p[i + 1] - SIZE / 2) * WIDE_FIT + SIZE / 2
                    end
                    s = { c = s.c, w = math.max(2, s.w * WIDE_FIT), p = p }
                end
                strokes[#strokes + 1] = s
            end
            startRender(slot, strokes)
        else
            startRender(slot, {})
            local _, player = world()
            pcall(withCanvas, player, slot.rt, function(cv)
                disc(cv, DISC.p[1], DISC.p[2], DISC.w, colour(DISC.c))
                local tex = asset(string.format(SYMBOL_TEX[1], symbol, symbol)) or asset(string.format(SYMBOL_TEX[2], symbol, symbol))
                if tex then
                    cv:K2_DrawTexture(tex, { X = 86, Y = 86 }, { X = 340, Y = 340 }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, { R = 1, G = 1, B = 1, A = 1 }, 2, 0, { X = 0.5, Y = 0.5 })
                end
            end)
        end
    end
    return slot.rt
end
-- The number that changes when that player's tag does.
function Tags.versionOf(pid) return version[tostring(pid or me())] or 0 end

-- A material that shows the given strokes ({ { w, c, p = { x, y, ... } }, ... }, as in a
-- tag), kept under `name`.
function Tags.paintOf(name, strokes)
    local slot = canPaint() and slotFor("#" .. tostring(name)) or nil
    if not slot then return nil end
    if slot.text ~= name then
        slot.text = name
        startRender(slot, strokes)
    end
    return slot.mid
end

-- A picture painted once by `paint(canvas, white, size, clear)`: `white` is the plain texture
-- to stamp rectangles with, `clear` the colour that, drawn opaque, leaves nothing. (The
-- emote wheel's ring, coop/emote.lua.)
function Tags.canvasPicture(key, paint)
    if not canPaint() then return nil end
    key = "canvas:" .. tostring(key)
    local slot = slotFor(key)
    if not slot then return nil end
    if slot.text ~= key then
        slot.text = key
        startRender(slot, {})
        local _, player = world()
        local ok, e = pcall(withCanvas, player, slot.rt, function(cv) paint(cv, white, SIZE, CLEAR) end)
        if not ok then log("Tags: picture %s: %s", key, tostring(e)) end
    end
    return slot.rt
end

-- A round cut of a square picture that is still being made (an entry of coop/thumbs.lua:
-- { rt, done }): the texture is empty until the picture is there, then holds it with
-- everything outside the circle taken away (strips of "no paint", as the eraser does).
local rounds = {}
function Tags.roundPicture(key, source)
    if not canPaint() or type(source) ~= "table" then return nil end
    key = "round:" .. tostring(key)
    local slot = slotFor(key)
    if not slot then return nil end
    if slot.text ~= key then
        slot.text = key
        startRender(slot, {})
        rounds[#rounds + 1] = { key = key, slot = slot, source = source }
    end
    return slot.rt
end

Core.every(0.1, function()
    if not live() or #rounds == 0 then return end
    local w, player = world()
    for i = #rounds, 1, -1 do
        local r = rounds[i]
        if not w or w.slots[r.key] ~= r.slot then
            table.remove(rounds, i)
        elseif r.source.done then
            table.remove(rounds, i)
            pcall(withCanvas, player, r.slot.rt, function(cv)
                local one = { R = 1, G = 1, B = 1, A = 1 }
                cv:K2_DrawTexture(r.source.rt, { X = 0, Y = 0 }, { X = SIZE, Y = SIZE }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, one, 0, 0, { X = 0.5, Y = 0.5 })
                local radius, n = SIZE / 2 - 4, 128
                local h = SIZE / n
                for j = 0, n - 1 do
                    local dy = -SIZE / 2 + (j + 0.5) * h
                    local half = math.abs(dy) < radius and math.sqrt(radius * radius - dy * dy) or 0
                    local side = SIZE / 2 - half
                    cv:K2_DrawTexture(white, { X = 0, Y = j * h }, { X = side, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, CLEAR, 0, 0, { X = 0.5, Y = 0.5 })
                    cv:K2_DrawTexture(white, { X = SIZE - side, Y = j * h }, { X = side, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, CLEAR, 0, 0, { X = 0.5, Y = 0.5 })
                end
            end)
        end
    end
end)

return Tags
