-- The player's own voice. The game has one set of sounds for its player (the jump, the
-- landing, being out of breath, a fall, a cough, taking a drug, climbing a fence or a
-- wall), and they are a man's. A player whose character is a woman hears them higher and a
-- little quieter: FemaleVoicePitch (FemaleVoiceClimbPitch for the climbing sounds) and
-- FemaleVoiceVolume in config.lua multiply what the game's sounds have (1 and 1 leave them
-- as they are). Nobody else hears these sounds: every game plays only its own player's.
--
-- The numbers are written into the sounds themselves (a cue's PitchMultiplier and
-- VolumeMultiplier, a wave's Pitch and Volume). The engine reads them whenever it plays or
-- mixes one, so nothing is hooked. What the game had is read before the first change and
-- put back for a man. The sounds are loaded with the player's class; a world that comes
-- after the main menu has them fresh, so they are set again for every new character.

local Core = require("core")
local World = require("coop.world")
local Look = require("coop.look")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Voice = { pitch = 1, volume = 1, climb = 1, count = 0 }

local AUDIO = "/Game/Audio/"
-- { asset below Audio, true for a cue, true for a climbing sound }
local SOUNDS = {
    { "Player/regularJumpCue", true }, { "Player/regularLandCue", true }, { "Player/staminaBreathCue", true },
    { "Player/tiredBreath-01", false }, { "Player/maleCough-01-002", false },
    { "FallDamage/fallDamageSmallCue", true }, { "FallDamage/fallDamageHighCue", true },
    { "GUI/DrugUse/DrugUseSmoke_Cue", true }, { "GUI/DrugUse/DrugUseSnort_Cue", true }, { "GUI/DrugUse/DrugUseSwallow_Cue", true },
    { "SFX/ObstacleJumping/fenceJumpCue", true, true }, { "SFX/ObstacleJumping/wallJumpCue", true, true },
}
Voice.SOUNDS = SOUNDS

local was = {}        -- asset -> { pitch, volume } as the game has them
local key = nil       -- the character and the numbers the sounds were last set for
local retryAt, retries = nil, 0

-- pitch, volume, pitch of the climbing sounds
local function numbers()
    local p, v = tonumber(Core.config.FemaleVoicePitch) or 1.2, tonumber(Core.config.FemaleVoiceVolume) or 0.8
    local c = tonumber(Core.config.FemaleVoiceClimbPitch) or 1.3
    return math.max(0.5, math.min(2, p)), math.max(0, math.min(2, v)), math.max(0.5, math.min(2, c))
end

local function find(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if valid(o) then return o end
    return nil
end

-- Sets every sound; returns how many were there.
local function set(pitch, volume, climb)
    local done = 0
    for _, s in ipairs(SOUNDS) do
        local name = s[1]
        pcall(function()
            local o = find(AUDIO .. name .. "." .. name:match("[^/]+$"))
            if not o then return end
            local pk, vk = s[2] and "PitchMultiplier" or "Pitch", s[2] and "VolumeMultiplier" or "Volume"
            if not was[name] then was[name] = { o[pk], o[vk] } end
            o[pk] = was[name][1] * (s[3] and climb or pitch)
            o[vk] = was[name][2] * volume
            done = done + 1
        end)
    end
    return done
end

local function woman()
    local ok, yes = pcall(function()
        if not World.extras() then return false end
        Look.current()                      -- (reads the player's file the first time)
        return Look.state().gender == "f"
    end)
    return ok and yes == true
end

local function check()
    local player = World.player()
    if not player then
        key, retryAt, retries = nil, nil, 0
        return
    end
    local pitch, volume, climb = 1, 1, 1
    if woman() then pitch, volume, climb = numbers() end
    local k = string.format("%d %.3f %.3f %.3f", player:GetAddress(), pitch, volume, climb)
    local now = os.clock()
    if k == key and not (retryAt and now >= retryAt) then return end
    if k ~= key then retries = 0 end
    key = k
    Voice.count = set(pitch, volume, climb)
    Voice.pitch, Voice.volume, Voice.climb = pitch, volume, climb
    -- a sound the world has not loaded yet: looked for a few more times
    retryAt = nil
    if Voice.count < #SOUNDS and retries < 3 then
        retries = retries + 1
        retryAt = now + 20
    end
    vlog("Voice: pitch %.2f, volume %.2f on %d of %d sounds", pitch, volume, Voice.count, #SOUNDS)
end

Core.every(2, function() pcall(check) end)

-- Right away (the "who are you" screen, after the choice).
function Voice.refresh()
    key = nil
    pcall(check)
end

return Voice
