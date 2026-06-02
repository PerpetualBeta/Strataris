# Strataris — backlog / ideas (for later)

Deferred items, not yet scheduled. Pick from here when ready.

## Marketing / write-up angles (for README, product page, blog post)
- [ ] **Tiny footprint — the whole game is ~1 MB.** The game itself — the
      universal binary with **every pixel and sound generated in code** — is
      about **1.1 MB**, *smaller than the asset payload of many single web
      pages*, and it would fit on a 1.44 MB floppy. Lead with this. The hook:
      **there are zero asset files** — terrain (seamless fbm), the 3D ship hulls
      (flat-shaded meshes), the music and SFX (a code synth), the radio voice
      (offline-rendered + filtered), the fonts, the particle smoke/fire — all
      synthesised at runtime. No textures, no audio files, no models to ship.
      Demoscene-style "everything from maths," running as a native Mac app.
      - **Framing note (post-Sparkle):** the *shipped* `.app` is ~5.7 MB because
        it embeds the **Sparkle** auto-updater framework (~3 MB) and its helper
        apps. So phrase it as **"the game itself is ~1 MB; the rest of the
        download is just the auto-updater."** Don't claim the whole download
        fits on a floppy anymore — the *game* does; the bundle doesn't.
      - **README done** — rewritten as a full product README leading with this
        hook (game ~1.2 MB, zero asset files, bundle ~5.7 MB w/ Sparkle).
        Still to do: **product page** and **blog post** reusing the same angle.

## Scoring
- [x] **Stardate on high-score entries** — done. `HighScoreEntry.stardate`
      (`yyyymmdd::hhmm`, optional so older highscores.json still decodes),
      shown as a column in the game-over table.
- [x] **Proper columnar high-score table** — done. `drawGameOver` lays out
      aligned **RANK | NAME | STARDATE | SCORE | LEVEL** columns at fixed
      x-positions.

## Visual / polish
- [x] **Damaged buildings emit persistent smoke and fire.** Already implemented
      (smoke/flame scales with `Structure.health` / `StructureField.stageLook`
      damage stages).

## Menus / UI chrome
- [x] **App menu bar** — done. `AppDelegate.installMainMenu()` builds a native
      menu in code (no nib): app menu (About / Hide / Quit) + Window menu
      (Minimize / Zoom / Enter Full Screen ⌃⌘F). Jorvik order: About first.
      A "Check for Updates…" item slots into the app menu when Sparkle lands.
- [x] **About modal** — done. Standard macOS About panel
      (`orderFrontStandardAboutPanel`) showing the app icon, version, a
      "Galactic Colony Defence" tagline, the zero-asset hook, and the Jorvik
      credit. Native/dependency-free (no SwiftUI) to keep the footprint tiny.
- [ ] **About modal — add links** to the game product page (once it exists)
      and the GitHub repo (once public). The `.credits` attributed string
      supports clickable links via `.link` attributes; add a product-page URL
      and `https://github.com/PerpetualBeta/Strataris` as a footer line.
      Deferred until both destinations are live. (NB: if we end up wanting
      richer link styling/behaviour, this is the point where reusing the
      suite's `JorvikAboutView` could be reconsidered — see the footprint
      trade-off noted when the panel was first built.)
- [x] **Settings… menu item** — done (⌘,), plus a Controller… item that opens
      the controller sheet from the menu as well as the C key.
- [x] **Game options screen** — done. Native AppKit sheet (`OptionsSheet`,
      ⌘,): Audio (Music / SFX / Voice volume sliders, live + persisted),
      Controls (invert pitch + deadzone, moved here from the controller sheet),
      Data (**Reset High Scores** with a confirm alert). Backed by a new
      `GameSettings` UserDefaults store; AudioEngine gained per-category gains
      (music voices tagged) and Gamepad now persists its prefs. Esc closes the
      sheet. (Difficulty slider still future work.)

## Distribution / release
- [x] **Sparkle auto-updater** — done. Embedded `Sparkle.framework`
      (`EMBEDDED_FRAMEWORKS := Sparkle`); Info.plist has `SUFeedURL`
      (`…/appcasts/strataris.xml`), the shared Jorvik `SUPublicEDKey`, and
      24 h scheduled checks; `SPUStandardUpdaterController` starts on launch and
      a "Check for Updates…" item sits in the app menu. Uses the existing
      machine EdDSA signing key (no new key minted).
      - [ ] **Publish `strataris.xml`** to jorviksoftware.cc/appcasts/ at first
            release (sign the build with `sign_update`). Until it exists,
            "Check for Updates…" will just report no update / a feed error —
            expected pre-release.

## Audio / feedback
- [x] **Voice notifications + radio comms FX.** Already implemented
      (see `VoiceComms.swift` — edge-triggered, rate-limited callouts wrapped in
      static/squelch/roger-bleep comms FX).

## Input
- [x] **Gamepad support + configure sheet.** Done. Detection + live preview
      already existed; added **rebinding**: `PadAction` (fire / throttle ± /
      pause / warp) each map to a controller button/trigger, edited in the
      controller sheet (click an action → press a button to bind), reset to
      defaults, and persisted via `GameSettings.padBindings`. The left stick is
      fixed (steer/pitch). Warp is now its own bindable action (default LT), so
      the old "left trigger warps" toggle was retired. Keyboard stays a
      fallback. (Stick-axis remap / per-controller profiles still future work.)

## Input (cont.)
- [ ] **Keyboard configure sheet** — a rebinding UI for keyboard players,
      mirroring the controller sheet (`SettingsSheet`). Today the keyboard map is
      hardcoded in `GameView.set(keyCode:)` (arrows = steer/pitch, Space = fire,
      X/Z perks, etc.) with no way to change it. Needs: a `keyBindings` store in
      `GameSettings` (action → keyCode), a key-capture sheet (click an action →
      press a key), reset-to-defaults, and `GameView` routing keyDown/Up through
      the bindings instead of the fixed `switch`. Pair it with the existing
      controller sheet so both input methods are configurable. (Pitch already
      honours the shared Invert-pitch setting.)

## Flight model (6DOF — exp/6dof branch)
- [x] **Flight Envelope Trim control** — done. FLIGHT TRIM section in the
      Settings sheet (⌘,): Agility (pitch/roll), Yaw (full 6DOF) and Auto-level
      sliders as multipliers on the tuned rates (centre tick = 1.0 default,
      auto-level can go to 0 = hold attitude). Persisted via `GameSettings`
      (`trimAgility`/`trimYaw`/`trimAutoLevel`), applied live in
      `Renderer.updateMeshFlight` to both envelopes.

## Front-end / narrative screens
- [x] **Back-story screen** — done. Mission-briefing crawl (`.briefing` state /
      `drawBriefing`): an "incoming transmission" of original lore over the
      attract flyover, reachable from the title (B).
- [x] **Alien craft codex screen** — done. `.codex` state / `drawCodex`: the
      four craft types with their rotating low-poly meshes, names, roles and
      point values, reachable from the title (V).

## Branding / assets
- [x] **App icon.** Done — `generate_icon.swift` renders `AppIcon.icns`
      procedurally (no source art file, true to the zero-asset ethos),
      combining the established Jorvik visual language: the brand-blue
      rounded-square badge + wireframe globe backdrop (from BrowserCommander /
      BrowserNotes) with the swept-fin rocket glyph tilted 45° right (from
      SpaceMan's menu-bar icon) atop it — a craft over a world. Wired via
      Info.plist `CFBundleIconFile = AppIcon`; release.mk copies the root-level
      icns into the bundle. Regenerate with `swift generate_icon.swift`.

## Window / presentation
- [x] **Open the game window maximised** — done. `AppDelegate` sets the window
      to the screen's `visibleFrame` on launch (below the menu bar, clear of the
      Dock). The fixed internal `RenderConfig` framebuffer is now blitted
      through an aspect-correct **letterbox viewport** (centred 16:9 with black
      bars), so non-16:9 screens never distort — just larger nearest-neighbour
      upscale. Green-button full-screen uses the same path.

## Systems (already flagged as "next" candidates)
- [ ] Title / start screen (logo, PRESS ENTER, view high scores from menu).
- [ ] Cockpit frame — art surround for the HUD.
- [ ] Async warp — generate the next planet on a background thread WHILE the
      player keeps flying (that's why flight continues after a level is cleared:
      no freeze — a seamless warp transition mid-flight rather than a "WARPING…"
      stall). Jonathan has a specific plan here; revisit with him.
- [ ] Audio — cannons, explosions, shield-down alarm, ambient per planet.
