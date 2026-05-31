// Strataris — Metal presentation layer.
//
// The voxel engine renders on the CPU into a small RGBA framebuffer; this
// layer's only job is to get that framebuffer onto the screen each frame:
// upload it to a texture and draw a single full-screen triangle that samples
// it with NEAREST filtering, so the low-res image upscales into crisp,
// period-correct pixels rather than a blurry mess.
//
// The blit shader is compiled at runtime from the source string below, which
// keeps the build a plain `swiftc` source list (no .metal compile step in
// the Makefile). It's a few dozen lines of MSL; the cost is a one-off ~tens
// of ms at launch.

import MetalKit
import QuartzCore
import AppKit

// Internal render resolution. 16:9, deliberately tiny. Bump later if we want
// a sharper look; the CPU cost scales with width × distance-steps.
enum RenderConfig {
    static let width = 480
    static let height = 270
    static let crosshairX = Float(width) / 2
    static let crosshairY = Float(height) / 2
}

enum GameState {
    case title, briefing, codex, playing, won, lost, warping
}

private let blitShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

// Full-screen triangle from a bare vertex id — no vertex buffer needed.
vertex VSOut v_blit(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2)
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);                 // flip V (texture origin top-left)
    return o;
}

fragment float4 f_blit(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}
"""

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let texture: MTLTexture
    private let bytesPerRow: Int

    private var terrain: Terrain
    private var structures: StructureField
    private var voxel: VoxelRenderer
    private var enemies: EnemyField
    private var combat = Combat()
    private var camera: Camera
    private var titleCam: Camera        // drifting cinematic camera for the attract flyover
    private let input: InputState

    private var lastTime: CFTimeInterval = 0
    private var state: GameState = .title
    private var titleTime: Float = 0
    private var missionTime: Float = 0          // elapsed mission clock (MET) for the chronometer
    private let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy.MM.dd"; return f }()
    private let clockFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private let stardateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd'::'HHmm"; return f }()
    private var level = 1               // progression: starts at 1, +1 each warp (unbounded)
    private var paused = false
    private var restartLatch = false
    private var pauseLatch = false
    private var warpLatch = false
    private var briefingLatch = false
    private var briefingTime: Float = 0     // scroll clock for the briefing crawl
    private var codexLatch = false
    private var codexTime: Float = 0        // spin clock for the codex models

    private let maxShield: Float = 100
    private var shield: Float = 100
    private var shieldRechargeDelay: Float = 0     // pause before shields start regenerating
    private var projectiles = ProjectileField()   // enemy fire aimed at the player
    private var bombs = ProjectileField()         // visible ordnance dropped on structures
    private var smoke: SmokeField                 // damage plumes + explosion debris
    private var damageFlash: Float = 0
    private var loseReason = "BASES LOST"

    let highScores = HighScores()
    private var awaitingName = false               // entering initials after a qualifying run
    private var newScoreRank = -1                  // index of the just-added entry (for highlight)

    let audio = AudioEngine()
    private lazy var comms = VoiceComms(audio: audio)
    private let gamepad: Gamepad
    private var muteLatch = false

    // Feature-flag state (hidden flags; see FeatureFlags).
    private var fpsSmoothed: Float = 0          // showFPS readout
    private var screenshotPending = false       // screenshotOnSpace request (edge)
    private var screenshotLatch = false
    private var pulseCharges = FeatureFlags.radialPulseWeapon ? 3 : 0   // radialPulseWeapon, per run
    private var pulseLatch = false
    private var wasPlaying = false              // edge-detect level start (Easter egg)

    // Voice-callout edge tracking.
    private var voiceLowArmed = true, voiceCritArmed = true
    private var prevVoiceStructHealth = 0
    private var attackCalloutTimer: Float = 0
    private var motherAnnounced = false
    private var structureBurstDone = Set<Int>()    // bases already given a death burst

    // Warp cut-scene state (async terrain gen + cinematic phases).
    private var warpPhase = 0
    private var warpTime: Float = 0
    private var warpCam = Camera(x: 0, y: 0, height: 0, angle: 0, horizon: 0, horizonBase: 0)
    private var warpReady = false
    private var warpTerrain: Terrain?
    private var warpVoxel: VoxelRenderer?
    private var warpStructures: StructureField?
    private var warpEnemies: EnemyField?
    private let warpPhaseDur: [Float] = [2.0, 1.8, 2.2, 1.6, 2.2]   // ascent, orbit, hyper, approach, descent

    // A separate, randomly-themed mini-world for the title flyover, so the
    // attract scene varies each launch WITHOUT changing the deterministic
    // game planets.
    private var titleTerrain: Terrain
    private var titleVoxel: VoxelRenderer
    private var titleStructures: StructureField

    // Edge/delta tracking for one-shot SFX.
    private var prevKills = 0, prevShots = 0, prevBombs = 0, prevStanding = 0
    private var prevTracer = false
    private var lastTitleBeat = -1

    private static func planetSeed(_ n: Int) -> UInt32 { 1000 &+ UInt32(n) &* 2_654_435_761 }
    private static func difficulty(forPlanet n: Int) -> Float { 1 + Float(n - 1) * 0.15 }
    private static func enemyCount(forPlanet n: Int) -> Int { 12 + (n - 1) * 3 }

    init(device: MTLDevice, view: MTKView, input: InputState, gamepad: Gamepad) {
        self.device = device
        self.input = input
        self.gamepad = gamepad

        guard let queue = device.makeCommandQueue() else {
            fatalError("Strataris: could not create a Metal command queue")
        }
        self.queue = queue

        // Build the blit pipeline.
        do {
            let library = try device.makeLibrary(source: blitShaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "v_blit")
            desc.fragmentFunction = library.makeFunction(name: "f_blit")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Strataris: blit pipeline build failed — \(error)")
        }

        // The CPU framebuffer, mirrored into a managed texture each frame.
        let w = RenderConfig.width, h = RenderConfig.height
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        texDesc.usage = .shaderRead
        texDesc.storageMode = .managed          // works on Apple Silicon + Intel
        guard let tex = device.makeTexture(descriptor: texDesc) else {
            fatalError("Strataris: could not create the framebuffer texture")
        }
        self.texture = tex
        self.bytesPerRow = w * 4

        // Build planet 1 — DETERMINISTIC (fixed seed + theme sequence), so the
        // game's planets always follow the same pattern. Stamp installations
        // before anything renders so they're founded from the first frame.
        let seed = Renderer.planetSeed(1)
        let t = Terrain(seed: seed, theme: PlanetTheme.forPlanet(1))
        self.terrain = t
        self.structures = StructureField(terrain: t, around: 512, cy: 512, count: 5, seed: seed ^ 0x00AB_CDEF)
        self.voxel = VoxelRenderer(width: w, height: h, terrain: t)
        self.camera = Camera.start(over: t, renderHeight: h)
        self.enemies = EnemyField(terrain: t, around: 512, cy: 512,
                                  count: Renderer.enemyCount(forPlanet: 1),
                                  difficulty: Renderer.difficulty(forPlanet: 1),
                                  seed: seed ^ 0x00DE_F123)
        self.smoke = SmokeField(terrain: t)

        // Build a separate, RANDOMLY-themed mini-world just for the title
        // flyover (small map → cheap), so the attract scene differs each launch
        // while the game itself stays on its fixed planet sequence.
        let tSeed = UInt32.random(in: 1...UInt32.max)
        let tTheme = PlanetTheme.all.randomElement()!
        let tt = Terrain(size: 1024, seed: tSeed, theme: tTheme)
        self.titleTerrain = tt
        self.titleVoxel = VoxelRenderer(width: w, height: h, terrain: tt)
        self.titleStructures = StructureField(terrain: tt, around: 512, cy: 512, count: 5, seed: tSeed ^ 0xABCD)
        self.titleCam = Camera.start(over: tt, renderHeight: h)

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Fixed internal resolution; the full-screen triangle stretches to
        // whatever the drawable is, so nothing to do here.
    }

    /// Build planet `n`: fresh terrain (new seed + layout), structures, craft,
    /// and ramped difficulty. Does NOT touch the score — the caller decides
    /// whether to carry it (warp) or reset it (game-over restart).
    private func loadPlanet(_ n: Int) {
        let seed = Renderer.planetSeed(n)
        let t = Terrain(seed: seed, theme: PlanetTheme.forPlanet(n))
        terrain = t
        structures = StructureField(terrain: t, around: 512, cy: 512, count: 5, seed: seed ^ 0x00AB_CDEF)
        voxel = VoxelRenderer(width: RenderConfig.width, height: RenderConfig.height, terrain: t)
        enemies = EnemyField(terrain: t, around: 512, cy: 512,
                             count: Renderer.enemyCount(forPlanet: n),
                             difficulty: Renderer.difficulty(forPlanet: n),
                             seed: seed ^ 0x00DE_F123)
        camera = Camera.start(over: t, renderHeight: RenderConfig.height)
        projectiles = ProjectileField()
        bombs = ProjectileField()
        smoke = SmokeField(terrain: t)
        voiceLowArmed = true; voiceCritArmed = true
        motherAnnounced = false; attackCalloutTimer = 0; prevVoiceStructHealth = 0
        structureBurstDone.removeAll()
        shield = maxShield                  // warping recharges shields fully
        shieldRechargeDelay = 0
        damageFlash = 0
        paused = false
        input.resetControls()               // never resume mid-turn / auto-firing
        state = .playing
    }

    private static func midi(_ n: Int) -> Float { 440 * powf(2, Float(n - 69) / 12) }

    /// An original, dark, foreboding title theme (NOT a copyrighted tune):
    /// a slow D-minor piece that DEVELOPS over 64 steps — an ominous intro and
    /// brooding A theme, a rising chromatic bridge with double-time war-drums,
    /// then a climactic B statement an octave up with a dissonant high cluster,
    /// before resolving back. Deep moving bass + minor chords throughout.
    private func titleMusic() {
        let step = Int(titleTime / 0.19)        // slow + grave
        guard step != lastTitleBeat else { return }
        lastTitleBeat = step
        let s = step % 64
        let bar = s / 8
        let climax = s >= 32                    // bridge + B section: more intensity

        // Timpani — heavy and low; double-time through the climax for drive.
        if (climax && s % 2 == 0) || (!climax && s % 4 == 0) {
            audio.trigger(wave: AudioEngine.noise, f0: 1, f1: 1, dur: 0.22, amp: 0.20, music: true)
            audio.trigger(wave: AudioEngine.sine, f0: 56, f1: 26, dur: 0.28, amp: 0.24, music: true)
        }
        // Deep bass root + minor chord per bar (Dm – Bb – Gm – A, twice).
        if s % 8 == 0 {
            let roots = [38, 34, 31, 33, 38, 34, 31, 33]                  // D2 Bb1 G1 A1 ×2
            audio.trigger(wave: AudioEngine.saw, f0: Renderer.midi(roots[bar]),
                          f1: Renderer.midi(roots[bar]), dur: 1.5, amp: 0.14, attack: 0.03, music: true)
            let dm: [Int] = [50, 53, 57], bb = [46, 50, 53], gm = [43, 46, 50], a = [45, 49, 52]
            let chords = [dm, bb, gm, a, dm, bb, gm, a]
            for n in chords[bar] {
                audio.trigger(wave: AudioEngine.triangle, f0: Renderer.midi(n), f1: Renderer.midi(n),
                              dur: 1.6, amp: 0.05, attack: 0.06, music: true)
            }
            // Dissonant high cluster swells in during the climax (dread/tension).
            if climax {
                audio.trigger(wave: AudioEngine.triangle, f0: Renderer.midi(81), f1: Renderer.midi(81),
                              dur: 1.6, amp: 0.035, attack: 0.2, music: true)
                audio.trigger(wave: AudioEngine.triangle, f0: Renderer.midi(82), f1: Renderer.midi(82),
                              dur: 1.6, amp: 0.030, attack: 0.2, music: true)   // semitone clash
            }
        }
        // Melody: intro (rest) → A theme → chromatic bridge → B climax (8va).
        // Harmonic-minor leading tones (C#=61 / 73) add menace.
        let mel = [ 0,  0,  0,  0,   0,  0,  0,  0,    // intro
                   62,  0,  0, 64,  65,  0, 64, 62,    // A
                   69,  0,  0, 67,  65,  0, 64, 62,    // A
                   62, 64, 65, 67,  69, 70, 69,  0,    // bridge — chromatic climb
                   74,  0,  0, 76,  77,  0, 76, 74,    // B (octave up)
                   81,  0,  0, 79,  77,  0, 76, 74,    // B
                   73,  0, 74,  0,  77, 76, 74,  0,    // B → resolve
                    0,  0,  0,  0,   0,  0,  0,  0]     // breath before the loop
        let m = mel[s]
        if m > 0 {
            let f = Renderer.midi(m)
            audio.trigger(wave: AudioEngine.saw, f0: f, f1: f, dur: 0.30, amp: 0.16, attack: 0.02, music: true)
            audio.trigger(wave: AudioEngine.saw, f0: f * 0.5, f1: f * 0.5, dur: 0.32, amp: 0.12, attack: 0.03, music: true)
            if climax {   // add a brighter octave on top for power
                audio.trigger(wave: AudioEngine.saw, f0: f * 2, f1: f * 2, dur: 0.26, amp: 0.06, attack: 0.02, music: true)
            }
        }
    }

    // MARK: Warp cut-scene

    /// Start the warp: generate the next planet on a background thread while a
    /// cinematic plays, so there's no freeze.
    private func beginWarp() {
        level += 1
        state = .warping
        warpPhase = 0; warpTime = 0; warpReady = false
        warpTerrain = nil; warpVoxel = nil; warpStructures = nil; warpEnemies = nil
        warpCam = camera                                  // ascent continues from here
        audio.whoosh(rising: true)                        // lift-off

        let p = level
        let seed = Renderer.planetSeed(p)
        let theme = PlanetTheme.forPlanet(p)
        let w = RenderConfig.width, h = RenderConfig.height
        let ec = Renderer.enemyCount(forPlanet: p), diff = Renderer.difficulty(forPlanet: p)
        DispatchQueue.global(qos: .userInitiated).async {
            let t = Terrain(seed: seed, theme: theme)
            let vox = VoxelRenderer(width: w, height: h, terrain: t)
            let str = StructureField(terrain: t, around: 512, cy: 512, count: 5, seed: seed ^ 0x00AB_CDEF)
            let en = EnemyField(terrain: t, around: 512, cy: 512, count: ec, difficulty: diff, seed: seed ^ 0x00DE_F123)
            DispatchQueue.main.async {
                self.warpTerrain = t; self.warpVoxel = vox
                self.warpStructures = str; self.warpEnemies = en
                self.warpReady = true
            }
        }
    }

    private func finalizeWarp() {
        guard let t = warpTerrain, let vox = warpVoxel, let str = warpStructures, let en = warpEnemies else { return }
        terrain = t; voxel = vox; structures = str; enemies = en      // score (combat) carries over
        camera = Camera.start(over: t, renderHeight: RenderConfig.height)
        projectiles = ProjectileField(); bombs = ProjectileField(); smoke = SmokeField(terrain: t)
        shield = maxShield; shieldRechargeDelay = 0; damageFlash = 0
        combat.clearTransient()
        voiceLowArmed = true; voiceCritArmed = true; motherAnnounced = false
        attackCalloutTimer = 0; prevVoiceStructHealth = 0; structureBurstDone.removeAll()
        input.resetControls()
        warpTerrain = nil; warpVoxel = nil; warpStructures = nil; warpEnemies = nil
        state = .playing
    }

    /// Draw the dashboard chronometer (live stardate/clock + mission-elapsed time).
    private func chrono(on vox: VoxelRenderer) {
        let now = Date()
        let met = Int(missionTime)
        vox.drawChronometer(date: dateFmt.string(from: now), clock: clockFmt.string(from: now),
                            mission: String(format: "%02d:%02d", met / 60, met % 60))
    }

    private func globeColor(_ th: PlanetTheme) -> (Float, Float, Float) {
        ((Float(th.veg.0) + Float(th.water.0)) / 2,
         (Float(th.veg.1) + Float(th.water.1)) / 2,
         (Float(th.veg.2) + Float(th.water.2)) / 2)
    }

    private func updateAndDrawWarp(dt: Float, in view: MTKView) {
        warpTime += dt
        // Advance phases. Approach (3) holds until the new planet is generated.
        if warpTime >= warpPhaseDur[min(warpPhase, 4)] {
            if warpPhase == 3 && !warpReady {
                warpTime = warpPhaseDur[3]                  // hold at approach
            } else {
                warpPhase += 1; warpTime = 0
                if warpPhase == 2 { audio.warp() }
                if warpPhase == 4 {
                    audio.whoosh(rising: false)             // re-entry
                    warpCam = Camera.start(over: warpTerrain ?? terrain, renderHeight: RenderConfig.height)
                    warpCam.x = 512; warpCam.y = 512; warpCam.angle = 0
                }
                if warpPhase >= 5 { finalizeWarp(); return }
            }
        }
        let W = RenderConfig.width, H = RenderConfig.height
        let p = min(1, warpTime / warpPhaseDur[min(warpPhase, 4)])

        // Ship ambience: loud rumble in atmosphere (ascent/descent), quiet hum in space.
        audio.engine(on: true, speed: (warpPhase == 0 || warpPhase == 4) ? 260 : 30)

        // Draws the cockpit instrument cluster + radar over the cut-scene, so we
        // stay "in the ship" the whole time (no sudden EVA).
        func panel(_ vox: VoxelRenderer, _ cam: Camera, _ str: StructureField, _ en: EnemyField, _ t: Terrain) {
            let alt = max(0, Int(cam.height - t.heightF(cam.x, cam.y)))
            vox.drawCockpit(score: combat.score, basesStanding: str.standing, basesTotal: str.structures.count,
                            aliens: en.remaining, planetName: PlanetTheme.name(forLevel: level), level: level,
                            speed: Int(cam.speed), altitude: alt,
                            shield: Int(shield), maxShield: Int(maxShield), roll: cam.roll, pitch: cam.pitch)
            vox.drawRadar(camera: cam, enemies: en, structures: str)
            chrono(on: vox)
        }
        let labelY = Int(Float(H) * 0.12)

        switch warpPhase {
        case 0:   // ascent — climb out of the current world
            warpCam.height = camera.height + p * p * 1400
            warpCam.horizon = camera.horizon + p * Float(H) * 0.55
            warpCam.x += -sinf(warpCam.angle) * 36 * dt
            warpCam.y += -cosf(warpCam.angle) * 36 * dt
            voxel.render(camera: warpCam)
            voxel.dimScreen(p > 0.7 ? (p - 0.7) / 0.3 : 0)
            panel(voxel, warpCam, structures, enemies, terrain)
            voxel.drawUnicodeCentered("DEPARTING", y: labelY, fontSize: 14, 0.82, 0.9, 1.0)
            present(in: view, from: voxel)
        case 1:   // orbit — the planet we left, shrinking
            voxel.clearSpace(warpTime)
            voxel.drawGlobe(cx: W / 2, cy: H / 2 - Int(18 * p), r: max(1, Int(120 - 84 * p)),
                            base: globeColor(terrain.theme))
            panel(voxel, warpCam, structures, enemies, terrain)
            voxel.drawUnicodeCentered("LEAVING ORBIT", y: labelY, fontSize: 14, 0.82, 0.9, 1.0)
            present(in: view, from: voxel)
        case 2:   // hyperspace
            voxel.drawHyperspace(time: warpTime, progress: p)
            panel(voxel, warpCam, structures, enemies, terrain)
            voxel.drawUnicodeCentered("HYPERSPACE", y: labelY, fontSize: 16, 0.85, 0.92, 1.0)
            present(in: view, from: voxel)
        case 3:   // approach — the new planet growing
            voxel.clearSpace(warpTime + 11)
            voxel.drawGlobe(cx: W / 2, cy: H / 2, r: Int(20 + 112 * p),
                            base: globeColor(warpTerrain?.theme ?? terrain.theme))
            panel(voxel, warpCam, structures, enemies, terrain)
            voxel.drawUnicodeCentered("APPROACHING \(PlanetTheme.name(forLevel: level).uppercased())", y: labelY, fontSize: 13, 0.85, 0.92, 1.0)
            present(in: view, from: voxel)
        default:  // 4: descent — drop into the new world
            if let nv = warpVoxel, let nt = warpTerrain, let ns = warpStructures, let ne = warpEnemies {
                let g = nt.heightF(512, 512)
                let pe = 1 - (1 - p) * (1 - p)              // ease out
                warpCam.height = (g + 760) + ((g + 140) - (g + 760)) * pe
                warpCam.horizon = Float(H) * (0.85 - 0.45 * p)
                nv.render(camera: warpCam)
                nv.dimScreen(p < 0.3 ? (0.3 - p) / 0.3 : 0)
                panel(nv, warpCam, ns, ne, nt)
                nv.drawUnicodeCentered("\(PlanetTheme.name(forLevel: level).uppercased())   ·   LEVEL \(level)", y: labelY, fontSize: 14, 0.85, 0.92, 1.0)
                present(in: view, from: nv)
            }
        }
    }

    /// Enter the lost state, and begin name entry if the run made the table.
    private func onGameOver() {
        state = .lost
        audio.gameOver()
        newScoreRank = -1
        if highScores.qualifies(combat.score) {
            awaitingName = true
            input.nameEntryActive = true
            input.nameBuffer = ""
            input.nameCommitted = false
        }
    }

    func draw(in view: MTKView) {
        // Frame clock. First frame establishes the baseline; clamp dt so a
        // hitch (or a breakpoint) can't fling the camera across the map.
        let now = CACurrentMediaTime()
        if lastTime == 0 { lastTime = now }
        let dt = Float(min(1.0 / 20.0, max(0.0, now - lastTime)))
        lastTime = now
        if state != .title && state != .lost && !paused { missionTime += dt }   // mission clock

        // Smoothed FPS for the optional HUD readout.
        if dt > 0 { fpsSmoothed += (1 / dt - fpsSmoothed) * 0.1 }

        // Refresh gamepad each frame; ignore its input while the sheet is open.
        gamepad.poll(input)
        if gamepad.configuring { input.gp = InputState.Controls() }

        // Mute toggle (works in every state).
        if input.mute && !muteLatch { audio.muted.toggle(); muteLatch = true }
        if !input.mute { muteLatch = false }

        // Screenshot request (feature flag) — edge-triggered; captured at present.
        if input.screenshot && !screenshotLatch { screenshotLatch = true; screenshotPending = true }
        if !input.screenshot { screenshotLatch = false }

        // Level-start edge (entered .playing from anything else). Pausing keeps
        // state == .playing, so resuming doesn't re-trigger.
        if state == .playing && !wasPlaying { onLevelStart() }
        wasPlaying = (state == .playing)

        // Title / attract screen — wait for Enter to drop into the (already
        // built) planet 1, then run the normal pipeline from the next frame.
        if state == .title {
            // Fixed step → smooth motion regardless of frame-time wobble.
            let step: Float = 1.0 / 60.0
            titleTime += step
            titleCam.angle = sinf(titleTime * 0.09) * 0.28
            titleCam.x += -sinf(titleCam.angle) * 26 * step
            titleCam.y += -cosf(titleCam.angle) * 26 * step
            // Ease altitude so it doesn't snap as we cross terrain cells (the jitter).
            let targetH = titleTerrain.heightF(titleCam.x, titleCam.y) + 95
            titleCam.height += (targetH - titleCam.height) * min(1, step * 2.5)
            audio.engine(on: false, speed: 0)

            titleMusic()

            if input.restart && !restartLatch {
                restartLatch = true
                input.resetControls()        // start neutral, not mid-turn
                audio.uiStart()
                lastTitleBeat = -1
                missionTime = 0              // fresh mission clock
                state = .playing
            }
            if !input.restart { restartLatch = false }

            if input.briefing && !briefingLatch {
                briefingLatch = true
                audio.uiStart()
                briefingTime = 0
                state = .briefing
            }
            if !input.briefing { briefingLatch = false }

            if input.codex && !codexLatch {
                codexLatch = true
                audio.uiStart()
                codexTime = 0
                state = .codex
            }
            if !input.codex { codexLatch = false }

            titleVoxel.render(camera: titleCam)                      // randomly-themed flyover
            titleVoxel.drawTitleScreen(time: titleTime,
                                       topName: highScores.entries.first?.name,
                                       topScore: highScores.entries.first?.score ?? 0)
            present(in: view, from: titleVoxel)
            return
        }

        // Mission briefing — a scrolling transmission over the attract flyover.
        if state == .briefing {
            let step: Float = 1.0 / 60.0
            titleTime += step
            briefingTime += step
            titleCam.angle = sinf(titleTime * 0.09) * 0.28
            titleCam.x += -sinf(titleCam.angle) * 26 * step
            titleCam.y += -cosf(titleCam.angle) * 26 * step
            let targetH = titleTerrain.heightF(titleCam.x, titleCam.y) + 95
            titleCam.height += (targetH - titleCam.height) * min(1, step * 2.5)
            audio.engine(on: false, speed: 0)
            titleMusic()

            // ENTER engages (starts the game); B stands down (back to title).
            if input.restart && !restartLatch {
                restartLatch = true
                input.resetControls()
                audio.uiStart()
                lastTitleBeat = -1
                missionTime = 0
                state = .playing
            }
            if !input.restart { restartLatch = false }
            if (input.briefing || input.back) && !briefingLatch {
                briefingLatch = true
                audio.uiStart()
                state = .title
            }
            if !input.briefing && !input.back { briefingLatch = false }

            titleVoxel.render(camera: titleCam)
            titleVoxel.drawBriefing(time: briefingTime)
            present(in: view, from: titleVoxel)
            return
        }

        // Enemy-craft codex — rotating model database over the attract flyover.
        if state == .codex {
            let step: Float = 1.0 / 60.0
            titleTime += step
            codexTime += step
            titleCam.angle = sinf(titleTime * 0.09) * 0.28
            titleCam.x += -sinf(titleCam.angle) * 26 * step
            titleCam.y += -cosf(titleCam.angle) * 26 * step
            let targetH = titleTerrain.heightF(titleCam.x, titleCam.y) + 95
            titleCam.height += (targetH - titleCam.height) * min(1, step * 2.5)
            audio.engine(on: false, speed: 0)
            titleMusic()

            // ENTER engages (starts the game); V closes (back to title).
            if input.restart && !restartLatch {
                restartLatch = true
                input.resetControls()
                audio.uiStart()
                lastTitleBeat = -1
                missionTime = 0
                state = .playing
            }
            if !input.restart { restartLatch = false }
            if (input.codex || input.back) && !codexLatch {
                codexLatch = true
                audio.uiStart()
                state = .title
            }
            if !input.codex && !input.back { codexLatch = false }

            titleVoxel.render(camera: titleCam)
            titleVoxel.drawCodex(time: codexTime)
            present(in: view, from: titleVoxel)
            return
        }

        // Warp cut-scene runs its own pipeline.
        if state == .warping {
            updateAndDrawWarp(dt: dt, in: view)
            return
        }

        // Pause toggle (edge-detected; only meaningful mid-game).
        if input.pause && !pauseLatch {
            if state == .playing { paused.toggle() }
            pauseLatch = true
        }
        if !input.pause { pauseLatch = false }

        let active = (state == .playing && !paused && !gamepad.configuring)
        // Flight (camera + scene motion) also continues on the PLANET CLEARED
        // screen — you keep flying until you choose to warp.
        let flying = ((state == .playing || state == .won) && !paused && !gamepad.configuring)

        if flying {
            camera.update(dt: dt, input: input, terrain: terrain)
        }
        voxel.render(camera: camera)

        if active {
            // Radial pulse weapon (feature flag): wipe every remaining craft.
            // No score for these kills. Clearing the field trips the normal
            // "planet cleared" win below.
            if input.pulse && !pulseLatch {
                pulseLatch = true
                if pulseCharges > 0 && enemies.remaining > 0 {
                    pulseCharges -= 1
                    let wreckage = enemies.obliterateAll()
                    combat.detonate(at: wreckage, smoke: smoke)
                    audio.pulse()
                }
            }
            if !input.pulse { pulseLatch = false }

            structures.tick(dt: dt)
            enemies.update(dt: dt, playerX: camera.x, playerY: camera.y, playerZ: camera.height,
                           structures: structures, projectiles: projectiles, bombs: bombs)
            // Player-fire hit-test BEFORE drawing sprites: the depth buffer
            // must hold terrain only, or a craft would occlude its own shot.
            combat.update(dt: dt, input: input, camera: camera, field: enemies, voxel: voxel, smoke: smoke,
                          crosshairX: RenderConfig.crosshairX, crosshairY: RenderConfig.crosshairY)
            // Advance enemy fire (hits drain hull) and the visible bombs
            // (aimed at structures — kept off the player by a far aim point).
            let hits = projectiles.update(dt: dt, playerX: camera.x, playerY: camera.y,
                                          playerZ: camera.height, terrain: terrain)
            _ = bombs.update(dt: dt, playerX: 1e9, playerY: 1e9, playerZ: 1e9, terrain: terrain)
            if hits > 0 {
                shield = max(0, shield - Float(hits) * 8)
                shieldRechargeDelay = 1.8            // hold off regen briefly after a hit
                damageFlash = min(1, damageFlash + 0.7)
            }
            // Shields recharge during a lull.
            if shieldRechargeDelay > 0 { shieldRechargeDelay -= dt }
            else { shield = min(maxShield, shield + 28 * dt) }
            damageFlash = max(0, damageFlash - dt * 2)
            // One-shot SFX from this frame's events (edge/delta detected).
            if combat.tracerActive && !prevTracer { audio.playerShot() }
            if combat.kills > prevKills { audio.kill() }
            if projectiles.shots.count > prevShots { audio.enemyShot() }
            if bombs.shots.count > prevBombs { audio.bomb() }
            if structures.standing < prevStanding {
                audio.structureLost()
                for (i, s) in structures.structures.enumerated() where !s.alive && !structureBurstDone.contains(i) {
                    structureBurstDone.insert(i)
                    smoke.burst(x: s.x, y: s.y, z: s.roofHeight, big: true)   // visible building explosion
                    comms.say("Command post lost")
                }
            }
            if hits > 0 { audio.shieldHit() }

            // Voice callouts (edge-triggered, rate-limited).
            // Warning states spread across the bar so "low → critical → down"
            // don't pile up in the final few hits: low at half shields, critical
            // at a fifth, then destroyed at zero. Re-arm with hysteresis above
            // each trigger so they don't chatter while hovering at a threshold.
            let sf = shield / maxShield
            if sf <= 0.25 && voiceCritArmed { comms.say("Shields critical"); voiceCritArmed = false }
            else if sf <= 0.50 && voiceLowArmed { comms.say("Shields low"); voiceLowArmed = false }
            if sf > 0.60 { voiceLowArmed = true }
            if sf > 0.35 { voiceCritArmed = true }

            attackCalloutTimer = max(0, attackCalloutTimer - dt)
            let curHP = structures.structures.reduce(0) { $0 + max(0, $1.health) }
            if curHP < prevVoiceStructHealth && attackCalloutTimer <= 0 {
                comms.say("Command post under attack"); attackCalloutTimer = 12
            }
            prevVoiceStructHealth = curHP

            let hasMother = enemies.enemies.contains { $0.kind == .mothership }
            if hasMother && !motherAnnounced { comms.say("Mothership detected"); motherAnnounced = true }
            if !hasMother { motherAnnounced = false }

            // Resolve lose / win.
            if shield <= 0 {
                loseReason = "SHIELDS DOWN"; onGameOver()
            } else if structures.structures.count > 0 && structures.standing == 0 {
                loseReason = "BASES LOST"; onGameOver()
            } else if enemies.remaining == 0 {
                state = .won; audio.planetCleared()
                comms.say("Attack fleet defeated")
                combat.clearTransient()                 // clear last laser/explosion
                projectiles = ProjectileField()         // and any in-flight ordnance
                bombs = ProjectileField()
            }
        } else if awaitingName {
            // Finalise the high-score entry when the player confirms.
            if input.nameCommitted {
                let nm = input.nameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                newScoreRank = highScores.add(name: nm.isEmpty ? "ANON" : nm,
                                              score: combat.score, level: level,
                                              stardate: stardateFmt.string(from: Date()))
                awaitingName = false
                input.nameEntryActive = false
                input.nameCommitted = false
            }
        } else if state == .won {
            // Keep flying; warp only on the dedicated WARP input (left trigger
            // / R), so a held fire button can't warp you the instant you clear.
            if input.warp && !warpLatch {
                warpLatch = true
                beginWarp()                     // cinematic + async next-planet gen
            }
        } else if state == .lost {
            if input.restart && !restartLatch {
                restartLatch = true
                level = 1
                combat = Combat()               // game over — fresh run
                pulseCharges = FeatureFlags.radialPulseWeapon ? 3 : 0
                missionTime = 0
                loadPlanet(1)
            }
        }
        if !input.restart { restartLatch = false }
        if !input.warp { warpLatch = false }

        if flying { smoke.update(dt: dt, structures: structures, maxHealth: structures.maxHealth) }

        voxel.drawEnemies(enemies, camera: camera)
        voxel.drawExplosions(combat.explosions, duration: combat.explosionDuration, camera: camera)
        voxel.drawProjectiles(bombs, camera: camera,                       // ordnance on bases — orange-red
                              glow: packRGBA(255, 120, 40), core: packRGBA(255, 220, 130))
        voxel.drawProjectiles(projectiles, camera: camera)                 // fire at you — hot yellow
        voxel.drawSmoke(smoke, camera: camera)                             // damage plumes + debris
        if combat.tracerActive {
            voxel.drawTracers(crosshairX: RenderConfig.crosshairX, crosshairY: RenderConfig.crosshairY)
        }
        voxel.drawDamageFlash(damageFlash)
        if active {
            voxel.drawCrosshair(x: RenderConfig.crosshairX, y: RenderConfig.crosshairY)
        }

        voxel.drawCockpit(score: combat.score,
                          basesStanding: structures.standing,
                          basesTotal: structures.structures.count,
                          aliens: enemies.remaining,
                          planetName: PlanetTheme.name(forLevel: level), level: level,
                          speed: Int(camera.speed),
                          altitude: max(0, Int(camera.height - terrain.heightF(camera.x, camera.y))),
                          shield: Int(shield), maxShield: Int(maxShield),
                          roll: camera.roll, pitch: camera.pitch)
        voxel.drawRadar(camera: camera, enemies: enemies, structures: structures)
        chrono(on: voxel)
        if FeatureFlags.radialPulseWeapon { voxel.drawPulseCharges(pulseCharges) }

        if paused && state == .playing {
            voxel.drawBanner(title: "PAUSED", subtitle: "PRESS P TO RESUME")
        } else {
            switch state {
            case .lost:
                if awaitingName {
                    voxel.drawNameEntry(score: combat.score, name: input.nameBuffer)
                } else {
                    voxel.drawGameOver(loseReason: loseReason, score: combat.score,
                                       scores: highScores.entries, highlight: newScoreRank)
                }
            case .won:
                // Reflect the live warp binding (default LT) rather than a fixed
                // label; mention the pad only when one is connected.
                let warpPrompt = gamepad.connected
                    ? "\(Gamepad.friendlyName(gamepad.binding(for: .warp))) / R TO WARP"
                    : "PRESS R TO WARP"
                voxel.drawBanner(title: "\(PlanetTheme.name(forLevel: level).uppercased()) SECURED",
                                 subtitle: "LEVEL \(level) CLEAR    \(warpPrompt)")
            case .playing, .title, .briefing, .codex, .warping:
                break
            }
        }

        // Engine hum while flying; resync SFX deltas for next frame.
        audio.engine(on: flying, speed: camera.speed)
        prevKills = combat.kills
        prevShots = projectiles.shots.count
        prevBombs = bombs.shots.count
        prevStanding = structures.standing
        prevTracer = combat.tracerActive

        present(in: view, from: voxel)
    }

    /// Upload the given renderer's framebuffer and blit it to the drawable.
    private func present(in view: MTKView, from vr: VoxelRenderer) {
        if FeatureFlags.showFPS { vr.drawFPS(Int(fpsSmoothed.rounded())) }
        if screenshotPending { screenshotPending = false; saveScreenshot(from: vr) }
        let region = MTLRegionMake2D(0, 0, RenderConfig.width, RenderConfig.height)
        texture.replace(region: region, mipmapLevel: 0,
                        withBytes: vr.framebuffer, bytesPerRow: bytesPerRow)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        // Letterbox: keep the framebuffer's native aspect inside whatever the
        // drawable is (maximised windows are rarely exactly 16:9). The pass
        // clears to black first, so the unused margins read as clean bars.
        let dw = Double(drawable.texture.width)
        let dh = Double(drawable.texture.height)
        if dw > 0, dh > 0 {
            let target = Double(RenderConfig.width) / Double(RenderConfig.height)
            var vw = dw, vh = dh, vx = 0.0, vy = 0.0
            if dw / dh > target {            // too wide → pillarbox (bars left/right)
                vw = dh * target; vx = (dw - vw) / 2
            } else {                          // too tall → letterbox (bars top/bottom)
                vh = dw / target; vy = (dh - vh) / 2
            }
            enc.setViewport(MTLViewport(originX: vx, originY: vy, width: vw, height: vh, znear: 0, zfar: 1))
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Fired once when a level begins playing (see the edge detector in update).
    private func onLevelStart() {
        // Easter egg: on May the 4th (or when forced for testing), a send-off.
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        if (c.month == 5 && c.day == 4) || FeatureFlags.forceMayTheFourth {
            comms.say("May the fourth be with you")
        }
    }

    /// Save the just-rendered framebuffer (feature flag) as a PNG on the Desktop,
    /// upscaled 4× nearest-neighbour (480×270 → 1920×1080) so the pixels stay
    /// crisp — ready for the README / product page / blog.
    private func saveScreenshot(from vr: VoxelRenderer) {
        let w = RenderConfig.width, h = RenderConfig.height
        guard let native = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let dst = native.bitmapData else { return }
        // Framebuffer is packed 0xAABBGGRR → little-endian bytes R,G,B,A, which
        // matches NSBitmapImageRep's default (alpha last, non-premultiplied).
        memcpy(dst, vr.framebuffer, w * h * 4)

        // Upscale 4× with no interpolation (hard pixel edges, no blur).
        let scale = 4, uw = w * scale, uh = h * scale
        guard let big = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: uw, pixelsHigh: uh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: uw * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: big) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .none
        native.draw(in: NSRect(x: 0, y: 0, width: uw, height: uh), from: .zero,
                    operation: .copy, fraction: 1, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.none.rawValue])
        NSGraphicsContext.restoreGraphicsState()

        guard let png = big.representation(using: .png, properties: [:]) else { return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Strataris \(fmt.string(from: Date())).png"
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = dir.appendingPathComponent(name)
        do { try png.write(to: url); audio.uiStart(); print("📸 screenshot → \(url.path) (\(uw)×\(uh))") }
        catch { print("screenshot failed: \(error)") }
    }
}
