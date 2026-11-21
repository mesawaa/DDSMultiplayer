-- Clients and dealers that have stopped answering: REPAIR on the MOD OPTIONS page.
--
-- A dealer can take his product and then never say that the cash is ready.
-- What a client or a dealer
-- does next is one thing in the game: the sales manager counts every client's
-- `clientsOrderCountdown` down, and at 0 the client orders, or a dealer who has taken his
-- product (`clientDealerTookDope`) says that the cash is ready. A client is left out of
-- the counting while he waits for an answer to an order (`clientAwaitingResponse`), is
-- lost, arrested or one of the lab crew. So somebody is stuck for good when
--   * he waits for an answer to an order that is not there (any more), or
--   * his countdown does not go down while the others' do.
-- The first is seen at once. For the second the game that runs the sales (the host's, or
-- a single player's) looks at the countdowns now and then and notes who is not moving.
--
-- REPAIR puts both right: the waiting is ended, and the countdown is set to 0, at which
-- the game has him order (or report his cash) at once. Nobody else is touched: a dealer
-- who is simply still selling keeps his time. Every dealer's state goes into the log
-- (ipc/mod.log), so that a report says which of the two it was.
--
-- A guest's REPAIR is done by the host's game, where the sales run.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local GEN = (rawget(_G, "DDSMP_CLIENTS_GEN") or 0) + 1
_G.DDSMP_CLIENTS_GEN = GEN
local function live() return rawget(_G, "DDSMP_CLIENTS_GEN") == GEN end

local Clients = { stats = { looks = 0, repairs = 0, waiting = 0, stalled = 0 } }

Clients.PERIOD = 30          -- seconds between two looks at the countdowns
Clients.STALL = 150          -- a countdown that has not gone down for this long, while others did, is stuck

local track = {}             -- client -> { value, since }: his countdown and since when it has not gone down
local progressAt = nil       -- when a countdown was last seen going down
local trackedFor = nil       -- the sales manager the notes are about
local clock = nil            -- the game's time of day at the last look (minutes)
local runningSince = nil     -- since when every look has found the game's clock moved on and the sales switched on

local function sales() return Repl.singleton("salesManager_C") end

-- True where this game runs the sales: a single player's game and the host's.
local function runsSales()
    return World.player() ~= nil and not (World.active and World.role == "guest")
end

local function array(obj, name)
    return Repl.splitArray(Repl.export(obj, { name })[name] or "()")
end

-- The clients as the sales manager has them: one record each, by number (from 0).
local function snapshot(s)
    local avail, lost, dealer = array(s, "clientsAvailable"), array(s, "clientsLost"), array(s, "clientIsDealer")
    local waiting, took, cash = array(s, "clientAwaitingResponse"), array(s, "clientDealerTookDope"), array(s, "clientDealerCashToPay")
    local count, crew = array(s, "clientsOrderCountdown"), array(s, "ClientsLabCrew")
    local ids, closed, accepted = array(s, "orderListClientID"), array(s, "orderListClosed"), array(s, "orderListAccepted")
    local newest = array(s, "clientsNewestOrderID")
    local arrested = {}
    for _, v in ipairs(array(s, "ArrestedClients")) do arrested[tonumber(v) or -1] = true end
    -- an order that can still be answered or is being delivered
    local open = {}
    for i = 1, #ids do
        local c = tonumber(ids[i]) or -1
        if c >= 0 and closed[i] ~= "True" and (accepted[i] == "True" or tonumber(newest[c + 1]) == i - 1) then open[c] = true end
    end
    local list = {}
    for c = 0, #avail - 1 do
        list[#list + 1] = { c = c, contact = tonumber(avail[c + 1]) or -1, lost = lost[c + 1] == "True", dealer = dealer[c + 1] == "True",
            waiting = waiting[c + 1] == "True", took = took[c + 1] == "True", cash = tonumber(cash[c + 1]) or 0,
            count = tonumber(count[c + 1]) or 0, crew = crew[c + 1] == "True", arrested = arrested[c] == true, open = open[c] == true }
    end
    return list
end

-- Somebody the game counts down: known, not lost, not arrested, not lab crew.
local function counted(r)
    return r.contact >= 0 and not r.lost and not r.arrested and not r.crew
end

---------------------------------------------------------------- who is not moving

local function look()
    local s = sales()
    if not s then return end
    local address = s:GetAddress()
    if trackedFor ~= address then track, progressAt, trackedFor, clock, runningSince = {}, nil, address, nil, nil end
    local now = os.clock()
    -- The countdowns go with the game's own time: while it stands still (a pause, a menu)
    -- or the sales are switched off nobody's countdown moves, and nobody is stuck.
    local minutes, active = nil, false
    pcall(function()
        local d = Repl.singleton("dayTimeControler_C")
        minutes = math.floor((tonumber(d.curHour) or 0) * 60 + (tonumber(d.curMinute) or 0))
        active = s.salesActive == true
    end)
    if minutes ~= nil and clock ~= nil and minutes ~= clock and active then
        runningSince = runningSince or now
    else
        runningSince = nil
    end
    clock = minutes
    Clients.stats.looks = Clients.stats.looks + 1
    local seen = {}
    for _, r in ipairs(snapshot(s)) do
        if counted(r) and not r.waiting and not r.open and r.count > 0 then
            seen[r.c] = true
            local t = track[r.c]
            if not t then
                track[r.c] = { value = r.count, since = now }
            elseif r.count < t.value - 0.001 then
                t.value, t.since = r.count, now
                progressAt = now
            elseif r.count > t.value + 0.001 then
                t.value, t.since = r.count, now          -- (set anew: a new wait begins)
            end
        end
    end
    for c in pairs(track) do
        if not seen[c] then track[c] = nil end
    end
end

-- True for a client whose countdown has not gone down for a while, though the game's time
-- went on and the sales were switched on all that while. Where other clients are being
-- counted down too, one of theirs must have moved meanwhile (when nobody's moves, the game
-- is not counting just now, and nobody is stuck).
local function stalled(c)
    local t = track[c]
    if not t or not runningSince then return false end
    local now = os.clock()
    if now - t.since < Clients.STALL or runningSince > t.since + Clients.PERIOD then return false end
    local others = false
    for other in pairs(track) do
        if other ~= c then others = true break end
    end
    return not others or (progressAt ~= nil and progressAt >= t.since + Clients.STALL / 2)
end

Core.every(5, function()
    if not live() or not runsSales() then return end
    if os.clock() < (Clients.lookAt or 0) then return end
    Clients.lookAt = os.clock() + Clients.PERIOD
    local ok, e = pcall(look)
    if not ok then vlog("Clients: %s", tostring(e)) end
end)

---------------------------------------------------------------- repair

local function nameOf(contact)
    local name = nil
    pcall(function()
        local cm = Repl.singleton("contactsManager_C")
        name = cm.characterList[contact + 1].Name_16_FF9AED99407FDA5CC81F3A92D99C45A8:ToString()
    end)
    return (name and name ~= "") and name or ("contact " .. tostring(contact))
end

-- Does the repair in this game (which runs the sales). Returns how many were put right
-- and a line for the player.
function Clients.repair(by)
    local s = sales()
    if not s then return 0, "No sales manager in this world" end
    local list = snapshot(s)
    local fixed, names, dealers = 0, {}, 0
    for _, r in ipairs(list) do
        if r.dealer then
            dealers = dealers + 1
            log("Clients: dealer %d (%s): took product %s, cash to pay %d, waiting for an answer %s, open order %s, countdown %.1f%s%s%s%s", r.c, nameOf(r.contact),
                tostring(r.took), r.cash, tostring(r.waiting), tostring(r.open), r.count, r.arrested and ", ARRESTED" or "", r.lost and ", LOST" or "",
                r.crew and ", lab crew" or "", stalled(r.c) and ", countdown NOT MOVING" or "")
        end
        if counted(r) then
            local why = nil
            if r.waiting and not r.open then
                why = "waited for an answer to an order that is not there"
                Clients.stats.waiting = Clients.stats.waiting + 1
            elseif not r.waiting and not r.open and stalled(r.c) then
                why = "countdown was not moving"
                Clients.stats.stalled = Clients.stats.stalled + 1
            end
            if why then
                local ok, e = pcall(function()
                    s.clientAwaitingResponse[r.c + 1] = false
                    s.clientsOrderCountdown[r.c + 1] = 0.0
                    if r.waiting then
                        local cm = Repl.singleton("contactsManager_C")
                        if cm then cm.charOrderPending[r.contact + 1] = false end
                    end
                end)
                track[r.c] = nil
                if ok then
                    fixed = fixed + 1
                    names[#names + 1] = nameOf(r.contact)
                    log("Clients: %s %d (%s) %s: put right%s", r.dealer and "dealer" or "client", r.c, nameOf(r.contact), why,
                        (r.dealer and r.took) and "; his cash message comes now" or "; he orders again now")
                else
                    log("Clients: %s %d could not be put right: %s", r.dealer and "dealer" or "client", r.c, tostring(e))
                end
            end
        end
    end
    Clients.stats.repairs = Clients.stats.repairs + 1
    local active = "?"
    pcall(function() active = tostring(s.salesActive) end)
    log("Clients: repair asked by %s: %d client(s), %d dealer(s), %d put right; sales running here: %s", tostring(by or "this player"), #list, dealers, fixed, active)
    if fixed == 0 then return 0, string.format("Nobody looked stuck (%d clients, %d dealers)", #list, dealers) end
    local shown = table.concat(names, ", ", 1, math.min(3, #names)) .. (#names > 3 and " ..." or "")
    return fixed, string.format("%d put right: %s", fixed, shown)
end

local function toast(text)
    local Hud = package.loaded["coop.hud"]
    if type(Hud) == "table" and Hud.toast then pcall(Hud.toast, text, 6) end
end

-- REPAIR pressed: done here, or asked of the host. Returns false when it cannot be done.
function Clients.ask()
    if not World.player() then return false end
    if World.active and World.role == "guest" then
        if not World.shared() then return false end
        Net.send("cfq", {}, World.host or Net.S.owner)
        toast("Asked the host's game to look at dealers and clients")
        return true
    end
    local ok, n, text = pcall(Clients.repair, Net.S.myName)
    toast(ok and text or "Dealers and clients could not be looked at")
    if not ok then log("Clients: %s", tostring(n)) end
    return true
end

Net.on("cfq", function(sender)
    if not live() or World.role ~= "host" or not World.inWorld[sender] then return end
    local ok, n, text = pcall(Clients.repair, Net.name(sender))
    if not ok then
        log("Clients: %s", tostring(n))
        n, text = 0, "Dealers and clients could not be looked at"
    end
    Net.send("cfa", { n = n, m = text }, sender)     -- (never a field `t`: Net.send puts the message type there)
    if ok and n > 0 then toast(Net.name(sender) .. " repaired dealers and clients: " .. text) end
end)

Net.on("cfa", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) or type(data.m) ~= "string" then return end
    toast(data.m:sub(1, 200))
end)

local function reset() track, progressAt, trackedFor, clock, runningSince, Clients.lookAt = {}, nil, nil, nil, nil, nil end
World.listen("start", function() if live() then reset() end end)
World.listen("stop", function() if live() then reset() end end)

function Clients.state() return { track = track, progressAt = progressAt, clock = clock, runningSince = runningSince } end
Clients.snapshot = function() local s = sales() return s and snapshot(s) or {} end
Clients.stalled = stalled
Clients.look = look

return Clients
