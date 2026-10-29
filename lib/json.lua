-- JSON for pollen: decode (the station lists, mpv's replies) and encode (mpv's commands).
-- Pure Lua 5.3, no state. decode() raises an error on malformed input: call it with pcall.
-- JSON null decodes to nil (so it vanishes from tables), which is all pollen needs.

local J = {}

local find, sub, byte, char = string.find, string.sub, string.byte, string.char
local concat, tonumber = table.concat, tonumber

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function utf8char(n)
  if n < 0x80 then return char(n) end
  if n < 0x800 then return char(0xC0 | (n >> 6), 0x80 | (n & 0x3F)) end
  if n < 0x10000 then return char(0xE0 | (n >> 12), 0x80 | ((n >> 6) & 0x3F), 0x80 | (n & 0x3F)) end
  return char(0xF0 | (n >> 18), 0x80 | ((n >> 12) & 0x3F), 0x80 | ((n >> 6) & 0x3F), 0x80 | (n & 0x3F))
end

local value -- forward

local function skip(s, i)
  local _, e = find(s, "^[ \t\r\n]*", i)
  return e + 1
end

local function fail(s, i, what)
  error(("json: %s at character %d"):format(what, i), 0)
end

local function str(s, i) -- s[i] is the opening quote
  local parts, n, j = nil, 0, i + 1
  while true do
    local a = find(s, '["\\]', j)
    if not a then fail(s, i, "unterminated string") end
    if byte(s, a) == 34 then -- the closing quote
      if not parts then return sub(s, j, a - 1), a + 1 end
      n = n + 1; parts[n] = sub(s, j, a - 1)
      return concat(parts), a + 1
    end
    parts = parts or {}
    n = n + 1; parts[n] = sub(s, j, a - 1)
    local c = sub(s, a + 1, a + 1)
    if c == "u" then
      local cp = tonumber(sub(s, a + 2, a + 5), 16) or fail(s, a, "bad \\u escape")
      j = a + 6
      if cp >= 0xD800 and cp <= 0xDBFF and sub(s, j, j + 1) == "\\u" then -- a surrogate pair
        local lo = tonumber(sub(s, j + 2, j + 5), 16)
        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
          cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
          j = j + 6
        end
      end
      n = n + 1; parts[n] = utf8char(cp)
    else
      n = n + 1; parts[n] = ESCAPES[c] or fail(s, a, "bad escape")
      j = a + 2
    end
  end
end

local function arr(s, i)
  local t, n = {}, 0
  i = skip(s, i + 1)
  if sub(s, i, i) == "]" then return t, i + 1 end
  while true do
    local v
    v, i = value(s, i)
    n = n + 1; t[n] = v
    i = skip(s, i)
    local c = sub(s, i, i)
    if c == "]" then return t, i + 1 end
    if c ~= "," then fail(s, i, "expected , or ]") end
    i = skip(s, i + 1)
  end
end

local function obj(s, i)
  local t = {}
  i = skip(s, i + 1)
  if sub(s, i, i) == "}" then return t, i + 1 end
  while true do
    if sub(s, i, i) ~= '"' then fail(s, i, "expected a key") end
    local k
    k, i = str(s, i)
    i = skip(s, i)
    if sub(s, i, i) ~= ":" then fail(s, i, "expected :") end
    local v
    v, i = value(s, skip(s, i + 1))
    t[k] = v
    i = skip(s, i)
    local c = sub(s, i, i)
    if c == "}" then return t, i + 1 end
    if c ~= "," then fail(s, i, "expected , or }") end
    i = skip(s, i + 1)
  end
end

value = function(s, i)
  local c = sub(s, i, i)
  if c == '"' then return str(s, i) end
  if c == "{" then return obj(s, i) end
  if c == "[" then return arr(s, i) end
  if c == "t" and sub(s, i, i + 3) == "true" then return true, i + 4 end
  if c == "f" and sub(s, i, i + 4) == "false" then return false, i + 5 end
  if c == "n" and sub(s, i, i + 3) == "null" then return nil, i + 4 end
  local a, e = find(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if a then return tonumber(sub(s, a, e)) or fail(s, i, "bad number"), e + 1 end
  fail(s, i, "unexpected " .. (c == "" and "end" or ("'" .. c .. "'")))
end

function J.decode(s)
  local v, i = value(s, skip(s, 1))
  if skip(s, i) <= #s then fail(s, i, "trailing characters") end
  return v
end

-- encode: strings, numbers, booleans and arrays of them (mpv's commands), and plain tables
local function enc(v, out)
  local t = type(v)
  if t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      local e = ({ ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" })[c]
      return e or ("\\u%04x"):format(byte(c))
    end) .. '"'
  elseif t == "number" then
    out[#out + 1] = (math.type(v) == "integer" or v ~= math.floor(v)) and tostring(v) or ("%d"):format(v)
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      out[#out + 1] = "["
      for k = 1, #v do if k > 1 then out[#out + 1] = "," end; enc(v[k], out) end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for k, x in pairs(v) do
        if not first then out[#out + 1] = "," end
        first = false
        enc(tostring(k), out); out[#out + 1] = ":"; enc(x, out)
      end
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = "null"
  end
end

function J.encode(v)
  local out = {}
  enc(v, out)
  return concat(out)
end

return J
