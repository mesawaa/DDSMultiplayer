-- The task list at the left of the screen, sorted (EXPERIMENTAL: DeliveryList).
--
-- The game's list (it slides in when a task is new, while Tab is held, with the phone up
-- and at a work station) shows the open tasks in the order they came, twelve at most. With
-- this on, a key (config DeliveryListKey, "O") goes through four lists; a line just above
-- the list says for a moment which one it is now:
--
--   Chronological        the game's list as it is
--   Deliveries by drug   the deliveries first, drug by drug, the largest first (what has to
--                        be packed); then the other tasks, the storyline's, in a group of
--                        their own
--   Deliveries by area   the deliveries part of town by part of town; then the other tasks
--                        in a group of their own
--   All tasks            as by area, and a task that has a place on the map stands with
--                        the deliveries of the part of town it is in, below them; tasks
--                        without a place come last
--
-- Held for half a second the key hides, or shows again, the deliveries the other players
-- have marked as theirs (coop/marks.lua), in every one of the lists.
--
-- Nothing is left out and nothing is written differently: every row is the game's own
-- entry with the words the game gave that task. Only the order changes, with a little room
-- between two groups. (All open tasks are there, also past the game's twelve.)
--
-- A delivery is an order of the sales manager's (the host's runs them; every game has its
-- lists): accepted, not closed, its task neither done nor failed. A dealer who already has
-- his product is waiting to hand over cash: that comes last among the deliveries. A client
-- somebody has marked (coop/marks.lua) has the square of the row filled with that player's
-- colour.
--
-- The game's own rows are not thrown away while the list shows ours (an entry of a
-- finished task tidies its task up a moment after it is made, and must be left to): a row
-- of a task that is done or failed, and a row for a package on its way, stay where they
-- are; the others wait in a box beside the list that is never drawn.

local Core = require("core")
local World = require("coop.world")
local Repl = require("coop.repl")
local Colours = require("coop.colours")

local log, valid = Core.log, Core.valid
local config = Core.config

local GEN = (rawget(_G, "DDSMP_ORDERS_GEN") or 0) + 1
_G.DDSMP_ORDERS_GEN = GEN
local function live() return rawget(_G, "DDSMP_ORDERS_GEN") == GEN end

local Orders = {}

local HUD_CLASS = "/Game/Player/playerHUD.playerHUD_C"
local ENTRY = "/Game/GUI/miniTaskListItem.miniTaskListItem_C"
local NAME = "Name_16_FF9AED99407FDA5CC81F3A92D99C45A8"
local DRUG = "DrugName_2_D42CFE1B49201DD5F14A7B92ED1D9E5F"
local WHITE = "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"
local MARKER = "/Game/GUI/WorldMap/worldMapMarker.worldMapMarker_C"
local SALE_AREA = "/Game/Interactive/DrugSale/DrugSaleArea.DrugSaleArea_C"
local COLLAPSED = 1

Orders.MODES = { "all", "drug", "area", "areaq" }
Orders.TITLES = { all = "Chronological", drug = "Deliveries by drug", area = "Deliveries by area", areaq = "All tasks" }
Orders.HOLD = 0.5          -- seconds the key is held to hide or show what the others have marked
Orders.MAX_ROWS = 26       -- rows of ours on the list at most
Orders.GAP = 9             -- between two drugs, or two parts of town
Orders.LABEL_GAP = 6       -- between the line that names the list and the list's top
Orders.LABEL_SECONDS = 3

local function on() return Core.experimental("DeliveryList") end

---------------------------------------------------------------- the orders

local function count(arr)
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    return ok and type(n) == "number" and n or 0
end

-- id of a part of town -> the name the game shows for it
local areaNames, areaNamesAt = {}, -100
local function areaName(id)
    if os.clock() - areaNamesAt > 30 then
        areaNamesAt = os.clock()
        pcall(function()
            local m = Core.find("saleAreaManager_C")
            local names = {}
            for i = 1, count(m.saleAreaStrings) do
                names[m.saleAreaStrings[i]:ToString()] = m.saleAreaDisplayName[i]:ToString()
            end
            if next(names) then areaNames = names end
        end)
    end
    return areaNames[id] or id
end

-- The clients as the sales manager has them: { [client number, from 0] = { ... } }, with
-- the client's newest order when it is still to be answered or delivered:
--   name, area (id), areaName, dealer,
--   order (number, from 0), accepted, grams, drug, cash (a dealer's cash to fetch), task,
--   text (the words the game gave the order's task)
local clientsCache, clientsAt, clientsFor = nil, -100, nil

function Orders.clients()
    local player = World.player()
    if not player then return {} end
    local key = player:GetAddress()
    if clientsCache and clientsFor == key and os.clock() - clientsAt < 0.9 then return clientsCache end
    local out = {}
    local ok, e = pcall(function()
        local sm, cm, qm = Core.find("salesManager_C"), Core.find("contactsManager_C"), Core.find("questManager_C")
        if not valid(sm) or not valid(cm) or not valid(qm) then return end
        local nClients = count(sm.clientsAvailable)
        local nOrders = math.min(count(sm.orderListAccepted), count(sm.orderListClosed), count(sm.orderListClientID), count(sm.orderListDrugQuantity),
            count(sm.orderListTaskID), count(sm.orderListDrugOrdered))
        local nNewest, nAreas, nDealer, nDope, nWaiting = count(sm.clientsNewestOrderID), count(sm.clientsAssignedArea), count(sm.clientIsDealer),
            count(sm.clientDealerTookDope), count(sm.clientAwaitingResponse)
        local nContacts = count(cm.characterList)
        local nTasks = math.min(count(qm.taskCompleted), count(qm.taskFailed), count(qm.taskDecriptions))
        for i = 1, nClients do
            local c = { contact = sm.clientsAvailable[i] }
            local lost = false
            pcall(function() lost = i <= count(sm.clientsLost) and sm.clientsLost[i] == true end)
            if not lost and c.contact >= 0 and c.contact < nContacts then
                c.name = cm.characterList[c.contact + 1][NAME]:ToString()
                c.area = i <= nAreas and sm.clientsAssignedArea[i]:ToString() or ""
                c.areaName = areaName(c.area)
                c.dealer = i <= nDealer and sm.clientIsDealer[i] == true
                local o = i <= nNewest and sm.clientsNewestOrderID[i] or -1
                -- (the order has to be this client's: a client who has never ordered has a number that is not)
                if o >= 0 and o < nOrders and sm.orderListClientID[o + 1] == i - 1 and sm.orderListClosed[o + 1] ~= true then
                    local accepted = sm.orderListAccepted[o + 1] == true
                    local task = sm.orderListTaskID[o + 1]
                    local open = false
                    if accepted then
                        open = task >= 0 and task < nTasks and qm.taskCompleted[task + 1] ~= true and qm.taskFailed[task + 1] ~= true
                    else
                        open = i <= nWaiting and sm.clientAwaitingResponse[i] == true
                    end
                    if open then
                        c.order, c.accepted, c.task = o, accepted, task
                        c.grams = sm.orderListDrugQuantity[o + 1]
                        c.drug = sm.orderListDrugOrdered[o + 1][DRUG]:ToString()
                        c.cash = c.dealer and i <= nDope and sm.clientDealerTookDope[i] == true
                        if accepted then c.text = qm.taskDecriptions[task + 1]:ToString() end
                    end
                end
                out[i - 1] = c
            end
        end
    end)
    if not ok then
        Core.vlog("Orders: the clients: %s", tostring(e))
        return clientsCache and clientsFor == key and clientsCache or {}
    end
    clientsCache, clientsAt, clientsFor = out, os.clock(), key
    return out
end

-- The client with that contact number (the number Shady Comm knows a contact by): the
-- client's number and the entry of Orders.clients(), or nil.
-- (after something that changes the orders: the next look reads them anew)
function Orders.forget() clientsAt = -100 end

function Orders.clientOfContact(contact)
    for id, c in pairs(Orders.clients()) do
        if c.contact == contact then return id, c end
    end
    return nil, nil
end

-- True for a client another player has marked (coop/marks.lua).
local function theirs(client)
    local Marks = package.loaded["coop.marks"]
    return type(Marks) == "table" and Marks.byOther ~= nil and Marks.byOther(client) == true
end

-- Whether the deliveries the other players have marked are left off the list (holding the
-- key switches it).
function Orders.hiding() return on() and Colours.pref("hideOthers") == true end

-- The tasks of those deliveries: { [task number] = true }.
local function hiddenTasks()
    local out = {}
    if not Orders.hiding() then return out end
    for id, c in pairs(Orders.clients()) do
        if c.order and c.accepted and theirs(id) then out[c.task] = true end
    end
    return out
end

-- The orders to deliver: accepted and open, sorted for a list. Each is the client's entry
-- with `client` (number) and `gap` (true: a new drug, or a new part of town, starts here).
function Orders.deliveries(mode)
    local list = {}
    local hide = Orders.hiding()
    for id, c in pairs(Orders.clients()) do
        if c.order and c.accepted and not (hide and theirs(id)) then
            c.client = id
            list[#list + 1] = c
        end
    end
    local function drugKey(c) return c.cash and "\255" or c.drug:lower() end
    table.sort(list, function(a, b)
        if mode == "area" and a.areaName ~= b.areaName then return a.areaName < b.areaName end
        local da, db = drugKey(a), drugKey(b)
        if da ~= db then return da < db end
        if a.grams ~= b.grams then return a.grams > b.grams end
        if a.name ~= b.name then return a.name < b.name end
        return a.client < b.client
    end)
    for i, c in ipairs(list) do
        local before = list[i - 1]
        if mode == "area" then
            c.gap = before ~= nil and before.areaName ~= c.areaName
        else
            c.gap = before ~= nil and drugKey(before) ~= drugKey(c)
        end
    end
    return list
end

-- The words of a row: the game's own for that task.
function Orders.rowText(c) return c.text or "" end

---------------------------------------------------------------- the other tasks

local function bools(text)
    local t = {}
    for w in tostring(text or ""):gmatch("%a+") do t[#t + 1] = (w == "True") end
    return t
end

-- The task table's marks, each as a list from 1: displayed (the list has shown the task as
-- finished and is done with it), completed, failed.
local flagsCache, flagsAt, flagsFor = nil, -100, nil
local function taskFlags()
    local player = World.player()
    if not player then return nil end
    local key = player:GetAddress()
    if flagsCache and flagsFor == key and os.clock() - flagsAt < 0.9 then return flagsCache end
    local qm = Core.find("questManager_C")
    if not valid(qm) then return nil end
    local ok, e = pcall(Repl.export, qm, { "taskDisplayed", "taskCompleted", "taskFailed" })
    if not ok or type(e) ~= "table" then return nil end
    flagsCache = { displayed = bools(e.taskDisplayed), completed = bools(e.taskCompleted), failed = bools(e.taskFailed) }
    flagsAt, flagsFor = os.clock(), key
    return flagsCache
end

-- The open tasks that are no delivery, in the order they came: { task (number, from 0),
-- text, special (the game draws such a row with its parcel) }.
function Orders.quests()
    local out = {}
    pcall(function()
        local f = taskFlags()
        local qm = Core.find("questManager_C")
        if not f or not valid(qm) then return end
        local taken = {}
        for _, c in pairs(Orders.clients()) do
            if c.order and c.accepted then taken[c.task] = true end
        end
        local nSpecial = count(qm.taskSpecial)
        for i = 1, math.min(#f.displayed, #f.completed, #f.failed, count(qm.taskDecriptions)) do
            if not f.displayed[i] and not f.completed[i] and not f.failed[i] and not taken[i - 1] then
                out[#out + 1] = { task = i - 1, text = qm.taskDecriptions[i]:ToString(), special = i <= nSpecial and qm.taskSpecial[i] == true }
            end
        end
    end)
    return out
end

-- The parts of town have no borders, only selling spots: a place is in the part whose spot
-- is nearest.
local spots, spotsFor = nil, nil
local function areaAt(x, y)
    local player = World.player()
    if not player then return nil end
    local key = player:GetAddress()
    if spotsFor ~= key or not spots or #spots == 0 then
        spots, spotsFor = {}, key
        for _, area in ipairs(Core.actors(SALE_AREA) or {}) do
            pcall(function()
                local id = area.AreaID:ToString()
                area.salePoints:ForEach(function(_, v)
                    local spot = v:get()
                    if valid(spot) then
                        local l = spot:K2_GetActorLocation()
                        spots[#spots + 1] = { x = l.X, y = l.Y, id = id }
                    end
                end)
            end)
        end
    end
    local best, least = nil, math.huge
    for _, sp in ipairs(spots) do
        local d = (sp.x - x) ^ 2 + (sp.y - y) ^ 2
        if d < least then best, least = sp.id, d end
    end
    return best
end

-- task number -> the name of the part of town its marker on the map stands in
local function questAreas()
    local out = {}
    for _, a in ipairs(Core.actors(MARKER) or {}) do
        pcall(function()
            if a.taskRelated ~= true then return end
            local l = a:K2_GetActorLocation()
            local id = areaAt(l.X, l.Y)
            if id then out[a.relatedTaskID] = areaName(id) end
        end)
    end
    return out
end

-- The rows of a sorted list, top to bottom: { text, gap (room above), client (a delivery:
-- the client's number), special }.
function Orders.rows(mode)
    local out = {}
    local function put(item, gap)
        item.gap = gap == true and #out > 0
        out[#out + 1] = item
    end
    local deliveries = Orders.deliveries(mode == "areaq" and "area" or mode)
    local quests = Orders.quests()
    if mode == "areaq" then
        local where = questAreas()
        local groups, names, rest = {}, {}, {}
        local function group(name)
            if not groups[name] then
                groups[name] = { d = {}, q = {} }
                names[#names + 1] = name
            end
            return groups[name]
        end
        for _, c in ipairs(deliveries) do
            local g = group(c.areaName)
            g.d[#g.d + 1] = c
        end
        for _, q in ipairs(quests) do
            local name = where[q.task]
            if name then
                local g = group(name)
                g.q[#g.q + 1] = q
            else
                rest[#rest + 1] = q
            end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local first = true
            for _, c in ipairs(groups[name].d) do
                put({ text = c.text or "", client = c.client }, first)
                first = false
            end
            for _, q in ipairs(groups[name].q) do
                put({ text = q.text, special = q.special }, first)
                first = false
            end
        end
        for i, q in ipairs(rest) do put({ text = q.text, special = q.special }, i == 1) end
    else
        for _, c in ipairs(deliveries) do put({ text = c.text or "", client = c.client }, c.gap) end
        for i, q in ipairs(quests) do put({ text = q.text, special = q.special }, i == 1) end
    end
    return out
end

---------------------------------------------------------------- which list

function Orders.mode()
    if not on() then return "all" end
    local m = Colours.pref("list")
    for _, known in ipairs(Orders.MODES) do if m == known then return m end end
    return "drug"
end

local shown = nil          -- what our rows on the HUD were made from: { hud, mode, sig, rows }

local function signature(mode, rows)
    local Marks = package.loaded["coop.marks"]
    local parts = { mode }
    if mode == "all" then
        -- (the game's list: only what is left off it is ours)
        local off = {}
        for task in pairs(hiddenTasks()) do off[#off + 1] = task end
        table.sort(off)
        return mode .. ";" .. table.concat(off, ",")
    end
    for _, r in ipairs(rows) do
        local colour = ""
        if r.client and type(Marks) == "table" and Marks.hexOfClient then colour = Marks.hexOfClient(r.client) or "" end
        parts[#parts + 1] = r.text .. "/" .. tostring(r.gap) .. "/" .. colour
    end
    return table.concat(parts, ";")
end

---------------------------------------------------------------- the rows on the HUD

local function library() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end

local function entry(hud, text, special)
    local lib, class = library(), Core.class(ENTRY)
    if not valid(lib) or not valid(class) then return nil end
    local w = lib:Create(hud, class, nil)
    if not valid(w) then return nil end
    -- (never "done" or "failed": such an entry writes into the game's task table when it goes)
    w:Setup(FText(text), false, 0, false, special == true, false)
    return w
end

local function isOurs(w)
    if not shown then return false end
    local a = w:GetAddress()
    for _, r in ipairs(shown.rows) do if r == a then return true end end
    return false
end

-- Where the game's own rows wait while the list shows ours: a box of our own beside the
-- list, never drawn. (In the list they would be counted by the game's "tasks available (N)"
-- line; thrown away, an entry of a finished task could not tidy its task up.)
local holder = nil         -- { hud, box }

local function holderFor(hud, list)
    if holder and holder.hud == hud:GetAddress() and valid(holder.box) then return holder.box end
    holder = nil
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.VerticalBox"), hud.WidgetTree)
    if not valid(box) then return nil end
    local slot = list:GetParent():AddChildToCanvas(box)
    if not valid(slot) then return nil end
    box:SetVisibility(COLLAPSED)
    holder = { hud = hud:GetAddress(), box = box }
    return box
end

-- True for a row of the game's that a row of ours stands in for: an open task's, with the
-- task's words. (Not: a task shown as done or failed for the last time, a package on its way.)
local function replaced(w, flags, qm)
    local ok, yes = pcall(function()
        local task = w.TaskID
        if type(task) ~= "number" or task < 0 or task >= count(qm.taskDecriptions) then return false end
        if flags.completed[task + 1] or flags.failed[task + 1] then return false end
        return w.txtTaskNam:GetText():ToString() == qm.taskDecriptions[task + 1]:ToString()
    end)
    return ok and yes == true
end

-- Makes the list on the HUD what the mode says. `fresh`: the game has just filled it.
local function render(hud, fresh)
    local list = hud.curTaskPanel
    if not valid(list) then return end
    local mode = Orders.mode()
    -- ours of before go (the game has thrown them out itself when it filled the list)
    if shown and not fresh and shown.hud == hud:GetAddress() then
        for i = list:GetChildrenCount() - 1, 0, -1 do
            local w = list:GetChildAt(i)
            if valid(w) and isOurs(w) then list:RemoveChild(w) end
        end
    end
    shown = nil
    -- (rows of the game's from an earlier filling: it would have thrown them out itself)
    if fresh and holder and valid(holder.box) then pcall(function() holder.box:ClearChildren() end) end
    if not on() then return end
    local made, rows = {}, {}
    if mode ~= "all" then
        local flags, qm = taskFlags(), Core.find("questManager_C")
        -- (the task table cannot be read: the game's list stays as it is)
        if not flags or not valid(qm) then return end
        rows = Orders.rows(mode)
        -- the game's rows of open tasks wait beside the list
        local box = holderFor(hud, list)
        if not box then return end
        local theirs = {}
        for i = 0, list:GetChildrenCount() - 1 do theirs[#theirs + 1] = list:GetChildAt(i) end
        for _, w in ipairs(theirs) do
            if valid(w) and replaced(w, flags, qm) then box:AddChild(w) end
        end
        local Marks = package.loaded["coop.marks"]
        for i, r in ipairs(rows) do
            if i > Orders.MAX_ROWS then break end
            local w = entry(hud, r.text, r.special)
            if w then
                list:AddChild(w)
                made[#made + 1] = w:GetAddress()
                if r.gap then pcall(function() w.Slot:SetPadding({ Left = 0, Top = Orders.GAP, Right = 0, Bottom = 0 }) end) end
                -- marked: the square filled with the player's colour
                local colour = r.client and type(Marks) == "table" and Marks.colourOfClient and Marks.colourOfClient(r.client) or nil
                if colour then
                    pcall(function()
                        local white = Core.class(WHITE)
                        if white then w.checkbox:SetBrushFromTexture(white, false) end
                        w.checkbox:SetColorAndOpacity(colour)
                    end)
                end
            end
        end
    end
    if mode == "all" then
        -- the game's list as it is, less the deliveries the others have marked (when hidden)
        local off = hiddenTasks()
        local flags, qm = taskFlags(), Core.find("questManager_C")
        if next(off) and flags and valid(qm) then
            local box = holderFor(hud, list)
            if box then
                local rowsOfTheirs = {}
                for i = 0, list:GetChildrenCount() - 1 do rowsOfTheirs[#rowsOfTheirs + 1] = list:GetChildAt(i) end
                for _, w in ipairs(rowsOfTheirs) do
                    local task = nil
                    pcall(function() task = w.TaskID end)
                    if valid(w) and off[task] and replaced(w, flags, qm) then box:AddChild(w) end
                end
            end
        end
    end
    shown = { hud = hud:GetAddress(), mode = mode, sig = signature(mode, rows), rows = made }
end

Core.Hooks.add(HUD_CLASS .. ":updateMiniTaskList", function(ctx)
    if not live() or (not on() and not shown) then return end
    local ok, e = pcall(function()
        local hud = ctx:get()
        if valid(hud) then render(hud, true) end
    end)
    if not ok then log("Orders: the task list: %s", tostring(e)) end
end)

local function hudOf(player)
    local hud = nil
    pcall(function() hud = player.HUD end)
    return valid(hud) and hud or nil
end

-- Has the game fill its list again (ours follows in the hook); the list slides in for a
-- few seconds as it does when a task is new.
function Orders.refresh()
    local player = World.player()
    local hud = player and hudOf(player)
    if hud then pcall(function() hud:updateMiniTaskList() end) end
end

-- Which list it is now, said for a moment in a line just above the list (where nothing
-- of the list can cover it).
local label = nil          -- { hud, w, till }

local function announce(text)
    local player = World.player()
    local hud = player and hudOf(player)
    if not hud then return end
    local list = hud.curTaskPanel
    if not valid(list) then return end
    local w = label and label.hud == hud:GetAddress() and valid(label.w) and label.w or nil
    if not w then
        w = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), hud.WidgetTree)
        if not valid(w) then return end
        pcall(function() w:SetFont(hud.txtTaskNum.Font) end)
        pcall(function()
            w:SetShadowOffset({ X = 1, Y = 1 })
            w:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 })
        end)
        local slot = list:GetParent():AddChildToCanvas(w)
        slot:SetAutoSize(true)
        local at = list.Slot:GetPosition()
        slot:SetAlignment({ X = 0, Y = 1 })
        slot:SetPosition({ X = at.X + 5, Y = at.Y - Orders.LABEL_GAP })
    end
    w:SetText(FText(text))
    w:SetVisibility(3)
    label = { hud = hud:GetAddress(), w = w, till = os.clock() + Orders.LABEL_SECONDS }
end

-- The next list (the key: a line above the list says which it is now), or the one named.
function Orders.setMode(mode)
    if not on() then return end
    local byKey = mode == nil
    if not mode then
        local now = Orders.mode()
        for i, m in ipairs(Orders.MODES) do
            if m == now then mode = Orders.MODES[i % #Orders.MODES + 1] end
        end
    end
    Colours.setPref("list", mode)
    Orders.refresh()
    if byKey then pcall(announce, Orders.TITLES[mode]) end
end

Core.every(0.25, function()
    if not live() or not label then return end
    if os.clock() > label.till then
        pcall(function() if valid(label.w) then label.w:SetVisibility(COLLAPSED) end end)
        label = nil
    end
end)

-- The orders change without the game filling its list (another player's sale in a shared
-- world, a mark): our rows are made again as they are.
Core.every(1, function()
    if not live() then return end
    local player = World.player()
    if not player or World.joining or World.gone then
        shown = nil
        return
    end
    local hud = hudOf(player)
    if not hud then return end
    if not on() then
        if shown then pcall(Orders.refresh) end
        return
    end
    if not shown or shown.hud ~= hud:GetAddress() then
        -- (a list the game filled before this was switched on, or a new world)
        local ok, e = pcall(render, hud, shown == nil or shown.hud ~= hud:GetAddress())
        if not ok then log("Orders: the task list: %s", tostring(e)) end
        return
    end
    local mode = Orders.mode()
    local sig = signature(mode, mode ~= "all" and Orders.rows(mode) or {})
    if mode == "all" then
        -- (rows of the game's that were put aside come back only when it fills its list)
        if sig ~= shown.sig then pcall(Orders.refresh) end
        return
    end
    if sig ~= shown.sig then
        local ok, e = pcall(render, hud, false)
        if not ok then log("Orders: the task list: %s", tostring(e)) end
    end
end)

-- Hides or shows the deliveries the other players have marked (the key, held).
function Orders.setHiding(hide)
    if not on() then return end
    if hide == nil then hide = not Orders.hiding() end
    Colours.setPref("hideOthers", hide == true)
    clientsAt = -100
    Orders.refresh()
    pcall(announce, hide and "Marked by others: hidden" or "Marked by others: shown")
end

-- The key. A press goes on to the next list when the key comes up again; held for half a
-- second it hides or shows what the others have marked instead.
local KEYS = { "J", "K", "N", "O", "X", "Z" }      -- what the settings offer (and "NONE")
local function KEY() return tostring(Core.config.DeliveryListKey or "O"):upper() end
local held = nil           -- { at } while the key is down and nothing has been done with it
local spent = false        -- the hold has done its work: nothing more until the key is up

local function keyDown()
    local down = false
    pcall(function()
        local Keys = require("coop.keys")
        down = World.player():GetController():IsInputKeyDown({ KeyName = FName(Keys.ue(KEY())) }) == true
    end)
    return down
end

-- (every key the settings offer is listened to, and the one in config.lua when it is
-- another: which of them counts is asked when one is pressed, so a change counts at once)
local function pressed(name)
    if not live() or not on() or held or spent or KEY() ~= name then return end
    local player = World.player()
    if not player or World.joining then return end
    -- (a letter typed into the computer, a talk or one of the mod's screens is not the key)
    local busy = false
    pcall(function() busy = player.computerOpen == true or player.inDialogue == true or player.isTrading == true end)
    local Screen = package.loaded["coop.screen"]
    if busy or (type(Screen) == "table" and Screen.current) then return end
    held = { at = os.clock() }
end

if Core.bindKey then
    local bound = {}
    local own = KEY()
    for _, name in ipairs({ own, table.unpack(KEYS) }) do
        if name ~= "NONE" and not bound[name] then
            bound[name] = true
            Core.bindKey(name, function() pressed(name) end)
        end
    end
end

Core.onTick(function()
    if not live() then return end
    if spent then
        if not keyDown() then spent = false end
        return
    end
    if not held then return end
    if not World.player() then
        held = nil
        return
    end
    if not keyDown() then
        held = nil
        Orders.setMode()
    elseif os.clock() - held.at >= Orders.HOLD then
        held, spent = nil, true
        Orders.setHiding()
    end
end)

-- (the switch on the EXPERIMENTAL page)
function Orders.apply() Orders.refresh() end

function Orders.shutdown() shown, holder, label = nil, nil, nil end

-- (for test scripts)
function Orders.shown() return shown end

return Orders
