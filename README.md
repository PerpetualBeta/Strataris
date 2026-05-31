# Strataris — Galactic Colony Defence

A first-person, voxel-terrain shoot-'em-up for macOS — *Space Invaders* by
way of *Rescue on Fractalus*, with the period-correct pixelated look of the
*Star Raiders* tribute. You auto-fly across procedurally generated planets;
later you'll steer, throttle, and shoot waves of alien craft, with a
radar/scope tracking the survivors and a warp to the next world when a
planet is cleared.

**The first *native* game in the Jorvik suite** — the others (Star Raiders,
Rescue on Fractalus, Centipede, Mr. Do!, Gauntlet) are HTML/canvas tributes.

> **Name is a placeholder.** To rename: change `BUNDLE_NAME`, `PRODUCT_NAME`,
> `BUNDLE_ID` in the `Makefile` and the folder name. Nothing in the Swift
> sources hard-codes it.

## Status: flying-terrain prototype

What works today:

- **Voxel terrain engine** — Comanche-style "Voxel Space" CPU raycaster
  (front-to-back march + y-buffer occlusion), rendered into a low-res
  framebuffer and upscaled nearest-neighbour by a runtime-compiled Metal
  blit shader.
- **Procedural planets** — seamless tiling fractal-noise heightmaps with
  flat seas, height-banded colour, slope shading, and distance haze. Our
  own maps (no licence-encumbered Comanche assets); each seed is a new
  world.
- **Auto-fly flight** with steering, climb/dive, and throttle; the camera
  keeps clearance above the terrain.

Not yet: enemies, fire, radar, cockpit/HUD frame, warp, audio, planet
variety/themes, gamepad support. (See "Next" below.)

## Run it

```sh
gmake build              # universal .app via the shared jorvik-release pipeline
open .build/Strataris.app   # fly
```

Controls: **←/→** steer · **↑/↓** climb/dive · **+ / −** throttle ·
**Space** fire (stubbed) · **Esc** quit.

Headless smoke test (no window/GPU — exercises terrain gen + raycaster,
prints timing):

```sh
STRATARIS_SMOKE=1 ./.build/Strataris.app/Contents/MacOS/Strataris
```

On an M3 Max the render runs ~0.9 ms/frame at 480×270 (~1100 fps of
headroom) — the whole 16 ms budget is still free for sprites and HUD.

## Layout

| File | Role |
|------|------|
| `main.swift`        | Entry point; smoke-test vs GUI launch |
| `AppDelegate.swift` | Window + input→renderer wiring |
| `GameView.swift`    | `MTKView` subclass; keyboard capture |
| `Renderer.swift`    | Metal present layer + `RenderConfig`; blit shader |
| `VoxelRenderer.swift` | CPU voxel engine + headless `SmokeTest` |
| `Terrain.swift`     | Procedural heightmap/colourmap generation + sampling |
| `Camera.swift`      | Ship/observer state + per-frame flight update |
| `InputState.swift`  | Held-key flags shared view→renderer |

The renderer is split CPU (engine) / GPU (present) deliberately: the engine
has no GPU dependency (hence the headless test), and when the CPU path
eventually needs the headroom it can be re-homed to a Metal compute shader
behind the same seam.

## Next

1. **Billboard sprites with terrain depth-test** — the one genuinely novel
   bit: enemies that can duck behind ridges. De-risk this first.
2. Fire + projectiles + hit detection.
3. Radar/scope (relative bearing of surviving craft).
4. Cockpit frame + HUD (speed, altitude, health, ammo, score).
5. Warp / planet themes (palette + noise params per world).
6. Audio (AVAudioEngine) and gamepad (GameController.framework).
