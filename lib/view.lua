-- The view: where the radio is, and what the reel is doing with it. Stateful: include it only
-- from pollen.lua.
--
-- On the left, the globe: every station a dot (so the dots draw the places people broadcast
-- from), a faint graticule, and the station playing at the middle, sending out radio waves as
-- loud as it is. The wind's last moves are its trail; while tuning, the station being tried
-- blinks at the end of a dotted path and the globe turns toward it.
-- On the right, the tape: the reel laid flat, its waveform, the write head sweeping it, the
-- window the grains are read from under it, and the grains themselves leaving it, up when
-- they play forwards and down when backwards, faster the higher they're pitched.
-- What the station sends flows from it on the globe to the head.
--
-- V.update(dt, st) moves things; V.draw(st) draws them. st is what the sound and the radio are
-- doing, in the script's terms (see look() in pollen.lua): reel, head, filled, frozen, density,
-- size, rate, reverse, age, pos_spread, fb, space, hazed, color, drive, media, static, wave
-- (the tape: a level 0..1 for each of #wave segments of the reel), amp (what's being written
-- now), stations, here (the station playing), seeking (the one being tried), trail (the last
-- stations, oldest first).

local V = {}

local rad, deg = math.rad, math.deg
local sin, cos, asin, atan, sqrt = math.sin, math.cos, math.asin, math.atan, math.sqrt
local floor, min, max, random = math.floor, math.min, math.max, math.random
local TAU = math.pi * 2

-- the globe
local GX, GY, GR = 28, 31, 25
-- the tape: one column for each segment of the wave, from X0
local X0, TY, HMAX = 62, 31, 9
local MAX_GRAINS, MAX_FLOW = 40, 16

local t = 0
local seek, seek_t = nil, 0 -- the station being tried, and for how long
local grains, flow = {}, {}
local spawn_acc, flow_acc = 0, 0
local haze = {} -- fixed seeds for the haze, so a held haze stays put
for i = 1, 60 do haze[i] = { x = random(), y = random(), tw = random() * TAU } end

-- ---------- pixels, gathered per level and drawn with one fill per level ----------

local dots, rects = {}, {}
for l = 0, 15 do dots[l], rects[l] = {}, {} end
local function px(x, y, l)
  l = floor(l + 0.5)
  if l < 1 or x < 0 or x >= 128 or y < 0 or y >= 64 then return end
  local b = dots[min(15, l)]
  b[#b + 1] = floor(x)
  b[#b + 1] = floor(y)
end
local function rect(x, y, w, h, l)
  l = floor(l + 0.5)
  if l < 1 then return end
  local b = rects[min(15, l)]
  b[#b + 1] = floor(x); b[#b + 1] = floor(y); b[#b + 1] = w; b[#b + 1] = h
end
local function flush()
  for l = 1, 15 do
    local b = rects[l]
    if #b > 0 then
      screen.level(l)
      for i = 1, #b, 4 do screen.rect(b[i], b[i + 1], b[i + 2], b[i + 3]) end
      screen.fill()
      rects[l] = {}
    end
  end
  for l = 1, 15 do
    local b = dots[l]
    if #b > 0 then
      screen.level(l)
      for i = 1, #b, 2 do screen.pixel(b[i], b[i + 1]) end
      screen.fill()
      dots[l] = {}
    end
  end
end

-- ---------- the globe ----------

-- where it faces (degrees), and where it's turning to
local lat0, lon0 = 20, 0
local function wrap(a) return (a + 540) % 360 - 180 end

-- a place on the screen, and how far it faces us (z > 0: this side of the globe)
local function project(lat, lon)
  local p, l = rad(lat), rad(lon - lon0)
  local p0 = rad(lat0)
  local x = cos(p) * sin(l)
  local y = cos(p0) * sin(p) - sin(p0) * cos(p) * cos(l)
  local z = sin(p0) * sin(p) + cos(p0) * cos(p) * cos(l)
  return GX + x * GR, GY - y * GR, z
end

-- the stations (and the graticule) as pixels, worked out again only when the globe turns
local cache = { list = nil, lat = nil, lon = nil, px = {} }
local pre = {} -- each station's sines and cosines
local grid = {}
for lon = -180, 135, 45 do for lat = -80, 80, 8 do grid[#grid + 1] = { lat, lon } end end
for _, lat in ipairs({ -45, 0, 45 }) do for lon = -180, 175, 6 do grid[#grid + 1] = { lat, lon } end end

local function globe_pixels(list)
  if cache.list == list and cache.lat == lat0 and cache.lon == lon0 then return cache.px end
  if cache.list ~= list then
    pre = {}
    for i, s in ipairs(list or {}) do
      local p, l = rad(s.lat), rad(s.lon)
      pre[i] = { sin(p), cos(p), sin(l), cos(l) }
    end
  end
  local p0, l0 = rad(lat0), rad(lon0)
  local sp0, cp0, sl0, cl0 = sin(p0), cos(p0), sin(l0), cos(l0)
  local count, out = {}, {}
  for _, s in ipairs(pre) do
    local cd = s[4] * cl0 + s[3] * sl0 -- cos(lon - lon0)
    local z = sp0 * s[1] + cp0 * s[2] * cd
    if z > 0 then
      local sd = s[3] * cl0 - s[4] * sl0
      local x = floor(GX + s[2] * sd * GR)
      local y = floor(GY - (cp0 * s[1] - sp0 * s[2] * cd) * GR)
      local k = y * 128 + x
      local c = count[k]
      if not c then c = { x, y, 0, z }; count[k] = c; out[#out + 1] = c end
      c[3] = c[3] + 1
      if z > c[4] then c[4] = z end
    end
  end
  -- a dot is brighter the more stations share it and the nearer it faces us
  for _, c in ipairs(out) do c[3] = min(6, 1 + 2 * c[4] + 0.6 * (c[3] - 1)) end
  for _, g in ipairs(grid) do
    local x, y, z = project(g[1], g[2])
    if z > 0.05 then out[#out + 1] = { floor(x), floor(y), 1 } end
  end
  cache.list, cache.lat, cache.lon, cache.px = list, lat0, lon0, out
  return out
end

local rim = {}
for i = 0, 159 do local a = TAU * i / 160; rim[#rim + 1] = { GX + cos(a) * (GR + 0.5), GY + sin(a) * (GR + 0.5) } end

-- the great circle from a to b, as n + 1 points ({ lat, lon })
local function path(a, b, n)
  local function vec(s)
    local p, l = rad(s.lat), rad(s.lon)
    return cos(p) * cos(l), cos(p) * sin(l), sin(p)
  end
  local ax, ay, az = vec(a)
  local bx, by, bz = vec(b)
  local w = math.acos(max(-1, min(1, ax * bx + ay * by + az * bz)))
  local pts = {}
  for i = 0, n do
    local f = i / n
    local ka, kb
    if w < 1e-6 then ka, kb = 1 - f, f else ka, kb = sin((1 - f) * w) / sin(w), sin(f * w) / sin(w) end
    local x, y, z = ka * ax + kb * bx, ka * ay + kb * by, ka * az + kb * bz
    pts[#pts + 1] = { lat = deg(asin(max(-1, min(1, z / sqrt(x * x + y * y + z * z))))), lon = deg(atan(y, x)) }
  end
  return pts
end

local function draw_path(a, b, l, upto)
  local pts = path(a, b, 40)
  for i = 1, floor(#pts * (upto or 1)) do
    if i % 2 == 1 then
      local x, y, z = project(pts[i].lat, pts[i].lon)
      if z > 0 then px(x, y, l) end
    end
  end
end

-- radio waves from a point: rings going out, as bright as the station is loud
local function waves(x, y, loud)
  for k = 0, 1 do
    local ph = (t * 0.7 + k * 0.5) % 1
    local r = 2 + 9 * ph
    local l = (1 - ph) * (2 + 10 * loud)
    if l >= 1 then
      local n = floor(r * 5)
      for i = 0, n - 1 do
        local a = TAU * i / n
        px(x + cos(a) * r, y + sin(a) * r, l)
      end
    end
  end
end

local function draw_globe(st)
  for _, p in ipairs(rim) do px(p[1], p[2], 2) end
  for _, c in ipairs(globe_pixels(st.stations)) do px(c[1], c[2], c[3]) end
  local trail = st.trail or {}
  for i = 2, #trail do draw_path(trail[i - 1], trail[i], 1 + 4 * (i - 1) / max(1, #trail - 1)) end
  local here = st.here
  if here then
    local x, y, z = project(here.lat, here.lon)
    if z > 0 then
      if not st.seeking then waves(x, y, st.loud) end
      rect(x - 1, y - 1, 3, 3, st.seeking and 8 or 15)
    end
  end
  if st.seeking then
    local s = st.seeking
    if here then draw_path(here, s, 6, min(1, seek_t * 1.5)) end
    local x, y, z = project(s.lat, s.lon)
    if z > 0 and (t * 4) % 1 < 0.6 then rect(x - 1, y - 1, 3, 3, 12) end
  end
end

-- ---------- the tape ----------

local function loudest(wave)
  local m = 0.03
  for i = 1, #wave do if wave[i] > m then m = wave[i] end end
  return m
end
local function level_at(wave, frac)
  local n = #wave
  return (wave[floor((frac % 1) * n) % n + 1] or 0) / loudest(wave)
end
-- the half-height of each column: broadcasts are compressed, so the waveform is stretched
-- between its quietest and its loudest (like a sampler zooming in), or it'd be a solid bar
local heights = {}
local function shape(st)
  local n, filled = #st.wave, st.filled / st.reel
  local lo, hi = math.huge, 0.03
  for i = 1, n do
    local w = st.wave[i]
    if (filled >= 1 or (i - 0.5) / n <= filled) and w > 0 then lo, hi = min(lo, w), max(hi, w) end
  end
  if lo == math.huge then lo = 0 end
  lo = lo * 0.7
  for i = 1, n do
    local w = st.wave[i]
    heights[i] = w <= 0 and 0 or floor(1 + (HMAX - 1) * max(0, (w - lo) / max(1e-6, hi - lo)) ^ 1.2 + 0.5)
  end
end
local function tape_x(frac, n) return X0 + (frac % 1) * n end

local function draw_tape(st)
  -- media: tape wobbles it, vintage digital snaps it to a coarse grid
  local ox, oy, snap = 0, 0, nil
  if st.media == 3 then ox = sin(t * 1.3) * 0.7 end
  if st.media == 4 then ox, oy = sin(t * 1.1) * 1.4, sin(t * 0.7) * 0.6 end
  if st.media == 2 then snap = 2 end
  local function P(x, y, l)
    if snap then x, y = floor(x / snap) * snap, floor(y / snap) * snap end
    px(x + ox, y + oy, l)
  end

  -- the haze of the reverb, over the tape
  for i = 1, floor(st.space * #haze) do
    local h = haze[i]
    local x = 60 + ((h.x + (st.hazed and 0 or t * 0.01)) % 1) * 66
    local y = 12 + h.y * 38
    P(x, y, 1 + (sin(h.tw + (st.hazed and 0 or t * 2)) + 1) * 1.1)
  end

  -- the waveform: a column for each segment, as tall as what was written there was loud.
  -- The newest is brightest, just behind the head; older sound stays lit, dimmer; what isn't
  -- caught yet is a faint dotted line. Pressed, it's all evenly lit and the head stops.
  local n = #st.wave
  local headf, filled = st.head / st.reel, st.filled / st.reel
  for i = 0, n - 1 do
    local f = (i + 0.5) / n
    local x = X0 + i + ox
    if filled >= 1 or f <= filled then
      local l = st.frozen and 8 or 4 + 11 * max(0, 1 - ((headf - f) % 1) * 4)
      local h = heights[i + 1]
      if h < 1 then P(x, TY, l * 0.6) else rect(x, TY - h + oy, 1, 2 * h + 1, l) end
    elseif i % 2 == 0 then
      P(x, TY, 1)
    end
  end
  -- the head
  local hx = tape_x(headf, n) + ox
  rect(hx, TY - HMAX - 3, 1, 2 * HMAX + 7, st.frozen and 9 or 15)
  -- the window the grains are read from: a bracket under the tape, behind the head by memory
  local y = TY + HMAX + 4
  local to = headf - st.age / st.reel
  local w = max(2, st.pos_spread * n)
  for k = 0, floor(w) do P(tape_x(to - k / n, n), y, 7) end
  P(tape_x(to, n), y - 1, 7)
  P(tape_x(to - w / n, n), y - 1, 7)

  -- the grains; the filter dims them as it closes, drive shakes them
  local dim = 1
  if st.color < 0.45 then dim = 0.35 + 0.65 * st.color / 0.45 end
  local j = st.drive * 1.5
  for _, g in ipairs(grains) do
    local env = sin(math.pi * max(0, g.life) / g.max)
    local x = g.x + (j > 0 and (random() - 0.5) * j or 0)
    local gy = g.y + (j > 0 and (random() - 0.5) * j or 0)
    P(x, gy - g.v * 0.08, (1 + 4 * env) * dim * g.bright)
    for k = 0, g.len - 1 do P(x - floor(g.len / 2) + k, gy, (4 + 11 * env) * dim * g.bright) end
  end
end

-- ---------- moving ----------

function V.reset() grains, flow, spawn_acc = {}, {}, 0 end

local function head_point(st) return tape_x(st.head / st.reel, #st.wave), TY - HMAX - 3 end

function V.update(dt, st)
  t = t + dt
  st.loud = min(1, (st.amp or 0) / loudest(st.wave))
  shape(st)
  if st.seeking ~= seek then seek, seek_t = st.seeking, 0 else seek_t = seek_t + dt end
  -- the globe turns to the station (or the one being tried); with none yet, it just turns
  local aim = st.seeking or st.here
  if aim then
    local k = min(1, dt * 2.5)
    lon0 = lon0 + wrap(aim.lon - lon0) * k
    lat0 = lat0 + (aim.lat * 0.7 - lat0) * k
    if math.abs(wrap(aim.lon - lon0)) < 0.05 and math.abs(aim.lat * 0.7 - lat0) < 0.05 then
      lon0, lat0 = aim.lon, aim.lat * 0.7
    end
  else
    lon0 = wrap(lon0 + dt * 12)
  end

  -- new grains, as many as the engine plays (a few less when dense: it's a picture, not a meter)
  local n = #st.wave
  spawn_acc = spawn_acc + min(st.density, 30) * dt
  while spawn_acc >= 1 do
    spawn_acc = spawn_acc - 1
    local from = st.head / st.reel - (st.age + st.pos_spread * st.reel * random()) / st.reel
    local loud = level_at(st.wave, from)
    -- silence on the tape throws none
    if #grains < MAX_GRAINS and st.filled > 0 and loud > 0.05 then
      local dir = random() < st.reverse and 1 or -1 -- backwards: down
      local life = max(0.6, min(2.5, st.size * 2))
      local v = (4 + 8 * sqrt(st.rate)) * dir
      local len = 1 + floor(3 * max(0, min(1, math.log(st.size / 0.02) / math.log(100))) + 0.5)
      local h = heights[floor((from % 1) * n) % n + 1] or 0
      grains[#grains + 1] = { x = tape_x(from, n), y = TY + (h + 1) * dir, v = v, v0 = v, vx = (random() - 0.5) * 3,
        life = life, max = life, len = len, bright = 0.3 + 0.7 * min(1, loud) }
    end
  end
  -- grains drift off the tape; cross-pollination turns them back to it
  for i = #grains, 1, -1 do
    local g = grains[i]
    g.life = g.life - dt
    g.v = g.v - g.v0 * st.fb * 2.2 * dt / g.max
    g.y = g.y + g.v * dt
    g.x = g.x + g.vx * dt
    local back = st.fb > 0.2 and g.v * g.v0 < 0 and math.abs(g.y - TY) <= HMAX
    if g.life <= 0 or g.y < 10 or g.y > 53 or back then table.remove(grains, i) end
  end

  -- what the station sends, flowing from it to the head (not while the reel is pressed)
  local here = st.here
  if here and not st.frozen and not st.seeking then
    flow_acc = flow_acc + 10 * st.loud * dt
    while flow_acc >= 1 do
      flow_acc = flow_acc - 1
      local x, y, z = project(here.lat, here.lon)
      if z > 0 and #flow < MAX_FLOW then flow[#flow + 1] = { x = x, y = y, f = 0 } end
    end
  end
  local hx, hy = head_point(st)
  for i = #flow, 1, -1 do
    local p = flow[i]
    p.f = p.f + dt / 0.8
    p.tx, p.ty = hx, hy
    if p.f >= 1 then table.remove(flow, i) end
  end
end

function V.draw(st)
  st.loud = min(1, (st.amp or 0) / loudest(st.wave))
  shape(st)
  draw_globe(st)
  for _, p in ipairs(flow) do
    local f = p.f * p.f
    px(p.x + (p.tx - p.x) * f, p.y + (p.ty - p.y) * f, 2 + 4 * sin(math.pi * p.f))
  end
  draw_tape(st)
  -- the static between stations: snow over everything
  for _ = 1, floor(st.static * 260) do px(random(0, 127), random(0, 63), random(1, 6)) end
  flush()
end

return V
