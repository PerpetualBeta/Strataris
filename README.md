# Strataris — Galactic Colony Defence

A first-person, voxel-terrain shoot-'em-up for macOS. You fly low over alien
worlds, defend ground installations from waves of attacking craft, and warp on
to the next planet when the skies are clear — chasing a high score across an
endless campaign. *Defender* by way of *Rescue on Fractalus*, with a
period-correct pixelated look.

**The first *native* game in the Jorvik suite** — the others (Star Raiders,
Rescue on Fractalus, Centipede, Mr. Do!, Gauntlet) are HTML/canvas tributes.

## The whole game is about 1 MB — and there are zero asset files

Every pixel and every sound in Strataris is **generated in code**. There are no
textures, no audio files, no 3-D models, no fonts to ship:

- **Terrain** — seamless fractal-noise (fbm) heightmaps, height-banded colour,
  slope shading, distance haze.
- **Ships** — flat-shaded low-poly hulls, a handful of triangles each.
- **Music & SFX** — a from-scratch synthesiser (square/saw/triangle/noise/
  rumble voices, envelopes, a limiter).
- **Radio voice comms** — speech rendered offline and band-pass-filtered into a
  crackly cockpit-radio timbre, with squelch and roger bleeps.
- **Fonts** — a 5×7 bitmap font for the HUD, plus a Core Text rasteriser for
  proportional screens.
- **Particles** — smoke and fire for damaged installations.

The result: the game binary (a universal arm64 + x86_64 build) is **~1.2 MB** —
*smaller than the asset payload of many single web pages*, and it would fit on a
1.44 MB floppy. Genuinely in the 16-bit spirit: demoscene-style "everything from
maths," running as a native Mac app.

> The full shipped `.app` is **~5.7 MB**, because it embeds the
> [Sparkle](https://sparkle-project.org) auto-updater framework (~3 MB) for
> in-app updates. The *game itself* is the ~1.2 MB part.

## The game

- **Fly and fight.** Bank, climb/dive, and throttle a low-flying interceptor
  over procedurally generated terrain. Fire on attacking craft; a fixed
  forward cannon and a tracking scope do the aiming work.
- **Defend the colony.** Each world has ground installations the enemy bombs.
  Lose them all and the run is over.
- **Know your enemy** (points for each):
  - **Drone** — 10 — cheap swarm.
  - **Fighter** — 100 — hunts you and strafes.
  - **Destroyer** — 250 — bombs installations; turns on you if you get close.
  - **Mothership** — 2500 — slow, heavily armoured, appears on a timer.
- **Warp onward.** Clear a planet and warp — a full cockpit cut-scene with
  engine spool, light-streaks, and re-entry — to the next world. The colonies
  are a finite, *named* cluster (Demeter, Tantalus, Boreas, Pandora, Vulcan,
  Vesper), cycled endlessly; your **level** climbs forever and is the mark of
  progression.
- **Cockpit dashboard.** A cohesive instrument panel: flight computer readout,
  LED shield/throttle gauges, an artificial horizon, a chronometer/stardate,
  and a sweeping radar scope tracking surviving craft.
- **Mission briefing & enemy codex.** Reachable from the title screen — a
  scrolling back-story transmission and a rotating-3-D-model database of the
  alien fleet.
- **High-score table.** Name, stardate, score, and level, persisted across
  sessions.

## Run it

```sh
gmake build                 # universal .app via the shared jorvik-release pipeline
open .build/Strataris.app   # fly
```

### Controls

| | |
|---|---|
| **← / →** | steer (bank) |
| **↑ / ↓** | climb / dive |
| **+ / −** | throttle |
| **Space** | fire |
| **R** / **Return** | start · restart · warp (on the cleared-planet screen) |
| **P** | pause |
| **M** | mute |
| **B** / **V** | mission briefing / enemy intel (from the title) |
| **Esc** | back (close briefing/codex) |
| **C** | controller setup |
| **⌘,** | settings (audio, controls, reset scores) |
| **⌘Q** | quit |

A connected game controller (Xbox / DualShock / any Extended Gamepad) is
detected automatically; the left stick steers/pitches and the discrete actions
(fire, throttle, pause, warp) are **rebindable** from the controller sheet.
Keyboard always works as a fallback.

### Hidden feature flags

Off by default; opt in per machine with `defaults write` (relaunch to apply):

```sh
defaults write cc.jorviksoftware.Strataris ShowFPS           -bool true  # FPS readout, top-right
defaults write cc.jorviksoftware.Strataris ScreenshotOnSpace -bool true  # F (or a rebindable gamepad button) saves a 1920×1080 PNG (4× nearest-neighbour) to the Desktop; Space stays fire
defaults write cc.jorviksoftware.Strataris RadialPulseWeapon -bool true  # 3 charges (X, or a rebindable gamepad button) that wipe all enemies — those kills don't score
```

### Headless smoke test

Exercises the hot path (terrain generation + raycaster + a slice of the game
loop) with no window or GPU, and prints timing:

```sh
STRATARIS_SMOKE=1 ./.build/Strataris.app/Contents/MacOS/Strataris
```

On an M3 Max the voxel render runs ~0.9 ms/frame at 480×270 — the framebuffer
is upscaled, nearest-neighbour and aspect-correct (letterboxed), to fill the
window.

## Architecture

The renderer is split CPU (engine) / GPU (present): the CPU voxel engine writes
a low-res packed-RGBA framebuffer, which a runtime-compiled Metal blit shader
uploads as a texture and draws to the drawable. The engine has **no GPU
dependency** (hence the headless smoke test), so it can be re-homed to a Metal
compute shader behind the same seam if it ever needs the headroom.

| File | Role |
|------|------|
| `main.swift` | Entry point; smoke-test vs GUI launch |
| `AppDelegate.swift` | Window (maximised), menu bar, About, Sparkle, input wiring |
| `GameView.swift` | `MTKView` subclass; keyboard capture |
| `Renderer.swift` | Game-state machine, frame loop, Metal present + blit shader |
| `VoxelRenderer.swift` | CPU voxel engine, HUD/dashboard, screens, headless `SmokeTest` |
| `Terrain.swift` | Procedural heightmap/colourmap generation + sampling |
| `PlanetTheme.swift` | The named planet cluster (palettes per world) |
| `Camera.swift` | Ship/observer state + per-frame flight update |
| `InputState.swift` | Effective input (keyboard OR'd with gamepad) |
| `Gamepad.swift` | Controller polling + rebindable action map |
| `Mesh.swift` | Low-poly ship meshes (flat-shaded solids) |
| `Enemy.swift` | Enemy field, kinds, AI, points |
| `Structure.swift` | Ground installations + damage stages |
| `Combat.swift` / `Projectile.swift` | Fire, bombs, hit detection, scoring |
| `Smoke.swift` | Particle smoke/fire |
| `Sprite.swift` | Billboard sprites with terrain depth-test |
| `Font.swift` / `TextImage.swift` | 5×7 bitmap font / Core Text rasteriser |
| `AudioEngine.swift` | Code synthesiser (music + SFX buses) |
| `VoiceComms.swift` | Radio voice callouts |
| `HighScores.swift` | Persistent high-score table |
| `GameSettings.swift` | UserDefaults-backed settings (volumes, controls, binds) |
| `FeatureFlags.swift` | Hidden `defaults write` feature flags |
| `OptionsSheet.swift` / `SettingsSheet.swift` | Options / controller sheets |
| `generate_icon.swift` | Build-time app-icon generator (not compiled in) |

## Roadmap

See `TODO.md` for the backlog. The game is feature-complete for a release
candidate; remaining items are polish and distribution (publishing the Sparkle
appcast, a product page, About-panel links).

---

*A Jorvik Software game.*
