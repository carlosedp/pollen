-- pollen
-- the world's radio, carried
-- on the wind, scattered
-- as grains
--
-- E1 choose a part
-- E2 E3 shape it
-- K3 its gesture
--   (on the wind: drift)
-- hold K2 + E2: its variety
-- hold K1: peek
-- hold K1 + K2: back a station
--
-- needs mpv and socat for the
-- radio; without them, it
-- plays the norns input
--
-- by Voltage Foundry Modular
-- vfmod.com

-- Copyright (C) 2026 Voltage Foundry Modular. Free software under the GNU GPL v3.0
-- (see LICENSE).

engine.name = "Pollen"

local S = include("lib/sound")
local view = include("lib/view")
local radio = include("lib/radio")
local W = include("lib/walker")

local FPS = 15

-- the parts of pollen, each with two macros (E2, E3), a gesture (K3) and a variety
-- (hold K2 + E2). A gesture that holds a state keeps it in a param, so presets save it.
local PARTS = {
  { id = "wind", macros = { "pace", "reach" }, defaults = { 0, 0.3 },
    gesture = "drift", variety = "wind_kind" },
  { id = "catch", macros = { "position", "feedback" }, defaults = { 0.3, 0.2 },
    gesture = "press", hold = "catch_press", variety = "catch_reel" },
  { id = "scatter", macros = { "density", "size" }, defaults = { 0.45, 0.65 },
    gesture = "burst", variety = "scatter_envelope" },
  { id = "tint", macros = { "pitch", "spread" }, defaults = { 0.5, 0.15 },
    gesture = "flip", hold = "tint_flip", variety = "tint_scale" },
  { id = "tone", macros = { "color", "drive" }, defaults = { 0.5, 0.1 },
    gesture = "fade", variety = "tone_media" },
  { id = "air", macros = { "space", "mix" }, defaults = { 0.35, 1 },
    gesture = "haze", hold = "air_haze" },
}

local part = 1
local held = { false, false, false } -- K1, K2, K3
local burst, fading = 0, 0 -- the gestures in flight (fading: 1 down to 0)
local FADE = 2.5 -- s, a fade's length
local head, filled = 0, 0 -- the write head and how much of the reel is caught (s), mirrored
-- the tape: the loudest level written to each of WAVE segments of the reel, as the head last
-- passed it (from the engine's amp_reel poll); a pressed reel keeps what's there
local WAVE = 64
local wave, last_seg = {}, nil
local function wipe() for i = 1, WAVE do wave[i] = 0 end; last_seg = nil end
wipe()
local sent = {}
local reel_now = 15 -- the engine's reel (s)
local shown = { part = 0, e2 = 0, e3 = 0, word = 0, station = 0 } -- seconds left for each overlay
local tuning = false -- moving between stations: the reel pressed (if the handover is), static (if set)
local station, status = nil, "starting"
local seeking, trail, amp = nil, {}, 0 -- the station being tried, the last ones, the level written
-- pace: how often the wind moves on its own, in seconds (false: only by hand)
local PACES = { false, 600, 300, 120, 60, 30 }
local word = ""
local redraw_metro

local function m(id) return params:get(id) end
local function pressed() return m("catch_press") == 1 or (tuning and m("handover") == 2) end
local function pace_s() return PACES[math.min(#PACES, 1 + math.floor(m("wind_pace") * #PACES))] end
local function db(v) return v <= -59.9 and 0 or 10 ^ (v / 20) end

-- a fade (tone's gesture), like a shortwave signal fading: for a moment the sound sinks and
-- darkens, the filter closing toward its low end, then it comes back
local function fade_amount() return math.sin(math.pi * fading) end
local function fade_color(c) return c + (0.08 - c) * 0.85 * fade_amount() end

-- the values sound.engine() maps, from the params and the gestures in flight
local function values()
  return {
    catch_position = m("catch_position"), catch_feedback = m("catch_feedback"),
    scatter_density = m("scatter_density"), scatter_size = m("scatter_size"),
    tint_pitch = m("tint_pitch"), tint_spread = m("tint_spread"),
    tone_color = fade_color(m("tone_color")), tone_drive = m("tone_drive"),
    air_space = m("air_space"), air_mix = m("air_mix"),
    reel = S.REELS[m("catch_reel")], envelope = m("scatter_envelope"), media = m("tone_media"),
    scale = m("tint_scale"),
    frozen = pressed(), flipped = m("tint_flip") == 1, hazed = m("air_haze") == 1,
    burst = burst,
  }
end

-- send whatever changed since last time
local function send()
  local e = S.engine(values())
  e.level = db(m("level")) * (1 - 0.6 * fade_amount())
  e.adc = db(m("input"))
  e.static = math.max(m("static"), tuning and m("tune_static") or 0)
  for k, v in pairs(e) do
    if sent[k] ~= v then
      engine.set(k, v)
      sent[k] = v
    end
  end
end

local function say(w) word, shown.word = w, 1.2 end

-- a level from the engine: onto the segment under the head, and any the head skipped since
-- (a few at most: a head that jumps, as when the engine's head poll corrects the mirror, just
-- starts again where it is)
local function catch_level(a)
  amp = a
  if pressed() then return end
  local seg = math.floor(head / S.REELS[m("catch_reel")] * WAVE) % WAVE + 1
  if seg ~= last_seg then
    local gap = last_seg and (seg - last_seg) % WAVE or 0
    local i = (gap > 0 and gap <= 8) and last_seg % WAVE + 1 or seg
    while true do
      wave[i] = a
      if i == seg then break end
      i = i % WAVE + 1
    end
    last_seg = seg
  else
    wave[seg] = math.max(wave[seg], a)
  end
end

-- ---------- params ----------

local function add_params()
  local macro_spec = function(d) return controlspec.new(0, 1, "lin", 0, d, "", 0.01) end
  local counts = { wind = 4, catch = 4, scatter = 3, tint = 4, tone = 3, air = 3 }
  for _, P in ipairs(PARTS) do
    params:add_group("pollen_" .. P.id, P.id, counts[P.id])
    for i, name in ipairs(P.macros) do
      local id = P.id .. "_" .. name
      params:add_control(id, name, macro_spec(P.defaults[i]))
      params:set_action(id, send)
    end
    if P.id == "wind" then
      local names = {}
      for i, k in ipairs(W.KINDS) do names[i] = k.name end
      params:add_option("wind_kind", "wind", names, 1)
      params:add_trigger("wind_drift", "drift now") -- also MIDI-mappable, and norns-web's Drift button
      params:set_action("wind_drift", function() if radio.drift() then say("drifting") end end)
    elseif P.id == "catch" then
      local names = {}
      for i, s in ipairs(S.REELS) do names[i] = s .. " s" end
      params:add_option("catch_reel", "reel", names, 3)
      params:set_action("catch_reel", function(i)
        if S.REELS[i] == reel_now then return end -- the engine starts with a 15 s reel
        reel_now = S.REELS[i]
        engine.reel(reel_now)
        head, filled = 0, 0
        wipe()
        view.reset()
        send()
      end)
    elseif P.id == "scatter" then
      params:add_option("scatter_envelope", "envelope", S.ENVELOPES, 1)
      params:set_action("scatter_envelope", send)
    elseif P.id == "tint" then
      local names = {}
      for i, s in ipairs(S.SCALES) do names[i] = s.name end
      params:add_option("tint_scale", "scale", names, 2)
      params:set_action("tint_scale", send)
    elseif P.id == "tone" then
      params:add_option("tone_media", "media", S.MEDIA, 1)
      params:set_action("tone_media", send)
    end
    if P.hold then
      params:add_binary(P.hold, P.gesture, "toggle", 0)
      params:set_action(P.hold, send)
    end
  end
  params:add_group("pollen_radio", "radio", 5)
  -- how a new station comes in: blended over the reel (crossfaded over one pass of the head, so
  -- the reel turns from the old station to the new as it's written over), or with the reel
  -- pressed while it loads and then a quick crossfade
  params:add_option("handover", "handover", { "over the reel", "pressed" }, 1)
  params:add_control("tune_static", "static while tuning", controlspec.new(0, 1, "lin", 0, 0, "", 0.01))
  params:add_control("crossfade", "crossfade (pressed)", controlspec.new(0.2, 10, "lin", 0, 2, "s", 0.01))
  params:add_control("timeout", "give a station", controlspec.new(4, 30, "lin", 0, 10, "s", 0.01))
  params:add_trigger("refresh", "refresh the stations")
  params:set_action("refresh", function() radio.refresh() end)
  params:add_group("pollen_levels", "levels", 4)
  params:add_control("level", "level", controlspec.new(-60, 6, "lin", 0, 0, "dB", 0.01))
  params:set_action("level", send)
  params:add_control("input", "input", controlspec.new(-60, 6, "lin", 0, 0, "dB", 0.01))
  params:set_action("input", send)
  params:add_control("static", "static", controlspec.new(0, 1, "lin", 0, 0, "", 0.01))
  params:set_action("static", send)
  params:add_trigger("clear", "clear the reel")
  params:set_action("clear", function()
    engine.clear()
    filled = 0
    wipe()
    view.reset()
  end)
end

-- ---------- controls ----------

function enc(n, d)
  local P = PARTS[part]
  if n == 1 then
    part = util.clamp(part + d, 1, #PARTS)
    shown.part = 1.5
  elseif held[2] and n == 2 then
    if P.variety then
      params:delta(P.variety, d)
      say(params:string(P.variety))
    end
  elseif n == 2 or n == 3 then
    params:delta(P.id .. "_" .. P.macros[n - 1], d)
    shown["e" .. n] = 1.2
  end
end

local function gesture(P)
  if P.hold then
    local on = m(P.hold) == 1
    params:set(P.hold, on and 0 or 1)
    local words = { catch_press = { "pressed", "released" }, tint_flip = { "backwards", "forwards" },
      air_haze = { "haze held", "haze free" } }
    say(words[P.hold][on and 2 or 1])
  elseif P.gesture == "burst" then
    burst = 1
    say("burst")
  elseif P.gesture == "fade" then
    fading = 1
    say("fading")
  elseif P.gesture == "drift" then
    if radio.drift() then say("drifting") end
  end
  send()
end

function key(n, z)
  held[n] = z == 1
  if n == 2 and z == 1 and held[1] then -- hold K1 + K2: back to the station before
    if radio.back() then say("back") end
  elseif n == 3 and z == 1 and not held[1] then
    gesture(PARTS[part])
  end
end

-- ---------- the picture ----------

-- what the view draws, from what the sound and the radio are doing
local function look()
  local e = S.engine(values())
  return {
    reel = S.REELS[m("catch_reel")], head = head, filled = filled, frozen = pressed(),
    density = e.density, size = e.size, rate = 2 ^ (e.pitch / 12), reverse = e.reverse,
    age = e.position, pos_spread = e.pos_spread, fb = e.fb,
    space = m("air_space"), hazed = m("air_haze") == 1,
    color = fade_color(m("tone_color")), drive = e.drive, media = m("tone_media"),
    static = math.max(m("static"), tuning and m("tune_static") or 0),
    wave = wave, amp = amp,
    stations = radio.stations, here = station, seeking = seeking, trail = trail,
  }
end

local function text(x, y, s, l, align)
  screen.level(math.floor(l))
  screen.move(x, y)
  if align == "right" then screen.text_right(s) elseif align == "center" then screen.text_center(s) else screen.text(s) end
end

-- text that fits a width, cut short with an ellipsis
local function fit(s, w)
  s = tostring(s or "")
  if screen.text_extents(s) <= w then return s end
  while #s > 1 and screen.text_extents(s .. "...") > w do s = s:sub(1, -2) end
  return s .. "..."
end

local function place_of(st)
  if st.place ~= "" and st.place ~= st.country then return st.place .. ", " .. st.country end
  return st.country
end

-- the place, in w pixels: all of it if it fits, else the city, else the country
local function short_place(st, w)
  for _, s in ipairs({ place_of(st), st.place, st.country }) do
    if s ~= "" and screen.text_extents(s) <= w then return s end
  end
  return fit(st.country ~= "" and st.country or st.place, w)
end

-- a macro's name and a bar for where it is, E2's on the left and E3's on the right (where the
-- encoders are), on a dark strip so the picture doesn't run through them; f fades them out
local BAR = 20
local function draw_macro(P, k, f)
  local name = P.macros[k]
  local w = screen.text_extents(name) or #name * 5
  local x = k == 1 and 2 or 126 - BAR - 4 - w
  screen.level(0)
  screen.rect(x - 2, 55, w + BAR + 6, 9)
  screen.fill()
  text(x, 62, name, 12 * f)
  local bx = x + w + 4
  screen.level(math.max(1, math.floor(2 * f + 0.5)))
  screen.rect(bx, 58, BAR, 2)
  screen.fill()
  screen.level(math.max(1, math.floor(10 * f + 0.5)))
  screen.rect(bx, 58, math.max(1, math.floor(BAR * m(P.id .. "_" .. name) + 0.5)), 2)
  screen.fill()
end

-- hold K1: every part and where its two macros are, as bars (no numbers), and the station
local function draw_peek()
  for i, P in ipairs(PARTS) do
    local y = (i - 1) * 9
    local l = i == part and 15 or 5
    text(2, y + 6, P.id, l)
    for k = 1, 2 do
      local x = 48 + (k - 1) * 40
      local v = m(P.id .. "_" .. P.macros[k])
      screen.level(2)
      screen.rect(x, y + 2, 34, 3)
      screen.fill()
      screen.level(l)
      screen.rect(x, y + 2, math.max(1, math.floor(34 * v + 0.5)), 3)
      screen.fill()
    end
  end
  if station then text(64, 62, fit(station.name .. " - " .. place_of(station), 126), 8, "center")
  else text(64, 62, status, 4, "center") end
end

function redraw()
  screen.clear()
  if held[1] then
    draw_peek()
  else
    view.draw(look())
    local P = PARTS[part]
    -- the top right, over the tape: a gesture's word, or tuning, or the station's name (bright
    -- as it arrives); under the tape, its place, or the radio's state when it isn't playing
    if shown.word > 0 then text(126, 8, word, 12 * math.min(1, shown.word), "right")
    elseif seeking then text(126, 8, "tuning", 5 + 5 * math.abs(math.sin(util.time() * 4)), "right")
    elseif station then text(126, 8, fit(station.name, 64), 4 + 9 * math.min(1, shown.station), "right") end
    if station and status == "playing" or status == "tuning" then
      if station then text(126, 52, short_place(station, 64), 3 + 7 * math.min(1, shown.station), "right") end
    else
      text(126, 52, status, 4, "right")
    end
    if shown.part > 0 then
      local w = screen.text_extents(P.id) or #P.id * 5
      screen.level(0)
      screen.rect(0, 0, w + 4, 10)
      screen.fill()
      text(2, 8, P.id, 15 * math.min(1, shown.part))
    end
    for k = 1, 2 do
      local f = math.min(1, math.max(shown["e" .. (k + 1)], shown.part))
      if f > 0 then draw_macro(P, k, f) end
    end
  end
  screen.update()
end

local function tick()
  local dt = 1 / FPS
  local reel = S.REELS[m("catch_reel")]
  if not pressed() then
    head = (head + dt) % reel
    filled = math.min(reel, filled + dt)
  end
  for k, v in pairs(shown) do shown[k] = math.max(0, v - dt) end
  if burst > 0 or fading > 0 then
    burst = math.max(0, burst - dt / 1.5)
    fading = math.max(0, fading - dt / FADE)
    send()
  end
  view.update(dt, look())
  redraw()
end

function init()
  add_params()
  params:bang()
  send()
  -- the engine tells where its write head really is (the mirror drifts) and what it writes
  local ph = poll.set("head", function(v) head = v end)
  if ph then
    ph.time = 0.5
    ph:start()
  end
  local pr = poll.set("amp_reel", catch_level)
  if pr then
    pr.time = 1 / 30
    pr:start()
  end
  redraw_metro = metro.init(tick, 1 / FPS)
  redraw_metro:start()

  -- the radio, and the wind's pace on the norns clock
  radio.init({
    tuning = function(on)
      tuning = on
      if not on then seeking = nil end
      send()
    end,
    seeking = function(st) seeking = st end,
    arrived = function(st)
      station, seeking, shown.station = st, nil, 6
      trail[#trail + 1] = st
      if #trail > 6 then table.remove(trail, 1) end
    end,
    status = function(s) status = s end,
    settings = function()
      local over = m("handover") == 1
      return { kind = W.KINDS[m("wind_kind")].id, reach = m("wind_reach"),
        xfade = over and S.REELS[m("catch_reel")] or m("crossfade"),
        timeout = m("timeout"), settle = 1.5, volume = 1 }
    end,
  })
  clock.run(function()
    local waited = 0
    while true do
      clock.sleep(1)
      waited = waited + 1
      local every = pace_s()
      if every and waited >= every and radio.drift() then waited = 0 end
    end
  end)
end

function cleanup()
  if redraw_metro then redraw_metro:stop() end
  radio.cleanup()
end
