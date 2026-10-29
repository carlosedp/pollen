# <img src="doc/img/icon.svg" alt="" width="40" height="40" align="top"> pollen

🌼 The world's radio, carried on the wind, scattered as grains. A live granular instrument for
[monome norns](https://monome.org/docs/norns/).

**[Try it in your browser](https://carlosedp.github.io/pollen/)**: the real script, on
[norns-web](https://github.com/carlosedp/norns-web).

Pollen grains and radio waves both cross the planet through the sky and land far from where they
started. pollen will tune into live radio stations around the globe, wander from one to the next on
the wind, and catch each one on a reel that it scatters as grains, in the spirit of Make Noise
Morphagene and Endorphin.es Evil Pet. See [docs/DESIGN.md](docs/DESIGN.md) for the idea and
[docs/SPEC.md](docs/SPEC.md) for the plumbing.

> **Version 0 (in development).** The reel and the grains play, on the norns input (in the browser,
> a made-up broadcast). The radio, the globe and the seed vault come next. The engine passes its
> tests on a real SuperCollider server, but nothing has run on a norns yet.

## Install

From the maiden REPL:

```
;install https://github.com/carlosedp/pollen
```

Nothing else is needed for v0. mi-UGens are optional: with them, the reverb is MiVerb, the reverb
from Clouds and Rings; without them, FreeVerb2.

## Controls

| Control      | Does                                                                                     |
| ------------ | ---------------------------------------------------------------------------------------- |
| E1           | choose a part: catch, scatter, tint, tone, air                                           |
| E2, E3       | that part's two macros (their names show for a moment while you turn them)               |
| K3           | its gesture: press the reel (catch), a burst (scatter), backwards (tint), static (tone), hold the haze (air) |
| hold K2 + E2 | its variety: reel length (catch), grain envelope (scatter), scale (tint), media (tone)   |
| hold K1      | peek: every part and where its macros are                                                |

| Part    | E2 · E3          | What it does                                                                  |
| ------- | ---------------- | ----------------------------------------------------------------------------- |
| catch   | memory · cross   | how far back into the reel the grains reach; how much of them is written back in (cross-pollination) |
| scatter | density · size   | how many grains, how long each one is                                         |
| tint    | pitch · spread   | their pitch in the scale; how far it scatters, and past the middle, some backwards |
| tone    | color · drive    | one-knob filter (left closes a low-pass, right opens a high-pass); saturation |
| air     | space · mix      | the reverb; from the live input alone to the grains alone                     |

The screen is the bloom. The reel is a ring; the write head sweeps around it; grains leave it as
pollen, from where they're read (the short arc inside the ring), flying as fast as they're
pitched. Pressed, the sweep stops and the ring holds still. The haze around it is the reverb. Every
macro, variety and gesture is also in PARAMS, so it saves with PSETs and can be MIDI-mapped.

## How it's built

```
pollen.lua               the script: parts, params, controls, the picture
lib/sound.lua            every macro -> engine parameter mapping (where the sound is tuned)
lib/bloom.lua            the bloom: the reel as a ring, the pollen
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
- Mutable Instruments, Make Noise, Endorphin.es, monome, norns and Radio Garden are trademarks of
  their owners, named only to say what pollen works with or was inspired by. No affiliation or
  endorsement is implied.
