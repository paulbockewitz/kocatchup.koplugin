-- JSON encode/decode. Uses KOReader's bundled rapidjson when available,
-- otherwise falls back to a small pure-Lua implementation so the module
-- also works under plain LuaJIT (unit tests, other frontends).
local ok, rapidjson = pcall(require, "rapidjson")
if ok and type(rapidjson) == "table" and rapidjson.encode and rapidjson.decode then
    return { encode = rapidjson.encode, decode = rapidjson.decode }
end

local Json = {}

-- encoding ------------------------------------------------------------------

local escape_map = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_char(c)
    return escape_map[c] or string.format("\\u%04x", c:byte())
end

local function encode_string(s)
    return '"' .. s:gsub('[%z\1-\31"\\]', escape_char) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true, n
end

local function encode_value(v, seen)
    local tv = type(v)
    if v == nil then
        return "null"
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            error("cannot encode non-finite number")
        end
        return string.format("%.14g", v)
    elseif tv == "string" then
        return encode_string(v)
    elseif tv == "table" then
        if seen[v] then error("cannot encode circular table") end
        seen[v] = true
        local parts = {}
        local arr, n = is_array(v)
        if arr then
            for i = 1, n do
                parts[#parts + 1] = encode_value(v[i], seen)
            end
            seen[v] = nil
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, val in pairs(v) do
                if type(k) == "string" then
                    parts[#parts + 1] = encode_string(k) .. ":" .. encode_value(val, seen)
                end
            end
            seen[v] = nil
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    error("cannot encode value of type " .. tv)
end

function Json.encode(v)
    return encode_value(v, {})
end

-- decoding ------------------------------------------------------------------

local decode_value

local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local unescape_map = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
    n = "\n", r = "\r", t = "\t",
}

local function utf8_char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
end

local function decode_string(s, i)
    local out = {}
    i = i + 1 -- skip opening quote
    while true do
        local c = s:sub(i, i)
        if c == "" then error("unterminated string") end
        if c == '"' then return table.concat(out), i + 1 end
        if c == "\\" then
            local esc = s:sub(i + 1, i + 1)
            if esc == "u" then
                local hex = s:sub(i + 2, i + 5)
                local cp = tonumber(hex, 16)
                if not cp then error("bad unicode escape") end
                if cp >= 0xD800 and cp <= 0xDBFF then
                    -- surrogate pair
                    local hex2 = s:sub(i + 8, i + 11)
                    local lo = tonumber(hex2, 16)
                    if s:sub(i + 6, i + 7) == "\\u" and lo then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        out[#out + 1] = utf8_char(cp)
                        i = i + 12
                    else
                        error("bad surrogate pair")
                    end
                else
                    out[#out + 1] = utf8_char(cp)
                    i = i + 6
                end
            else
                local ch = unescape_map[esc]
                if not ch then error("bad escape \\" .. esc) end
                out[#out + 1] = ch
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

local function decode_number(s, i)
    local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    local v = tonumber(num)
    if not v then error("bad number at position " .. i) end
    return v, i + #num
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "" then error("unexpected end of input") end
    if c == "{" then
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            if s:sub(i, i) ~= '"' then error("expected object key at " .. i) end
            local key
            key, i = decode_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ":" then error("expected ':' at " .. i) end
            obj[key], i = decode_value(s, i + 1)
            i = skip_ws(s, i)
            local sep = s:sub(i, i)
            if sep == "," then
                i = skip_ws(s, i + 1)
            elseif sep == "}" then
                return obj, i + 1
            else
                error("expected ',' or '}' at " .. i)
            end
        end
    elseif c == "[" then
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            arr[#arr + 1], i = decode_value(s, i)
            i = skip_ws(s, i)
            local sep = s:sub(i, i)
            if sep == "," then
                i = i + 1
            elseif sep == "]" then
                return arr, i + 1
            else
                error("expected ',' or ']' at " .. i)
            end
        end
    elseif c == '"' then
        return decode_string(s, i)
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        return decode_number(s, i)
    end
end

function Json.decode(s)
    if type(s) ~= "string" then error("expected string") end
    local v, i = decode_value(s, 1)
    i = skip_ws(s, i)
    if i <= #s then error("trailing garbage at " .. i) end
    return v
end

return Json
