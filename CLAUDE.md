# pollen

A norns script: live radio from around the globe, caught on a reel and scattered as grains. The
idea, vocabulary and decisions are in docs/DESIGN.md (read it before changing behavior); the
plumbing (backends, mpv, JACK, walker) is docs/SPEC.md. README.md is the player's view.

**Status:** v0, in development. The reel engine (`lib/Engine_Pollen.sc`) and its browser twin play
on the norns input / a demo broadcast; five parts (catch, scatter, tint, tone, air) drive it. Not
yet: the radio (backends, mpv player), the walker and its globe view, the seed vault, crow/grid.
Never run on a norns: the Lua passes the smoke test; the engine passes `make test-sc` on scsynth
3.13 (with the FreeVerb2 fallback: MiVerb is untested in SuperCollider).

## Commands

```
make test      # lua test/smoke.lua + node test/engine.mjs; run after every Lua or engine change
make test-sc   # test/sc/run.sh: the .sc on a real scsynth in a container; after every .sc change
make web       # the real script in a browser at http://localhost:8800/
```

## Rules that are easy to break

- **norns runs Lua 5.3.** No `<const>`/`<close>` or other 5.4+ features (the dev machine has Lua
  5.5, norns-web runs 5.4; neither catches 5.4-only code).
- **`include()` is `dofile`:** every call returns a fresh copy. Stateful modules (`lib/bloom.lua`)
  are included only from `pollen.lua`. `lib/sound.lua` is pure.
- **Lua owns every macro-to-parameter mapping** (`lib/sound.lua`); the engine exposes raw
  parameters only, all through one command, `set(key, value)`, sent to a group holding every
  synth. A new parameter is a SynthDef argument, a key in `Engine_Pollen.js`'s `DEFAULTS` and
  handled in its worklet; the smoke test fails if Lua sends a key either engine lacks.
- **Engine changes go in both engines:** `lib/Engine_Pollen.sc` and `lib/Engine_Pollen.js` (the
  worklet mirrors the SynthDefs: SC's own filter formulas, Lag's 60 dB in t, the same limiter).
  `test/engine.mjs` and `test/sc/engine.scd` make the same checks on each; keep them in step.
- **Never write mi-UGens class names in the .sc file.** Look them up with `\MiVerb.asClass`; a
  missing class fails sclang for every norns script. Without mi-UGens the engine must still play.
- **K1 is hold-only.** A quick K1 tap opens the norns system menu.
- **No numbers on screen.** The bloom is the readout; names show briefly on touch; hold K1 peeks.
- Params group sizes are declared up front (`counts` in `add_params`); the smoke test checks them.
  Add new options at the end of their lists (`lib/sound.lua`), so saved PSETs keep their choices.
- `tools/norns-web` is a **git subtree** of github.com/carlosedp/norns-web: keep it generic,
  commit changes to it apart from pollen's, send them back with `make norns-web-push BRANCH=...`.
  `git subtree` here needs GNU `dirname` (the Makefile handles it; uutils' breaks the prefix).
- **Seeds are private:** never commit recorded broadcasts; demo audio must be ours or licensed.
- Credit borrowed ideas or code (Clouds/Beads MIT, Graintopia MIT) in README and code comments.
  danielrigler/grains has no license: ideas only, no code.

## Related repos

- `~/projects/terrarium`: the sibling script; its conventions (parts, macros, peek, norns-web,
  plugin) are the model here.
- `~/projects/norns-web`: the browser runtime (its own repo; pollen carries it as a subtree).
- `~/projects/norns-mi-UGens`: mi-UGens for norns and as WebAssembly (`lib/Engine_Pollen/` holds
  MiVerb from it).

## Environment

WSL2 (Ubuntu) on Windows; `gh`, `podman`, `lua`, `node` are available. `rm` is aliased to prompt:
use `command rm` in scripts.
