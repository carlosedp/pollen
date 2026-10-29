-- The player: two mpv instances ("a" and "b"), so the next station can start while the
-- current one plays. Each one sends its sound to SuperCollider's inputs over JACK (the
-- engine's input, where the ADC also arrives) and listens on a socket for JSON commands,
-- sent with socat. All of it runs through norns.system_cmd: nothing blocks.
--
--   P.available()          mpv and socat installed? (and a list of what's missing)
--   P.launch()             start both (after killing any left from before)
--   P.send(name, cmd, cb)  an mpv command ({ "loadfile", url, "replace" }), cb(reply table)
--   P.kill()               stop both (cleanup)
--
-- JACK: mpv connects itself to the ports matching JACK_TO, in order (in_1, in_2). To check on
-- a norns: `jack_lsp -c` while a station plays should show pollen_a:out_0 -> SuperCollider:in_1.

local json = include("lib/json")

local P = {}

P.NAMES = { "a", "b" }
P.JACK_TO = "SuperCollider:in_"
P.NEEDS = { "mpv", "socat" }

function P.socket(name) return "/tmp/pollen_" .. name .. ".sock" end

local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

function P.available()
  local missing = {}
  for _, prog in ipairs(P.NEEDS) do
    if util.os_capture("command -v " .. prog) == "" then missing[#missing + 1] = prog end
  end
  return #missing == 0, missing
end

function P.kill()
  norns.system_cmd("pkill -f 'input-ipc-server=/tmp/pollen_' ; rm -f /tmp/pollen_a.sock /tmp/pollen_b.sock")
end

function P.launch()
  -- anything left over from a crash goes first
  P.kill()
  for _, name in ipairs(P.NAMES) do
    norns.system_cmd(table.concat({
      "nohup mpv --idle=yes --no-video --no-terminal --really-quiet",
      "--ao=jack --jack-name=pollen_" .. name, "--jack-autoconnect=yes --jack-port=" .. quote(P.JACK_TO),
      "--audio-samplerate=48000 --cache=yes --demuxer-readahead-secs=2 --network-timeout=10",
      "--volume=0 --input-ipc-server=" .. P.socket(name), ">/dev/null 2>&1 &",
    }, " "))
  end
end

-- one command, one reply ({ error = "success", data = ... }, or { error = "..." } when mpv
-- isn't there or answers nothing)
function P.send(name, cmd, cb)
  local line = json.encode({ command = cmd })
  norns.system_cmd("echo " .. quote(line) .. " | socat - " .. P.socket(name) .. " 2>/dev/null", function(out)
    if not cb then return end
    for l in (out or ""):gmatch("[^\n]+") do
      local ok, r = pcall(json.decode, l)
      if ok and type(r) == "table" and r.error then cb(r); return end -- skip mpv's event lines
    end
    cb({ error = "no reply" })
  end)
end

return P
