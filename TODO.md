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
- [ ] **Stardate on high-score entries** — record a timestamp at the moment a
      score is added, formatted `yyyymmdd::hhmm`, stored on `HighScoreEntry`
      (Codable — make it optional / defaulted so existing highscores.json still
      decodes) and shown as a column in the game-over high-score table.
- [ ] **Proper columnar high-score table** — replace the current concatenated
      single-string rows with aligned columns: **NAME | STARDATE | SCORE |
      LEVEL**, with a header row. Needs a left-aligned Unicode draw at fixed
      column x-positions (Core Text is proportional, so can't rely on spaces).
      (Drop the planet "P3" suffix into the LEVEL column.)

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

## Front-end / narrative screens
- [ ] **Back-story screen** — a briefing/intro that sets the premise (our
      colonies are under attack; you fly planet-to-planet defending the ground
      installations). Reachable from the title menu (and maybe shown once on
      first run). Scrolling or paged text over the attract-mode flyover, in the
      cockpit/computer-display style; original prose (no copyrighted lore).
- [ ] **Alien craft codex screen** — a "know your enemy" page showing each of
      the four craft types with its low-poly 3D model (reuse `EnemyField.meshes`
      / the mesh rasteriser, slowly rotating), its name, role/purpose, and the
      points awarded for destroying it. Current values to display:
      - **Drone** — 10 pts — cheap swarm; mimics the nearest destroyer/fighter.
      - **Fighter** — 100 pts — hunts the player and strafes.
      - **Destroyer** — 250 pts — bombs ground installations (freefall); turns
        to hunt the player if you get within its defensive perimeter.
      - **Mothership** — 2500 pts — slow, heavily armoured (10 hp), high value;
        appears on a timer. (Confirm values against `Enemy.swift` at build time.)
      Reachable from the title menu; in the same cockpit-display visual style.

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
