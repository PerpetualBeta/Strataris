// Strataris — headless screenshot harness (STRATARIS_SHOTS[=dir]=1).
//
// Renders the salient doc/marketing shots by driving the game's REAL draw
// methods (drawCanopyStruts / drawCockpit / warpConsole / drawGlobe /
// drawHyperspace / drawTitleScreen / drawCodex / drawBriefing / drawGameOver)
// plus the real GPU mesh renderer for the world — then writes each frame to a
// 4× nearest-neighbour PNG. The draw code is the shipping code, so the captures
// match the game pixel-for-pixel.
//
// To make the shots sell the game, the world scenes are staged: a different
// planet per shot, and dense attack formations (built as GPU entity transforms
// directly, so we control how many craft fill the frame) with a firefight of
// explosions, smoke and tracer bolts. Not part of the shipped behaviour — a
// dev/marketing tool, off unless STRATARIS_SHOTS is set.

import Cocoa
import Metal
import simd

enum Captures {
    static func run(outDir: String) {
        setvbuf(stdout, nil, _IONBF, 0)
        let w = RenderConfig.width, h = RenderConfig.height
        let scale = 4

        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirURL: URL = (outDir.isEmpty || outDir == "1")
            ? home.appendingPathComponent("Desktop/Strataris-Shots")
            : URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        print("Strataris screenshots → \(dirURL.path) (\(w * scale)×\(h * scale))")

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("  ⚠︎ no Metal device — cannot render world shots; aborting."); return
        }

        var n = 0
        func save(_ canvas: Canvas2D, _ label: String) {
            n += 1
            let name = String(format: "%02d-%@.png", n, label)
            writePNG(canvas.framebuffer, w: w, h: h, scale: scale, to: dirURL.appendingPathComponent(name))
            print("  📸 \(name)")
        }

        // Deterministic pseudo-random in [0,1) from an index + salt.
        func rnd(_ i: Int, _ salt: Int) -> Float {
            var x = UInt32(truncatingIfNeeded: (i &+ 1) &* 73_856_093 ^ (salt &+ 1) &* 19_349_663)
            x = (x ^ (x >> 13)) &* 1_274_126_177
            return Float((x >> 8) & 0xFFFF) / 65535.0
        }
        func col3(_ m: simd_float4x4) -> SIMD3<Float> { let c = m.columns.3; return SIMD3(c.x, c.y, c.z) }

        // A craft transform matching enemyModel's basis (right, fwd, up, pos).
        func craftModel(_ pos: SIMD3<Float>, _ fwd: SIMD3<Float>, _ s: Float) -> simd_float4x4 {
            let f = simd_normalize(simd_length(fwd) < 1e-4 ? SIMD3(0, 1, 0) : fwd)
            var r = simd_cross(f, SIMD3<Float>(0, 0, 1))
            if simd_length(r) < 1e-4 { r = SIMD3(1, 0, 0) }
            r = simd_normalize(r)
            let u = simd_cross(r, f)
            return simd_float4x4(columns: (SIMD4(r * s, 0), SIMD4(f * s, 0), SIMD4(u * s, 0), SIMD4(pos, 1)))
        }
        func scaleFor(_ k: EnemyKind) -> Float {
            switch k { case .destroyer: return 22; case .fighter: return 16; case .drone: return 12; case .mothership: return 62 }
        }

        // A dense swarm bearing down on the colony, ahead of the camera (−Y),
        // spread across the frame at mixed depths/altitudes/kinds, facing the
        // player. `count` craft + a mothership anchoring the back.
        func formation(cam: SIMD3<Float>, count: Int, terrain: Terrain, seed: Int)
            -> [(kind: EnemyKind, model: simd_float4x4)] {
            var out = [(kind: EnemyKind, model: simd_float4x4)]()
            for i in 0..<count {
                let t = Float(i) / Float(max(1, count - 1))
                let depth = 90 + t * 660 + (rnd(i, seed) - 0.5) * 90
                let spread = 70 + depth * 0.6
                let px = cam.x + (rnd(i, seed + 1) - 0.5) * 2 * spread
                let py = cam.y - depth
                let agl = 26 + rnd(i, seed + 2) * 150 + (1 - t) * 30
                let pz = terrain.heightF(px, py) + agl
                let r = rnd(i, seed + 3)
                let kind: EnemyKind = r < 0.55 ? .drone : (r < 0.85 ? .fighter : .destroyer)
                var fwd = SIMD3<Float>(cam.x - px, cam.y - py, (cam.z - pz) * 0.5)
                fwd.x += (rnd(i, seed + 4) - 0.5) * 0.7 * simd_length(fwd)   // banking jitter
                out.append((kind, craftModel(SIMD3(px, py, pz), fwd, scaleFor(kind))))
            }
            // Mothership: high and far, centre-ish — the looming threat.
            let mp = SIMD3<Float>(cam.x + 40, cam.y - 760, terrain.heightF(cam.x + 40, cam.y - 760) + 230)
            out.append((.mothership, craftModel(mp, SIMD3(0, 1, -0.1), scaleFor(.mothership))))
            return out
        }

        // A firefight: big, dynamic explosion blooms across the swarm, smoke
        // plumes, the player's bolts streaking out to several targets, and enemy
        // bolts raining back.
        func storm(cam: SIMD3<Float>, ents: [(kind: EnemyKind, model: simd_float4x4)], seed: Int) -> [Billboard] {
            var fx = [Billboard]()
            if ents.isEmpty { return fx }
            // explosions (additive core + glow) — dynamic blooms
            for k in 0..<3 {
                let c = col3(ents[(k * 7 + 3) % ents.count].model)
                let s = 26 + Float(k) * 8
                fx.append(Billboard(center: c, size: s,       color: SIMD4(1.0, 0.82, 0.40, 0.95), additive: true))
                fx.append(Billboard(center: c, size: s * 1.7, color: SIMD4(1.0, 0.45, 0.16, 0.5),  additive: true))
            }
            // smoke plumes from a couple of stricken craft
            for k in 0..<2 {
                let base = col3(ents[(k * 5 + 1) % ents.count].model)
                for j in 0..<5 {
                    let p = base + SIMD3<Float>(Float(j) * 5, Float(j) * 3, 24 + Float(j) * 16)
                    fx.append(Billboard(center: p, size: 12 + Float(j) * 5, color: SIMD4(0.5, 0.5, 0.55, 0.5 - Float(j) * 0.07), additive: false))
                }
            }
            // player bolts — streaks from the ship nose to several craft
            let muzzle = SIMD3<Float>(cam.x, cam.y - 24, cam.z - 12)
            for k in 0..<5 {
                let target = col3(ents[(k * 4 + 2) % ents.count].model)
                for s in 0...6 {
                    let f = Float(s) / 6
                    fx.append(Billboard(center: muzzle + (target - muzzle) * f, size: 4, color: SIMD4(1, 1, 0.6, 1), additive: true))
                }
            }
            // enemy bolts raining toward the player
            for k in 0..<9 {
                let src = col3(ents[(k * 3) % ents.count].model)
                fx.append(Billboard(center: src + (muzzle - src) * (0.25 + rnd(k, seed + 9) * 0.5), size: 5, color: SIMD4(1, 0.4, 0.2, 1), additive: true))
            }
            return fx
        }

        // Colony installations as 3D model instances (mirrors Renderer).
        func buildings(_ field: StructureField, _ terr: Terrain, cam: SIMD3<Float>) -> [BuildingInstance] {
            let size = Float(terr.size), halfS = size * 0.5
            func wrap(_ v: Float, _ c: Float) -> Float {
                var d = (v - c).truncatingRemainder(dividingBy: size)
                if d > halfS { d -= size } else if d < -halfS { d += size }
                return c + d
            }
            return field.structures.map { st in
                let padZ = terr.heightF(st.x, st.y), s = Float(st.half)
                let yaw = Float((Int(st.x) ^ Int(st.y)) & 7) * 0.18, cs = cosf(yaw), sn = sinf(yaw)
                let m = simd_float4x4(columns: (
                    SIMD4<Float>(cs * s, sn * s, 0, 0), SIMD4<Float>(-sn * s, cs * s, 0, 0),
                    SIMD4<Float>(0, 0, s, 0), SIMD4<Float>(wrap(st.x, cam.x), wrap(st.y, cam.y), padZ, 1)))
                if !st.alive { return (kind: .rubble, model: m, tint: SIMD4<Float>(1, 1, 1, 0)) }
                let f = max(0, min(1, Float(st.health) / Float(field.maxHealth)))
                let charred = SIMD3<Float>(0.85, 0.45, 0.38)
                let t = charred + (SIMD3<Float>(1, 1, 1) - charred) * f
                return (kind: st.kind, model: m, tint: SIMD4<Float>(t.x, t.y, t.z, 0))
            }
        }

        func globeColor(_ th: PlanetTheme) -> (Float, Float, Float) {
            ((Float(th.veg.0) + Float(th.water.0)) / 2,
             (Float(th.veg.1) + Float(th.water.1)) / 2,
             (Float(th.veg.2) + Float(th.water.2)) / 2)
        }
        func nebula(_ th: PlanetTheme) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat(th.skyTop.0) / 255, CGFloat(th.skyTop.1) / 255, CGFloat(th.skyTop.2) / 255)
        }

        // The named worlds (index into PlanetTheme.all): Demeter, Tantalus,
        // Boreas, Pandora, Vulcan, Vesper.
        let mesh = MeshTerrainRenderer(device: device, terrain: Terrain(size: 4096, seed: 1, theme: PlanetTheme.all[0]), width: w, height: h)
        guard let mesh = mesh else { print("  ⚠︎ mesh renderer init failed"); return }

        // Build a world scene (terrain swapped in, swarm + optional firefight
        // rendered) and return the canvas + camera + a busy radar field.
        struct Scene { let canvas: Canvas2D; let cam: SIMD3<Float>; let theme: PlanetTheme
                       let field: EnemyField; let structs: StructureField; let alt: Int }
        func world(_ themeIdx: Int, seed: Int, alt: Float, pitch: Float, bank: Float,
                   count: Int, fire: Bool) -> Scene {
            let theme = PlanetTheme.all[themeIdx]
            let terrain = Terrain(size: 4096, seed: UInt32(seed), theme: theme)
            let structs = StructureField(terrain: terrain, around: 512, cy: 512, count: 5)   // stamped into terrain
            mesh.setTerrain(terrain)
            let camPos = SIMD3<Float>(512, 760, terrain.heightF(512, 760) + alt)
            mesh.recenterIfNeeded(around: camPos, sync: true)
            let cam6 = Camera6DOF.restricted(position: camPos, heading: 0, pitch: pitch, bank: bank, speed: 150)
            let ents = formation(cam: camPos, count: count, terrain: terrain, seed: seed)
            let canvas = Canvas2D(width: w, height: h, mapSize: Float(terrain.size))
            mesh.renderInto(canvas.framebuffer, camera: cam6, entities: ents,
                            structures: buildings(structs, terrain, cam: camPos),
                            fx: fire ? storm(cam: camPos, ents: ents, seed: seed) : [])
            let field = EnemyField(terrain: terrain, around: 512, cy: 512, count: 26)         // busy radar
            return Scene(canvas: canvas, cam: camPos, theme: theme, field: field, structs: structs,
                         alt: max(0, Int(camPos.z - terrain.heightF(camPos.x, camPos.y))))
        }

        // The in-cockpit HUD in gameplay order (HUD over world, struts over that,
        // console bent last).
        func hud(_ s: Scene, score: Int, bases: Int, aliens: Int, speed: Int, shield: Int,
                 roll: Float, pitch: Float, blips: Bool, crosshair: Bool) {
            if crosshair { s.canvas.drawCrosshair(x: Float(RenderConfig.crosshairX), y: Float(RenderConfig.crosshairY)) }
            s.canvas.drawCanopyStruts()
            s.canvas.drawCockpit(score: score, basesStanding: bases, basesTotal: 5, aliens: aliens,
                                 planetName: s.theme.name, level: 1, speed: speed, altitude: s.alt,
                                 shield: shield, maxShield: 100, roll: roll, pitch: pitch)
            s.canvas.drawRadar(originX: s.cam.x, originY: s.cam.y, fwdX: 0, fwdY: -1, rightX: -1, rightY: 0,
                               enemies: blips ? s.field : nil, structures: blips ? s.structs : nil)
            s.canvas.drawChronometer(date: "2026.06.06", clock: "19:08", mission: "01:30")
            s.canvas.warpConsole()
        }

        // A space panel (warp transit): no world, banked/level dial, empty radar.
        func spacePanel(_ canvas: Canvas2D, planet: String, level: Int, roll: Float, alt: Int) {
            canvas.drawCanopyStruts()
            canvas.drawCockpit(score: 24300, basesStanding: 5, basesTotal: 5, aliens: 0,
                               planetName: planet, level: level, speed: 30, altitude: alt,
                               shield: 100, maxShield: 100, roll: roll, pitch: 0)
            canvas.drawRadar(originX: 512, originY: 512, fwdX: 0, fwdY: -1, rightX: -1, rightY: 0,
                             enemies: nil, structures: nil)
            canvas.drawChronometer(date: "2026.06.06", clock: "19:08", mission: "02:05")
            canvas.warpConsole()
        }
        let labelY = Int(Float(h) * 0.12)

        // ===== shots =============================================================

        // 1 — Title (Demeter), swarm behind the wordmark.
        do {
            let s = world(0, seed: 7, alt: 110, pitch: -0.16, bank: 0.04, count: 18, fire: false)
            s.canvas.drawTitleScreen(time: 0.3, topName: "ACE", topScore: 48250,
                                     startHint: "Press Fire to Start", configHint: "[K] Configure Keyboard",
                                     nebula: nebula(s.theme))
            save(s.canvas, "title")
        }

        // 2 — Gameplay hero (Vesper) — dense incoming swarm.
        do {
            let s = world(5, seed: 21, alt: 105, pitch: -0.20, bank: 0.06, count: 22, fire: false)
            hud(s, score: 12840, bases: 5, aliens: s.field.remaining, speed: 150, shield: 100,
                roll: 0.06, pitch: -0.20, blips: true, crosshair: true)
            save(s.canvas, "gameplay")
        }

        // 3 — Combat (Vulcan) — full firefight.
        do {
            let s = world(4, seed: 33, alt: 100, pitch: -0.18, bank: -0.10, count: 26, fire: true)
            s.canvas.drawTracers(crosshairX: Float(RenderConfig.crosshairX), crosshairY: Float(RenderConfig.crosshairY))
            hud(s, score: 21360, bases: 3, aliens: s.field.remaining, speed: 178, shield: 64,
                roll: -0.10, pitch: -0.18, blips: true, crosshair: true)
            save(s.canvas, "combat")
        }

        // 4 — Combat (Pandora) — a second, different firefight (alt hero).
        do {
            let s = world(3, seed: 51, alt: 120, pitch: -0.24, bank: 0.12, count: 24, fire: true)
            s.canvas.drawTracers(crosshairX: Float(RenderConfig.crosshairX), crosshairY: Float(RenderConfig.crosshairY))
            hud(s, score: 33820, bases: 4, aliens: s.field.remaining, speed: 168, shield: 80,
                roll: 0.12, pitch: -0.24, blips: true, crosshair: true)
            save(s.canvas, "combat-2")
        }

        // 5 — Level clear (Boreas) — banner over a few stragglers.
        do {
            let s = world(2, seed: 14, alt: 110, pitch: -0.20, bank: 0.03, count: 6, fire: false)
            hud(s, score: 41200, bases: 5, aliens: 0, speed: 150, shield: 100,
                roll: 0.03, pitch: -0.20, blips: false, crosshair: false)
            s.canvas.drawBanner(title: "\(s.theme.name.uppercased()) SECURED",
                                subtitle: "5/5 BASES SAVED   +2500    PRESS R TO WARP")
            save(s.canvas, "level-clear")
        }

        // 6 — Warp: leaving orbit (departing Pandora).
        do {
            let canvas = Canvas2D(width: w, height: h, mapSize: 4096)
            canvas.clearSpace(3.0)
            canvas.drawGlobe(cx: w / 2 + 150, cy: h / 2 + 22, r: 78, base: globeColor(PlanetTheme.all[3]), time: 2.0)
            spacePanel(canvas, planet: "Pandora", level: 4, roll: -0.55, alt: 9000)
            canvas.drawUnicodeCentered("LEAVING ORBIT", y: labelY, fontSize: 14, 0.82, 0.9, 1.0)
            save(canvas, "warp-orbit")
        }

        // 7 — Warp: hyperspace.
        do {
            let canvas = Canvas2D(width: w, height: h, mapSize: 4096)
            canvas.drawHyperspace(time: 1.4, progress: 0.62)
            spacePanel(canvas, planet: "Pandora", level: 5, roll: 0, alt: 0)
            canvas.drawUnicodeCentered("HYPERSPACE", y: labelY, fontSize: 16, 0.85, 0.92, 1.0)
            save(canvas, "warp-hyperspace")
        }

        // 8 — Warp: approaching the next world (Tantalus).
        do {
            let next = PlanetTheme.all[1]
            let canvas = Canvas2D(width: w, height: h, mapSize: 4096)
            canvas.clearSpace(14.0)
            canvas.drawGlobe(cx: w / 2, cy: h / 2, r: 104, base: globeColor(next), time: 3.0)
            spacePanel(canvas, planet: next.name, level: 5, roll: 0, alt: 6000)
            canvas.drawUnicodeCentered("APPROACHING \(next.name.uppercased())", y: labelY, fontSize: 13, 0.85, 0.92, 1.0)
            save(canvas, "warp-approach")
        }

        // 9 — Enemy codex (Tantalus backdrop).
        do {
            let s = world(1, seed: 9, alt: 110, pitch: -0.18, bank: 0, count: 12, fire: false)
            s.canvas.drawCodex(time: 0.7)
            save(s.canvas, "codex")
        }

        // 10 — Mission briefing (Vesper backdrop).
        do {
            let s = world(5, seed: 5, alt: 110, pitch: -0.18, bank: 0, count: 12, fire: false)
            s.canvas.drawBriefing(time: 18.0)
            save(s.canvas, "briefing")
        }

        // 11 — Game over (Vulcan) — firefight frozen under the table.
        do {
            let s = world(4, seed: 41, alt: 100, pitch: -0.20, bank: 0, count: 22, fire: true)
            let scores = [
                HighScoreEntry(name: "ACE",   score: 48250, level: 9, stardate: "20260606::1908"),
                HighScoreEntry(name: "NOVA",  score: 31100, level: 6, stardate: "20260604::2140"),
                HighScoreEntry(name: "ZIG",   score: 18900, level: 4, stardate: "20260606::1912"),
                HighScoreEntry(name: "ORBIT", score:  9400, level: 3, stardate: "20260601::1015"),
                HighScoreEntry(name: "REX",   score:  4200, level: 2, stardate: "20260530::0902"),
            ]
            s.canvas.drawGameOver(loseReason: "COLONY OVERRUN", score: 18900, scores: scores, highlight: 2)
            save(s.canvas, "game-over")
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
