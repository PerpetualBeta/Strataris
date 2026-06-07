# Strataris — Architecture

The world is a GPU triangle-mesh terrain (`MeshTerrain.swift`) rendered from a
quaternion camera (`Camera6DOF`) into a 480×270 offscreen texture, then read
back into a 2D packed-RGBA canvas (`Canvas2D.swift`) where the HUD, cutscenes,
codex and text composite on top. A runtime-compiled Metal blit shader uploads
that canvas and upscales it nearest-neighbour to the drawable, aspect-correct
and letterboxed, for the period-correct pixelated look.

On an M3 Max the GPU mesh frame (encode + readback) runs ~1.3 ms at 480×270.

## Source map

| File | Role |
|------|------|
| `main.swift` | Entry point; smoke-test / screenshot-harness / GUI launch |
| `AppDelegate.swift` | Window (maximised), menu bar, About, Sparkle, input wiring |
| `GameView.swift` | `MTKView` subclass; keyboard capture + rebinding |
| `Renderer.swift` | Game-state machine, frame loop, Metal present + blit shader |
| `MeshTerrain.swift` | GPU mesh-terrain renderer + `Camera6DOF` quaternion flight camera |
| `Canvas2D.swift` | 2D canvas: HUD/dashboard, radar, cutscenes, codex, screens, headless `SmokeTest` |
| `Terrain.swift` | Procedural heightmap/colourmap generation + sampling |
| `PlanetTheme.swift` | The named planet cluster (palettes per world) |
| `Camera.swift` | Legacy scalar bridge (HUD/radar/AI/audio), written from `Camera6DOF` |
| `InputState.swift` | Effective input (keyboard OR'd with gamepad) |
| `Gamepad.swift` | Controller polling + rebindable action map |
| `Mesh.swift` | Low-poly ship & building meshes (flat-shaded solids) |
| `Enemy.swift` | Enemy field, kinds, AI, points |
| `Structure.swift` | Colony installations (3-D models on a concrete pad) + damage state |
| `Combat.swift` / `Projectile.swift` | Fire, bombs, hit detection, scoring |
| `Smoke.swift` | Particle smoke/fire |
| `Font.swift` / `TextImage.swift` | 5×7 bitmap font / Core Text rasteriser |
| `AudioEngine.swift` | Code synthesiser (music + SFX buses) |
| `VoiceComms.swift` | Radio voice callouts |
| `HighScores.swift` | Persistent high-score table |
| `GameSettings.swift` | UserDefaults-backed settings (volumes, controls, binds) |
| `FeatureFlags.swift` | Hidden `defaults write` feature flags |
| `OptionsSheet.swift` / `SettingsSheet.swift` / `KeyboardSheet.swift` | Options / controller / keyboard sheets |
| `Captures.swift` | Headless screenshot harness (`STRATARIS_SHOTS`) for docs/marketing |
| `generate_icon.swift` | Build-time app-icon generator (not compiled in) |
