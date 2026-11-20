-- Menu integration for DDS Multiplayer.
--
-- Adds a MULTIPLAYER entry to the game's main menu and to the in-game pause menu (same
-- button style and font as the entries around it) and a panel beside it with the lobby
-- status and actions. Widgets are built from stock UMG classes at runtime and parented to
-- the menu's own canvas, so they live and die with that menu widget.
--
-- UE4SS cannot bind Lua to UMG click delegates, so clicks are detected by polling
-- IsPressed/IsHovered once per frame (see UI.tick).

local UI = {}

local C             -- context from main.lua: S, config, log, valid, host, invite, leave
local states = {}   -- one state per menu kind ("main", "pause")
local st = nil      -- state of the menu being processed right now

local VIS_VISIBLE, VIS_COLLAPSED, VIS_SELF_HIT_TEST_INVISIBLE = 0, 1, 4
local PANEL_W = 430

local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local SOFT = { R = 0.72, G = 0.72, B = 0.72, A = 1 }      -- idle panel actions
local GREY = { R = 0.45, G = 0.45, B = 0.45, A = 1 }      -- secondary text, disabled actions
local RED = { R = 0.37, G = 0.0, B = 0.0, A = 1 }         -- the menu's own accent (NEW GAME)
local RED_HOT = { R = 0.75, G = 0.03, B = 0.03, A = 1 }   -- hovered primary action
local GREEN = { R = 0.25, G = 0.65, B = 0.25, A = 1 }

-- Where things go in each menu. Positions are canvas units relative to the left edge and
-- the vertical centre of the screen, like the stock entries.
local PROFILES = {
    main = {
        canvas = "buttonPanel",
        template = "btnOptions",            -- SETTINGS: the new entry copies it and sits below it
        body = "txtDiffDesc",               -- widget whose font is used for body text
        entry = { y = 100 },                -- x is taken from the template
        shift = {                           -- stock widgets moved to make room: name, dx, dy
            { "btnOpenCredits", 0, 50 }, { "ButtonGameVersionChange", 0, 50 },
            { "btnExitGame", 0, 50 },
        },
        -- The menu's hover animations put its underline at fixed places: where CREDITS and
        -- EXIT GAME used to be. For those two and for the new entry an underline of our
        -- own is shown instead (the stock one is hidden meanwhile).
        underline = { stock = "buttonUnderline", dx = 5, dy = 40, also = { "btnOpenCredits", "btnExitGame" } },
        panel = { x = 470, y = -150 },
        blocker = "difficultyPanel",        -- stock overlay that takes the panel's place
    },
    pause = {
        canvas = nil,                       -- the root canvas
        template = "btnSettings",
        body = "txtConfirmDesc",
        -- The stock labels are centred in their buttons on a diagonal; the long word
        -- MULTIPLAYER then starts further left than SETTINGS above it. Moved right so that
        -- the left edges keep stepping to the right.
        entry = { x = 372, y = 100 },
        -- MOD OPTIONS (coop/options.lua) below it, one more step to the right
        extra = { label = "MOD OPTIONS", x = 401, y = 150 },
        shift = { { "btnExitGame", 66, 100 } },
        panel = { x = 760, y = -150 },
        blocker = "confirmPanel",
        raise = "confirmPanel",             -- keep the stock confirm dialog above our widgets
    },
}

local function text(s) return FText(s) end

local function className(obj) return obj:GetClass():GetFName():ToString() end

local CONTAINERS = { CanvasPanel = true, VerticalBox = true, HorizontalBox = true, Button = true }

local function collect(widget, out, depth)
    out[widget:GetFName():ToString()] = widget
    if depth < 5 and CONTAINERS[className(widget)] then
        for i = 0, widget:GetChildrenCount() - 1 do
            collect(widget:GetChildAt(i), out, depth + 1)
        end
    end
    return out
end

local function new(kind)
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. kind), st.tree)
end

local function slateColor(c)
    return { SpecifiedColor = c, ColorUseRule = 0 }
end

local function label(str, fontFrom, size, color)
    local tb = new("TextBlock")
    tb:SetFont(fontFrom.Font)
    if size then
        local font = tb.Font
        font.Size = size
        tb:SetFont(font)
    end
    if color then tb:SetColorAndOpacity(slateColor(color)) end
    tb:SetText(text(str))
    return tb
end

-- A text-only button that looks and sounds like the stock entries of this menu.
-- Panel actions are left-aligned with no inset so they line up with the panel's text.
local function menuButton(str, size, panelAction)
    local button = new("Button")
    button:SetStyle(st.tplButton.WidgetStyle)
    button:SetBackgroundColor(st.tplButton.BackgroundColor)
    local tb = label(str, st.tplLabel, size, WHITE)
    local slot = button:AddChild(tb)
    local tplSlot = st.tplLabel.Slot
    if panelAction then
        local pad = tplSlot.Padding
        slot:SetPadding({ Left = 0, Top = pad.Top, Right = 0, Bottom = pad.Bottom })
        slot:SetHorizontalAlignment(1)   -- HAlign_Left
    else
        slot:SetPadding(tplSlot.Padding)
        slot:SetHorizontalAlignment(tplSlot.HorizontalAlignment)
    end
    slot:SetVerticalAlignment(tplSlot.VerticalAlignment)
    return button, tb
end

local function addRow(box, widget, top, bottom, left)
    local slot = box:AddChildToVerticalBox(widget)
    slot:SetPadding({ Left = left or 0, Top = top or 0, Right = 0, Bottom = bottom or 0 })
    return slot
end

local function build(kind, menu)
    local profile = PROFILES[kind]
    st = { kind = kind, profile = profile, menu = menu, address = menu:GetAddress(), tree = menu.WidgetTree,
        moved = {}, buttons = {}, open = false, signature = nil }
    states[kind] = st
    local root = st.tree.RootWidget
    local w = collect(root, {}, 0)
    st.w = w
    st.tplButton = w[profile.template]
    st.tplLabel = st.tplButton:GetChildAt(0)
    local canvas = profile.canvas and w[profile.canvas] or root
    local tplSlot = st.tplButton.Slot
    local tplPos = tplSlot:GetPosition()

    -- Make room for the new entry.
    for _, move in ipairs(profile.shift) do
        local widget = w[move[1]]
        if widget then
            local slot = widget.Slot
            local pos = slot:GetPosition()
            st.moved[#st.moved + 1] = { slot = slot, x = pos.X, y = pos.Y }
            slot:SetPosition({ X = pos.X + move[2], Y = pos.Y + move[3] })
        end
    end
    if profile.raise and w[profile.raise] then w[profile.raise].Slot:SetZOrder(10) end

    -- Menu entry: same slot settings, label colour and size as the entry above it.
    local entry, entryLabel = menuButton("MULTIPLAYER")
    entryLabel:SetColorAndOpacity(st.tplLabel.ColorAndOpacity)
    local entrySlot = canvas:AddChildToCanvas(entry)
    entrySlot:SetAnchors(tplSlot.LayoutData.Anchors)
    entrySlot:SetAlignment(tplSlot.LayoutData.Alignment)
    entrySlot:SetAutoSize(tplSlot.bAutoSize)
    entrySlot:SetSize(tplSlot:GetSize())
    entrySlot:SetPosition({ X = profile.entry.x or tplPos.X, Y = profile.entry.y })
    st.entry, st.entryLabel = entry, entryLabel
    if profile.extra then
        local extra, extraLabel = menuButton(profile.extra.label)
        extraLabel:SetColorAndOpacity(st.tplLabel.ColorAndOpacity)
        local extraSlot = canvas:AddChildToCanvas(extra)
        extraSlot:SetAnchors(tplSlot.LayoutData.Anchors)
        extraSlot:SetAlignment(tplSlot.LayoutData.Alignment)
        extraSlot:SetAutoSize(tplSlot.bAutoSize)
        extraSlot:SetSize(tplSlot:GetSize())
        extraSlot:SetPosition({ X = profile.extra.x, Y = profile.extra.y })
        st.extra, st.extraLabel = extra, extraLabel
    end

    local u = profile.underline
    if u and w[u.stock] then
        local stock = w[u.stock]
        local line = new("Image")
        pcall(function()
            local c = stock.ColorAndOpacity
            line:SetColorAndOpacity({ R = c.R, G = c.G, B = c.B, A = c.A })
        end)
        local slot = canvas:AddChildToCanvas(line)
        slot:SetAnchors(stock.Slot.LayoutData.Anchors)
        slot:SetAlignment(stock.Slot.LayoutData.Alignment)
        slot:SetSize(stock.Slot:GetSize())
        pcall(function()
            local pivot = stock.RenderTransformPivot
            line:SetRenderTransformPivot({ X = pivot.X, Y = pivot.Y })
        end)
        line:SetRenderScale({ X = 0, Y = 1 })
        line:SetVisibility(3)                -- never takes the mouse
        local also = {}
        for _, name in ipairs(u.also) do
            if w[name] then also[#also + 1] = w[name] end
        end
        st.underline = { stock = stock, line = line, slot = slot, also = also, dx = u.dx, dy = u.dy, scale = 0, shown = 0, hidden = false }
    end

    -- Panel.
    local panel = new("Border")
    panel:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.82 })
    panel:SetPadding({ Left = 28, Top = 22, Right = 28, Bottom = 14 })
    local box = new("VerticalBox")
    panel:AddChild(box)

    addRow(box, label("MULTIPLAYER", st.tplLabel, 28, WHITE), 0, 8)
    local accent = new("Border")
    accent:SetBrushColor({ R = 0.55, G = 0.02, B = 0.02, A = 1 })
    accent:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    local accentSize = new("Spacer")
    accentSize:SetSize({ X = PANEL_W, Y = 2 })
    accent:AddChild(accentSize)
    addRow(box, accent, 0, 16)

    local body = w[profile.body] or st.tplLabel
    st.status = label("", st.tplLabel, 18, WHITE)
    addRow(box, st.status, 0, 4)
    st.detail = label("", body, 14, GREY)
    addRow(box, st.detail, 0, 14)
    st.playersTitle = label("PLAYERS", st.tplLabel, 14, GREY)
    addRow(box, st.playersTitle, 0, 4)
    st.players = label("", body, 15, WHITE)
    addRow(box, st.players, 0, 14)

    local primary, primaryLabel = menuButton("HOST LOBBY", 18, true)
    addRow(box, primary, 0, 0)
    local join, joinLabel = menuButton("JOIN WORLD", 18, true)
    addRow(box, join, 0, 0)
    -- A guest's character is kept with the host's world: what there is, and starting over.
    st.character = label("", body, 14, GREY)
    addRow(box, st.character, 8, 0)
    local over, overLabel = menuButton("START OVER WITH A NEW CHARACTER", 18, true)
    addRow(box, over, 0, 0)
    local restore, restoreLabel = menuButton("CO-OP AUTOSAVES", 18, true)
    addRow(box, restore, 0, 0)
    local leave, leaveLabel = menuButton("LEAVE LOBBY", 18, true)
    addRow(box, leave, 0, 0)
    local back, backLabel = menuButton("BACK", 18, true)
    addRow(box, back, 0, 0)

    local panelSlot = canvas:AddChildToCanvas(panel)
    panelSlot:SetAnchors({ Minimum = { X = 0, Y = 0.5 }, Maximum = { X = 0, Y = 0.5 } })
    panelSlot:SetAlignment({ X = 0, Y = 0 })
    panelSlot:SetAutoSize(true)
    panelSlot:SetPosition({ X = profile.panel.x, Y = profile.panel.y })
    panel:SetVisibility(VIS_COLLAPSED)
    st.panel = panel
    st.primary, st.primaryLabel = primary, primaryLabel
    st.join, st.joinLabel = join, joinLabel
    st.restore, st.restoreLabel = restore, restoreLabel
    st.over, st.overLabel = over, overLabel
    st.leave = leave

    -- The stock entries do not change colour on hover, so the new entry does not either.
    -- Panel actions brighten on hover; the primary one is red like NEW GAME.
    st.buttons = {
        { widget = entry, label = entryLabel, click = function() UI.toggle() end },
        { widget = primary, label = primaryLabel, idle = RED, hover = RED_HOT, click = function() UI.primaryAction() end },
        { widget = leave, label = leaveLabel, idle = SOFT, hover = WHITE, click = function() C.leave() end },
        { widget = back, label = backLabel, idle = SOFT, hover = WHITE, click = function() UI.close() end },
        { widget = join, label = joinLabel, idle = RED, hover = RED_HOT, click = function()
            if C.world then C.world.join() end
        end },
        { widget = over, label = overLabel, idle = SOFT, hover = WHITE, click = function()
            -- asked twice: the first click only changes the button's words for a few seconds
            if st.overAt and os.clock() - st.overAt < 6 then
                st.overAt = nil
                if C.world and C.world.startOver then C.world.startOver() end
            else
                st.overAt = os.clock()
            end
            st.signature = nil
        end },
        { widget = restore, label = restoreLabel, idle = SOFT, hover = WHITE, click = function()
            -- The list of autosaves takes this panel's place; closing it brings the panel back.
            local main = states.main
            local opened = C.world and C.world.openAutosaves and C.world.openAutosaves(function()
                if main and states.main == main and not main.failed then
                    st = main
                    pcall(UI.open)
                end
            end)
            if opened then UI.close() end
        end },
    }
    if st.extra then
        st.buttons[#st.buttons + 1] = { widget = st.extra, label = st.extraLabel, click = function()
            UI.close()
            if C.modOptions then C.modOptions() end
        end }
    end
    for _, b in ipairs(st.buttons) do
        if b.idle then b.label:SetColorAndOpacity(slateColor(b.idle)) end
    end
    C.log("Multiplayer entry added to the %s menu", kind)
end

---------------------------------------------------------------- state -> widgets

local function refresh()
    local S = C.S
    if S.lobby then st.hostRequested = nil end
    local hosting = st.hostRequested ~= nil and (os.clock() - st.hostRequested) < 10
    local names = {}
    for id, name in pairs(S.members) do
        names[#names + 1] = (id == S.me) and (name .. "  (you)") or name
    end
    table.sort(names)
    local notice = S.notice and (os.time() - S.notice.at) < 8 and S.notice.text or nil
    local worldText = C.world and C.world.status() or nil
    local canJoin = C.world ~= nil and C.world.canJoin() == true
    -- the autosave is looked for once a second, not every frame
    if st == states.main and os.clock() >= (st.autosaveAt or 0) then
        st.autosaveAt = os.clock() + 1
        st.autosave = C.world and C.world.autosave and C.world.autosave() or nil
    end
    local autosave = st == states.main and not canJoin and st.autosave or nil
    local character = st == states.main and canJoin and C.world.character and C.world.character() or nil
    local confirming = character ~= nil and st.overAt ~= nil and os.clock() - st.overAt < 6
    local signature = table.concat({ tostring(S.ready), tostring(S.lobby), tostring(hosting), tostring(notice),
        tostring(worldText), tostring(canJoin), tostring(autosave), tostring(character), tostring(confirming), table.concat(names, "|") }, "#")
    if signature == st.signature then return end
    st.signature = signature

    local inLobby = S.lobby ~= nil
    if not S.ready then
        st.status:SetText(text("CONNECTING TO STEAM"))
        st.status:SetColorAndOpacity(slateColor(GREY))
        st.detail:SetText(text("Start the game through Steam to use multiplayer."))
    elseif inLobby then
        st.status:SetText(text(string.format("LOBBY ACTIVE  %d / %d", #names, C.config.MaxPlayers or 4)))
        st.status:SetColorAndOpacity(slateColor(GREEN))
        st.detail:SetText(text(#names > 1 and "Playing together." or "Waiting for friends to join."))
    elseif hosting then
        st.status:SetText(text("CREATING LOBBY"))
        st.status:SetColorAndOpacity(slateColor(GREY))
        st.detail:SetText(text("Contacting Steam."))
    else
        st.status:SetText(text("NOT IN A LOBBY"))
        st.status:SetColorAndOpacity(slateColor(WHITE))
        st.detail:SetText(text("Mod v" .. tostring(C.version) .. ". Signed in as " .. tostring(S.myName) .. ". Host a lobby, or accept a friend's Steam invite."))
    end
    if inLobby and worldText then st.detail:SetText(text(worldText)) end
    if notice then st.detail:SetText(text(notice)) end
    st.join:SetVisibility(canJoin and VIS_VISIBLE or VIS_COLLAPSED)
    st.restore:SetVisibility(autosave and VIS_VISIBLE or VIS_COLLAPSED)
    if autosave then st.restoreLabel:SetText(text("CO-OP AUTOSAVES  (" .. tostring(autosave):upper() .. ")")) end
    if canJoin then st.joinLabel:SetText(text("JOIN " .. tostring(C.world.hostName()):upper() .. "'S WORLD")) end
    st.character:SetVisibility(character and VIS_SELF_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
    st.over:SetVisibility(character and VIS_VISIBLE or VIS_COLLAPSED)
    if character then
        st.character:SetText(text(character))
        st.overLabel:SetText(text(confirming and "DELETE THIS CHARACTER?  CLICK AGAIN" or "START OVER WITH A NEW CHARACTER"))
    end

    st.playersTitle:SetVisibility(inLobby and VIS_SELF_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
    st.players:SetVisibility(inLobby and VIS_SELF_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
    st.players:SetText(text(table.concat(names, "\n")))

    st.primaryLabel:SetText(text(inLobby and "INVITE FRIENDS" or "HOST LOBBY"))
    local canAct = S.ready and not hosting
    st.primary:SetIsEnabled(canAct)
    local primaryButton = st.buttons[2]
    -- Only one action is highlighted: joining the world when that is possible.
    local accent = canJoin and SOFT or RED
    primaryButton.idle, primaryButton.hover = canAct and accent or GREY, canAct and (canJoin and WHITE or RED_HOT) or GREY
    primaryButton.label:SetColorAndOpacity(slateColor(primaryButton.hovered and primaryButton.hover or primaryButton.idle))
    st.leave:SetVisibility(inLobby and VIS_VISIBLE or VIS_COLLAPSED)
    st.entryLabel:SetText(text(inLobby and string.format("MULTIPLAYER  (%d)", #names) or "MULTIPLAYER"))
end

---------------------------------------------------------------- actions (act on the current menu)

local function blocked()
    local blocker = st.w[st.profile.blocker]
    return blocker ~= nil and blocker.Visibility ~= VIS_COLLAPSED
end

function UI.primaryAction()
    if not C.S.ready then return end
    if C.S.lobby then
        C.invite()
    else
        st.hostRequested = os.clock()
        C.host()
    end
end

function UI.open()
    if not st or st.open or blocked() then return end
    st.open = true
    st.signature = nil
    st.panel:SetVisibility(VIS_SELF_HIT_TEST_INVISIBLE)
end

function UI.close()
    if not st or not st.open then return end
    st.open = false
    st.panel:SetVisibility(VIS_COLLAPSED)
end

function UI.toggle()
    if st and st.open then UI.close() else UI.open() end
end

---------------------------------------------------------------- per-frame

local function pollButtons()
    for _, b in ipairs(st.buttons) do
        local hovered = b.widget:IsHovered()
        local pressed = b.widget:IsPressed()
        if hovered ~= b.hovered then
            b.hovered = hovered
            if b.idle then b.label:SetColorAndOpacity(slateColor(hovered and b.hover or b.idle)) end
        end
        if b.pressed and not pressed and hovered then
            local ok, e = pcall(b.click)
            if not ok then C.log("Menu click failed: %s", tostring(e)) end
        end
        b.pressed = pressed
    end
end

-- Draws the hover underline for the new entry and for the stock entries that were moved.
local function pollUnderline()
    local u = st.underline
    if not u then return end
    local target = nil
    if UI.debugHover then
        target = UI.debugHover == "entry" and st.entry or st.w[UI.debugHover]
    elseif st.entry:IsHovered() then
        target = st.entry
    else
        for _, b in ipairs(u.also) do
            if b:IsHovered() then target = b end
        end
    end
    -- the stock entries slide a little to the right and dim while hovered; so does ours
    local onEntry = target == st.entry
    if onEntry ~= u.onEntry then
        u.onEntry = onEntry
        pcall(function()
            st.entry:SetRenderTranslation({ X = onEntry and 7 or 0, Y = 0 })
            st.entry:SetRenderOpacity(onEntry and 0.6 or (st.entryOpacity or 1))
        end)
    end
    if target then
        local p = target.Slot:GetPosition()
        u.slot:SetPosition({ X = p.X + u.dx, Y = p.Y + u.dy })
        u.scale = math.min(1, u.scale + 0.14)
        if not u.hidden then
            u.hidden = true
            u.stock:SetRenderOpacity(0)
        end
    else
        u.scale = math.max(0, u.scale - 0.14)
        if u.hidden and u.scale == 0 then
            u.hidden = false
            u.stock:SetRenderOpacity(1)
        end
    end
    if u.scale ~= u.shown then
        u.shown = u.scale
        u.line:SetRenderScale({ X = u.scale, Y = 1 })
    end
end

-- The stock entries can fade in one by one (main menu intro). Follow the entry above
-- ours so the new one is not visible early and fades with the rest.
local function followStockEntry()
    local tpl, entry = st.tplButton, st.entry
    local opacity = tpl.RenderOpacity
    if opacity ~= st.entryOpacity then
        st.entryOpacity = opacity
        entry:SetRenderOpacity(opacity)
        if st.extra then st.extra:SetRenderOpacity(opacity) end
    end
    local visibility = tpl.Visibility
    if visibility ~= st.entryVisibility then
        st.entryVisibility = visibility
        entry:SetVisibility(visibility)
        if st.extra then st.extra:SetVisibility(visibility) end
    end
end

-- Makes the state for this menu instance current, building the widgets on first use.
-- Returns false when the UI is unavailable for it.
local function select(kind, menu)
    if not C or not PROFILES[kind] or not C.valid(menu) then return false end
    st = states[kind]
    if not st or st.address ~= menu:GetAddress() or (not st.failed and not C.valid(st.entry)) then
        local ok, e = xpcall(function() build(kind, menu) end, debug.traceback)
        if not ok then
            C.log("Could not build the %s menu UI: %s", kind, tostring(e))
            UI.destroy(kind)
            st = { kind = kind, address = menu:GetAddress(), failed = true }
            states[kind] = st
        end
    end
    return not st.failed
end

-- Call once per frame while the menu of this kind is on screen.
function UI.tick(kind, menu)
    if not select(kind, menu) then return end
    local ok, e = xpcall(function()
        if st.open and blocked() then UI.close() end
        followStockEntry()
        pollButtons()
        pollUnderline()
        refresh()
    end, debug.traceback)
    if not ok then
        C.log("Menu UI error, disabling it for the %s menu: %s", kind, tostring(e))
        st.failed = true
    end
end

-- Call when a reused menu widget (the pause menu) is shown again: start with the panel closed.
function UI.shown(kind, menu)
    if not select(kind, menu) then return end
    pcall(UI.close)
    for _, b in ipairs(st.buttons) do b.pressed = false end
end

-- Removes everything this module added to a menu (used when reloading during development).
function UI.destroy(kind)
    local s = states[kind]
    if not s then return end
    pcall(function()
        for _, m in ipairs(s.moved or {}) do m.slot:SetPosition({ X = m.x, Y = m.y }) end
        if s.panel then s.panel:RemoveFromParent() end
        if s.underline then
            s.underline.line:RemoveFromParent()
            s.underline.stock:SetRenderOpacity(1)
        end
        if s.entry then s.entry:RemoveFromParent() end
        if s.extra then s.extra:RemoveFromParent() end
    end)
    states[kind] = nil
    if st == s then st = nil end
end

function UI.init(context)
    C = context
end

function UI.state(kind) return states[kind or "main"] end

return UI
