-- The bloom: a close-up of the flower. The reel is a ring of tape (a circular buffer drawn as
-- a circle, which is also a flower head and a radio dial): the waveform of what it caught, bent
-- around, brightest just behind the write head that sweeps it. Grains leave it as pollen, from
-- where they're read, as bright as the tape is loud there. Stateful: include it only from
-- pollen.lua.
--
-- B.update(dt, st) moves things; B.draw(st) draws them. st is what the sound is doing,
-- in the script's terms (see look() in pollen.lua): reel, head, filled, frozen, density,
-- size, rate, reverse, age, pos_spread, fb, space, hazed, color, drive, media, static, and
-- wave (the tape: a level 0..1 for each of #wave segments of the reel, from its start).

local B = {}

local CX, CY, R = 64, 32, 20
local TAU = math.pi * 2
local MAX_POLLEN = 48

local pollen = {}
local spawn_acc, t = 0, 0
local haze = {} -- fixed seeds for the haze, so a held haze stays put
for i = 1, 60 do haze[i] = { a = math.random() * TAU, r = math.random(), tw = math.random() * TAU } end

-- pixels are gathered per level and drawn with one fill per level
local buckets = {}
for l = 0, 15 do buckets[l] = {} end
local function px(x, y, l)
  l = math.floor(l + 0.5)
  if l < 1 or x < 0 or x > 127 or y < 0 or y > 63 then return end
  if l > 15 then l = 15 end
  local b = buckets[l]
  b[#b + 1] = math.floor(x + 0.5)
  b[#b + 1] = math.floor(y + 0.5)
end
-- and strokes, per level too (the tape's waveform: one short line per segment)
local strokes = {}
for l = 0, 15 do strokes[l] = {} end
local function ln(x1, y1, x2, y2, l)
  l = math.floor(l + 0.5)
  if l < 1 then return end
  if l > 15 then l = 15 end
  local b = strokes[l]
  b[#b + 1] = x1; b[#b + 1] = y1; b[#b + 1] = x2; b[#b + 1] = y2
end
local function flush()
  for l = 1, 15 do
    local b = strokes[l]
    if #b > 0 then
      screen.level(l)
      for i = 1, #b, 4 do
        screen.move(b[i], b[i + 1])
        screen.line(b[i + 2], b[i + 3])
      end
      screen.stroke()
      strokes[l] = {}
    end
  end
  for l = 1, 15 do
    local b = buckets[l]
    if #b > 0 then
      screen.level(l)
      for i = 1, #b, 2 do screen.pixel(b[i], b[i + 1]) end
      screen.fill()
      buckets[l] = {}
    end
  end
end

-- the tape's level at a point of the reel (0..1 of it), against its loudest: like a waveform
-- display, the tape shows its shape whether the station is loud or quiet
local function loudest(wave)
  local m = 0.03
  for i = 1, #wave do if wave[i] > m then m = wave[i] end end
  return m
end
local function level_at(wave, frac)
  local n = #wave
  return (wave[math.floor((frac % 1) * n) % n + 1] or 0) / loudest(wave)
end

-- the angle of a moment in the reel: the top of the ring is its start, clockwise
local function angle(frac) return -math.pi / 2 + TAU * frac end

function B.reset() pollen, spawn_acc = {}, 0 end

function B.update(dt, st)
  t = t + dt
  -- new pollen, as many as the grains (a few less when dense: it's a picture, not a meter)
  spawn_acc = spawn_acc + math.min(st.density, 30) * dt
  while spawn_acc >= 1 do
    spawn_acc = spawn_acc - 1
    local back = (st.age + st.pos_spread * st.reel * math.random()) / st.reel
    local from = st.head / st.reel - back
    local loud = level_at(st.wave, from)
    -- silence on the tape throws no pollen
    if #pollen < MAX_POLLEN and st.filled > 0 and loud > 0.05 then
      local dir = math.random() < st.reverse and -1 or 1
      local life = math.max(0.6, math.min(2.5, st.size * 2))
      local speed = (12 + 14 * st.rate) * dir
      pollen[#pollen + 1] = { a = angle(from), r = R, v = speed, v0 = speed, life = life, max = life,
        spin = (math.random() - 0.5) * 0.6, bright = 0.3 + 0.7 * math.min(1, loud) }
    end
  end
  -- pollen drifts out (or in, backwards); cross-pollination turns it back to the ring
  for i = #pollen, 1, -1 do
    local p = pollen[i]
    p.life = p.life - dt
    p.v = p.v - p.v0 * st.fb * 2.2 * dt / p.max
    p.r = p.r + p.v * dt
    p.a = p.a + p.spin * dt
    if p.life <= 0 or p.r < 3 or (st.fb > 0.2 and p.v * p.v0 < 0 and p.r <= R) then table.remove(pollen, i) end
  end
end

function B.draw(st)
  -- media: tape wobbles the picture, vintage digital snaps it to a coarse grid
  local ox, oy, snap = 0, 0, nil
  if st.media == 3 then ox = math.sin(t * 1.3) * 0.7 end
  if st.media == 4 then ox, oy = math.sin(t * 1.1) * 1.4, math.sin(t * 0.7) * 0.6 end
  if st.media == 2 then snap = 2 end
  local function P(x, y, l)
    if snap then x, y = math.floor(x / snap) * snap, math.floor(y / snap) * snap end
    px(x + ox, y + oy, l)
  end
  local cx, cy = CX, CY

  -- the haze of the reverb, around the bloom
  local n = math.floor(st.space * #haze)
  for i = 1, n do
    local h = haze[i]
    local a = h.a + (st.hazed and 0 or t * 0.05)
    local r = R + 4 + h.r * (4 + st.space * 14)
    local l = 1 + (math.sin(h.tw + (st.hazed and 0 or t * 2)) + 1) * 1.2
    P(cx + math.cos(a) * r, cy + math.sin(a) * r, l)
  end

  local function L(x1, y1, x2, y2, l)
    if snap then
      x1, y1 = math.floor(x1 / snap) * snap, math.floor(y1 / snap) * snap
      x2, y2 = math.floor(x2 / snap) * snap, math.floor(y2 / snap) * snap
    end
    ln(x1 + ox, y1 + oy, x2 + ox, y2 + oy, l)
  end

  -- the tape: each segment of the reel a short column across the ring, as long as what was
  -- written there was loud. The newest is brightest, just behind the head; older sound stays
  -- lit, dimmer; what's not caught yet is a faint dotted line. Pressed, it's all evenly bright
  -- and the sweep stops.
  local headf = st.head / st.reel
  local filled = st.filled / st.reel
  local n, top = #st.wave, loudest(st.wave)
  for i = 0, n - 1 do
    local f = (i + 0.5) / n
    local a = angle(f)
    local ca, sa = math.cos(a), math.sin(a)
    if filled >= 1 or f <= filled then
      local h = 1 + 9 * (st.wave[i + 1] / top) ^ 0.8
      local l
      if st.frozen then
        l = 8
      else
        l = 4 + 11 * math.max(0, 1 - ((headf - f) % 1) * 4)
      end
      if h < 1.6 then
        P(cx + ca * R, cy + sa * R, l * 0.6)
      else
        -- a column of pixels across the ring (the same at every angle, unlike a line)
        for r = R - h * 0.45, R + h * 0.55, 1 do P(cx + ca * r, cy + sa * r, l) end
      end
    elseif i % 2 == 0 then
      P(cx + ca * R, cy + sa * R, 1)
    end
  end
  -- the head: a tick across the tape
  local ha = angle(headf)
  L(cx + math.cos(ha) * (R - 6), cy + math.sin(ha) * (R - 6), cx + math.cos(ha) * (R + 7), cy + math.sin(ha) * (R + 7),
    st.frozen and 9 or 15)
  -- where the grains are read from: a short arc inside the tape
  local from = headf - st.age / st.reel
  local width = math.max(0.01, st.pos_spread)
  for k = 0, 6 do
    local a = angle(from - width * k / 6)
    P(cx + math.cos(a) * (R - 8), cy + math.sin(a) * (R - 8), 7 - k * 0.7)
  end

  -- the pollen itself; the filter dims it as it closes, drive shakes it
  local dim = 1
  if st.color < 0.45 then dim = 0.35 + 0.65 * st.color / 0.45 end
  for _, p in ipairs(pollen) do
    local j = st.drive * 1.5
    local x = cx + math.cos(p.a) * p.r + (j > 0 and (math.random() - 0.5) * j or 0)
    local y = cy + math.sin(p.a) * p.r + (j > 0 and (math.random() - 0.5) * j or 0)
    local env = math.sin(math.pi * math.max(0, p.life) / p.max)
    -- a short trail back along its path, dimmer
    local tr = p.r - p.v * 0.08
    P(cx + math.cos(p.a) * tr, cy + math.sin(p.a) * tr, (1 + 5 * env) * dim * p.bright)
    P(x, y, (4 + 11 * env) * dim * p.bright)
  end

  -- the heart of the flower: a pollen grain, spikes turning with the density
  local spin = t * (0.3 + st.density * 0.05)
  for k = 0, 7 do
    local a = spin + k * TAU / 8
    P(cx + math.cos(a) * 5, cy + math.sin(a) * 5, 8)
  end
  for k = 0, 11 do
    local a = k * TAU / 12
    P(cx + math.cos(a) * 3, cy + math.sin(a) * 3, 12)
  end
  P(cx, cy, 15)

  -- the static between stations: snow over everything
  for _ = 1, math.floor(st.static * 260) do
    px(math.random(0, 127), math.random(0, 63), math.random(1, 6))
  end
  flush()
end

return B
