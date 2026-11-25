-- First sales for every player.
--
-- The opening gives a player one package (2 x 3 g marijuana, 1 x 5 g amphetamine) and
-- three clients to sell it to. The game makes those orders fit the package by a rule
-- about the WORLD: the first two orders ever made are 3 g of the first drug, the third is
-- 5 g of the second (salesManager: calcOrderQuantity and getOrderedDrugIndex look at the
-- length of the order list). Every order after that comes from the usual formula. So the
-- second player to fetch their package got "4 g" orders that nobody can fill before there
-- is a work station, and because that player's story sends them to the same clients 0, 1
-- and 2, they replaced the first player's orders as well.
--
-- Now:
--   * Each player who has fetched the package and not yet made the three sales tells the
--     host what they carry of it (the host looks at its own pockets).
--   * The host's game keeps one open order per carried piece: where pieces are missing an
--     order it makes one for a client who has none, through the game's own
--     clientSendNewOrder with the order list shortened for the length of that call, so the
--     game's rule gives the amount, the drug and the client's message. The lists are put
--     back with the new order at their end.
--   * The orders a player's own story sends to clients 0, 1 and 2 are taken back the
--     moment they are made, in the host's game as well: left in, the host's three raced
--     the ones made here for the same clients and one of the two was lost. (A host who
--     fetched the package before anybody joined has the game's own three, which fit.)

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")
local Story = require("coop.story")
local json = require("json")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Desk = {
    needs = {},     -- host: player id -> { list = { { d, g, n } }, at }
    made = {},      -- host: number of an order made here -> its piece ("0|3")
    clients = 0,    -- host: clients found here for want of one without an order
    stats = { undone = 0, issued = 0, failed = 0, clients = 0 },
}

local QM_PATH = "/Game/WorldControlers/questManager.questManager_C"
local SALES_PATH = "/Game/WorldControlers/salesManager.salesManager_C"
-- The arrays an order is one element of (the ones clientSendNewOrder adds to).
local ORDER = { "orderListClientID", "orderListDrugOrdered", "orderListDrugQuantity", "orderListDrugExpectedPrice",
    "orderListTaskID", "orderListAccepted", "orderListDeliveryTime", "orderListClosed" }
-- A piece of the package -> how long the order list has to look for the game's rule to
-- make an order of it: by index of the drug in the phone's list and grams.
local RULE = { ["0|3"] = 0, ["1|5"] = 2 }
local WINDOW = 45       -- seconds after a player's first package in which their story sends its three orders
local PACE = 6          -- seconds between two orders made here

local windowUntil = 0
local lastLen = nil
local firstNewest = nil     -- the "newest order" entries as they were when this game's window opened
local busy = false          -- true while this module itself has the game make an order
local issueAt, needSince = 0, nil
local sentText, sentAt = nil, 0
local skip = {}             -- client -> time until which it is not tried again

local function enabled()
    return Core.enabled("Story") and Core.enabled("Orders")
end

local function sales() return Repl.singleton("salesManager_C") end
local function computer() return Repl.singleton("mainComputer_C") end

local function get(obj, name)
    return Repl.splitArray(Repl.export(obj, { name })[name] or "()")
end

local function put(obj, name, elements)
    Repl.import(obj, { [name] = Repl.joinArray(elements) })
end

local function count(s)
    local ok, n = pcall(function() return s.orderListClientID:GetArrayNum() end)
    return ok and n or nil
end

local function bare(text)
    return (tostring(text):gsub('^"', ""):gsub('"$', ""))
end

---------------------------------------------------------------- an order taken back

-- Removes the order that was made for `client` a moment ago (the last one of the list):
-- its element of every list, the client's message about it, and what the client and its
-- contact remember about having asked. Nothing has been sent to anybody yet: this runs in
-- the same frame as the game function that made it.
local function takeBack(s)
    local ids = get(s, "orderListClientID")
    local L = #ids
    if L == 0 then return false end
    local client = tonumber(ids[L])
    if not client or client < 0 or client > 2 then return false end
    local accepted, closed, newest = get(s, "orderListAccepted"), get(s, "orderListClosed"), get(s, "clientsNewestOrderID")
    if accepted[L] == "True" or closed[L] == "True" or tonumber(newest[client + 1]) ~= L - 1 then return false end
    local lists = {}
    for _, name in ipairs(ORDER) do
        local e = get(s, name)
        if #e ~= L then return false end
        e[L] = nil
        lists[name] = e
    end
    -- the order this client had before, if any
    local prev = nil
    for j = L - 1, 1, -1 do
        if tonumber(ids[j]) == client then
            prev = j
            break
        end
    end
    local open = prev ~= nil and closed[prev] ~= "True" and accepted[prev] ~= "True"
    newest[client + 1] = prev and tostring(prev - 1) or (firstNewest and firstNewest[client + 1]) or newest[client + 1]
    local waiting = get(s, "clientAwaitingResponse")
    if waiting[client + 1] then waiting[client + 1] = open and "True" or "False" end
    local contact = tonumber(get(s, "clientsAvailable")[client + 1])

    for _, name in ipairs(ORDER) do put(s, name, lists[name]) end
    put(s, "clientsNewestOrderID", newest)
    put(s, "clientAwaitingResponse", waiting)

    local c = computer()
    if c and contact then
        local users, texts, mine = get(c, "messagesUsers"), get(c, "messagesList"), get(c, "messagesMine")
        local n = #users
        if n > 0 and #texts == n and #mine == n and tonumber(users[n]) == contact and mine[n] ~= "True" then
            users[n], texts[n], mine[n] = nil, nil, nil
            put(c, "messagesUsers", users)
            put(c, "messagesList", texts)
            put(c, "messagesMine", mine)
            local list, counts = get(c, "contactList"), get(c, "contactNumMessages")
            for i, id in ipairs(list) do
                if tonumber(id) == contact and counts[i] then
                    counts[i] = tostring(math.max(0, (tonumber(counts[i]) or 1) - 1))
                    put(c, "contactNumMessages", counts)
                    break
                end
            end
        end
        local manager = Repl.singleton("contactsManager_C")
        if manager then
            local pending = get(manager, "charOrderPending")
            if pending[contact + 1] then
                pending[contact + 1] = open and "True" or "False"
                put(manager, "charOrderPending", pending)
            end
        end
        pcall(function()
            if valid(c.interface) then
                Core.callFirst(c.interface, { "renderContacts", "Render Contacts" })
                c.interface:checkOptionAvailability()
            end
        end)
    end
    Desk.stats.undone = Desk.stats.undone + 1
    vlog("First sales: the order this game's story made for client %d is taken back (the host makes the ones that fit)", client)
    return true
end

Core.Hooks.add(QM_PATH .. ":retrievedFirstPackage", function()
    if not World.active or not enabled() then return end
    windowUntil = os.clock() + WINDOW
    local s = sales()
    if s then
        lastLen = count(s)
        firstNewest = get(s, "clientsNewestOrderID")
    end
end)

Core.Hooks.add(SALES_PATH .. ":clientSendNewOrder", function(ctx)
    if busy or not World.active or not enabled() then return end
    local s = ctx:get()
    if not valid(s) then return end
    local n = count(s)
    local grew = n ~= nil and lastLen ~= nil and n > lastLen
    lastLen = n
    if not grew then return end
    -- A guest's game makes no orders of its own (its sales manager is off): what gets here
    -- are the three calls of its story. In the host's game the same three calls come
    -- within the window after its first package; anything later is the usual business.
    if World.role == "host" and os.clock() > windowUntil then return end
    local ok, e = pcall(takeBack, s)
    if not ok then log("First sales: %s", tostring(e)) end
    lastLen = count(s)
end)

---------------------------------------------------------------- what a player still has to sell

-- The pieces of the first package in the local player's pockets: { { d, g, n } }.
local function carried()
    local out = {}
    -- from the first package to the third sale (the step "First clients" itself is over
    -- with the first order a player confirms)
    local q = Repl.singleton("questManager_C")
    local ok, selling = pcall(function() return q.firstDeadDrop == true and q.firstSalesDone ~= true end)
    if not ok or not selling then return out end
    local player = World.player()
    if not player then return out end
    local v = Repl.export(player, { "InventoryComponent.ItemNames", "InventoryComponent.ItemQuantities", "InventoryComponent.ItemCurAmount" })
    local names = Repl.splitArray(v["InventoryComponent.ItemNames"] or "()")
    local units = Repl.splitArray(v["InventoryComponent.ItemQuantities"] or "()")
    local grams = Repl.splitArray(v["InventoryComponent.ItemCurAmount"] or "()")
    for i, name in ipairs(names) do
        local d, g, n = bare(name), tonumber(grams[i]), tonumber(units[i])
        if d:sub(1, 5) == "DRUG-" and g and n and n > 0 then out[#out + 1] = { d = d, g = math.floor(g + 0.5), n = math.floor(n) } end
    end
    table.sort(out, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.g < b.g end)
    return out
end

Net.on("fneed", function(sender, data)
    if World.role ~= "host" or not World.inWorld[sender] or type(data.p) ~= "table" then return end
    local list = {}
    for i, p in ipairs(data.p) do
        if i > 12 then break end
        if type(p) == "table" and type(p.d) == "string" and tonumber(p.g) and tonumber(p.n) then
            list[#list + 1] = { d = p.d, g = math.floor(tonumber(p.g)), n = math.min(20, math.floor(tonumber(p.n))) }
        end
    end
    Desk.needs[sender] = #list > 0 and { list = list, at = os.clock() } or nil
end)

World.listen("peerleft", function(id) Desk.needs[id] = nil end)

---------------------------------------------------------------- the host's desk

-- Has the game make one order for `client` as if the order list had `k` orders.
local function issue(s, client, k)
    -- (In a world that has been played for long the lists are not all of one length: some
    -- were added by a later version of the game. Each is cut and put back by its own.)
    local saved = {}
    for _, name in ipairs(ORDER) do saved[name] = get(s, name) end
    local n = #saved.orderListClientID
    if n < k or #saved.orderListDrugQuantity < k then return false, "too few orders so far" end
    busy = true
    local made = nil
    local ok, e = pcall(function()
        local short = {}
        for _, name in ipairs(ORDER) do
            short[name] = math.min(k, #saved[name])
            local cut = {}
            for i = 1, short[name] do cut[i] = saved[name][i] end
            put(s, name, cut)
        end
        s:clientSendNewOrder(client, false)
        made = {}
        for _, name in ipairs(ORDER) do
            local now = get(s, name)
            if #now ~= short[name] + 1 then
                made = nil
                break
            end
            made[name] = now[#now]
        end
    end)
    -- back to the real lists, with the new order at their end
    for _, name in ipairs(ORDER) do
        local full = saved[name]
        if made then full[#full + 1] = made[name] end
        put(s, name, full)
    end
    if made then
        local newest = get(s, "clientsNewestOrderID")
        if newest[client + 1] then
            newest[client + 1] = tostring(n)
            put(s, "clientsNewestOrderID", newest)
        end
    end
    busy = false
    lastLen = count(s)
    if not ok then return false, tostring(e) end
    return made ~= nil, made and nil or "the client did not order"
end

-- The clients that could be asked: not waiting for an answer, their newest order (if any)
-- closed, not lost, arrested or a dealer. `tried` counts those left out only because they
-- made no order a moment ago.
local function freeClients(s, ids, closed, newest)
    local avail, lost, dealer, waiting = get(s, "clientsAvailable"), get(s, "clientsLost"), get(s, "clientIsDealer"), get(s, "clientAwaitingResponse")
    local arrested = {}
    for _, v in ipairs(get(s, "ArrestedClients")) do arrested[tonumber(v) or -1] = true end
    local out, tried, now = {}, 0, os.clock()
    for c = 0, #avail - 1 do
        local last = tonumber(newest[c + 1])
        local open = last ~= nil and last >= 0 and tonumber(ids[last + 1]) == c and closed[last + 1] ~= "True"
        if not open and not arrested[c] and lost[c + 1] ~= "True" and dealer[c + 1] ~= "True" and waiting[c + 1] ~= "True"
            and (tonumber(avail[c + 1]) or -1) >= 0 then
            if now >= (skip[c] or 0) then out[#out + 1] = c else tried = tried + 1 end
        end
    end
    return out, tried
end

local function tend()
    local s, c = sales(), computer()
    if not s or not c then return end
    -- what everybody in the step carries, by piece
    local want, any = {}, false
    local function add(list)
        for _, p in ipairs(list) do
            local key = p.d .. "|" .. p.g
            want[key] = (want[key] or 0) + p.n
            any = true
        end
    end
    add(carried())
    local now = os.clock()
    for id, need in pairs(Desk.needs) do
        if now - need.at > 70 or not World.inWorld[id] then Desk.needs[id] = nil else add(need.list) end
    end
    if not any then
        needSince = nil
        return
    end
    needSince = needSince or now
    -- like the game, which lets ten seconds pass before the first client writes
    if now - needSince < 8 or now < issueAt then return end

    local drugIds, drugs = get(c, "drugsAvailableIDs"), get(c, "drugsAvailable")
    local index = {}
    for i, id in ipairs(drugIds) do index[bare(id)] = i - 1 end
    local ids, closed, accepted = get(s, "orderListClientID"), get(s, "orderListClosed"), get(s, "orderListAccepted")
    local ordered, grams, newest = get(s, "orderListDrugOrdered"), get(s, "orderListDrugQuantity"), get(s, "clientsNewestOrderID")
    -- open orders that can still be answered or are being delivered, by piece
    local have = {}
    for i = 1, #ids do
        local client = tonumber(ids[i]) or -1
        if closed[i] ~= "True" and (accepted[i] == "True" or tonumber(newest[client + 1]) == i - 1) then
            local key = Desk.made[i - 1]
            -- (besides the orders made here only those of clients 0 to 2, the game's own
            -- three for a first package: in a world played for long other clients' orders
            -- of 3 g or 5 g are the host's business, and counting them left a guest's
            -- piece without an order, 2026-11-19)
            if not key and client >= 0 and client <= 2 then
                for j, text in ipairs(drugs) do
                    if text == ordered[i] then
                        key = (j - 1) .. "|" .. tostring(tonumber(grams[i]) or 0)
                        break
                    end
                end
            end
            if key then have[key] = (have[key] or 0) + 1 end
        end
    end
    -- the first piece that has fewer orders than players carry of it (the 3 g ones first:
    -- the 5 g rule needs two orders in the list)
    local pick = nil
    for key, n in pairs(want) do
        local d, g = key:match("^(.*)|(%d+)$")
        local rule = index[d] and ((index[d]) .. "|" .. g) or nil
        local k = rule and RULE[rule] or nil
        if k and n > (have[rule] or 0) and (not pick or k < pick.k) then pick = { k = k, rule = rule } end
    end
    if not pick then return end
    issueAt = now + PACE
    local free, tried = freeClients(s, ids, closed, newest)
    if #free == 0 then
        -- nobody to ask: a new client, as the game makes three for a first package. Not
        -- while clients who made no order are only waiting to be asked again, and a few at
        -- most.
        if tried > 0 or Desk.clients >= 6 then return end
        Desk.clients = Desk.clients + 1
        local ok = pcall(function() s:generateNewClient(true) end)
        if ok then Desk.stats.clients = Desk.stats.clients + 1 end
        vlog("First sales: no client without an order, a new one is found (%s)", tostring(ok))
        if not ok then return end
        -- The new client is asked at once: in a world where every client already has an
        -- order the game gives a new one an order of its own within seconds, and the desk
        -- found a client without one again and again (2026-11-19, a guest in a level-13 world).
        ids, closed, newest = get(s, "orderListClientID"), get(s, "orderListClosed"), get(s, "clientsNewestOrderID")
        free = freeClients(s, ids, closed, newest)
        if #free == 0 then return end
    end
    local client = free[math.random(#free)]
    local made, why = issue(s, client, pick.k)
    if made then
        Desk.made[#ids] = pick.rule
        Desk.stats.issued = Desk.stats.issued + 1
        log("First sales: an order that fits a first package was made (client %d, piece %s)", client, pick.rule)
    else
        Desk.stats.failed = Desk.stats.failed + 1
        skip[client] = now + 30
        vlog("First sales: client %d made no order (%s)", client, tostring(why))
    end
end

Core.every(2, function()
    if not World.shared() or not enabled() then return end
    local s = sales()
    if s and not busy then lastLen = count(s) end
    if World.role == "guest" then
        if not Story.isReady() then return end
        local list = carried()
        local ok, text = pcall(json.encode, list)
        if not ok then return end
        local now = os.clock()
        if text ~= sentText or (#list > 0 and now - sentAt > 20) then
            sentText, sentAt = text, now
            Net.send("fneed", { p = list }, World.host or Net.S.owner)
        end
        return
    end
    local ok, e = xpcall(tend, debug.traceback)
    if not ok then
        busy = false
        log("First sales: %s", tostring(e))
    end
end)

-- The length of the order list is looked at often while this game's story is about to
-- send its orders: the hook above tells a new order by it.
Core.every(0.25, function()
    if busy or not World.active or os.clock() > windowUntil then return end
    local s = sales()
    if s then lastLen = count(s) end
end)

local function reset()
    Desk.needs, Desk.made, Desk.clients = {}, {}, 0
    windowUntil, lastLen, firstNewest, busy = 0, nil, nil, false
    issueAt, needSince, sentText, sentAt, skip = 0, nil, nil, 0, {}
end
World.listen("start", reset)

-- RELOAD of "First clients" (coop/options.lua): orders are looked at again now, clients
-- that made none are asked again, and a guest tells the host again what it carries.
function Desk.nudge()
    issueAt, skip, Desk.clients = 0, {}, 0
    if needSince then needSince = os.clock() - 10 end
    sentText = nil
end
World.listen("stop", reset)

return Desk
