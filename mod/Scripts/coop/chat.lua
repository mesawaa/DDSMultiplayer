-- Lobby chat. A key opens a line to type on (config ChatKey, "/"), Enter sends it to
-- everybody in the lobby, Escape puts it away. A message shows at the lower left for a few
-- seconds and fades; while the line is open the last messages are all there.
--
-- The widgets are a screen-wide panel of the mod's own, above everything else the mod puts
-- up (the card table and the shops are where people talk). It never takes the mouse. The
-- line to type on is the engine's editable text: while it has the keyboard the game gets no
-- keys at all, so typing walks nowhere and opens nothing, and Escape does not pause.
--
-- What ends the typing:
--   Enter    the text box gives the keyboard up by itself when Enter is pressed; that, or
--            the Enter key seen by the mod's own key watcher, sends the line.
--   Escape   seen by the key watcher only (the text box ignores it): nothing is sent.
--   anything else that takes the keyboard (the game starts a talk, an arrest): what was
--            typed is sent and the input is left as the game has set it.
-- The other keys of the mod do nothing while the line is open (Core.typing).

local Core = require("core")
local Net = require("net")
local World = require("coop.world")

local log, valid = Core.log, Core.valid
local config = Core.config

-- (a copy of this file loaded again by a test replaces the one before)
local GEN = (rawget(_G, "DDSMP_CHAT_GEN") or 0) + 1
_G.DDSMP_CHAT_GEN = GEN
local function live() return rawget(_G, "DDSMP_CHAT_GEN") == GEN end

local Chat = {}

local TAB ="/Game/GUI/EquipmentShopping/EquipmentShopCatFilter.EquipmentShopCatFilter_C"
local VISIBLE, COLLAPSED, NO_HIT, SELF_NO_HIT = 0, 1, 3, 4
local BOLD = "/Game/GUI/Fonts/RobotoCondensed-Bold_Font.RobotoCondensed-Bold_Font"

Chat.ROWS = 8             -- messages on screen at most
Chat.SHOW = 8             -- seconds a message stays
Chat.FADE = 1.2           -- the last of them fading
Chat.MAX = 140            -- characters in one message
Chat.WIDTH = 560          -- of the lines, in interface units (the screen is 1080 high)
Chat.LEFT, Chat.BOTTOM = 25, 64
Chat.SIZE = 15
Chat.KEEP = 60            -- messages remembered

local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local RED = { R = 0.85, G = 0.08, B = 0.08, A = 1 }
-- one colour per player, by their place in the lobby's list
local NAMES = {
    { R = 1.0, G = 0.55, B = 0.10, A = 1 },
    { R = 0.30, G = 0.75, B = 1.0, A = 1 },
    { R = 0.45, G = 0.90, B = 0.35, A = 1 },
    { R = 1.0, G = 0.45, B = 0.75, A = 1 },
    { R = 1.0, G = 0.90, B = 0.30, A = 1 },
    { R = 0.70, G = 0.55, B = 1.0, A = 1 },
}

local lines = {}          -- { name, text, color, at }, oldest first
local changed = true      -- the rows have to be filled again
local ui = nil            -- widgets of the world being played
local failedFor = nil
local typing = nil        -- { at, lostAt, screen } while the line is open
local closedAt = -100
local lastSent = -100

local function library() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end
local function slate(c) return { SpecifiedColor = c, ColorUseRule = 0 } end

---------------------------------------------------------------- messages

local function clean(s)
    s = tostring(s or ""):gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #s > Chat.MAX then
        s = s:sub(1, Chat.MAX)
        -- not in the middle of a character of several bytes
        while #s > 0 and s:byte(#s) >= 128 and s:byte(#s) < 192 do s = s:sub(1, -2) end
        if #s > 0 and s:byte(#s) >= 192 then s = s:sub(1, -2) end
    end
    return s
end

local function colourOf(id)
    local ids = {}
    for member in pairs(Net.S.members) do ids[#ids + 1] = member end
    table.sort(ids)
    for i, member in ipairs(ids) do
        if member == id then return NAMES[(i - 1) % #NAMES + 1] end
    end
    return NAMES[1]
end

-- Puts a message on the screen (and into what is remembered).
function Chat.add(name, text, color)
    text = clean(text)
    if text == "" then return end
    lines[#lines + 1] = { name = tostring(name or "?"), text = text, color = color or NAMES[1], at = os.clock() }
    while #lines > Chat.KEEP do table.remove(lines, 1) end
    changed = true
end

-- Says something to the whole lobby. False when nothing was sent.
function Chat.say(text)
    text = clean(text)
    if text == "" then return false end
    local now = os.clock()
    if now - lastSent < 0.3 then return false end
    lastSent = now
    if Net.inLobby() then Net.send("chat", { m = text }) end
    Chat.add(Net.S.myName, text, colourOf(Net.S.me))
    return true
end

Net.on("chat", function(sender, data, name)
    if type(data.m) ~= "string" then return end
    log("Chat: %s: %s", tostring(Net.S.members[sender] or name), clean(data.m))
    Chat.add(Net.S.members[sender] or name, data.m, colourOf(sender))
end)

---------------------------------------------------------------- widgets

local function build(player)
    local pc = player:GetController()
    if not valid(pc) then error("no controller") end
    local class = StaticFindObject(TAB)
    if not valid(class) then
        pcall(function() LoadAsset((TAB:gsub("_C$", ""))) end)
        class = StaticFindObject(TAB)
    end
    if not valid(class) then error("no widget class") end
    local W = library():Create(player, class, pc)
    if not valid(W) or not valid(W.WidgetTree) or not valid(W.WidgetTree.RootWidget) then error("no widget") end
    local tree, root = W.WidgetTree, W.WidgetTree.RootWidget
    for k = 0, root:GetChildrenCount() - 1 do root:GetChildAt(k):SetVisibility(COLLAPSED) end
    local u = { owner = player:GetAddress(), widget = W, rows = {} }
    local function new(kind) return StaticConstructObject(StaticFindObject("/Script/UMG." .. kind), tree) end

    -- The game's bold font. The panel's own widget brings a font of the same family; the
    -- bold face is put into it. (Not taken from the HUD: right after a world has loaded the
    -- HUD's texts are not there to copy from, and the engine's plain font showed instead.)
    local font, bold = nil, nil
    pcall(function() font = W.txtBtnName.Font end)
    pcall(function()
        bold = StaticFindObject(BOLD)
        if not valid(bold) then
            pcall(function() LoadAsset(BOLD) end)
            bold = StaticFindObject(BOLD)
        end
        if not valid(bold) then bold = nil end
    end)
    u.font = font ~= nil and (bold and "bold" or "regular") or "none"
    local function label(color)
        local t = new("TextBlock")
        if font then pcall(function() t:SetFont(font) end) end
        pcall(function()
            local f = t.Font
            f.Size = Chat.SIZE
            if bold then f.FontObject = bold end
            t:SetFont(f)
        end)
        t:SetColorAndOpacity(slate(color))
        pcall(function()
            t:SetShadowOffset({ X = 1, Y = 1 })
            t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 })
        end)
        t:SetVisibility(NO_HIT)
        return t
    end

    -- the messages: a column that grows upwards from just above the line to type on
    local column = new("VerticalBox")
    for i = 1, Chat.ROWS do
        local name, words = label(WHITE), label(WHITE)
        pcall(function() words.AutoWrapText = true end)
        local row = new("HorizontalBox")
        row:AddChildToHorizontalBox(name):SetPadding({ Left = 0, Top = 0, Right = 7, Bottom = 0 })
        local ws = row:AddChildToHorizontalBox(words)
        ws:SetSize({ SizeRule = 1, Value = 1 })
        local back = new("Border")
        back:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.45 })
        back:SetPadding({ Left = 9, Top = 3, Right = 9, Bottom = 3 })
        back:AddChild(row)
        local size = new("SizeBox")
        size:SetWidthOverride(Chat.WIDTH)
        size:AddChild(back)
        size:SetVisibility(COLLAPSED)
        column:AddChildToVerticalBox(size)
        u.rows[i] = { box = size, name = name, words = words, shown = false, alpha = -1 }
    end
    column:SetVisibility(NO_HIT)
    local slot = root:AddChildToCanvas(column)
    slot:SetAnchors({ Minimum = { X = 0, Y = 1 }, Maximum = { X = 0, Y = 1 } })
    slot:SetAlignment({ X = 0, Y = 1 })
    slot:SetAutoSize(true)
    slot:SetPosition({ X = Chat.LEFT, Y = -(Chat.BOTTOM + 36) })

    -- the line to type on
    local edit = new("EditableText")
    pcall(function()
        local style = edit.WidgetStyle
        if font then style.Font = font end
        style.Font.Size = Chat.SIZE
        if bold then style.Font.FontObject = bold end
    end)
    local say = label(RED)
    say:SetText(FText("SAY"))
    local bar = new("HorizontalBox")
    local ss = bar:AddChildToHorizontalBox(say)
    ss:SetPadding({ Left = 0, Top = 0, Right = 9, Bottom = 0 })
    pcall(function() ss:SetVerticalAlignment(2) end)
    local es = bar:AddChildToHorizontalBox(edit)
    es:SetSize({ SizeRule = 1, Value = 1 })
    pcall(function() es:SetVerticalAlignment(2) end)
    local back = new("Border")
    back:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.7 })
    back:SetPadding({ Left = 9, Top = 5, Right = 9, Bottom = 5 })
    back:AddChild(bar)
    local size = new("SizeBox")
    size:SetWidthOverride(Chat.WIDTH)
    size:AddChild(back)
    local bslot = root:AddChildToCanvas(size)
    bslot:SetAnchors({ Minimum = { X = 0, Y = 1 }, Maximum = { X = 0, Y = 1 } })
    bslot:SetAlignment({ X = 0, Y = 1 })
    bslot:SetAutoSize(true)
    bslot:SetPosition({ X = Chat.LEFT, Y = -Chat.BOTTOM })
    size:SetVisibility(COLLAPSED)
    u.edit, u.bar = edit, size

    pcall(function() root:SetVisibility(SELF_NO_HIT) end)
    W:SetVisibility(SELF_NO_HIT)
    W:AddToViewport(45)
    return u
end

-- The widgets of the world being played, or nil (the main menu, a world on its way out).
local function panel()
    local player = World.player()
    if not player or World.gone then
        ui = nil
        return nil
    end
    local owner = player:GetAddress()
    if ui and ui.owner == owner and valid(ui.widget) then return ui, player end
    ui = nil
    if failedFor == owner then return nil end
    local ok, made = xpcall(build, debug.traceback, player)
    if not ok then
        failedFor = owner
        log("Chat: the panel could not be built: %s", tostring(made))
        return nil
    end
    ui, changed = made, true
    return ui, player
end

---------------------------------------------------------------- typing

local BUSY = { "inventoryOpen", "phoneUp", "computerOpen", "mapOpen", "saveScreenOpen", "isTrading", "inDialogue",
    "atWorkStation", "inAppartmentMode", "RenovationMode", "isLockpicking", "equipmentShopOpen", "beenCaught",
    "waiting", "sleepDialogue" }

-- One of the game's own windows has the keys (or the game is paused).
local function busy(player)
    for _, f in ipairs(BUSY) do
        local on = false
        pcall(function() on = player[f] == true end)
        if on then return true end
    end
    local paused = false
    pcall(function() paused = Core.statics():IsGamePaused(player) == true end)
    return paused
end

function Chat.isOpen() return typing ~= nil end

-- Opens the line. `force`: also outside a lobby (tests).
function Chat.open(force)
    if typing then return true end
    -- (something else of the mod's has the keyboard: the colour field of the tag editor)
    if Core.typing then return false end
    if not force and not Net.inLobby() then return false end
    local u, player = panel()
    if not u or busy(player) then return false end
    local pc = player:GetController()
    if not valid(pc) then return false end
    u.edit:SetText(FText(""))
    u.bar:SetVisibility(SELF_NO_HIT)
    library():SetInputMode_UIOnlyEx(pc, u.edit, 2)
    u.edit:SetKeyboardFocus()
    typing = { at = os.clock() }
    Core.typing = true
    changed = true
    return true
end

local function close(u, player)
    typing = nil
    Core.typing = nil
    closedAt = os.clock()
    changed = true
    u.bar:SetVisibility(COLLAPSED)
    -- the game took the keys for a window of its own meanwhile: they stay as it set them
    if busy(player) then return end
    local pc = player:GetController()
    if not valid(pc) then return end
    local screen = package.loaded["coop.screen"]
    local s = type(screen) == "table" and screen.current or nil
    if s and valid(s.widget) then
        library():SetInputMode_GameAndUIEx(pc, s.widget, 0, false)
        pc.bShowMouseCursor = true
        s.mouseAt = os.clock() + 0.5
    else
        library():SetInputMode_GameOnly(pc)
    end
end

-- Ends the typing: `send` false throws the text away.
function Chat.finish(send)
    if not typing then return end
    local u, player = panel()
    if not u then
        typing, Core.typing = nil, nil
        return
    end
    local text = ""
    pcall(function() text = u.edit:GetText():ToString() end)
    close(u, player)
    if send then Chat.say(text) end
end

function Chat.text()
    local t = nil
    if ui and typing then pcall(function() t = ui.edit:GetText():ToString() end) end
    return t
end

---------------------------------------------------------------- tick

local function fill(u)
    local first = #lines - Chat.ROWS
    for i, row in ipairs(u.rows) do
        local line = lines[first + i]
        if line ~= row.line then
            row.line = line
            if line then
                row.name:SetText(FText(line.name .. ":"))
                row.name:SetColorAndOpacity(slate(line.color))
                row.words:SetText(FText(line.text))
            end
        end
    end
end

-- The widgets go with their world: once it ends they are only forgotten, never touched.
local function forget()
    ui, failedFor = nil, nil
    if typing then typing, Core.typing = nil, nil end
end
World.listen("start", function() if live() then forget() end end)
World.listen("stop", function() if live() then forget() end end)

Core.onTick(function()
    if not live() then return end
    if ui then
        local p = World.player()
        if not p or World.gone or p:GetAddress() ~= ui.owner then forget() end
    end
    if not typing and #lines == 0 then return end
    local u, player = panel()
    if not u then
        typing, Core.typing = nil, nil
        return
    end
    local now = os.clock()
    if typing then
        local focused = false
        pcall(function() focused = u.edit:HasKeyboardFocus() == true end)
        local fresh = now - typing.at < 0.3
        if focused then
            typing.lostAt = nil
            local text = ""
            pcall(function() text = u.edit:GetText():ToString() end)
            -- the key that opened the line can arrive as its first letter
            if fresh and #text == 1 then
                u.edit:SetText(FText(""))
            elseif #text > Chat.MAX then
                u.edit:SetText(FText(clean(text)))
            end
        elseif fresh then
            -- (or as an Enter, when Enter is the key)
            pcall(function() u.edit:SetKeyboardFocus() end)
        else
            typing.lostAt = typing.lostAt or now
            if now - typing.lostAt > 0.2 then Chat.finish(true) end
        end
    end
    if changed then
        changed = false
        fill(u)
    end
    for _, row in ipairs(u.rows) do
        local alpha = 0
        if row.line then
            if typing then
                alpha = 1
            else
                local left = Chat.SHOW - (now - row.line.at)
                alpha = left <= 0 and 0 or math.min(1, left / Chat.FADE)
            end
        end
        local shown = alpha > 0
        if shown ~= row.shown then
            row.shown = shown
            row.box:SetVisibility(shown and NO_HIT or COLLAPSED)
        end
        if shown and math.abs(alpha - row.alpha) > 0.02 then
            row.alpha = alpha
            row.box:SetRenderOpacity(alpha)
        end
    end
end)

---------------------------------------------------------------- keys

-- Names the config may use for keys that have none of their own in UE4SS.
local KEY_NAMES = { ["/"] = "OEM_TWO", SLASH = "OEM_TWO", ENTER = "RETURN" }

local function watch(name, fn)
    local key = Key[KEY_NAMES[name] or name]
    if not key then
        log("Chat: unknown key '%s'", tostring(name))
        return
    end
    -- (not through Core.bindKey: these keys are the ones that work while typing)
    RegisterKeyBind(key, function()
        ExecuteInGameThread(function() if live() then fn() end end)
    end)
end

local chatKey = tostring(config.ChatKey or "/"):upper()
if chatKey ~= "" and chatKey ~= "NONE" then
    local enterToo = (KEY_NAMES[chatKey] or chatKey) == "RETURN"
    if not enterToo then
        watch(chatKey, function()
            if not typing and os.clock() - closedAt > 0.3 then Chat.open() end
        end)
    end
    watch("RETURN", function()
        if typing then
            if os.clock() - typing.at > 0.3 then Chat.finish(true) end
        elseif enterToo and os.clock() - closedAt > 0.3 then
            Chat.open()
        end
    end)
    watch("ESCAPE", function()
        if typing then Chat.finish(false) end
    end)
end

Chat.lines = lines
function Chat.state() return ui, typing end

return Chat
