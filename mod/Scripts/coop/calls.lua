-- Story calls with one storyline for everybody (Sync.Story off): the first call counts.
--
-- The game's story calls (Eddie's, and whoever else rings with something to say) are made
-- by the quest manager of each game by itself: `player:phoneNewCall(caller, audio, onAnswer,
-- onDecline, onEnd, text)`. What the call is for happens when it is answered or when it
-- ends: the phone runs the quest manager's function named in onAnswer / onEnd, which adds
-- the task and only then notes that the call has been heard (`eddieCalls[n]`). With one
-- storyline that note is shared, but it comes too late for a game whose own call is
-- already ringing: both calls ended, and the task was there twice (reported with 0.18.0,
-- "some phone calls that we get from Eddie ... will give duplicated tasks").
--
-- So a call is claimed when it starts to ring. The host keeps who has which call (by the
-- name of what it runs). The first player to ask has it; in every other game the same
-- call still rings and can be listened to, but its phone runs nothing (the three function
-- names on the phone are emptied), and the task comes from the first player's call
-- through the shared task table. When the player who has a call leaves before it was
-- heard, it is free again and a game that was told no starts its call again.
--
-- Only with one storyline: with separate storylines every player's calls are their own.
-- A host of a version without this never answers; a call then counts as before.

local Core = require("core")
local Net = require("net")
local World = require("coop.world")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local GEN = (rawget(_G, "DDSMP_CALLS_GEN") or 0) + 1
_G.DDSMP_CALLS_GEN = GEN
local function live() return rawget(_G, "DDSMP_CALLS_GEN") == GEN end

local Calls = { stats = { rung = 0, asked = 0, mine = 0, muted = 0, freed = 0, again = 0 } }

local PLAYER = "/Game/Player/playerCharacterBP.playerCharacterBP_C"
local KEEP = 900             -- seconds a call stays its player's without being asked for again

local held = {}              -- host: call -> { by = player id, at = os.time() }
local muted = {}             -- this game: call -> { retry = the call's onDecline, by, at }
local last = nil             -- the call ringing here: { key, answer, decline, finish }

local function oneStoryline()
    local Story = package.loaded["coop.story"]
    return World.shared() and type(Story) == "table" and Story.oneStoryline ~= nil and Story.oneStoryline() == true
end

local function hostId() return World.host or Net.S.owner end

local function text(param)
    local s = ""
    pcall(function()
        local v = param:get()
        s = type(v) == "string" and v or v:ToString()
    end)
    return s
end

-- Host: whose call it is. True when `who` has it (now or already).
local function decide(key, who)
    local h = held[key]
    if h and h.by ~= who and os.time() - h.at < KEEP and (h.by == Net.S.me or World.inWorld[h.by]) then
        return false, h.by
    end
    held[key] = { by = who, at = os.time() }
    return true, who
end

-- The call that rings here runs nothing any more. (Only while the phone still has this
-- very call: a later one has put its own names there.)
local function mute(call, by)
    local player = World.player()
    local phone = player and player.phoneRef
    if not valid(phone) then return false end
    local same = false
    pcall(function()
        same = phone.functionCallEnd:ToString() == call.finish and phone.functionCallAccept:ToString() == call.answer
    end)
    if not same then return false end
    local ok = pcall(function()
        phone.functionCallAccept = ""
        phone.functionCallDecline = ""
        phone.functionCallEnd = ""
    end)
    if not ok then
        log("Calls: the call '%s' could not be taken off this phone", call.key)
        return false
    end
    muted[call.key] = { retry = call.decline, by = by, at = os.time() }
    Calls.stats.muted = Calls.stats.muted + 1
    log("Calls: '%s' is %s's call: it rings here too, but the task comes from theirs", call.key, Net.name(by))
    pcall(function()
        local Hud = package.loaded["coop.hud"]
        if type(Hud) == "table" and Hud.toast then Hud.toast(Net.name(by) .. " got this call first: the task comes from their call", 6) end
    end)
    return true
end

-- A story call starts to ring in this game.
local function rang(player, answer, decline, finish)
    if player:GetAddress() ~= (World.player() and World.player():GetAddress()) then return end
    local key = finish ~= "" and finish or answer
    if key == "" then return end                 -- a call that does nothing when heard
    Calls.stats.rung = Calls.stats.rung + 1
    last = { key = key, answer = answer, decline = decline, finish = finish }
    if not oneStoryline() then return end
    if World.role == "host" then
        local ok, by = decide(key, Net.S.me)
        if ok then
            Calls.stats.mine = Calls.stats.mine + 1
            vlog("Calls: '%s' is this game's call", key)
        else
            mute(last, by)
        end
    else
        Calls.stats.asked = Calls.stats.asked + 1
        Net.send("ecq", { k = key }, hostId())
    end
end

Core.Hooks.add(PLAYER .. ":phoneNewCall", function(ctx, _, _, onAnswer, onDecline, onEnd)
    if not live() or not World.active then return end
    local player = ctx:get()
    if not valid(player) then return end
    local ok, e = pcall(rang, player, text(onAnswer), text(onDecline), text(onEnd))
    if not ok then log("Calls: %s", tostring(e)) end
end)

-- A guest's call starts to ring: the host says whose it is.
Net.on("ecq", function(sender, data)
    if not live() or World.role ~= "host" or not World.inWorld[sender] or type(data.k) ~= "string" or #data.k > 80 then return end
    if not oneStoryline() then return end
    local ok, by = decide(data.k, sender)
    Net.send("eca", { k = data.k, ok = ok and 1 or 0, by = by }, sender)
    vlog("Calls: %s asks for '%s': %s", Net.name(sender), data.k, ok and "theirs" or ("no, it is " .. Net.name(by) .. "'s"))
end)

Net.on("eca", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= hostId() or type(data.k) ~= "string" then return end
    if data.ok == 1 then
        Calls.stats.mine = Calls.stats.mine + 1
        muted[data.k] = nil
        vlog("Calls: '%s' is this game's call", data.k)
    elseif last and last.key == data.k then
        mute(last, tostring(data.by or sender))
    end
end)

-- A call is free again (its player left before it was heard): a game that was told no
-- has the quest manager try its call again, as after a declined one.
local function again(key)
    local m = muted[key]
    if not m then return end
    muted[key] = nil
    if m.retry == "" then return end
    local player = World.player()
    if not player then return end
    Calls.stats.again = Calls.stats.again + 1
    log("Calls: '%s' is free again; this game's call is tried again", key)
    pcall(function() player:phoneCallFunction(m.retry) end)
end

Net.on("ecf", function(sender, data)
    if not live() or World.role ~= "guest" or sender ~= hostId() or type(data.k) ~= "string" then return end
    again(data.k)
end)

World.listen("peerleft", function(id)
    if not live() or World.role ~= "host" then return end
    for key, h in pairs(held) do
        if h.by == id then
            held[key] = nil
            Calls.stats.freed = Calls.stats.freed + 1
            log("Calls: %s left with the call '%s': it is free again", Net.name(id), key)
            for _, other in ipairs(World.targets()) do Net.send("ecf", { k = key }, other) end
            again(key)
        end
    end
end)

local function reset()
    held, muted, last = {}, {}, nil
end
World.listen("start", function() if live() then reset() end end)
World.listen("stop", function() if live() then reset() end end)

function Calls.state() return { held = held, muted = muted, last = last } end
Calls.oneStoryline = oneStoryline

return Calls
