# <img src="doc/img/icon.svg" alt="" width="40" height="40" align="top"> pollen

🌾 The world's radio, carried on the wind, scattered as grains. A live granular instrument for
[monome norns](https://monome.org/docs/norns/).

**[Try it in your browser](https://carlosedp.github.io/pollen/)**: the real script, on
[norns-web](https://github.com/carlosedp/norns-web).

Pollen grains and radio waves both cross the planet through the sky and land far from where they
started. pollen will tune into live radio stations around the globe, wander from one to the next on
the wind, and catch each one on a reel that it scatters as grains, in the spirit of Make Noise
Morphagene and Endorphin.es Evil Pet. See [docs/DESIGN.md](docs/DESIGN.md) for the idea and
[docs/SPEC.md](docs/SPEC.md) for the plumbing.

> **Version 0.2 (in development).** The radio plays: stations from radio-browser.info, the wind
> carrying you between them, each one caught on the reel and scattered as grains. The globe view
> and the seed vault come next. The engine passes its tests on a real SuperCollider server and the
> radio plays in the browser, but nothing has run on a norns yet.

## Install

From the maiden REPL:

```
;install https://github.com/carlosedp/pollen
```

The radio needs **mpv** and **socat** on the norns (over ssh: `sudo apt install -y mpv socat`;
mpv brings its ffmpeg libraries along). Without them pollen still plays, on the norns input, and
the screen says what's missing. mi-UGens are optional: with them, the reverb is MiVerb, the reverb
from Clouds and Rings; without them, FreeVerb2.

## Controls

| Control      | Does                                                                                     |
| ------------ | ---------------------------------------------------------------------------------------- |
| E1           | choose a part: wind, catch, scatter, tint, tone, air                                     |
| E2, E3       | that part's two macros (their names and bars show for a moment while you turn them)               |
| K3           | its gesture: drift (wind), press the reel (catch), a burst (scatter), backwards (tint), a fade (tone), hold the haze (air) |
| hold K2 + E2 | its variety: the wind (wind), reel length (catch), grain envelope (scatter), scale (tint), media (tone) |
| hold K1      | peek: every part and where its macros are, and the station                               |
| hold K1 + K2 | back to the station before                                                               |

Each part has two macros (E2 on the left, E3 on the right), a gesture (K3) and a variety (hold
K2, turn E2). The bars beside the names show where each macro is.

**wind**: when and where the radio moves to the next station.
- *pace* (E2): how often it moves on by itself. All the way left (where it starts) it only moves
  when you drift (K3); then every 10, 5, 2 or 1 minutes, or every 30 seconds.
- *reach* (E3): how far a move goes. Left stays close, a city or two away; right crosses
  continents.
- K3 *drift*: move on to the next station now.
- variety, *the wind*: a breeze goes to one of the nearest stations, a trade wind keeps one
  direction, an eddy wanders, a gust goes anywhere, the far side goes to the other side of the
  world and back.

**catch**: the reel, the loop of tape the radio is recorded onto and the grains are read from.
- *position* (E2): where on the reel the grains are read. Left is just behind the recording, so you
  hear the station almost live; right reaches back into what was caught seconds ago, and the
  grains come from a wider stretch of it.
- *feedback* (E3): how much of the grains is recorded back onto the reel with the radio. Left: the
  reel holds only the radio. Right: the grains pile up on themselves into smears and drones.
- K3 *press*: stop recording, so the reel holds what it has and the grains keep playing it (K3
  again releases it).
- variety, *reel length*: 4, 8, 15, 30 or 60 seconds of tape.

**scatter**: the grains themselves.
- *density* (E2): how many: from one every two seconds to 40 a second, looser in time and wider
  in stereo as there are more.
- *size* (E3): how long each one is: from 20 ms, a click or a buzz, to 2 s, a long overlapping
  wash.
- K3 *burst*: four times as many for a moment.
- variety, *envelope*: the shape of each grain. Bell is smooth, pluck starts sharp and dies away,
  block is square and clicky.

**tint**: the pitch of the grains.
- *pitch* (E2): from two octaves down (left) to two up (right); the middle plays them as
  recorded. It snaps to the notes of the scale.
- *spread* (E3): how much each grain's pitch wanders from that, up to an octave. Past the middle,
  some grains also play backwards.
- K3 *flip*: most grains play backwards (K3 again turns them around).
- variety, *scale*: octaves, fifths, major, minor, chromatic, or free (no snapping).

**tone**: the color of the sound.
- *color* (E2): one filter knob, like a DJ mixer's. The middle is open. Turn left and a low-pass
  closes, darker and muffled. Turn right and a high-pass opens, thinner. It rings more toward
  either end.
- *drive* (E3): saturation, from clean to crunchy.
- K3 *fade*: like a shortwave signal fading: for a moment the sound sinks and darkens, then
  comes back.
- variety, *media*: what the sound passes through, after Beads: digital (clean), vintage (a
  lo-fi sampler), clean tape, dirty tape.

**air**: the space around it, and the final mix.
- *space* (E2): how much of the grains goes to the reverb, and how big the room is.
- *mix* (E3): left is the radio alone, as it plays; right is the grains alone; between them, both.
- K3 *haze*: hold the reverb's tail so it hangs on (K3 again lets it go).

**The wind** picks the next station: a *breeze* drifts to one of the nearest, a *trade wind*
carries on along one bearing, an *eddy* wanders, a *gust* goes anywhere, the *far side* jumps to
the other side of the world and back. While the next station loads, the last one keeps playing. Once it's really playing, the two
crossfade over one pass of the reel, so the head writes the new station over the old a little
more each moment and the grains travel from one place to the other. (In PARAMS, *handover* can
instead press the reel while tuning and crossfade quickly, and *static while tuning* adds some
hiss.) A station that doesn't play in time is skipped. Its name and place show as you arrive (and on a K1 peek).

The screen has two halves. On the left, the globe: every station is a dot, the one playing is at
the middle sending out radio waves as loud as it is, the wind's last moves are its trail, and
while tuning the station being tried blinks at the end of a dotted path. On the right, the reel
laid flat like tape: the waveform of what it caught, with the write head sweeping it (the newest
sound brightest behind it; what isn't caught yet is a dotted line). The bracket under the tape is
where the grains are read from (position). The grains leave the tape from there, up when they play
forwards and down when backwards, faster the higher they're pitched; silence throws none. Pressed,
the head stops and the whole tape holds evenly lit. The haze over it is the reverb. Every
macro, variety and gesture is also in PARAMS, so it saves with PSETs and can be MIDI-mapped.

## How it's built

```
pollen.lua               the script: parts, params, controls, the picture
lib/sound.lua            every macro -> engine parameter mapping (where the sound is tuned)
lib/view.lua             the screen: the globe and the stations, the tape and the grains
lib/radio.lua            the radio: tuning a station (press, static, load, crossfade, release)
lib/stations.lua         the stations, from radio-browser.info, cached on the norns
lib/player.lua           two mpv players, over JACK into the engine, driven through socat
lib/walker.lua           the wind: where to go next (great circles, nearest, antipodes)
lib/json.lua             JSON, decode and encode
lib/Engine_Pollen.sc     the engine: writer -> reel -> grains -> filter, drive, media, reverb, limiter
lib/Engine_Pollen.js     the same engine for the browser (norns ignores it)
lib/Engine_Pollen/       MiVerb as WebAssembly, for the browser (from norns-mi-UGens)
tools/norns-web/         the script in a browser (a git subtree of carlosedp/norns-web)
test/                    the Lua smoke test, the browser engine's offline render, the engine on scsynth
docs/                    SPEC.md (the plumbing) and DESIGN.md (the idea and the decisions)
```

## Development

`make` lists the tasks:

```
make web       # the script in a browser, reloading on save: http://localhost:8800/
make test      # the Lua smoke test and the browser engine's offline render
make test-sc   # the SuperCollider engine on a real scsynth, in a container (podman or docker)
make deploy    # copy to a norns over ssh (NORNS=we@<ip> if norns.local doesn't resolve)
```

`tools/norns-web` is a git subtree: `make norns-web-pull` updates it, `make norns-web-push
BRANCH=...` sends changes back.

## License and credits

pollen is made by [Voltage Foundry Modular](https://vfmod.com). © 2026 Voltage Foundry Modular.

- **The code** is free software under the GNU GPL v3.0 (see [LICENSE](LICENSE)).
- **Ideas from** Émilie Gillet's Mutable Instruments Clouds and Beads (their code is MIT): the
  media stage follows Beads' four. Inspired by Make Noise Morphagene and Endorphin.es Evil Pet.
- **The reverb**, when installed, is MiVerb from Volker Böhm's
  [mi-UGens](https://github.com/v7b1/mi-UGens) (GPL-3.0); the browser carries it as WebAssembly,
  built by [norns-mi-UGens](https://github.com/carlosedp/norns-mi-UGens) (`lib/Engine_Pollen/BUILDINFO`).
- [wasmoon](https://github.com/ceifa/wasmoon) (MIT) is vendored in `tools/norns-web`.
- **The stations** come from [radio-browser.info](https://www.radio-browser.info), a community
  database; pollen fetches its list at most once a week and identifies itself when it does. The
  streams are the stations' own; pollen plays them live and never redistributes them.
- Mutable Instruments, Make Noise, Endorphin.es, monome, norns and Radio Garden are trademarks of
  their owners, named only to say what pollen works with or was inspired by. No affiliation or
  endorsement is implied.

## To do on hardware

- [ ] the engine loads and sounds; CPU on a CM3 with the densest grains and the radio playing
- [ ] mpv into SuperCollider over JACK: `jack_lsp -c` while a station plays should show
  `pollen_a:out_0 -> SuperCollider:in_1` (`P.JACK_TO` in `lib/player.lua` if the names differ)
- [ ] mpv's CPU with two players, and how long a station takes to start
- [ ] the first fetch and parse of the stations on a norns (about 2 MB of JSON)
- [ ] tune the macros by ear (`lib/sound.lua`)
