-- MOD OPTIONS: the mod's own screen for getting a game unstuck, in the game.
--
-- Opened from the pause menu (its MOD OPTIONS entry) or with ModOptionsKey, always on
-- SETTINGS. Four pages:
--
--   SETTINGS  the settings of config.lua, written into that file. Most take effect at
--             once; the Sync switches after a restart (every player should have the same).
--   REPAIR    dealers and clients that stopped answering are put right (coop/clients.lua);
--             draw jars, boxes and bags again; ask for the whole shared state again (a
--             guest from the host, the host for every guest); UNSTUCK, a stuck player
--             moved to the nearest open ground.
--   QUESTS    the open story steps (and the step of Olivia's wall), each with RELOAD: the
--             step is set up again so that the player can do it (Eddie back on his bench,
--             the first package back in the player's own dead drop, the first clients'
--             orders asked for again, the ATMs switched on, the marker, the task list).
--             Nothing is completed, so nobody is asked.
--   EXPERIMENTAL  the features that are not fully tested yet (coop/experimental.lua),
--             each with its switch, off until the player switches it on; kept in
--             the Experimental table of config.lua.

local Core = require("core")
local World = require("coop.world")
local Screen = require("coop.screen")
local Hud = require("coop.hud")
local Story = require("coop.story")
local Sync = require("coop.sync")
local Experimental = require("coop.experimental")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_OPTIONS_GEN") or 0) + 1
_G.DDSMP_OPTIONS_GEN = GEN
local function live() return rawget(_G, "DDSMP_OPTIONS_GEN") == GEN end

local Options = { tab = "settings" }

local scr = nil          -- the open screen
local drawn = {}         -- what the page put on it
local BUTTON_INSET = 10.5
local BAR = 18            -- the room a scroll bar takes
local ROW_BG = { R = 0.03, G = 0.03, B = 0.035, A = 0.95 }
local ACCENT = { R = 0.55, G = 0.02, B = 0.02, A = 1 }
local YELLOW = { R = 0.95, G = 0.75, B = 0.2, A = 1 }

-- Olivia's wall, while its step is one this player can be stuck on.
local function wall()
    local Quest = package.loaded["coop.wallquest"]
    if type(Quest) ~= "table" or not Quest.state or not Quest.state() then return nil end
    local s = Quest.step()
    if s < Quest.ASK or s > Quest.TELL then return nil end
    return Quest
end

---------------------------------------------------------------- unstuck

-- UNSTUCK moves the player to the nearest open, flat ground. Rings of points around them,
-- nearest first: a line down from each finds the ground (no steeper than about 37 degrees,
-- wide enough to stand on) and the player's own capsule has to fit there without touching
-- anything. A place in plain sight of the player is taken before one behind something.
-- The first look allows ground only a little higher than the player's middle (no landing
-- on a car roof); a second look allows more (a player sunk into the floor). Pressed again
-- within AGAIN_SECONDS it looks further out than the last move, so it never sends a
-- player back and forth. With nothing near, or while falling: the last place the player
-- stood on the ground.
local KSL = nil
local TRACE_RED, TRACE_GREEN = { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }
local FLAT = 0.8                  -- the ground's normal, upward part, at least
local NEAREST, FARTHEST, STEP = 60, 1000, 50
local REACH = { 30, 250 }         -- how far over the player's middle the ground may be, first and second look
local DOWN = 300                  -- how far under the player's middle it may be
local AGAIN_SECONDS = 20
local BUSY = { "inventoryOpen", "phoneUp", "computerOpen", "mapOpen", "saveScreenOpen", "isTrading", "inDialogue",
    "atWorkStation", "inAppartmentMode", "RenovationMode", "isLockpicking", "equipmentShopOpen", "beenCaught",
    "waiting", "sleepDialogue" }
local lastGround = nil            -- { X, Y, Z }: the capsule's middle where the player last stood on the ground
local lastMove = nil              -- { at, dist }

local function ksl()
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    return KSL
end

local function lineHit(p, from, to)
    local hit = {}
    local ok, yes = pcall(function()
        return ksl():LineTraceSingle(p, from, to, 0, false, {}, 0, hit, true, TRACE_RED, TRACE_GREEN, 0)
    end)
    return ok and yes == true, hit
end

-- True when a capsule of this size with its middle at `c` touches nothing.
local function roomAt(p, c, r, h)
    local hit = {}
    local ok, yes = pcall(function()
        return ksl():CapsuleTraceSingle(p, c, { X = c.X, Y = c.Y, Z = c.Z + 1 }, r, h, 0, false, {}, 0, hit, true,
            TRACE_RED, TRACE_GREEN, 0)
    end)
    return ok and yes == false
end

-- Where the player's middle would be standing on the ground under (x, y), or nil.
local function standAt(p, x, y, z, r, h, reach)
    local yes, hit = lineHit(p, { X = x, Y = y, Z = z + reach }, { X = x, Y = y, Z = z - DOWN })
    if not yes then return nil end
    local n, at = hit.ImpactNormal, hit.ImpactPoint
    if type(n) ~= "table" or type(at) ~= "table" or (n.Z or 0) < FLAT then return nil end
    local c = { X = x, Y = y, Z = at.Z + h + 3 }
    if not roomAt(p, c, r, h) then return nil end
    -- ground under the whole capsule, not the top of a fence
    for k = 0, 3 do
        local a = k * math.pi / 2
        local sx, sy = x + math.cos(a) * r * 0.8, y + math.sin(a) * r * 0.8
        if not lineHit(p, { X = sx, Y = sy, Z = at.Z + 20 }, { X = sx, Y = sy, Z = at.Z - 30 }) then return nil end
    end
    return c
end

local function find(p, minDist)
    local l = p:K2_GetActorLocation()
    local cap = p.CapsuleComponent
    local r, h = cap:GetScaledCapsuleRadius(), cap:GetScaledCapsuleHalfHeight()
    for _, reach in ipairs(REACH) do
        local hidden = nil
        for d = math.max(NEAREST, minDist), FARTHEST, STEP do
            local n = math.min(24, math.max(8, math.floor(2 * math.pi * d / 80)))
            for i = 0, n - 1 do
                local a = 2 * math.pi * i / n
                local c = standAt(p, l.X + math.cos(a) * d, l.Y + math.sin(a) * d, l.Z, r, h, reach)
                if c then
                    if not lineHit(p, l, c) then return c, d end
                    hidden = hidden or { c = c, d = d }
                end
            end
            -- (one behind something counts once nothing in sight is as near plus 2 m)
            if hidden and d >= hidden.d + 200 then break end
        end
        if hidden then return hidden.c, hidden.d end
    end
    return nil
end

local function busyFlag(p)
    for _, f in ipairs(BUSY) do
        local yes = false
        pcall(function() yes = p[f] == true end)
        if yes then return f end
    end
    local Casino = package.loaded["coop.casino"]
    if type(Casino) == "table" and Casino.seated then return "card table" end
    return nil
end

local function unstuck()
    local p = World.player()
    if not p then return end
    local why = busyFlag(p)
    if why then
        pcall(Hud.toast, "Close what is open first, then UNSTUCK", 4)
        log("Options: unstuck refused (%s)", why)
        return
    end
    local minDist = 0
    if lastMove and os.clock() - lastMove.at < AGAIN_SECONDS then minDist = lastMove.dist + STEP end
    local from = p:K2_GetActorLocation()
    -- falling (through the floor, off the map): back up to the last ground stood on, not
    -- to whatever is under the world
    local falling = false
    pcall(function() falling = p.CharacterMovement:IsFalling() == true end)
    local ok, c, d = true, nil, nil
    if not (falling and lastGround) then ok, c, d = pcall(find, p, minDist) end
    if not ok then
        log("Options: unstuck: %s", tostring(c))
        c, d = nil, nil
    end
    local how = "open ground"
    if not c and lastGround then
        local dx, dy, dz = lastGround.X - from.X, lastGround.Y - from.Y, lastGround.Z - from.Z
        local far = math.sqrt(dx * dx + dy * dy + dz * dz)
        if far > 50 then c, d, how = lastGround, far, "the last ground you stood on" end
    end
    if not c then
        pcall(Hud.toast, "No open ground found nearby", 4)
        log("Options: unstuck found no ground near (%.0f %.0f %.0f)", from.X, from.Y, from.Z)
        return
    end
    pcall(function() p:K2_SetActorLocation(c, false, {}, true) end)
    pcall(function() p.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 } end)
    pcall(function() p.CharacterMovement:SetMovementMode(3, 0) end)
    lastMove = { at = os.clock(), dist = d }
    pcall(Hud.toast, string.format("Moved %.1f m to %s", d / 100, how), 4)
    log("Options: unstuck from (%.0f %.0f %.0f) to (%.0f %.0f %.0f), %.0f cm", from.X, from.Y, from.Z, c.X, c.Y, c.Z, d)
end

-- the last place the player stood on the ground with room around them
Core.every(1, function()
    if not live() then return end
    local p = World.player()
    if not p then
        lastGround = nil
        return
    end
    pcall(function()
        if p.CharacterMovement:IsMovingOnGround() ~= true or busyFlag(p) then return end
        local l = p:K2_GetActorLocation()
        local cap = p.CapsuleComponent
        if roomAt(p, l, cap:GetScaledCapsuleRadius() - 2, cap:GetScaledCapsuleHalfHeight() - 2) then
            lastGround = { X = l.X, Y = l.Y, Z = l.Z + 2 }
        end
    end)
end)

---------------------------------------------------------------- config.lua

local CONFIG = Core.MOD_DIR .. "/Scripts/config.lua"

-- Every setting the screen shows. `sync` = a switch of the Sync table (after a restart);
-- `zero` = what 0 means; `desc` = grey words under the name; `warn` = yellow words on a
-- group's title line, after its grey words.
local SETTINGS = {
    -- (the user: the storyline switch near the top, "it should be known that turning off is
    -- how quests will be shared")
    { group = "STORY", note = "after a restart; every player the same" },
    { key = "Story", sync = true, name = "Independent story",
        desc = "ON: every player has their own quests and level of the story. OFF: one storyline for everybody, the quests are shared." },
    { group = "CO-OP" },
    { key = "ShowPlayersOnMap", name = "Other players on the map" },
    { key = "PopulationPerExtraPlayer", name = "Street population per extra player", min = 0, max = 3, step = 0.1 },
    { key = "ClientsPerExtraPlayer", name = "Clients per extra player", min = 0, max = 3, step = 0.05 },
    { key = "OrderLimitMultiplier", name = "Eddie's order limit, times", min = 0.5, max = 5, step = 0.25 },
    { key = "OrderLimitPerExtraPlayer", name = "Eddie's order limit per extra player", min = 0, max = 3, step = 0.25 },
    { key = "SharedXpMultiplier", name = "Share of a partner's XP", min = 0, max = 1, step = 0.05 },
    { key = "MaxPlayers", name = "Players in a lobby", min = 2, max = 16, step = 1 },
    { key = "AutosaveMinutes", name = "Co-op autosave, minutes", min = 0, max = 60, step = 1, zero = "OFF" },
    { key = "AutosaveKeep", name = "Co-op autosaves kept", min = 1, max = 50, step = 1 },
    { key = "StoryCatchUpMinutes", name = "Steps done by others complete after, minutes", min = 0, max = 240, step = 5, zero = "NEVER" },
    { key = "InGameNotifications", name = "Lobby messages in the game" },
    { key = "NotifyRemoteXp", name = "Message for every XP from a partner" },
    { group = "GAME" },
    { key = "MaxLevel", name = "Highest level", min = 0, max = 300, step = 5, zero = "NONE" },
    { key = "PoliceDogs", name = "Police dogs" },
    { key = "PoliceDogChance", name = "Police dog chance", min = 0, max = 1, step = 0.05 },
    { key = "SoloExtras", name = "Card room, clothes shop, and extras in singleplayer" },
    { key = "CardRoomAlwaysOpen", name = "Club open at any hour" },
    { key = "Verbose", name = "Detailed log" },
    { group = "SYNC", note = "after a restart; every player the same",
        warn = "Switching these off is not thoroughly tested." },
    { key = "Police", sync = true, name = "Police chasing other players" },
    { key = "Time", sync = true, name = "Shared clock" },
    { key = "Objects", sync = true, name = "Containers, stashes, dead drops" },
    { key = "Homes", sync = true, name = "Hideouts" },
    { key = "Tags", sync = true, name = "Wall tags" },
    { key = "Spawns", sync = true, name = "Dropped items, placed furniture" },
    { key = "Clients", sync = true, name = "Clients" },
    { key = "Population", sync = true, name = "Passers-by and police patrols" },
    { key = "Money", sync = true, name = "Bank account, messages, contacts" },
    { key = "Orders", sync = true, name = "Orders, tasks, gang business" },
    { key = "Managers", sync = true, name = "Exposure, reputation, and sale areas" },
}

local fileValues = nil   -- what config.lua says right now (a table), read when the page is drawn

local function readFile()
    local f = io.open(CONFIG, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function evaluate(text)
    local fn = load(text, "=config.lua", "t", {})
    if not fn then return nil end
    local ok, t = pcall(fn)
    return ok and type(t) == "table" and t or nil
end

local function literal(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    if math.type(v) == "integer" or v == math.floor(v) then return string.format("%d", math.floor(v)) end
    return (string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", ""))
end

-- Writes one value into config.lua, keeping every comment and line as it is. `where` says
-- which table of the file the key is in: false = the file's own, true = Sync, a name =
-- that table (put at the end of the file when it is not there yet). Returns true when the
-- file has it afterwards.
local function writeValue(key, where, value)
    local tbl = where == true and "Sync" or (type(where) == "string" and where) or nil
    local text = readFile()
    if not text then return false end
    local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
    local entry = key .. " = " .. literal(value) .. ","
    local lines, inside, done = {}, nil, false      -- inside: the table of the file a line is in
    for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("([^\n]*)\n") do
        local body = line:gsub("\r$", "")
        local opened = body:match("^%s*([%a_][%w_]*)%s*=%s*{%s*$") or body:match("^%s*([%a_][%w_]*)%s*=%s*{%s*%-%-.*$")
        local empty = tbl and not inside and not done and body:match("^(%s*)" .. tbl .. "%s*=%s*{%s*},?%s*$")
        if empty then
            -- (the table on one line with nothing in it: opened up)
            lines[#lines + 1] = empty .. tbl .. " = {"
            lines[#lines + 1] = empty .. "    " .. entry
            body = empty .. "},"
            done = true
        elseif not inside and opened then
            inside = opened
        elseif inside and body:match("^%s*},?%s*$") then
            if inside == tbl and not done then
                lines[#lines + 1] = "        " .. entry
                done = true
            end
            inside = nil
        elseif not done and inside == tbl then
            local indent, name, rest = body:match("^(%s*)([%a_][%w_]*)%s*=%s*(.-)$")
            if name == key and (tbl or #indent <= 4) then
                local tail = rest:match("^[^,]-(,.*)$") or ","
                body = indent .. name .. " = " .. literal(value) .. tail
                done = true
            end
        end
        lines[#lines + 1] = body
    end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    -- what the file does not have yet goes in before its closing brace: a setting of its
    -- own as a line, a table with the setting in it
    if not done and tbl ~= "Sync" then
        for i = #lines, 1, -1 do
            if lines[i]:match("^}") then
                if tbl then
                    table.insert(lines, i, "    },")
                    table.insert(lines, i, "        " .. entry)
                    table.insert(lines, i, "    " .. tbl .. " = {")
                else
                    table.insert(lines, i, "    " .. entry)
                end
                done = true
                break
            end
        end
    end
    if not done then return false end
    local out = table.concat(lines, eol) .. eol
    local t = evaluate(out)
    local now = nil
    if t and tbl then
        if type(t[tbl]) == "table" then now = t[tbl][key] end
    elseif t then
        now = t[key]
    end
    if now ~= value then
        log("Options: config.lua would not have read %s%s = %s; nothing written", tbl and (tbl .. ".") or "", key, literal(value))
        return false
    end
    local tmp = CONFIG .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(out)
    f:close()
    os.remove(CONFIG .. ".bak")
    os.rename(CONFIG, CONFIG .. ".bak")
    local ok = os.rename(tmp, CONFIG)
    if not ok then
        os.rename(CONFIG .. ".bak", CONFIG)
        return false
    end
    os.remove(CONFIG .. ".bak")
    return true
end

local function current(s)
    if s.sync then
        local file = fileValues and type(fileValues.Sync) == "table" and fileValues.Sync[s.key]
        if file == nil then file = Core.enabled(s.key) end
        return file
    end
    local v = Core.config[s.key]
    if v == nil and fileValues then v = fileValues[s.key] end
    return v
end

local function set(s, value)
    if not writeValue(s.key, s.sync == true, value) then
        pcall(Hud.toast, "config.lua could not be written", 4)
        return
    end
    if s.sync then
        fileValues = evaluate(readFile() or "") or fileValues
    else
        Core.config[s.key] = value
    end
    log("Options: %s%s = %s", s.sync and "Sync." or "", s.key, literal(value))
end

---------------------------------------------------------------- the screen

local render

local function close()
    local s = scr
    scr, drawn = nil, {}
    if s and s.open then pcall(s.close) end
end

local function put(column, widget, bottom, top)
    local slot = column:AddChildToVerticalBox(widget)
    slot:SetPadding({ Left = 0, Top = top or 0, Right = 0, Bottom = bottom or 0 })
    return slot
end


-- A row: words on the left (a name and, under it, smaller grey words), controls on the right.
local function row(inner, name, sub, controls, subColor)
    local h = scr.new("HorizontalBox")
    local words = scr.new("VerticalBox")
    words:AddChildToVerticalBox(scr.text(name, "name", 19))
    if sub and sub ~= "" then
        local t = scr.text(sub, "small", 14, subColor or Screen.GREY)
        pcall(function() t:SetAutoWrapText(true) end)
        words:AddChildToVerticalBox(t):SetPadding({ Left = 0, Top = 3, Right = 0, Bottom = 0 })
    end
    local ws = h:AddChildToHorizontalBox(words)
    ws:SetSize({ SizeRule = 1, Value = 1 })
    ws:SetVerticalAlignment(2)
    ws:SetPadding({ Left = 0, Top = 0, Right = 24, Bottom = 0 })
    for _, c in ipairs(controls or {}) do
        local cs = h:AddChildToHorizontalBox(c)
        cs:SetVerticalAlignment(2)
    end
    local box = scr.box(ROW_BG, h)
    box:SetPadding({ Left = 18, Top = 10, Right = 18 - BUTTON_INSET, Bottom = 10 })
    put(inner, box, 6)
end

-- A group's title, with grey words after it and a yellow warning after those, on one line.
local function group(inner, title, note, first, warn)
    local h = scr.new("HorizontalBox")
    h:AddChildToHorizontalBox(scr.text(title, "button", 17, Screen.GREY)):SetVerticalAlignment(2)
    if note then
        local n = h:AddChildToHorizontalBox(scr.text(note, "small", 14, Screen.GREY))
        n:SetVerticalAlignment(2)
        n:SetPadding({ Left = 16, Top = 0, Right = 0, Bottom = 0 })
    end
    if warn then
        local w = h:AddChildToHorizontalBox(scr.text(warn, "small", 14, YELLOW))
        w:SetVerticalAlignment(2)
        w:SetPadding({ Left = 16, Top = 0, Right = 0, Bottom = 0 })
    end
    put(inner, h, 8, first and 0 or 14)
end

local function emptyLine(inner, text)
    put(inner, scr.text(text, "name", 18, Screen.GREY), 0, 6)
end


-- QUESTS: every open story step with RELOAD, which sets the step up again for the player
-- to do (nothing is completed, so nobody is asked).
local function reloadPage(inner)
    local any = false
    local function reloaded(name, done)
        local what = (done and #done > 0) and (": " .. table.concat(done, ", ")) or ""
        pcall(Hud.toast, string.format('"%s" reloaded%s', name, what), 6)
        Core.after(1, function() if scr then render() end end)
    end
    if World.player() and Core.find("questManager_C") then
        for _, step in ipairs(Story.openSteps()) do
            any = true
            local b = scr.button("RELOAD", nil, function()
                local name, done = Story.reload(step.id, step.name)
                if name then reloaded(name, done) end
            end)
            local label = step.name ~= "" and step.name or step.desc
            row(inner, label, step.name ~= "" and step.desc or nil, { b.widget })
        end
    end
    local Quest = wall()
    if Quest and Quest.reload then
        any = true
        local b = scr.button("RELOAD", nil, function()
            if Quest.reload() then reloaded(Quest.TITLE) end
        end)
        row(inner, Quest.TITLE, Quest.goal and Quest.goal() or nil, { b.widget })
    end
    if not any then emptyLine(inner, "No open story steps.") end
end

local function repairPage(inner)
    local redraw = scr.button("REDRAW", nil, function()
        local n = Sync.redrawAll()
        pcall(Hud.toast, string.format("%d jars, boxes and bags drawn again", n), 4)
    end)
    row(inner, "Redraw jars, boxes and packages", nil, { redraw.widget })
    if World.shared() then
        local guest = World.role == "guest"
        local b = scr.button("RESYNC", nil, function()
            if Sync.resyncAll() then
                pcall(Hud.toast, guest and "Asked the host for everything again" or "Sending everything to every guest again", 4)
            end
        end)
        row(inner, guest and "Resync with the host" or "Resync every guest", nil, { b.widget })
    end
    -- dealers and clients that have stopped answering (coop/clients.lua): done by the game
    -- that runs the sales, the host's
    local Clients = package.loaded["coop.clients"]
    if type(Clients) == "table" and Clients.ask then
        local fix = scr.button("FIX", nil, function() Clients.ask() end)
        row(inner, "Repair dealers and clients that stopped answering", "A dealer who never reports his cash, a client who never orders again", { fix.widget })
    end
    local move = scr.button("UNSTUCK", nil, function()
        close()
        Core.after(0.1, unstuck)
    end)
    row(inner, "Unstuck: move to the nearest open, flat ground", "Press again to go further", { move.widget })
end

local function valueText(s, v)
    if type(v) == "boolean" then return v and "ON" or "OFF" end
    if type(v) ~= "number" then return tostring(v) end
    if v == 0 and s.zero then return s.zero end
    return literal(v)
end

local function settingsPage(inner)
    fileValues = evaluate(readFile() or "") or fileValues
    local first = true
    for _, s in ipairs(SETTINGS) do
        if s.group then
            group(inner, s.group, s.note, first, s.warn)
            first = false
        else
            local v = current(s)
            local controls = {}
            local sub, subColor = s.desc, nil
            if s.sync and v ~= Core.enabled(s.key) then
                sub, subColor = (s.desc and (s.desc .. "  ") or "") .. "Changes after a restart.", YELLOW
            end
            if s.min then
                v = tonumber(v) or s.min
                local function nudge(dir)
                    return function()
                        local n = math.floor((v + dir * s.step) / s.step + 0.5) * s.step
                        n = math.max(s.min, math.min(s.max, n))
                        if s.step >= 1 then n = math.floor(n + 0.5) else n = math.floor(n * 100 + 0.5) / 100 end
                        if n ~= v then
                            set(s, n)
                            render()
                        end
                    end
                end
                local minus = scr.button("-", nil, nudge(-1))
                local plus = scr.button("+", nil, nudge(1))
                if v <= s.min then scr.enable(minus, false) end
                if v >= s.max then scr.enable(plus, false) end
                local value = scr.text(valueText(s, v), "price", 18)
                local vb = scr.sized(nil, 92)
                local center = scr.new("HorizontalBox")
                center:AddChildToHorizontalBox(value):SetHorizontalAlignment(2)
                vb:AddChild(center)
                pcall(function() center.Slot:SetHorizontalAlignment(2) end)
                controls = { minus.widget, vb, plus.widget }
            else
                local on = v ~= false
                local b = scr.button(on and "ON" or "OFF", nil, function()
                    set(s, not on)
                    render()
                end)
                scr.tint(b, on and Screen.GREEN or Screen.GREY)
                controls = { b.widget }
            end
            row(inner, s.name, sub, controls, subColor)
        end
    end
end

-- EXPERIMENTAL: the features of coop/experimental.lua that are not fully tested yet, each
-- with its switch (off until the player switches it on).
local function experimentalPage(inner)
    Experimental.page({
        scr = scr, inner = inner, row = row, put = put, emptyLine = emptyLine, YELLOW = YELLOW,
        write = writeValue,
        render = function() render() end,
        file = function() return evaluate(readFile() or "") end,
    })
end

local TABS = { { "settings", "SETTINGS" }, { "repair", "REPAIR" }, { "quests", "QUESTS" },
    { "experimental", "EXPERIMENTAL" } }

render = function()
    if not scr or not scr.open then return end
    -- (the same page drawn again keeps where it was scrolled to)
    local scroll = 0
    if scr.list and Options.tab == scr.listTab then pcall(function() scroll = scr.list:GetScrollOffset() end) end
    scr.list = nil
    scr.removeAll(drawn)
    drawn = {}
    local U, H = scr.units()
    local W = math.floor(math.min(1200, U * 0.7))

    local column = scr.new("VerticalBox")
    local head = scr.new("HorizontalBox")
    local title = head:AddChildToHorizontalBox(scr.text("MOD OPTIONS", "button", 30))
    title:SetSize({ SizeRule = 1, Value = 1 })
    title:SetVerticalAlignment(2)
    local version = head:AddChildToHorizontalBox(scr.text("v" .. tostring(Core.VERSION), "small", 14, Screen.GREY))
    version:SetVerticalAlignment(2)
    version:SetPadding({ Left = 0, Top = 0, Right = 24, Bottom = 0 })
    local x = scr.bigButton("X", 1.3, close)
    scr.tint(x, Screen.RED)
    local xs = head:AddChildToHorizontalBox(x.box)
    xs:SetVerticalAlignment(2)
    xs:SetPadding({ Left = 0, Top = 0, Right = -BUTTON_INSET * 1.3, Bottom = 0 })
    put(column, scr.sized(head, W), 10):SetHorizontalAlignment(1)

    local line = scr.box(ACCENT, scr.sized(nil, W, 2))
    put(column, line, 14):SetHorizontalAlignment(1)

    local bar = scr.new("HorizontalBox")
    for i, t in ipairs(TABS) do
        local b = scr.bigButton(t[2], 1.3, function()
            if Options.tab ~= t[1] then
                Options.tab = t[1]
                render()
            end
        end)
        if Options.tab == t[1] then scr.tint(b, Screen.GREEN) end
        bar:AddChildToHorizontalBox(b.box):SetPadding({ Left = i > 1 and 36 or 0, Top = 0, Right = 0, Bottom = 0 })
    end
    local bs = column:AddChildToVerticalBox(bar)
    bs:SetPadding({ Left = -BUTTON_INSET * 1.3, Top = 0, Right = 0, Bottom = 16 })

    -- A page taller than the room has a scroll bar, which takes its width from the rows:
    -- such a page is drawn again as wide as the rows plus the bar (the bar right of the
    -- red line's end), so that every page's rows end under the end of the red line.
    local scrollBox = scr.new("ScrollBox")
    local inner = scr.new("VerticalBox")
    scrollBox:AddChild(inner)
    scr.overflow = scr.overflow or {}
    local over = scr.overflow[Options.tab] == true
    local ls = column:AddChildToVerticalBox(scr.sized(scrollBox, over and W + BAR or W, math.floor(H * 0.6)))
    scr.list, scr.listTab, scr.listInner, scr.listHeight = scrollBox, Options.tab, inner, math.floor(H * 0.6)

    -- (the user: "show toast that settings are only for host")
    if Options.tab == "settings" and scr.toldTab ~= "settings" and World.active and World.role == "guest" then
        pcall(Hud.toast, "Settings are the host's: changed here, most of them only count when you host", 6)
    end
    scr.toldTab = Options.tab

    local ok, e = xpcall(function()
        if Options.tab == "quests" then reloadPage(inner)
        elseif Options.tab == "repair" then repairPage(inner)
        elseif Options.tab == "experimental" then experimentalPage(inner)
        else settingsPage(inner) end
    end, debug.traceback)
    if not ok then log("Options: the %s page: %s", Options.tab, tostring(e)) end

    scr.place(column, 0.5, 0.5, 0, 0)
    drawn = { column }
    if scroll > 0 then pcall(function() scrollBox:SetScrollOffset(scroll) end) end
    local s, tab = scr, Options.tab
    Core.after(0.1, function()
        if scr ~= s or not s.open or Options.tab ~= tab or s.list == nil then return end
        -- (the rows' own height against the room they have)
        local ok, taller = pcall(function() return s.listInner:GetDesiredSize().Y > s.listHeight + 1 end)
        if ok and type(taller) == "boolean" and taller ~= over then
            s.overflow[tab] = taller
            render()
        end
    end)
end

function Options.open(tab)
    if not live() or World.gone or World.joining then return false end
    local player = World.player()
    if not player then return false end
    if Screen.current and Screen.current ~= scr then return false end      -- another of the mod's screens
    -- (a fresh screen starts on SETTINGS)
    if tab then Options.tab = tab elseif not scr then Options.tab = "settings" end
    if scr then
        render()
        return true
    end
    local s = Screen.open()
    if not s then return false end
    scr, drawn = s, {}
    s.onClose = function()
        if scr == s then scr, drawn = nil, {} end
    end
    s.fill(s.box({ R = 0, G = 0, B = 0, A = 0.9 }), 0)
    render()
    return true
end

function Options.close() close() end
Options.unstuck = unstuck
function Options.isOpen() return scr ~= nil end
Options.writeValue, Options.SETTINGS = writeValue, SETTINGS

Options.render = function() if scr then render() end end

-- From the pause menu: the game goes on (the pause menu closes the way its RESUME does),
-- then the screen opens.
function Options.fromPause()
    local player = World.player()
    if not player then return end
    pcall(function() player:resumeGame() end)
    Core.after(0.15, function()
        if not live() then return end
        local ok, e = pcall(Options.open)
        if not ok then log("Options: %s", tostring(e)) end
    end)
end

-- Escape opens the game's pause menu over the screen: the screen gives way to it.
Core.onTick(function()
    if not live() or not scr then return end
    local player = World.player()
    if not player then return end
    local menu = nil
    pcall(function() menu = player.pauseMenu end)
    local up = false
    pcall(function() up = valid(menu) and menu:IsInViewport() end)
    if not up then return end
    close()
    pcall(function()
        local pc = player:GetController()
        StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameAndUIEx(pc, menu, 2, false)
        pc.bShowMouseCursor = true
    end)
end)

if Core.bindKey then
    Core.bindKey(Core.config.ModOptionsKey or "F9", function()

        if not live() then return end
        if scr then
            close()
            return
        end
        local player = World.player()
        local paused = false
        pcall(function() paused = valid(player.pauseMenu) and player.pauseMenu:IsInViewport() end)
        if player and not paused then pcall(Options.open) end
    end)
end

return Options
