-- DDS Multiplayer: Steam lobbies, shared XP and co-op world sync for Drug Dealer Simulator.
--
-- Modules:
--   core.lua   logging, config, hooks, timers
--   net.lua    bridge DLL link: lobby, peers, messages, files, player state stream
--   xp.lua     shared XP
--   ui.lua     MULTIPLAYER entry and panel in the main menu and pause menu
--   coop/*.lua co-op world sync (loaded below when present)
--
-- All mod logic runs on the game thread, driven by the tick at the bottom of this file.

local Core = require("core")
local Net = require("net")
local ui = require("ui")
local XP = require("xp")

local config, log, valid = Core.config, Core.log, Core.valid
local S = Net.S
local M = {}   -- every module, also handed to the developer harness

---------------------------------------------------------------- lobby actions

local function host(quiet)
    if not S.ready then Net.notify("Steam is not ready yet") return end
    Net.command((quiet and "HOSTQUIET " or "HOST ") .. tostring(config.MaxPlayers or 4))
end

local function leave()
    Net.command("LEAVE")
end

local function memberSummary()
    local names = {}
    for _, name in pairs(S.members) do names[#names + 1] = name end
    table.sort(names)
    return table.concat(names, ", ")
end

local function statusText()
    local v = "Mod v" .. Core.VERSION .. ". "
    if not S.ready then return v .. "Steam bridge not ready" end
    if not S.lobby then
        return v .. string.format("Not in a lobby. Press %s to host and invite friends.", config.HostInviteKey)
    end
    return v .. string.format("Lobby with %d player(s): %s | shared XP sent %.0f, received %.0f",
        S.memberCount, memberSummary(), XP.S.stats.sent, XP.S.stats.received)
end

---------------------------------------------------------------- notifications

-- Lobby and co-op messages also appear as the game's own hint popup while in a world.
Net.listen("notice", function(text)
    if not config.InGameNotifications then return end
    pcall(function()
        local qm = Core.find("questManager_C")
        if qm then qm:quickHint(FText("[Multiplayer] " .. text), 0) end
    end)
end)

Net.listen("lobby", function(kind)
    if kind == "created" then
        Net.notify("Lobby created. Invite friends from the Steam overlay.")
    elseif kind == "joined" then
        Net.notify("Joined the multiplayer lobby.")
    end
end)
Net.listen("left", function() Net.notify("Left the multiplayer lobby") end)
Net.listen("joined", function(_, name) Net.notify(name .. " joined the lobby") end)
Net.listen("gone", function(_, name) Net.notify(name .. " left the lobby") end)

---------------------------------------------------------------- menus

ui.init({
    S = S, config = config, log = log, valid = valid, version = Core.VERSION,
    -- From the menus, hosting and inviting are separate steps.
    host = function() host(true) end,
    invite = function() Net.command("INVITE") end,
    leave = leave,
    world = {
        canJoin = function() return M.world ~= nil and M.world.canJoin() end,
        join = function() if M.world then M.world.requestJoin() end end,
        -- the autosave that can be loaded from the main menu: its date, or nil
        autosave = function()
            local info = M.world and not M.world.active and not M.world.joining and M.world.autosaveInfo() or nil
            return info and tostring(info.date or "saved") or nil
        end,
        loadAutosave = function() if M.world then M.world.loadAutosave() end end,
        hostName = function() return Net.name(S.owner) end,
        status = function()
            local W = M.world
            if not W or not Net.inLobby() then return nil end
            if W.active and W.role == "guest" then return "You are in " .. Net.name(S.owner) .. "'s world." end
            if W.active and W.role == "host" then
                local n = 0
                for _ in pairs(W.inWorld) do n = n + 1 end
                return string.format("%d player%s in your world.", n, n == 1 and "" or "s")
            end
            if W.joining then return "Loading " .. Net.name(S.owner) .. "'s world..." end
            if Net.isGuest() then
                if W.canJoin() then return "Join " .. Net.name(S.owner) .. "'s world to play together." end
                return "Go to the main menu to join " .. Net.name(S.owner) .. "'s world."
            end
            if Net.hasPeers() then return "Guests can join your world from their main menu." end
            return nil
        end,
    },
})

Core.Hooks.add("/Game/MainMenu/mainMenuWidget.mainMenuWidget_C:Tick", function(ctx)
    local menu = ctx:get()
    local world = package.loaded["coop.world"]
    if world then world.menu = { widget = menu, at = os.clock() } end
    ui.tick("main", menu)
end)

-- The player's pause menu widget is created once and re-added to the viewport on every
-- pause. It has no Tick of its own, so its Construct event switches on per-tick polling.
local pauseMenu = nil
Core.Hooks.add("/Game/Player/pauseMenu.pauseMenu_C:Construct", function(ctx)
    pauseMenu = ctx:get()
    ui.shown("pause", pauseMenu)
end)
Core.onTick(function()
    if not pauseMenu then return end
    local ok, alive = pcall(function()
        if not valid(pauseMenu) or not pauseMenu:IsInViewport() then return false end
        ui.tick("pause", pauseMenu)
        return true
    end)
    if not ok or not alive then pauseMenu = nil end
end)

---------------------------------------------------------------- keys and console

local function bindKey(name, fn)
    local key = Key[name]
    if not key then
        log("Unknown key '%s' in config.lua", tostring(name))
        return
    end
    -- Key callbacks arrive on UE4SS's input thread.
    RegisterKeyBind(key, function() ExecuteInGameThread(fn) end)
end

Core.bindKey = bindKey
bindKey(config.HostInviteKey, function() host(false) end)
bindKey(config.LeaveKey, leave)
bindKey(config.StatusKey, function() Net.notify(statusText()) end)

-- Console: ddsmp host | invite | leave | status | join <lobbyId> | testxp <amount>
RegisterConsoleCommandHandler("ddsmp", function(_, params, out)
    local cmd = (params[1] or "status"):lower()
    local function say(text)
        log("%s", text)
        pcall(function() out:Log("[DDSMP] " .. text) end)
    end
    if cmd == "host" then
        host(false)
    elseif cmd == "invite" then
        Net.command("INVITE")
    elseif cmd == "leave" then
        leave()
    elseif cmd == "join" and params[2] then
        Net.command("JOIN " .. params[2])
    elseif cmd == "testxp" then
        local amount = tonumber(params[2]) or 10
        local sm = XP.findStats()
        if sm then sm:addExp(amount) say("Called addExp(" .. amount .. ")") else say("Not in a game world") end
    else
        say(statusText())
    end
    return true
end)

---------------------------------------------------------------- co-op modules

M.Core, M.Net, M.ui, M.XP, M.host, M.leave, M.statusText = Core, Net, ui, XP, host, leave, statusText

for _, name in ipairs({ "coop.repl", "coop.world", "coop.avatar", "coop.dyn", "coop.sync", "coop.npc", "coop.pop", "coop.k9", "coop.story", "coop.hud", "coop.screen", "coop.emote", "coop.look", "coop.traits", "coop.thumbs", "coop.clerk", "coop.teammap", "coop.scale", "coop.levels", "coop.eddie", "coop.homes", "coop.casino", "coop.tags" }) do
    local ok, mod = pcall(require, name)
    if ok then
        M[name:match("[^.]+$")] = mod
    elseif not tostring(mod):find("not found", 1, true) then
        log("Module %s failed to load: %s", name, tostring(mod))
    end
end

---------------------------------------------------------------- startup and main tick

local booted = false
local devTick = nil

local function boot()
    booted = true
    -- "-ddsmp=NAME" on the command line gives this instance its own ipc directory, so two
    -- copies of the game can run from one install during development.
    local commandLine = ""
    pcall(function()
        commandLine = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetCommandLine():ToString()
    end)
    Core.instance = commandLine:match("%-ddsmp=([%w_%-]+)")
    Core.commandLine = commandLine
    -- "-ddsmp_server": this copy only hosts (see the end of this file)
    Core.server = commandLine:find("-ddsmp_server", 1, true) ~= nil
    if Net.start(Core.MOD_DIR, Core.instance, log) then
        Core.logFile = Net.ipcDir() .. "/mod.log"
        -- the log of the session before stays readable (a crash is looked at after a restart)
        pcall(function()
            os.remove(Net.ipcDir() .. "/mod.prev2.log")
            os.rename(Net.ipcDir() .. "/mod.prev.log", Net.ipcDir() .. "/mod.prev2.log")
            os.rename(Core.logFile, Net.ipcDir() .. "/mod.prev.log")
        end)
        local f = io.open(Core.logFile, "wb")
        if f then f:close() end
        log("v%s loaded. %s = host/invite, %s = leave, %s = status", Core.VERSION, config.HostInviteKey,
            config.LeaveKey, config.StatusKey)
    end
    -- Developer harness: only when <mod>/autotest.txt and Scripts/devtest.lua both exist.
    if Core.fileSize(Core.MOD_DIR .. "/autotest.txt") > 0 then
        local ok, dev = pcall(require, "devtest")
        if ok and type(dev) == "function" then
            devTick = dev(M)
        else
            log("devtest not loaded: %s", tostring(dev))
        end
    end
end

Core.onTick(function() Net.poll() end)

---------------------------------------------------------------- server mode (experimental)

-- Started with -ddsmp_server (and best with -nullrhi -nosound, which makes the game draw and
-- play nothing) a copy of the game does nothing but host: from the main menu it loads the
-- co-op autosave, or the last saved game when there is none, opens a lobby and keeps it
-- open. Nobody sits at it: tutorial tips are closed, and the "who are you" screen stays
-- away. It is still the whole game, with its own Steam account that owns it.
do
    local stage, since, menuSince = "menu", os.clock(), nil
    Core.every(1, function()
        if not Core.server then return end
        local W = M.world
        if not W then return end
        local now = os.clock()
        local player = W.player()
        if stage == "menu" then
            local up = W.menu ~= nil and now - W.menu.at < 1.5 and not player
            menuSince = up and (menuSince or now) or nil
            -- a few seconds for the menu to settle and the bridge to be ready
            if menuSince and now - menuSince > 8 and S.ready then
                local loaded = (W.autosaveInfo() ~= nil and W.loadAutosave()) or W.continueGame()
                log("Server: %s", loaded and "loading the world" or "no world could be loaded (no autosave, no saved game?)")
                stage, since, menuSince = loaded and "loading" or "menu", now, nil
            end
        elseif stage == "loading" then
            if player and Core.find("statisticsManager_C") and now - since > 25 then
                stage, since = "hosting", now - 60
            elseif now - since > 240 then
                stage, since = "menu", now
            end
        elseif stage == "hosting" then
            if not player then
                stage, since = "menu", now
            elseif not S.lobby and now - since >= 60 then
                since = now
                log("Server: opening the lobby")
                host(true)
            end
            pcall(function()
                local q = Core.find("questManager_C")
                if q and q.tipActive == true then
                    pcall(function() if valid(q.curGameTip) then q.curGameTip:killWidget() end end)
                    q:gameTipEnd()
                end
            end)
        end
    end)
end
Core.every(0.25, Core.Hooks.ensure)
Core.every(1, function() if devTick then devTick() end end)

-- The whole mod runs on the game thread. Running Lua from UE4SS's async thread as well
-- (LoopAsync) corrupts the Lua state sooner or later and crashes the game, so the tick
-- uses the game-thread timer; the async fallback is only for UE4SS builds without it.
local function tick()
    if not booted then
        local ok, e = xpcall(boot, debug.traceback)
        if not ok then log("Startup failed: %s", tostring(e)) end
    end
    Core.runTick()
end

if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(30, function()
        tick()
        return false
    end)
else
    local queued, queuedAt = false, 0
    LoopAsync(100, function()
        if not queued or os.clock() - queuedAt > 2 then
            queued, queuedAt = true, os.clock()
            ExecuteInGameThread(function()
                queued = false
                tick()
            end)
        end
        return false
    end)
end
