-- Marking a client's order as one's own (TWEAKS: ClientMarks).
--
--   * A click on the picture of a client or a dealer in Shady Comm's contact list marks
--     their open order (one still to be answered, or accepted and still to be delivered)
--     for the player who clicked; a click again takes the mark off. (A click anywhere
--     else on the row, and a double click, do what they do in the game.)
--   * A marked client carries the player's colour (coop/colours.lua): a ring round their
--     picture in the contact list, the square of their row on the task list
--     (coop/orders.lua), and, a shade off, their icon and name on the map and their icon
--     on the compass. The other players' own markers there are their colour in full.
--   * The mark goes when the order is done with: delivered, turned down, failed, or
--     followed by a new one; and when the player who made it leaves the world.
--   * The colour is the player's own: COLOUR, under the player's name at the top of
--     Shady Comm's left column, opens a screen with colours to click and a field for six
--     hex digits. A ring in that colour is round the player's picture there, and round
--     the other players' pictures in the PLAYERS list.
--
-- The host keeps the marks ("mkq" a guest asks, "mks" the list to everybody, "mkn" words
-- for the player who asked). A host with an older version never answers: nothing is marked.
-- A player with this switched off sees no marks and makes none.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")
local Screen = require("coop.screen")
local Colours = require("coop.colours")
local Orders = require("coop.orders")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_MARKS_GEN") or 0) + 1
_G.DDSMP_MARKS_GEN = GEN
local function live() return rawget(_G, "DDSMP_MARKS_GEN") == GEN end

local Marks = {}

local INTERFACE = "/Game/GUI/shadyCommInterface.shadyCommInterface_C"
local TAB = "/Game/GUI/EquipmentShopping/EquipmentShopCatFilter.EquipmentShopCatFilter_C"
local CONFIRM = "BndEvt__btnConfirmOrder_K2Node_ComponentBoundEvent_12_OnButtonClickedEvent__DelegateSignature"
local CLICK = TAB .. ":BndEvt__btnShowFunctional_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local MARKER = "/Game/GUI/WorldMap/worldMapMarker.worldMapMarker_C"
local COLLAPSED, NO_HIT = 1, 3
local DEALER_WORDS = " (Dealer)"       -- what the map writes after a dealer's name

-- the game's own colours for a client and a dealer on the map (icon, name)
local MAP_CLIENT = { { R = 0.0, G = 0.9271, B = 0.0701, A = 1 }, { R = 0.0007, G = 0.5938, B = 0.0012, A = 1 } }
local MAP_DEALER = { { R = 0.8125, G = 0.3161, B = 0.0, A = 1 }, { R = 0.8958, G = 0.5175, B = 0.0, A = 1 } }

-- What the colour screen offers: the six colours players have by their place, and six more.
Marks.MORE = { "FF3B30", "2EC4B6", "3D6BFF", "B5E61D", "B5651D", "F2F2F2" }

-- The ring round a picture: how wide its line is, in the units pictures are laid out in
-- (a pixel each on a screen 1080 high). It stands 2 units outside the picture.
Marks.RING_WIDTH = 1.5

local function on() return Core.experimental("ClientMarks") end
local function me() return tostring(Net.S.me or "me") end
local function hosting() return World.role ~= "guest" end
local function hostId() return World.host or Net.S.owner end
local function slate(c) return { SpecifiedColor = c, ColorUseRule = 0 } end
local function library() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end

local function nameOf(pid)
    if pid == me() then return tostring(Net.S.myName or "You") end
    for id, name in pairs(Net.S.members or {}) do
        if tostring(id) == pid then return tostring(name) end
    end
    return "Another player"
end

---------------------------------------------------------------- the marks

local marks = {}           -- client number -> { p = player id (text), o = order number }
local version = 0          -- goes up with every change (what is drawn follows it)
local sentAt, sentVersion = 0, -1

local function bump() version = version + 1 end

function Marks.all() return marks end
function Marks.version() return version end

-- The colour a client is marked in ("RRGGBB" / as the screen takes it); nil: not marked,
-- or this player has marks switched off.
function Marks.hexOfClient(client)
    local m = on() and marks[client] or nil
    return m and Colours.hexOf(m.p) or nil
end

-- True for a client somebody else has marked.
function Marks.byOther(client)
    local m = on() and marks[client] or nil
    return m ~= nil and m.p ~= me()
end

function Marks.colourOfClient(client)
    local m = on() and marks[client] or nil
    return m and Colours.of(m.p) or nil
end

local function wire()
    local out = {}
    for client, m in pairs(marks) do out[#out + 1] = { c = client, p = m.p, o = m.o } end
    return out
end

local function tell(target)
    if not World.active or World.role ~= "host" then return end
    local list = wire()
    if target then
        Net.send("mks", { m = list }, target)
    else
        for _, id in ipairs(World.targets()) do Net.send("mks", { m = list }, id) end
        sentAt, sentVersion = os.clock(), version
    end
end

-- The host's answer to a click on a picture: marks, takes the mark off, or says why not.
-- Returns words for the player who asked (nil: done).
local function request(pid, client)
    local c = Orders.clients()[client]
    if not c then return nil end
    if not c.order then return "No open order from " .. c.name end
    local m = marks[client]
    if m and m.o == c.order then
        if m.p ~= pid then return nameOf(m.p) .. " has marked " .. c.name end
        marks[client] = nil
        log("Marks: %s unmarked by %s", c.name, nameOf(pid))
    else
        marks[client] = { p = pid, o = c.order }
        log("Marks: %s (order %d) marked by %s", c.name, c.order, nameOf(pid))
    end
    bump()
    return nil
end

local function say(text)
    local Hud = package.loaded["coop.hud"]
    if type(Hud) == "table" and Hud.toast then pcall(Hud.toast, text, 4) end
end

-- Marks the client's order for this player, or takes this player's mark off.
function Marks.toggle(client)
    if not on() or type(client) ~= "number" then return end
    if hosting() then
        local words = request(me(), client)
        if words then say(words) end
        if World.active then tell() end
    elseif World.active then
        Net.send("mkq", { c = client }, hostId())
    end
end

Net.on("mkq", function(sender, data)
    if not live() or World.role ~= "host" or not World.inWorld[sender] or type(data) ~= "table" then return end
    local client = math.tointeger(tonumber(data.c) or -1)
    if not client or client < 0 then return end
    local words = request(tostring(sender), client)
    if words then Net.send("mkn", { m = words }, sender) end
    tell()
end)

Net.on("mks", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= hostId() or type(data) ~= "table" or type(data.m) ~= "table" then return end
    local new, same = {}, true
    for _, e in ipairs(data.m) do
        local client, order = type(e) == "table" and math.tointeger(tonumber(e.c) or -1) or nil, type(e) == "table" and math.tointeger(tonumber(e.o) or -1) or nil
        if client and client >= 0 and order and e.p ~= nil then new[client] = { p = tostring(e.p), o = order } end
    end
    for client, m in pairs(new) do
        local old = marks[client]
        if not old or old.p ~= m.p or old.o ~= m.o then same = false end
    end
    for client in pairs(marks) do if not new[client] then same = false end end
    if same then return end
    marks = new
    bump()
end)

Net.on("mkn", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= hostId() or type(data) ~= "table" or type(data.m) ~= "string" then return end
    say(data.m:sub(1, 120))
end)

-- The host (and a game on its own): a mark goes with its order, and with its player.
Core.every(1, function()
    if not live() then return end
    local player = World.player()
    if not player or World.joining or World.gone then
        if next(marks) then marks = {} bump() end
        return
    end
    if not hosting() then return end
    if next(marks) then
        local clients = Orders.clients()
        local here = { [me()] = true }
        if World.active then
            for id, there in pairs(World.inWorld or {}) do if there then here[tostring(id)] = true end end
        end
        -- (only against a list that was read: one that could not be says nothing about the orders)
        if next(clients) then
            for client, m in pairs(marks) do
                local c = clients[client]
                local why = (not c and "the client is gone") or (c.order ~= m.o and "the order is done with") or (not here[m.p] and "the player has left") or nil
                if why then
                    marks[client] = nil
                    bump()
                    log("Marks: the mark on %s goes: %s", c and c.name or ("client " .. tostring(client)), why)
                end
            end
        end
    end
    if World.active and World.role == "host" and (version ~= sentVersion or os.clock() - sentAt > 15) then tell() end
end)

World.listen("peer", function(id) if live() then tell(id) end end)
-- (a host's world starts and stops being shared with the first and the last guest: the
-- host's own marks stay through both; what a guest knew belongs to the world it was in)
World.listen("start", function(role)
    if not live() then return end
    sentVersion = -1
    if role == "guest" then marks = {} bump() end
end)
World.listen("stop", function(role)
    if not live() then return end
    if role == "guest" then marks = {} bump() end
end)
World.listen("loading", function() if live() then marks = {} bump() end end)

---------------------------------------------------------------- the ring

-- A white ring on nothing, painted once (coop/tags.lua); an image tints it.
local RING_UNITS = 256     -- an image shows the whole picture (512 across) at half size

-- A white ring on nothing for a picture `across` units wide, painted once (coop/tags.lua);
-- an image tints it. It is painted in the middle of the picture at twice the size it is
-- shown at, so that it comes out as an even thin line (a large ring shown small breaks up
-- into dots).
local function ringPicture(across)
    local Tags = package.loaded["coop.tags"]
    if type(Tags) ~= "table" or not Tags.canvasPicture then return nil end
    local ok, rt = pcall(Tags.canvasPicture, string.format("markring%d/%s", across, tostring(Marks.RING_WIDTH)), function(cv, white, size, clear)
        local k = size / RING_UNITS
        local c = size / 2
        local outer = across / 2 * k
        local inner = outer - Marks.RING_WIDTH * k
        cv:K2_DrawPolygon(white, { X = c, Y = c }, { X = outer, Y = outer }, 96, { R = 1, G = 1, B = 1, A = 1 })
        -- the hole: strips of nothing as wide as the circle is at their height
        local rows = math.floor(2 * inner)
        local h = 2 * inner / rows
        for i = 0, rows - 1 do
            local dy = -inner + (i + 0.5) * h
            local w = math.sqrt(math.max(0, inner * inner - dy * dy))
            cv:K2_DrawTexture(white, { X = c - w, Y = c + dy - h / 2 }, { X = 2 * w, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, clear, 0, 0, { X = 0.5, Y = 0.5 })
        end
    end)
    return ok and valid(rt) and rt or nil
end

-- A ring image in a canvas, round the square at x, y of that size, `grow` outside it.
local function makeRing(owner, canvas, x, y, size, grow)
    local rt = ringPicture(size + 2 * grow)
    if not rt or not valid(canvas) then return nil end
    local img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), owner.WidgetTree)
    if not valid(img) then return nil end
    pcall(function() img:SetBrushFromTexture(rt, false) end)
    pcall(function()
        local now = img.Brush.ResourceObject
        if not valid(now) or now:GetAddress() ~= rt:GetAddress() then img.Brush.ResourceObject = rt end
        img.Brush.ImageSize = { X = RING_UNITS, Y = RING_UNITS }
    end)
    img:SetVisibility(NO_HIT)
    -- (the image is much larger than the ring, and empty round it: its middle on the picture's)
    local slot = canvas:AddChildToCanvas(img)
    slot:SetAutoSize(false)
    slot:SetPosition({ X = x + size / 2 - RING_UNITS / 2, Y = y + size / 2 - RING_UNITS / 2 })
    slot:SetSize({ X = RING_UNITS, Y = RING_UNITS })
    slot:SetZOrder(3)
    return img
end

-- A ring round a picture that sits on a canvas, wherever and however large it is there
-- (taken from the picture's own slot: the game's UE 4.27 build moved the pictures of the
-- contact list), `grow` outside it.
local function makeRingOn(owner, pic, grow)
    local slot = pic.Slot
    local canvas = pic:GetParent()
    local pos, size = slot:GetPosition(), slot:GetSize()
    local L = slot.LayoutData
    local w, h = size.X, size.Y
    if slot:GetAutoSize() or w < 1 then
        local s = pic.Brush.ImageSize
        w, h = s.X, s.Y
    end
    local across = math.floor(math.min(w, h) + 0.5)
    local rt = ringPicture(across + 2 * grow)
    if not rt or not valid(canvas) then return nil end
    local img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), owner.WidgetTree)
    if not valid(img) then return nil end
    pcall(function() img:SetBrushFromTexture(rt, false) end)
    pcall(function()
        local now = img.Brush.ResourceObject
        if not valid(now) or now:GetAddress() ~= rt:GetAddress() then img.Brush.ResourceObject = rt end
        img.Brush.ImageSize = { X = RING_UNITS, Y = RING_UNITS }
    end)
    img:SetVisibility(NO_HIT)
    -- (the middle of the ring's image on the middle of the picture, in the picture's anchors)
    local cx = pos.X + (0.5 - L.Alignment.X) * w
    local cy = pos.Y + (0.5 - L.Alignment.Y) * h
    local s = canvas:AddChildToCanvas(img)
    s:SetAnchors(L.Anchors)
    s:SetAlignment({ X = 0.5, Y = 0.5 })
    s:SetAutoSize(false)
    s:SetPosition({ X = cx, Y = cy })
    s:SetSize({ X = RING_UNITS, Y = RING_UNITS })
    s:SetZOrder(math.max(3, slot:GetZOrder() + 1))
    return img
end

---------------------------------------------------------------- Shady Comm

local function interface()
    local computer = Core.find("mainComputer_C")
    local ui = nil
    pcall(function() ui = computer and computer.interface end)
    if not valid(ui) then return nil end
    local shown = false
    pcall(function() shown = ui:IsInViewport() end)
    return shown and ui or nil
end

local rings = {}           -- contact row (address) -> { img, hex }
local dirty = false
local att = nil            -- what is ours on the open Shady Comm screen: { address, ring, hex, button }
local picker = nil

-- The colour of the ring a row of the contact list gets, nil for none.
local function rowColour(row)
    local known = false
    pcall(function() known = valid(row.parentRef) end)
    if known then
        local client = Orders.clientOfContact(row.userid)
        return client and Marks.hexOfClient(client) or nil
    end
    -- a player's row (coop/shady.lua makes them, with nothing behind them)
    local Shady = package.loaded["coop.shady"]
    if type(Shady) ~= "table" or not Shady.others then return nil end
    local name = row.txtUsername:GetText():ToString()
    for _, e in ipairs(Shady.others()) do
        if e.name == name and e.on then return Colours.hexOf(e.id) end
    end
    return nil
end

-- A button nobody sees, over the picture of a contact row (36 across at 30, 10): one of the
-- game's own small buttons, as the mod's screens use them, because its click is an event
-- of the game's that can be listened to.
local function makeButton(row)
    local player = World.player()
    local w = library():Create(player, Core.class(TAB), player:GetController())
    if not valid(w) then return nil end
    pcall(function() w.txtBtnName:SetVisibility(COLLAPSED) end)
    pcall(function() w.btnShow:SetRenderOpacity(0) end)
    pcall(function()
        local slot = w.btnShow.Slot
        slot:SetSize({ SizeRule = 1, Value = 1 })
        slot:SetHorizontalAlignment(0)
        slot:SetVerticalAlignment(0)
        slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    end)
    pcall(function()
        local rowSlot = w.btnShow:GetParent().Slot
        rowSlot:SetAutoSize(false)
        rowSlot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
        rowSlot:SetAlignment({ X = 0, Y = 0 })
        rowSlot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    end)
    -- (exactly over the picture: its slot's place and size)
    local pic = row.avatar.Slot
    local slot = row.avatar:GetParent():AddChildToCanvas(w)
    slot:SetAutoSize(false)
    slot:SetAnchors(pic.LayoutData.Anchors)
    slot:SetAlignment(pic.LayoutData.Alignment)
    slot:SetPosition(pic:GetPosition())
    local size = pic:GetSize()
    if pic:GetAutoSize() or size.X < 1 then size = row.avatar.Brush.ImageSize end
    slot:SetSize({ X = size.X, Y = size.Y })
    slot:SetZOrder(math.max(4, pic:GetZOrder() + 2))
    return w
end

-- Every row of the contact list gets what is ours: a client with an open order the button
-- over the picture, a marked one (and a player) the ring.
local function decorate(ui)
    local list = ui.contactList
    if not valid(list) then return end
    local kept = {}
    for i = 0, list:GetChildrenCount() - 1 do
        local row = list:GetChildAt(i)
        local isRow = false
        pcall(function() isRow = row:GetClass():GetFName():ToString() == "shadyCommContactWidget_C" end)
        if isRow then
            local address = row:GetAddress()
            local r = rings[address] or {}
            -- the ring
            local want = nil
            if on() then pcall(function() want = rowColour(row) end) end
            if r.img and not valid(r.img) then r.img, r.hex = nil, nil end
            if want and not r.img then
                pcall(function() r.img = makeRingOn(row, row.avatar, 2) end)
            end
            if r.img and r.hex ~= (want or "") then
                r.hex = want or ""
                pcall(function()
                    if want then r.img:SetColorAndOpacity(Colours.fromHex(want)) end
                    r.img:SetVisibility(want and NO_HIT or COLLAPSED)
                end)
            end
            -- the button over the picture: only where a click would mark something
            local client, c = nil, nil
            if on() then
                pcall(function()
                    if valid(row.parentRef) then client, c = Orders.clientOfContact(row.userid) end
                end)
            end
            local clickable = client ~= nil and c.order ~= nil
            if r.btn and not valid(r.btn) then r.btn, r.clickable = nil, nil end
            if clickable and not r.btn then
                pcall(function() r.btn = makeButton(row) end)
                r.btnAddress = r.btn and r.btn:GetAddress() or nil
            end
            r.client = client
            if r.btn and r.clickable ~= clickable then
                r.clickable = clickable
                pcall(function() r.btn:SetVisibility(clickable and 4 or COLLAPSED) end)
            end
            if r.img or r.btn then kept[address] = r end
        end
    end
    rings = kept
end

-- (the lists are drawn anew by the game for many reasons: ours follows a moment later)
Core.Hooks.add({ INTERFACE .. ":renderContacts", INTERFACE .. ":Render Contacts" }, function() if live() then dirty = true end end)

-- A click on one of the buttons over the pictures, heard the two ways the mod's screens
-- hear their buttons (coop/screen.lua): the game's own click event of that kind of button,
-- and a look every tick at whether one is held down. Whichever comes first counts; the
-- other is the same click.
local function press(r)
    if not r.clickable or not r.client then return end
    local now = os.clock()
    if now - (r.firedAt or 0) < 0.35 then return end
    r.firedAt = now
    Marks.toggle(r.client)
    dirty = true
end

Core.Hooks.add(CLICK, function(ctx)
    if not live() or not on() or not next(rings) then return end
    local ok, e = pcall(function()
        local w = ctx:get()
        if not valid(w) then return end
        local address = w:GetAddress()
        for _, r in pairs(rings) do
            if r.btnAddress == address then
                press(r)
                return
            end
        end
    end)
    if not ok then log("Marks: the click: %s", tostring(e)) end
end)

local function clicks()
    for _, r in pairs(rings) do
        if r.btn and r.clickable then
            local down = false
            pcall(function() down = r.btn.btnShow:IsPressed() == true end)
            if down and not r.down then press(r) end
            r.down = down
        end
    end
end

-- Automatically mark accepted deliveries (a setting of this feature): the order this player
-- has just confirmed on Shady Comm is marked for them, unless somebody has it already.
Core.Hooks.add(INTERFACE .. ":" .. CONFIRM, function(ctx)
    if not live() or not on() or not Core.experimental("AutoMark") then return end
    local contact = nil
    pcall(function() contact = ctx:get().curSelectedUser end)
    if type(contact) ~= "number" or contact < 0 then return end
    local function look(again)
        if not live() or not World.player() then return end
        Orders.forget()
        local client, c = Orders.clientOfContact(contact)
        if client and c.order and c.accepted then
            if not marks[client] then
                Marks.toggle(client)
                dirty = true
            end
        elseif again > 0 then
            -- (the order is accepted a moment after the button)
            Core.after(0.7, function() look(again - 1) end)
        end
    end
    Core.after(0.3, function() look(3) end)
end)

---------------------------------------------------------------- the colour screen

local function closePicker()
    local s = picker
    picker = nil
    if s and s.open then pcall(s.close) end
end

local function backToComputer()
    pcall(function()
        local now = interface()
        local pc = World.player():GetController()
        if now and valid(pc) then
            library():SetInputMode_GameAndUIEx(pc, now, 2, false)
            pc.bShowMouseCursor = true
        end
    end)
end

local function choose(hex)
    Colours.set(hex)
    closePicker()
end

local function stopTyping(s)
    if not s.typing then return end
    s.typing = nil
    Core.typing = nil
    pcall(function()
        local pc = World.player():GetController()
        if valid(pc) and valid(s.widget) then
            library():SetInputMode_GameAndUIEx(pc, s.widget, 0, false)
            pc.bShowMouseCursor = true
        end
    end)
    s.mouseAt = os.clock() + 0.5
end

local function startTyping(s)
    if s.typing or Core.typing or not valid(s.edit) then return end
    local pc = World.player():GetController()
    if not valid(pc) then return end
    local ok = pcall(function()
        s.edit:SetText(FText(""))
        library():SetInputMode_UIOnlyEx(pc, s.edit, 2)
        s.edit:SetKeyboardFocus()
    end)
    if not ok then return end
    s.typing = { at = os.clock() }
    Core.typing = true
end

local function openPicker()
    if picker or not on() then return end
    if not interface() then return end
    local s = Screen.open()
    if not s then return end
    picker = s
    s.onClose = function()
        if picker == s then picker = nil end
        if s.typing then
            s.typing = nil
            Core.typing = nil
        end
        backToComputer()
    end
    s.fill(s.box({ R = 0, G = 0, B = 0, A = 0.9 }), 0)
    local now = Colours.hexOf()
    local column = s.new("VerticalBox")
    local head = s.new("HorizontalBox")
    head:AddChildToHorizontalBox(s.text("YOUR COLOUR", "button", 22)):SetVerticalAlignment(2)
    local x = s.bigButton("X", 1.3, closePicker)
    s.tint(x, Screen.RED)
    local xs = head:AddChildToHorizontalBox(x.box)
    xs:SetPadding({ Left = 40, Top = 0, Right = 0, Bottom = 0 })
    xs:SetVerticalAlignment(2)
    local hs = column:AddChildToVerticalBox(head)
    hs:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 18 })
    hs:SetHorizontalAlignment(2)
    -- two rows of six colours
    local offered = Colours.places()
    for _, hex in ipairs(Marks.MORE) do offered[#offered + 1] = hex end
    local row = nil
    for i, hex in ipairs(offered) do
        if (i - 1) % 6 == 0 then
            row = s.new("HorizontalBox")
            local rs = column:AddChildToVerticalBox(row)
            rs:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 14 })
            rs:SetHorizontalAlignment(2)
        end
        local hit = s.hit("colour:" .. hex, function() choose(hex) end)
        local stack = s.new("Overlay")
        stack:AddChildToOverlay(s.sized(s.box(Colours.fromHex(hex)), 64, 64))
        local os_ = stack:AddChildToOverlay(hit.widget)
        os_:SetHorizontalAlignment(0)
        os_:SetVerticalAlignment(0)
        local frame = s.box(hex == now and Screen.WHITE or { R = 0.02, G = 0.02, B = 0.025, A = 1 }, s.sized(stack, 64, 64), 4)
        row:AddChildToHorizontalBox(frame):SetPadding({ Left = 7, Top = 0, Right = 7, Bottom = 0 })
    end
    -- the colour written out: a chip of it, "#" and the six digits (typed into)
    local field = s.new("HorizontalBox")
    s.chip = s.box(Colours.fromHex(now))
    local cs = field:AddChildToHorizontalBox(s.sized(s.chip, 26, 26))
    cs:SetPadding({ Left = 10, Top = 0, Right = 10, Bottom = 0 })
    cs:SetVerticalAlignment(2)
    local ps = field:AddChildToHorizontalBox(s.text("#", "button", 20, Screen.GREY))
    ps:SetPadding({ Left = 0, Top = 0, Right = 4, Bottom = 0 })
    ps:SetVerticalAlignment(2)
    local edit = s.new("EditableText")
    pcall(function()
        local style = edit.WidgetStyle
        style.Font = s.text("", "button", 20).Font
        style.Font.Size = 20
    end)
    pcall(function() edit:SetText(FText(now)) end)
    pcall(function() edit:SetHintText(FText(now)) end)
    pcall(function() edit:SetVisibility(NO_HIT) end)
    local es = field:AddChildToHorizontalBox(edit)
    es:SetSize({ SizeRule = 1, Value = 1 })
    es:SetVerticalAlignment(2)
    s.edit, s.shownHex = edit, now
    local fieldHit = s.hit("hex", function() startTyping(s) end)
    local fieldStack = s.new("Overlay")
    fieldStack:AddChildToOverlay(s.box({ R = 0.02, G = 0.02, B = 0.025, A = 1 }, field, 0))
    local fh = fieldStack:AddChildToOverlay(fieldHit.widget)
    fh:SetHorizontalAlignment(0)
    fh:SetVerticalAlignment(0)
    -- the field from the left edge of the colours, USE up to their right edge
    local bottom = s.new("HorizontalBox")
    local fs = bottom:AddChildToHorizontalBox(s.sized(fieldStack, nil, 44))
    fs:SetSize({ SizeRule = 1, Value = 1 })
    fs:SetVerticalAlignment(2)
    local use = s.bigButton("USE", 1.3, function()
        local typed = ""
        pcall(function() typed = s.edit:GetText():ToString() end)
        local hex = Colours.clean(typed)
        if hex then choose(hex) end
    end)
    s.tint(use, Screen.GREEN)
    local us = bottom:AddChildToHorizontalBox(use.box)
    us:SetPadding({ Left = 18, Top = 0, Right = 0, Bottom = 0 })
    us:SetVerticalAlignment(2)
    local bs = column:AddChildToVerticalBox(s.sized(bottom, 6 * 72 + 5 * 14, nil))
    bs:SetPadding({ Left = 0, Top = 6, Right = 0, Bottom = 0 })
    bs:SetHorizontalAlignment(2)
    s.place(column, 0.5, 0.5, 0, 0)
end
Marks.openPicker, Marks.closePicker = openPicker, closePicker

-- While the colour screen is open: the chip follows what is typed; Enter (the field gives
-- the keyboard up) takes a whole colour, anything less stays to be typed on.
local function pickerTick(s)
    local text = ""
    pcall(function() text = s.edit:GetText():ToString() end)
    local clean = text:gsub("[^%x]", ""):upper():sub(1, 6)
    if clean ~= text then pcall(function() s.edit:SetText(FText(clean)) end) end
    local hex = Colours.clean(clean)
    if hex and #clean == 6 and hex ~= s.shownHex then
        s.shownHex = hex
        pcall(function() s.chip:SetBrushColor(Colours.fromHex(hex)) end)
    end
    if s.typing then
        local focused = false
        pcall(function() focused = s.edit:HasKeyboardFocus() == true end)
        if not focused and os.clock() - s.typing.at > 0.3 then
            stopTyping(s)
            if hex and #clean == 6 then choose(hex) end
        end
    end
end

---------------------------------------------------------------- the player's own row

local wasDown = false

local function detach()
    if not att then return end
    pcall(function() if valid(att.button) then att.button:RemoveFromParent() end end)
    pcall(function() if valid(att.buttonBox) then att.buttonBox:RemoveFromParent() end end)
    pcall(function() if valid(att.ring) then att.ring:RemoveFromParent() end end)
    att = nil
end

-- The ring round a picture that sits in an overlay (Shady Comm of the game's UE 4.27 build):
-- painted to fill its own image, which is as large as the picture (the overlay keeps its
-- size) and drawn `grow` larger all round.
local function makeRingOver(owner, pic, grow)
    local overlay = pic:GetParent()
    local across = 0
    pcall(function() across = pic.Brush.ImageSize.X end)
    if not valid(overlay) or not across or across < 8 then return nil end
    local saved = Marks.RING_WIDTH
    Marks.RING_WIDTH = saved * RING_UNITS / (across + 2 * grow)
    local ok, rt = pcall(ringPicture, RING_UNITS)
    Marks.RING_WIDTH = saved
    if not ok or not rt then return nil end
    local img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), owner.WidgetTree)
    if not valid(img) then return nil end
    pcall(function() img:SetBrushFromTexture(rt, false) end)
    pcall(function()
        local now = img.Brush.ResourceObject
        if not valid(now) or now:GetAddress() ~= rt:GetAddress() then img.Brush.ResourceObject = rt end
        img.Brush.ImageSize = { X = across, Y = across }
    end)
    img:SetVisibility(NO_HIT)
    local slot = overlay:AddChildToOverlay(img)
    slot:SetHorizontalAlignment(2)   -- centre
    slot:SetVerticalAlignment(2)
    img:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
    img:SetRenderScale({ X = (across + 2 * grow) / across, Y = (across + 2 * grow) / across })
    return img
end

local function attach(ui)
    local a = { address = ui:GetAddress() }
    local panel = ui.btnDesktop:GetParent()
    a.onCanvas = panel:GetClass():GetFName():ToString() == "CanvasPanel"
    if not a.onCanvas then
        -- the game's UE 4.27 build: the picture in an overlay, PICTURE in a row under the
        -- name (both found by coop/shady.lua); the ring and COLOUR are added once those are
        -- there (placeButton)
        pcall(function()
            local player = World.player()
            local w = library():Create(player, Core.class(TAB), player:GetController())
            w.txtBtnName:SetText(FText("COLOUR"))
            w.btnShow:SetRenderOpacity(1)
            a.button = w
        end)
        return a
    end
    -- the ring round the player's picture (the picture is 50 across at 20, 20)
    pcall(function() a.ring = makeRing(ui, panel, 20, 20, 50, 2) end)
    -- COLOUR, beside PICTURE (coop/shady.lua's button). It is put in place once PICTURE
    -- has been laid out and has a size (placeButton).
    pcall(function()
        local player = World.player()
        local w = library():Create(player, Core.class(TAB), player:GetController())
        w.txtBtnName:SetText(FText("COLOUR"))
        w.btnShow:SetRenderOpacity(1)
        w:SetRenderTransformPivot({ X = 0, Y = 0 })
        w:SetRenderScale({ X = 0.62, Y = 0.62 })
        local slot = panel:AddChildToCanvas(w)
        slot:SetAutoSize(true)
        slot:SetPosition({ X = 74, Y = 48 })
        slot:SetZOrder(5)
        w:SetVisibility(COLLAPSED)
        a.button, a.slot = w, slot
    end)
    return a
end

-- True once COLOUR stands beside PICTURE.
local function placeButton(a)
    if a.placed or not a.button then return a.placed == true end
    a.tries = (a.tries or 0) + 1
    local x, y = nil, nil
    local Shady = package.loaded["coop.shady"]
    local theirs = type(Shady) == "table" and Shady.attached and Shady.attached() or nil
    if not a.onCanvas then
        -- beside PICTURE in its row, made as small by a scale box; the ring on the picture
        if not (theirs and valid(theirs.buttonRow) and valid(theirs.image)) then return false end
        local ui = interface()
        if not ui then return false end
        if not a.ring then pcall(function() a.ring = makeRingOver(ui, theirs.image, 2) end) end
        local box = StaticConstructObject(StaticFindObject("/Script/UMG.ScaleBox"), ui.WidgetTree)
        box:SetStretch(7)                -- UserSpecified
        box:SetUserSpecifiedScale(0.62)
        box:AddChild(a.button)
        local slot = theirs.buttonRow:AddChildToHorizontalBox(box)
        slot:SetPadding({ Left = 4, Top = 0, Right = 0, Bottom = 0 })
        a.buttonBox = box
        a.placed = true
        return true
    end
    if theirs and valid(theirs.button) then
        pcall(function()
            local p = theirs.button.Slot:GetPosition()
            local size = theirs.button:GetDesiredSize()
            if size.X > 1 then x, y = p.X + size.X * 0.62 + 4, p.Y end
        end)
    end
    -- (no PICTURE button after a few looks: where that one would be)
    if not x and a.tries > 8 then x, y = 74, 48 end
    if not x then return false end
    pcall(function()
        a.slot:SetPosition({ X = x, Y = y })
        a.button:SetVisibility(4)
    end)
    a.placed = true
    return true
end

Core.onTick(function()
    if not live() then return end
    if picker then
        local ok, e = pcall(pickerTick, picker)
        if not ok then log("Marks: the colour screen: %s", tostring(e)) end
        return
    end
    if not att then return end
    local ui = interface()
    if not ui or ui:GetAddress() ~= att.address then
        att, rings = nil, {}
        return
    end
    if dirty then
        dirty = false
        local ok, e = pcall(decorate, ui)
        if not ok then log("Marks: the contact list: %s", tostring(e)) end
    end
    pcall(clicks)
    local down = false
    pcall(function() down = att.button ~= nil and att.button.btnShow:IsPressed() end)
    if down and not wasDown then
        local ok, e = pcall(openPicker)
        if not ok then log("Marks: the colour screen: %s", tostring(e)) end
    end
    wasDown = down
end)

Core.every(0.5, function()
    if not live() then return end
    local player = World.player()
    if not player or World.joining or World.gone then
        att, rings = nil, {}
        if picker then picker = nil end
        return
    end
    local ui = interface()
    if not ui then
        att, rings = nil, {}
        if picker then closePicker() end
        return
    end
    if not on() then
        if att then
            detach()
            pcall(decorate, ui)
        end
        return
    end
    if not att or att.address ~= ui:GetAddress() then
        local made, a = pcall(attach, ui)
        if not made then
            log("Marks: the player's row: %s", tostring(a))
            return
        end
        att = a
    end
    pcall(placeButton, att)
    -- the ring round the player's own picture
    local hex = Colours.hexOf()
    if att.ring and att.hex ~= hex then
        if pcall(function() att.ring:SetColorAndOpacity(Colours.fromHex(hex)) end) then att.hex = hex end
    end
    local ok, e = pcall(decorate, ui)
    if not ok then log("Marks: the contact list: %s", tostring(e)) end
end)

---------------------------------------------------------------- the map and the compass

-- The other players' markers (coop/teammap.lua) are their own colour on the map; so that a
-- player and the clients that player has marked can be told apart, a marked client's icon
-- on the map and the compass is that colour let through only this much.
Marks.CLIENT_SHADE = 0.8

local function shaded(hex)
    local c = Colours.fromHex(hex)
    c.A = Marks.CLIENT_SHADE
    return c
end

-- name of the marker -> colour, for the other players in the lobby
local function playerColours()
    local out = {}
    if not on() then return out end
    for id, name in pairs(Net.S.members or {}) do
        if tostring(id) ~= me() then out[tostring(name)] = Colours.hexOf(id) end
    end
    return out
end

-- name on the map -> colour, for every marked client that is out there
local function wanted()
    local out = nil
    if not on() then return nil end
    local clients = nil
    for client, m in pairs(marks) do
        clients = clients or Orders.clients()
        local c = clients[client]
        if c and c.order == m.o and c.accepted then
            out = out or {}
            out[c.name] = Colours.hexOf(m.p)
        end
    end
    return out
end

local map = { widget = nil, painted = {} }

local function paintMap(player, want)
    local open = false
    pcall(function() open = player.mapOpen == true end)
    if not open then
        map.widget, map.painted = nil, {}
        return
    end
    local w = map.widget
    local there = false
    if w then pcall(function() there = valid(w) and w:IsInViewport() end) end
    if not there then
        w = FindFirstOf("worldMapWidget_C")
        there = false
        pcall(function() there = valid(w) and w:IsInViewport() end)
        map.widget, map.painted = there and w or nil, {}
        if not there then return end
    end
    local painted = {}
    local players = playerColours()
    pcall(function()
        w.mapMarkers:ForEach(function(_, v)
            local m = v:get()
            if not valid(m) then return end
            local address = m:GetAddress()
            local name = m.txtMarkerName:GetText():ToString()
            local dealer = false
            if name:sub(-#DEALER_WORDS) == DEALER_WORDS then
                name, dealer = name:sub(1, -#DEALER_WORDS - 1), true
            end
            -- (a player's marker is one the game draws as a dealer's)
            local hex, key = nil, nil
            if dealer and players[name] then
                hex, key = players[name], players[name] .. "p"
            elseif want and want[name] then
                hex, key = want[name], want[name] .. "c"
            end
            local before = map.painted[address]
            if hex then
                if before ~= key then
                    local c = key:sub(-1) == "c" and shaded(hex) or Colours.fromHex(hex)
                    m.icon:SetColorAndOpacity(c)
                    m.txtMarkerName:SetColorAndOpacity(slate(c))
                end
                painted[address] = key
            elseif before then
                -- (no longer marked while the map is open: the game's colours again)
                local own = dealer and MAP_DEALER or MAP_CLIENT
                m.icon:SetColorAndOpacity(own[1])
                m.txtMarkerName:SetColorAndOpacity(slate(own[2]))
            end
        end)
    end)
    map.painted = painted
end

local compass = { painted = {}, count = 0 }

local function paintCompass(player, want)
    local hud = player.HUD
    if not valid(hud) or not valid(hud.compasMarkersHolder) then return end
    local n = 0
    for _ in pairs(want or {}) do n = n + 1 end
    if n == 0 then
        -- (the last mark is gone: the compass is made again in the game's colours)
        if next(compass.painted) then
            compass.painted = {}
            pcall(function() hud:refreshCompass() end)
        end
        return
    end
    -- where the marked clients' markers are
    local spots = {}
    for _, a in ipairs(Core.actors(MARKER) or {}) do
        pcall(function()
            if a.markerCategory ~= 3 then return end
            local hex = want[a.MarkerName:ToString()]
            if not hex then return end
            local l = a:K2_GetActorLocation()
            spots[#spots + 1] = { x = l.X, y = l.Y, hex = hex }
        end)
    end
    local painted, lost = {}, false
    local places = {}
    hud.compassLocations:ForEach(function(i, v)
        local l = v:get()
        places[i] = { l.X, l.Y }
    end)
    for i, place in ipairs(places) do
        local widget = hud.compasMarkersHolder:GetChildAt(i - 1)
        if valid(widget) then
            local address = widget:GetAddress()
            local hex = nil
            for _, s in ipairs(spots) do
                if math.abs(place[1] - s.x) < 2 and math.abs(place[2] - s.y) < 2 then hex = s.hex break end
            end
            if hex then
                if compass.painted[address] ~= hex then pcall(function() widget.Image_0:SetColorAndOpacity(shaded(hex)) end) end
                painted[address] = hex
            elseif compass.painted[address] then
                lost = true
            end
        end
    end
    compass.painted = painted
    -- (a marker that was ours and is no longer: the game makes the compass again, ours are
    -- painted at the next look)
    if lost then
        compass.painted = {}
        pcall(function() hud:refreshCompass() end)
    end
end

Core.every(0.3, function()
    if not live() then return end
    local player = World.player()
    if not player or World.joining or World.gone then
        map.widget, map.painted = nil, {}
        return
    end
    local want = wanted()
    if not want and not next(map.painted) and not map.widget then
        local open = false
        pcall(function() open = player.mapOpen == true end)
        if not open then return end
    end
    local ok, e = pcall(paintMap, player, want)
    if not ok then log("Marks: the map: %s", tostring(e)) end
end)

Core.every(1, function()
    if not live() then return end
    local player = World.player()
    if not player or World.joining or World.gone then
        compass.painted = {}
        return
    end
    local want = wanted()
    if not want and not next(compass.painted) then return end
    local ok, e = pcall(paintCompass, player, want)
    if not ok then log("Marks: the compass: %s", tostring(e)) end
end)

-- A colour has changed: what carries it is painted again.
Colours.onChange(function()
    if not live() then return end
    bump()
    dirty = true
    map.painted, compass.painted = {}, {}
end)

-- (the switch on the TWEAKS page)
function Marks.apply()
    dirty = true
    map.painted = {}
    local Ord = package.loaded["coop.orders"]
    if type(Ord) == "table" and Ord.refresh then pcall(Ord.refresh) end
end

function Marks.shutdown()
    closePicker()
    detach()
end

-- (for test scripts)
function Marks.attached() return att end
function Marks.rings() return rings end
function Marks.picker() return picker end
function Marks.painted() return map.painted, compass.painted end
function Marks.setMarks(list) marks = list bump() end

return Marks
