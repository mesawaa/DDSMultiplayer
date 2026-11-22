-- The keys a key binding of the mod can be put on: for each the name config.lua knows it by
-- (UE4SS's), the name the game's engine knows it by (to ask whether it is held down), and
-- what is written on the screen for it.

local Keys = {}

Keys.LIST = {}
local byName, byUe = {}, {}

local function add(name, ue, label)
    -- (only what this build of UE4SS can bind)
    if type(Key) ~= "table" or Key[name] == nil then return end
    local k = { name = name, ue = ue, label = label or name }
    Keys.LIST[#Keys.LIST + 1] = k
    byName[name] = k
    byUe[ue:upper()] = k
end

for c = string.byte("A"), string.byte("Z") do add(string.char(c), string.char(c)) end
for i, word in ipairs({ "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE" }) do
    local ue = word:sub(1, 1) .. word:sub(2):lower()
    add(word, ue, tostring(i - 1))
    add("NUM_" .. word, "NumPad" .. ue, "NUM " .. tostring(i - 1))
end
for i = 1, 12 do add("F" .. i, "F" .. i) end
add("SPACE", "SpaceBar")
add("TAB", "Tab")
add("CAPS_LOCK", "CapsLock", "CAPS LOCK")
add("BACKSPACE", "BackSpace")
add("INS", "Insert", "INSERT")
add("DEL", "Delete", "DELETE")
add("HOME", "Home")
add("END", "End")
add("PAGE_UP", "PageUp", "PAGE UP")
add("PAGE_DOWN", "PageDown", "PAGE DOWN")
add("LEFT_ARROW", "Left", "LEFT")
add("RIGHT_ARROW", "Right", "RIGHT")
add("UP_ARROW", "Up", "UP")
add("DOWN_ARROW", "Down", "DOWN")
add("LEFT_SHIFT", "LeftShift", "LEFT SHIFT")
add("RIGHT_SHIFT", "RightShift", "RIGHT SHIFT")
add("LEFT_CONTROL", "LeftControl", "LEFT CTRL")
add("RIGHT_CONTROL", "RightControl", "RIGHT CTRL")
add("LEFT_ALT", "LeftAlt", "LEFT ALT")
add("RIGHT_ALT", "RightAlt", "RIGHT ALT")
add("OEM_ONE", "Semicolon", ";")
add("OEM_TWO", "Slash", "/")
add("OEM_THREE", "Tilde", "`")
add("OEM_FOUR", "LeftBracket", "[")
add("OEM_FIVE", "Backslash", "\\")
add("OEM_SIX", "RightBracket", "]")
add("OEM_SEVEN", "Apostrophe", "'")
add("OEM_COMMA", "Comma", ",")
add("OEM_PERIOD", "Period", ".")
add("OEM_MINUS", "Hyphen", "-")
add("OEM_PLUS", "Equals", "=")

-- other ways config.lua may write a key
local ALSO = { ["/"] = "OEM_TWO", SLASH = "OEM_TWO", ENTER = "RETURN" }

-- The entry for what config.lua says (nil for a key that is not on the list).
function Keys.find(value)
    local name = tostring(value or ""):upper()
    return byName[ALSO[name] or name]
end

-- The engine's name of the key (as it is when the key is not on the list).
function Keys.ue(value)
    local k = Keys.find(value)
    return k and k.ue or tostring(value or "")
end

function Keys.label(value)
    local k = Keys.find(value)
    return k and k.label or tostring(value or ""):upper()
end

-- The entry for an engine key name.
function Keys.fromUe(ue) return byUe[tostring(ue or ""):upper()] end

-- The keys of the list that are held down now: { [name] = true }.
function Keys.down(pc)
    local out = {}
    for _, k in ipairs(Keys.LIST) do
        local ok, held = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(k.ue) }) == true end)
        if ok and held then out[k.name] = true end
    end
    return out
end

return Keys
