-- Scratch tickets ("STREET CA$H").
--
-- The places where the game's loot spawners put down bobby pins, water bottles and spray
-- cans now and then hold a scratch ticket instead. Most of them have been scratched
-- already and win nothing; once in a while one is fresh. A fresh ticket is scratched with
-- the mouse on a screen of its own (double-click it in the inventory): three equal amounts
-- in a row (across, down or slanting) win that amount. Amy's gas station, Jay's and Robert Bridge's "local shop" in sector C
-- sell fresh tickets for $20 in their own BUY window (the ticket is one more product of
-- their row in the game's shop table) and cash winning ones: "I've got a winning scratch
-- ticket" opens the game's trade window, the tickets are dragged into it, ACCEPT pays.
--
-- The tickets are items of the game: rows added to its ItemDatabase when the mod starts
-- (names, icons drawn by tools/lotto_art.py, assets/lotto/), so pockets, backpack,
-- containers, dropping and saving treat them like any other item. A pickup of the game
-- remembers only its `data` (name and so on), not which item it is, so a ticket lying in
-- the world is known by the name in its data and made a ticket again wherever it turns
-- up: after a save is loaded, after it was dropped, and in the other player's game.

local Core = require("core")
local World = require("coop.world")
local Repl = require("coop.repl")
local Screen = require("coop.screen")
local Hud = require("coop.hud")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_LOTTO_GEN") or 0) + 1
_G.DDSMP_LOTTO_GEN = GEN
local function live() return rawget(_G, "DDSMP_LOTTO_GEN") == GEN end

local Lotto = { stats = { converted = 0, scratched = 0, won = 0, cashed = 0 } }

---------------------------------------------------------------- numbers

-- Of the bobby pins, water bottles and spray cans the loot spawners put down, this share
-- is a ticket instead; of the tickets, this share is fresh (the rest are used).
Lotto.LOOT_SHARE = 0.12
Lotto.FRESH_SHARE = 0.15
-- What a fresh ticket turns out to be (the user's numbers, from Hobo: Tough Life).
-- The two big prizes (the user's numbers, 2026-11-18: 3% and 1%) come out of the winning
-- tickets' share: six in ten still lose, the three small prizes each gave up a tenth.
Lotto.ODDS = { { p = 0.6000, win = 0 }, { p = 0.1170, win = 10 }, { p = 0.1053, win = 20 }, { p = 0.1377, win = 30 }, { p = 0.0300, win = 100 }, { p = 0.0100, win = 500 } }
Lotto.AMOUNTS = { 10, 20, 30, 100, 500 }                   -- what a ticket can win
Lotto.FACES = { 1, 2, 5, 10, 15, 20, 25, 30 }     -- what the boxes can show
-- The big prizes are rarely won (Lotto.ODDS). Now and then a ticket that did not win one
-- shows it twice side by side (TEASE: how often), or once somewhere (LONE).
Lotto.BIG = { 100, 100, 500 }
Lotto.TEASE, Lotto.LONE = 0.10, 0.08

---------------------------------------------------------------- the items

local DIR = Core.MOD_DIR .. "/assets/lotto/"
local DB = "/Game/DataTables/ItemDatabase.ItemDatabase"
-- What a ticket dropped from the inventory becomes: the game makes the row's actor class
-- and tells it nothing of which item it was (the drop is caught below and the pickup made
-- a ticket at once). The bare pickup class is no item at all of its own: whatever went
-- wrong, a dropped ticket can never turn into something else.
local CARRIER = "/Game/Interactive/pickupItemBase.pickupItemBase_C"
-- Where tickets are found: the loot spawners' small things.
local LOOT = {
    "/Game/Interactive/pickupItems/bobbyPinBoxPickupBP.bobbyPinBoxPickupBP_C",
    "/Game/Drugs/DrugProduction/WeedClasses/waterBottleBP.waterBottleBP_C",
    "/Game/TerritorySpraying/sprayPaintBP.sprayPaintBP_C",
}
local SPAWNER = "/Game/Interactive/Spawners/lootSpawner.lootSpawner_C"
local LOOT_CLASS, CARRIER_CLASS = {}, CARRIER:match("([%w_]+)$")
for _, path in ipairs(LOOT) do LOOT_CLASS[path:match("([%w_]+)$")] = true end

local KINDS = {
    fresh = { id = "ITEM-LOTTO-FRESH", name = "Scratch ticket", icon = "icon_fresh", picture = "ticket_fresh",
        desc = "A STREET CA$H ticket nobody has scratched yet. Double-click it in your inventory to scratch it." },
    used = { id = "ITEM-LOTTO-USED", name = "Used scratch ticket", icon = "icon_used", picture = "ticket_used",
        desc = "Somebody scratched this one already. It won nothing." },
    win10 = { id = "ITEM-LOTTO-WIN-10", name = "Winning ticket ($10)", icon = "icon_win10", picture = "ticket_win10", value = 10 },
    win20 = { id = "ITEM-LOTTO-WIN-20", name = "Winning ticket ($20)", icon = "icon_win20", picture = "ticket_win20", value = 20 },
    win30 = { id = "ITEM-LOTTO-WIN-30", name = "Winning ticket ($30)", icon = "icon_win30", picture = "ticket_win30", value = 30 },
    win100 = { id = "ITEM-LOTTO-WIN-100", name = "Winning ticket ($100)", icon = "icon_win100", picture = "ticket_win100", value = 100 },
    win500 = { id = "ITEM-LOTTO-WIN-500", name = "Winning ticket ($500)", icon = "icon_win500", picture = "ticket_win500", value = 500 },
}
local WHERE = "Cash it at the gas station, at Jay's or at Robert's shop in sector C."
for _, k in pairs(KINDS) do
    if k.value then k.desc = string.format("A STREET CA$H ticket that won $%d. %s", k.value, WHERE) end
end
local BY_ID, BY_NAME = {}, {}
for key, k in pairs(KINDS) do
    k.key = key
    BY_ID[k.id], BY_NAME[k.name] = k, k
end
Lotto.KINDS = KINDS

-- The item row's fields (the game's NewItemStructure) and the pickup data's.
local R = {
    name = "Name_2_FF6B1B3640DC8500F30969AD1A856723", desc = "Description_4_35628C2940A2D525609C95B5117627A9",
    icon = "Icon_7_9183F95946ADBF277F39248EA95CF966", size = "Size_11_DA41073149E4068109A8AB8E696904F9",
    weight = "Weight_13_021ECC0A46EA3F14A02418AA4DB9743B", actor = "ActorClass_16_F5DFA0B44AED17EA1ACCD6BAA11A44E6",
    cat = "Category_20_4D582CF747C56D9FA5FEB3BB8E3352EF", stack = "CanStack_23_F3E61B4F4566F31AF4248FAAF5A8CA86",
    stackMax = "StackMaxSize_26_8F7C50134A1C333C95AC528E9B2D8226", defAmount = "DefaultAmount_28_92DC36D146C4C881302ADB822BE4DA16",
    maxAmount = "MaxAmount_30_A9F0786545866BB36EC0868C59DA7E92", invW = "InventoryWidth_37_5E59630A4044F97CFED95FA62B62189A",
    invH = "InventoryHeight_38_5A2E3AD34332DF72F2131484DBF09FB0",
}
local D = {
    name = "Name_2_DE72969C475DA33FA2F65892697C784C", desc = "Desc_15_C67A089C4E33FD18F2A111BA47FD6ACE",
    size = "Size_6_4944B52D4D792BAD9BB279A37D23B78A", weight = "Wieght_8_4A5B2F4A44DC71DC37992A9C578CEACC",
    actor = "ActorClass_19_92D5E7B44B81759034AE35B07C0EC14A", cat = "Category_23_0F75A19C496A045546393F8BBCFE4526",
    stack = "canStack_25_6E7A78DA43FCB6665D916FA42A34E301", quantity = "quantity_28_03E582D645680161A02BA0940CD2DFCA",
}
local CATEGORY = 15           -- counted in pieces, like bobby pins

local function asset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if valid(o) then return o end
    pcall(function() LoadAsset((path:gsub("_C$", ""))) end)
    o = StaticFindObject(path)
    if valid(o) then return o end
    return nil
end

local textures = {}           -- file name -> Texture2D (made once per game start)

local function texture(name)
    local t = textures[name]
    if valid(t) then return t end
    local ok, made = pcall(function()
        local KRL = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
        return KRL:ImportFileAsTexture2D(World.player() or KRL, DIR .. name .. ".png")
    end)
    if ok and valid(made) then
        textures[name] = made
        return made
    end
    log("Lotto: picture %s could not be loaded: %s", name, tostring(made))
    return nil
end

local rowsAt = nil            -- address of the table the rows were added to

-- Adds the ticket rows to the game's item table (once per table object).
-- (The table is kept per world: looking it up by path costs 8 ms. `fresh`: looked up anew,
-- for the moment a load starts, when the world that is kept is the one being left.)
local function ensureItems(fresh)
    local db = (not fresh and Core.class(DB)) or asset(DB)
    if not db then return false end
    local address = db:GetAddress()
    if rowsAt == address then
        -- (a table loaded anew can sit where the last one was)
        local ok, row = pcall(function() return db:FindRow(KINDS.fresh.id) end)
        if ok and row ~= nil then return true end
    end
    local carrier = asset(CARRIER)
    if not carrier then return false end
    local all = true
    for _, k in pairs(KINDS) do
        local ok, e = pcall(function()
            local row = {
                [R.name] = FText(k.name), [R.desc] = FText(k.desc), [R.size] = 0.1, [R.weight] = 0.005, [R.actor] = carrier,
                [R.cat] = CATEGORY, [R.stack] = true, [R.stackMax] = 100, [R.defAmount] = 0, [R.maxAmount] = 0, [R.invW] = 0, [R.invH] = 0,
            }
            local icon = texture(k.icon)
            if icon then row[R.icon] = icon end
            db:AddRow(k.id, row)
        end)
        if not ok then
            all = false
            log("Lotto: the item %s could not be added: %s", k.id, tostring(e))
        end
    end
    if all then
        rowsAt = address
        log("Lotto: %d ticket items added to the item table (%x)", 5, address)
    end
    return all
end
Lotto.ensureItems = ensureItems

---------------------------------------------------------------- tickets in the world

local CUBE = "/Engine/BasicShapes/Cube.Cube"
local SKIN = "/Game/CitizenNPC/CharacterParts/Materials/Basebody/MI_ma_body_01_deep.MI_ma_body_01_deep"
local BLACK = "/Engine/EngineResources/Black.Black"
local FLAT = "/Engine/EngineMaterials/FlatNormal.FlatNormal"
-- A ticket is 10 x 14.6 cm (the picture's proportions), a card's thickness.
Lotto.MODEL = { x = 0.1, y = 0.146, z = 0.003, lift = 0.4, yaw = 90 }

local materials = { owner = nil }     -- kind key -> material (made per world)

local function materialFor(kind, player)
    local owner = player:GetAddress()
    if materials.owner ~= owner then materials = { owner = owner } end
    local m = materials[kind.key]
    if valid(m) then return m end
    local base, pic = asset(SKIN), texture(kind.picture)
    if not base or not pic then return nil end
    local KML = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    m = KML:CreateDynamicMaterialInstance(player, base, FName("None"))
    if not valid(m) then return nil end
    m:SetTextureParameterValue(FName("Albedo"), pic)
    local black, flat = asset(BLACK), asset(FLAT)
    if black then m:SetTextureParameterValue(FName("Tint Mask"), black) end
    if flat then m:SetTextureParameterValue(FName("Normal"), flat) end
    materials[kind.key] = m
    return m
end

local function dataName(a)
    local ok, s = pcall(function() return a.data[D.name]:ToString() end)
    if ok and type(s) == "string" then return s end
    ok, s = pcall(function()
        local text = tostring(Repl.export(a, { "data" }).data)
        return text:match(D.name .. '="([^"]*)"')
    end)
    return ok and s or nil
end

local function itemID(a)
    local ok, s = pcall(function() return a.ItemID:ToString() end)
    return ok and s or ""
end

local function clean(s) return (tostring(s):gsub('["\\]', "")) end

-- Makes a pickup the ticket `kind`: what it is, what it is called and remembers, and how
-- it looks. `yaw`: the way it lies. `keep`: it keeps the number of tickets it holds (a
-- dropped stack); otherwise it is one ticket.
local function dress(a, kind, yaw, keep)
    local player = World.player()
    if not player then return false end
    a.ItemID = FName(kind.id)
    pcall(function() a.objName = FText(kind.name) end)
    pcall(function() if not keep or (tonumber(a.quantity) or 0) < 1 then a.quantity = 1 end end)
    local carrier = asset(CARRIER)
    Repl.import(a, { data = string.format('(%s="%s",%s="%s",%s=0.100000,%s=0.005000,%s=BlueprintGeneratedClass\'%s\',%s=%d,%s=True,%s=1)',
        D.name, clean(kind.name), D.desc, clean(kind.desc), D.size, D.weight, D.actor, carrier and carrier:GetFullName():match("^%S+%s+(.+)$") or CARRIER,
        D.cat, CATEGORY, D.stack, D.quantity) })
    local model = a.Model
    if valid(model) then
        local cube, mat = asset(CUBE), materialFor(kind, player)
        if cube then
            model:SetStaticMesh(cube)
            if mat then model:SetMaterial(0, mat) end
            local M = Lotto.MODEL
            model:SetRelativeScale3D({ X = M.x, Y = M.y, Z = M.z })
            -- (a model the game simulates, a dropped one, keeps its place and falls flat)
            local simulating = false
            pcall(function() simulating = model:IsSimulatingPhysics(FName("None")) == true end)
            if not simulating then
                model:K2_SetRelativeLocationAndRotation({ X = 0, Y = 0, Z = M.lift }, { Pitch = 0, Yaw = (yaw or 0) + M.yaw, Roll = 0 }, false, {}, true)
            end
        end
    end
    return true
end
Lotto.dress = dress

local function hash(l, text)
    local h = (math.floor(l.X / 10 + 0.5) * 73856093) ~ (math.floor(l.Y / 10 + 0.5) * 19349663) ~ (math.floor(l.Z / 10 + 0.5) * 83492791)
    h = h & 0x7fffffff
    for i = 1, #text do h = (h * 31 + text:byte(i)) & 0x7fffffff end
    for _ = 1, 3 do h = ((h ~ (h >> 13)) * 1103515245 + 12345) & 0x7fffffff end
    return h
end

-- The game's day: what a spawner puts down is decided anew every day.
local function today()
    local d = 0
    pcall(function()
        local clock = Core.find("BP_WorldTimeAndConditions_C")
        d = clock:GetCurrentIntDay() * 100 + clock:GetCurrentIntMonth()
    end)
    return d
end

local spawners = { owner = nil, at = 0, list = {} }

local function nearSpawner(l)
    local player = World.player()
    if not player then return false end
    local owner = player:GetAddress()
    if spawners.owner ~= owner or os.clock() - spawners.at > 60 then
        spawners = { owner = owner, at = os.clock(), list = {} }
        for _, s in ipairs(Core.actors(SPAWNER) or {}) do
            pcall(function()
                local p = s:K2_GetActorLocation()
                spawners.list[#spawners.list + 1] = { X = p.X, Y = p.Y, Z = p.Z }
            end)
        end
    end
    for _, p in ipairs(spawners.list) do
        if (p.X - l.X) ^ 2 + (p.Y - l.Y) ^ 2 + (p.Z - l.Z) ^ 2 < 120 * 120 then return true end
    end
    return false
end

-- What a spawner's thing at `l` becomes (nil: it stays what it is). The same in every
-- player's game: it follows from the place, the kind of thing and the day.
local function rollLoot(l, class)
    local h = hash(l, class .. ":" .. today())
    if (h % 10000) / 10000 >= Lotto.LOOT_SHARE then return nil end
    return ((h // 10000) % 1000) / 1000 < Lotto.FRESH_SHARE and KINDS.fresh or KINDS.used
end
Lotto.rollLoot = rollLoot

local seen = { owner = nil, list = {} }       -- address -> class name (looked at once)

local function scan()
    local player = World.player()
    if not player or World.joining or World.gone then return end
    if not ensureItems() then return end
    local owner = player:GetAddress()
    if seen.owner ~= owner then seen = { owner = owner, list = {} } end
    local now = {}
    local function look(a, cls, loot)
        if not Core.alive(a) then return end
        local address = a:GetAddress()
        local name = dataName(a)
        local kind = name and BY_NAME[name] or nil
        if kind then
            -- a ticket: it must be the item, and look like one
            if itemID(a) ~= kind.id or seen.list[address] ~= "dressed:" .. kind.key then
                local ok, e = pcall(dress, a, kind, 0, true)
                if not ok then log("Lotto: a ticket could not be made: %s", tostring(e)) end
            end
            now[address] = "dressed:" .. kind.key
            return
        end
        if seen.list[address] == cls then
            now[address] = cls
            return
        end
        now[address] = cls
        if not loot then return end
        local dropped = false
        pcall(function() dropped = a.dropedByPlayer == true end)
        if dropped then return end
        local l = a:K2_GetActorLocation()
        if not nearSpawner(l) then return end
        local into = rollLoot(l, cls)
        if not into then return end
        local ok, e = pcall(dress, a, into, hash(l, "yaw") % 360)
        if ok then
            now[address] = "dressed:" .. into.key
            Lotto.stats.converted = Lotto.stats.converted + 1
            log("Lotto: the %s at %.0f %.0f %.0f is a %s today", cls, l.X, l.Y, l.Z, into.name:lower())
        else
            log("Lotto: a find could not be made a ticket: %s", tostring(e))
        end
    end
    -- (every pickup of the game is one of the bare pickup class's kind)
    for _, a in ipairs(Core.actors(CARRIER) or {}) do
        local cls = ""
        pcall(function() cls = a:GetClass():GetFName():ToString() end)
        if LOOT_CLASS[cls] then
            pcall(look, a, cls, true)
        elseif cls == CARRIER_CLASS then
            pcall(look, a, cls, false)
        end
    end
    seen.list = now
end

-- A ticket dropped from the inventory (or a pocket): the game has just made the bare
-- pickup at the player's hands, with nothing in it that says which ticket it was. The
-- drag that was dropped says it.
local DROP = "/Game/Player/Inventory/itemDropWidget.itemDropWidget_C"
Core.Hooks.add(DROP .. ":OnDrop", function(_, _, _, operation)
    if not live() then return end
    local id = nil
    pcall(function() id = operation:get().Payload.ItemID:ToString() end)
    local kind = id and BY_ID[id] or nil
    if not kind then return end
    local player = World.player()
    if not player then return end
    local p = player:K2_GetActorLocation()
    local made = 0
    for _, a in ipairs(Core.actors(CARRIER) or {}) do
        pcall(function()
            if a:GetClass():GetFName():ToString() ~= CARRIER_CLASS or itemID(a) ~= "None" then return end
            if BY_NAME[dataName(a) or ""] then return end
            local l = a:K2_GetActorLocation()
            if (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 + (l.Z - p.Z) ^ 2 > 400 * 400 then return end
            dress(a, kind, math.random(0, 359), true)
            made = made + 1
        end)
    end
    log("Lotto: %d dropped %s made", made, kind.name:lower())
end)

Core.every(1, function()
    if not live() then return end
    local ok, e = pcall(scan)
    if not ok then log("Lotto: %s", tostring(e)) end
end)

-- The game loads its item table anew with every world. The rows go into it when a save
-- starts loading (before the call: the save's inventories are read after them), and
-- whenever the table is found without them.
Core.every(3, function()
    if live() then pcall(ensureItems) end
end)
pcall(RegisterHook, "/Script/RamaSaveSystem.RamaSaveLibrary:RamaSave_LoadFromFile", function()
    if not live() then return end
    local ok, e = pcall(ensureItems, true)
    if not ok then log("Lotto: %s", tostring(e)) end
end)

---------------------------------------------------------------- the inventory

local NAMES = { "InventoryComponent.ItemNames", "InventoryComponent.ItemQuantities", "InventoryComponent.ItemLocalGuids" }

-- The player's stacks of tickets: { id, count, guid }.
local function stacks(player)
    local out = {}
    local v = Repl.export(player, NAMES)
    local ids, counts, guids = Repl.splitArray(v[NAMES[1]] or "()"), Repl.splitArray(v[NAMES[2]] or "()"), Repl.splitArray(v[NAMES[3]] or "()")
    for i, raw in ipairs(ids) do
        local id = raw:gsub('"', "")
        if BY_ID[id] then
            local a, b, c, d = tostring(guids[i] or ""):match("A=(%-?%d+),B=(%-?%d+),C=(%-?%d+),D=(%-?%d+)")
            out[#out + 1] = { id = id, count = math.floor(tonumber(counts[i]) or 0),
                guid = a and { A = tonumber(a), B = tonumber(b), C = tonumber(c), D = tonumber(d) } or nil }
        end
    end
    return out
end
Lotto.stacks = function() local p = World.player() return p and stacks(p) or {} end

local function count(player, key)
    local n = 0
    for _, s in ipairs(stacks(player)) do
        if key == nil or s.id == KINDS[key].id then n = n + s.count end
    end
    return n
end

local function winners(player)
    local n = 0
    for _, s in ipairs(stacks(player)) do if BY_ID[s.id].value then n = n + s.count end end
    return n
end

-- Tickets a shop takes: the winning ones (paid) and the used ones (thrown away for the
-- player, who would otherwise have to carry them to a bin).
local function handable(player)
    local n = 0
    for _, s in ipairs(stacks(player)) do if BY_ID[s.id].value or s.id == KINDS.used.id then n = n + s.count end end
    return n
end

-- Takes one ticket of `kind` out of the inventory. True when it did.
local function takeOne(player, kind)
    for _, s in ipairs(stacks(player)) do
        if s.id == kind.id and s.count > 0 and s.guid then
            local before = count(player, kind.key)
            pcall(function() player.InventoryComponent:RemoveItem(s.guid, 1) end)
            if count(player, kind.key) < before then return true end
        end
    end
    return false
end

-- Gives the player a ticket of `kind` the way a find is picked up: into the inventory, or
-- left at their feet when there is no room. `n`: so many of them (one stack).
local function give(player, kind, n)
    local l = player:K2_GetActorLocation()
    local f = player:GetActorForwardVector()
    local a = player:GetWorld():SpawnActor(asset(CARRIER), { X = l.X + f.X * 40, Y = l.Y + f.Y * 40, Z = l.Z - 60 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(a) then return false end
    if n and n > 1 then
        pcall(function() a.quantity = n end)
        dress(a, kind, math.random(0, 359), true)
    else
        dress(a, kind, math.random(0, 359))
    end
    local before = count(player, kind.key)
    pcall(function() a:objectPickup() end)
    return count(player, kind.key) > before
end
Lotto.give = function(key) local p = World.player() return p and give(p, KINDS[key]) end

-- What a shop sells comes as a stack of its own (the game never adds a purchase to a
-- stack the player has already), and every stack takes one of the inventory's places. So
-- stacks of the same ticket are put together: the later one is taken out and picked up
-- again, which the game adds to the first. One stack at a time, and never while a window
-- that shows the inventory is open.
local function tidy(player)
    local busy = true
    pcall(function()
        busy = player.isTrading == true or player.inventoryOpen == true or player.inDialogue == true or valid(player.curContainer)
    end)
    if busy then return end
    local first = {}
    for _, s in ipairs(stacks(player)) do
        if first[s.id] and s.guid and s.count > 0 then
            local kind = BY_ID[s.id]
            local before = count(player, kind.key)
            pcall(function() player.InventoryComponent:RemoveItem(s.guid, s.count) end)
            local taken = before - count(player, kind.key)
            if taken > 0 and not give(player, kind, taken) then
                log("Lotto: %d %s could not be put with the others: at the player's feet", taken, kind.name:lower())
            end
            return
        end
        first[s.id] = true
    end
end

---------------------------------------------------------------- scratching

local seeded = false
local function roll()
    if not seeded then
        math.randomseed(os.time() + math.floor(os.clock() * 1000))
        seeded = true
    end
    local r, acc = math.random(), 0
    for _, o in ipairs(Lotto.ODDS) do
        acc = acc + o.p
        if r < acc then return o.win end
    end
    return 0
end

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- The fifteen amounts under the foil, 5 across and 3 down. The outcome is rolled first
-- (Lotto.ODDS); the board only shows it. Three equal amounts in a row win: across, down or
-- slanting (LINES). A winning board has exactly one such row, of the amount won; a losing
-- one has none. Returns the amounts and the winning row (three box numbers) or nil.
local COLS, ROWS = 5, 3
local LINES = {}
for r = 0, ROWS - 1 do
    for c = 0, COLS - 1 do
        for _, d in ipairs({ { 0, 1 }, { 1, 0 }, { 1, 1 }, { 1, -1 } }) do
            local r2, c2 = r + 2 * d[1], c + 2 * d[2]
            if r2 < ROWS and c2 >= 0 and c2 < COLS then
                LINES[#LINES + 1] = { r * COLS + c + 1, (r + d[1]) * COLS + c + d[2] + 1, r2 * COLS + c2 + 1 }
            end
        end
    end
end
Lotto.LINES = LINES

local function board(win)
    local n = COLS * ROWS
    local t, line = {}, nil
    if win > 0 then
        line = LINES[math.random(1, #LINES)]
        for _, i in ipairs(line) do t[i] = win end
    end
    -- the false hope: a big prize twice side by side, or once
    local r = math.random()
    if r < Lotto.TEASE + Lotto.LONE then
        local big = Lotto.BIG[math.random(1, #Lotto.BIG)]
        -- (a ticket that won a big prize teases with the other one)
        if big == win then big = win == 100 and 500 or 100 end
        for _ = 1, 40 do
            local l = LINES[math.random(1, #LINES)]
            local a, b = l[1], l[2]
            if math.random() < 0.5 then a, b = l[2], l[3] end
            if not t[a] and not t[b] then
                t[a] = big
                if r < Lotto.TEASE then t[b] = big end
                break
            end
        end
    end
    -- the rest: small amounts, none of them more than three times, and never a third
    -- equal one in a row
    local used = {}
    for i = 1, n do if t[i] then used[t[i]] = (used[t[i]] or 0) + 1 end end
    local function makesRow(i, a)
        for _, l in ipairs(LINES) do
            if l[1] == i or l[2] == i or l[3] == i then
                local same = true
                for _, k in ipairs(l) do if k ~= i and t[k] ~= a then same = false end end
                if same then return true end
            end
        end
        return false
    end
    local order = {}
    for i = 1, n do if not t[i] then order[#order + 1] = i end end
    shuffle(order)
    for _, i in ipairs(order) do
        local faces = shuffle({ table.unpack(Lotto.FACES) })
        for _, a in ipairs(faces) do
            if (used[a] or 0) < 3 and not makesRow(i, a) then
                t[i] = a
                break
            end
        end
        -- (cannot happen with eight faces; a box is never left empty)
        t[i] = t[i] or Lotto.FACES[1]
        used[t[i]] = (used[t[i]] or 0) + 1
    end
    return t, line
end
Lotto.board = board

-- (tests) the rows of three equal amounts on a board
function Lotto.rows(t)
    local out = {}
    for _, l in ipairs(LINES) do
        if t[l[1]] == t[l[2]] and t[l[2]] == t[l[3]] then out[#out + 1] = l end
    end
    return out
end

-- The ticket's picture is 560 x 820; the boxes in it, 5 across and 3 down (as
-- tools/lotto_art.py draws them).
local PIC = { w = 560, h = 820 }
local BOXES = {}
for r = 0, 2 do
    for c = 0, 4 do
        local x0, y0 = 40 + c * 98, 388 + r * 91
        BOXES[#BOXES + 1] = { x0, y0, x0 + 88, y0 + 80 }
    end
end
Lotto.CELLS = #BOXES
Lotto.CELL = 14               -- foil flakes, in the ticket picture's pixels
Lotto.REACH = 23              -- how far round the mouse the foil comes off (picture pixels)
Lotto.CLEAR = 0.62            -- a box whose foil is this far gone is cleared at once

local game = nil              -- the ticket on screen: { win, amounts, boxes, scr, ... }
local SCRATCH_SOUND = "/Game/Audio/WeedGrowing/pullingOutFlower-01.pullingOutFlower-01"
local CASH_SOUND = "/Game/Audio/GUI/popupCashRecieved_SFX.popupCashRecieved_SFX"

local function sound(path, volume, pitch)
    pcall(function()
        local s = asset(path)
        if s then StaticFindObject("/Script/Engine.Default__GameplayStatics"):PlaySound2D(World.player(), s, volume or 1, pitch or 1, 0, nil, nil) end
    end)
end

local NO_HIT, COLLAPSED = 3, 1
local FOIL = { R = 0.62, G = 0.63, B = 0.66, A = 1 }
local INK = { R = 0.04, G = 0.24, B = 0.13, A = 1 }
local GOLD = { R = 0.97, G = 0.77, B = 0.15, A = 1 }

local finish, nextTicket            -- (below)

local function render()
    local g = game
    if not g or not g.scr then return end
    local s = g.scr
    if g.panel then s.removeAll(g.panel) end
    g.panel = {}
    local function put(w, ax, ay, x, y)
        s.place(w, ax, ay, x, y)
        g.panel[#g.panel + 1] = w
        return w
    end
    local function button(label, scale, ax, ay, fn)
        local b = s.bigButton(label, scale, fn)
        put(b.box, ax, ay, 0, 0)
        return b
    end
    -- the words and buttons: one column, in the middle of the room right of the ticket
    local right = 0.5 + (g.cx + g.dispW / 2) / g.unitsW
    local ax = (right + 1) / 2
    if g.done then
        -- (another fresh ticket in the pockets: straight on to it)
        local more = false
        pcall(function() more = count(World.player(), "fresh") > 0 end)
        if g.win > 0 then
            put(s.text("WINNER", "button", 54, GOLD), ax, 0.36)
            put(s.text(string.format("$%d", g.win), "button", 72, Screen.GREEN), ax, 0.44)
            put(s.text("CASH IT AT THE GAS STATION,", "button", 15), ax, 0.52)
            put(s.text("JAY'S OR ROBERT'S IN SECTOR C", "button", 15), ax, 0.55)
            if more then
                button("NEXT TICKET", 1.4, ax, 0.64, function() nextTicket() end)
                button("DONE", 1.4, ax, 0.71, function() finish() end)
            else
                button("DONE", 1.4, ax, 0.64, function() finish() end)
            end
        else
            put(s.text("NO LUCK", "button", 54, Screen.RED), ax, 0.42)
            put(s.text("NOT THIS TIME", "button", 18), ax, 0.49)
            if more then
                button("NEXT TICKET", 1.4, ax, 0.6, function() nextTicket() end)
                button("DONE", 1.4, ax, 0.67, function() finish() end)
            else
                button("DONE", 1.4, ax, 0.6, function() finish() end)
            end
        end
    else
        put(s.text("HOLD THE LEFT MOUSE BUTTON", "button", 17), ax, 0.39)
        put(s.text("AND RUB THE SILVER OFF", "button", 17), ax, 0.42)
        put(s.text("3 IN A ROW WINS", "button", 17, GOLD), ax, 0.47)
        button("SCRATCH ALL", 1.4, ax, 0.56, function() Lotto.revealAll() end)
        -- (a ticket not yet touched goes back into the pocket as it was)
        if not g.touched then button("PUT IT AWAY", 1.4, ax, 0.63, function() finish() end) end
    end
end

-- Lays the ticket, the amounts and the foil out on the screen.
local function layTicket(g)
    local s = g.scr
    local W, H = s.units()
    g.unitsW, g.unitsH = W, H
    local k = math.min(1.05, (H * 0.86) / PIC.h)
    g.k = k
    g.dispW, g.dispH = PIC.w * k, PIC.h * k
    -- the ticket sits a little left of the middle; the words and buttons are on its right
    g.cx = -math.min(170, W * 0.09)
    local dim = s.box({ R = 0, G = 0, B = 0, A = 0.8 })
    dim:SetVisibility(NO_HIT)
    s.fill(dim, 0)
    local function at(widget, x, y, w, h, z)
        local slot = s.canvas:AddChildToCanvas(widget)
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
        slot:SetAlignment({ X = 0, Y = 0 })
        slot:SetAutoSize(false)
        slot:SetPosition({ X = x, Y = y })
        slot:SetSize({ X = w, Y = h })
        if z then slot:SetZOrder(z) end
        return slot
    end
    -- picture: (px, py) in the ticket's own pixels -> screen units from the middle
    local x0, y0 = g.cx - g.dispW / 2, -g.dispH / 2
    g.x0, g.y0 = x0, y0
    local face = s.new("Image")
    pcall(function() face:SetBrushFromTexture(texture("ticket_face"), false) end)
    face:SetVisibility(NO_HIT)
    at(face, x0, y0, g.dispW, g.dispH, 1)
    g.boxes = {}
    local rnd = math.random
    for i, b in ipairs(BOXES) do
        local box = { amount = g.amounts[i], cells = {}, left = 0, clear = false }
        local bx, by, bw, bh = b[1], b[2], b[3] - b[1], b[4] - b[2]
        local t = s.text(string.format("$%d", box.amount), "button", math.floor(math.min(bw, bh) * 0.42 * k + 0.5), INK)
        local tslot = s.canvas:AddChildToCanvas(t)
        tslot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
        tslot:SetAlignment({ X = 0.5, Y = 0.5 })
        tslot:SetAutoSize(true)
        tslot:SetPosition({ X = x0 + (bx + bw / 2) * k, Y = y0 + (by + bh / 2) * k })
        tslot:SetZOrder(2)
        box.text = t
        local n = Lotto.CELL
        local cols, rows = math.ceil(bw / n), math.ceil(bh / n)
        local cw, ch = bw / cols, bh / rows
        for r = 0, rows - 1 do
            for c = 0, cols - 1 do
                local img = s.new("Image")
                local shade = 0.96 + rnd() * 0.08
                img:SetColorAndOpacity({ R = FOIL.R * shade, G = FOIL.G * shade, B = FOIL.B * shade, A = 1 })
                img:SetVisibility(NO_HIT)
                -- (a hair larger than its share, so that no seams show)
                at(img, x0 + (bx + c * cw) * k - 0.5, y0 + (by + r * ch) * k - 0.5, cw * k + 1, ch * k + 1, 3)
                box.cells[#box.cells + 1] = { img = img, x = bx + (c + 0.5) * cw, y = by + (r + 0.5) * ch, on = true }
            end
        end
        box.left = #box.cells
        g.boxes[i] = box
    end
end

local function clearBox(box)
    for _, c in ipairs(box.cells) do
        if c.on then
            c.on = false
            pcall(function() c.img:SetVisibility(COLLAPSED) end)
        end
    end
    box.left, box.clear = 0, true
end

local function checkDone()
    local g = game
    if not g or g.done then return end
    for _, b in ipairs(g.boxes) do if not b.clear then return end end
    g.done = true
    if g.win > 0 then
        sound(CASH_SOUND, 1)
        -- the three that won, in red like a pen ring round them
        for _, i in ipairs(g.line or {}) do
            local b = g.boxes[i]
            if b then
                pcall(function() b.text:SetColorAndOpacity({ SpecifiedColor = { R = 0.78, G = 0.08, B = 0.08, A = 1 }, ColorUseRule = 0 }) end)
            end
        end
    end
    render()
end

function Lotto.revealAll()
    local g = game
    if not g or g.done then return end
    for _, b in ipairs(g.boxes) do clearBox(b) end
    checkDone()
end

-- One rub at screen units (ux, uy) from the middle.
local function rub(ux, uy)
    local g = game
    local px, py = (ux - g.x0) / g.k, (uy - g.y0) / g.k
    local reach = Lotto.REACH
    local any = false
    for _, b in ipairs(g.boxes) do
        if not b.clear then
            for _, c in ipairs(b.cells) do
                if c.on and (c.x - px) ^ 2 + (c.y - py) ^ 2 <= reach * reach then
                    c.on = false
                    b.left = b.left - 1
                    any = true
                    pcall(function() c.img:SetVisibility(COLLAPSED) end)
                end
            end
            if b.left <= #b.cells * (1 - Lotto.CLEAR) then clearBox(b) end
        end
    end
    if any and not g.touched then
        g.touched = true
        render()            -- (it cannot be put away any more)
    end
    return any
end
Lotto.rub = function(ux, uy) if game then local r = rub(ux, uy) checkDone() return r end end

-- What the scratching made of the ticket goes into the inventory, whatever way the screen
-- is closed (a ticket taken off the screen half scratched is scratched all the same). A
-- ticket nobody has rubbed yet goes back as it was.
local function settle(g)
    if g.settled then return end
    g.settled = true
    local player = World.player()
    if not player or player:GetAddress() ~= g.owner then return end
    if not g.touched and not g.done then
        if not give(player, KINDS.fresh) then Hud.toast("No room for the ticket: it is at your feet", 4) end
        return
    end
    local kind = g.win > 0 and KINDS["win" .. g.win] or KINDS.used
    if not give(player, kind) then Hud.toast("No room for the ticket: it is at your feet", 4) end
    Lotto.stats.scratched = Lotto.stats.scratched + 1
    if g.win > 0 then Lotto.stats.won = Lotto.stats.won + g.win end
    log("Lotto: a ticket was scratched: %s", g.win > 0 and ("won $" .. g.win) or "nothing")
end

finish = function()
    local g = game
    if not g then return end
    game = nil
    local s = g.scr
    g.scr = nil
    if s then
        s.onClose = nil
        pcall(s.close)
    end
    pcall(function()
        local c = World.player():GetController()
        c:ResetIgnoreLookInput()
        c:ResetIgnoreMoveInput()
    end)
    pcall(settle, g)
end

-- This ticket goes into the inventory as what it turned out to be, and the next fresh one
-- comes on screen.
nextTicket = function()
    finish()
    Core.after(0.05, function()
        if live() and not game then
            local ok, e = pcall(Lotto.scratch)
            if not ok then log("Lotto: %s", tostring(e)) end
        end
    end)
end

-- Scratches one fresh ticket of the player's. `outcome` (tests): the amount it wins.
function Lotto.scratch(outcome)
    if game then return false end
    local player = World.player()
    if not player then return false end
    if not ensureItems() then return false end
    local busy = false
    pcall(function() busy = player.isTrading == true or player.inDialogue == true or player.atWorkStation == true end)
    if busy then return false end
    if count(player, "fresh") <= 0 then return false end
    pcall(function() if player.inventoryOpen == true then player:closeInventory() end end)
    if not takeOne(player, KINDS.fresh) then
        Hud.toast("The ticket could not be taken out", 3)
        return false
    end
    local win = outcome or roll()
    local amounts, line = board(win)
    local g = { win = win, amounts = amounts, line = line, owner = player:GetAddress() }
    local s = Screen.open()
    if not s then
        give(player, KINDS.fresh)
        return false
    end
    g.scr = s
    game = g
    local ok, e = pcall(layTicket, g)
    if not ok then
        log("Lotto: the ticket could not be laid out: %s", tostring(e))
        game = nil
        s.onClose = nil
        pcall(s.close)
        give(player, KINDS.fresh)
        return false
    end
    s.onClose = function() if game == g then finish() end end
    pcall(function()
        local c = player:GetController()
        c:SetIgnoreLookInput(true)
        c:SetIgnoreMoveInput(true)
    end)
    render()
    return true
end

function Lotto.game() return game end

-- The mouse, while a ticket is on screen: held down, it rubs along the way it moved.
local LMB = nil
Core.onTick(function()
    if not live() then return end
    local g = game
    if not g then return end
    if not g.scr or not valid(g.scr.widget) or World.gone then
        game = nil
        pcall(settle, g)
        return
    end
    if g.done then return end
    local player = World.player()
    if not player or player:GetAddress() ~= g.owner then
        game = nil
        return
    end
    local pc = player:GetController()
    LMB = LMB or { KeyName = FName("LeftMouseButton") }
    local x, y, down, scale = {}, {}, false, 1
    pcall(function()
        pc:GetMousePosition(x, y)
        down = pc:IsInputKeyDown(LMB) == true
        scale = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportScale(player)
    end)
    local mx, my = tonumber(x.LocationX), tonumber(y.LocationY)
    if not mx or not my or type(scale) ~= "number" or scale <= 0 then return end
    local ux, uy = mx / scale - g.unitsW / 2, my / scale - g.unitsH / 2
    if down then
        local any = false
        if g.last then
            -- (along the way from the last position, so that a fast stroke leaves no gaps)
            local dx, dy = ux - g.last.x, uy - g.last.y
            local steps = math.max(1, math.floor(math.sqrt(dx * dx + dy * dy) / (Lotto.REACH * g.k * 0.6)))
            for i = 1, steps do
                if rub(g.last.x + dx * i / steps, g.last.y + dy * i / steps) then any = true end
            end
        elseif rub(ux, uy) then
            any = true
        end
        g.last = { x = ux, y = uy }
        if any and os.clock() - (g.soundAt or 0) > 0.22 then
            g.soundAt = os.clock()
            sound(SCRATCH_SOUND, 0.35, 1.3 + math.random() * 0.4)
        end
        checkDone()
    else
        g.last = nil
    end
end)

-- Double-clicking a fresh ticket scratches it: in the backpack (the game's item widget
-- does nothing on a double-click there while no container is open) and in a pocket
-- (two presses on the same pocket within the double-click time).
local INV_ITEM = "/Game/Player/Inventory/inventoryItemWidget.inventoryItemWidget_C"
local POCKET = "/Game/Player/Inventory/pocketSlotWidget.pocketSlotWidget_C"

local function scratchSoon()
    Core.after(0.05, function()
        if live() and not game then
            local ok, e = pcall(Lotto.scratch)
            if not ok then log("Lotto: %s", tostring(e)) end
        end
    end)
end

-- (with a container or a trade open, a double-click moves the item: the game's own)
local function busyWindow(player)
    local busy = false
    pcall(function() busy = valid(player.curContainer) or player.isTrading == true end)
    return busy
end

Core.Hooks.add(INV_ITEM .. ":OnMouseButtonDoubleClick", function(ctx)
    if not live() then return end
    local w = ctx:get()
    local ok, id = pcall(function() return w.ItemID:ToString() end)
    if not ok or id ~= KINDS.fresh.id then return end
    local player = World.player()
    if not player or busyWindow(player) then return end
    scratchSoon()
end)

-- A pocket takes only the first press of a double-click (it starts a drag with it); the
-- second comes as a double-click it has no use for, and goes on to the game, where the
-- player's controller sees the left button go down. So a press on a fresh ticket in a
-- pocket waits a moment for that (a press that starts a drag never reaches the game).
-- Two plain presses on the same pocket close together count as well.
local DOUBLE = 0.5
local lastPress = { address = nil, at = 0 }
local armed = nil             -- { till, sawUp }: a pocket press on a fresh ticket

Core.Hooks.add(POCKET .. ":OnMouseButtonDown", function(ctx)
    if not live() then return end
    local w = ctx:get()
    local ok, id, address = pcall(function() return w.ItemID:ToString(), w:GetAddress() end)
    if not ok then return end
    local now = os.clock()
    local double = lastPress.address == address and now - lastPress.at < DOUBLE
    lastPress = { address = address, at = now }
    if id ~= KINDS.fresh.id or busyWindow(World.player()) then
        armed = nil
        return
    end
    if double then
        lastPress.at, armed = 0, nil
        scratchSoon()
        return
    end
    armed = { till = now + DOUBLE, sawUp = false }
end)

Core.onTick(function()
    local a = armed
    if not a or not live() then return end
    if os.clock() > a.till or game then
        armed = nil
        return
    end
    local player = World.player()
    local down = false
    pcall(function()
        LMB = LMB or { KeyName = FName("LeftMouseButton") }
        down = player:GetController():IsInputKeyDown(LMB) == true
    end)
    -- (the first press itself never shows here; should it ever, it has to be let go first)
    if not down then
        a.sawUp = true
    elseif a.sawUp then
        armed = nil
        scratchSoon()
    end
end)

---------------------------------------------------------------- cashing

-- At a shop that cashes tickets, a player carrying a winning one has one more answer:
-- "I've got a winning scratch ticket". It leads to "Let's see that ticket" with "Here",
-- which opens the game's trade window laid out for a sale. Winning tickets dragged into
-- it are paid out when it is accepted; anything else in it goes back, and nothing is paid.
-- `inPlace`: the lines go into the shopkeeper's own dialogue (put back when the player
-- leaves, and before the game saves) instead of a copy of it: Robert's own answers run
-- functions of his dialogue's class (the smuggling job), which a copy would not have.
local SHOPS = {
    { key = "amy", class = "/Game/Skeletal/NPC/ShopOwners/Amy/npcAmy.npcAmy_C" },
    { key = "jay", class = "/Game/Skeletal/NPC/ShopOwners/Jay/npcJay.npcJay_C" },
    { key = "robert", class = "/Game/Skeletal/NPC/ShopOwners/Smugglers/smugglerShopSectorC.smugglerShopSectorC_C", inPlace = true },
}
local DIALOGUE = "/Game/Interactive/dialogueInstance.dialogueInstance_C"
local PLAYER = "/Game/Player/playerCharacterBP.playerCharacterBP_C"
local OURS = "DDSMP-LOTTO"
local SEE = "Let's see that ticket."
local RANGE = 2500
local PAID, REFUSED, BINNED = 1, 2, 3    -- lines after "let's see that ticket"

local counters = {}           -- key -> { owner, npc, original, root, seeLine, inPlace, base }
local window = nil            -- while the trade window is open for tickets

local function same(a, b)
    local ok, v = pcall(function() return a:GetAddress() == b:GetAddress() end)
    return ok and v
end

local function isMod(d)
    local ok, v = pcall(function() return d.DialogueID:ToString():sub(1, 6) == "DDSMP-" end)
    return ok and v
end

local function talking(player)
    local ok, v = pcall(function() return player.inDialogue == true end)
    return ok and v
end

local function saying(player)
    local ok, t = pcall(function() return player.dialogueWidget.txtDialLine:GetText():ToString() end)
    return ok and t or ""
end

-- The shopkeeper's own dialogue (never one the mod made).
local function ownDialogue(c)
    if Core.alive(c.original) then return c.original end
    c.original = nil
    local cur = nil
    pcall(function() cur = c.npc.curDialogue end)
    if valid(cur) and not isMod(cur) then
        c.original = cur
        return cur
    end
    for _, d in ipairs(Core.actors(DIALOGUE) or {}) do
        local ok, theirs = pcall(function() return Core.alive(d) and not isMod(d) and valid(d.talkerRef) and same(d.talkerRef, c.npc) end)
        if ok and theirs then
            c.original = d
            return d
        end
    end
    return nil
end

local function drop(c)
    if c.borrowed then
        -- (the wall quest's talk on Amy: its own to put away)
        c.root, c.seeLine, c.borrowed = nil, nil, nil
        return
    end
    if c.inPlace then
        -- (the shopkeeper's own dialogue gets its own lines back)
        pcall(function() if Core.alive(c.root) and c.base then Repl.importRaw(c.root, "dialogueLines", c.base) end end)
        c.root, c.seeLine, c.base = nil, nil, nil
        return
    end
    if not World.gone and Core.alive(c.npc) then
        pcall(function()
            local cur = c.npc.curDialogue
            if valid(cur) and same(cur, c.root) and Core.alive(c.original) then c.npc.curDialogue = c.original end
        end)
    end
    pcall(function() if Core.alive(c.root) then c.root:K2_DestroyActor() end end)
    c.root, c.seeLine = nil, nil
end

-- Amy is the wall quest's while it has a talk of its own on her. The quest then puts the
-- cashing answer into that talk (Lotto.cashAnswer; the number of its "let's see that
-- ticket" line is the quest's `extraLine`), and the counter works on the quest's dialogue.
local function wallAmy()
    local ok, v = pcall(function()
        local Quest = package.loaded["coop.wallquest"]
        local a = Quest and Quest.amy and Quest.amy()
        return a ~= nil and Core.alive(a.root) and a or nil
    end)
    return ok and v or nil
end

local function cashAnswer(n)
    return { "I've got scratch tickets", to = n }, {
        { SEE, { "Here", sale = true }, { "Never mind" } },
        { "There you go. Don't spend it all in one place.", { "Thanks" } },
        { "I only take scratched tickets.", { "Fine" } },
        { "No luck, huh. I'll bin those for you.", { "Thanks" } },
    }
end

-- (for the wall quest) the answer to add to Amy's talk, when this player has a winner
function Lotto.cashAnswer(player)
    local ok, n = pcall(handable, player)
    return ok and n > 0 and cashAnswer or nil
end

local function tendCounter(player, shop)
    local c = counters[shop.key]
    if not c or c.owner ~= player:GetAddress() or not Core.alive(c.npc) then
        if c then drop(c) end
        c = nil
        for _, a in ipairs(Core.actors(shop.class) or {}) do
            if Core.alive(a) then
                c = { owner = player:GetAddress(), npc = a, inPlace = shop.inPlace }
                break
            end
        end
        counters[shop.key] = c
        if not c then return end
    end
    if window and same(window.npc, c.npc) then return end
    local near = false
    pcall(function()
        local l, p = c.npc:K2_GetActorLocation(), player:K2_GetActorLocation()
        near = (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 < RANGE * RANGE
    end)
    local want = near and handable(player) > 0
    if shop.key == "amy" then
        local a = wallAmy()
        if a then
            if c.root and not c.borrowed then drop(c) end
            if want and a.extraLine then
                c.root, c.seeLine, c.borrowed = a.root, a.extraLine, true
            else
                c.root, c.seeLine, c.borrowed = nil, nil, nil
            end
            return
        elseif c.borrowed then
            drop(c)
        end
    end
    if not want then
        if c.root and not talking(player) then drop(c) end
        return
    end
    if talking(player) then return end
    local cur = nil
    pcall(function() cur = c.npc.curDialogue end)
    -- (somebody else's talk on the shopkeeper: theirs comes first)
    if valid(cur) and isMod(cur) and not same(cur, c.root) then return end
    local own = ownDialogue(c)
    if not own then return end
    if c.root and not Core.alive(c.root) then c.root, c.seeLine, c.base = nil, nil, nil end
    if not c.root then
        local Quest = package.loaded["coop.wallquest"]
        if not Quest or not Quest.extended then return end
        local base = Repl.export(own, { "dialogueLines" }).dialogueLines
        local text = type(base) == "string" and Quest.extended(base, cashAnswer) or nil
        if not text then return end
        if c.inPlace then
            if not Repl.importRaw(own, "dialogueLines", text) then
                log("Lotto: the ticket talk could not be added for %s", shop.key)
                return
            end
            c.root, c.base = own, base
            c.seeLine = #Repl.splitArray(base)
            return
        end
        local l = c.npc:K2_GetActorLocation()
        local d = player:GetWorld():SpawnActor(asset(DIALOGUE), { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(d) then return end
        pcall(function() if valid(d.RamaSave) then d.RamaSave:K2_DestroyComponent(d) end end)
        pcall(function() d.DialogueID = FName(OURS) end)
        if not Repl.importRaw(d, "dialogueLines", text) then
            pcall(function() d:K2_DestroyActor() end)
            log("Lotto: the cashing talk could not be set up")
            return
        end
        pcall(function()
            d.firstDialougueID, d.startDialogueID, d.tradeReturnID = own.firstDialougueID, own.startDialogueID, own.tradeReturnID
            d.talkerRef = c.npc
        end)
        c.root = d
        c.seeLine = #Repl.splitArray(base)
    end
    if not valid(cur) or not same(cur, c.root) then
        pcall(function() c.npc.curDialogue = c.root end)
    end
end

local TRADED = { "tradedItemIDs", "tradedItemQuantities" }

local function openWindow(player, c)
    local screen = player.InventoryWidget
    local npc = c.npc
    if not valid(screen) or not Core.alive(c.root) or not c.seeLine then return end
    local was = Repl.export(npc, { "drugsDemandedID", "drugsDemandedQuantity", "drugsExpectedPrices" })
    Repl.import(npc, { drugsDemandedID = "()", drugsDemandedQuantity = "()", drugsExpectedPrices = "()" })
    -- (the window is laid out for a sale when its other side keeps no shop: for the moment
    -- of laying it out, the shopkeeper does not)
    local ok, e = pcall(function()
        npc.shopOwner = false
        local done = pcall(function() screen:prepareInventoryMode(player.curContainer, npc, player) end)
        if not done then screen:prepareInventoryMode(nil, npc, player) end
    end)
    pcall(function() npc.shopOwner = true end)
    if not ok then
        log("Lotto: the cashing window could not be laid out: %s", tostring(e))
        pcall(Repl.import, npc, was)
        return
    end
    pcall(function() screen.txtTradeTitle:SetText(FText("CASH TICKETS")) end)
    -- (a window for a sale takes only drugs; the one of a shop takes anything: the list is
    -- told it is a shop's. That only leaves out the green light while something is dragged
    -- over it.)
    pcall(function() screen.tradeItemList.declineSale = true end)
    -- the window's words for drugs, while it is the tickets' (put back when it closes)
    local labels = {}
    pcall(function()
        local screenAddress = screen:GetAddress()
        for _, t in ipairs(FindAllOf("TextBlock") or {}) do
            pcall(function()
                local s = t:GetText():ToString()
                local new = (s:find("^DROP DRUGS") and "DROP SCRATCHED\nTICKETS HERE") or (s == "Drugs expected:" and "Winning and used tickets") or nil
                if not new then return end
                local o = t:GetOuter()
                for _ = 1, 6 do
                    if not valid(o) then return end
                    if o:GetAddress() == screenAddress then break end
                    o = o:GetOuter()
                end
                if valid(o) and o:GetAddress() == screenAddress then
                    labels[#labels + 1] = { widget = t, text = s }
                    t:SetText(FText(new))
                end
            end)
        end
    end)
    local back = 0
    pcall(function() back = c.root.tradeReturnID end)
    window = { npc = npc, screen = screen, root = c.root, line = c.seeLine, back = back, was = was, labels = labels }
    pcall(function() c.root.tradeReturnID = c.seeLine end)
    log("Lotto: the cashing window is open")
end

-- What lies in the window: the money the winning tickets in it are worth, and whether
-- anything else is in it.
local function offered(screen)
    if not valid(screen) or not valid(screen.tradeItemList) then return 0, false, 0 end
    local v = Repl.export(screen.tradeItemList, TRADED)
    local ids, counts = Repl.splitArray(v[TRADED[1]] or "()"), Repl.splitArray(v[TRADED[2]] or "()")
    local money, other = 0, false
    for i, raw in ipairs(ids) do
        local k = BY_ID[(raw:gsub('"', ""))]
        local n = math.max(1, math.floor(tonumber(counts[i]) or 1))
        -- (a used ticket is taken for nothing; a fresh one or anything else is not theirs to take)
        if k and k.value then money = money + k.value * n elseif not (k and k.id == KINDS.used.id) then other = true end
    end
    return money, other, #ids
end

local function pay(player, amount)
    local before = 0
    local function cash()
        local out, n = {}, 0
        pcall(function()
            player:countAllMoney(out)
            n = tonumber(out.allMoneyCount) or 0
        end)
        return n
    end
    before = cash()
    pcall(function() player:addMoney(amount, true, {}) end)
    local missing = amount - (cash() - before)
    if missing > 0 then
        pcall(function()
            local computer = Core.find("mainComputer_C")
            computer.playerBankMoney = computer.playerBankMoney + missing
        end)
        Hud.toast(string.format("$%d went to your bank account: your pockets are full", missing), 5)
    end
end

local function closeWindow(player)
    local w = window
    window = nil
    if not w then return end
    local line = nil
    local ok, e = pcall(function()
        local money, other, stacksIn = offered(w.screen)
        if stacksIn == 0 then return end
        if other then
            w.screen:clearTradeItems()          -- (the game's own: everything back)
            line = REFUSED
            return
        end
        local list = w.screen.tradeItemList
        list:ClearTradedItems()
        list:renderTradeItems()
        if money <= 0 then
            log("Lotto: used tickets were handed in")
            line = BINNED
            return
        end
        pay(player, money)
        sound(CASH_SOUND, 1)
        Lotto.stats.cashed = Lotto.stats.cashed + money
        log("Lotto: tickets worth $%d were cashed", money)
        line = PAID
    end)
    if not ok then
        log("Lotto: the cashing window could not be settled: %s", tostring(e))
        pcall(function() w.screen:clearTradeItems() end)
    end
    pcall(function()
        if line and Core.alive(w.root) and player then
            w.root.tradeReturnID = w.line + line
            player.dialogueWidget:returnFromTrade()
        end
    end)
    pcall(function() if Core.alive(w.root) then w.root.tradeReturnID = w.back end end)
    pcall(function() if Core.alive(w.npc) then Repl.import(w.npc, w.was) end end)
    for _, l in ipairs(w.labels or {}) do
        pcall(function() if valid(l.widget) then l.widget:SetText(FText(l.text)) end end)
    end
end

local function counterTalking(player)
    for _, c in pairs(counters) do
        local ok, ours = pcall(function()
            return player.isTrading == true and Core.alive(c.root) and same(player.curSeller, c.npc) and saying(player) == SEE
        end)
        if ok and ours then return c end
    end
    return nil
end

Core.Hooks.add(PLAYER .. ":openTrade", function()
    if not live() or window then return end
    local player = World.player()
    if not player then return end
    local c = counterTalking(player)
    if c then
        local ok, e = pcall(openWindow, player, c)
        if not ok then log("Lotto: %s", tostring(e)) end
    end
end)

Core.onTick(function()
    if not live() then return end
    local player = World.player()
    if not window then
        -- (should the hook not be in place yet, the window is caught here a frame later)
        if player and next(counters) ~= nil then
            local c = counterTalking(player)
            if c then pcall(openWindow, player, c) end
        end
        return
    end
    local open = false
    pcall(function() open = player ~= nil and player.isTrading == true and valid(window.screen) end)
    if not open then
        closeWindow(player)
        return
    end
    -- (the game takes ACCEPT away from a shop's window while nothing is being bought)
    pcall(function() window.screen.btnAcceptTrade:SetIsEnabled(true) end)
end)

Core.every(1, function()
    if not live() then return end
    local player = World.player()
    if not player or World.joining or World.gone then
        counters = {}
        return
    end
    for _, shop in ipairs(SHOPS) do
        local ok, e = pcall(tendCounter, player, shop)
        if not ok then log("Lotto: %s: %s", shop.key, tostring(e)) end
    end
    if not game and not window then
        local ok, e = pcall(tidy, player)
        if not ok then log("Lotto: %s", tostring(e)) end
    end
end)

---------------------------------------------------------------- selling

-- The shops' rows in the game's shop table get the fresh ticket as one more product: the
-- BUY window lists a row's products (item and price, any number of them) and sells them
-- the game's own way. The rows are the table's own memory, so the product is added in
-- place, once per table (the game may load it anew).
Lotto.PRICE = 20
Lotto.SELLERS = { "SHOP-AMY", "SHOP-JAY", "SHOP-LAUNDRY-BACK" }     -- Amy, Jay, Robert's local shop
local SHOP_DB = "/Game/DataTables/ShopDatabase.ShopDatabase"
local P = { list = "ShopProducts_9_7832D5B44318B6677AC337AC9D3E48C9", id = "ProductID_2_61D18C814F9413C4177AA3B03A69AE14",
    price = "ProductPrice_5_328C964B4BE6AF79ACFB95BA8AA2E907" }

local function ensureProducts(fresh)
    local db = (not fresh and Core.class(SHOP_DB)) or asset(SHOP_DB)
    if not db then return false end
    local all = true
    for _, key in ipairs(Lotto.SELLERS) do
        local ok, e = pcall(function()
            local row = db:FindRow(key)
            if row == nil then return end
            local list = row[P.list]
            local n, there = list:GetArrayNum(), false
            for i = 1, n do
                if list[i][P.id]:ToString() == KINDS.fresh.id then
                    there = true
                    if list[i][P.price] ~= Lotto.PRICE then list[i][P.price] = Lotto.PRICE + 0.0 end
                end
            end
            if not there then
                list[n + 1] = { [P.id] = FName(KINDS.fresh.id), [P.price] = Lotto.PRICE + 0.0 }
                log("Lotto: %s sells scratch tickets", key)
            end
        end)
        if not ok then
            all = false
            log("Lotto: tickets could not be put on sale at %s: %s", key, tostring(e))
        end
    end
    return all
end
Lotto.ensureProducts = ensureProducts
Core.every(3, function()
    if live() then pcall(ensureProducts) end
end)
pcall(RegisterHook, "/Script/RamaSaveSystem.RamaSaveLibrary:RamaSave_LoadFromFile", function()
    if live() then pcall(ensureProducts, true) end
end)

-- (the lines added to a shopkeeper's own dialogue are never saved with it)
pcall(RegisterHook, "/Script/RamaSaveSystem.RamaSaveLibrary:RamaSave_SaveToFile", function()
    if not live() then return end
    for _, c in pairs(counters) do
        if c.inPlace and c.root then pcall(drop, c) end
    end
end)

function Lotto.counters() return counters end

-- (tests) why a counter has or lacks the cashing answer
function Lotto.why(key)
    local player, c = World.player(), counters[key]
    if not player or not c then return "no player or counter" end
    local parts = {}
    local function add(k, f)
        local ok, v = pcall(f)
        parts[#parts + 1] = k .. "=" .. (ok and tostring(v) or ("err " .. tostring(v)))
    end
    add("alive", function() return Core.alive(c.npc) end)
    add("owner", function() return c.owner == player:GetAddress() end)
    add("window", function() return window ~= nil end)
    add("near", function()
        local l, p = c.npc:K2_GetActorLocation(), player:K2_GetActorLocation()
        return math.floor(math.sqrt((l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2))
    end)
    add("winners", function() return winners(player) end)
    add("talking", function() return talking(player) end)
    add("curIsMod", function() return isMod(c.npc.curDialogue) end)
    add("own", function() return ownDialogue(c) ~= nil end)
    return table.concat(parts, " ")
end
function Lotto.window() return window end

return Lotto
