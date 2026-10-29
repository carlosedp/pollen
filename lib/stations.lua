-- The stations: where the flowers are. Fetched from radio-browser.info (an open, community
-- database), the most listened-to stations that have a place on the map, and kept on disk as a
-- compact Lua table so later starts don't fetch or parse it again (it's refreshed after a week).
--
--   St.load(cb)       cb(list, where): from the cache if it's fresh, else fetched (where:
--                     "cache", "fetched", or nil and an error)
--   St.refresh(cb)    fetch again, whatever the cache says
--
-- A station: { id, name, place, country, lat, lon, url, bitrate (kbps, 0 if unknown), codec }.
-- Never blocks for the network: curl runs through norns.system_cmd.

local json = include("lib/json")

local St = {}

St.UA = "pollen/0.2 (monome norns; https://github.com/carlosedp/pollen)"
St.LIMIT = 1500
St.MAX_AGE = 7 * 24 * 3600
-- radio-browser's servers, tried in a random order until one answers, then all.api (their
-- round-robin name, which follows the servers as they come and go; as of October 2026, de1 and
-- de2 are the ones up)
St.SERVERS = { "de1.api.radio-browser.info", "de2.api.radio-browser.info" }
St.LAST_RESORT = "all.api.radio-browser.info"

local function cache_file() return _path.data .. "pollen/stations_radiobrowser.lua" end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")) end

-- the API's records, down to what pollen uses; HLS streams and ones without a place are left out
function St.simplify(records)
  local out, seen = {}, {}
  for _, r in ipairs(records or {}) do
    local lat, lon = tonumber(r.geo_lat), tonumber(r.geo_long)
    local url = trim(r.url_resolved ~= "" and r.url_resolved or r.url)
    if lat and lon and (lat ~= 0 or lon ~= 0) and url:match("^https?://") and r.hls ~= 1 and not seen[url] then
      seen[url] = true
      out[#out + 1] = { id = r.stationuuid or url, name = trim(r.name), place = trim(r.state),
        country = trim(r.country), lat = lat, lon = lon, url = url,
        bitrate = math.floor(tonumber(r.bitrate) or 0), codec = trim(r.codec) }
    end
  end
  return out
end

function St.save(list)
  util.make_dir(_path.data .. "pollen")
  local f = io.open(cache_file(), "w")
  if not f then return false end
  f:write(("return { fetched = %d, stations = {\n"):format(os.time()))
  for _, s in ipairs(list) do
    f:write(("{id=%q,name=%q,place=%q,country=%q,lat=%.5f,lon=%.5f,url=%q,bitrate=%d,codec=%q},\n"):format(
      s.id, s.name, s.place, s.country, s.lat, s.lon, s.url, s.bitrate, s.codec))
  end
  f:write("} }\n")
  f:close()
  return true
end

-- the cached list and when it was fetched, or nil
function St.cached()
  if not util.file_exists(cache_file()) then return nil end
  local ok, t = pcall(dofile, cache_file())
  if ok and type(t) == "table" and type(t.stations) == "table" and #t.stations > 0 then return t.stations, t.fetched end
  return nil
end

function St.url(server)
  return ("https://%s/json/stations/search?has_geo_info=true&hidebroken=true&order=clickcount&reverse=true&limit=%d")
    :format(server, St.LIMIT)
end

function St.refresh(cb)
  local order = {}
  for i, s in ipairs(St.SERVERS) do table.insert(order, math.random(i), s) end
  order[#order + 1] = St.LAST_RESORT
  local function try(i)
    if i > #order then cb(nil, "no radio-browser server answered"); return end
    local cmd = ("curl -sfL -m 30 -A '%s' '%s'"):format(St.UA, St.url(order[i]))
    norns.system_cmd(cmd, function(out)
      local ok, records = pcall(json.decode, out or "")
      local list = ok and St.simplify(records) or {}
      if #list == 0 then
        print("pollen: " .. order[i] .. (ok and " sent no stations" or (": " .. tostring(records))))
        try(i + 1)
        return
      end
      St.save(list)
      cb(list, "fetched")
    end)
  end
  try(1)
end

function St.load(cb)
  local list, fetched = St.cached()
  if list and os.time() - (fetched or 0) < St.MAX_AGE then cb(list, "cache"); return end
  St.refresh(function(fresh, err)
    if fresh then cb(fresh, "fetched")
    elseif list then cb(list, "cache") -- old, but better than nothing (offline)
    else cb(nil, err) end
  end)
end

return St
