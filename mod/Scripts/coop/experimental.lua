-- EXPERIMENTAL: new features that are not fully tested yet, each off until the player
-- switches it on (the EXPERIMENTAL page of MOD OPTIONS, or the Experimental table of
-- config.lua).
--
-- A feature goes in FEATURES below and asks `Core.experimental("Key")` wherever it would
-- do something. Once it is tested it leaves the list and the question goes with it (a key
-- left behind in somebody's config.lua does nothing).
--
--   key    the name in config.lua's Experimental table
--   name   the row's words on the page
--   desc   grey words under them (optional)
--   needs  a module of an optional addon: the row is shown only with the addon installed
--   under  the key of another feature this one is a setting of: its row is shown only
--          while that feature is on
--   live   true: the switch counts at once (`Core.experimental` answers with the new
--          value; `apply(on)` is called when the feature has one). Without it the switch
--          counts after a restart, which is the safe choice for anything that sets itself
--          up when the game starts or a world loads.
--
-- A switch is this player's own: nothing here tells the other players. A feature that
-- needs every player to have it has to check that itself.

local Core = require("core")
local Screen = require("coop.screen")
local Hud = require("coop.hud")

local log = Core.log

local Experimental = {}

Experimental.FEATURES = {
    -- coop/orders.lua: the task list at the left as the open deliveries, sorted
    { key = "DeliveryList", name = "DELIVERY LIST", desc = "The O key sorts the task list at the left: deliveries by drug or by area, the other tasks in a group of their own or with their area.",
        live = true, apply = function()
            local Orders = package.loaded["coop.orders"]
            if type(Orders) == "table" and Orders.apply then Orders.apply() end
        end },
    -- coop/marks.lua, coop/colours.lua: every player sees the marks who has this on; the
    -- host needs this version
    { key = "ClientMarks", name = "MARK CLIENTS", desc = "Click the picture of a client or dealer on Shady Comm to mark the order as yours, in your colour (COLOUR, under your name there).",
        live = true, apply = function()
            local Marks = package.loaded["coop.marks"]
            if type(Marks) == "table" and Marks.apply then Marks.apply() end
        end },
    -- (a setting of MARK CLIENTS: shown under it while that is on)
    { key = "AutoMark", under = "ClientMarks", name = "AUTOMATICALLY MARK ACCEPTED DELIVERIES", desc = "An order you confirm on Shady Comm is marked as yours at once.", live = true },
    -- coop/hud.lua, coop/look.lua: F next to the key of "Use the mod's places" (KEYBINDS)
    { key = "UseWithF", name = "USE THE MOD'S PLACES WITH F", desc = "F, like the game's own places, wherever the game has nothing of its own on F.", live = true },
    -- coop/dance.lua: without it the club's dance floor stays black and white
    { key = "DanceFloor", name = "DANCE FLOOR LIGHTS", desc = "The club's dance floor lights up in colours while somebody stands on it.", live = true },
    -- coop/stack.lua (only the player who climbs needs it on)
    { key = "PlayerStacking", name = "STAND ON OTHER PLAYERS", desc = "Jump onto a crouching player; when they stand up you are higher up the wall.",
        live = true, apply = function(on)
            local Stack = package.loaded["coop.stack"]
            if type(Stack) == "table" and Stack.apply then Stack.apply(on) end
        end },
    -- coop/look.lua, coop/avatar.lua: the WATCHES tab of the clothes shops and the wardrobe,
    -- and watches on the figures. Without it nothing of them shows in this player's game.
    { key = "Watches", name = "WEARABLE WATCHES", desc = "A WATCHES tab at the clothes shops. Only players with this on see watches.",
        live = true, apply = function()
            local Avatar, Look = package.loaded["coop.avatar"], package.loaded["coop.look"]
            -- the other players' figures are made again, and ours is told again
            if type(Avatar) == "table" and Avatar.setLook then
                local looks = {}
                for id, l in pairs(Avatar.looks or {}) do looks[id] = l end
                for id, l in pairs(looks) do Avatar.setLook(id, l) end
            end
            if type(Look) == "table" and Look.announce then Look.announce() end
        end },
}

Experimental.NONE = "No experimental features in this version."

local function feature(key)
    for _, f in ipairs(Experimental.FEATURES) do
        if f.key == key then return f end
    end
    return nil
end

-- What is switched on in the running game, as a list of keys (features of the list only).
function Experimental.active()
    local on = {}
    for _, f in ipairs(Experimental.FEATURES) do
        if Core.experimental(f.key) then on[#on + 1] = f.key end
    end
    return on
end

-- Switches a feature on or off: into config.lua through `write(key, "Experimental", value)`
-- (the writer of coop/options.lua), and into the running game when the feature is `live`.
-- Returns true when the file has it.
function Experimental.set(key, on, write)
    local f = feature(key)
    if not f then return false end
    on = on == true
    if not write(f.key, "Experimental", on) then
        pcall(Hud.toast, "config.lua could not be written", 4)
        return false
    end
    if f.live then
        if type(Core.config.Experimental) ~= "table" then Core.config.Experimental = {} end
        Core.config.Experimental[f.key] = on
        if f.apply then
            local ok, e = pcall(f.apply, on)
            if not ok then log("Experimental: %s: %s", f.key, tostring(e)) end
        end
    end
    log("Experimental: %s = %s%s", f.key, on and "true" or "false", f.live and "" or " (after a restart)")
    return true
end

-- The page of MOD OPTIONS. `ui` is what coop/options.lua draws its own pages with:
-- scr, inner, row, put, emptyLine, render, write, file (config.lua as it is now, a table
-- or nil), YELLOW.
function Experimental.page(ui)
    local scr, inner = ui.scr, ui.inner
    if #Experimental.FEATURES == 0 then
        ui.emptyLine(inner, Experimental.NONE)
        return
    end
    local file = ui.file and ui.file() or nil
    local inFile = file and type(file.Experimental) == "table" and file.Experimental or nil
    local function inFileOn(key)
        if inFile then return inFile[key] == true end
        return Core.experimental(key)
    end
    for _, f in ipairs(Experimental.FEATURES) do
        local running = Core.experimental(f.key)
        local on = running
        if inFile then on = inFile[f.key] == true end
        -- (a setting of another feature shows only while that feature is on)
        if f.under and not inFileOn(f.under) then goto continue end
        if f.needs and type(package.loaded[f.needs]) ~= "table" then goto continue end
        local sub, subColor = f.desc, nil
        if on ~= running then
            sub, subColor = (f.desc and (f.desc .. "  ") or "") .. "Changes after a restart.", ui.YELLOW
        end
        local b = scr.button(on and "ON" or "OFF", nil, function()
            if Experimental.set(f.key, not on, ui.write) then ui.render() end
        end)
        scr.tint(b, on and Screen.GREEN or Screen.GREY)
        ui.row(inner, f.name, sub, { b.widget }, subColor)
        ::continue::
    end
end

-- (a report with the log then says what was switched on)
do
    local on = Experimental.active()
    if #on > 0 then log("Experimental: switched on: %s", table.concat(on, ", ")) end
end

return Experimental
