-- The wind: where pollen goes next. Pure functions over a list of stations ({ lat, lon, ... });
-- the wind's own memory (its bearing, the stations visited) is a table the caller keeps.
--
--   W.next(kind, stations, from, mem, reach, skip) -> a station (or nil: none left)
--
-- kind: one of W.KINDS' ids. from: the station we're at (nil at first). reach: 0..1, how far a
-- move goes. skip(st): true for stations not to land on (dead ones).

local W = {}

W.KINDS = {
  { id = "breeze", name = "breeze" },        -- to one of the nearest flowers not visited yet
  { id = "trade", name = "trade wind" },     -- steadily along one bearing
  { id = "eddy", name = "eddy" },            -- a random walk: the bearing turns a little each move
  { id = "gust", name = "gust" },            -- anywhere at all
  { id = "far", name = "far side" },         -- to the other side of the world, and back
}

local R_EARTH = 6371
local rad, deg = math.rad, math.deg
local sin, cos, asin, atan = math.sin, math.cos, math.asin, math.atan

function W.distance(a, b) -- km, along the surface (haversine)
  local dlat, dlon = rad(b.lat - a.lat), rad(b.lon - a.lon)
  local h = sin(dlat / 2) ^ 2 + cos(rad(a.lat)) * cos(rad(b.lat)) * sin(dlon / 2) ^ 2
  return 2 * R_EARTH * asin(math.min(1, math.sqrt(h)))
end

function W.bearing(a, b) -- degrees from north, the way from a to b
  local p1, p2, dl = rad(a.lat), rad(b.lat), rad(b.lon - a.lon)
  local y = sin(dl) * cos(p2)
  local x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
  return (deg(atan(y, x)) + 360) % 360
end

function W.travel(a, bearing, km) -- the point km away from a along a bearing
  local d, b = km / R_EARTH, rad(bearing)
  local p1, l1 = rad(a.lat), rad(a.lon)
  local p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(b))
  local l2 = l1 + atan(sin(b) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
  return { lat = deg(p2), lon = (deg(l2) + 540) % 360 - 180 }
end

function W.antipode(a) return { lat = -a.lat, lon = (a.lon + 360) % 360 - 180 } end

-- the station nearest a point, among those ok(st) allows
local function nearest(stations, point, ok)
  local best, bd = nil, math.huge
  for _, st in ipairs(stations) do
    if ok(st) then
      local d = W.distance(point, st)
      if d < bd then best, bd = st, d end
    end
  end
  return best
end

-- k nearest, for the breeze: a short list, kept sorted by insertion
local function k_nearest(stations, point, ok, k)
  local list = {}
  for _, st in ipairs(stations) do
    if ok(st) then
      local d = W.distance(point, st)
      if #list < k or d < list[#list].d then
        local i = #list + 1
        while i > 1 and list[i - 1].d > d do i = i - 1 end
        table.insert(list, i, { st = st, d = d })
        if #list > k then list[#list] = nil end
      end
    end
  end
  return list
end

-- the distance a move covers: 50 km at the least reach, 5000 at the most
function W.step_km(reach) return 50 * 100 ^ math.max(0, math.min(1, reach)) end

function W.next(kind, stations, from, mem, reach, skip)
  mem.visited = mem.visited or {}
  local function ok(st) return st ~= from and not mem.visited[st] and not (skip and skip(st)) end
  local any = false
  for _, st in ipairs(stations) do if ok(st) then any = true; break end end
  if not any then -- every flower visited: start afresh
    mem.visited = {}
    for _, st in ipairs(stations) do if ok(st) then any = true; break end end
    if not any then return nil end
  end
  local pick
  if not from or kind == "gust" then
    local n = 0
    for _, st in ipairs(stations) do
      if ok(st) then
        n = n + 1
        if math.random(n) == 1 then pick = st end -- one at random, in one pass
      end
    end
  elseif kind == "breeze" then
    local list = k_nearest(stations, from, ok, 1 + math.floor(reach * 9 + 0.5))
    pick = list[math.random(#list)].st
  elseif kind == "trade" or kind == "eddy" then
    mem.bearing = mem.bearing or math.random() * 360
    if kind == "eddy" then mem.bearing = (mem.bearing + (math.random() - 0.5) * 120) % 360 end
    pick = nearest(stations, W.travel(from, mem.bearing, W.step_km(reach)), ok)
  elseif kind == "far" then
    local target = W.antipode(from)
    if reach > 0 then target = W.travel(target, math.random() * 360, W.step_km(reach) * math.random() * 0.5) end
    pick = nearest(stations, target, ok)
  end
  if pick then mem.visited[pick] = true end
  return pick
end

return W
