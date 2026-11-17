-- The host's co-op autosaves, in the main menu.
--
-- The multiplayer panel opens a list of the autosaves (coop/world.lua keeps the last few).
-- One of them can be loaded, or copied into a save slot of the game, from where the
-- game's own LOAD GAME screen loads it like any other save.
--
-- Both screens are the game's own load/save screen (saveLoadWidget) with its own rows
-- (saveSlotWidget), so they look and behave like it:
--   * the list is that screen in its load form, with a row per autosave in place of the
--     save slots;
--   * the slot choice is that screen in its save form, untouched: the game's slots, its
--     "+" for another slot, its question and its box for the save's name.
-- A click on a row is the game's (the row tells its screen, which shows its question).
-- What happens next is ours: the game's OK would load from, or save the main menu into,
-- a slot, so the question's two buttons are replaced by buttons of our own, made in the
-- same style. They are asked every frame whether they are held down (a script cannot be
-- told about a click).

local Core = require("core")
local World = require("coop.world")

local log, valid = Core.log, Core.valid

local Backups = {}

local FRAME = "/Game/GUI/saveLoadWidget.saveLoadWidget_C"
local ROW = "/Game/GUI/saveSlotWidget.saveSlotWidget_C"
local VISIBLE, COLLAPSED, HIDDEN = 0, 1, 2
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local RED = { R = 0.37, G = 0.0, B = 0.0, A = 1 }        -- the colour of the game's own OK
local LIST_TITLE, LIST_DESC = "CO-OP AUTOSAVES", "Choose an autosave"
local PICK_TITLE = "CO-OP AUTOSAVE"
local SLOT_TITLE = "COPY TO SAVE SLOT"

local S = nil      -- while the list is up: { list = screen, slots = screen or nil, entry, onClose }

local function asset(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() LoadAsset((path:gsub("_C$", ""))) end)
    o = StaticFindObject(path)
    return valid(o) and o or nil
end

local function library() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end

local function menu()
    local seen = World.menu
    if not seen or os.clock() - seen.at > 1 or not valid(seen.widget) then return nil end
    return seen.widget
end

---------------------------------------------------------------- what a row says

local function plural(n, word) return string.format("%d %s%s", n, word, n == 1 and "" or "S") end

-- First line of a row: what the world was like.
local function rowName(e)
    local m, parts = e.meta, {}
    if tonumber(m.day) then parts[#parts + 1] = "DAY " .. math.floor(m.day) end
    if tonumber(m.level) then parts[#parts + 1] = "LEVEL " .. math.floor(m.level) end
    if tonumber(m.players) then parts[#parts + 1] = plural(math.floor(m.players), "PLAYER") end
    if #parts == 0 then return e.before and "EARLIER AUTOSAVE" or "AUTOSAVE" end
    return table.concat(parts, "   ")
end

-- Second line: when it was saved, written the way the game writes a save's date.
local function rowDate(e) return World.autosaveDate(e) end

-- Both in one line of ordinary writing, for the question about a row.
local function rowSentence(e)
    local m, parts = e.meta, {}
    if tonumber(m.day) then parts[#parts + 1] = "day " .. math.floor(m.day) end
    if tonumber(m.level) then parts[#parts + 1] = "level " .. math.floor(m.level) end
    if tonumber(m.players) then parts[#parts + 1] = plural(math.floor(m.players), "player"):gsub("S$", "s") end
    local date = rowDate(e)
    if date ~= "" then table.insert(parts, 1, date) end
    if #parts == 0 then return "Autosave" end
    return (table.concat(parts, ", "))
end

local function defaultName(e)
    if tonumber(e.meta.day) then return "Co-op day " .. math.floor(e.meta.day) end
    return "Co-op autosave"
end

---------------------------------------------------------------- the screens

local function setText(block, str) block:SetText(FText(str)) end

-- A button like the question's own two, added to their row.
local function button(screen, label, color, click)
    local w = screen.widget
    local model = w.btnConfirmOK
    local b = StaticConstructObject(StaticFindObject("/Script/UMG.Button"), w.WidgetTree)
    b:SetStyle(model.WidgetStyle)
    b:SetBackgroundColor(model.BackgroundColor)
    local modelText = model:GetChildAt(0)
    local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), w.WidgetTree)
    t:SetFont(modelText.Font)
    t:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
    t:SetText(FText(label))
    local inner = b:AddChild(t)
    inner:SetPadding(modelText.Slot.Padding)
    inner:SetHorizontalAlignment(modelText.Slot.HorizontalAlignment)
    inner:SetVerticalAlignment(modelText.Slot.VerticalAlignment)
    local outer = screen.row:AddChildToHorizontalBox(b)
    outer:SetPadding(model.Slot.Padding)
    screen.buttons[#screen.buttons + 1] = { widget = b, label = label, click = click }
end

-- Opens the game's load/save screen over the main menu. `save` = its save form.
local function openScreen(kind)
    local owner, lib, class = menu(), library(), asset(FRAME)
    if not owner or not valid(lib) or not class then return nil end
    local w = lib:Create(owner, class, nil)
    if not valid(w) then return nil end
    w:Setup(kind == "slots", true, nil)
    local screen = { kind = kind, widget = w, address = w:GetAddress(), buttons = {}, dressed = nil, titleAt = 0 }
    -- the question's own OK and CANCEL stay out of sight: ours take their place
    screen.row = w.btnConfirmOK:GetParent()
    w.btnConfirmOK:SetVisibility(COLLAPSED)
    w.btnConfirmCancel:SetVisibility(COLLAPSED)
    return screen
end

local function hideQuestion(screen)
    screen.widget.ConfirmPanel:SetVisibility(HIDDEN)
    screen.dressed = nil
end

local function fillList(screen)
    local w, lib, rowClass, owner = screen.widget, library(), asset(ROW), menu()
    w.SlotListing:ClearChildren()
    for i, e in ipairs(screen.entries) do
        local row = lib:Create(owner, rowClass, nil)
        row:Setup(true, rowName(e), rowDate(e), i - 1, w)
        w.SlotListing:AddChildToVerticalBox(row)
    end
    w.txtNoLoad:SetVisibility(COLLAPSED)
    setText(w.txtSaveLoadTitle, LIST_TITLE)
    setText(w.txtSaveLoadDesc, LIST_DESC)
end

local function closeSlots()
    local slots = S and S.slots
    if not slots then return end
    S.slots = nil
    slots.buttons = {}
    if not slots.dead then pcall(function() if valid(slots.widget) then slots.widget:RemoveFromParent() end end) end
    local list = S.list
    if list and not list.dead then pcall(function() list.widget:SetVisibility(list.visibility) end) end
end

function Backups.close(quiet)
    if not S then return end
    closeSlots()
    local list, onClose = S.list, S.onClose
    S = nil
    list.buttons = {}
    if not list.dead then pcall(function() if valid(list.widget) then list.widget:RemoveFromParent() end end) end
    if onClose and not quiet then pcall(onClose) end
end

local function load()
    local entry = S and S.entry
    if not entry then return end
    Backups.close(true)
    if not World.loadAutosave(entry) then
        local Net = require("net")
        Net.notify("That autosave could not be loaded.")
    end
end

local function copy()
    local slots = S and S.slots
    if not slots or not S.entry then return end
    local w = slots.widget
    local slot = w.clickedSlotID
    local name = w.inputSaveName:GetText():ToString()
    if name:gsub("%s", "") == "" then name = defaultName(S.entry) end
    local ok, problem = World.copyAutosaveToSlot(S.entry, slot, name, w.saveObject)
    if not ok then
        log("Autosave not copied to slot %s: %s", tostring(slot), tostring(problem))
        setText(w.txtConfirmDesc, "Not copied: " .. tostring(problem) .. ".")
        return
    end
    hideQuestion(slots)
    w:RefreshList()             -- the game's own: the slots as they are now
    slots.titleAt = 0
end

local function openSlots()
    if not S or S.slots or not S.entry then return end
    local slots = openScreen("slots")
    if not slots then return end
    button(slots, "OK", RED, copy)
    button(slots, "CANCEL", WHITE, function() hideQuestion(slots) end)
    S.slots = slots
    hideQuestion(S.list)
    S.list.widget:SetVisibility(COLLAPSED)
    slots.widget:AddToViewport(2)
end

-- Opens the list. `onClose` is called when the player has closed it again (not when an
-- autosave is being loaded). False when there is nothing to list or no main menu.
function Backups.open(onClose)
    if S then return true end
    local entries = World.autosaves and World.autosaves() or {}
    if #entries == 0 or not menu() or World.active or World.joining then return false end
    local ok, problem = xpcall(function()
        local list = openScreen("list")
        if not list then error("the game's load screen is not available") end
        list.entries = entries
        fillList(list)
        button(list, "LOAD", RED, load)
        button(list, SLOT_TITLE, WHITE, openSlots)
        button(list, "CANCEL", WHITE, function() hideQuestion(list) end)
        list.visibility = list.widget.Visibility
        S = { list = list, onClose = onClose }
        list.widget:AddToViewport(1)
    end, debug.traceback)
    if not ok then
        log("Autosave list: %s", tostring(problem))
        S = nil
        return false
    end
    return true
end

---------------------------------------------------------------- the question

-- The game has just shown its question for the row that was clicked: make it ours.
local function dress(screen)
    local w = screen.widget
    local id = w.clickedSlotID
    if screen.kind == "list" then
        local e = screen.entries[id + 1]
        if not e then
            hideQuestion(screen)
            return
        end
        S.entry = e
        setText(w.txtConfirmTitle, PICK_TITLE)
        setText(w.txtConfirmDesc, rowSentence(e))
    else
        setText(w.txtConfirmTitle, SLOT_TITLE)
        -- an occupied slot keeps its name, as in the game; an empty one gets one that says what it is
        local occupied = true
        pcall(function() occupied = w.saveObject.slotOccupied[id + 1] == true end)
        if not occupied and S.entry then setText(w.inputSaveName, defaultName(S.entry)) end
    end
    screen.dressed = id
end

local function watchQuestion(screen)
    local w = screen.widget
    if w.ConfirmPanel.Visibility == VISIBLE then
        if screen.dressed ~= w.clickedSlotID then dress(screen) end
        return true
    end
    screen.dressed = nil
    return false
end

Core.Hooks.add(FRAME .. ":SlotClicked", function(ctx)
    if not S then return end
    local w = ctx:get()
    if not valid(w) then return end
    local address = w:GetAddress()
    for _, screen in ipairs({ S.slots or false, S.list }) do
        if screen and screen.address == address and not screen.dead then
            screen.dressed = nil
            local ok, e = xpcall(watchQuestion, debug.traceback, screen)
            if not ok then log("Autosave list: %s", tostring(e)) end
        end
    end
end)

-- The screen's own "x" removes it. Nothing of a removed screen may be called again (the
-- engine destroys it at its next clean-up), so it is marked the moment it goes.
Core.Hooks.add(FRAME .. ":Destruct", function(ctx)
    if not S then return end
    local address = nil
    pcall(function() address = ctx:get():GetAddress() end)
    for _, screen in ipairs({ S.slots or false, S.list }) do
        if screen and screen.address == address then
            screen.dead = true
            screen.buttons = {}
        end
    end
end)

---------------------------------------------------------------- every frame

local function there(screen)
    if screen.dead then return false end
    local ok, up = pcall(function() return valid(screen.widget) and screen.widget:IsInViewport() end)
    return ok and up == true
end

local function pollButtons(screen)
    for _, b in ipairs(screen.buttons) do
        local hovered, pressed = b.widget:IsHovered(), b.widget:IsPressed()
        local clicked = b.pressed and not pressed and hovered
        b.pressed = pressed
        if clicked then
            local ok, e = xpcall(b.click, debug.traceback)
            if not ok then log("Autosave list: %s: %s", b.label, tostring(e)) end
            return          -- the click may have closed the screen these buttons are in
        end
    end
end

local function tick()
    if not S then return end
    local seen = World.menu
    if not seen or os.clock() - seen.at > 5 or World.joining or World.active or World.player() then
        -- the main menu is going (a game is starting, a friend's world is loading): the
        -- screens go with it, while they can still be taken away
        Backups.close(true)
        return
    end
    if S.slots and not there(S.slots) then
        S.slots.dead = true
        closeSlots()            -- back to the list of autosaves
    end
    if not there(S.list) then
        S.list.dead = true
        Backups.close()
        return
    end
    local screen = S.slots or S.list
    local w = screen.widget
    if screen.kind == "slots" and os.clock() >= screen.titleAt then
        -- the game writes its own heading again whenever it lists the slots anew
        screen.titleAt = os.clock() + 0.2
        if w.txtSaveLoadTitle:GetText():ToString() ~= SLOT_TITLE then setText(w.txtSaveLoadTitle, SLOT_TITLE) end
    end
    if watchQuestion(screen) then pollButtons(screen) end
end

Core.onTick(function()
    local ok, e = xpcall(tick, debug.traceback)
    if not ok then
        log("Autosave list error, closing it: %s", tostring(e))
        if S then
            S.list.dead = true
            if S.slots then S.slots.dead = true end
            S = nil
        end
    end
end)

---------------------------------------------------------------- for scripts (tests)

function Backups.isOpen() return S ~= nil end
function Backups.state() return S end

-- Clicks row `index` (1 = the first) of the screen that is in front, the way the row does.
function Backups.pick(index)
    local screen = S and (S.slots or S.list)
    if not screen then return false end
    screen.widget:SlotClicked(index - 1)
    return true
end

-- Presses a button of the question by its label.
function Backups.click(label)
    local screen = S and (S.slots or S.list)
    if not screen then return false end
    for _, b in ipairs(screen.buttons) do
        if b.label == label then
            local ok, e = xpcall(b.click, debug.traceback)
            if not ok then log("Autosave list: %s: %s", label, tostring(e)) end
            return ok
        end
    end
    return false
end

return Backups
