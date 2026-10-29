-- The radio: the stations, the wind and the player, together. Moving to a new station
-- (drifting) goes: press the reel and bring in the static, load the next station on the idle
-- player, wait until it really plays, crossfade, let the reel catch it, release. A station
-- that doesn't play in time is marked dead (for an hour) and the wind tries another.
-- Stateful: include it only from pollen.lua.
--
--   R.init(hooks)   hooks: tuning(on) (press/static while moving), arrived(station),
--                   status(text), settings() -> { kind, reach, xfade, timeout, settle, volume }
--   R.drift()       move on with the wind (ignored while already moving)
--   R.back()        back to the station before (history)
--   R.cleanup()

local Stations = include("lib/stations")
local Player = include("lib/player")
local W = include("lib/walker")

local R = { stations = nil, current = nil, status = "starting", busy = false }

R.DEAD_FOR = 3600 -- seconds a station that didn't play is left alone
R.TRIES = 4       -- stations tried in one move before giving up

local hooks = {}
local live = "a"  -- the player that's playing (or will, the first time)
local history, mem, dead = {}, {}, {}
local forced = nil -- the station back() asked for

local function set_status(s)
  R.status = s
  if hooks.status then hooks.status(s) end
end

-- an mpv command, waited for inside a clock (a reply, or { error = "timeout" })
local function call(name, cmd, timeout)
  local reply
  Player.send(name, cmd, function(r) reply = r end)
  local t = 0
  while not reply and t < timeout do
    clock.sleep(0.05)
    t = t + 0.05
  end
  return reply or { error = "timeout" }
end

local function is_dead(st)
  local d = dead[st.url]
  return d ~= nil and os.time() - d < R.DEAD_FOR
end

local function crossfade(to, s)
  local from, steps = live, 12
  for i = 1, steps do
    local v = i / steps
    Player.send(to, { "set_property", "volume", math.floor(100 * v * s.volume + 0.5) })
    if from ~= to then -- the first station has nothing to fade from
      Player.send(from, { "set_property", "volume", math.floor(100 * (1 - v) * s.volume + 0.5) })
    end
    clock.sleep(s.xfade / steps)
  end
  if from ~= to then Player.send(from, { "stop" }) end
end

local function move()
  if R.busy or not R.stations then return false end
  R.busy = true
  clock.run(function()
    local s = hooks.settings()
    hooks.tuning(true)
    set_status("tuning")
    local arrived = false
    for _ = 1, R.TRIES do
      local st = forced or W.next(s.kind, R.stations, R.current, mem, s.reach, is_dead)
      forced = nil
      if not st then break end
      local idle = R.current and (live == "a" and "b" or "a") or live
      -- loadfile is waited for without a limit: mpv answers at once (or socat fails at once);
      -- in a browser the answer waits for its sound to be switched on
      local r = call(idle, { "loadfile", st.url, "replace" }, math.huge)
      if r.error == "success" then
        local waited = 0
        while waited < s.timeout do
          clock.sleep(0.5)
          waited = waited + 0.5
          local t = call(idle, { "get_property", "playback-time" }, 3)
          if t.error == "success" and (tonumber(t.data) or 0) > 0.3 then arrived = true; break end
        end
      end
      if arrived then
        crossfade(idle, s)
        live = idle
        R.current = st
        history[#history + 1] = st
        if #history > 32 then table.remove(history, 1) end
        hooks.arrived(st)
        set_status("playing")
        print(("pollen: %s (%s), %s"):format(st.name, st.place ~= "" and (st.place .. ", " .. st.country) or st.country, st.url))
        clock.sleep(s.settle) -- the reel catches the new station before it's released
        break
      end
      call(idle, { "stop" }, 3)
      dead[st.url] = os.time()
      print(("pollen: no sound from %s (%s), moving on"):format(st.name, st.country))
    end
    if not arrived then set_status(R.current and "playing" or "silent") end
    hooks.tuning(false)
    R.busy = false
  end)
  return true
end

function R.drift() return move() end

function R.back()
  if R.busy or #history < 2 then return false end
  table.remove(history) -- the one playing now
  forced = table.remove(history)
  return move()
end

function R.init(h)
  hooks = h
  local ok, missing = Player.available()
  if not ok then
    set_status("needs " .. table.concat(missing, " and "))
    print("pollen: the radio needs " .. table.concat(missing, " and ") .. ". Over ssh (ssh we@norns.local): "
      .. "sudo apt install -y " .. table.concat(missing, " ") .. " -- until then, pollen plays the input.")
    return
  end
  Player.launch()
  set_status("gathering")
  Stations.load(function(list, where)
    if not list then
      set_status("offline")
      print("pollen: no stations (" .. tostring(where) .. "); pollen plays the input")
      return
    end
    R.stations = list
    print(("pollen: %d stations (%s)"):format(#list, where))
    clock.run(function()
      clock.sleep(1) -- mpv opens its socket a moment after it starts
      move()
    end)
  end)
end

function R.refresh()
  Stations.refresh(function(list) if list then R.stations = list end end)
end

function R.cleanup() Player.kill() end

return R
