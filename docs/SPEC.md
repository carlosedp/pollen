# pollen — design spec

> A norns script that tunes into live radio stations around the globe (via Radio Garden / radio-browser), walks the globe randomly or along musical paths, and feeds the stream into a live granular engine in the spirit of Morphagene / Endorphin.es Evil Pet.

Working name: **pollen** (grains from the garden). Alternatives: _meridian_, _antipode_, _skywave_, _driftwave_.

---

## 1. Goals

- Pull a live internet radio stream from anywhere on the globe and treat it as a continuous live input to a granular engine.
- Choose stations randomly or by "walking" the globe (geographic movement over time), clock-synced or manual.
- Real-time granular manipulation: position, size, density, pitch, spread, reverse, freeze, feedback.
- Make station changes musical: freeze the grain buffer during tuning, crossfade, optional "dial static".
- Hands-on control: norns encoders/keys, params, MIDI CC, grid (optional), crow CV in/out (optional).
- Screen: dot-matrix world map with station dots and current-position cursor.

### Non-goals (v1)

- Recording the raw streams to disk (beyond normal norns TAPE).
- Video, metadata display beyond station/place/country name.
- Running the station browser in a web UI.

---

## 2. Target platform

- monome norns (stock CM3 and Pi 3 (and 4) / shield). Must stay within CM3 CPU budget at default settings.
- norns audio runs at 48 kHz under JACK; SuperCollider engine + Lua script.
- External deps: `mpv` (and its ffmpeg libs), `curl`. Do **not** auto-install silently: detect on load, show an install prompt on screen and print the command to maiden (`sudo apt install -y mpv`).

---

## 3. Architecture

```txt
 ┌───────────────┐   HTTP/JSON   ┌──────────────┐
 │ station       │◀─────────────▶│ Radio Garden │ (unofficial API)
 │ backend (Lua) │◀─────────────▶│ radio-browser│ (open API, fallback)
 └──────┬────────┘               └──────────────┘
        │ stream URL
 ┌──────▼────────┐  FIFO cmds  ┌───────────┐  JACK   ┌──────────────────────┐
 │ player.lua    │────────────▶│ mpv  A/B  │────────▶│ SuperCollider engine │──▶ out
 │ (2 instances) │             └───────────┘         │ Engine_Pollen.sc     │
 └──────▲────────┘                                   └──────────▲───────────┘
        │                                                       │ params / polls
 ┌──────┴────────┐     ┌───────────┐     ┌─────────┐            │
 │ walker.lua    │◀───▶│ pollen.lua│◀───▶│ ui.lua  │────────────┘
 │ (geo walks)   │     │ (main)    │     │ map/screen
 └───────────────┘     └───────────┘     └─────────┘
```

### File layout

```txt
pollen/
  pollen.lua              -- main script: init, params, clock, keys/encs, cleanup
  lib/
    Engine_Pollen.sc      -- SuperCollider granular engine
    backend.lua           -- backend interface + selection
    backend_radiogarden.lua
    backend_radiobrowser.lua
    cache.lua             -- on-disk cache of places/stations (data dir)
    player.lua            -- mpv process management, JACK routing, crossfade
    walker.lua            -- globe walk strategies, haversine, nearest-neighbour
    ui.lua                -- screen drawing, world map
    worldmap.lua          -- precomputed 128x64-ish land mask / coastline points
    json.lua              -- vendored pure-Lua JSON (e.g. rxi/json.lua, MIT)
    control.lua           -- MIDI CC map, grid, crow
  data/                   -- default pset(s)
  README.md
```

---

## 4. Components

### 4.1 Station backends (`backend*.lua`)

Common interface:

```lua
backend:places()                -- -> list of {id, name, country, lat, lon, size}
backend:stations(place_id)      -- -> list of {id, title, url_or_id}
backend:stream_url(station)     -- -> playable URL (follow redirects)
backend:search(query)           -- optional
```

**Radio Garden (unofficial, may break):**

- `GET https://radio.garden/api/ara/content/places` — all places with geo `[lon, lat]`
- `GET https://radio.garden/api/ara/content/page/{placeId}/channels` — stations in a place
- `GET https://radio.garden/api/ara/content/listen/{channelId}/channel.mp3` — redirects to the real stream; resolve with `curl -sIL -o /dev/null -w '%{url_effective}'`
- Reference: unofficial OpenAPI spec `jonasrmichel/radio-garden-openapi`.
- Be polite: cache aggressively, send a sensible User-Agent, no bulk crawling of channel pages.

**radio-browser.info (open, community DB):** fallback / alternative default. Use stations with `geo_lat`/`geo_long`; group into synthetic "places" by rounding coords. Resolve a server via DNS/round-robin per their docs.

Backend is a param (`radiogarden` / `radiobrowser`), auto-fallback if the first fails.

### 4.2 Cache (`cache.lua`)

- Store places JSON in `_path.data.."pollen/places_<backend>.json"`; refresh if older than 7 days or on demand (param action).
- Cache per-place station lists lazily (LRU, cap size).
- Track a "dead" list (stream failed) with a TTL so the walker skips it.
- Favorites list persisted in data dir; K-combo to add current station.

### 4.3 Async HTTP

- Never block the Lua main thread. Use `norns.system_cmd(cmd, callback)` (async) for curl calls; parse in callback.
- Timeouts on every curl (`--max-time`).

### 4.4 Player (`player.lua`)

- Two mpv instances (A/B) so the next station can buffer while the current one plays; crossfade in the engine (two stereo inputs) or by ramping mpv volume.
- Launch (per instance), roughly:

  ```txt
  mpv --no-video --idle --no-terminal \
      --ao=jack --jack-name=pollen_a --jack-autoconnect=no \
      --audio-samplerate=48000 --cache=yes --demuxer-readahead-secs=2 \
      --input-ipc-server=/dev/shm/pollen_a.sock
  ```

  (FIFO via `--input-file` is the alternative; precedent: schollz/norns.online.)

- Control: `loadfile <url> replace`, `set volume`, `stop` via IPC socket (`socat` or `echo ... > fifo`).
- Detect "playing" vs "failed": poll mpv `idle-active` / `core-idle` / playback-time via IPC, or watch for audio on the engine input (amplitude poll). Timeout (e.g. 8 s) → mark dead, pick another.
- JACK routing: after mpv registers ports, `jack_connect pollen_a:out_0 <engine in L>` etc. **Verify port names on device with `jack_lsp`** (SuperCollider inputs vs crone inputs) — engine must receive mpv as its input, _not_ go straight to system:playback. Keep the routing table in one place.
- `cleanup()`: kill both mpv instances, remove sockets/FIFOs, disconnect ports. Also kill orphans from a previous crash on `init()`.

### 4.5 Granular engine (`Engine_Pollen.sc`)

Live, continuously-recording granulator, Morphagene/Evil Pet flavoured.

- Inputs: stream A, stream B (crossfade `xfade` 0..1), optional norns ADC mix (`adc_mix`).
- Circular stereo buffer (default 8 s, param 2–30 s) written by `BufWr`/`RecordBuf` at a moving write head; `rec` gated off when **freeze** is on.
- `feedback`: mix of grain output written back into the buffer (with soft clip) for Morphagene-style layering.
- Grain playback: `GrainBuf` (mono buffers per channel or stereo handled by two voices), triggers from `Impulse`/`Dust` blend:
  - `density` (grains/s), `jitter` (0 = sync, 1 = random)
  - `size` (ms)
  - `position` — **relative to write head** (age in buffer, 0 = now), plus `pos_spread` randomisation
  - `pitch` (semitones), `pitch_spread`, optional quantize to scale
  - `reverse` probability
  - `spread` (stereo pan randomisation)
  - envelope shape (Hann / perc / rect)
- Post: multimode filter (LP/HP/BP, cutoff, res), saturation/drive, reverb (FreeVerb2) send, dry/wet `mix`, output level.
- Static/noise generator for tuning gaps (`static_level`, auto-triggered by Lua during station changes).
- Polls: input amplitude (stream health), output envelope follower (for crow out), write-head position (for UI).
- Commands: one `engine.<param>(value)` per parameter; `freeze(0/1)`, `clear()`.
- CPU budget: cap max grains (e.g. 16–24 on CM3); expose `max_density` param.
- Evaluate the use of Mutable Instruments engines like Clouds or Beads which have been ported and are available at $HOME/projects/norns-mi-UGens and on GitHub. Even use these modules's Reverb for example.
- The idea is inspired by Evil Pet where one can record a part of a stream and process/manipulate it in real-time, layering and transforming audio creatively.

### 4.6 Walker (`walker.lua`)

Decides the next place/station. Modes (param):

| mode        | behaviour                                                            |
| ----------- | -------------------------------------------------------------------- |
| `random`    | uniform random place (optionally weighted by station count)          |
| `nearest`   | nearest unvisited place to current                                   |
| `drift`     | move along a bearing by `step_km` each change, snap to nearest place |
| `wander`    | random walk: bearing jitters each step                               |
| `antipode`  | jump to place nearest to the antipode, alternate                     |
| `sun`       | follow local dusk/dawn line based on current UTC time                |
| `country`   | random within locked country                                         |
| `favorites` | cycle/random over favorites                                          |
| `manual`    | only on user action; E-knob scrolls nearby places                    |

- Haversine distance; simple spatial index (lat/lon grid buckets) for nearest-neighbour on CM3.
- History ring (for "go back" key) and visited-set to avoid repeats.

### 4.7 Change triggering

- `change_mode`: manual / every N beats (norns clock) / probability per bar / crow input trigger / MIDI note / grid key.
- On change: (1) set freeze on (if `freeze_on_tune`), (2) optional static burst, (3) load next station on idle mpv instance, (4) when audio detected, crossfade over `xfade_time`, (5) release freeze after `refreeze_delay`.

### 4.8 UI (`ui.lua`)

- Page 1 **GLOBE**: dot world map (precomputed points in `worldmap.lua`), dim dots for places (subsample), bright cursor for current, trail of last N stations, station title + city/country scrolling text, status (tuning / playing / dead).
- Page 2 **GRAINS**: position/size/density/pitch with a buffer strip showing write head and grain positions.
- Page 3 **TONE**: filter/drive/reverb/mix.
- Keys/encs (suggestion):
  - E1 page; E2/E3 page params
  - K2 next station (walker); K3 freeze toggle
  - K1+K2 previous (history); K1+K3 favorite current
- Redraw at ~15 fps via metro; keep drawing cheap.

### 4.9 Control (`control.lua`)

- All engine params exposed via norns `params` → MIDI-mappable for free.
- crow (optional, detect): in 1 = change trigger, in 2 = CV → position (or walker bearing); out 1 = output envelope, out 2 = longitude as CV (-5..+5 V), out 3 = latitude, out 4 = gate on station change.
- grid (optional): row of favorites, freeze, mode select, density/position faders.

---

## 5. Params (initial list)

- **station**: backend, walk mode, change mode, change every (beats), change probability, step km, freeze on tune, static level, crossfade time, refresh places (trigger)
- **grains**: buffer length, position, pos spread, size, density, jitter, pitch, pitch spread, reverse prob, stereo spread, envelope, feedback, freeze, max density
- **tone**: filter type, cutoff, res, drive, reverb send, reverb size, mix, level, adc mix
- **io**: crow in/out assignments, MIDI device

Save/load psets as normal; favorites saved separately in data dir.

---

## 6. Error handling & robustness

- No network: show "offline" on screen; engine keeps granulating frozen buffer.
- Stream fails / silent > timeout: mark dead, try next (max retries, then back off).
- mpv missing: show install instructions, engine still usable with ADC input.
- Backend schema changed: catch JSON errors, fall back to other backend, log to maiden.
- Never leave orphan mpv processes (cleanup + startup sweep).

---

## 7. Milestones

1. **Spike**: shell-level proof — mpv plays a Radio Garden stream into JACK, manually `jack_connect` into SuperCollider input on norns.
2. **Engine v0**: `Engine_Pollen.sc` with circular buffer + GrainBuf + freeze, driven by ADC input; params wired.
3. **Backend + cache**: Radio Garden places/channels/stream resolve, async curl, cache on disk; radio-browser fallback.
4. **Player**: single mpv instance managed from Lua, routing, failure detection.
5. **Walker + clock**: random/nearest/drift modes, clock-synced changes, freeze-on-tune.
6. **Crossfade**: dual mpv, static burst.
7. **UI**: world map page, grains page.
8. **Extras**: crow/grid/MIDI, favorites, remaining walk modes (antipode, sun), CPU tuning on CM3.
9. **Release**: README, install notes, norns community catalog submission.

---

## 8. Open questions

- Engine input: route mpv into SuperCollider inputs directly, or into crone so the norns input levels/monitor apply? (Decide after spike, check `jack_lsp`.)
- Default backend for a public release: radio-browser (open) vs Radio Garden (nicer data, unofficial).
- Mono vs stereo grain buffer on CM3.
- Whether softcut should be used for a secondary "tape" layer.
- At $HOME/projects/terrarium, we have tools/norns-web as a layer to bring a script running on norns to the web. It's barebones and might not fit the requirements of pollen but could serve as inspiration or a starting point.
- How could we design a nice GUI that is visually appealing and user-friendly close to the theme but also functional instead of a bunch of parameters and controls?

## 9. References

- Radio Garden unofficial OpenAPI: <https://github.com/jonasrmichel/radio-garden-openapi>
- Go client/CLI: <https://github.com/jonasrmichel/radio-garden-go>
- radio-browser API: <https://api.radio-browser.info>
- mpv on norns via JACK (precedent): <https://github.com/schollz/norns.online>
- norns scripting reference: <https://monome.org/docs/norns/>
- Inspiration: Make Noise Morphagene, Endorphin.es Evil Pet
- mi-UGens: <https://github.com/carlosedp/norns-mi-UGens>
- terrarium: <https://github.com/carlosedp/terrarium>
