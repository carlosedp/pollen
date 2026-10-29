-- Headless smoke test: pollen on norns-web's norns API (tools/norns-web/lib/norns.lua, the
-- same Lua the browser runs), with the page's side stubbed to record engine commands.
-- Plays every part, macro, gesture and variety, and checks what reaches the engine.
--
--   lua test/smoke.lua        (Lua 5.3+, from the repo root)

math.randomseed(1)
local errors, calls, sets, frames = {}, {}, {}, 0
js_bridge = {
  log = function() end,
  error = function(e) errors[#errors + 1] = e; io.stderr:write("error: ", e, "\n") end,
  engine = function(name, ...)
    calls[name] = (calls[name] or 0) + 1
    if name == "set" then
      local k, v = ...
      sets[k] = sets[k] or { n = 0 }
      local s = sets[k]
      s.n, s.last = s.n + 1, v
      s.min, s.max = math.min(s.min or v, v), math.max(s.max or v, v)
      assert(type(v) == "number" and v == v and v > -math.huge and v < math.huge,
        ("set %s: not a finite number: %s"):format(k, tostring(v)))
    elseif name == "reel" then
      local secs = ...
      assert(secs >= 1 and secs <= 60, "reel out of range: " .. tostring(secs))
    end
  end,
  engine_name = function() end,
  os_capture = function() return "" end,
  storage_get = function() end,
  storage_set = function() end,
  nb = function() end,
}
dofile("tools/norns-web/lib/norns.lua")
norns_web.boot("pollen", "pollen.lua", "./")
assert(engine.name == "Pollen", "engine.name not set")

local now = 0
local function run(sec)
  for _ = 1, math.floor(sec * 60 + 0.5) do
    now = now + 1 / 60
    if norns_web.tick(now) then frames = frames + 1 end
  end
end
local function turn(n, d, times) for _ = 1, times or 1 do norns_web.enc(n, d) end end
local function press(n) norns_web.key(n, 1); norns_web.key(n, 0) end
local function ok(label) print(("ok  %-36s frames: %d"):format(label, frames)) end

-- params: every group holds exactly the params it declares
do
  local P = params.params
  for i, p in ipairs(P) do
    if p.kind == "group" then
      local n = 0
      for _, q in ipairs(P) do if q.group == p.name then n = n + 1 end end
      assert(n == p.count, ("group %s declares %d params but has %d"):format(p.name, p.count, n))
    elseif p.kind ~= "separator" then
      assert(p.group, "param outside any group: " .. tostring(p.id))
    end
  end
end

run(3); ok("default bloom")

-- every part: both macros to both ends, the gesture twice, every variety
for part = 1, 5 do
  turn(1, -5); turn(1, 1, part - 1)
  turn(2, 1, 120); turn(3, 1, 120); run(1)
  turn(2, -1, 120); turn(3, -1, 120); run(1)
  turn(2, 1, 50); turn(3, 1, 50)
  press(3); run(1.6)
  press(3); run(0.5)
  norns_web.key(2, 1)
  turn(2, 1, 8); run(0.5)
  turn(2, -1, 8)
  norns_web.key(2, 0)
  ok("part " .. part)
end

-- hold K1: the peek, and K3 does nothing while it's held
local before = params:get("catch_press")
turn(1, -5)
norns_web.key(1, 1); run(0.5); press(3); run(0.5); norns_web.key(1, 0)
assert(params:get("catch_press") == before, "K3 under a held K1 pressed the reel")
ok("peek")

-- every reel length, then a long run
for i = 1, 5 do params:set("catch_reel", i); run(0.5) end
params:set("catch_reel", 3)
params:set("clear", 1)
run(20); ok("20 s more")

-- what reached the engine: every key a control of one of the engine's SynthDefs, and the
-- browser's engine knows it too
local sc = io.open("lib/Engine_Pollen.sc"):read("a")
local js = io.open("lib/Engine_Pollen.js"):read("a")
local controls = {}
for args in sc:gmatch("SynthDef%(\\pollen_%w+, { |(.-)|") do
  for name in args:gmatch("([%a_]+)%s*=") do controls[name] = true end
end
for k, s in pairs(sets) do
  assert(controls[k], "engine.set('" .. k .. "'): no SynthDef control by that name")
  assert(js:find('"' .. k .. '"', 1, true) or js:find("%f[%w_]" .. k .. "%s*:"),
    "engine.set('" .. k .. "'): Engine_Pollen.js doesn't handle it")
end
local function range(k, lo, hi)
  local s = assert(sets[k], "never sent: " .. k)
  assert(s.min >= lo and s.max <= hi, ("%s went %g..%g, outside %g..%g"):format(k, s.min, s.max, lo, hi))
end
range("density", 0.1, 200); range("size", 0.005, 4); range("mix", 0, 1); range("fb", 0, 0.95)
range("cutoff", 20, 20000); range("position", 0, 60); range("reverse", 0, 1)
range("ftype", 0, 3); range("media", 0, 3); range("env", 0, 2); range("static", 0, 1)
-- one engine.reel per change, none for the 15 s the engine starts with: the catch part's
-- variety walk (15 -> 60: 2, 60 -> 4: 4) and the loop over every length (4, then back to 15: 5)
assert(calls.reel == 11, "reel: expected 11 changes, got " .. tostring(calls.reel))
assert(calls.clear == 1, "clear the reel didn't reach the engine")

local keys = {}
for k in pairs(sets) do keys[#keys + 1] = k end
table.sort(keys)
print(("engine: %d keys set (%s)"):format(#keys, table.concat(keys, " ")))
print(("%d frames, %d error(s)"):format(frames, #errors))
if #errors > 0 or frames == 0 then os.exit(1) end
