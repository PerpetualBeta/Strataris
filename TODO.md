# Strataris — backlog / ideas (for later)

Deferred items, not yet scheduled. Pick from here when ready.

## Marketing / write-up angles (for README, product page, blog post)
- [ ] **Tiny footprint — the whole game is ~1 MB.** The entire `.app` bundle
      (universal binary included) is about **1 MB** — it would fit on a 1.44 MB
      floppy disk, and it's *smaller than the asset payload of many single web
      pages*. Lead with this. The reason is the hook: **there are zero asset
      files** — every pixel and every sound is generated procedurally in code.
      Terrain (seamless fbm), the 3D ship hulls (flat-shaded meshes), the music
      and SFX (a code synth), the radio voice (offline-rendered + filtered), the
      fonts, the particle smoke/fire — all synthesised at runtime. No textures,
      no audio files, no models to ship. Genuinely in the 16-bit spirit:
      demoscene-style "everything from maths," running as a native Mac app.

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
- [ ] **Damaged buildings emit persistent smoke and fire.** Structures that have
      taken damage should continuously billow smoke (and show flame at low
      health), not just change colour/height. Should scale with damage — light
      smoke when first hit, heavy black smoke + fire as it nears rubble — and
      persist every frame (a particle/sprite emitter anchored to the structure
      top, depth-tested against terrain like other sprites). Ties into the
      existing `Structure.health` / `StructureField.stageLook` damage stages.

## Menus / UI chrome
- [ ] **App menu bar** (currently menu-less): standard Strataris menu with
      About, Quit, and a "Check for Updates…" item (pairs with Sparkle).
- [ ] **About modal** — title, version/build, Jorvik credit, maybe the logo.
- [ ] **Game options screen** — toggles/sliders for Music volume, SFX volume,
      Voice on/off, (and likely invert-pitch/deadzone moved here from the
      controller sheet, plus difficulty later). Persist to UserDefaults.
      Include a **Reset High Scores** button (clears highscores.json, with a
      confirm).

## Distribution / release
- [ ] **Sparkle auto-updater.** Embed `Sparkle.framework` (the Makefile already
      supports `EMBEDDED_FRAMEWORKS := Sparkle`, as SpaceMan etc. do): add the
      EdDSA key pair, `SUFeedURL` + `SUPublicEDKey` to Info.plist, an
      `SPUStandardUpdaterController` wired to a "Check for Updates" menu item,
      and publish an appcast.xml. Mirror the setup from an existing Sparkle
      Jorvik app. (Release pipeline already signs/notarises/staples + can
      dual-ship zip/pkg.)

## Audio / feedback
- [ ] **Voice notifications** (synthesised speech via `AVSpeechSynthesizer`, or
      pre-rendered): trigger on key events — "Shields low" (≤20%), "Shields
      depleted / critical" (≤5%), "Command post under attack", "Mothership
      detected", "Attack fleet defeated", etc. Edge-triggered, rate-limited so
      they don't spam; respect the mute toggle.
      - Wrap each callout in **radio comms FX**: a short burst of static/squelch
        in before the voice, a "10-4" roger **bleep** out, slight band-limited /
        crackly filtering on the voice for that cockpit-radio feel.

## Input
- [ ] **Gamepad support + configure sheet.** Detect a paired controller (Xbox/
      DualShock) via GameController.framework (`GCController`, controller
      connect/disconnect notifications); map stick = bank/pitch, triggers/face
      = fire & throttle, buttons = pause/start. Add a settings sheet to show
      the detected controller and let the player rebind. Keyboard stays as a
      fallback.

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
- [ ] **Open the game window maximised** — launch zoomed to fill the screen
      (or full-screen) rather than the current fixed/default size. Mind the
      voxel renderer's fixed internal `RenderConfig` resolution: the framebuffer
      is scaled to the view, so a maximised window just means a larger upscale —
      check it still looks right (aspect/letterboxing) at full size.

## Systems (already flagged as "next" candidates)
- [ ] Title / start screen (logo, PRESS ENTER, view high scores from menu).
- [ ] Cockpit frame — art surround for the HUD.
- [ ] Async warp — generate the next planet on a background thread WHILE the
      player keeps flying (that's why flight continues after a level is cleared:
      no freeze — a seamless warp transition mid-flight rather than a "WARPING…"
      stall). Jonathan has a specific plan here; revisit with him.
- [ ] Audio — cannons, explosions, shield-down alarm, ambient per planet.
