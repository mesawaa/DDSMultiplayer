-- Minimal JSON encoder/decoder for network messages. Output never contains raw control
-- characters, so an encoded value is always a single line. Decoding never executes code.

local json = {}

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    return n == #t
end

function json.encode(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v % 1 == 0 and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.6g", v)
    elseif t == "string" then
        return encodeString(v)
    elseif t == "table" then
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[i] = json.encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, val in pairs(v) do
            parts[#parts + 1] = encodeString(tostring(k)) .. ":" .. json.encode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function skip(s, i)
    return s:find("%S", i) or #s + 1
end

local decodeValue

local function decodeString(s, i)
    local out = {}
    i = i + 1
    while true do
        local j = s:find('["\\]', i)
        if not j then error("unterminated string") end
        out[#out + 1] = s:sub(i, j - 1)
        if s:sub(j, j) == '"' then return table.concat(out), j + 1 end
        local e = s:sub(j + 1, j + 1)
        if e == "n" then out[#out + 1] = "\n"
        elseif e == "r" then out[#out + 1] = "\r"
        elseif e == "t" then out[#out + 1] = "\t"
        elseif e == "u" then
            local code = tonumber(s:sub(j + 2, j + 5), 16) or 63
            out[#out + 1] = code < 256 and string.char(code) or "?"
            j = j + 4
        else out[#out + 1] = e end
        i = j + 2
    end
end

decodeValue = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            local key
            key, i = decodeString(s, skip(s, i))
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then error("expected ':'") end
            obj[key], i = decodeValue(s, i + 1)
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            if d ~= "," then error("expected ',' or '}'") end
            i = i + 1
        end
    elseif c == "[" then
        local arr = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            arr[#arr + 1], i = decodeValue(s, i)
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            if d ~= "," then error("expected ',' or ']'") end
            i = i + 1
        end
    elseif c == '"' then
        return decodeString(s, i)
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4
    end
    local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    if not num or num == "" then error("unexpected character at " .. i) end
    return tonumber(num), i + #num
end

-- Returns the decoded value, or nil plus an error message.
function json.decode(s)
    if type(s) ~= "string" or #s > 2000000 then return nil, "bad input" end
    local ok, value = pcall(function()
        local v = decodeValue(s, 1)
        return v
    end)
    if not ok then return nil, value end
    return value
end

return json
