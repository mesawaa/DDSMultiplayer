-- MOD OPTIONS: the mod's own screen for getting a game unstuck, in the game.
--
-- Opened from the pause menu (its MOD OPTIONS entry) or with ModOptionsKey. Three pages:
--
--   QUESTS    the story steps open for this player, and the step of Olivia's wall, each
--             with SKIP (clicked twice). In a shared world every other player in it has
--             to allow a skip first (ALLOW / DENY on this page; they are told to open it);
--             one DENY, or no answer within VOTE_SECONDS, and nothing is skipped. A step
--             is completed the way the game completes it, so what comes after it starts
--             as usual. Every player in the world is told who skipped what. With one storyline for everybody (Sync.Story = false)
--             a guest's skip is done by the host, whose game runs that storyline.
--   REPAIR    draw jars, boxes and bags again; ask for the whole shared state again (a
--             guest from the host, the host for every guest); give the controls back.
--   SETTINGS  the settings of config.lua, written into that file. Most take effect at
--             once; the Sync switches after a restart (every player should have the same).

local Core = require("core")
local Net = require("net")
local World = require("coop.world")
local Screen = require("coop.screen")
local Hud = require("coop.hud")
local Story = require("coop.story")
local Sync = require("coop.sync")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_OPTIONS_GEN") or 0) + 1
_G.DDSMP_OPTIONS_GEN = GEN
local function live() return rawget(_G, "DDSMP_OPTIONS_GEN") == GEN end

local Options = { tab = "quests" }

local scr = nil          -- the open screen
local drawn = {}         -- what the page put on it
local armed = {}         -- action -> when its first click was (a second one within ARM does it)
local ARM = 6
local BUTTON_INSET = 10.5
local BAR = 18            -- the room a scroll bar takes
local ROW_BG = { R = 0.03, G = 0.03, B = 0.035, A = 0.95 }
local ACCENT = { R = 0.55, G = 0.02, B = 0.02, A = 1 }
local YELLOW = { R = 0.95, G = 0.75, B = 0.2, A = 1 }

---------------------------------------------------------------- telling everybody

-- Shows `text` after the name of whoever did it, in every game of the world. `from` is
-- the player who did it; `except` is a game that has already shown it.
local function announce(from, text, except)
    local me = Net.S.me
    pcall(Hud.toast, (from == me and "You" or Net.name(from)) .. " " .. text, 7)
    log("Options: %s %s", from == me and "this player" or "a player", text)
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= except then Net.send("mox", { x = text, p = from }, id) end
        end
    elseif World.role == "guest" and from == me then
        Net.send("mox", { x = text }, World.host or Net.S.owner)
    end
end

Net.on("mox", function(sender, data)
    if not live() or not World.active or type(data.x) ~= "string" or #data.x > 200 then return end
    if World.role == "host" then
        if not World.inWorld[sender] then return end
        announce(sender, data.x, sender)
    elseif World.role == "guest" and sender == (World.host or Net.S.owner) then
        local who = data.p ~= nil and data.p or sender
        pcall(Hud.toast, (who == Net.S.me and "You" or Net.name(who)) .. " " .. data.x, 7)
        log("Options: told that %s %s", who == Net.S.me and "this player" or "a player", data.x)
    end
end)

---------------------------------------------------------------- skipping

local function stepWords(name) return string.format('skipped the story step "%s"', name) end

-- With one storyline for everybody the host's game runs it: a guest asks the host.
local function remoteStory()
    return World.active and World.role == "guest" and Core.enabled("Orders") and not Core.enabled("Story")
end

local approvedAt = {}     -- (host) player -> when the others last allowed one of their skips

Net.on("skq", function(sender, data)
    if not live() or World.role ~= "host" or not World.inWorld[sender] then return end
    if os.clock() - (approvedAt[sender] or -1000) > 30 then
        log("Options: a skip from a guest that nobody allowed was ignored")
        return
    end
    approvedAt[sender] = nil
    if type(data.i) ~= "number" or type(data.n) ~= "string" then return end
    local name = Story.skip(math.floor(data.i), data.n)
    if name then announce(sender, stepWords(name)) end
end)

local function wall()
    local Quest = package.loaded["coop.wallquest"]
    if type(Quest) ~= "table" or not Quest.state or not Quest.state() then return nil end
    local s = Quest.step()
    if s < Quest.ASK or s > Quest.TELL then return nil end
    return Quest
end

local function skipStep(step)
    if remoteStory() then
        Net.send("skq", { i = step.id, n = step.name }, World.host or Net.S.owner)
        log("Options: asked the host to skip step %d", step.id)
        return
    end
    local name = Story.skip(step.id, step.name)
    if name then announce(Net.S.me, stepWords(name)) end
end

local function skipWall()
    local Quest = wall()
    if not Quest then return end
    local from = Quest.step()
    Quest.advance(from + 1)
    announce(Net.S.me, string.format('skipped a step of "%s"', Quest.TITLE))
end

---------------------------------------------------------------- asking the others first

-- The host keeps the votes. A request: { rid, from, name, need = { id = true },
-- yes = { id = true }, at }. Every game has a copy of the open ones (`requests`), with
-- `asked` when this game's player has to answer and `answer` once they have.
local VOTE_SECONDS = 60
local requests = {}
local asking = nil        -- this player's own request: { rid, name, go, at }
local counter = 0

local function rerender()
    Core.after(0.05, function() if scr and Options.render then Options.render() end end)
end

local function idList(set)
    local out = {}
    for id in pairs(set) do out[#out + 1] = id end
    return out
end

local function toGuests(kind, data)
    if World.role ~= "host" then return end
    for id in pairs(World.inWorld) do Net.send(kind, data, id) end
end

local function askLine(r)
    return string.format('%s wants to skip "%s". Answer in MOD OPTIONS (%s)', Net.name(r.from), r.name,
        tostring(Core.config.ModOptionsKey or "F9"))
end

-- What every game does when a request ends. `by`: who said no ("time": not everybody
-- answered in time, "left": the asking player left).
local function ended(rid, ok, by)
    local r = requests[rid]
    requests[rid] = nil
    if asking and asking.rid == rid then
        local mine = asking
        asking = nil
        if ok then
            log("Options: the others allowed the skip of \"%s\"", mine.name)
            local done, e = pcall(mine.go)
            if not done then log("Options: the skip failed: %s", tostring(e)) end
        elseif by == "time" then
            pcall(Hud.toast, string.format('Not everybody answered: "%s" was not skipped', mine.name), 6)
        else
            pcall(Hud.toast, string.format('%s said no: "%s" was not skipped', by and Net.name(by) or "Somebody", mine.name), 6)
        end
    elseif r and not ok and r.asked then
        pcall(Hud.toast, string.format('The skip of "%s" was called off', r.name), 4)
    end
    rerender()
end

local function finish(r, ok, by)
    if World.role ~= "host" then return end
    if ok and r.from ~= Net.S.me then approvedAt[r.from] = os.clock() end
    log("Options: the skip of \"%s\" %s", r.name, ok and "was allowed by everybody" or ("was not allowed (" .. tostring(by) .. ")"))
    toGuests("skd", { r = r.rid, ok = ok, b = by })
    ended(r.rid, ok, by)
end

local function check(r)
    for id in pairs(r.need) do
        if not r.yes[id] then return end
    end
    finish(r, true)
end

-- A request comes in (or is made) here.
local function seen(rid, from, name, need)
    local r = { rid = rid, from = from, name = name, at = os.clock(), asked = need[Net.S.me] == true }
    requests[rid] = r
    if r.asked then
        pcall(Hud.toast, askLine(r), 8)
        r.toldAt = os.clock()
    end
    rerender()
    return r
end

local function openRequest(from, c, name)
    local rid = tostring(from) .. ":" .. tostring(c)
    local need = {}
    if from ~= Net.S.me then need[Net.S.me] = true end
    for id in pairs(World.inWorld) do
        if id ~= from then need[id] = true end
    end
    local r = seen(rid, from, name, need)
    r.need, r.yes = need, {}
    log("Options: %s asks to skip \"%s\"; %d to answer", from == Net.S.me and "this player" or "a player", name, #idList(need))
    toGuests("skv", { r = rid, p = from, n = name, w = idList(need) })
    check(r)
end

local function vote(voter, rid, yes)
    local r = requests[rid]
    if World.role ~= "host" or not r or not r.need or not r.need[voter] then return end
    log("Options: %s %s the skip of \"%s\"", voter == Net.S.me and "this player" or "a player", yes and "allowed" or "denied", r.name)
    if not yes then
        finish(r, false, voter)
        return
    end
    r.yes[voter] = true
    toGuests("sky", { r = rid, p = voter })
    if r.from == Net.S.me then pcall(Hud.toast, Net.name(voter) .. " allowed the skip", 3) end
    check(r)
end

Net.on("skr", function(sender, data)
    if not live() or World.role ~= "host" or not World.inWorld[sender] then return end
    if type(data.c) ~= "number" or type(data.n) ~= "string" or #data.n > 120 then return end
    openRequest(sender, data.c, data.n)
end)
Net.on("ska", function(sender, data)
    if not live() or World.role ~= "host" or not World.inWorld[sender] or type(data.r) ~= "string" then return end
    vote(sender, data.r, data.a == true)
end)
Net.on("skv", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) then return end
    if type(data.r) ~= "string" or type(data.n) ~= "string" or type(data.w) ~= "table" then return end
    local need = {}
    for _, id in ipairs(data.w) do need[tostring(id)] = true end
    seen(data.r, tostring(data.p), data.n, need)
    log("Options: told that a player asks to skip \"%s\"%s", data.n, need[Net.S.me] and " (this player is asked)" or "")
end)
Net.on("sky", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) then return end
    if asking and asking.rid == data.r and data.p ~= Net.S.me then pcall(Hud.toast, Net.name(data.p) .. " allowed the skip", 3) end
end)
Net.on("skd", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) or type(data.r) ~= "string" then return end
    log("Options: the skip request %s ended: %s", data.r, data.ok == true and "allowed" or ("not allowed, " .. tostring(data.b)))
    ended(data.r, data.ok == true, data.b)
end)

-- The other players are asked; `go` does the skip once every one of them has allowed it.
-- Alone in the world it is done at once.
local function askSkip(name, go)
    if not World.shared() then
        go()
        return true
    end
    if asking then
        pcall(Hud.toast, "Wait for the answer to your last skip", 3)
        return false
    end
    counter = counter + 1
    asking = { rid = tostring(Net.S.me) .. ":" .. counter, name = name, go = go, at = os.clock() }
    pcall(Hud.toast, string.format('Asking the others to allow skipping "%s"', name), 5)
    if World.role == "host" then
        openRequest(Net.S.me, counter, name)
    else
        Net.send("skr", { c = counter, n = name }, World.host or Net.S.owner)
    end
    rerender()
    return true
end

local function answer(rid, yes)
    local r = requests[rid]
    if not r or not r.asked or r.answer ~= nil then return end
    r.answer = yes
    if World.role == "host" then
        vote(Net.S.me, rid, yes)
    else
        Net.send("ska", { r = rid, a = yes }, World.host or Net.S.owner)
    end
    rerender()
end

Core.every(1, function()
    if not live() then return end
    local now = os.clock()
    if not World.active then
        requests, asking = {}, nil
        return
    end
    for rid, r in pairs(requests) do
        if World.role == "host" and r.need and now - r.at > VOTE_SECONDS then
            finish(r, false, "time")
        elseif World.role ~= "host" and now - r.at > VOTE_SECONDS + 15 then
            requests[rid] = nil           -- (the host is gone or never said)
            rerender()
        elseif r.asked and r.answer == nil and now - (r.toldAt or 0) > 20 then
            r.toldAt = now
            pcall(Hud.toast, askLine(r), 8)
        end
    end
    if asking and now - asking.at > VOTE_SECONDS + 20 then
        asking = nil
        rerender()
    end
end)

World.listen("peerleft", function(id)
    if not live() or World.role ~= "host" then return end
    id = tostring(id)
    for _, r in pairs(requests) do
        if r.need then
            if r.from == id then
                finish(r, false, "left")
            elseif r.need[id] then
                r.need[id] = nil
                check(r)
            end
        end
    end
end)

---------------------------------------------------------------- repairs

local function resetControls()
    local player = World.player()
    if not player then return end
    local pc = player:GetController()
    local busy = false
    for _, f in ipairs({ "inventoryOpen", "phoneUp", "computerOpen", "mapOpen", "saveScreenOpen", "isTrading", "inDialogue" }) do
        pcall(function() if player[f] == true then busy = true end end)
    end
    pcall(function() if not busy then player.disableWorldInteraction = false end end)
    pcall(function()
        StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(pc)
        pc.bShowMouseCursor = false
        pc:ResetIgnoreInputFlags()
    end)
    log("Options: controls given back%s", busy and " (a window of the game is open: left alone)" or "")
end

---------------------------------------------------------------- config.lua

local CONFIG = Core.MOD_DIR .. "/Scripts/config.lua"

-- Every setting the screen shows. `sync` = a switch of the Sync table (after a restart);
-- `zero` = what 0 means.
local SETTINGS = {
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
    { key = "SoloExtras", name = "Card room, clothes shops and wardrobe in single player" },
    { key = "Casino", name = "Card room" },
    { key = "CardRoomAlwaysOpen", name = "Club open at any hour" },
    { key = "EmoteThirdPerson", name = "Emotes switch to the view from behind" },
    { key = "FemaleVoicePitch", name = "Woman's voice, pitch", min = 0.8, max = 1.6, step = 0.05 },
    { key = "FemaleVoiceClimbPitch", name = "Woman's voice, pitch when climbing", min = 0.8, max = 1.6, step = 0.05 },
    { key = "FemaleVoiceVolume", name = "Woman's voice, volume", min = 0, max = 1, step = 0.05 },
    { key = "Verbose", name = "Detailed log" },
    { group = "SYNC", note = "after a restart; every player the same" },
    { key = "World", sync = true, name = "Guests load the host's world" },
    { key = "Avatars", sync = true, name = "Other players' characters" },
    { key = "Police", sync = true, name = "Police chasing other players" },
    { key = "Time", sync = true, name = "Shared clock" },
    { key = "Doors", sync = true, name = "Doors" },
    { key = "Objects", sync = true, name = "Containers, stashes, dead drops" },
    { key = "Homes", sync = true, name = "Hideouts" },
    { key = "Tags", sync = true, name = "Wall tags" },
    { key = "Spawns", sync = true, name = "Dropped items, placed furniture" },
    { key = "Clients", sync = true, name = "Clients" },
    { key = "Population", sync = true, name = "Passers-by and police patrols" },
    { key = "Money", sync = true, name = "Bank account, messages, contacts" },
    { key = "Orders", sync = true, name = "Orders, tasks, gang business" },
    { key = "Story", sync = true, name = "A storyline of their own for every player" },
    { key = "Managers", sync = true, name = "Exposure, sale areas and the rest" },
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

-- Writes one value into config.lua, keeping every comment and line as it is. Returns true
-- when the file has it afterwards.
local function writeValue(key, isSync, value)
    local text = readFile()
    if not text then return false end
    local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
    local lines, inSync, done = {}, false, false
    for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("([^\n]*)\n") do
        local body = line:gsub("\r$", "")
        if body:match("^%s*Sync%s*=%s*{") then
            inSync = true
        elseif inSync and body:match("^%s*},?%s*$") then
            if isSync and not done then
                lines[#lines + 1] = "        " .. key .. " = " .. literal(value) .. ","
                done = true
            end
            inSync = false
        elseif not done and inSync == isSync then
            local indent, name, rest = body:match("^(%s*)([%a_][%w_]*)%s*=%s*(.-)$")
            if name == key and (isSync or #indent <= 4) then
                local tail = rest:match("^[^,]-(,.*)$") or ","
                body = indent .. name .. " = " .. literal(value) .. tail
                done = true
            end
        end
        lines[#lines + 1] = body
    end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    -- a setting the file does not have yet goes in before its closing brace
    if not done and not isSync then
        for i = #lines, 1, -1 do
            if lines[i]:match("^}") then
                table.insert(lines, i, "    " .. key .. " = " .. literal(value) .. ",")
                done = true
                break
            end
        end
    end
    if not done then return false end
    local out = table.concat(lines, eol) .. eol
    local t = evaluate(out)
    local now = t and (isSync and type(t.Sync) == "table" and t.Sync[key] or t[key])
    if now ~= value then
        log("Options: config.lua would not have read %s = %s; nothing written", key, literal(value))
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
    scr, drawn, armed = nil, {}, {}
    if s and s.open then pcall(s.close) end
end

local function put(column, widget, bottom, top)
    local slot = column:AddChildToVerticalBox(widget)
    slot:SetPadding({ Left = 0, Top = top or 0, Right = 0, Bottom = bottom or 0 })
    return slot
end

-- A button that asks once more before it does anything.
local function confirmButton(id, label, fn)
    local hot = armed[id] and os.clock() - armed[id] < ARM
    local b = scr.button(hot and "CLICK AGAIN" or label, nil, function()
        if armed[id] and os.clock() - armed[id] < ARM then
            armed = {}
            fn()
        else
            armed = { [id] = os.clock() }
            Core.after(ARM + 0.1, function()
                if scr and armed[id] and os.clock() - armed[id] >= ARM then
                    armed[id] = nil
                    render()
                end
            end)
        end
        render()
    end)
    if hot then scr.tint(b, Screen.RED) end
    return b
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

local function group(inner, title, note, first)
    local h = scr.new("HorizontalBox")
    h:AddChildToHorizontalBox(scr.text(title, "button", 17, Screen.GREY)):SetVerticalAlignment(2)
    if note then
        local n = h:AddChildToHorizontalBox(scr.text(note, "small", 14, Screen.GREY))
        n:SetVerticalAlignment(2)
        n:SetPadding({ Left = 16, Top = 0, Right = 0, Bottom = 0 })
    end
    put(inner, h, 8, first and 0 or 14)
end

local function emptyLine(inner, text)
    put(inner, scr.text(text, "name", 18, Screen.GREY), 0, 6)
end

local function waiting()
    local b = scr.button("WAITING", nil, function() end)
    scr.enable(b, false)
    return b
end

local function questsPage(inner)
    -- other players' skips this player is asked about
    local list = {}
    for _, r in pairs(requests) do
        if r.asked then list[#list + 1] = r end
    end
    table.sort(list, function(a, b) return a.at < b.at end)
    if #list > 0 then
        group(inner, "SKIPS TO ANSWER", nil, true)
        for _, r in ipairs(list) do
            local controls = {}
            if r.answer == nil then
                local yes = scr.button("ALLOW", nil, function() answer(r.rid, true) end)
                scr.tint(yes, Screen.GREEN)
                local no = scr.button("DENY", nil, function() answer(r.rid, false) end)
                scr.tint(no, Screen.RED)
                controls = { yes.widget, no.widget }
            else
                local b = scr.button(r.answer and "ALLOWED" or "DENIED", nil, function() end)
                scr.enable(b, false)
                controls = { b.widget }
            end
            row(inner, Net.name(r.from) .. " wants to skip", r.name, controls)
        end
        group(inner, "YOUR STEPS")
    end
    local any = false
    local function after()
        Core.after(1.6, function() if scr then render() end end)
        Core.after(4, function() if scr then render() end end)
    end
    if World.player() and Core.find("questManager_C") then
        for _, step in ipairs(Story.openSteps()) do
            any = true
            local label = step.name ~= "" and step.name or step.desc
            local b = (asking and asking.name == label) and waiting() or confirmButton("step" .. step.id, "SKIP", function()
                askSkip(label, function()
                    skipStep(step)
                    after()
                end)
            end)
            row(inner, label, step.name ~= "" and step.desc or nil, { b.widget })
        end
    end
    local Quest = wall()
    if Quest then
        any = true
        local label = Quest.TITLE
        local b = (asking and asking.name == label) and waiting() or confirmButton("wall", "SKIP", function()
            askSkip(label, function()
                skipWall()
                Core.after(0.5, function() if scr then render() end end)
            end)
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
    local reset = scr.button("RESET", nil, function()
        close()
        Core.after(0.1, resetControls)
    end)
    row(inner, "Give back the controls", nil, { reset.widget })
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
            group(inner, s.group, s.note, first)
            first = false
        else
            local v = current(s)
            local controls = {}
            local sub, subColor = nil, nil
            if s.sync and v ~= Core.enabled(s.key) then sub, subColor = "after a restart", YELLOW end
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

local TABS = { { "quests", "QUESTS" }, { "repair", "REPAIR" }, { "settings", "SETTINGS" } }

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
                Options.tab, armed = t[1], {}
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

    local ok, e = xpcall(function()
        if Options.tab == "quests" then questsPage(inner)
        elseif Options.tab == "repair" then repairPage(inner)
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
    if tab then Options.tab = tab end
    if scr then
        render()
        return true
    end
    local s = Screen.open()
    if not s then return false end
    scr, drawn, armed = s, {}, {}
    s.onClose = function()
        if scr == s then scr, drawn, armed = nil, {}, {} end
    end
    s.fill(s.box({ R = 0, G = 0, B = 0, A = 0.9 }), 0)
    render()
    return true
end

function Options.close() close() end
function Options.isOpen() return scr ~= nil end
Options.writeValue, Options.SETTINGS = writeValue, SETTINGS
Options.skipStep, Options.skipWall, Options.askSkip, Options.answer = skipStep, skipWall, askSkip, answer
function Options.requests() return requests end
function Options.asking() return asking end

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
