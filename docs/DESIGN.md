# pollen: design notes

The identity, sound engine, screen, dependencies and dev environment for pollen, worked out on top
of [SPEC.md](SPEC.md) (October 2026). SPEC.md covers the plumbing (backends, mpv, JACK, walker); this
file covers what pollen _is_ and the decisions that shape it. Where the two disagree, this file wins
and SPEC.md should be updated.

## The idea

**Pollen grains and radio waves both cross the planet through the sky, invisibly, and land
somewhere far from where they started.** A flower doesn't aim its pollen; the wind carries it. A
station doesn't aim its signal either; skywave bounces it off the ionosphere to wherever it lands.

pollen joins the two. The globe is a garden. Every station is a flower in bloom, broadcasting. The
wind carries you from flower to flower. At each one you catch some pollen, a few seconds of its
sound, and you scatter it as grains. Grains from the flowers you've passed mix in the reel, so it
holds a little of every place you've been: cross-pollination.

The name already tells this story (Radio Garden → garden → pollen), so we keep **pollen**.

### Vocabulary

Like terrarium, the code keeps working names and the screen, PARAMS names and manual use the
garden's names. Users never see "buffer" or "feedback".

| on screen / in the manual | in the code         | what it is                                                |
| ------------------------- | ------------------- | --------------------------------------------------------- |
| flower, bloom             | station             | a live stream at a place on the globe                     |
| the wind                  | walker              | what picks the next station, and how                      |
| drift                     | station change      | moving to the next flower (the globe turns, static plays) |
| the reel                  | circular buffer     | the stations you caught, as splices                       |
| catch                     | record / write head | taking pollen from the current flower                     |
| press                     | freeze              | a pressed flower: the reel stops recording and keeps it   |
| scatter                   | grain density, size | how the pollen is thrown                                  |
| cross-pollinate           | feedback / layering | grains written back into the reel, over the next station  |
| static, between flowers   | tuning noise        | the sky's hiss while the wind is moving you               |
| the herbarium             | favorites           | flowers you kept (K1 + K3)                                |
| the seed vault            | offline recordings  | stations kept as files, to play with no network           |

Wind kinds (the walk modes from SPEC §4.6, renamed for the screen):

| wind       | walk mode   | moves                                                 |
| ---------- | ----------- | ----------------------------------------------------- |
| breeze     | `nearest`   | to the nearest flower you haven't visited             |
| trade wind | `drift`     | steadily along one bearing                            |
| eddy       | `wander`    | a random walk, the bearing turning a little each step |
| gust       | `random`    | anywhere at all                                       |
| far side   | `antipode`  | to the other side of the world, and back              |
| dusk       | `sun`       | along the line where evening is falling right now     |
| homeland   | `country`   | within one country                                    |
| herbarium  | `favorites` | among the flowers you kept                            |
| still air  | `manual`    | only when you push it (K3)                            |

### Look

- **Icon:** a pollen grain that is also a globe: a round grain with short spikes (pollen under a
  microscope is spiky), meridians across its face, two radio arcs coming off one side. 32×32 pixel
  art, `shape-rendering="crispEdges"`, the same way terrarium's icon is made.
- **Palette:** pollen gold (`#f0c43a`, `#d9a441`, `#a8741a`) on night-sky blue-black (`#0b1020`),
  a pale ink for the land (`#c9d0ca`). It sits next to terrarium's amber screen and earth tones as a
  sibling.
- **Tagline:** "the world's radio, carried on the wind, scattered as grains."
- **norns-web page:** the device under a night sky (as terrarium's), with one action button,
  **Drift**, that sends the wind on.

## Sound engine

### What to take from Morphagene and Evil Pet

- **Morphagene:** a long reel cut into splices; _gene size_ (grain size), _slide_ (where in the
  splice), _vari-speed_ (pitch and direction, reverse included), _morph_ (overlap, from gaps to a
  dense cloud), _organize_ (which splice). pollen's reel works the same way, and **each station
  you catch becomes a splice**. _Organize_ is picking which flower's pollen you're scattering:
  the one you're at now, or one from three stations back.
- **Evil Pet:** live input as the source; you catch a moment, hold it, and play it. In pollen,
  catching and pressing a phrase off a live station is the main gesture (K3).

### Options

| option                                    | for                                                                                                                                                                                                   | against                                                                                                                                                     |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Own engine: `BufWr` reel + `GrainBuf`** | long reel (up to about 60 s; stereo at 48 kHz is about 23 MB), position measured back from the write head, splices, freeze, and feedback are all ours. Core SuperCollider only, no deps, cheap on CM3 | we write and tune it                                                                                                                                        |
| **MiClouds** (live granulator)            | Clouds' real sound: texture, its four modes (granular, pitch-shifter, looping delay, spectral), and its built-in freeze, feedback and reverb                                                          | the buffer is about a second as shipped (see below). It's a live granulator, not a reel, so it can't hold several stations                                  |
| **MiBeads**                               | a lovely sound, clocked or free grains, a delay mode, its tape and vintage-digital "media", and a reverb                                                                                              | 4 s as shipped (see below). Never pass `seed` (terrarium's rule)                                                                                            |
| Graintopia (infinitedigits)               | MIT: we can borrow code, with its notice                                                                                                                                                              | sample-based, not live input                                                                                                                                |
| danielrigler/grains                       | a good reference for what a norns granular script can feel like                                                                                                                                       | **no license in the repo, so no rights to its code.** Read it for ideas, but don't copy or port it. Where it builds on Graintopia, go to Graintopia instead |

### Bigger buffers for Clouds and Beads

Their buffers are small because of the STM32's RAM, not the DSP. In the source (norns-mi-UGens
`work/mi-UGens`):

- **Clouds: easy.** The wrapper (`projects/MiClouds/MiClouds.cpp`) allocates the buffers itself:
  `largeBufSize = 118784` and `smallBufSize = 65536-128` bytes, passed to
  `GranularProcessor::Init(large, size, small, size)`, which splits whatever it gets among the
  channels. 118784 bytes is about 0.9 s of 16-bit stereo at Clouds' 32 kHz, and roughly 2–4× that
  in its mono or lo-fi modes. A larger buffer is a change to that one number, or better, a new UGen
  input (`bufsize`, a scalar), in our norns-mi-UGens fork. To check by ear: Clouds' position and
  size knobs span the whole buffer, so at 30 s they get coarse, and its grain count stays fixed
  (32–40). 8–15 s is probably the sweet spot. The spectral mode's buffers come from the small
  block and don't need to grow.
- **Beads: harder.** Its 4 s (`kDelayBufferSizeBits = 768 * 1000 * 8`: 768 KB at 48 kHz 16-bit
  stereo; lower media qualities run at 24/32 kHz with less resolution, so they hold more) is
  fixed when it's compiled: the `DelayLine<resolution, max_delay, …, bank_size = 262144,
num_banks = 3>` templates, `max_delay`, and the wrapper's `kDelayMemSize = 768 * 1024`. Growing
  it means patching those constants together and rebuilding both the native and the WebAssembly
  builds. It's doable as a build flag in norns-mi-UGens (`--beads-seconds N`), but it's a fork of
  Beads' DSP that has to be listened through.

**Worth it?** A longer Clouds, yes: it's cheap, so it's worth a spike for the _clouds_ species
(below). A longer Beads, not for v1. Pollen's reel already does the long-memory part. What Beads
adds is its character, and the ideas behind that character can be borrowed with credit:

- **From Clouds:** _texture_ (the grain window morphing from a rectangle to a smooth bell, then
  diffusion), and the spectral mode as a later _species_.
- **From Beads:** the _media_ (dirty tape, clean tape, vintage digital, digital) as a quality
  control after the grains, and grains clocked to a tempo or free.

Émilie Gillet's STM32 code (Clouds, Beads) is MIT: borrowing ideas, or code with its notice, is
fine. Credit goes in the README and THIRD-PARTY-NOTICES, as terrarium does. Mutable's guidelines
for derivative works ask that the products not be named after the modules, so pollen's on-screen
names stay garden names (a _clouds_ species is described as "after Clouds").

### Decision

**Our own reel engine is the core, and the mi-UGens add color.**

1. **The reel** (`BufWr`, stereo, 8–60 s, splice markers kept in Lua) and **grains** (`GrainBuf`
   ×2 for stereo, triggers blended from `Impulse` and `Dust`, grain count capped by `max_density`)
   do what SPEC §4.5 asks: the Morphagene parameters, feedback through a soft clip, and freeze.
   This part only needs core SuperCollider, so pollen makes sound without any installs (on ADC
   input, if mpv is missing).
2. **Air: MiVerb** (Clouds' and Rings' reverb, which is cheap) when mi-UGens are installed;
   FreeVerb2 otherwise. Look the class up with `\MiVerb.asClass`, never by name (terrarium's rule:
   a missing class breaks sclang for every script).
3. **Ideas from Clouds and Beads in the reel engine, credited:** a _texture_ window morph and a
   _media_ stage (tape wow and saturation, vintage-digital bit depth and rate) after the grains.
4. **Later (v1.x): a "species" switch** for the grain stage: _pollen_ (the reel), _clouds_
   (MiClouds with a larger buffer, spectral mode included) and _beads_ (MiBeads). It's terrarium's
   swappable-module idea, applied to one slot. It's not in v1, because two granulators at once
   won't fit CM3's CPU and the reel is what makes pollen pollen.

## The screen

The scene is the readout, as in terrarium: no numbers. Station, city and country are the only
text, shown when you arrive and on a K1 peek.

### Two views of one scene

**Globe (where).** An orthographic globe, not the spec's flat map: a sphere of land dots that
turns. The dots are precomputed unit vectors (`worldmap.lua`, about 800–1200 points). A frame is
one rotation (9 multiplies per point) and a back-face test, which is cheap enough for CM3 at
15 fps.

- Flowers are dim dots, subsampled. The current flower sends out **radio rings** that spread and
  fade; their brightness follows the stream's input level (the amplitude poll), so a dead stream
  visibly goes quiet.
- **Drifting** turns the globe along the great circle to the next flower (a slerp over
  `xfade_time`) and draws the arc, while the static plays. Earlier arcs stay as faint trails: the
  wind's route.
- **Night side:** land past the terminator (from UTC; terrarium's `daylight.lua` has the maths)
  is drawn dimmer. The _dusk_ wind visibly follows that line.
- **Pollen** comes off the current flower: one particle per grain (simulated in Lua from density
  and size, not polled per grain). It drifts downwind (along the walk bearing) and lives as long as
  the grain does.

**Bloom (what).** A close-up of the flower. **The reel is drawn as a ring**: a circular buffer
drawn as a circle, which is also a flower head and a radio dial. The write head sweeps around it
like a radar. Splices are petals, one per station caught, and pressed ones are drawn solid. Grains
are pollen leaving the ring:

| what moves       | how it shows                                           |
| ---------------- | ------------------------------------------------------ |
| position (slide) | the angle behind the write head the pollen leaves from |
| size             | how far a grain flies before it fades                  |
| density          | how many fly                                           |
| pitch            | how fast they fly (lower is slower)                    |
| reverse          | grains fall back into the ring instead of out          |
| press (freeze)   | the sweep stops and the pollen hangs in the air        |
| cross-pollinate  | grains arc back and land on the ring again             |
| air (reverb)     | a haze around the bloom                                |

### Controls (terrarium's grammar)

E1 picks a part. The wind's part shows the globe; the others show the bloom, with a quick zoom
between them. Each part has two macros, and their names show for a moment while you turn them.

| part    | E2 / E3                                  | K3 gesture      | hold K2 + E2 (variant) |
| ------- | ---------------------------------------- | --------------- | ---------------------- |
| wind    | pace (how often) · reach (how far)       | drift now       | wind kind              |
| catch   | memory (how far back) · cross (feedback) | press / release | splice to scatter from |
| scatter | density · size                           | a burst         | envelope shape         |
| tint    | pitch (in the key) · spread / reverse    | flip direction  | scale                  |
| air     | space · mix                              | static burst    | filter type            |

- **K1 is hold-only** (a tap opens the system menu). Hold K1 to peek at the station and place
  name, the reel's petals and the wind. **K1 + K2:** go back a flower (history). **K1 + K3:** keep
  this flower in the herbarium.
- **pace** runs from "still air" through clocked divisions (every 64 beats … every 4) to free and
  fast. **reach** sweeps each wind's own range (step km, or how far an eddy turns).
- Everything is in PARAMS too (SPEC §5), for PSETs and MIDI.

This replaces SPEC §4.8's three param pages.

## Dependencies

Use [norns-deps](https://splines.cc/scripts/norns-deps/) (`github.com/vehka/norns-deps`). It checks
on load, asks on screen before installing, shows progress, and has a manifest to uninstall from,
which is what SPEC §2 wants (no silent installs).

```lua
local deps = include("lib/deps")
local d = deps.new { name = "pollen", dir = _path.data .. "pollen/deps" }
d:add { id = "mpv",   label = "mpv",   check = "mpv",   pkg = "mpv",   why = "plays the radio" }
d:add { id = "socat", label = "socat", check = "socat", pkg = "socat", why = "talks to mpv" }
d:add { id = "mi",    label = "mi-UGens", check_ugens = "MiVerb",
        ugens = "https://github.com/carlosedp/norns-mi-UGens/releases/latest/download/mi-UGens-norns.tar.gz",
        why = "the reverb (optional)" }
```

- **mpv and socat are required for the radio. mi-UGens are optional:** without them, the air is
  FreeVerb2.
- Its repo has no license file, but its author has allowed public use (confirmed with them,
  October 2026). Vendor it in `lib/deps.lua` with a line saying where it came from, and ask for a
  license file upstream so the permission is on record. Still to check: how it handles `sudo` on
  a stock norns, and whether its `ugens` step should defer to our tarball's `install.sh`.
  That script moves older mi-UGens installs aside, because duplicate classes break sclang. Its
  `ugen_conflicts()` may cover the same ground.
- Note the size on the install prompt: mpv brings its ffmpeg libraries along.

## The seed vault: radio for offline

Pollen makes seeds. The **seed vault** keeps short recordings of stations on the norns, so pollen
can play with no network: on a plane, at a gig with bad wifi, or when the APIs are down. (A seed
vault keeps seeds from all over the world for later, which is exactly this.)

- **A seed** is a raw recording of a stream: `curl --max-time <len> <url> | head -c <cap> > <file>`.
  The bytes are saved as they arrive, with no decoding or re-encoding, so it costs next to no CPU,
  and an Icecast mp3/aac/ogg stream is a playable file as it is. `head -c` is a hard size cap per
  seed (below), since a live stream has no length for curl to check. Next to it goes a sidecar
  `<file>.json` with the station, place, country, lat/lon, bitrate and date. Files live in
  `_path.audio .. "pollen/seeds/"` (`dust/audio`, so TAPE and other scripts can see them too).
- **Gathering** (PARAMS > seed vault, and a K-gesture):
  - _keep this one_ (hold K3 on the wind's part): records the current station for `seed length`
    (30–120 s), alongside listening, from a second `curl` on the same URL.
  - _forage_ (a trigger, with a count): the wind visits N stations in the background, with no
    sound, and keeps a seed from each, preferring places the vault doesn't have yet. It runs one
    station at a time with timeouts, so it never competes with the playing stream.
  - _gather while listening_ (off / on): every station you stay on longer than `seed length`
    leaves a seed.
- **Playing seeds:** a third backend, `seeds`, whose "stations" are local files. The player loads
  them in mpv exactly like a URL (`loadfile <path>`), so routing, crossfade, freeze-on-tune and the
  engine are all unchanged. The walker treats them as places, so every wind works offline.
  **No network → it switches to `seeds` by itself**, and back when the network returns.
- **On the globe** seeds are drawn as hollow dots where they were gathered, so you can see how
  much of the world you've collected. Seeds of herbarium flowers are kept when the vault is pruned.
- **Keeping the reel** (separate from seeds): _press and keep_ writes the reel's current contents
  to `dust/audio/pollen/reels/<date>.wav` (`Buffer.write`), the way a Morphagene saves a reel.
  That's your granular moment, not a station, and it can be loaded back into the reel later.
- **Seeds are private.** They're recordings of broadcasts, for personal use on your own device.
  pollen never uploads or shares them, and the repo never ships any. Demo audio for the browser
  and tests has to be our own or properly licensed.

### How much space: always say before gathering

A norns keeps everything on a small SD card (or the CM3's eMMC), shared with every script and
TAPE. So pollen **shows the estimate and the free space and waits for a yes before any gathering
that writes more than one seed**, and never fills the card.

- **The estimate:** a stream's size is its bitrate × time. radio-browser gives each station's
  `bitrate`, and Radio Garden doesn't, so an unknown bitrate counts as 128 kbps for the estimate
  and 320 kbps for the upper bound.

  | bitrate             | 1 min of seed | 50 seeds × 60 s | 200 seeds × 60 s |
  | ------------------- | ------------- | --------------- | ---------------- |
  | 64 kbps (aac, talk) | 0.5 MB        | 24 MB           | 96 MB            |
  | 128 kbps (most mp3) | 0.96 MB       | 48 MB           | 192 MB           |
  | 320 kbps (the most) | 2.4 MB        | 120 MB          | 480 MB           |

  (kbps × 1000 / 8 bytes a second: 128 kbps is 16 KB/s, 0.96 MB a minute.)

- **Before a forage** the screen says, for example: _"forage 50 seeds of 60 s: about 48 MB (up to
  120 MB). The vault has 210 MB, the card 3.1 GB free. K3 gather · K2 cancel"_. The sizes come
  from the stations it picks (their bitrates), the vault's size from its files, and the free space
  from `df -k` on `_path.audio`. _gather while listening_ shows the same line when you switch it on,
  per hour of listening at the current station's bitrate.
- **Hard limits, so an estimate can't be wrong by much:**
  - each seed is capped at `length × 320 kbps` bytes (`head -c`), whatever the stream claims;
  - `vault size` (default 500 MB, from 100 MB to 4 GB) is the most the vault holds. When it's full,
    the oldest seeds go first (herbarium seeds last), and the prompt says how many would go;
  - pollen always leaves `keep free` (default 1 GB) on the card. A gathering that would cross it is
    stopped and the screen says why. A forage in progress stops when free space drops below it.
- **PARAMS > seed vault** shows the vault's seed count and size, the card's free space, the estimate
  for the current forage settings, and _clear the vault_ (with a confirm).

In norns-web, seeds can come later. The `curl` handler could store CORS streams' bytes in the
browser's IndexedDB, and the dev server could write them to disk.

## Playing it without a norns

### What norns-web does today, and what pollen needs

norns-web (terrarium's `tools/norns-web`) runs the real Lua (wasmoon, Lua 5.4) with the screen,
encoders, keys, clocks, metros and PARAMS, plus an engine stand-in in JS. pollen also needs:

| pollen needs                         | norns-web today             | generic addition                                                                                                                |
| ------------------------------------ | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `curl` for the station APIs          | `system_cmd` is logged only | a **`system_cmd` handler hook**: a script's stand-in registers JS handlers by pattern. A built-in `curl` handler does a `fetch` |
| mpv playing a stream into the engine | nothing                     | the handler for pollen's mpv IPC lines plays an `<audio crossOrigin>` element into the engine's input                           |
| amplitude and write-head polls       | stub                        | **polls**: a stand-in publishes values and `poll` callbacks fire                                                                |
| CORS for streams and APIs            | n/a                         | `serve.mjs` **`/proxy?url=`** while developing                                                                                  |

All of these are generic, so norns-web stays script-agnostic, and **pollen's Lua runs unchanged**:
the seam is `norns.system_cmd` / `util.os_capture`, not a browser branch in the script.

### Measured: what a static page can play

On 2026-10-29: radio-browser's API sends `Access-Control-Allow-Origin: *`, and **30 of 39** random
HTTPS stations with geo info sent CORS headers on their streams (about 75%). A stream without
CORS fails to load under `crossOrigin="anonymous"` (an error event, not silence), so the player
marks it dead and the wind moves on, the same path as a dead stream on norns. Radio Garden's API
sends no CORS headers.

So:

- **Local dev (`serve.mjs`):** both backends, every stream, through the proxy.
- **Published page (GitHub Pages):** radio-browser only, CORS streams only. We don't run a public
  proxy for Radio Garden's unofficial API, and doing so wouldn't be polite to them.
- **Default backend for the release: radio-browser.** It's open and works in both places. Radio
  Garden is an option (this answers SPEC §8's open question).

### The engine in the browser: a twin, or scsynth itself?

- **A hand-written twin (terrarium's way):** `Engine_Pollen.js`, with the reel and grains in an
  AudioWorklet (a few hundred lines) and MiVerb from the existing mi-UGens WebAssembly build. It
  works now. The cost is one more copy to keep in step, a cost terrarium already pays three times
  over (.sc, .js, .cpp).
- **Real scsynth in WebAssembly:** [SuperSonic](https://github.com/samaaron/supersonic) runs
  scsynth in an AudioWorklet, speaks scsynth's OSC, and is GPL-3.0-or-later like us. **sclang
  doesn't come along,** so this would play the _same SynthDefs_, compiled to `.scsyndef` by a
  headless sclang in CI, but not the CroneEngine class. The engine would have to follow a
  convention: every `addCommand` is a plain `synth.set(\key, v)` or `buf` op, listed in a small
  manifest the page reads. **Unverified:** whether third-party UGens (mi-UGens) can be compiled in
  statically, whether a Web Audio node can feed its input bus, and whether `b_alloc` / `BufWr`
  work. Spike all three before depending on it.

**Decision (agreed):** write the engine twice to start, `Engine_Pollen.sc` and `Engine_Pollen.js`,
because that's the fastest way to get it playing. pollen's engine is small (one grain SynthDef, a
writer, a filter, a reverb), so the twin is cheap. The scsynth mode is a norns-web project for
later: spike SuperSonic with pollen's `.scsyndef` files there. If it passes, norns-web gets an
**scsynth mode** that removes the twin for any script that follows the convention. That is what
makes norns-web worth more than a terrarium tool.

### norns-web, split out (2026-10-29)

norns-web has its own repo, `~/projects/norns-web` (for `github.com/carlosedp/norns-web`), with its
history from terrarium, a GPL-3.0 license, a `test/hello` example, a headless check
(`lua test/headless.lua <script dir>`) and CI. Scripts carry it as a **git subtree** at
`tools/norns-web/`. terrarium does already, with the same paths as before, so its Pages build,
plugin and art tools are unchanged; `make norns-web-pull` / `make norns-web-push` sync it. For
pollen:

```sh
git subtree add --prefix=tools/norns-web https://github.com/carlosedp/norns-web main --squash
```

On this machine, `git subtree` needs GNU `dirname` first on the PATH: uutils' `dirname` turns
`tools/norns-web/.` into `tools`. norns-web's README explains the workaround.

Next, in norns-web: the generic pieces above (the `system_cmd` hook, a `fetch`-backed curl, the dev
proxy, polls), each with a test script under `test/`. Then the SuperSonic spike, and later a
virtual grid, crow and softcut.

Until pollen's engine runs on a real norns, the headless Lua test (terrarium's
`test/mock_norns.lua` + `smoke.lua` pattern) is the first line of defense: the mocked `system_cmd`
returns canned radio-browser JSON, and mpv IPC is recorded and asserted.

## Changes to SPEC.md this implies

- §4.5: the reel is up to 60 s, with Lua-tracked splices per station, plus an _organize_ control.
  MiVerb (optional) for the air.
- §4.8: one scene in two views (globe, bloom) and five parts with two macros each, instead of
  three param pages.
- §2 / §6: dependencies through norns-deps.
- §8: default backend radio-browser; norns-web is the dev environment (above).
- §4.2 / §6: a `seeds` backend (the seed vault), the automatic switch to it when offline, and
  `dust/audio/pollen/{seeds,reels}`.
- The file layout gains `lib/Engine_Pollen.js` (the browser twin), `lib/seeds.lua`, `lib/deps.lua`
  (norns-deps), `norns-web.json` and `tools/norns-web/` (the subtree).
