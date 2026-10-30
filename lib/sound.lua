-- pollen's sound: every macro (0..1) and option, mapped to the engine's raw parameters.
-- The engine only knows raw parameters (lib/Engine_Pollen.sc); the curves and ranges here
-- are where the sound is tuned. Pure functions: no state, safe to include anywhere.
--
-- sound.engine(v) takes the script's current values and returns { key = value } for the
-- engine's set(key, value).

local S = {}

S.REELS = { 4, 8, 15, 30, 60 } -- seconds
S.HEADS = { "1 head", "2 heads", "3 heads", "4 heads" } -- the grains' read heads
-- how far apart the heads play, in steps of the scale (each head one more than the last)
S.INTERVALS = { { name = "unison", steps = 0 }, { name = "a step apart", steps = 1 },
  { name = "two steps apart", steps = 2 }, { name = "three steps apart", steps = 3 },
  { name = "four steps apart", steps = 4 } }
S.ENVELOPES = { "bell", "pluck", "block" } -- engine env 0, 1, 2
S.MEDIA = { "digital", "vintage", "clean tape", "dirty tape" } -- after Beads' media
S.SCALES = {
  { name = "octaves", steps = { 0 } },
  { name = "fifths", steps = { 0, 7 } },
  { name = "major", steps = { 0, 2, 4, 7, 9 } },
  { name = "minor", steps = { 0, 3, 5, 7, 10 } },
  { name = "chromatic", steps = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 } },
  { name = "free", steps = nil },
}

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function expo(lo, hi, x) return lo * (hi / lo) ^ clamp(x, 0, 1) end

-- the nearest note of the scale, in semitones (free: unquantized)
function S.quantize(semis, scale)
  local steps = S.SCALES[scale].steps
  if not steps then return semis end
  local best, dist = 0, math.huge
  for oct = -3, 3 do
    for _, st in ipairs(steps) do
      local n = oct * 12 + st
      if math.abs(n - semis) < dist then best, dist = n, math.abs(n - semis) end
    end
  end
  return best
end

-- n steps of the scale up from a note of it (free: n semitones)
function S.step(semis, scale, n)
  local steps = S.SCALES[scale].steps
  if not steps or n == 0 then return semis + (steps and 0 or n) end
  local k = #steps
  -- the note's place in the scale, counted across octaves
  local idx
  for oct = -4, 4 do
    for i, st in ipairs(steps) do
      if oct * 12 + st == semis then idx = (oct + 4) * k + (i - 1) end
    end
  end
  if not idx then return semis + n end
  idx = idx + n
  return (idx // k - 4) * 12 + steps[idx % k + 1]
end

-- the semitones the tint's pitch macro plays: -24..+24, 0 in the middle (a dead zone)
function S.pitch(m, scale)
  local x = (m - 0.5) * 2
  if math.abs(x) < 0.06 then return 0 end
  return S.quantize(x * 24, scale)
end

-- v: catch_position, catch_feedback, scatter_density, scatter_size, tint_pitch, tint_spread,
-- tone_color, tone_drive, air_space, air_mix (0..1 each), and reel (s), envelope, media,
-- scale, heads, interval (indexes), frozen, flipped, hazed (booleans), burst (0..1, decaying)
function S.engine(v)
  local e = {}
  -- catch: position reaches back into the reel (squared: fine control near "now");
  -- feedback writes the grains back into it
  e.position = v.reel * (0.002 + 0.9 * v.catch_position ^ 2)
  e.pos_spread = 0.01 + 0.2 * v.catch_position
  e.fb = 0.85 * v.catch_feedback ^ 1.5
  e.freeze = v.frozen and 1 or 0

  -- scatter: density 0.5..40 grains a second (more in a burst), size 20 ms..2 s; the
  -- denser it gets the looser the timing. amp keeps the overlap from piling up.
  local density = expo(0.5, 40, v.scatter_density) * (1 + 3 * (v.burst or 0))
  local size = expo(0.02, 2, v.scatter_size)
  e.density, e.size = density, size
  e.jitter = 0.15 + 0.6 * v.scatter_density
  e.amp = 0.7 / math.sqrt(math.max(1, density * size))
  e.env = v.envelope - 1
  e.spread = 0.3 + 0.6 * v.scatter_density

  -- tint: pitch in the scale; spread opens the pitch (up to an octave) and past the middle
  -- sends some grains backwards. Flipped turns that around: mostly backwards.
  e.pitch = S.pitch(v.tint_pitch, v.scale)
  e.pitch_spread = 12 * v.tint_spread ^ 2
  -- the heads: spread evenly along the reel, each one the interval up the scale from the last
  local heads = v.heads or 1
  e.heads, e.hgap = heads, v.reel / heads
  local steps = S.INTERVALS[v.interval or 1].steps
  for k = 1, 3 do
    local off = k < heads and S.step(e.pitch, v.scale, k * steps) - e.pitch or 0
    while off > 24 do off = off - 12 end -- folded down by octaves: at most two above the first
    e["hp" .. k] = off
  end
  local rev = clamp((v.tint_spread - 0.5) * 1.2, 0, 0.6)
  e.reverse = v.flipped and 1 - rev or rev

  -- tone: color is one knob, a DJ filter: left of the middle a low-pass closes, right of
  -- it a high-pass opens, the middle is open. drive saturates.
  local c = v.tone_color
  if c < 0.45 then
    e.ftype, e.cutoff = 1, expo(120, 18000, c / 0.45)
  elseif c > 0.55 then
    e.ftype, e.cutoff = 2, expo(30, 6000, (c - 0.55) / 0.45)
  else
    e.ftype, e.cutoff = 0, 2000
  end
  e.res = 0.15 + 0.35 * math.abs(c - 0.5) * 2
  e.drive = v.tone_drive ^ 1.5
  e.media = v.media - 1

  -- air: space sends the grains to the reverb and grows it; mix goes from the live input
  -- alone (0) to the grains alone (1)
  e.send = 0.8 * v.air_space ^ 1.2
  e.vsize = 0.4 + 0.55 * v.air_space
  e.vfreeze = v.hazed and 1 or 0
  e.mix = v.air_mix
  return e
end

return S
