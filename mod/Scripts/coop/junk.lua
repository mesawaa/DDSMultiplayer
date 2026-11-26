-- The trash man: a homeless man who buys junk, in the small brick house in East Oldtown,
-- behind a small table made of a door on two barrels.
--
-- He buys water bottles (full or empty) and spray cans for a few dollars, takes used
-- scratch tickets for nothing, and buys valuables (watches, phones, jewellery, gold) for
-- about a third of what the game counts them at: less than a launder drop gives for them
-- after the launderer's cut. (Shops sell water bottles and spray paint for far more than
-- he pays: buying to sell to him gains nothing, so there is no limit on what he buys.)
-- He keeps the hours of Emma's stall and is gone in police hours; his table stays.
--
-- Talking to him uses the game's own dialogue screen (as with the mod's other people:
-- coop/edwin.lua). "Let's see what I have" opens the game's own inventory screen with his
-- box beside the player's pockets, as a stash or a dead drop opens: things are dragged
-- into it, and it takes only the kinds of things he buys (spray cans, water bottles,
-- scratch tickets, valuables). Under the box stands what a shop's counter has: ITEMS
-- VALUE, YOUR MONEY, and ACCEPT (he buys; what he does not buy goes back to the pockets),
-- CLEAR (all of it goes back) and CANCEL (it goes back and the screen closes, as it does
-- when the screen is closed any other way).
--
-- Every game puts its own man, table and box there; nothing of them is saved or shared
-- with the other games.

local Core = require("core")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Hud = require("coop.hud")
local Look = require("coop.look")
local Repl = require("coop.repl")
local Sync = require("coop.sync")
local NoTag = require("coop.notag")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_JUNK_GEN") or 0) + 1
_G.DDSMP_JUNK_GEN = GEN
local function live() return rawget(_G, "DDSMP_JUNK_GEN") == GEN end

local Junk = { NAME = "Trash man" }

-- The house's front wall (windows and door) runs along x 2870; its floor is at z 135. The
-- table stands in the room's back corner (placed with DDSScout): the game's
-- trash work station at two thirds of its size. He stands behind it, toward the corner,
-- turned to the room and the door.
local FLOOR = 135
local STAND = FLOOR + 88
local DESK = { x = 3200, y = 4450, z = 134.33, yaw = 60, scale = 0.683013,
    mesh = "/Game/StaticMeshes/Furniture/TrashWorkstation.TrashWorkstation" }
local MIDDLE = { x = 3231, y = 4448, top = 226 }      -- the middle of the table (its top: z 226)
local SPOT = { x = 3268, y = 4513, yaw = 240 }        -- behind the middle of the table
-- The ceiling lamp above his corner (placed with DDSScout): the game's trash ceiling
-- lamp, and under it a dim, warm light that flickers now and then. It is on only while he
-- is there.
local LAMP = { x = 3300, y = 4550, z = 362.42, yaw = 15, mesh = "/Game/StaticMeshes/Furniture/sm_TrashCeilingLamp.sm_TrashCeilingLamp" }
local LIGHT = { intensity = 900, radius = 600, color = { R = 1, G = 0.72, B = 0.42, A = 1 } }
-- The room (measured with lines of sight from inside): its walls' faces, the floor's top,
-- the ceiling's underside, and the street door in the front wall. Nothing inside can be
-- tagged (coop/notag.lua).
local ROOM = { x0 = 2872, x1 = 3440, y0 = 3825, y1 = 4735, floor = 135, ceiling = 430 }
local DOORS = { { wall = "x0", at = 4160, half = 70 } }
local BUILD_RANGE = 3500
local LOOK = { body = "SK_ma_casual_jacket_01_b", head = "SK_ma_head_01", hair = "", hat = "Hats_Hair/SK_ma_hat_casual_set_beanie_01",
    beard = "Hats_Hair/SK_ma_beard_single_02", arms = true }
Junk.SPOT, Junk.DESK, Junk.LOOK, Junk.MIDDLE = SPOT, DESK, LOOK, MIDDLE

-- His box: one of the game's containers, out of sight on the table. It takes the item
-- categories of what he buys: spray paint (10), water bottles (11), pieces (15: used
-- scratch tickets, but bobby pins and other tickets as well, which he leaves in the box),
-- valuables (16). (The game's garbage items, category 0, cannot be picked up in play.)
local BOX_CLASS = "/Game/Interactive/containerBase.containerBase_C"
local BOX_SIZE = { w = 4, h = 6 }       -- (the screen's container panel shows four columns whole)
local ACCEPTED = { 10, 11, 15, 16 }

-- What he pays: grouped rows, each with the items it stands for and the price of one.
local KINDS = {
    -- (about 35 % of the game's own values: 90, 300, 350, 550, 4,900, 9,600)
    { name = "WATCH", ids = { "ITEM-WATCH" }, price = 30 },
    { name = "PHONE", ids = { "ITEM-PHONE" }, price = 105 },
    { name = "BRACELET", ids = { "ITEM-BRACELET" }, price = 120 },
    { name = "NECKLACE", ids = { "ITEM-NECKLACE" }, price = 190 },
    { name = "GOLD BAR", ids = { "ITEM-GOLD-BAR-SMALL" }, price = 1715 },
    { name = "LARGE GOLD BAR", ids = { "ITEM-GOLD-BAR-LARGE" }, price = 3360 },
    -- (a water bottle full or empty)
    { name = "SPRAY CAN", ids = { "ITEM-SPRAYPAINT" }, price = 4 },
    { name = "WATER BOTTLE", ids = { "ITEM-WATER-BOTTLE" }, price = 2 },
    -- (taken for nothing: scratch tickets that have been scratched)
    { name = "USED SCRATCH TICKET", ids = { "ITEM-LOTTO-USED" }, price = 0 },
}
Junk.KINDS = KINDS

local function active() return World.extras() and Core.config.JunkBuyer ~= false end

-- He keeps the hours of Emma's stall (the game lets her be called from 07:00 to 20:00) and
-- is gone when police hours begin, at 20:00. His table stays.
local OPEN, CLOSE = 7, 20
local function atWork()
    local h = nil
    pcall(function() h = tonumber(Core.find("dayTimeControler_C").curHour) end)
    return h == nil or (h >= OPEN and h < CLOSE)
end
local function key(name) return tostring(Core.config[name] or "?") end

---------------------------------------------------------------- counting and paying

-- How many of each item an actor with an inventory holds.
local function contents(actor)
    local out = {}
    local v = Repl.export(actor, { "InventoryComponent.ItemNames", "InventoryComponent.ItemQuantities" })
    local names = Repl.splitArray(v["InventoryComponent.ItemNames"] or "()")
    local counts = Repl.splitArray(v["InventoryComponent.ItemQuantities"] or "()")
    for i, name in ipairs(names) do
        local id = tostring(name):gsub('"', "")
        out[id] = (out[id] or 0) + (tonumber(counts[i]) or 0)
    end
    return out
end

local function countOf(kind, have)
    local n = 0
    for _, id in ipairs(kind.ids) do n = n + (have[id] or 0) end
    return n
end

-- What he buys of `have`: { { kind, n } } and the money.
local function offer(have)
    local deal, money = {}, 0
    for _, kind in ipairs(KINDS) do
        local n = countOf(kind, have)
        if n > 0 then
            deal[#deal + 1] = { kind = kind, n = n }
            money = money + n * kind.price
        end
    end
    return deal, money
end

local function cash()
    local out = {}
    local ok = pcall(function() World.player():countAllMoney(out) end)
    if ok and type(out.allMoneyCount) == "number" then return out.allMoneyCount end
    return 0
end

-- Into the pockets; what does not fit goes to the bank account.
local function pay(amount)
    if amount <= 0 then return end
    local before = cash()
    pcall(function() World.player():addMoney(amount, true, {}) end)
    local missing = amount - (cash() - before)
    if missing > 0 then
        if Hud.bankTransfer(true, missing, "Junk", "EAST OLDTOWN") then
            Hud.toast(string.format("$%d went to your bank account: your pockets are full", missing), 4)
        else
            log("Junk: could not pay out $%d", missing)
        end
    end
end

-- Takes up to `n` of the kind out of an inventory. Returns how many really went.
local function takeOut(actor, kind, n)
    local inv = actor.InventoryComponent
    local gone = 0
    for _, id in ipairs(kind.ids) do
        local guard = 0
        while gone < n and guard < 40 do
            guard = guard + 1
            local before = contents(actor)[id] or 0
            if before <= 0 then break end
            pcall(function() inv:RemoveItemOfType(FName(id), math.min(before, n - gone)) end)
            local after = contents(actor)[id] or 0
            if after >= before then break end
            gone = gone + (before - after)
        end
    end
    return gone
end

---------------------------------------------------------------- the man, his table and his box

local fig = nil          -- { owner, p, desk, box, boxKey, dialogue }
local talking = 0
local opened = false     -- his box is open in the inventory screen

local function clear()
    if fig and not World.gone then
        if fig.p then pcall(Avatar.destroyStandIn, fig.p) end
        for _, a in ipairs({ fig.desk, fig.box, fig.dialogue, fig.lamp, fig.light }) do
            pcall(function() if valid(a) then a:K2_DestroyActor() end end)
        end
        for _, a in ipairs(fig.panels or {}) do
            pcall(function() if valid(a) then a:K2_DestroyActor() end end)
        end
    end
    fig, opened = nil, false
end

-- The dialogue: the furniture shopkeeper's lines with other words (see coop/edwin.lua).
local function dialogueText()
    local template = nil
    for _, d in ipairs(Core.actors("/Game/Interactive/dialogueInstance.dialogueInstance_C") or {}) do
        if not template and Core.alive(d) then
            local v = Repl.export(d, { "dialogueLines" }).dialogueLines
            if type(v) == "string" and v:find('"Show me your products"', 1, true) and v:find('"How can I help you?"', 1, true) then template = v end
        end
    end
    if not template then return nil end
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
    local t = swap(template, '"How can I help you?"', '"Got any junk for me? Bottles, spray cans, a watch... I buy it."')
    local a, b = t:find('ResponseText_2_3DC4585B4FB4F1C79DACFAA7F3A5BBD7="Show me your products"', 1, true)
    if not a then return nil end
    local close = t:find(")", b, true)
    local changed = t:sub(a, close)
    changed = swap(changed, '"Show me your products"', '"Let\'s see what I have"')
    changed = changed:gsub("(ExitsDialogue_8_%x+=)%a+", "%1True", 1)
    changed = changed:gsub("(EntersSale_10_%x+=)%a+", "%1False", 1)
    changed = changed:gsub('(questEventName_14_%x+=)"[^"]*"', '%1"DialogueLoaded"', 1)
    changed = changed:gsub("(LocalFunction_19_%x+=)%a+", "%1True", 1)
    t = t:sub(1, a - 1) .. changed .. t:sub(close + 1)
    return swap(t, '"Just passing, sorry"', '"Not today"')
end

local function near(player, range)
    local l = player:K2_GetActorLocation()
    return (l.X - MIDDLE.x) ^ 2 + (l.Y - MIDDLE.y) ^ 2 < range * range
end

local function makeBox(world)
    local class = StaticFindObject(BOX_CLASS)
    if not valid(class) then return nil end
    local box = world:SpawnActor(class, { X = MIDDLE.x, Y = MIDDLE.y, Z = MIDDLE.top + 5 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(box) then return nil end
    -- ours alone: never written into a save, never compared with the other games
    pcall(function() if valid(box.RamaSave) then box.RamaSave:K2_DestroyComponent(box) end end)
    pcall(function() box:SetActorHiddenInGame(true) end)
    pcall(function() box:SetActorEnableCollision(false) end)
    pcall(function() box.objName = FText(Junk.NAME) end)
    pcall(function()
        box.InventoryComponent.ContainerWidth = BOX_SIZE.w
        box.InventoryComponent.ContainerHeight = BOX_SIZE.h
    end)
    pcall(function()
        local list = box.AcceptedCategories
        for i, c in ipairs(ACCEPTED) do list[i] = c end
    end)
    fig.boxKey = Repl.key(box)
    Sync.setPrivate(fig.boxKey, true)
    return box
end

local function showMan(world)
    fig.p = Avatar.buildStandIn(LOOK, SPOT.x, SPOT.y, STAND, SPOT.yaw, nil, "calm")
    pcall(function()
        local text = dialogueText()
        local class = StaticFindObject("/Game/Interactive/dialogueInstance.dialogueInstance_C")
        if not text or not valid(class) then return end
        local d = world:SpawnActor(class, { X = SPOT.x, Y = SPOT.y, Z = STAND }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(d) then return end
        pcall(function() if valid(d.RamaSave) then d.RamaSave:K2_DestroyComponent(d) end end)
        if Repl.importRaw(d, "dialogueLines", text) then fig.dialogue = d end
    end)
    pcall(function() fig.light.LightComponent:SetVisibility(true, false) end)
    log("Junk: the trash man is at his table (dialogue %s)", tostring(fig.dialogue ~= nil))
end

local function hideMan()
    if fig.p then pcall(Avatar.destroyStandIn, fig.p) end
    pcall(function() if valid(fig.dialogue) then fig.dialogue:K2_DestroyActor() end end)
    fig.p, fig.dialogue = nil, nil
    pcall(function() fig.light.LightComponent:SetVisibility(false, false) end)
end

local leaveFor = nil     -- (defined with the box: hands back what is in it and closes the screen)

local function ensure()
    local player = World.player()
    if not player then return end
    if fig and (fig.owner ~= player:GetAddress() or (not fig.failed and not valid(fig.desk))) then
        if fig.owner == player:GetAddress() then clear() else fig, opened = nil, false end
    end
    if not active() then
        if fig then clear() end
        return
    end
    local world = player:GetWorld()
    if not fig then
        if not near(player, BUILD_RANGE) then return end
        fig = { owner = player:GetAddress() }
        local ok, e = pcall(function()
            local a = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = DESK.x, Y = DESK.y, Z = DESK.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
            a:SetMobility(2)
            a.StaticMeshComponent:SetStaticMesh(Avatar.asset(DESK.mesh))
            -- (SpawnActor leaves the rotation out)
            a:K2_SetActorLocationAndRotation({ X = DESK.x, Y = DESK.y, Z = DESK.z }, { Pitch = 0, Yaw = DESK.yaw, Roll = 0 }, false, {}, true)
            a:SetActorScale3D({ X = DESK.scale, Y = DESK.scale, Z = DESK.scale })
            fig.desk = a
            fig.box = makeBox(world)
        end)
        local okP, panels = pcall(NoTag.panels, world, ROOM, DOORS)
        fig.panels = okP and panels or {}
        pcall(function()
            local lamp = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = LAMP.x, Y = LAMP.y, Z = LAMP.z }, { Pitch = 0, Yaw = 0, Roll = 0 })
            lamp:SetMobility(2)
            lamp.StaticMeshComponent:SetStaticMesh(Avatar.asset(LAMP.mesh))
            lamp:K2_SetActorLocationAndRotation({ X = LAMP.x, Y = LAMP.y, Z = LAMP.z }, { Pitch = 0, Yaw = LAMP.yaw, Roll = 0 }, false, {}, true)
            lamp:SetActorEnableCollision(false)
            fig.lamp = lamp
            -- the light just under the shade
            local o, e = {}, {}
            lamp:GetActorBounds(false, o, e)
            local z = (tonumber(o.Z) or LAMP.z) - (tonumber(e.Z) or 0) - 6
            local l = world:SpawnActor(StaticFindObject("/Script/Engine.PointLight"), { X = o.X or LAMP.x, Y = o.Y or LAMP.y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
            local c = l.LightComponent
            c:SetMobility(2)
            pcall(function() c.SpecularScale = 0.3 end)
            c:SetIntensity(LIGHT.intensity)
            c:SetAttenuationRadius(LIGHT.radius)
            c:SetLightColor(LIGHT.color, true)
            c:SetCastShadows(false)
            c:SetVisibility(false, false)
            fig.light = l
        end)
        if not ok or not valid(fig.desk) then
            log("Junk: his table could not be put up: %s", tostring(e))
            fig.failed = true
            return
        end
    end
    if fig.failed then return end
    local work = atWork()
    if work and not fig.p then
        local ok, e = pcall(showMan, world)
        if not ok then log("Junk: %s", tostring(e)) end
    elseif not work and fig.p then
        if leaveFor then pcall(leaveFor, player) end
        hideMan()
        log("Junk: the trash man has gone (police hours)")
    end
end

---------------------------------------------------------------- his box in the inventory screen

-- Opens the game's inventory screen with his box beside the pockets.
function Junk.show()
    local player = World.player()
    if not player or not active() or not fig or not fig.p or not valid(fig.box) then return false end
    local ok, e = pcall(function()
        player.curContainer = fig.box
        player:openInventory()
    end)
    if not ok then
        log("Junk: his box could not be opened: %s", tostring(e))
        return false
    end
    opened = true
    return true
end

local function boxIsOpen(player)
    local yes = false
    pcall(function()
        yes = player.inventoryOpen == true and fig ~= nil and valid(fig.box) and player.curContainer:GetAddress() == fig.box:GetAddress()
    end)
    return yes
end

-- The rows of an inventory: { { id, n, amount, guid } }.
local function guidOf(text)
    local g = {}
    for k, v in tostring(text):gmatch("(%a)=(%-?%d+)") do g[k] = tonumber(v) end
    if not (g.A and g.B and g.C and g.D) then return nil end
    return { A = g.A, B = g.B, C = g.C, D = g.D }
end

local function rows(actor)
    local v = Repl.export(actor, { "InventoryComponent.ItemNames", "InventoryComponent.ItemQuantities", "InventoryComponent.ItemCurAmount",
        "InventoryComponent.ItemLocalGuids" })
    local names = Repl.splitArray(v["InventoryComponent.ItemNames"] or "()")
    local counts = Repl.splitArray(v["InventoryComponent.ItemQuantities"] or "()")
    local amounts = Repl.splitArray(v["InventoryComponent.ItemCurAmount"] or "()")
    local guids = Repl.splitArray(v["InventoryComponent.ItemLocalGuids"] or "()")
    local out = {}
    for i, name in ipairs(names) do
        local id = tostring(name):gsub('"', "")
        out[#out + 1] = { id = id, n = tonumber(counts[i]) or 0, amount = tonumber(amounts[i]) or 0, guid = guidOf(guids[i]) }
    end
    return out
end

local function redraw(player)
    pcall(function()
        local w = player.InventoryWidget
        w:renderContainer(fig.box)
        w:RefreshInventory()
    end)
end

-- Hands back what is in his box, with the game's own call that a shop's CLEAR uses (it
-- also puts a thing onto a stack of its kind). Its answer says how much went in; what does
-- not fit stays in the box. (Holding the inventory's updates meanwhile, as the shop does,
-- made every thing after the first go nowhere.) Returns the number handed back and kept.
local NO_MIX = { SubstanceForm_10_C925520C4AB9EFE7114FA789E8C6ED6A = 0, Humidity_13_89BE6EF14389F8190C5A7FA273040A2B = 0.0,
    SubstanceName_16_B4DFC395423C963522E86AA3E95B2CFB = FText("") }
local function giveBack(player)
    if not fig or not valid(fig.box) then return 0, 0 end
    local inv = player.InventoryComponent
    local back, kept = 0, 0
    for _, r in ipairs(rows(fig.box)) do
        local left, why = r.n, "no answer"
        local ok, e = pcall(function()
            local added, rest, guid = {}, {}, {}
            inv:AddItem(FName(r.id), FText(""), r.n, r.amount, NO_MIX, { A = 0, B = 0, C = 0, D = 0 }, true, false, -1, false, false, added, rest, guid)
            left = tonumber(rest.QuantityLeft) or r.n
            why = string.format("all added %s, left %s", tostring(added.AllAdded), tostring(rest.QuantityLeft))
        end)
        if not ok then why = tostring(e) end
        local got = math.max(0, r.n - left)
        if got < r.n then log("Junk: %s x%d (amount %d) did not go back into the pockets: %s", r.id, r.n - got, r.amount, why) end
        if got > 0 and r.guid then pcall(function() fig.box.InventoryComponent:RemoveItem(r.guid, got) end) end
        back, kept = back + got, kept + (r.n - got)
    end
    pcall(function() inv:DispatchUpdate() end)
    pcall(function() player:refreshBackpackData() end)
    return back, kept
end

local function keptNote(kept)
    if kept > 0 then Hud.toast(string.format("%d thing(s) did not fit in your pockets and are still in his box", kept), 5) end
end

-- ACCEPT: he buys what is in his box; what he does not buy goes back to the player.
local function accept(player)
    local deal = offer(contents(fig.box))
    local sold, paid = 0, 0
    for _, d in ipairs(deal) do
        local gone = takeOut(fig.box, d.kind, d.n)
        sold, paid = sold + gone, paid + gone * d.kind.price
    end
    if paid > 0 then pay(paid) end
    if sold > 0 then log("Junk: bought %d thing(s) for $%d", sold, paid) end
    local _, kept = giveBack(player)
    keptNote(kept)
    redraw(player)
end

local function clearBox(player)
    local _, kept = giveBack(player)
    keptNote(kept)
    redraw(player)
end

---------------------------------------------------------------- the shop's panel under his box

-- Under the box, in place of its weight: ITEMS VALUE, YOUR MONEY and ACCEPT / CLEAR /
-- CANCEL, made like the game's own trade panel (its fonts, colours, button style and
-- spacing, copied from its widgets in the same screen). They are copies: the game's own
-- buttons run its trade.
local panel = nil        -- { screen, weightRow, parts = {}, value, money, buttons = {} }

local function copyText(tree, model, str)
    local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree)
    t:SetFont(model.Font)
    t:SetColorAndOpacity(model.ColorAndOpacity)
    t:SetText(FText(str))
    return t
end

local function copySlot(slot, model)
    pcall(function() slot:SetPadding(model.Slot.Padding) end)
    pcall(function() slot:SetVerticalAlignment(model.Slot.VerticalAlignment) end)
    pcall(function() slot:SetHorizontalAlignment(model.Slot.HorizontalAlignment) end)
end

local function buildPanel(w)
    local tree = w.WidgetTree
    local HBOX = StaticFindObject("/Script/UMG.HorizontalBox")
    local weightRow = w.txtContainerWeight:GetParent()
    local column = weightRow:GetParent()
    local p = { screen = w:GetAddress(), weightRow = weightRow, parts = {}, buttons = {} }
    local function line(valueModel)
        local rowModel = valueModel:GetParent()
        local labelModel = rowModel:GetChildAt(0)
        local h = StaticConstructObject(HBOX, tree)
        copySlot(h:AddChildToHorizontalBox(copyText(tree, labelModel, labelModel:GetText():ToString())), labelModel)
        local v = copyText(tree, valueModel, "")
        copySlot(h:AddChildToHorizontalBox(v), valueModel)
        copySlot(column:AddChildToVerticalBox(h), rowModel)
        p.parts[#p.parts + 1] = h
        return v
    end
    p.value = line(w.txtItemsValue)
    -- (the shop's value is green: the game colours it when it shows the shop; left alone it
    -- is the widget's own red)
    pcall(function() p.value:SetColorAndOpacity({ SpecifiedColor = { R = 0.2, G = 0.6, B = 0.2, A = 1 }, ColorUseRule = 0 }) end)
    p.money = line(w.txtWalletValue)
    local row = StaticConstructObject(HBOX, tree)
    for _, it in ipairs({ { w.btnAcceptTrade, "accept" }, { w.btnClearTrade, "clear" }, { w.btnCancelTrade, "cancel" } }) do
        local model = it[1]
        local b = StaticConstructObject(StaticFindObject("/Script/UMG.Button"), tree)
        b:SetStyle(model.WidgetStyle)
        b:SetBackgroundColor(model.BackgroundColor)
        local modelText = model:GetChildAt(0)
        copySlot(b:AddChild(copyText(tree, modelText, modelText:GetText():ToString())), modelText)
        copySlot(row:AddChildToHorizontalBox(b), model)
        p.buttons[#p.buttons + 1] = { widget = b, what = it[2] }
    end
    copySlot(column:AddChildToVerticalBox(row), w.btnAcceptTrade:GetParent())
    p.parts[#p.parts + 1] = row
    return p
end

local COLLAPSED, SHOWN = 1, 0
local function showPanel(on)
    if not panel then return end
    for _, part in ipairs(panel.parts) do pcall(function() part:SetVisibility(on and SHOWN or COLLAPSED) end) end
    pcall(function() panel.weightRow:SetVisibility(on and COLLAPSED or SHOWN) end)
end

local function money(n)
    local t = tostring(math.floor(n))
    local out = t:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return "$ " .. out:gsub("^,", "")
end

local shown = nil        -- the texts last put in
local function tendPanel(player)
    local w = player.InventoryWidget
    if not panel or panel.screen ~= w:GetAddress() then
        local ok, made = pcall(buildPanel, w)
        if not ok then
            log("Junk: the panel could not be made: %s", tostring(made))
            return
        end
        panel, shown = made, nil
    end
    showPanel(true)
    local _, worth = offer(contents(fig.box))
    local title, value, wallet = Junk.NAME:upper(), money(worth), money(cash())
    local now = nil
    pcall(function() now = w.txtContainerName:GetText():ToString() end)
    if shown and shown.value == value and shown.wallet == wallet and now == title then return end
    shown = { value = value, wallet = wallet }
    pcall(function() w.txtContainerName:SetText(FText(title)) end)
    pcall(function() panel.value:SetText(FText(value)) end)
    pcall(function() panel.money:SetText(FText(wallet)) end)
    for _, b in ipairs(panel.buttons) do
        if b.what == "accept" then pcall(function() b.widget:SetIsEnabled(worth > 0) end) end
    end
end

local function pollButtons(player)
    if not panel then return end
    for _, b in ipairs(panel.buttons) do
        local hovered, pressed = false, false
        pcall(function() hovered, pressed = b.widget:IsHovered(), b.widget:IsPressed() end)
        local clicked = b.pressed and not pressed and hovered
        b.pressed = pressed
        if clicked then
            if b.what == "accept" then
                accept(player)
            elseif b.what == "clear" then
                clearBox(player)
            else
                pcall(function() player:closeInventory() end)
            end
            shown = nil
            return
        end
    end
end

-- The screen was closed (CANCEL, Tab, Escape): what is in his box goes back, as with a
-- shop's counter.
local function closed(player)
    opened, shown = false, nil
    showPanel(false)
    if not fig or not valid(fig.box) then return end
    local _, kept = giveBack(player)
    keptNote(kept)
end

-- He goes home: an open screen of his is closed first, and his box handed back.
leaveFor = function(player)
    if opened and boxIsOpen(player) then pcall(function() player:closeInventory() end) end
    if opened then closed(player) end
end

-- (for test scripts)
Junk.accept, Junk.clearBox, Junk.giveBack, Junk.rows = accept, clearBox, giveBack, rows
function Junk.panel() return panel end

Core.onTick(function()
    if not live() or not opened then return end
    local player = World.player()
    if not player then
        opened = false
        return
    end
    if boxIsOpen(player) then
        local ok, e = pcall(tendPanel, player)
        if not ok then log("Junk: %s", tostring(e)) end
        ok, e = pcall(pollButtons, player)
        if not ok then log("Junk: %s", tostring(e)) end
    else
        local ok, e = pcall(closed, player)
        if not ok then log("Junk: %s", tostring(e)) end
    end
end)

-- Starts the talk with him. Returns false when it cannot (the box is opened directly then).
function Junk.talk()
    local player = World.player()
    if not player or not fig or not valid(fig.dialogue) then return false end
    local ok, e = pcall(function()
        talking = os.clock()
        player:startDialogue(fig.dialogue)
        player.focusCamera = false
        player.dialogueWidget.txtTalkerName:SetText(FText(Junk.NAME))
    end)
    if not ok then log("Junk: dialogue failed: %s", tostring(e)) end
    return ok
end

Core.Hooks.add("/Game/Interactive/dialogueInstance.dialogueInstance_C:DialogueLoaded", function(ctx)
    if not live() or not fig or not fig.dialogue or os.clock() - talking > 600 then return end
    local ok, mine = pcall(function() return ctx:get():GetAddress() == fig.dialogue:GetAddress() end)
    if not ok or not mine then return end
    talking = 0
    -- (once the dialogue screen has gone)
    Core.after(0.4, function()
        if live() then pcall(Junk.show) end
    end)
end)

---------------------------------------------------------------- at the table

local function turnedFrom(player, l, x, y)
    local at = nil
    pcall(function() at = player:GetController():GetControlRotation().Yaw end)
    if not at then return 0 end
    return math.abs(((math.deg(math.atan(y - l.Y, x - l.X)) - at + 180) % 360) - 180)
end

-- At the table, turned his way; not while a talk is on or a screen is open.
local function nearHim()
    local player = World.player()
    if not player or not active() or not fig or not fig.p then return false end
    local busy = false
    pcall(function() busy = player.inDialogue == true or player.inventoryOpen == true end)
    if busy then return false end
    local l = player:K2_GetActorLocation()
    if math.abs(l.Z - STAND) > 130 then return false end
    -- (inside the house: between the front wall and the back of the room)
    if l.X < 2880 or l.X > 3600 then return false end
    local d = (l.X - MIDDLE.x) ^ 2 + (l.Y - MIDDLE.y) ^ 2
    if d > 300 * 300 then return false end
    return d < 140 * 140 or turnedFrom(player, l, SPOT.x, SPOT.y) < 60
end
Junk.near = nearHim

local UNDER = rawget(_G, "DDSMP_JUNK_UNDER") or Look.takeover
_G.DDSMP_JUNK_UNDER = UNDER
Junk.takeover = {
    isOpen = function() return UNDER.isOpen() end,
    near = function() return (live() and not UNDER.isOpen() and nearHim()) or UNDER.near() end,
    prompt = function()
        if live() and nearHim() then return key("WardrobeKey"), "Talk" end
        return UNDER.prompt()
    end,
    toggle = function()
        if live() and not UNDER.isOpen() and nearHim() then
            if not Junk.talk() then Junk.show() end
        else
            UNDER.toggle()
        end
    end,
    move = function() end,
    choose = function() end,
}
Look.takeover = Junk.takeover

---------------------------------------------------------------- keeping it all in order

-- The flicker: the light drifts between 85 and 100 per cent, and now and then dips for a
-- moment to a quarter or a half.
local flick = { left = 0, level = 1, target = 1 }
Core.onTick(function(dt)
    if not live() or not fig or not fig.p or not fig.light then return end
    dt = tonumber(dt) or 0.016
    flick.left = flick.left - dt
    if flick.left <= 0 then
        if math.random() < 0.12 then
            flick.target, flick.left = 0.25 + math.random() * 0.25, 0.03 + math.random() * 0.1
        else
            flick.target, flick.left = 0.85 + math.random() * 0.15, 0.08 + math.random() * 0.3
        end
    end
    flick.level = flick.level + (flick.target - flick.level) * math.min(1, dt * 30)
    pcall(function() fig.light.LightComponent:SetIntensity(LIGHT.intensity * flick.level) end)
end)

-- On the map: "Recycler", once per world (the marker is never saved: coop/hud.lua).
local marker = nil
Core.every(1, function()
    if not live() then return end
    ensure()
    if active() and Hud.ready() and (not marker or not Core.alive(marker)) then
        marker = Hud.mapMarker("Recycler", "Bottles, cans, valuables. Open only during the day", MIDDLE.x, MIDDLE.y, FLOOR, Hud.MARKER_SHOP)
    elseif not active() and marker then
        pcall(Hud.forgetMarker, marker)
        marker = nil
    end
end)

World.listen("loading", function()
    if not live() then return end
    clear()
end)

function Junk.shutdown()
    clear()
    if marker then pcall(Hud.forgetMarker, marker) marker = nil end
    if Look.takeover == Junk.takeover then Look.takeover = UNDER end
end

Junk.state = function() return fig end
Junk.offer, Junk.contents = offer, contents
return Junk
