-- Pouring at a work station while another player uses the same equipment.
--
-- The game checks a jar (or tray, mortar, flask) when the player picks it: empty, or holding
-- the same substance. Then the amount window opens, and its ADD only asks "is it empty?":
-- empty, the jar takes the new substance; not empty, the grams are added to what it already
-- holds, whatever that is. In one game nothing can change the jar while the window is open.
-- In co-op another player can fill it in the meantime: their amphetamine arrives, and this
-- player's 50 g of marijuana are then added to it as amphetamine.
--
-- So while the amount window is open, a change from another game to what the window pours
-- into (or takes from) closes the window the way its CANCEL does: nothing is moved, the
-- package keeps its contents, and the player is told who used the equipment.
--
-- And a pour is sent at once (not at the next look at things nearby, up to a second or
-- six away), so two players who press ADD at nearly the same moment rarely both see an
-- empty jar.

local Core = require("core")
local World = require("coop.world")
local Repl = require("coop.repl")
local Sync = require("coop.sync")
local Net = require("net")

local log = Core.log
local valid = Core.valid

local Pour = { stats = { closed = 0, pushed = 0 } }

local ADD_WIDGET = "/Game/Drugs/DrugLab/workStationSubstanceAddWidget.workStationSubstanceAddWidget_C"
local EQUIPMENT = "/Game/Drugs/DrugLab/workStationEquipmentBase.workStationEquipmentBase_C"
-- what equipment holds
local HELD = { "curCapacity", "InitialSubstanceMixProp", "FinalProductMixProp", "productionFinished" }

local pending = nil  -- { widget, address, held }: an open window and what its equipment held before a change came in

local function isEquipment(obj)
    local base = Core.class(EQUIPMENT)
    if not base or not valid(obj) then return false end
    local ok, is = pcall(function() return obj:IsA(base) end)
    return ok and is == true
end

local function heldText(obj)
    local v = Repl.export(obj, HELD)
    local parts = {}
    for i, name in ipairs(HELD) do parts[i] = name .. "=" .. tostring(v[name]) end
    return table.concat(parts, ";")
end

-- The equipment the window pours into, and the equipment it takes from (a window opened
-- with a jar as the source); packages are not equipment.
local function involved(w)
    local list = {}
    for _, name in ipairs({ "Equipment", "Substance" }) do
        pcall(function()
            local obj = w[name]
            if isEquipment(obj) then list[#list + 1] = obj end
        end)
    end
    return list
end

local function stillOpen(w)
    local ok, on = pcall(function() return valid(w) and w:IsInViewport() end)
    return ok and on == true
end

-- The amount window on screen, if any. Looked for only when another game changes a piece
-- of equipment while this game's player is at a work station. The window last opened is
-- known from its Setup (whose hook may not be in place yet for the session's first one);
-- otherwise all windows of the kind are gone through (some 40 ms).
local lastWindow = nil
Core.Hooks.add(ADD_WIDGET .. ":Setup", function(ctx) lastWindow = ctx:get() end)

local function openWindow()
    if lastWindow and stillOpen(lastWindow) then return lastWindow end
    if not Core.class(ADD_WIDGET) then return nil end      -- never opened in this session
    for _, w in ipairs(FindAllOf("workStationSubstanceAddWidget_C") or {}) do
        if stillOpen(w) then
            lastWindow = w
            return w
        end
    end
    return nil
end

-- Called with what another game is about to change here (coop/sync.lua).
function Pour.before(obj)
    pending = nil
    if not isEquipment(obj) then return end
    local player = World.player()
    local at = false
    pcall(function() at = player.atWorkStation == true end)
    if not at then return end
    local w = openWindow()
    if not w then return end
    local address = obj:GetAddress()
    for _, e in ipairs(involved(w)) do
        if e:GetAddress() == address then
            local ok, text = pcall(heldText, obj)
            if ok then pending = { widget = w, address = address, held = text } end
            return
        end
    end
end
table.insert(Sync.beforeApply, Pour.before)

local function equipmentName(obj)
    local name = nil
    pcall(function() name = obj.childNameStorage:ToString() end)
    if not name or name == "" then return "equipment" end
    return name:lower()
end

-- ... and with it again once the change is in.
function Pour.guard(obj)
    local p = pending
    pending = nil
    if not p or p.address ~= obj:GetAddress() or not stillOpen(p.widget) then return nil end
    local ok, now = pcall(heldText, obj)
    if not ok or now == p.held then return nil end
    local w = p.widget
    local who = Sync.applyingFrom and Net.name(Sync.applyingFrom) or "Another player"
    local name = equipmentName(obj)
    local closed = pcall(function() w:BndEvt__btnCancel_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature() end)
    if not closed then pcall(function() w:killWidget(false) end) end
    Pour.stats.closed = Pour.stats.closed + 1
    log("Pour: %s changed the %s while the amount window was open; window closed, nothing poured", who, name)
    Core.after(0.1, function()
        local hud = package.loaded["coop.hud"]
        if type(hud) == "table" and hud.toast then
            pcall(hud.toast, string.format("%s just used the %s. Nothing was poured.", who, name), 4)
        end
    end)
    return nil
end
table.insert(Sync.refreshGuards, Pour.guard)

-- After ADD: what the window poured into and took from goes out now.
Core.Hooks.add(ADD_WIDGET .. ":BndEvt__btnAdd_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature", function(ctx)
    if not World.shared() then return end
    local w = ctx:get()
    if not valid(w) then return end
    for _, obj in ipairs(involved(w)) do
        if Core.alive(obj) then
            local key = Repl.key(obj)
            local sent
            if Sync.tracked()[key] then sent = Sync.watchObject(obj) > 0 else sent = Sync.pushObject(obj) end
            if sent then Pour.stats.pushed = Pour.stats.pushed + 1 end
            Core.vlog("Pour: %s sent right after ADD (%s)", key, tostring(sent))
        end
    end
end)

return Pour
