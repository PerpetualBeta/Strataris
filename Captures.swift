// Strataris — headless screenshot harness (STRATARIS_SHOTS[=dir]=1).
//
// Renders the salient doc/marketing shots by driving the game's REAL draw
// methods (drawCanopyStruts / drawCockpit / warpConsole / drawGlobe /
// drawHyperspace / drawTitleScreen / drawCodex / drawBriefing / drawGameOver)
// in the same order the live game uses, plus the real GPU mesh renderer for the
// world — then writes each frame to a 4× nearest-neighbour PNG. The draw code
// is the shipping code, so the captures match the game pixel-for-pixel.
//
// Not part of the shipped behaviour — a dev/marketing tool, off unless the
// STRATARIS_SHOTS env var is set.

import Cocoa
import Metal
import simd

enum Captures {
    static func run(outDir: String) {
        setvbuf(stdout, nil, _IONBF, 0)
        let w = RenderConfig.width, h = RenderConfig.height
        let scale = 4

        // Output directory (env value, or ~/Desktop/Strataris-Shots if it was "1").
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirURL: URL = (outDir.isEmpty || outDir == "1")
            ? home.appendingPathComponent("Desktop/Strataris-Shots")
            : URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        print("Strataris screenshots → \(dirURL.path) (\(w * scale)×\(h * scale))")

        let device = MTLCreateSystemDefaultDevice()
        if device == nil { print("  ⚠︎ no Metal device — world shots skipped, 2D screens only") }

        var n = 0
        func save(_ canvas: Canvas2D, _ label: String) {
            n += 1
            let name = String(format: "%02d-%@.png", n, label)
            writePNG(canvas.framebuffer, w: w, h: h, scale: scale, to: dirURL.appendingPathComponent(name))
            print("  📸 \(name)")
        }

        // ---- shared scene helpers ------------------------------------------------

        // Wrap a world point into the camera's neighbourhood (mirrors Renderer).
        func wrapped(_ x: Float, _ y: Float, _ z: Float, cam: SIMD3<Float>, size: Float) -> SIMD3<Float> {
            let half = size * 0.5
            func near(_ v: Float, _ c: Float) -> Float {
                var d = (v - c).truncatingRemainder(dividingBy: size)
                if d > half { d -= size } else if d < -half { d += size }
                return c + d
            }
            return SIMD3(near(x, cam.x), near(y, cam.y), z)
        }
        func entities(_ field: EnemyField, cam: SIMD3<Float>, size: Float)
            -> [(kind: EnemyKind, model: simd_float4x4)] {
            field.enemies.map { e in
                var m = enemyModel(e, scale: field.scale(for: e.kind))
                m.columns.3 = SIMD4<Float>(wrapped(e.x, e.y, e.z, cam: cam, size: size), 1)
                return (kind: e.kind, model: m)
            }
        }

        // The full in-cockpit HUD, in gameplay order (HUD over world, struts over
        // that, console bent last). `blips` populates the radar.
        func panel(_ canvas: Canvas2D, planet: String, level: Int, score: Int,
                   bases: Int, basesTotal: Int, aliens: Int,
                   speed: Int, alt: Int, shield: Int, roll: Float, pitch: Float,
                   cam: SIMD3<Float>, field: EnemyField?, structs: StructureField?,
                   blips: Bool, crosshair: Bool = false) {
            if crosshair {
                canvas.drawCrosshair(x: Float(RenderConfig.crosshairX), y: Float(RenderConfig.crosshairY))
            }
            canvas.drawCanopyStruts()
            canvas.drawCockpit(score: score, basesStanding: bases, basesTotal: basesTotal,
                               aliens: aliens, planetName: planet, level: level,
                               speed: speed, altitude: alt, shield: shield, maxShield: 100,
                               roll: roll, pitch: pitch)
            canvas.drawRadar(originX: cam.x, originY: cam.y, fwdX: 0, fwdY: -1, rightX: -1, rightY: 0,
                             enemies: blips ? field : nil, structures: blips ? structs : nil)
            canvas.drawChronometer(date: "2026.06.06", clock: "19:08", mission: "01:30")
            canvas.warpConsole()
        }

        func globeColor(_ th: PlanetTheme) -> (Float, Float, Float) {
            ((Float(th.veg.0) + Float(th.water.0)) / 2,
             (Float(th.veg.1) + Float(th.water.1)) / 2,
             (Float(th.veg.2) + Float(th.water.2)) / 2)
        }
        func nebula(_ th: PlanetTheme) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat(th.skyTop.0) / 255, CGFloat(th.skyTop.1) / 255, CGFloat(th.skyTop.2) / 255)
        }

        // ---- world (mesh-backed) scene ------------------------------------------

        let theme = PlanetTheme.all[0]                       // Demeter — the hero world
        let terrain = Terrain(size: 4096, seed: 7, theme: theme)
        let size = Float(terrain.size)
        let cx: Float = 512, cy: Float = 512
        let structures = StructureField(terrain: terrain, around: cx, cy: cy, count: 5)
        let field = EnemyField(terrain: terrain, around: cx, cy: cy, count: 14)

        // Camera: low, just behind the dense sub-cluster of the fleet (≈ world
        // (640,−1130)) with a base nearby, looking into it so several craft and an
        // installation fill the view.
        let camPos = SIMD3<Float>(650, -800, terrain.heightF(650, -800) + 120)
        let gameCam = Camera6DOF.restricted(position: camPos, heading: 0, pitch: -0.22, bank: 0.05, speed: 150)
        let alt = max(0, Int(camPos.z - terrain.heightF(camPos.x, camPos.y)))

        var mesh: MeshTerrainRenderer? = nil
        if let device = device {
            mesh = MeshTerrainRenderer(device: device, terrain: terrain, width: w, height: h)
            mesh?.recenterIfNeeded(around: camPos, sync: true)
        }

        // Combat FX (built with the same recipe as Renderer.meshFX) for the action shot.
        func combatFX() -> [Billboard] {
            var fx = [Billboard]()
            // The base nearest the camera (so the FX land in frame, not behind us).
            let s = structures.structures.filter { $0.alive }
                .min { hypotf($0.x - camPos.x, $0.y - camPos.y) < hypotf($1.x - camPos.x, $1.y - camPos.y) }
            if let s = s {
                let c = wrapped(s.x, s.y, terrain.heightF(s.x, s.y) + 14, cam: camPos, size: size)
                fx.append(Billboard(center: c, size: 30, color: SIMD4(1.0, 0.82, 0.40, 0.9), additive: true))
                fx.append(Billboard(center: c, size: 52, color: SIMD4(1.0, 0.45, 0.16, 0.5), additive: true))
                for k in 0..<5 {
                    let p = wrapped(s.x + Float(k) * 6, s.y, terrain.heightF(s.x, s.y) + 30 + Float(k) * 12,
                                    cam: camPos, size: size)
                    fx.append(Billboard(center: p, size: 14 + Float(k) * 4, color: SIMD4(0.5, 0.5, 0.55, 0.45), additive: false))
                }
            }
            // a couple of tracer bolts converging downrange
            for e in field.enemies.prefix(2) {
                fx.append(Billboard(center: wrapped(e.x, e.y, e.z, cam: camPos, size: size),
                                    size: 4, color: SIMD4(1, 1, 0.6, 1), additive: true))
            }
            return fx
        }

        // 1 — Title screen (wordmark over a live-style backdrop).
        do {
            let canvas = Canvas2D(width: w, height: h, mapSize: size)
            if let mesh = mesh {
                mesh.renderInto(canvas.framebuffer, camera: gameCam, entities: entities(field, cam: camPos, size: size))
            }
            canvas.drawTitleScreen(time: 0.3, topName: "ACE", topScore: 48250,
                                   startHint: "Press Fire to Start",
                                   configHint: "[K] Configure Keyboard",
                                   nebula: nebula(theme))
            save(canvas, "title")
        }

        // 2 — Gameplay hero (full cockpit over the battle).
        if let mesh = mesh {
            let canvas = Canvas2D(width: w, height: h, mapSize: size)
            mesh.renderInto(canvas.framebuffer, camera: gameCam,
                            entities: entities(field, cam: camPos, size: size))
            panel(canvas, planet: theme.name, level: 1, score: 12840,
                  bases: 5, basesTotal: 5, aliens: field.remaining,
                  speed: 150, alt: alt, shield: 100, roll: 0.05, pitch: -0.22,
                  cam: camPos, field: field, structs: structures, blips: true, crosshair: true)
            save(canvas, "gameplay")
        }

        // 3 — Combat moment (explosion + smoke + tracers).
        if let mesh = mesh {
            let canvas = Canvas2D(width: w, height: h, mapSize: size)
            mesh.renderInto(canvas.framebuffer, camera: gameCam,
                            entities: entities(field, cam: camPos, size: size), fx: combatFX())
            canvas.drawTracers(crosshairX: Float(RenderConfig.crosshairX), crosshairY: Float(RenderConfig.crosshairY))
            panel(canvas, planet: theme.name, level: 1, score: 13620,
                  bases: 4, basesTotal: 5, aliens: max(0, field.remaining - 2),
                  speed: 168, alt: alt, shield: 72, roll: -0.10, pitch: -0.22,
                  cam: camPos, field: field, structs: structures, blips: true, crosshair: true)
            save(canvas, "combat")
        }

        // 4 — Level clear (SECURED banner + bases-saved bonus).
        if let mesh = mesh {
            let canvas = Canvas2D(width: w, height: h, mapSize: size)
            mesh.renderInto(canvas.framebuffer, camera: gameCam)
            panel(canvas, planet: theme.name, level: 1, score: 18900,
                  bases: 5, basesTotal: 5, aliens: 0,
                  speed: 150, alt: alt, shield: 100, roll: 0.05, pitch: -0.22,
                  cam: camPos, field: field, structs: structures, blips: false)
            canvas.drawBanner(title: "\(theme.name.uppercased()) SECURED",
                              subtitle: "5/5 BASES SAVED   +2500    PRESS R TO WARP")
            save(canvas, "level-clear")
        }

        // 5 — Warp: leaving orbit (banked away, departed planet w/ atmosphere).
        do {
            let canvas = Canvas2D(width: w, height: h, mapSize: size)
            canvas.clearSpace(3.0)
            canvas.drawGlobe(cx: w / 2 + 150, cy: h / 2 + 22, r: 78,
                             base: globeColor(theme), time: 2.0)
            panel(canvas, planet: theme.name, level: 1, score: 18900,
                  bases: 5, basesTotal: 5, aliens: 0,
                  speed: 30, alt: 9000, shield: 100, roll: -0.55, pitch: 0,
                  cam: camPos, field: nil, structs: nil, blips: false)
            canvas.drawUnicodeCentered("LEAVING ORBIT", y: Int(Float(h) * 0.12), fontSize: 14, 0.82, 0.9, 1.0)
            save(canvas, "warp-orbit")
        }

        // 6 — Warp: hyperspace.
        do {
            let canvas = Canvas2D(width: w, height: h, mapSize: size)
            canvas.drawHyperspace(time: 1.4, progress: 0.62)
            panel(canvas, planet: theme.name, level: 2, score: 18900,
                  bases: 5, basesTotal: 5, aliens: 0,
                  speed: 30, alt: 0, shield: 100, roll: 0, pitch: 0,
                  cam: camPos, field: nil, structs: nil, blips: false)
            canvas.drawUnicodeCentered("HYPERSPACE", y: Int(Float(h) * 0.12), fontSize: 16, 0.85, 0.92, 1.0)
            save(canvas, "warp-hyperspace")
        }

        // 7 — Warp: approaching the next world.
        do {
            let next = PlanetTheme.all[1]                    // Tantalus
            let canvas = Canvas2D(width: w, height: h, mapSize: size)
            canvas.clearSpace(14.0)
            canvas.drawGlobe(cx: w / 2, cy: h / 2, r: 104, base: globeColor(next), time: 3.0)
            panel(canvas, planet: next.name, level: 2, score: 18900,
                  bases: 0, basesTotal: 5, aliens: 0,
                  speed: 30, alt: 6000, shield: 100, roll: 0, pitch: 0,
                  cam: camPos, field: nil, structs: nil, blips: false)
            canvas.drawUnicodeCentered("APPROACHING \(next.name.uppercased())",
                                       y: Int(Float(h) * 0.12), fontSize: 13, 0.85, 0.92, 1.0)
            save(canvas, "warp-approach")
        }

        // 8 — Enemy codex.
        do {
            let canvas = Canvas2D(width: w, height: h, mapSize: size)
            if let mesh = mesh {
                mesh.renderInto(canvas.framebuffer, camera: gameCam, entities: entities(field, cam: camPos, size: size))
            }
            canvas.drawCodex(time: 0.7)
            save(canvas, "codex")
        }

        // 9 — Mission briefing.
        do {
            let canvas = Canvas2D(width: w, height: h, mapSize: size)
            if let mesh = mesh {
                mesh.renderInto(canvas.framebuffer, camera: gameCam, entities: entities(field, cam: camPos, size: size))
            }
            canvas.drawBriefing(time: 18.0)
            save(canvas, "briefing")
        }

        // 10 — Game over (high-score table).
        do {
            let canvas = Canvas2D(width: w, height: h, mapSize: size)
            if let mesh = mesh { mesh.renderInto(canvas.framebuffer, camera: gameCam) }
            let scores = [
                HighScoreEntry(name: "ACE",   score: 48250, level: 9, stardate: "20260606::1908"),
                HighScoreEntry(name: "NOVA",  score: 31100, level: 6, stardate: "20260604::2140"),
                HighScoreEntry(name: "ZIG",   score: 18900, level: 4, stardate: "20260606::1912"),
                HighScoreEntry(name: "ORBIT", score:  9400, level: 3, stardate: "20260601::1015"),
                HighScoreEntry(name: "REX",   score:  4200, level: 2, stardate: "20260530::0902"),
            ]
            canvas.drawGameOver(loseReason: "COLONY OVERRUN", score: 18900, scores: scores, highlight: 2)
            save(canvas, "game-over")
        }

        print("✅ \(n) screenshots written")
    }

    /// Write a packed-RGBA framebuffer to a `scale`× nearest-neighbour PNG.
    private static func writePNG(_ fb: UnsafeMutablePointer<UInt32>, w: Int, h: Int, scale: Int, to url: URL) {
        guard let native = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let dst = native.bitmapData else { return }
        memcpy(dst, fb, w * h * 4)
        let uw = w * scale, uh = h * scale
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
        try? png.write(to: url)
    }
}
