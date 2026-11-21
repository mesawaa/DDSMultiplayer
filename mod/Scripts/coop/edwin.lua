-- Edwin, behind the bar of the night club.
--
-- He stands behind the counter with his music in his ears, walking on the spot. For a few
-- dollars he puts on the song a player picks: it plays at once on the club's speaker, for
-- everybody (coop/casino.lua plays the club's music; the songs to pick from are the ones it
-- plays by itself). Every game puts its own Edwin there; nothing of him is saved.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Hud = require("coop.hud")
local Look = require("coop.look")
local Screen = require("coop.screen")
local Casino = require("coop.casino")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_EDWIN_GEN") or 0) + 1
_G.DDSMP_EDWIN_GEN = GEN
local function live() return rawget(_G, "DDSMP_EDWIN_GEN") == GEN end

local Edwin = { open = false }

-- Behind the counter (which runs along y -7925, the shelves along the wall at -7675), on
-- the bar's floor, turned to the room.
local FLOOR = -195
local SPOT = { x = 14850, y = -7845, yaw = -90 }
Edwin.SPOT = SPOT
-- (sports T-shirt, army cap worn backwards, sports sunglasses)
local LOOK = { body = "SK_ma_sport_01_b#MI_ma_sport_01_base", head = "SK_ma_head_05_asian", hair = "",
    hat = "Hats_Hair/SK_ma_hat_casual_set_army_cap_01_back_hair", glasses = "SK_ma_glass_03#MI_glass_dark2", beard = "", arms = true }
Edwin.LOOK = LOOK
-- (the walk with music in the ears, made to be played on the spot)
local STRUT = "/Game/Animations/CitizenMale_Walk_08_Listen_Music_Loop_IP.CitizenMale_Walk_08_Listen_Music_Loop_IP"

local function active() return Casino.active() and Core.config.ClubSongs ~= false end
local function key(name) return tostring(Core.config[name] or "?") end
local function me() return Net.S.me or "me" end
local function authority() return not World.shared() or World.role == "host" end
local function price()
    local v = tonumber(Core.config.ClubSongPrice)
    if not v or v < 0 then v = 20 end
    return math.floor(v)
end

---------------------------------------------------------------- the man

local fig = nil          -- { owner, p }

local function clear()
    if fig and fig.p and not World.gone then pcall(Avatar.destroyStandIn, fig.p) end
    fig = nil
end

local function ensure()
    local player = World.player()
    if not player then return end
    if fig and (fig.owner ~= player:GetAddress() or not fig.p or not valid(fig.p.body)) then
        fig = nil        -- another world: he went with it
    end
    if fig or not active() or not Casino.nearClub() then return end
    fig = { owner = player:GetAddress() }
    local ok, e = pcall(function()
        fig.p = Avatar.buildStandIn(LOOK, SPOT.x, SPOT.y, FLOOR + 90, SPOT.yaw, "EDWIN")
        if fig.p then Avatar.poseStandIn(fig.p, STRUT) end
    end)
    if not ok or not fig.p then
        log("Edwin: could not be put behind the bar: %s", tostring(e))
        fig.failed = true
    else
        log("Edwin: behind the bar")
    end
end

---------------------------------------------------------------- the songs

-- The songs by kind, from the club's list (a song goes by its number in that list).
local KINDS = {
    { name = "DARK", cut = "^Dark/artlistDark" },
    { name = "CHILL", cut = "^Medium/artlistMediumchill" },
    { name = "COMMERCIAL", cut = "^Medium/artlistMediumcommercial" },
    { name = "TRAP", cut = "^Medium/artlistMediumtrap" },
    { name = "OLD SCHOOL", cut = "^Oldschool/artlistOldschool" },
    { name = "HARDCORE", cut = "^TwoTowers/" },
}

local function titleOf(path, cut)
    local t = path:gsub(cut, "")
    t = t:gsub("^Hardcore", ""):gsub("_KosmaDDS$", ""):gsub("^DDS_", "")
    t = t:gsub("[-_]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return t:upper()
end

local songs = nil        -- kind -> { { index, title } }
local titles = {}        -- index -> title

local function listSongs()
    if songs then return songs end
    songs = {}
    local first = (Casino.CLUB_SET or 0) + 1
    for k, kind in ipairs(KINDS) do
        songs[k] = {}
        for i = first, #(Casino.TRACKS or {}) do
            local path = Casino.TRACKS[i]
            if path:find(kind.cut) then
                local title = titleOf(path, kind.cut)
                songs[k][#songs[k] + 1] = { index = i, title = title }
                titles[i] = title
            end
        end
    end
    return songs
end
Edwin.songs = listSongs

---------------------------------------------------------------- the screen

local scr, shown, tab = nil, {}, 1
local render

local function put(widget, ax, ay, x, y)
    scr.place(widget, ax, ay, x, y)
    shown[#shown + 1] = widget
    return widget
end

local function button(label, scale, ax, ay, x, y, fn)
    local b = scr.button(label, scale, fn)
    put(b.widget, ax, ay, x, y)
    return b
end

local function close()
    Edwin.open = false
    local s = scr
    scr, shown = nil, {}
    if s then
        s.onClose = nil
        pcall(s.close)
    end
end

-- A player has paid: the song plays now. (In the game that plays the club's music; a
-- guest's game asks the host's.)
local function pick(song)
    local cost = price()
    if cost > 0 and not Casino.take(cost) then
        Hud.toast(string.format("You need $%d in cash for a song", cost), 3)
        return render()
    end
    if authority() then
        if not Casino.pickTrack(song.index) then
            Casino.pay(cost)
            Hud.toast("Edwin cannot put that one on", 3)
            return render()
        end
    else
        Net.send("djp", { i = song.index }, World.host or Net.S.owner)
    end
    pcall(Casino.tell, "had Edwin put on " .. song.title)
    Hud.toast("Edwin puts on " .. song.title, 4)
    close()
end
Edwin.pick = function(index)
    listSongs()
    for _, list in ipairs(songs) do
        for _, song in ipairs(list) do if song.index == index then return pick(song) end end
    end
end

Net.on("djp", function(sender, data)
    if not live() or World.role ~= "host" or not World.inWorld[sender] or not active() then return end
    Casino.pickTrack(data.i)
end)

render = function()
    if not scr or not scr.open then return end
    scr.removeAll(shown)
    shown = {}
    local all = listSongs()
    local money, cost = Casino.cash(), price()
    put(scr.text("EDWIN", "button", 46), 0.5, 0.13)
    put(scr.text(string.format("PICK A SONG   $%d", cost), "button", 24), 0.5, 0.195)
    put(scr.text(string.format("CASH  $%d", money), "button", 18), 0.5, 0.24)
    for k, kind in ipairs(KINDS) do
        local b = button(kind.name, 1.4, 0.5, 0.32, (k - (#KINDS + 1) / 2) * 200, 0, function() tab = k render() end)
        scr.tint(b, k == tab and Screen.GREEN or Screen.WHITE)
    end
    local playing = nil
    pcall(function() playing = titles[Casino.music().index] end)
    for n, song in ipairs(all[tab] or {}) do
        local col, line = (n - 1) % 3, (n - 1) // 3
        local b = button(song.title, 1.4, 0.5, 0.43 + line * 0.07, (col - 1) * 360, 0, function() pick(song) end)
        if money < cost then scr.enable(b, false) end
        if song.title == playing then scr.tint(b, Screen.GREEN) end
    end
    if playing then put(scr.text("NOW PLAYING   " .. playing, "button", 20), 0.5, 0.84) end
    button("CLOSE", 1.4, 0.5, 0.92, 0, 0, close)
end

function Edwin.show()
    if Edwin.open then return true end
    local player = World.player()
    if not player or not active() then return false end
    scr = Screen.open()
    if not scr then return false end
    Edwin.open = true
    shown = {}
    local shade = scr.box({ R = 0, G = 0, B = 0, A = 0.78 })
    pcall(function() shade:SetVisibility(3) end)
    scr.fill(shade, -5)
    scr.onClose = function() Edwin.open, scr, shown = false, nil, {} end
    render()
    return true
end
Edwin.close = close
Edwin.refresh = function() if render then render() end end

---------------------------------------------------------------- at the bar

local function turnedFrom(player, l, x, y)
    local at = nil
    pcall(function() at = player:GetController():GetControlRotation().Yaw end)
    if not at then return 0 end
    return math.abs(((math.deg(math.atan(y - l.Y, x - l.X)) - at + 180) % 360) - 180)
end

-- At the counter in front of him (or with him behind it), turned his way.
local function nearEdwin()
    local player = World.player()
    if not player or not active() or not fig or not fig.p then return false end
    local l = player:K2_GetActorLocation()
    if math.abs(l.Z - (FLOOR + 90)) > 130 then return false end
    local d = (l.X - SPOT.x) ^ 2 + (l.Y - SPOT.y) ^ 2
    if d > 260 * 260 then return false end
    return d < 110 * 110 or turnedFrom(player, l, SPOT.x, SPOT.y) < 60
end
Edwin.near = nearEdwin

-- The sit-down key at the bar asks Edwin; anywhere else in the club it does what it did.
local UNDER = rawget(_G, "DDSMP_EDWIN_UNDER") or Look.takeover
_G.DDSMP_EDWIN_UNDER = UNDER
Edwin.takeover = {
    isOpen = function() return (live() and Edwin.open) or UNDER.isOpen() end,
    near = function() return (live() and not UNDER.isOpen() and nearEdwin()) or UNDER.near() end,
    prompt = function()
        if live() and nearEdwin() then return key("WardrobeKey"), string.format("Pick a song ($%d)", price()) end
        return UNDER.prompt()
    end,
    toggle = function()
        if live() and Edwin.open then
            close()
        elseif live() and not UNDER.isOpen() and nearEdwin() then
            Edwin.show()
        else
            UNDER.toggle()
        end
    end,
    move = function() end,
    choose = function() end,
}
Look.takeover = Edwin.takeover

---------------------------------------------------------------- keeping it all in order

Core.every(1, function()
    if not live() then return end
    local player = World.player()
    if not player then return end
    ensure()
    -- walking away from the bar closes the list
    if Edwin.open then
        local l = player:K2_GetActorLocation()
        if (l.X - SPOT.x) ^ 2 + (l.Y - SPOT.y) ^ 2 > 420 * 420 then close() end
    end
end)

World.listen("stop", function() if live() and Edwin.open then pcall(close) end end)

-- A save loaded from inside the game: the level stays, so he is taken away (and put back
-- for the new player).
World.listen("loading", function()
    if not live() then return end
    if Edwin.open then pcall(close) end
    clear()
end)

-- For reloading the module while developing.
function Edwin.shutdown()
    if Edwin.open then pcall(close) end
    clear()
    if Look.takeover == Edwin.takeover then Look.takeover = UNDER end
end

Edwin.state = function() return fig end
return Edwin
