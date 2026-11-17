-- Shady Comm: who plays in this world, and a picture for each of them.
--
--   * Every player has a picture for Shady Comm: the game's grey figure, one of ten of the
--     game's portraits, or their own tag (the drawing, or the symbol they chose). It is
--     picked with PICTURE under the player's name at the top of the left column, and is
--     kept with the player's character in the world (coop/guests.lua: per save).
--   * The player's own row at the top shows it, and their level.
--   * Above the contacts stands PLAYERS: everybody else who has a character in this world,
--     with their picture, their level, and whether they are in the world right now. The
--     host knows them from the save (the characters written beside it) and tells the
--     guests; a guest tells the host its picture and level as they change.
--   * A message a player writes shows that player's picture, in every game. Messages are
--     the game's own and shared (coop/sync.lua), so who wrote one travels in the message:
--     as many no-break spaces at its end as the writer's number in this world (the host
--     is 1; a guest gets a number from the host, kept with their character). They cannot
--     be seen. A message without them is shown with the picture of whoever looks at it:
--     in single player that is everything.
--
-- Nothing of the game's is replaced: its widgets are made as it makes them and then given
-- other pictures and words.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")
local Guests = require("coop.guests")
local Sync = require("coop.sync")
local Repl = require("coop.repl")
local Screen = require("coop.screen")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_SHADY_GEN") or 0) + 1
_G.DDSMP_SHADY_GEN = GEN
local function live() return rawget(_G, "DDSMP_SHADY_GEN") == GEN end

local Shady = {}

local COMPUTER = "/Game/Interactive/mainComputer.mainComputer_C"
local INTERFACE = "/Game/GUI/shadyCommInterface.shadyCommInterface_C"
local CONTACT = "/Game/GUI/shadyCommContactWidget.shadyCommContactWidget_C"
local GROUP = "/Game/GUI/shadyCommContactGroupTitle.shadyCommContactGroupTitle_C"
local TAB = "/Game/GUI/EquipmentShopping/EquipmentShopCatFilter.EquipmentShopCatFilter_C"
local FIGURE = "/Game/GUI/shadyComm/playerAvatar.playerAvatar"
local PORTRAIT = "/Game/GUI/Avatars/clientAvatars/client-avatar-%02d.client-avatar-%02d"
local MARK = "\194\160"
local COLLAPSED, NO_HIT, SELF_NO_HIT = 1, 3, 4

-- What can be picked: "" the game's figure, "aNN" a portrait, "tag" the player's tag.
-- (the ten: a pug, a corgi, mushrooms, a comic face, a speedometer, a red car, a sunset,
-- green code, an eye, a hand making the peace sign)
Shady.CHOICES = { "", "a01", "a02", "a04", "a07", "a09", "a10", "a14", "a17", "a31", "a32", "tag" }

local function asset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset((path:gsub("%.[^%.]+$", ""))) end)
    o = StaticFindObject(path)
    return valid(o) and o or nil
end

---------------------------------------------------------------- pictures

local function myId() return tostring(Net.S.me or "me") end

-- What goes on an image for a picture (looked up anew every time: nothing of the game's
-- is kept between calls).
local function resource(pic, pid)
    if pic == "tag" then
        local Tags = package.loaded["coop.tags"]
        local rt = nil
        if type(Tags) == "table" and Tags.pictureOf then
            local ok, r = pcall(Tags.pictureOf, pid or myId())
            if ok and valid(r) then rt = r end
        end
        if rt then return rt end
        pic = ""
    end
    local n = tonumber(tostring(pic or ""):match("^a(%d+)$"))
    return (n and asset(string.format(PORTRAIT, n, n))) or asset(FIGURE)
end

-- Puts a picture on an image that may already be on screen. (Writing the picture into the
-- image's brush is not enough there: the brush keeps what it was last drawn with until it
-- is told through the image's own setter.)
local function show(img, res)
    if not valid(img) or not valid(res) then return false end
    return pcall(function()
        local size = img.Brush.ImageSize
        local w, h = size.X, size.Y
        local set = pcall(function() img:SetBrushFromTexture(res, false) end)
        local now = nil
        pcall(function() now = img.Brush.ResourceObject end)
        if not set or not valid(now) or now:GetAddress() ~= res:GetAddress() then img.Brush.ResourceObject = res end
        img.Brush.ImageSize = { X = w, Y = h }
    end)
end

---------------------------------------------------------------- this player

local pending = nil       -- a picture picked before the player has a character in this world

local function myPic()
    local r = Guests.ready() and Guests.self() or nil
    if type(r) == "table" and type(r.pic) == "string" then return r.pic end
    return pending or ""
end

local function setPic(pic)
    pic = tostring(pic or "")
    local r = Guests.ready() and Guests.self() or nil
    if type(r) ~= "table" then
        pending = pic
        return
    end
    pending = nil
    r.pic = pic
    Guests.setSelf(r)
    log("Shady Comm: picture '%s'", pic == "" and "the grey figure" or pic)
end
Shady.setPic, Shady.myPic = setPic, myPic

local function myLevel()
    local level = 1
    pcall(function() level = math.floor(tonumber(Core.find("statisticsManager_C").playerLevel) or 1) end)
    return level
end

---------------------------------------------------------------- who is in this world

-- Everybody else with a character in this world: { id, name, level, pic, no, on }.
local others = {}
local myNo = nil          -- this player's number in this world (guest: from the host)
local online = {}         -- host: player id -> { p, l } as that player's game last said
local sentRoster, sentAt, sentMine, sentMineAt = nil, 0, nil, 0

local function hosting() return World.role ~= "guest" end

local function inWorld()
    local set = {}
    if World.active then
        for id, on in pairs(World.inWorld or {}) do if on then set[tostring(id)] = true end end
    end
    return set
end

-- The host's list, from the characters kept with the save and what their games say.
local function hostRoster()
    local players = Guests.players()
    local used = { [1] = true }
    for _, r in pairs(players) do
        if type(r) == "table" and tonumber(r.no) then used[math.floor(tonumber(r.no))] = true end
    end
    local here = inWorld()
    local out = {}
    for id, r in pairs(players) do
        if type(r) == "table" then
            if not tonumber(r.no) then
                local n = 2
                while used[n] do n = n + 1 end
                r.no, used[n] = n, true
            end
            local key = tostring(id)
            local on = here[key] == true
            local said = on and online[key] or nil
            local kept = type(r.c) == "table" and type(r.c.pic) == "string" and r.c.pic or ""
            out[#out + 1] = { id = key, name = tostring(r.name or "?"), level = (said and said.l) or Guests.levelOf(r) or 1, pic = (said and said.p) or kept,
                no = math.floor(tonumber(r.no)), on = on }
        end
    end
    table.sort(out, function(a, b) return a.no < b.no end)
    return out
end

local function wire(list)
    local out = {}
    for i, e in ipairs(list) do out[i] = { i = e.id, n = e.name, l = e.level, p = e.pic, o = e.no, on = e.on } end
    return out
end

local function signature(list)
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = table.concat({ e.id, e.name, tostring(e.level), e.pic, tostring(e.no), tostring(e.on) }, "/") end
    return table.concat(parts, ";")
end

Net.on("shr", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= (World.host or Net.S.owner) or type(data) ~= "table" or type(data.r) ~= "table" then return end
    local list, me = {}, myId()
    -- the host itself
    if type(data.h) == "table" then
        list[1] = { id = tostring(sender), name = Net.name(sender), level = tonumber(data.h.l) or 1, pic = tostring(data.h.p or ""), no = 1, on = true }
    end
    for _, e in ipairs(data.r) do
        if type(e) == "table" and e.i ~= nil then
            if tostring(e.i) == me then
                myNo = tonumber(e.o)
            else
                list[#list + 1] = { id = tostring(e.i), name = tostring(e.n or "?"), level = tonumber(e.l) or 1, pic = tostring(e.p or ""), no = tonumber(e.o) or 0, on = e.on == true }
            end
        end
    end
    others = list
end)

Net.on("shp", function(sender, data)
    if not live() or World.role ~= "host" or type(data) ~= "table" then return end
    online[tostring(sender)] = { p = tostring(data.p or ""), l = tonumber(data.l) or 1 }
    sentAt = 0          -- (the others hear of it at the next round)
end)

local function tendRoster()
    if hosting() then
        myNo = 1
        others = hostRoster()
        if World.active and World.role == "host" then
            local mine = { p = myPic(), l = myLevel() }
            local sig = signature(others) .. "|" .. mine.p .. "|" .. mine.l
            if sig ~= sentRoster or os.clock() - sentAt > 20 then
                sentRoster, sentAt = sig, os.clock()
                for _, id in ipairs(World.targets()) do Net.send("shr", { r = wire(others), h = mine }, id) end
            end
        end
    elseif World.active then
        local mine = myPic() .. "|" .. myLevel()
        if mine ~= sentMine or os.clock() - sentMineAt > 20 then
            sentMine, sentMineAt = mine, os.clock()
            Net.send("shp", { p = myPic(), l = myLevel() }, World.host or Net.S.owner)
        end
    end
end

-- The picture of the player with that number in this world.
local function picOfNo(no)
    if no == nil or no == myNo then return myPic(), myId() end
    for _, e in ipairs(others) do if e.no == no then return e.pic, e.id end end
    return "", nil
end

function Shady.others() return others end
function Shady.myNo() return myNo end

---------------------------------------------------------------- who wrote a message

local function trailing(text)
    -- (an array element as text: "..." with the message between the quotes)
    local body = text:sub(-1) == '"' and text:sub(1, -2) or text
    local n = 0
    while body:sub(-2) == MARK do
        n = n + 1
        body = body:sub(1, -3)
    end
    return n
end

local known, knownFor = nil, nil      -- how many messages are accounted for (per world)

-- Messages that have appeared since the last look and were written here get this
-- player's number. (What another game wrote arrives while coop/sync.lua is applying it,
-- and carries its writer's number already.)
local function claim(computer)
    local player = World.player()
    if not player or not valid(computer) then return end
    local key = player:GetAddress()
    local ok, n = pcall(function() return computer.messagesMine:GetArrayNum() end)
    if not ok or type(n) ~= "number" then return end
    if knownFor ~= key or known == nil or n < known then
        known, knownFor = n, key
        return
    end
    if n == known then return end
    if Sync.isApplying() or not World.active or not myNo then
        known = n
        return
    end
    local e = Repl.export(computer, { "messagesList", "messagesMine" })
    local texts, mine = Repl.splitArray(e.messagesList or "()"), Repl.splitArray(e.messagesMine or "()")
    local changed = false
    for i = known + 1, #texts do
        local t = texts[i]
        if mine[i] == "True" and t:sub(-1) == '"' and trailing(t) == 0 then
            texts[i] = t:sub(1, -2) .. MARK:rep(myNo) .. '"'
            changed = true
        end
    end
    known = n
    if changed then Repl.import(computer, { messagesList = Repl.joinArray(texts) }) end
end

-- The messages on screen: each of a player's gets its writer's picture.
local function paintMessages(ui)
    local list = ui.messageList
    if not valid(list) then return end
    local cache = {}
    for i = 0, list:GetChildrenCount() - 1 do
        pcall(function()
            local w = list:GetChildAt(i)
            if not valid(w) or w.messageMine.Visibility ~= 0 then return end
            local text = w.txtMessageMine:GetText():ToString()
            local no = trailing(text)
            if no == 0 then no = nil end
            local pic, pid = picOfNo(no)
            local key = pic .. "/" .. tostring(pid)
            if cache[key] == nil then cache[key] = resource(pic, pid) or false end
            -- (the picture beside the player's bubble: the second thing in the bubble's row)
            local row = w.messageMine:GetContent()
            if cache[key] and valid(row) and row:GetChildrenCount() >= 2 then show(row:GetChildAt(1), cache[key]) end
        end)
    end
end

Core.Hooks.add(INTERFACE .. ":renderMessages", function(ctx)
    if not live() then return end
    local ok, e = pcall(function()
        local ui = ctx:get()
        if not valid(ui) then return end
        claim(ui.parentRef)
        paintMessages(ui)
    end)
    if not ok then log("Shady Comm: messages: %s", tostring(e)) end
end)

Core.Hooks.add(COMPUTER .. ":addUserMessage", function(ctx)
    if not live() then return end
    pcall(function() claim(ctx:get()) end)
end)

---------------------------------------------------------------- the players above the contacts

local function addPlayers(ui)
    if #others == 0 then return end
    local list = ui.contactList
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local groupClass, rowClass = asset(GROUP), asset(CONTACT)
    if not valid(list) or not valid(lib) or not groupClass or not rowClass then return end
    local made = {}
    local title = lib:Create(ui, groupClass, nil)
    if not valid(title) then return end
    pcall(function() title.txtHeading:SetText(FText("PLAYERS")) end)
    made[1] = title
    for _, e in ipairs(others) do
        local row = lib:Create(ui, rowClass, nil)
        if valid(row) then
            pcall(function() row.txtUsername:SetText(FText(e.name)) end)
            pcall(function() row.txtAreaNam:SetText(FText(e.on and "in the world" or "away")) end)
            pcall(function() show(row.avatar, resource(e.pic, e.id)) end)
            for _, name in ipairs({ "txtNewMessages", "unreadMarker", "userBgActive", "arrestCover", "blackRibon", "expProgress" }) do
                pcall(function() row[name]:SetVisibility(COLLAPSED) end)
            end
            pcall(function()
                row.dealerLevelPanel:SetVisibility(SELF_NO_HIT)
                row.txtDealerLevel:SetText(FText("lvl " .. tostring(e.level)))
            end)
            -- (a row of the game's opens that contact's messages when clicked: these do nothing)
            pcall(function() row:SetVisibility(NO_HIT) end)
            pcall(function() if not e.on then row:SetRenderOpacity(0.55) end end)
            made[#made + 1] = row
        end
    end
    -- (a list only adds at its end: what it holds is taken out and put back after ours)
    local rest = {}
    for i = 0, list:GetChildrenCount() - 1 do rest[#rest + 1] = list:GetChildAt(i) end
    list:ClearChildren()
    for _, w in ipairs(made) do list:AddChild(w) end
    for _, w in ipairs(rest) do if valid(w) then list:AddChild(w) end end
end

Core.Hooks.add(INTERFACE .. ":renderContacts", function(ctx)
    if not live() then return end
    local ok, e = pcall(function()
        local ui = ctx:get()
        if valid(ui) then addPlayers(ui) end
    end)
    if not ok then log("Shady Comm: players: %s", tostring(e)) end
end)

---------------------------------------------------------------- the player's own row, and the picker

-- What this module has put into the Shady Comm screen that is open: { address, image,
-- level, button, shown }. The screen is the computer's `interface`; it is asked for anew
-- every time, and nothing of ours is touched once it is another one or gone.
local att = nil
local picker = nil

local function interface()
    local computer = Core.find("mainComputer_C")
    local ui = nil
    pcall(function() ui = computer and computer.interface end)
    if not valid(ui) then return nil end
    local shown = false
    pcall(function() shown = ui:IsInViewport() end)
    return shown and ui or nil
end

local function attach(ui)
    local a = { address = ui:GetAddress() }
    local panel = ui.btnDesktop:GetParent()
    for i = 0, panel:GetChildrenCount() - 1 do
        local c = panel:GetChildAt(i)
        local name = c:GetFName():ToString()
        if name == "Image_8" then a.image = c end
        if name == "VerticalBox_12" then a.nameBox = c end
    end
    local player = World.player()
    local pc = player:GetController()
    local at = { X = 80, Y = 18 }
    pcall(function() local p = a.nameBox.Slot:GetPosition() at = { X = p.X, Y = p.Y } end)
    -- the level, at the right edge of the column, on the name's line
    pcall(function()
        local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), ui.WidgetTree)
        t:SetFont(ui.txtUserMainName.Font)
        t:SetColorAndOpacity({ SpecifiedColor = { R = 0.55, G = 0.55, B = 0.55, A = 1 }, ColorUseRule = 0 })
        t:SetVisibility(NO_HIT)
        local slot = panel:AddChildToCanvas(t)
        slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        slot:SetAlignment({ X = 1, Y = 0 })
        slot:SetAutoSize(true)
        slot:SetPosition({ X = -18, Y = at.Y })
        a.level = t
    end)
    -- PICTURE, under the name: one of the game's small buttons
    pcall(function()
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local w = lib:Create(player, asset(TAB), pc)
        w.txtBtnName:SetText(FText("PICTURE"))
        w.btnShow:SetRenderOpacity(1)
        w:SetRenderTransformPivot({ X = 0, Y = 0 })
        w:SetRenderScale({ X = 0.62, Y = 0.62 })
        local slot = panel:AddChildToCanvas(w)
        slot:SetAutoSize(true)
        slot:SetPosition({ X = at.X - 6, Y = at.Y + 22 })
        slot:SetZOrder(5)
        a.button = w
    end)
    return a
end

local function closePicker()
    local s = picker
    picker = nil
    if s and s.open then pcall(s.close) end
end

local function openPicker()
    if picker then return end
    local ui = interface()
    if not ui then return end
    local s = Screen.open()
    if not s then return end
    picker = s
    s.onClose = function()
        if picker == s then picker = nil end
        -- (the computer's screen has the mouse again)
        pcall(function()
            local now = interface()
            local pc = World.player():GetController()
            if now and valid(pc) then
                StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameAndUIEx(pc, now, 2, false)
                pc.bShowMouseCursor = true
            end
        end)
    end
    s.fill(s.box({ R = 0, G = 0, B = 0, A = 0.9 }), 0)
    local column = s.new("VerticalBox")
    local head = s.new("HorizontalBox")
    head:AddChildToHorizontalBox(s.text("YOUR PICTURE ON SHADY COMM", "button", 22)):SetVerticalAlignment(2)
    local x = s.bigButton("X", 1.3, closePicker)
    s.tint(x, Screen.RED)
    local xs = head:AddChildToHorizontalBox(x.box)
    xs:SetPadding({ Left = 40, Top = 0, Right = 0, Bottom = 0 })
    xs:SetVerticalAlignment(2)
    column:AddChildToVerticalBox(head):SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 18 })
    local now = myPic()
    local perRow = math.ceil(#Shady.CHOICES / 2)
    local row = nil
    for i, pic in ipairs(Shady.CHOICES) do
        if (i - 1) % perRow == 0 then
            row = s.new("HorizontalBox")
            column:AddChildToVerticalBox(row):SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 14 })
        end
        local img = s.new("Image")
        pcall(function()
            img.Brush.ResourceObject = resource(pic, myId())
            img.Brush.ImageSize = { X = 96, Y = 96 }
        end)
        img:SetVisibility(NO_HIT)
        local hit = s.hit("pic:" .. (pic == "" and "none" or pic), function()
            setPic(pic)
            closePicker()
        end)
        local stack = s.new("Overlay")
        stack:AddChildToOverlay(img)
        local hs = stack:AddChildToOverlay(hit.widget)
        hs:SetHorizontalAlignment(0)
        hs:SetVerticalAlignment(0)
        local cell = s.new("VerticalBox")
        local on = pic == now
        cell:AddChildToVerticalBox(s.box(on and Screen.GREEN or { R = 0.02, G = 0.02, B = 0.025, A = 1 }, s.sized(stack, 96, 96), 4))
        local label = pic == "tag" and "USE TAG" or (pic == "" and "DEFAULT" or "")
        local ls = cell:AddChildToVerticalBox(s.text(label, "small", 13, on and Screen.GREEN or Screen.GREY))
        ls:SetHorizontalAlignment(2)
        ls:SetPadding({ Left = 0, Top = 4, Right = 0, Bottom = 0 })
        row:AddChildToHorizontalBox(cell):SetPadding({ Left = 0, Top = 0, Right = 14, Bottom = 0 })
    end
    s.place(column, 0.5, 0.5, 0, 0)
end
Shady.openPicker, Shady.closePicker = openPicker, closePicker

local wasDown = false

Core.onTick(function()
    if not live() or not att then return end
    -- (the screen may have gone since the last look: only then is anything of ours left alone)
    local ui = interface()
    if not ui or ui:GetAddress() ~= att.address then
        att = nil
        return
    end
    if picker then return end
    local down = false
    pcall(function() down = att.button ~= nil and att.button.btnShow:IsPressed() end)
    if down and not wasDown then
        local ok, e = pcall(openPicker)
        if not ok then log("Shady Comm: the picker: %s", tostring(e)) end
    end
    wasDown = down
end)

Core.every(0.5, function()
    if not live() then return end
    local player = World.player()
    if not player or World.joining or World.gone then
        att, others, online, myNo, sentRoster, sentMine = nil, {}, {}, nil, nil, nil
        if picker then picker = nil end
        return
    end
    -- a picture picked before there was a character to keep it with
    if pending and Guests.ready() and type(Guests.self()) == "table" then setPic(pending) end
    -- the messages this world came with are nobody's in particular
    if knownFor ~= player:GetAddress() then
        pcall(function()
            local n = Core.find("mainComputer_C").messagesMine:GetArrayNum()
            if type(n) == "number" then known, knownFor = n, player:GetAddress() end
        end)
    end
    local ok, e = pcall(tendRoster)
    if not ok then log("Shady Comm: %s", tostring(e)) end
    local ui = interface()
    if not ui then
        att = nil
        if picker then closePicker() end
        return
    end
    if not att or att.address ~= ui:GetAddress() then
        local made, a = pcall(attach, ui)
        if not made then
            log("Shady Comm: the player's row: %s", tostring(a))
            return
        end
        att = a
        -- (the lists as they stand were drawn before we looked)
        pcall(function() ui:renderContacts() end)
        pcall(function() if ui.curSelectedUser >= 0 then paintMessages(ui) end end)
    end
    local pic = myPic()
    local version = 0
    pcall(function() version = package.loaded["coop.tags"].versionOf() end)
    local key = pic .. "/" .. version
    if att.shown ~= key then
        if show(att.image, resource(pic, myId())) then att.shown = key end
        pcall(function() if ui.curSelectedUser >= 0 then paintMessages(ui) end end)
    end
    local level = "lvl " .. myLevel()
    if att.levelText ~= level then
        att.levelText = level
        pcall(function() att.level:SetText(FText(level)) end)
    end
    -- the list is drawn anew when somebody's picture, level or presence changes
    local sig = signature(others)
    if att.roster ~= sig then
        att.roster = sig
        pcall(function() ui:renderContacts() end)
        pcall(function() if ui.curSelectedUser >= 0 then paintMessages(ui) end end)
    end
end)

function Shady.shutdown()
    closePicker()
    att = nil
end

-- (for test scripts)
function Shady.attached() return att end
function Shady.setOthers(list) others = list end
Shady.resource, Shady.trailing = resource, trailing

return Shady
