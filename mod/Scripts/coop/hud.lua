-- In-game overlay: the emote wheel, pick lists, a prompt line and short notices.
--
-- Like the menu entries (ui.lua), the widgets are stock UMG classes created at runtime.
-- They are parented to the player's own HUD widget, use the font of a text the HUD already
-- shows, and never take mouse input: everything here is driven by keys and by where the
-- player looks.

local Core = require("core")
local World = require("coop.world")

local log, valid = Core.log, Core.valid

local Hud = {}

local VISIBLE, COLLAPSED, NO_HIT = 0, 1, 3
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local SOFT = { R = 0.62, G = 0.62, B = 0.62, A = 1 }
local GREY = { R = 0.42, G = 0.42, B = 0.42, A = 1 }
local RED = { R = 0.85, G = 0.08, B = 0.08, A = 1 }
local WHEEL_RADIUS = 210
local LIST_ROWS = 9

local st = nil          -- widgets of the current HUD
local failedFor = nil   -- HUD address for which building failed (do not retry every tick)

local function text(s) return FText(s) end
local function slateColor(c) return { SpecifiedColor = c, ColorUseRule = 0 } end
local function className(obj) return obj:GetClass():GetFName():ToString() end

-- First widget of the given class below `widget`.
local function findWidget(widget, class, depth)
    if not valid(widget) or depth > 7 then return nil end
    if className(widget) == class then return widget end
    local n = 0
    pcall(function() n = widget:GetChildrenCount() end)
    for i = 0, n - 1 do
        local found = findWidget(widget:GetChildAt(i), class, depth + 1)
        if found then return found end
    end
    return nil
end

local function new(kind)
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. kind), st.tree)
end

local function label(str, size, color)
    local tb = new("TextBlock")
    if st.font then
        tb:SetFont(st.font.Font)
        local font = tb.Font
        font.Size = size
        tb:SetFont(font)
    end
    tb:SetColorAndOpacity(slateColor(color or WHITE))
    tb:SetText(text(str))
    return tb
end

-- Puts a widget on the overlay at a fraction of the screen, shifted by (x, y) units.
local function place(widget, anchorX, anchorY, x, y, alignX, alignY)
    local slot = st.layer:AddChildToCanvas(widget)
    slot:SetAnchors({ Minimum = { X = anchorX, Y = anchorY }, Maximum = { X = anchorX, Y = anchorY } })
    slot:SetAlignment({ X = alignX or 0.5, Y = alignY or 0.5 })
    slot:SetAutoSize(true)
    slot:SetPosition({ X = x, Y = y })
    return slot
end

local function build(hud)
    st = { address = hud:GetAddress(), tree = hud.WidgetTree }
    local root = st.tree.RootWidget
    local canvas = findWidget(root, "CanvasPanel", 0)
    if not canvas then error("the HUD has no canvas") end
    st.font = findWidget(root, "TextBlock", 0)

    st.layer = new("CanvasPanel")
    local slot = canvas:AddChildToCanvas(st.layer)
    slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
    slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    slot:SetZOrder(40)
    st.layer:SetVisibility(NO_HIT)

    -- Wheel: a dark plate, a title in the middle, eight entries around it.
    st.wheel = { labels = {} }
    local plate = new("Border")
    plate:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.55 })
    local plateSize = new("Spacer")
    plateSize:SetSize({ X = 2 * WHEEL_RADIUS + 300, Y = 2 * WHEEL_RADIUS + 110 })
    plate:AddChild(plateSize)
    place(plate, 0.5, 0.5, 0, 0)
    st.wheel.plate = plate
    st.wheel.title = label("", 22, WHITE)
    place(st.wheel.title, 0.5, 0.5, 0, -14)
    st.wheel.hint = label("", 13, GREY)
    place(st.wheel.hint, 0.5, 0.5, 0, 18)
    for i = 1, 8 do
        local a = math.rad((i - 1) * 45)
        local tb = label("", 19, SOFT)
        place(tb, 0.5, 0.5, WHEEL_RADIUS * math.sin(a) * 1.25, -WHEEL_RADIUS * math.cos(a))
        st.wheel.labels[i] = tb
    end
    st.wheel.widgets = { plate, st.wheel.title, st.wheel.hint }
    for _, tb in ipairs(st.wheel.labels) do st.wheel.widgets[#st.wheel.widgets + 1] = tb end
    for _, w in ipairs(st.wheel.widgets) do w:SetVisibility(COLLAPSED) end

    -- List: title, rows, a line of help.
    st.list = { rows = {} }
    local panel = new("Border")
    panel:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.8 })
    panel:SetPadding({ Left = 26, Top = 18, Right = 34, Bottom = 16 })
    local box = new("VerticalBox")
    panel:AddChild(box)
    local function row(widget, top, bottom)
        local s = box:AddChildToVerticalBox(widget)
        s:SetPadding({ Left = 0, Top = top or 0, Right = 0, Bottom = bottom or 0 })
    end
    st.list.title = label("", 24, WHITE)
    row(st.list.title, 0, 10)
    for i = 1, LIST_ROWS do
        st.list.rows[i] = label("", 17, SOFT)
        row(st.list.rows[i], 0, 3)
    end
    st.list.footer = label("", 13, GREY)
    row(st.list.footer, 10, 0)
    place(panel, 0.05, 0.5, 0, 0, 0, 0.5)
    panel:SetVisibility(COLLAPSED)
    st.list.panel = panel

    -- One-line prompt and notice.
    -- The prompt looks like the game's own action hint under the crosshair (red key, white
    -- action), and takes its fonts from it.
    local row = new("HorizontalBox")
    st.promptKey, st.promptLabel = label("", 15, { R = 0.37, G = 0, B = 0, A = 1 }), label("", 15, WHITE)
    pcall(function()
        st.promptKey:SetFont(hud.txtActionBtn.Font)
        st.promptLabel:SetFont(hud.txtAction.Font)
    end)
    -- the same spacing as the game's own hint (its key and action have these paddings)
    local keySlot = row:AddChildToHorizontalBox(st.promptKey)
    keySlot:SetPadding({ Left = 10, Top = 7, Right = 5, Bottom = 6 })
    local gap = row:AddChildToHorizontalBox(st.promptLabel)
    gap:SetPadding({ Left = 5, Top = 6, Right = 10, Bottom = 6 })
    st.promptSlot = place(row, 0.5, 0.5, 0, 64)
    -- the game's hint: a row (key, action) in a panel centred just below the crosshair
    pcall(function()
        st.gameText = hud.txtAction
        st.gameRow = hud.txtAction:GetParent()
        st.gamePanel = st.gameRow:GetParent()
    end)
    st.prompt = row
    st.prompt:SetVisibility(COLLAPSED)
    st.toast = label("", 17, WHITE)
    place(st.toast, 0.5, 0.8, 0, 0)
    st.toast:SetVisibility(COLLAPSED)
    st.toastUntil = 0
end

-- True when the overlay exists for the HUD that is on screen now.
function Hud.ready()
    local player = World.player()
    if not player then return false end
    local hud = nil
    pcall(function() hud = player.HUD end)
    if not valid(hud) then return false end
    local address = hud:GetAddress()
    if st and st.address == address and valid(st.layer) then return true end
    if failedFor == address then return false end
    st = nil
    local ok, e = xpcall(build, debug.traceback, hud)
    if not ok then
        failedFor = address
        st = nil
        log("Overlay could not be built: %s", tostring(e))
        return false
    end
    return true
end

---------------------------------------------------------------- wheel

function Hud.wheel(title, hint, names)
    if not Hud.ready() then return false end
    st.wheel.title:SetText(text(title))
    st.wheel.hint:SetText(text(hint or ""))
    for i, tb in ipairs(st.wheel.labels) do
        tb:SetText(text(names[i] or ""))
        tb:SetColorAndOpacity(slateColor(SOFT))
    end
    for _, w in ipairs(st.wheel.widgets) do w:SetVisibility(NO_HIT) end
    st.wheel.open, st.wheel.picked, st.wheel.baseTitle = true, nil, title
    return true
end

function Hud.wheelHighlight(index)
    if not st or not st.wheel.open or st.wheel.picked == index then return end
    st.wheel.picked = index
    for i, tb in ipairs(st.wheel.labels) do
        tb:SetColorAndOpacity(slateColor(i == index and RED or SOFT))
    end
end

function Hud.wheelHide()
    if not st or not valid(st.layer) then return end
    for _, w in ipairs(st.wheel.widgets) do w:SetVisibility(COLLAPSED) end
    st.wheel.open = false
end

---------------------------------------------------------------- list

-- rows: list of strings. `selected` is the highlighted row (1-based).
function Hud.list(title, rows, selected, footer)
    if not Hud.ready() then return false end
    st.list.title:SetText(text(title))
    st.list.footer:SetText(text(footer or ""))
    local first = math.max(1, math.min(selected - math.floor(LIST_ROWS / 2), #rows - LIST_ROWS + 1))
    for i = 1, LIST_ROWS do
        local index = first + i - 1
        local tb = st.list.rows[i]
        if rows[index] then
            tb:SetText(text((index == selected and "> " or "   ") .. rows[index]))
            tb:SetColorAndOpacity(slateColor(index == selected and WHITE or SOFT))
            tb:SetVisibility(NO_HIT)
        else
            tb:SetVisibility(COLLAPSED)
        end
    end
    st.list.panel:SetVisibility(NO_HIT)
    st.list.open = true
    return true
end

function Hud.listHide()
    if not st or not valid(st.layer) then return end
    st.list.panel:SetVisibility(COLLAPSED)
    st.list.open = false
end

---------------------------------------------------------------- prompt and notice

-- The game's own hint, when it shows: its row's size and the panel's centre (units).
local function gameHint()
    local shown, w, h, y = false, 0, 0, 45
    pcall(function()
        shown = st.gamePanel:IsVisible() and st.gameRow:IsVisible() and st.gameText:IsVisible()
            and st.gameText:GetText():ToString() ~= ""
        local d = st.gameRow:GetDesiredSize()
        w, h = d.X, d.Y
        y = st.gamePanel.Slot:GetPosition().Y
    end)
    return shown and w > 0, w, h, y
end

-- An `under` prompt is a line of the game's own kind: it stands right below the game's
-- hint for the same thing (the wardrobe's "change clothes"), key under key, or in the
-- hint's place when the game shows none.
local function placePrompt()
    if not st or not st.promptText or not valid(st.prompt) then return end
    local x, y, ax, ay = 0, 64, 0.5, 0.5
    if st.promptUnder then
        local shown, w, h, cy = gameHint()
        if shown then
            x, y, ax, ay = -w / 2, cy + h / 2, 0, 0
        else
            y = cy
        end
    end
    local key = string.format("%.0f %.0f %.1f %.1f", x, y, ax, ay)
    if key == st.promptPlace then return end
    st.promptPlace = key
    pcall(function()
        st.promptSlot:SetAlignment({ X = ax, Y = ay })
        st.promptSlot:SetPosition({ X = x, Y = y })
    end)
end

-- EXPERIMENTAL UseWithF: a prompt for the key of the mod's places says F, the game's own
-- use key, as long as the game shows no hint of its own (then F is the game's, and the
-- prompt keeps the mod's key). A line under the game's hint keeps the mod's key too.
Hud.USE_KEY = "F"

local function shownKey(key)
    if not key or st.promptUnder or not Core.experimental("UseWithF") then return key end
    if tostring(key):upper() ~= tostring(Core.config.WardrobeKey or "U"):upper() then return key end
    if gameHint() then return key end
    return Hud.USE_KEY
end

-- The key the prompt shows now (nil without a prompt).
function Hud.promptKey()
    return st and st.promptText and st.promptShown or nil
end

-- True while the game shows a hint of its own (what it would do on its use key).
function Hud.gameHintShown()
    if not st then return false end
    return (gameHint()) == true
end

-- key: what to press ("U"); action: what it does ("SIT DOWN"). nil hides the prompt.
-- under: a line below the game's own hint, written as the game writes its hints (the
-- action as given, not in capitals).
function Hud.prompt(key, action, under)
    if not Hud.ready() then return end
    local str = key and (tostring(key) .. "|" .. tostring(action) .. (under and "|u" or "")) or nil
    if str == st.promptText then return end
    st.promptText = str
    st.promptUnder = under == true
    st.promptRaw = key
    if str then
        st.promptShown = shownKey(key)
        st.promptKey:SetText(text(tostring(st.promptShown):upper()))
        st.promptLabel:SetText(text(under and tostring(action or "") or tostring(action or ""):upper()))
        placePrompt()
        st.prompt:SetVisibility(NO_HIT)
    else
        st.prompt:SetVisibility(COLLAPSED)
    end
end

-- The game's hint comes and goes as the player looks about.
Core.onTick(function()
    if st and st.promptUnder and st.promptText then placePrompt() end
    -- (F or the mod's key, as the game's hint comes and goes)
    if st and st.promptText and valid(st.promptKey) then
        local k = shownKey(st.promptRaw)
        if k ~= st.promptShown then
            st.promptShown = k
            pcall(function() st.promptKey:SetText(text(tostring(k):upper())) end)
        end
    end
end)

-- A short message, in the game's own list of them (on the left, with its red mark). While
-- a screen of ours covers the game's HUD the same kind of line is put on that screen, in
-- the same place. Our own line in the middle only when neither can be had.
local QUICK_CLASS = "/Game/GUI/quickMessageWidget.quickMessageWidget_C"

local function quickOnScreen(s, player, hud, str)
    local ok = pcall(function()
        if not (s.quickList and valid(s.quickList)) then
            local list = s.new("VerticalBox")
            local slot = s.canvas:AddChildToCanvas(list)
            -- where the game's panel of these lines is (read off it; these are its values)
            local a, o, al = { 0, 0.5, 0, 0.5 }, { 25, 250, 400, 250 }, { 0, 1 }
            pcall(function()
                local src = hud.quickMessageList:GetParent().Slot
                local sa, so, sal = src:GetAnchors(), src:GetOffsets(), src:GetAlignment()
                a = { sa.Minimum.X, sa.Minimum.Y, sa.Maximum.X, sa.Maximum.Y }
                o = { so.Left, so.Top, so.Right, so.Bottom }
                al = { sal.X, sal.Y }
            end)
            -- (a screen with a panel on the left has the lines just right of it)
            if type(s.quickLeft) == "number" then a[1], a[3] = s.quickLeft, s.quickLeft end
            slot:SetAnchors({ Minimum = { X = a[1], Y = a[2] }, Maximum = { X = a[3], Y = a[4] } })
            slot:SetOffsets({ Left = o[1], Top = o[2], Right = o[3], Bottom = o[4] })
            slot:SetAlignment({ X = al[1], Y = al[2] })
            slot:SetAutoSize(false)
            slot:SetZOrder(60)
            list:SetVisibility(3)
            s.quickList = list
        end
        local class = StaticFindObject(QUICK_CLASS)
        if not valid(class) then
            pcall(function() LoadAsset((QUICK_CLASS:gsub("_C$", ""))) end)
            class = StaticFindObject(QUICK_CLASS)
        end
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local w = lib:Create(player, class, nil)
        w:Setup(text(str))
        s.quickList:AddChild(w)
    end)
    return ok
end

function Hud.toast(str, seconds)
    if not Hud.ready() then return end
    local player = World.player()
    local hud = player.HUD
    local screen = package.loaded["coop.screen"]
    local s = type(screen) == "table" and screen.current or nil
    if s and s.canvas then
        if quickOnScreen(s, player, hud, str) then return end
    else
        local shown = pcall(function()
            local v = hud:GetVisibility()
            if v == 1 or v == 2 then error("the HUD is put away") end
            hud:displayQuickMessage(text(str))
        end)
        if shown then return end
    end
    st.toast:SetText(text(str))
    st.toast:SetVisibility(NO_HIT)
    st.toastUntil = os.clock() + (seconds or 3)
end

Core.every(0.5, function()
    if st and st.toastUntil > 0 and os.clock() >= st.toastUntil then
        st.toastUntil = 0
        if valid(st.layer) and valid(st.toast) then st.toast:SetVisibility(COLLAPSED) end
    end
end)

-- Markers on the map and compass, of the game's own kind.
--
-- The game saves its markers with the world. Ours must never end up in anybody's save:
-- their save component is removed, and should a save bring one back it is removed again.
local MARKER_CLASS = "/Game/GUI/WorldMap/worldMapMarker.worldMapMarker_C"
local ours = {}          -- address of each marker made in this session
local OUR_TIPS = {}      -- tooltip text of every kind of marker we make

Hud.MARKER_PIN, Hud.MARKER_SHOP, Hud.MARKER_PLAYER, Hud.MARKER_MONEY = 0, 1, 5, 6
-- The game's marker for a person: a client's icon, green. With `dealer` the map draws it
-- orange (its colour for the player's own dealers).
Hud.MARKER_PERSON = 3

-- Returns the marker actor. `category` picks the icon.
function Hud.mapMarker(name, tooltip, x, y, z, category, dealer)
    local player = World.player()
    if not player then return nil end
    OUR_TIPS[tooltip] = true
    local marker = nil
    pcall(function()
        local class = StaticFindObject(MARKER_CLASS)
        if not valid(class) then return end
        local Repl = require("coop.repl")
        local actor = player:GetWorld():SpawnActor(class, { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(actor) then return end
        local function quoted(str) return '"' .. tostring(str):gsub('[\\"]', "") .. '"' end
        Repl.import(actor, { MarkerName = quoted(name), MarkerTooltip = quoted(tooltip), markerCategory = "0",
            taskRelated = "False", relatedAreaString = '""', dealer = dealer and "True" or "False" })
        pcall(function()
            local saver = actor.RamaSave
            if valid(saver) then saver:K2_DestroyComponent(actor) end
        end)
        ours[actor:GetAddress()] = true
        marker = actor
        -- A marker that starts out as a shop removes itself, so it becomes one a moment later.
        if category and category ~= 0 then
            Core.after(1, function()
                pcall(function() if Core.alive(actor) then actor.markerCategory = category end end)
            end)
        end
    end)
    return marker
end

function Hud.forgetMarker(marker)
    pcall(function()
        if valid(marker) then
            ours[marker:GetAddress()] = nil
            marker:K2_DestroyActor()
        end
    end)
end

-- A marker of ours can only come back with a loaded world, so this looks a few times after
-- the player's character has changed (reading every marker takes a moment) and then stops.
local sweepFor, sweeps = 0, {}

Core.every(2, function()
    local player = World.player()
    if not player or not next(OUR_TIPS) then return end
    local owner = player:GetAddress()
    local now = os.clock()
    if owner ~= sweepFor then sweepFor, sweeps = owner, { now + 4, now + 15, now + 40, now + 90 } end
    if not sweeps[1] or now < sweeps[1] then return end
    table.remove(sweeps, 1)
    for _, marker in ipairs(Core.actors("/Game/GUI/WorldMap/worldMapMarker.worldMapMarker_C") or FindAllOf("worldMapMarker_C") or {}) do
        pcall(function()
            if Core.alive(marker) and not ours[marker:GetAddress()] and OUR_TIPS[marker.MarkerTooltip:ToString()] then
                log("Removed a marker of ours that came back with the save")
                marker:K2_DestroyActor()
            end
        end)
    end
end)

function Hud.state() return st end

-- Money into or out of the bank account the way the game does it: the balance changes
-- and the transfer is in the account's history (title and source as the game's own
-- transfers have them). False when it could not be done.
function Hud.bankTransfer(income, amount, title, source)
    local computer = Core.find("mainComputer_C")
    if not computer or amount <= 0 then return false end
    local before = nil
    pcall(function() before = computer.playerBankMoney end)
    if type(before) ~= "number" then return false end
    local ok = pcall(function() computer:newBankOperation(income == true, amount, FText(tostring(title)), FText(tostring(source)), false, true) end)
    local after = before
    pcall(function() after = computer.playerBankMoney end)
    -- (the balance says whether the game's function ran)
    if not ok or math.abs(after - before) < 0.005 then
        local set = pcall(function() computer.playerBankMoney = before + (income and amount or -amount) end)
        if not set then return false end
    end
    pcall(function() if Core.valid(computer.interface) then computer.interface:UpdateDesktop() end end)
    return true
end

return Hud
