// Strataris — Metal presentation layer.
//
// The canvas engine renders on the CPU into a small RGBA framebuffer; this
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
import simd

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
    private var canvas: Canvas2D
    private var enemies: EnemyField
    private var combat = Combat()
    private var camera: Camera
    private var titleCam: Camera        // drifting cinematic camera for the attract flyover
    private let input: InputState

    // GPU mesh-terrain renderer (true 6DOF-capable; the default). The legacy
    // `camera6` is the authoritative quaternion flight camera; the legacy
    // `Camera` is a derived scalar bridge (x/y/height/angle/roll/pitch/speed)
    // that the HUD, radar, enemy AI and engine audio still read.
    private let mesh: MeshTerrainRenderer
    private var camera6 = Camera6DOF.start(position: SIMD3<Float>(512, 512, 200))
    /// Smoothed scope heading for the radar: full-6DOF maneuvers can whip (steep
    /// bank) or flip (over the top of a loop) the raw ground heading; the scope
    /// eases toward it by shortest arc instead, and holds it while near-vertical.
    private var radarHeading: Float = 0

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
    private var gameOverDwell: Float = 0    // seconds before the game-over screen accepts input
    private var wonTime: Float = 0          // time on the PLANET CLEARED screen (banner fade)
    private var pauseLatch = false
    private var warpLatch = false
    private var briefingLatch = false
    private var briefingTime: Float = 0     // scroll clock for the briefing crawl
    private var codexLatch = false
    private var codexTime: Float = 0        // spin clock for the codex models
    private var backLatch = false           // Esc on the game-over screen → title

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
    private var pulseLatch = false
    private var wasPlaying = false              // edge-detect level start (Easter egg)

    // Per-run level-up perks (enabled by default; availability is a pure function
    // of `level`, so it resets automatically when `level` resets to 1).
    private var hasTargetingComputer: Bool { level >= 6 }
    private var hasCloak: Bool { level >= 9 }
    private var hasRadialPulse: Bool { level >= 12 }
    /// Full 6DOF (loops, rolls, yaw) — the level-3 Axis Unlock perk.
    private var hasAxisUnlock: Bool { level >= 3 }
    private var pulseCharges = 0                // radial pulse: granted at level 12
    private var targetLockId: Int? = nil        // targeting computer: locked craft (stable id)
    private var cloakActive: Float = 0          // seconds of cloak remaining (>0 = cloaked)
    private var cloakCooldown: Float = 0        // seconds until cloak usable again
    private var cloakLatch = false
    private let cloakDuration: Float = 10
    private let cloakRecharge: Float = 60
    private var perkBanner: String? = nil       // transient "PERK ONLINE" / bonus notification
    private var perkBannerTimer: Float = 0

    // Voice-callout edge tracking.
    private var voiceLowArmed = true, voiceCritArmed = true
    private var prevVoiceStructHealth = 0
    private var attackCalloutTimer: Float = 0
    private var motherAnnounced = false
    private var structureBurstDone = Set<Int>()    // bases already given a death burst

    // Warp cut-scene state (async terrain gen + cinematic phases).
    private var warpPhase = 0
    private var warpTime: Float = 0
    private var warpCam = Camera(x: 0, y: 0, height: 0, angle: 0)
    private var warpReady = false
    private var warpTerrain: Terrain?
    private var warpStructures: StructureField?
    private var warpEnemies: EnemyField?
    private let warpPhaseDur: [Float] = [2.0, 1.8, 2.2, 1.6, 2.2]   // ascent, orbit, hyper, approach, descent

    // A separate, randomly-themed mini-world for the title flyover, so the
    // attract scene varies each launch WITHOUT changing the deterministic
    // game planets.
    private var titleTerrain: Terrain
    private var titleStructures: StructureField   // ctor stamps bases into titleTerrain (mesh renders them)

    // Edge/delta tracking for one-shot SFX.
    private var prevKills = 0, prevShots = 0, prevBombs = 0, prevStanding = 0
    private var prevTracer = false
    private var lastTitleBeat = -1

    // Title-music sequencer clock, driven by a BACKGROUND GCD timer: the render
    // loop stalls during menu tracking / window drags, and even main-run-loop
    // timers miss beats while AppKit opens a menu synchronously. A background
    // queue is immune to all of it; audio.trigger is lock-guarded and
    // thread-safe. (Reading `state` off-main is a benign race — at worst the
    // theme starts/stops one tick late.)
    private let musicQueue = DispatchQueue(label: "cc.jorviksoftware.strataris.music")
    private var musicSource: DispatchSourceTimer?
    private var musicClock: Double = 0
    private var lastMusicTick: Double = 0

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
        self.canvas = Canvas2D(width: w, height: h, mapSize: Float(t.size))
        self.camera = Camera.start(over: t)
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
        self.titleStructures = StructureField(terrain: tt, around: 512, cy: 512, count: 5, seed: tSeed ^ 0xABCD)
        self.titleCam = Camera.start(over: tt)

        // Build the GPU mesh-terrain renderer for planet 1 (the world renderer).
        guard let m = MeshTerrainRenderer(device: device, terrain: t, width: w, height: h) else {
            fatalError("Strataris: could not build the mesh terrain renderer")
        }
        self.mesh = m

        super.init()
        resetCamera6(over: terrain)

        // Dev aid: STRATARIS_LEVEL=n launches the first run at level n (perk
        // fly-testing without clearing planets). Restarts return to level 1.
        if let n = ProcessInfo.processInfo.environment["STRATARIS_LEVEL"].flatMap({ Int($0) }), n > 1 {
            level = n
            loadPlanet(n)
        }

        // The attract flyover shows the random title world; the mesh was built
        // with the game terrain (planet 1), swapped back in on ENGAGE.
        if state == .title { mesh.setTerrain(titleTerrain) }

        // Title-theme sequencer: a background timer, so nothing the main thread
        // does (menu tracking, synchronous menu opening, window drags, sheets)
        // can starve the music mid-theme.
        lastMusicTick = CACurrentMediaTime()
        let src = DispatchSource.makeTimerSource(queue: musicQueue)
        src.schedule(deadline: .now(), repeating: .milliseconds(25))
        src.setEventHandler { [weak self] in self?.musicTick() }
        src.resume()
        musicSource = src
    }

    /// Advance the title-music clock and sequence the next notes (title /
    /// briefing / codex only — gameplay has no music, just the world's audio).
    /// Runs on `musicQueue`.
    private func musicTick() {
        let now = CACurrentMediaTime()
        let dt = min(0.25, now - lastMusicTick)
        lastMusicTick = now
        guard state == .title || state == .briefing || state == .codex else { return }
        musicClock += dt
        titleMusic()
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
        canvas.mapSize = Float(t.size)     // radar wrap; the canvas itself is reused
        enemies = EnemyField(terrain: t, around: 512, cy: 512,
                             count: Renderer.enemyCount(forPlanet: n),
                             difficulty: Renderer.difficulty(forPlanet: n),
                             seed: seed ^ 0x00DE_F123)
        camera = Camera.start(over: t)
        mesh.setTerrain(t)                 // off the hot path (load / restart): sync is fine
        resetCamera6(over: t)
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
    ///
    /// Sequenced from `musicTimer` (not the render loop) so it keeps playing
    /// while AppKit's event tracking stalls MTKView's frame timer.
    private func titleMusic() {
        let step = Int(musicClock / 0.19)       // slow + grave
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

    /// Detect level-up perk unlocks as the player advances. Called from
    /// `beginWarp` after `level` increments, so a perk earned by "reaching level
    /// N" becomes usable on planet N. One-time per level (level only increments).
    private func unlockPerks(reaching lvl: Int) {
        switch lvl {
        case 3:  notify("AXIS UNLOCK — FULL MANEUVERING")
        case 6:  notify("TARGETING COMPUTER ONLINE")
        case 9:  notify("CLOAKING DEVICE ONLINE"); cloakActive = 0; cloakCooldown = 0
        case 12: pulseCharges = 3; notify("RADIAL PULSE ARMED")
        default: break
        }
        // Bonus points at level 15 and every third level thereafter.
        if lvl >= 15 && (lvl - 15) % 3 == 0 {
            combat.awardBonus(5000)
            notify("BONUS +5000")
        }
    }

    private func notify(_ text: String) { perkBanner = text; perkBannerTimer = 4 }

    // MARK: Flight

    /// Min altitude above terrain — small, so you can dive and skim the hills.
    private let meshClearance: Float = 22
    private let meshThrottle: (min: Float, max: Float, accel: Float) = (20, 280, 140)

    /// Spawn / reset the authoritative 6DOF flight camera over a terrain.
    private func resetCamera6(over t: Terrain) {
        let g = t.heightF(512, 512)
        camera6 = Camera6DOF.start(position: SIMD3<Float>(512, 512, g + 90))
        camera6.speed = 90
        radarHeading = camera6.groundHeading
    }

    /// Authoritative flight in mesh mode: the proven spike model — fly along the
    /// real forward vector through a quaternion camera. Levels 1–2 use the
    /// restricted envelope (coordinated bank-turn, clamped pitch, auto-level on
    /// release); from level 3 the Axis Unlock perk opens the full envelope
    /// (free roll/pitch + a yaw axis — loops and rolls, auto-level hands-off).
    /// The legacy `Camera` is then synced FROM this so the HUD, radar, enemy AI
    /// and engine audio keep reading it unchanged.
    private func updateMeshFlight(dt: Float) {
        // Throttle.
        if input.faster { camera6.speed = min(meshThrottle.max, camera6.speed + meshThrottle.accel * dt) }
        if input.slower { camera6.speed = max(meshThrottle.min, camera6.speed - meshThrottle.accel * dt) }

        // Envelope tracks the perk (a pure function of level, so it resets with
        // the run); setMode keeps the view continuous across the switch.
        camera6.setMode(hasAxisUnlock ? .full : .restricted)

        // The `climb` field is nose-down/descend, `dive` is nose-up/climb
        // (GameView/Gamepad already fold in the Invert-pitch setting), and
        // flyRestricted/flyFull's positive pitch is nose-UP → pitchIn = dive − climb.
        let turn = (input.bankLeft ? 1 : 0) - (input.bankRight ? 1 : 0)
        let pitchIn = (input.dive ? 1 : 0) - (input.climb ? 1 : 0)

        // Flight envelope trim (Settings): multipliers on the tuned handling rates.
        let trim = GameSettings.shared
        let agility = trim.trimAgility, autoLevel = trim.trimAutoLevel

        if camera6.mode == .full {
            // Full 6DOF (Axis Unlock): left/right roll, up/down pitch, A/D (or
            // right stick) yaw. Hands-off eases back upright from any attitude
            // (even inverted); banking still turns like an aircraft.
            let yaw = (input.yawLeft ? 1 : 0) - (input.yawRight ? 1 : 0)
            if turn == 0 && pitchIn == 0 && yaw == 0 {
                camera6.autoLevelFull(dt: dt, rate: 1.6 * autoLevel)
            } else {
                camera6.flyFull(pitch: Float(pitchIn), yaw: Float(yaw), roll: Float(-turn), dt: dt,
                                rate: 1.9 * agility, yawRate: 1.1 * trim.trimYaw)
            }
            camera6.bankToTurn(dt: dt)
        } else {
            // Restricted (levels 1–2): coordinated bank-turn + clamped pitch.
            camera6.flyRestricted(turn: Float(turn), pitchIn: Float(pitchIn), dt: dt,
                                  yawRate: 1.4 * agility, pitchRate: 1.4 * agility,
                                  levelRate: 2.5 * autoLevel)
        }

        // Fly along the real facing, so pitching the nose actually climbs/dives.
        camera6.position += camera6.forward * camera6.speed * dt

        // Terrain-follow floor (ride up over hills) + soft ceiling.
        let ground = terrain.heightF(camera6.position.x, camera6.position.y)
        camera6.position.z = max(camera6.position.z, ground + meshClearance)
        camera6.position.z = min(camera6.position.z, 460)

        // Ease the radar's scope heading toward the true ground heading (shortest
        // arc, ~0.1 s time constant — imperceptible in restricted flight, steadies
        // the scope through full-6DOF rolls/loops). Hold while near-vertical: the
        // facing has no usable ground component there, so the heading is noise.
        let fwd = camera6.forward
        if fwd.x * fwd.x + fwd.y * fwd.y > 0.0025 {
            var d = camera6.groundHeading - radarHeading
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            radarHeading += d * min(1, dt * 10)
        }

        // Sync the legacy camera for everything that still reads it.
        camera.x = camera6.position.x
        camera.y = camera6.position.y
        camera.height = camera6.position.z
        camera.angle = camera6.groundHeading
        camera.speed = camera6.speed
        // Attitude dial: drawAttitude exaggerates bank ×3 (tuned for the canvas
        // build's tiny cosmetic roll), so pre-divide to show the TRUE bank angle —
        // it should read the same tilt as the 3D horizon. Pitch maps the ±0.5 rad
        // envelope onto the dial's ±80 scale (clamped: full-6DOF pitch can exceed
        // the dial's range — a flat dial is best-effort near vertical/inverted).
        camera.roll = camera6.bankAngle / 3
        camera.pitch = max(-80, min(80, camera6.pitchAngle / 0.5 * 80))
    }

    /// Re-express a world position in the camera's wrap neighbourhood: the map
    /// tiles every `terrain.size` units, so pick the image of (x, y) nearest the
    /// camera — otherwise craft/effects across the wrap seam render a full map
    /// away (fogged out, invisible) instead of right next door. Mirrors the
    /// wrap the radar and enemy AI apply.
    private func meshWrapped(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        let size = Float(terrain.size), h = size * 0.5
        func near(_ v: Float, _ c: Float) -> Float {
            var d = (v - c).truncatingRemainder(dividingBy: size)
            if d > h { d -= size } else if d < -h { d += size }
            return c + d
        }
        return SIMD3(near(x, camera6.position.x), near(y, camera6.position.y), z)
    }

    /// Craft as GPU entity transforms (kind + world model matrix), wrapped into
    /// the camera's neighbourhood.
    private func meshEntities() -> [(kind: EnemyKind, model: simd_float4x4)] {
        enemies.enemies.map { e in
            var m = enemyModel(e, scale: enemies.scale(for: e.kind))
            m.columns.3 = SIMD4<Float>(meshWrapped(e.x, e.y, e.z), 1)
            return (kind: e.kind, model: m)
        }
    }

    /// Map the live effect state to camera-facing billboards for the 3D pass:
    /// explosions (additive core + glow), smoke (alpha) / embers (additive), and
    /// enemy bolts / falling bombs (additive).
    private func meshFX() -> [Billboard] {
        var fx = [Billboard]()
        for ex in combat.explosions {
            let t = max(0, min(1, ex.age / combat.explosionDuration)), a = 1 - t
            let size = 16 + t * 34, c = meshWrapped(ex.x, ex.y, ex.z)
            fx.append(Billboard(center: c, size: size,       color: SIMD4(1.0, 0.82, 0.40, a),         additive: true))
            fx.append(Billboard(center: c, size: size * 1.7, color: SIMD4(1.0, 0.45, 0.16, a * 0.55),  additive: true))
        }
        for p in smoke.particles {
            let t = max(0, min(1, p.age / p.life)), c = meshWrapped(p.x, p.y, p.z)
            if p.fire {
                fx.append(Billboard(center: c, size: 6 + t * 6, color: SIMD4(1.0, 0.6 - t * 0.3, 0.2, (1 - t) * 0.9), additive: true))
            } else {
                fx.append(Billboard(center: c, size: 7 + t * 14, color: SIMD4(0.5, 0.5, 0.55, (1 - t) * 0.5), additive: false))
            }
        }
        for s in projectiles.shots { fx.append(Billboard(center: meshWrapped(s.x, s.y, s.z), size: 4, color: SIMD4(1, 1, 0.6, 1), additive: true)) }
        for s in bombs.shots       { fx.append(Billboard(center: meshWrapped(s.x, s.y, s.z), size: 5, color: SIMD4(1, 0.5, 0.2, 1), additive: true)) }
        return fx
    }

    /// Project a craft through the quaternion camera (mesh mode), matching where
    /// the GPU pass draws it. nil if behind the camera / off-screen.
    private func meshProject(enemyAt idx: Int) -> (x: Float, y: Float, depth: Float, radiusScale: Float)? {
        guard enemies.enemies.indices.contains(idx) else { return nil }
        let e = enemies.enemies[idx]
        return camera6.project(meshWrapped(e.x, e.y, e.z),
                               width: RenderConfig.width, height: RenderConfig.height)
    }

    /// Nearest craft (by depth) whose projected billboard the centre reticle is
    /// over. Terrain occlusion is best-effort (skipped) — craft hover clear of
    /// the ground.
    private func meshTargetedEnemy() -> Int? {
        let cx = RenderConfig.crosshairX, cy = RenderConfig.crosshairY
        var best: Int? = nil, bestDepth = Float.greatestFiniteMagnitude
        for (i, e) in enemies.enemies.enumerated() {
            guard let p = meshProject(enemyAt: i) else { continue }
            let r = min(enemies.scale(for: e.kind) * p.radiusScale, Float(RenderConfig.height) * 4) + 4
            if abs(cx - p.x) > r || abs(cy - p.y) > r { continue }
            if p.depth < bestDepth { bestDepth = p.depth; best = i }
        }
        return best
    }

    /// Nearest-to-reticle craft within `zone` px, ranked by 2D screen distance.
    private func meshLockableEnemy(zone: Float) -> Int? {
        let cx = RenderConfig.crosshairX, cy = RenderConfig.crosshairY
        var best: Int? = nil, bestD2 = zone * zone
        for (i, _) in enemies.enemies.enumerated() {
            guard let p = meshProject(enemyAt: i) else { continue }
            let dx = cx - p.x, dy = cy - p.y, d2 = dx * dx + dy * dy
            if d2 < bestD2 { bestD2 = d2; best = i }
        }
        return best
    }

    /// Targeting computer: keep the current lock while the craft stays within the
    /// target zone (100px of the reticle); otherwise acquire the nearest craft in
    /// the zone. Re-resolving the stable id each frame survives array compaction.
    private func updateTargetLock() {
        let cx = RenderConfig.crosshairX, cy = RenderConfig.crosshairY
        let zone: Float = 100
        if let id = targetLockId {
            var inZone = false
            if let idx = enemies.index(forId: id), let p = meshProject(enemyAt: idx) {
                let dx = cx - p.x, dy = cy - p.y; inZone = sqrtf(dx * dx + dy * dy) <= zone
            }
            if inZone { return }                    // lock still valid and in-zone
            targetLockId = nil                      // died, left view, or left the zone
        }
        if let idx = meshLockableEnemy(zone: zone) { targetLockId = enemies.enemies[idx].id }
    }

    /// Start the warp: generate the next planet on a background thread while a
    /// cinematic plays, so there's no freeze.
    private func beginWarp() {
        level += 1
        unlockPerks(reaching: level)
        state = .warping
        warpPhase = 0; warpTime = 0; warpReady = false
        warpTerrain = nil; warpStructures = nil; warpEnemies = nil
        warpCam = camera                                  // ascent continues from here
        audio.whoosh(rising: true)                        // lift-off

        let p = level
        let seed = Renderer.planetSeed(p)
        let theme = PlanetTheme.forPlanet(p)
        let ec = Renderer.enemyCount(forPlanet: p), diff = Renderer.difficulty(forPlanet: p)
        DispatchQueue.global(qos: .userInitiated).async {
            let t = Terrain(seed: seed, theme: theme)
            let str = StructureField(terrain: t, around: 512, cy: 512, count: 5, seed: seed ^ 0x00AB_CDEF)
            let en = EnemyField(terrain: t, around: 512, cy: 512, count: ec, difficulty: diff, seed: seed ^ 0x00DE_F123)
            DispatchQueue.main.async {
                self.warpTerrain = t
                self.warpStructures = str; self.warpEnemies = en
                self.warpReady = true
                self.mesh.stageTerrain(t)       // build the new patch off-thread for an instant commit
            }
        }
    }

    private func finalizeWarp() {
        guard let t = warpTerrain, let str = warpStructures, let en = warpEnemies else { return }
        terrain = t; structures = str; enemies = en      // score (combat) carries over
        canvas.mapSize = Float(t.size)                   // radar wrap for the new world
        camera = Camera.start(over: t)
        mesh.commitStagedTerrain(fallback: t)                         // instant swap (staged during the cut-scene)
        resetCamera6(over: t)
        projectiles = ProjectileField(); bombs = ProjectileField(); smoke = SmokeField(terrain: t)
        shield = maxShield; shieldRechargeDelay = 0; damageFlash = 0
        combat.clearTransient()
        voiceLowArmed = true; voiceCritArmed = true; motherAnnounced = false
        attackCalloutTimer = 0; prevVoiceStructHealth = 0; structureBurstDone.removeAll()
        input.resetControls()
        warpTerrain = nil; warpStructures = nil; warpEnemies = nil
        state = .playing
    }

    /// Draw the dashboard chronometer (live stardate/clock + mission-elapsed time).
    private func chrono(on vox: Canvas2D) {
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
                    warpCam = Camera.start(over: warpTerrain ?? terrain)
                    warpCam.x = 512; warpCam.y = 512; warpCam.angle = 0
                    // The descent flies over the NEW world, so commit the staged
                    // patch now (finalizeWarp's commit becomes a no-op).
                    if let nt = warpTerrain { mesh.commitStagedTerrain(fallback: nt) }
                }
                if warpPhase >= 5 { finalizeWarp(); return }
            }
        }
        let W = RenderConfig.width, H = RenderConfig.height
        let p = min(1, warpTime / warpPhaseDur[min(warpPhase, 4)])

        // Ship ambience: loud rumble in atmosphere (ascent/descent), quiet hum in space.
        audio.engine(on: true, speed: (warpPhase == 0 || warpPhase == 4) ? 260 : 30)

        // Draws the cockpit instrument cluster + radar over the cut-scene, so we
        // stay "in the ship" the whole time (no sudden EVA). The radar scope is
        // empty in transit (`blips: false`) — contact drops the moment we depart,
        // and the new world's blips only paint on the descent.
        func panel(_ vox: Canvas2D, _ cam: Camera, _ str: StructureField, _ en: EnemyField, _ t: Terrain,
                   blips: Bool) {
            let alt = max(0, Int(cam.height - t.heightF(cam.x, cam.y)))
            vox.drawCockpit(score: combat.score, basesStanding: str.standing, basesTotal: str.structures.count,
                            aliens: en.remaining, planetName: PlanetTheme.name(forLevel: level), level: level,
                            speed: Int(cam.speed), altitude: alt,
                            shield: Int(shield), maxShield: Int(maxShield), roll: cam.roll, pitch: cam.pitch)
            vox.drawRadar(camera: cam, enemies: blips ? en : nil, structures: blips ? str : nil)
            chrono(on: vox)
        }
        let labelY = Int(Float(H) * 0.12)

        switch warpPhase {
        case 0:   // ascent — climb out of the current world
            warpCam.height = camera.height + p * p * 1400
            warpCam.x += -sinf(warpCam.angle) * 36 * dt
            warpCam.y += -cosf(warpCam.angle) * 36 * dt
            // Climb through the live engine: the nose lifts as the climb steepens,
            // so departure matches gameplay seamlessly.
            let ascentPos = SIMD3<Float>(warpCam.x, warpCam.y, warpCam.height)
            let ascentCam = Camera6DOF.restricted(position: ascentPos, heading: warpCam.angle,
                                                  pitch: 0.5 * p, bank: 0, speed: 260)
            mesh.recenterIfNeeded(around: ascentPos)
            mesh.renderInto(canvas.framebuffer, camera: ascentCam)
            canvas.dimScreen(p > 0.7 ? (p - 0.7) / 0.3 : 0)
            panel(canvas, warpCam, structures, enemies, terrain, blips: false)
            canvas.drawUnicodeCentered("DEPARTING", y: labelY, fontSize: 14, 0.82, 0.9, 1.0)
            present(in: view, from: canvas)
        case 1:   // orbit — the planet we left, shrinking
            canvas.clearSpace(warpTime)
            canvas.drawGlobe(cx: W / 2, cy: H / 2 - Int(18 * p), r: max(1, Int(120 - 84 * p)),
                            base: globeColor(terrain.theme))
            panel(canvas, warpCam, structures, enemies, terrain, blips: false)
            canvas.drawUnicodeCentered("LEAVING ORBIT", y: labelY, fontSize: 14, 0.82, 0.9, 1.0)
            present(in: view, from: canvas)
        case 2:   // hyperspace
            canvas.drawHyperspace(time: warpTime, progress: p)
            panel(canvas, warpCam, structures, enemies, terrain, blips: false)
            canvas.drawUnicodeCentered("HYPERSPACE", y: labelY, fontSize: 16, 0.85, 0.92, 1.0)
            present(in: view, from: canvas)
        case 3:   // approach — the new planet growing
            canvas.clearSpace(warpTime + 11)
            canvas.drawGlobe(cx: W / 2, cy: H / 2, r: Int(20 + 112 * p),
                            base: globeColor(warpTerrain?.theme ?? terrain.theme))
            panel(canvas, warpCam, structures, enemies, terrain, blips: false)
            canvas.drawUnicodeCentered("APPROACHING \(PlanetTheme.name(forLevel: level).uppercased())", y: labelY, fontSize: 13, 0.85, 0.92, 1.0)
            present(in: view, from: canvas)
        default:  // 4: descent — drop into the new world
            if let nt = warpTerrain, let ns = warpStructures, let ne = warpEnemies {
                let g = nt.heightF(512, 512)
                let pe = 1 - (1 - p) * (1 - p)              // ease out
                warpCam.height = (g + 760) + ((g + 140) - (g + 760)) * pe
                // The staged patch was committed at phase entry, so the mesh
                // already holds the NEW world: flare in nose-high and settle
                // level as the altitude bleeds off — no renderer cut at the
                // playing handoff. No recenter here: the stride-1 patch is
                // exactly what gameplay resumes on, and re-LODding for the brief
                // high-altitude pass would just thrash rebuilds — the close fog
                // at entry reads as re-entry haze burning off.
                let pos = SIMD3<Float>(warpCam.x, warpCam.y, warpCam.height)
                let c6 = Camera6DOF.restricted(position: pos, heading: warpCam.angle,
                                               pitch: 0.45 * (1 - p), bank: 0, speed: 260)
                mesh.renderInto(canvas.framebuffer, camera: c6)
                canvas.dimScreen(p < 0.3 ? (0.3 - p) / 0.3 : 0)
                panel(canvas, warpCam, ns, ne, nt, blips: true)
                canvas.drawUnicodeCentered("\(PlanetTheme.name(forLevel: level).uppercased())   ·   LEVEL \(level)", y: labelY, fontSize: 14, 0.85, 0.92, 1.0)
                present(in: view, from: canvas)
            }
        }
    }

    /// Enter the lost state, and begin name entry if the run made the table.
    private func onGameOver() {
        state = .lost
        audio.gameOver()
        // Arm the edge latches: you usually die with fire still held, and with
        // "fire also starts/restarts" that would skip the game-over screen on the
        // very next frame. Held controls must be RELEASED before they can act.
        restartLatch = true
        backLatch = true
        // …and you're usually still TAPPING fire in the heat of the moment, so a
        // released-then-pressed fire would skip it too. Hold the screen for a
        // moment before it accepts any input (classic arcade game-over dwell).
        gameOverDwell = 1.2
        newScoreRank = -1
        if highScores.qualifies(combat.score) {
            awaitingName = true
            input.nameEntryActive = true
            input.nameBuffer = ""
            input.nameCommitted = false
        }
    }

    /// Abandon the current run and go back to the attract/title screen, leaving
    /// a fresh planet 1 staged so the next ENTER starts a clean game (the title
    /// → playing transition doesn't reload a planet itself).
    /// Clear all per-run perk state (called when a fresh run begins).
    private func resetPerks() {
        pulseCharges = 0
        targetLockId = nil
        cloakActive = 0; cloakCooldown = 0; cloakLatch = false
        perkBanner = nil; perkBannerTimer = 0
    }

    private func returnToTitle() {
        level = 1
        combat = Combat()
        resetPerks()
        missionTime = 0
        loadPlanet(1)           // stage a clean run (also sets state = .playing)…
        state = .title          // …but show the attract screen until ENGAGE
        mesh.setTerrain(titleTerrain)          // attract flyover shows the title world
        input.resetControls()
        lastTitleBeat = -1; musicClock = 0      // restart the title theme cleanly
        audio.uiStart()
    }

    /// Advance the attract-screen flyover and render its backdrop through the
    /// mesh renderer into the shared canvas framebuffer. Shared by the title,
    /// briefing and codex states (each then draws its own 2D overlay on top).
    /// The legacy `titleCam` path math is unchanged; it drives a `Camera6DOF`
    /// exactly as the warp ascent does. The 2D overlays composite afterwards.
    private func attractFlyover() {
        let step: Float = 1.0 / 60.0
        titleTime += step
        titleCam.angle = sinf(titleTime * 0.09) * 0.28
        titleCam.x += -sinf(titleCam.angle) * 26 * step
        titleCam.y += -cosf(titleCam.angle) * 26 * step
        // Ease altitude so it doesn't snap as we cross terrain cells (the jitter).
        let targetH = titleTerrain.heightF(titleCam.x, titleCam.y) + 95
        titleCam.height += (targetH - titleCam.height) * min(1, step * 2.5)
        audio.engine(on: false, speed: 0)
        // (Title music is sequenced by musicTimer, not per-frame here.)

        let pos = SIMD3<Float>(titleCam.x, titleCam.y, titleCam.height)
        let c6 = Camera6DOF.restricted(position: pos, heading: titleCam.angle,
                                       pitch: 0, bank: 0, speed: titleCam.speed)
        mesh.recenterIfNeeded(around: pos)
        mesh.renderInto(canvas.framebuffer, camera: c6)
    }

    /// ENGAGE from an attract screen → begin play. Swaps the mesh terrain back
    /// to the game world (the title showed the random attract world).
    private func engageFromTitle() {
        restartLatch = true
        input.resetControls()        // start neutral, not mid-turn
        audio.uiStart()
        lastTitleBeat = -1
        missionTime = 0              // fresh mission clock
        mesh.setTerrain(terrain)    // back to the game world (planet 1)
        state = .playing
    }

    func draw(in view: MTKView) {
        // Frame clock. First frame establishes the baseline; clamp dt so a
        // hitch (or a breakpoint) can't fling the camera across the map.
        let now = CACurrentMediaTime()
        if lastTime == 0 { lastTime = now }
        let dt = Float(min(1.0 / 20.0, max(0.0, now - lastTime)))
        lastTime = now
        if state != .title && state != .lost && !paused { missionTime += dt }   // mission clock
        // Perk notification fades only during play, so one set at warp-out (perks
        // unlock as the warp begins) still shows its full span on the new planet.
        if state == .playing && !paused && perkBannerTimer > 0 { perkBannerTimer -= dt }

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
            attractFlyover()                 // randomly-themed flyover (mesh renderer)

            if input.restart && !restartLatch { engageFromTitle() }
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

            canvas.drawTitleScreen(time: titleTime,
                                  topName: highScores.entries.first?.name,
                                  topScore: highScores.entries.first?.score ?? 0)
            present(in: view, from: canvas)
            return
        }

        // Mission briefing — a scrolling transmission over the attract flyover.
        if state == .briefing {
            attractFlyover()
            briefingTime += 1.0 / 60.0

            // ENTER engages (starts the game); B stands down (back to title).
            if input.restart && !restartLatch { engageFromTitle() }
            if !input.restart { restartLatch = false }
            if (input.briefing || input.back) && !briefingLatch {
                briefingLatch = true
                audio.uiStart()
                state = .title
            }
            if !input.briefing && !input.back { briefingLatch = false }

            canvas.drawBriefing(time: briefingTime)
            present(in: view, from: canvas)
            return
        }

        // Enemy-craft codex — rotating model database over the attract flyover.
        if state == .codex {
            attractFlyover()
            codexTime += 1.0 / 60.0

            // ENTER engages (starts the game); V closes (back to title).
            if input.restart && !restartLatch { engageFromTitle() }
            if !input.restart { restartLatch = false }
            if (input.codex || input.back) && !codexLatch {
                codexLatch = true
                audio.uiStart()
                state = .title
            }
            if !input.codex && !input.back { codexLatch = false }

            canvas.drawCodex(time: codexTime)
            present(in: view, from: canvas)
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
            // Fly the authoritative 6DOF camera; the legacy `camera` is synced
            // from it for the HUD/radar/AI/audio that still read scalar fields.
            updateMeshFlight(dt: dt)
        }
        // The world is rendered after the game logic (below): it projects through
        // `camera6` and draws the final craft positions for the frame.

        if active {
            // Radial pulse weapon (feature flag): wipe every remaining craft.
            // No score for these kills. Clearing the field trips the normal
            // "planet cleared" win below.
            if input.pulse && !pulseLatch {
                pulseLatch = true
                if hasRadialPulse && pulseCharges > 0 && enemies.remaining > 0 {
                    pulseCharges -= 1
                    let wreckage = enemies.obliterateAll()
                    combat.detonate(at: wreckage, smoke: smoke)
                    audio.pulse()
                }
            }
            if !input.pulse { pulseLatch = false }

            // Cloaking device (perk, level 9): 10s invisible, 60s recharge after
            // it ends. Cooldown persists across warps (not refilled by finalizeWarp).
            if input.cloak && !cloakLatch {
                cloakLatch = true
                if hasCloak && cloakActive <= 0 && cloakCooldown <= 0 {
                    cloakActive = cloakDuration
                    audio.whoosh(rising: false)
                }
            }
            if !input.cloak { cloakLatch = false }
            if cloakActive > 0 {
                cloakActive = max(0, cloakActive - dt)
                if cloakActive == 0 { cloakCooldown = cloakRecharge }   // recharge starts when cloak ends
            } else if cloakCooldown > 0 {
                cloakCooldown = max(0, cloakCooldown - dt)
            }

            structures.tick(dt: dt)
            enemies.update(dt: dt, playerX: camera.x, playerY: camera.y, playerZ: camera.height,
                           structures: structures, projectiles: projectiles, bombs: bombs,
                           playerCloaked: cloakActive > 0)
            // Targeting computer (perk, level 6): keep/refresh the lock BEFORE the
            // fire hit-test so fire can be redirected to the locked craft.
            if hasTargetingComputer { updateTargetLock() } else { targetLockId = nil }
            var lockedIdx = targetLockId.flatMap { enemies.index(forId: $0) }
            // Resolve the fire target through the quaternion projection. A
            // targeting-computer lock wins; otherwise fire follows whatever's
            // under the reticle (nil ⇒ fire but miss, tracer only).
            if lockedIdx == nil { lockedIdx = meshTargetedEnemy() }
            combat.update(dt: dt, input: input, field: enemies, smoke: smoke,
                          lockedTargetIndex: lockedIdx)
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
            if curHP < prevVoiceStructHealth {
                // A base was damaged or destroyed → the heightfield was re-stamped
                // (crumble look / ground restored). Rebuild the mesh patch so the
                // change shows up; the canvas path samples live, so it's a no-op there.
                mesh.markTerrainDirty()
                if attackCalloutTimer <= 0 { comms.say("Command post under attack"); attackCalloutTimer = 12 }
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
                state = .won; audio.planetCleared(); wonTime = 0
                warpLatch = true; restartLatch = true   // a held warp/fire mustn't skip the screen
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
            gameOverDwell = max(0, gameOverDwell - dt)
            if gameOverDwell <= 0 && input.restart && !restartLatch {
                restartLatch = true
                level = 1
                combat = Combat()               // game over — fresh run
                resetPerks()
                missionTime = 0
                loadPlanet(1)
            }
            // Esc on the high-score table backs out to the title screen. (During
            // name entry the key system swallows Esc, so this only fires once the
            // table is showing — exactly when the player expects it.)
            if gameOverDwell <= 0 && input.back && !backLatch && !awaitingName {
                backLatch = true
                returnToTitle()
            }
        }
        if !input.back { backLatch = false }
        if !input.restart { restartLatch = false }
        if !input.warp { warpLatch = false }

        if flying { smoke.update(dt: dt, structures: structures, maxHealth: structures.maxHealth) }

        // World render: the GPU mesh pass draws terrain + craft + effects and
        // reads the frame back into the framebuffer; everything below composites
        // 2D over it.
        mesh.recenterIfNeeded(around: camera6.position)
        mesh.renderInto(canvas.framebuffer, camera: camera6,
                        entities: meshEntities(), fx: meshFX())
        // Targeting computer: red dotted box around the locked craft.
        if hasTargetingComputer, let li = targetLockId.flatMap({ enemies.index(forId: $0) }),
           let p = meshProject(enemyAt: li) {
            canvas.drawLockBox(screenX: p.x, screenY: p.y,
                              half: enemies.scale(for: enemies.enemies[li].kind) * p.radiusScale,
                              color: packRGBA(255, 60, 60))
        }
        if combat.tracerActive {
            // Bolts converge on the locked craft when the targeting computer
            // has a lock, otherwise on the fixed reticle.
            var tx = RenderConfig.crosshairX, ty = RenderConfig.crosshairY
            if hasTargetingComputer, let li = targetLockId.flatMap({ enemies.index(forId: $0) }),
               let p = meshProject(enemyAt: li) {
                tx = p.x; ty = p.y
            }
            canvas.drawTracers(crosshairX: tx, crosshairY: ty)
        }
        canvas.drawDamageFlash(damageFlash)
        if active {
            canvas.drawCrosshair(x: RenderConfig.crosshairX, y: RenderConfig.crosshairY)
        }

        canvas.drawCockpit(score: combat.score,
                          basesStanding: structures.standing,
                          basesTotal: structures.structures.count,
                          aliens: enemies.remaining,
                          planetName: PlanetTheme.name(forLevel: level), level: level,
                          speed: Int(camera.speed),
                          altitude: max(0, Int(camera.height - terrain.heightF(camera.x, camera.y))),
                          shield: Int(shield), maxShield: Int(maxShield),
                          roll: camera.roll, pitch: camera.pitch)
        // Scope basis from the SMOOTHED ground heading (not the raw camera
        // basis): at steep bank/pitch the basis vectors' ground projections
        // collapse and whip around — deriving an orthonormal basis from one
        // eased heading keeps the scope steady through rolls and loops.
        // Handedness matches camera6's (at heading 0: fwd (0,-1), right (-1,0)).
        let fx = -sinf(radarHeading), fy = -cosf(radarHeading)
        canvas.drawRadar(originX: camera6.position.x, originY: camera6.position.y,
                        fwdX: fx, fwdY: fy, rightX: fy, rightY: -fx,
                        enemies: enemies, structures: structures)
        chrono(on: canvas)
        if hasRadialPulse { canvas.drawPulseCharges(pulseCharges) }
        if hasCloak { canvas.drawCloakStatus(active: cloakActive, cooldown: cloakCooldown) }
        if let banner = perkBanner, perkBannerTimer > 0, state != .title, state != .lost {
            canvas.drawNotification(banner, t: perkBannerTimer)
        }

        if paused && state == .playing {
            canvas.drawBanner(title: "PAUSED", subtitle: "PRESS P TO RESUME")
        } else {
            switch state {
            case .lost:
                if awaitingName {
                    canvas.drawNameEntry(score: combat.score, name: input.nameBuffer)
                } else {
                    canvas.drawGameOver(loseReason: loseReason, score: combat.score,
                                       scores: highScores.entries, highlight: newScoreRank)
                }
            case .won:
                // Reflect the live warp binding (default LT) rather than a fixed
                // label; mention the pad only when one is connected.
                let warpPrompt = gamepad.connected
                    ? "\(Gamepad.friendlyName(gamepad.binding(for: .warp))) / R TO WARP"
                    : "PRESS R TO WARP"
                // After 10 s the banner ghosts down so the player can free-fly the
                // cleared world with a clear view.
                wonTime += dt
                let fade: Float = wonTime < 10 ? 1 : max(0.1, 1 - (wonTime - 10) * 0.9)  // → 0.1 over 1 s
                canvas.drawBanner(title: "\(PlanetTheme.name(forLevel: level).uppercased()) SECURED",
                                 subtitle: "LEVEL \(level) CLEAR    \(warpPrompt)",
                                 opacity: fade)
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

        present(in: view, from: canvas)
    }

    /// Upload the given renderer's framebuffer and blit it to the drawable.
    private func present(in view: MTKView, from vr: Canvas2D) {
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
    private func saveScreenshot(from vr: Canvas2D) {
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
