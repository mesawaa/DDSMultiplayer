-- Full-screen, mouse-driven screens in the game's own look.
--
-- A script cannot make a widget from the bare engine class, and copying a button's style
-- struct crashes the game, so screens are put together from the game's own small widgets:
-- a shop filter tab is both the container (it is a canvas with one button row) and the
-- button; fonts are copied from a shop item card. Clicks are noticed twice over: by a
-- hook on the tab's own click event and by asking every button on every tick whether it
-- is held down; whichever comes first counts.

local Core = require("core")
local World = require("coop.world")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_SCREEN_GEN") or 0) + 1
_G.DDSMP_SCREEN_GEN = GEN
local function live() return rawget(_G, "DDSMP_SCREEN_GEN") == GEN end

local Screen = { current = nil }

local TAB = "/Game/GUI/EquipmentShopping/EquipmentShopCatFilter.EquipmentShopCatFilter_C"
local ITEM = "/Game/GUI/EquipmentShopping/equipmentShopItemWidget.equipmentShopItemWidget_C"
local CLICK = TAB .. ":BndEvt__btnShowFunctional_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local COLLAPSED, NO_HIT = 1, 3

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

local function library() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end

Screen.WHITE = { R = 1, G = 1, B = 1, A = 1 }
Screen.GREY = { R = 0.55, G = 0.55, B = 0.55, A = 1 }
Screen.GREEN = { R = 0.3, G = 0.85, B = 0.2, A = 1 }
Screen.RED = { R = 0.85, G = 0.1, B = 0.1, A = 1 }

-- Opens an empty screen over the game and gives the mouse to it. Returns the screen, or
-- nil when the game's widgets are not available.
function Screen.open()
    if Screen.current then Screen.current.close() end
    local player = World.player()
    if not player then return nil end
    local pc = player:GetController()
    local tabClass, itemClass = asset(TAB), asset(ITEM)
    if not tabClass or not itemClass or not valid(pc) then return nil end
    local lib = library()
    local W = lib:Create(player, tabClass, pc)
    if not valid(W) or not valid(W.WidgetTree) or not valid(W.WidgetTree.RootWidget) then return nil end

    local s = { widget = W, buttons = {}, byAddress = {}, open = true }
    local ownerAddress = player:GetAddress()
    local tree, root = W.WidgetTree, W.WidgetTree.RootWidget
    s.canvas = root
    for k = 0, root:GetChildrenCount() - 1 do root:GetChildAt(k):SetVisibility(COLLAPSED) end

    function s.new(kind) return StaticConstructObject(StaticFindObject("/Script/UMG." .. kind), tree) end

    -- Fonts: copied into text blocks of our own, which stay in the screen.
    local proto = {}
    local item = lib:Create(player, itemClass, pc)
    local function keep(name, source)
        local t = s.new("TextBlock")
        pcall(function() t:SetFont(source.Font) end)
        t:SetVisibility(COLLAPSED)
        root:AddChildToCanvas(t)
        proto[name] = t
    end
    keep("button", item.txtButtonText)
    keep("name", item.txtItemNam)
    keep("price", item.txtItemPrice)
    keep("small", item.txtDesc)
    -- The HUD's font has the card suits.
    pcall(function()
        local Hud = require("coop.hud")
        if Hud.ready() and Hud.state().font then keep("hud", Hud.state().font) end
    end)
    if not proto.hud then proto.hud = proto.name end

    -- Puts a widget at a fraction of the screen, shifted by (x, y).
    function s.place(widget, ax, ay, x, y, alignX, alignY)
        local slot = root:AddChildToCanvas(widget)
        slot:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } })
        slot:SetAlignment({ X = alignX or 0.5, Y = alignY or 0.5 })
        slot:SetAutoSize(true)
        slot:SetPosition({ X = x or 0, Y = y or 0 })
        return slot
    end

    -- Covers the whole screen (a dimmed background, for example).
    function s.fill(widget, z)
        local slot = root:AddChildToCanvas(widget)
        slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
        slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        if z then slot:SetZOrder(z) end
        return slot
    end

    -- Covers a part of the screen given as fractions of it.
    function s.area(widget, x0, y0, x1, y1, z)
        local slot = root:AddChildToCanvas(widget)
        slot:SetAnchors({ Minimum = { X = x0, Y = y0 }, Maximum = { X = x1, Y = y1 } })
        slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        if z then slot:SetZOrder(z) end
        return slot
    end

    function s.text(str, font, size, color)
        local t = s.new("TextBlock")
        t:SetFont((proto[font or "button"] or proto.button).Font)
        if size then
            local f = t.Font
            f.Size = math.floor(size + 0.5)
            t:SetFont(f)
        end
        t:SetColorAndOpacity({ SpecifiedColor = color or Screen.WHITE, ColorUseRule = 0 })
        t:SetText(FText(str))
        t:SetVisibility(NO_HIT)
        return t
    end

    function s.box(color, child, padding)
        local b = s.new("Border")
        b:SetBrushColor(color)
        if padding then b:SetPadding({ Left = padding, Top = padding, Right = padding, Bottom = padding }) end
        if child then b:AddChild(child) end
        return b
    end

    function s.sized(child, w, h)
        local box = s.new("SizeBox")
        if w then box:SetWidthOverride(w) end
        if h then box:SetHeightOverride(h) end
        if child then box:AddChild(child) end
        return box
    end

    -- A box that draws its child larger or smaller and takes up exactly the room it then
    -- needs. (A render scale leaves the room unchanged, so that neighbours overlap or
    -- stand at uneven distances.)
    function s.scaled(child, scale)
        local box = s.new("ScaleBox")
        pcall(function()
            box:SetStretch(7)                       -- by the factor given
            box:SetUserSpecifiedScale(scale)
        end)
        box:AddChild(child)
        return box
    end

    -- A button of another size for laying out: `box` is what goes into the screen.
    function s.bigButton(label, scale, onClick)
        local b = s.button(label, nil, onClick)
        b.box = s.scaled(b.widget, scale)
        return b
    end

    -- The size of the picture in the units widgets are laid out in (the game scales its
    -- interface with the height of the window: about 1080 units high at any size).
    function s.units()
        local w, h, scale = {}, {}, 1
        pc:GetViewportSize(w, h)
        pcall(function() scale = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportScale(player) end)
        if type(scale) ~= "number" or scale <= 0 then scale = 1 end
        return (tonumber(w.SizeX) or 1920) / scale, (tonumber(h.SizeY) or 1080) / scale
    end

    -- A button in the game's style. Returns a record with `widget`; set `enabled = false`
    -- with s.enable(button, false).
    function s.button(label, scale, onClick)
        local w = lib:Create(player, tabClass, pc)
        w.txtBtnName:SetText(FText(label))
        w.btnShow:SetRenderOpacity(1)
        pcall(function() w.txtBtnName:SetColorAndOpacity({ SpecifiedColor = Screen.WHITE, ColorUseRule = 0 }) end)
        if scale then w:SetRenderScale({ X = scale, Y = scale }) end
        -- `fresh` until the next tick: a button is made first and put into the screen (or
        -- into a box that goes into the screen) a moment later.
        local b = { widget = w, onClick = onClick, enabled = true, label = label, address = w:GetAddress(), fresh = true }
        s.buttons[#s.buttons + 1] = b
        s.byAddress[b.address] = b
        return b
    end

    -- An invisible button that fills whatever room it is given (a card, under its
    -- picture and words): clicking anywhere on the card that is not one of the card's own
    -- buttons presses it. `label` names it for tests (Screen.click("hit:" .. label)).
    -- (The tab's button sits in a row on the tab's canvas: the row is stretched over the
    -- canvas and the button over the row.)
    function s.hit(label, onClick)
        local b = s.button("", nil, onClick)
        b.label = "hit:" .. tostring(label)
        local w = b.widget
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
        return b
    end


    -- Where a widget hangs: "screen" when it sits somewhere under this screen's canvas,
    -- otherwise the address of the outermost box it is in (nil when it is in none).
    local rootAddress = root:GetAddress()
    local function topOf(w)
        local cur, address = w, nil
        for _ = 1, 16 do
            local ok, parent = pcall(function() return cur:GetParent() end)
            if not ok or not valid(parent) then break end
            local a = parent:GetAddress()
            if a == rootAddress then return "screen" end
            cur, address = parent, a
        end
        return address
    end
    s.topOf = topOf

    function s.forget(i)
        local b = table.remove(s.buttons, i)
        if b and s.byAddress[b.address] == b then s.byAddress[b.address] = nil end
    end

    function s.enable(b, on)
        b.enabled = on
        pcall(function()
            b.widget.btnShow:SetRenderOpacity(on and 1 or 0.35)
            b.widget.btnShow:SetIsEnabled(on)
        end)
    end

    function s.tint(b, color)
        pcall(function() b.widget.txtBtnName:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
    end

    function s.label(b, str)
        b.label = str
        pcall(function() b.widget.txtBtnName:SetText(FText(str)) end)
    end

    -- Takes widgets out of the screen. Every button that leaves with them is forgotten in
    -- the same call, also the ones inside a removed box: the engine destroys those widgets
    -- at its next garbage collection, and a call on a destroyed widget (is it pressed?
    -- what is it in?) crashes the game. A button made this tick that is not in anything
    -- removed is kept: it is put into the screen a moment after it is made.
    function s.removeAll(widgets)
        local gone = {}
        for _, widget in ipairs(widgets) do
            pcall(function()
                if valid(widget) then
                    gone[widget:GetAddress()] = true
                    widget:RemoveFromParent()
                end
            end)
        end
        for i = #s.buttons, 1, -1 do
            local b = s.buttons[i]
            local drop = gone[b.address] == true
            if not drop then
                local top = topOf(b.widget)
                drop = top ~= "screen" and ((top ~= nil and gone[top] == true) or not b.fresh)
            end
            if drop then s.forget(i) end
        end
    end

    function s.remove(widget) s.removeAll({ widget }) end

    function s.close()
        if not s.open then return end
        s.open = false
        if Screen.current == s then Screen.current = nil end
        -- The widgets went with the world they were made in: when that is gone (or another
        -- one is being played) they are only forgotten.
        local now = World.player()
        if World.gone or not now or now:GetAddress() ~= ownerAddress then
            s.buttons, s.byAddress = {}, {}
            if s.onClose then pcall(s.onClose) end
            return
        end
        pcall(function() if valid(W) then W:RemoveFromParent() end end)
        pcall(function()
            local p = World.player()
            local c = p and p:GetController()
            if valid(c) then
                lib:SetInputMode_GameOnly(c)
                c.bShowMouseCursor = false
            end
        end)
        if s.onClose then pcall(s.onClose) end
    end

    W:AddToViewport(40)
    pcall(function()
        lib:SetInputMode_GameAndUIEx(pc, W, 0, false)
        pc.bShowMouseCursor = true
    end)
    s.mouseAt = os.clock() + 0.5
    Screen.current = s
    return s
end

-- The mouse belongs to the open screen. Two things take it away without the screen
-- knowing: switching to another program and back (the game comes back looking around with
-- the mouse, no pointer), and the game's own windows (inventory, phone, map), which hand
-- the mouse to the game when they close. So the screen takes the mouse again: at once when
-- the pointer is found switched off, and otherwise twice a second, which costs nothing when
-- nothing was lost. Never while a mouse button is down (taking the mouse lets go of a
-- pressed button and of the held look-around at the card table) and never while one of the
-- game's windows is up (those need the mouse themselves). A button held on a widget of the
-- engine's own (the handle of a scroll bar, of a slider) is not seen as down from here: a
-- screen with such a widget says when to leave the mouse alone (`s.holdMouse()`).
local GAME_WINDOWS = { "inventoryOpen", "phoneUp", "computerOpen", "mapOpen", "saveScreenOpen", "isTrading" }
local LMB, RMB = nil, nil

local function keepMouse(s, anyDown)
    -- (a chat line being typed has the keyboard; the chat gives the mouse back when it closes)
    if Core.typing then return end
    local player = World.player()
    if not player or World.gone then return end
    local pc = player:GetController()
    if not valid(pc) then return end
    for _, f in ipairs(GAME_WINDOWS) do
        if player[f] == true then
            s.mouseAt = 0        -- (taken back the moment that window closes)
            return
        end
    end
    local now = os.clock()
    local lost = pc.bShowMouseCursor ~= true
    if not lost and now < (s.mouseAt or 0) then return end
    if anyDown then return end
    LMB = LMB or { KeyName = FName("LeftMouseButton") }
    RMB = RMB or { KeyName = FName("RightMouseButton") }
    if pc:IsInputKeyDown(LMB) == true or pc:IsInputKeyDown(RMB) == true then return end
    if not lost and s.holdMouse then
        local ok, hold = pcall(s.holdMouse)
        if ok and hold == true then
            s.held = (s.held or 0) + 1
            return
        end
    end
    s.mouseAt = now + 0.5
    library():SetInputMode_GameAndUIEx(pc, s.widget, 0, false)
    pc.bShowMouseCursor = true
    if lost then s.mouseTaken = (s.mouseTaken or 0) + 1 end
end

local function fire(b)
    if not b.enabled or not b.onClick then return end
    local now = os.clock()
    if now - (b.firedAt or 0) < 0.35 then return end
    b.firedAt = now
    local ok, e = xpcall(b.onClick, debug.traceback)
    if not ok then log("Screen: button %s: %s", tostring(b.label), tostring(e)) end
end

Core.Hooks.add(CLICK, function(context)
    if not live() then return end
    local s = Screen.current
    if not s then return end
    local w = context:get()
    local b = valid(w) and s.byAddress[w:GetAddress()] or nil
    if b then fire(b) end
end)

Core.onTick(function()
    if not live() then return end
    local s = Screen.current
    if not s then return end
    if not valid(s.widget) then
        Screen.current = nil
        return
    end
    -- A button that was made on an earlier tick and never put into the screen is dropped.
    for i = #s.buttons, 1, -1 do
        local b = s.buttons[i]
        if b.fresh then
            b.fresh = nil
            if s.topOf(b.widget) ~= "screen" then s.forget(i) end
        end
    end
    local pressed, anyDown = nil, false
    for _, b in ipairs(s.buttons) do
        local ok, down = pcall(function() return b.widget.btnShow:IsPressed() end)
        if ok then
            if down and not b.down then pressed = pressed or b end
            if down then anyDown = true end
            b.down = down
        end
    end
    if not s.ownMouse then pcall(keepMouse, s, anyDown) end
    if pressed then fire(pressed) end
end)

-- Presses a button from a script (tests).
function Screen.click(label)
    local s = Screen.current
    if not s then return false end
    for _, b in ipairs(s.buttons) do
        if b.label == label then
            b.firedAt = nil
            fire(b)
            return true
        end
    end
    return false
end

return Screen
