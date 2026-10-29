-- Headless smoke test: pollen on norns-web's norns API (tools/norns-web/lib/norns.lua, the
-- same Lua the browser runs), with the page's side stubbed to record engine commands.
-- Plays every part, macro, gesture and variety, and checks what reaches the engine.
--
--   lua test/smoke.lua        (Lua 5.3+, from the repo root)

math.randomseed(1)
local errors, calls, sets, frames = {}, {}, {}, 0
local json = dofile("lib/json.lua")

-- a pretend radio-browser: 40 made-up stations around the globe (no real data in the repo)
local records = {}
for i = 1, 40 do
  records[i] = { stationuuid = "st-" .. i, name = "Test FM " .. i, state = "Place " .. i, country = "Testland",
    geo_lat = -60 + (i * 37) % 120, geo_long = -180 + (i * 53) % 360,
    url_resolved = "https://stream.example/" .. i, url = "", bitrate = 128, codec = "MP3", hls = 0 }
end
records[41] = { stationuuid = "hls", name = "HLS FM", geo_lat = 1, geo_long = 1, url_resolved = "https://x/hls.m3u8", hls = 1 }
records[42] = { stationuuid = "nowhere", name = "No Place FM", url_resolved = "https://x/n" }
local STATIONS_JSON = json.encode(records)

-- a pretend mpv on the other end of socat: which URL each player has, at what volume. The
-- first station asked for never plays (a dead stream).
local mpv = { a = {}, b = {} }
local loads, curls, killed, first = {}, 0, 0, true
local function fake_cmd(cmd)
  if cmd:match("^curl .*radio%-browser") then curls = curls + 1; return STATIONS_JSON end
  if cmd:match("^nohup mpv") then return "" end
  if cmd:match("^pkill") then killed = killed + 1; return "" end
  local line, name = cmd:match("^echo '(.*)' | socat %- /tmp/pollen_(%a)%.sock")
  assert(line, "a command pollen shouldn't run: " .. cmd)
  local c = json.decode(line).command
  local p = mpv[name]
  if c[1] == "loadfile" then
    p.url, p.silent, first = c[2], first, false
    loads[#loads + 1] = c[2]
  elseif c[1] == "get_property" and c[2] == "playback-time" then
    if p.silent or not p.url then return '{"error":"property unavailable"}\n' end
    return '{"data":2.0,"error":"success"}\n'
  elseif c[1] == "set_property" and c[2] == "volume" then
    p.volume = c[3]
  elseif c[1] == "stop" then
    p.url = nil
  end
  return '{"request_id":0,"error":"success"}\n'
end
-- the station that's audible: the player at full volume
local function playing()
  for _, n in ipairs({ "a", "b" }) do if mpv[n].url and (mpv[n].volume or 0) >= 100 then return mpv[n].url end end
end
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
  os_capture = function(cmd) return cmd:match("^command %-v (%a+)") and "/usr/bin/x" or "" end,
  system_cmd = function(id, cmd) norns_web.system_cmd_done(id, fake_cmd(cmd)) end,
  make_dir = function(path) os.execute("mkdir -p '" .. path .. "'") end,
  storage_get = function() end,
  storage_set = function() end,
  nb = function() end,
  -- the engine's polls: a reel level that comes and goes (music with gaps), the head as Lua has it
  poll = function(name) if name == "amp_reel" then return (math.sin(os.clock() * 50) + 1) * 0.2 end end,
}
dofile("tools/norns-web/lib/norns.lua")
-- the station cache goes to a scratch folder, not the real data dir
local scratch = os.tmpname()
os.remove(scratch)
_path.data = scratch .. ".d/"
norns_web.boot("pollen", "pollen.lua", "./")
assert(engine.name == "Pollen", "engine.name not set")
params:set("wind_pace", 0) -- only by hand, until the pace is tested

local now = 0
local function run(sec)
  for _ = 1, math.floor(sec * 60 + 0.5) do
    now = now + 1 / 60
    if norns_web.tick(now) then frames = frames + 1 end
  end
end
local function turn(n, d, times) for _ = 1, times or 1 do norns_web.enc(n, d) end end
local function press(n) norns_web.key(n, 1); norns_web.key(n, 0) end
local W_KINDS = dofile("lib/walker.lua").KINDS
-- the wind's geometry, against known distances
do
  local Wk = dofile("lib/walker.lua")
  local london, paris = { lat = 51.5074, lon = -0.1278 }, { lat = 48.8566, lon = 2.3522 }
  local d = Wk.distance(london, paris)
  assert(math.abs(d - 344) < 3, "London-Paris should be ~344 km, got " .. d)
  local b = Wk.bearing(london, paris)
  assert(b > 140 and b < 160, "London to Paris heads south-east, got " .. b)
  local p = Wk.travel(london, b, d)
  assert(Wk.distance(p, paris) < 1, "travel() along the bearing should land in Paris")
  local a = Wk.antipode({ lat = 10, lon = 170 })
  assert(a.lat == -10 and math.abs(a.lon - -10) < 1e-9, "antipode of 10N 170E is 10S 10W")
end
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

-- the radio: stations fetched once (HLS and placeless ones left out), the first one silent,
-- so it's marked dead and the wind moves on; then a station plays
run(14)
assert(curls == 1, "expected one fetch of the stations, got " .. curls)
assert(#loads >= 2, "the silent first station didn't make the wind move on")
local here = playing()
assert(here and here ~= loads[1], "no station playing after the silent one")
for _, u in ipairs(loads) do assert(not u:match("m3u8") and u ~= "https://x/n", "loaded a station it should skip: " .. u) end
ok("radio: a dead station, then " .. here)

-- K2 drifts on; hold K1 + K2 goes back
press(2); run(6)
local there = playing()
assert(there and there ~= here, "K2 didn't move to another station")
norns_web.key(1, 1); press(2); norns_web.key(1, 0); run(6)
assert(playing() == here, "K1 + K2 didn't go back: " .. tostring(playing()))
ok("radio: drift and back")

-- the pace: every 4 beats (2 s at 120 bpm), the wind moves on by itself
params:set("wind_pace", 1)
local before_auto = #loads
run(12)
assert(#loads >= before_auto + 2, "the pace didn't move the wind")
params:set("wind_pace", 0)
ok("radio: the pace moves it")

-- every wind
for k = 1, #W_KINDS do params:set("wind_kind", k); press(2); run(5) end
ok("radio: every wind")

-- the cache: a fresh start reads it instead of fetching
assert(io.open(_path.data .. "pollen/stations_radiobrowser.lua"), "no station cache written")

-- every part: both macros to both ends, the gesture twice, every variety
for part = 1, 6 do
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

-- cleanup stops the players
cleanup()
assert(killed >= 2, "cleanup didn't stop mpv") -- once at start (leftovers), once now
os.execute("rm -rf '" .. _path.data .. "'")

local keys = {}
for k in pairs(sets) do keys[#keys + 1] = k end
table.sort(keys)
print(("engine: %d keys set (%s)"):format(#keys, table.concat(keys, " ")))
print(("%d frames, %d error(s)"):format(frames, #errors))
if #errors > 0 or frames == 0 then os.exit(1) end
