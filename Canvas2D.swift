// Strataris — 2D canvas (HUD, cutscenes, codex, text).
//
// A packed-RGBA framebuffer the Metal layer uploads as a texture and upscales
// nearest-neighbour (deliberately low-res for the period look). The GPU mesh
// renderer reads the 3D frame back INTO this framebuffer, then everything here
// composites the 2D layer on top: the cockpit dashboard + dials, radar,
// crosshair / tracers / lock box, damage flash, perk HUD, banners, the warp
// space cutscenes (starfield / globe / hyperspace), the title logo, the
// briefing crawl, the rotating-mesh codex, and all the bitmap/Core-Text glyphs.
// Being a plain CPU canvas (no GPU dependency for the 2D layer) is also what
// lets the headless SmokeTest at the bottom exercise it without a window.

import Foundation
import QuartzCore
import Metal     // SmokeTest's best-effort GPU render check

final class Canvas2D {
    let width: Int
    let height: Int
    let framebuffer: UnsafeMutablePointer<UInt32>

    /// Map wrap size for the radar scope (the world tiles every `mapSize` units).
    /// Set by the renderer whenever the terrain changes; the canvas itself holds
    /// no terrain reference.
    var mapSize: Float

    init(width: Int, height: Int, mapSize: Float) {
        self.width = width
        self.height = height
        self.mapSize = mapSize
        self.framebuffer = .allocate(capacity: width * height)
    }

    deinit {
        framebuffer.deallocate()
    }

    /// Flat triangle fill with NO depth test — for UI/codex models that paint
    /// over the framebuffer in their own painter's order (terrain depth ignored).
    private func fillTriFlat(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float,
                             _ cx: Float, _ cy: Float, _ color: UInt32) {
        let minX = max(0, Int(min(ax, min(bx, cx)).rounded(.down)))
        let maxX = min(width - 1, Int(max(ax, max(bx, cx)).rounded(.up)))
        let minY = max(0, Int(min(ay, min(by, cy)).rounded(.down)))
        let maxY = min(height - 1, Int(max(ay, max(by, cy)).rounded(.up)))
        if minX > maxX || minY > maxY { return }
        let area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        if abs(area) < 1e-4 { return }
        let inv = 1 / area
        let fb = framebuffer
        for py in minY...maxY {
            let fy = Float(py) + 0.5
            let row = py * width
            for px in minX...maxX {
                let fx = Float(px) + 0.5
                let wa = ((bx - fx) * (cy - fy) - (by - fy) * (cx - fx)) * inv
                let wb = ((cx - fx) * (ay - fy) - (cy - fy) * (ax - fx)) * inv
                let wc = 1 - wa - wb
                if wa < 0 || wb < 0 || wc < 0 { continue }
                fb[row + px] = color
            }
        }
    }

    /// Render a single mesh spinning on the spot at a fixed screen position
    /// (orthographic, flat-shaded, painter's-ordered). Used by the codex.
    private func drawMeshSpin(_ mesh: Mesh, cx: Int, cy: Int, scale: Float, yaw: Float) {
        let cA = cosf(yaw), sA = sinf(yaw)
        let tilt: Float = 0.52, cT = cosf(tilt), sT = sinf(tilt)   // slight look-down
        let n = mesh.verts.count
        var vx = [Float](repeating: 0, count: n), vy = vx, vz = vx
        var px = vx, py = vx
        for i in 0..<n {
            let (mx, my, mz) = mesh.verts[i]
            let x1 = mx * cA - my * sA, y1 = mx * sA + my * cA, z1 = mz   // yaw about up (Z)
            let y2 = y1 * cT - z1 * sT, z2 = y1 * sT + z1 * cT           // tilt about X
            vx[i] = x1; vy[i] = y2; vz[i] = z2
            px[i] = Float(cx) + x1 * scale
            py[i] = Float(cy) - z2 * scale
        }
        var lx: Float = -0.42, ly: Float = -0.5, lz: Float = 0.76
        let ll = sqrtf(lx * lx + ly * ly + lz * lz); lx /= ll; ly /= ll; lz /= ll
        // Far → near (larger view-Y is deeper into the screen) for convex hulls.
        let order = mesh.faces.indices.sorted {
            (vy[mesh.faces[$0].0] + vy[mesh.faces[$0].1] + vy[mesh.faces[$0].2])
                > (vy[mesh.faces[$1].0] + vy[mesh.faces[$1].1] + vy[mesh.faces[$1].2])
        }
        for fi in order {
            let (ia, ib, ic) = mesh.faces[fi]
            let e1x = vx[ib] - vx[ia], e1y = vy[ib] - vy[ia], e1z = vz[ib] - vz[ia]
            let e2x = vx[ic] - vx[ia], e2y = vy[ic] - vy[ia], e2z = vz[ic] - vz[ia]
            var nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x
            let nl = sqrtf(nx * nx + ny * ny + nz * nz); if nl < 1e-5 { continue }
            nx /= nl; ny /= nl; nz /= nl
            if ny > 0 { nx = -nx; ny = -ny; nz = -nz }              // orient toward viewer for shading
            var b = nx * lx + ny * ly + nz * lz
            b = 0.34 + 0.66 * max(0, b)
            let col = packRGBA(UInt8(min(255, mesh.color.0 * b)),
                               UInt8(min(255, mesh.color.1 * b)),
                               UInt8(min(255, mesh.color.2 * b)))
            fillTriFlat(px[ia], py[ia], px[ib], py[ib], px[ic], py[ic], col)
        }
    }


    /// Twin cannon bolts from the lower corners to the reticle.
    func drawTracers(crosshairX: Float, crosshairY: Float) {
        let col = packRGBA(120, 240, 255)
        drawLine(0, Float(height - 1), crosshairX, crosshairY, col)
        drawLine(Float(width - 1), Float(height - 1), crosshairX, crosshairY, col)
    }

    /// A small reticle at the aim point.
    func drawCrosshair(x: Float, y: Float) {
        let col = packRGBA(120, 255, 160)
        let cx = Int(x), cy = Int(y)
        let gap = 3, len = 7
        for d in gap...(gap + len) {
            plot(cx + d, cy, col); plot(cx - d, cy, col)
            plot(cx, cy + d, col); plot(cx, cy - d, col)
        }
        plot(cx, cy, col)
    }

    /// Lock box from a pre-projected screen position + radius (the caller
    /// projects through the quaternion camera).
    func drawLockBox(screenX: Float, screenY: Float, half: Float, color: UInt32) {
        drawDottedBox(cx: screenX, cy: screenY, half: min(half, Float(height) * 4) + 5, color: color)
    }

    private func drawDottedBox(cx: Float, cy: Float, half: Float, color: UInt32) {
        let x0 = Int(cx - half), x1 = Int(cx + half)
        let y0 = Int(cy - half), y1 = Int(cy + half)
        let dash = 3
        let cxlo = max(0, x0), cxhi = min(width - 1, x1)
        if cxlo <= cxhi { for x in cxlo...cxhi where ((x - x0) / dash) % 2 == 0 { plot(x, y0, color); plot(x, y1, color) } }
        let cylo = max(0, y0), cyhi = min(height - 1, y1)
        if cylo <= cyhi { for y in cylo...cyhi where ((y - y0) / dash) % 2 == 0 { plot(x0, y, color); plot(x1, y, color) } }
    }

    @inline(__always) private func plot(_ px: Int, _ py: Int, _ color: UInt32) {
        if px >= 0 && px < width && py >= 0 && py < height {
            framebuffer[py * width + px] = color
        }
    }

    /// Alpha-blend `color` onto the framebuffer pixel by coverage `a` (0…1) —
    /// used to feather the circular dial bezels so their rims read smooth rather
    /// than stair-stepped.
    @inline(__always) private func blendPixel(_ px: Int, _ py: Int, _ color: UInt32, _ a: Float) {
        if px < 0 || px >= width || py < 0 || py >= height || a <= 0 { return }
        let i = py * width + px
        if a >= 1 { framebuffer[i] = color; return }
        let d = framebuffer[i]
        let ia = 1 - a
        let rr = Float(color & 0xFF) * a + Float(d & 0xFF) * ia
        let gg = Float((color >> 8) & 0xFF) * a + Float((d >> 8) & 0xFF) * ia
        let bb = Float((color >> 16) & 0xFF) * a + Float((d >> 16) & 0xFF) * ia
        framebuffer[i] = packRGBA(UInt8(rr), UInt8(gg), UInt8(bb))
    }

    private func drawLine(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ color: UInt32) {
        let dx = x1 - x0, dy = y1 - y0
        let steps = Int(max(abs(dx), abs(dy)))
        if steps <= 0 { return }
        let sx = dx / Float(steps), sy = dy / Float(steps)
        var x = x0, y = y0
        for _ in 0...steps {
            let xi = Int(x), yi = Int(y)
            plot(xi, yi, color)
            plot(xi + 1, yi, color)        // 2px for visibility
            x += sx; y += sy
        }
    }

    // MARK: HUD + radar (call last, over everything)

    // MARK: Warp cut-scene scenes (drawn into this renderer's framebuffer)

    /// Deep-space backdrop with a drifting starfield.
    func clearSpace(_ time: Float) {
        let W = width, H = height
        for y in 0..<H {
            let t = Float(y) / Float(H)
            let c = packRGBA(UInt8(6 + 10 * t), UInt8(6 + 12 * t), UInt8(14 + 24 * t))
            let row = y * W
            for x in 0..<W { framebuffer[row + x] = c }
        }
        for i in 0..<170 {
            let h1 = (UInt32(i) &* 2_654_435_761) ^ 0x9E37_79B9
            let sx = (Int(h1 % UInt32(W)) + Int(time * 7)) % W
            let sy = Int((h1 >> 9) % UInt32(H))
            let tw = 0.5 + 0.5 * sinf(time * 2 + Float(i))
            let v = UInt8(140 + 110 * tw)
            plot(sx, sy, packRGBA(v, v, UInt8(min(255, Int(v) + 10))))
        }
    }

    /// A shaded planet globe (with a faint atmosphere rim).
    func drawGlobe(cx: Int, cy: Int, r: Int, base: (Float, Float, Float)) {
        if r < 1 { return }
        var lx: Float = -0.5, ly: Float = -0.4, lz: Float = 0.76
        let ll = sqrtf(lx * lx + ly * ly + lz * lz); lx /= ll; ly /= ll; lz /= ll
        for dy in -r...r {
            let py = cy + dy
            if py < 0 || py >= height { continue }
            let row = py * width
            for dx in -r...r {
                let px = cx + dx
                if px < 0 || px >= width { continue }
                let nx = Float(dx) / Float(r), ny = Float(dy) / Float(r)
                let e = nx * nx + ny * ny
                if e > 1 { continue }
                if e > 0.90 {                                   // atmosphere rim glow
                    framebuffer[row + px] = packRGBA(120, 170, 230)
                    continue
                }
                let nz = sqrtf(max(0, 1 - e))
                let b = 0.16 + 0.84 * max(0, nx * lx + ny * ly + nz * lz)
                framebuffer[row + px] = packRGBA(UInt8(min(255, base.0 * b)),
                                                 UInt8(min(255, base.1 * b)),
                                                 UInt8(min(255, base.2 * b)))
            }
        }
    }

    /// Hyperspace: stars streak radially outward from the centre, accelerating.
    func drawHyperspace(time: Float, progress: Float) {
        let W = width, H = height
        for i in 0..<(W * H) { framebuffer[i] = packRGBA(4, 4, 10) }
        let cx = Float(W) / 2, cy = Float(H) / 2
        let maxR = Float(max(W, H))
        let speed = 60 + progress * 360
        for i in 0..<240 {
            let h1 = (UInt32(i) &* 2_654_435_761) ^ 0x5151_7777
            let ang = Float(h1 % 6283) / 1000.0
            let phase = Float((h1 >> 5) % 1000) / 1000.0 * maxR
            let r = (phase + time * speed).truncatingRemainder(dividingBy: maxR)
            let len = 4 + progress * 36 + r * 0.10
            let ca = cosf(ang), sa = sinf(ang)
            let v = UInt8(150 + 105 * progress)
            let col = packRGBA(v, v, 255)
            drawLine(cx + ca * (r - len), cy + sa * (r - len), cx + ca * r, cy + sa * r, col)
        }
        if progress > 0.88 {                                    // white-out flash at the jump
            let a = (progress - 0.88) / 0.12
            for i in 0..<(W * H) {
                let c = framebuffer[i]
                let rr = Float(c & 0xFF) + (255 - Float(c & 0xFF)) * a
                let gg = Float((c >> 8) & 0xFF) + (255 - Float((c >> 8) & 0xFF)) * a
                let bb = Float((c >> 16) & 0xFF) + (255 - Float((c >> 16) & 0xFF)) * a
                framebuffer[i] = packRGBA(UInt8(min(255, rr)), UInt8(min(255, gg)), UInt8(min(255, bb)))
            }
        }
    }

    /// Dim the whole frame toward black (warp fades).
    func dimScreen(_ amount: Float) {
        if amount <= 0 { return }
        let keep = max(0, 1 - amount)
        let n = width * height
        for i in 0..<n { framebuffer[i] = darken(framebuffer[i], keep) }
    }

    /// Bottom instrument cluster (the only cockpit chrome — the rest is an
    /// open "plexiglass" canopy). A computer display for the readout text,
    /// segmented LED bars + digital readouts for shield/thrust/altitude, and
    /// the radar bezel. Draw AFTER the scene and BEFORE the radar scope.
    // MARK: Dashboard layout & styling (shared by cockpit / chronometer / radar)

    private var dashTopY: Int { height - 56 }       // top edge of the console
    private var dashBayY: Int { dashTopY + 6 }      // top of the instrument bays
    private let dashBayH = 44                        // bay height
    private let bayInfoX = 6,    bayInfoW = 132      // flight-computer read-out
    private let bayGaugeX = 144, bayGaugeW = 150     // LED gauges
    private let attCx = 322                          // artificial-horizon centre x
    private let bayChronoX = 350, bayChronoW = 72    // chronometer
    private let radarCx = 450                        // radar centre x
    private let roundR = 22                           // shared dial radius
    private var roundCy: Int { dashBayY + dashBayH / 2 }

    private let dashScreenBG = packRGBA(8, 17, 12)
    private let dashGreen = packRGBA(120, 255, 160)
    private let dashDim   = packRGBA(74, 150, 98)
    private let dashRing  = packRGBA(108, 116, 130)
    private let dashRingLo = packRGBA(44, 48, 60)

    /// A recessed dark instrument screen with a consistent inset bevel — the
    /// shared "module" the whole console is built from.
    private func dashScreen(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        fillRect(x, y, w, h, dashScreenBG)
        fillRect(x, y, w, 1, packRGBA(2, 5, 4))                  // inset shadow (top)
        fillRect(x, y, 1, h, packRGBA(2, 5, 4))                  // inset shadow (left)
        fillRect(x, y + h - 1, w, 1, packRGBA(96, 104, 118))     // bevel highlight (bottom)
        fillRect(x + w - 1, y, 1, h, packRGBA(96, 104, 118))     // bevel highlight (right)
    }

    /// A circular metal bezel with the same screen interior, so the round dials
    /// read as part of the same machined console as the rectangular screens.
    private func dashDial(cx: Int, cy: Int, r: Int) {
        let ro = Float(r), ri = Float(r - 3)
        // Turned-metal bezel: brightness follows the angle around the rim (lit
        // from the top-left) so the ring reads as a continuous machined band all
        // the way round — not a bevel that fades into the dark console on its
        // shadow side. Endpoints stay metallic so the whole circumference shows.
        let loR = Float(74), loG = Float(80), loB = Float(96)        // shadow-side metal
        let hiR = Float(158), hiG = Float(168), hiB = Float(188)     // lit-side metal
        let invSqrt2 = Float(0.70710677)
        // Step one pixel past the rim so the outer edge can feather into the
        // console behind it (coverage AA on both the rim and the ring/interior
        // seam — the same alpha-blended-edge treatment as the title text).
        for dy in -(r + 1)...(r + 1) {
            let py = cy + dy; if py < 0 || py >= height { continue }
            for dx in -(r + 1)...(r + 1) {
                let px = cx + dx; if px < 0 || px >= width { continue }
                let dist = sqrtf(Float(dx * dx + dy * dy))
                let outer = max(0, min(1, ro + 0.5 - dist))      // 1 inside rim → 0 outside
                if outer <= 0 { continue }
                let ringCov = max(0, min(1, dist - (ri - 0.5)))  // 1 = bezel ring, 0 = interior
                if ringCov <= 0 {
                    framebuffer[py * width + px] = dashScreenBG   // solid interior, no AA needed
                    continue
                }
                // Top-left light: t = 1 toward (-,-), 0 toward (+,+).
                let nd = dist > 0.5 ? (-Float(dx) - Float(dy)) / dist * invSqrt2 : 0
                let t = 0.5 + 0.5 * max(-1, min(1, nd))
                let ringCol = packRGBA(UInt8(loR + (hiR - loR) * t),
                                       UInt8(loG + (hiG - loG) * t),
                                       UInt8(loB + (hiB - loB) * t))
                if ringCov < 1 { framebuffer[py * width + px] = dashScreenBG }   // interior base
                blendPixel(px, py, ringCol, ringCov >= 1 ? outer : ringCov)
            }
        }
    }

    func drawCockpit(score: Int, basesStanding: Int, basesTotal: Int, aliens: Int,
                     planetName: String, level: Int,
                     speed: Int, altitude: Int, shield: Int, maxShield: Int, roll: Float, pitch: Float) {
        let W = width, H = height
        let dashTop = dashTopY

        // Console panel: dark brushed-metal gradient with a faint speckle.
        for y in dashTop..<H {
            let t = Float(y - dashTop) / Float(H - dashTop)
            let row = y * width
            for x in 0..<W {
                let h = (UInt32(x) &* 73_856_093) ^ (UInt32(y) &* 19_349_663)
                let n = Float(h & 3) - 1.5
                framebuffer[row + x] = packRGBA(UInt8(max(0, min(255, 56 - 26 * t + n))),
                                                UInt8(max(0, min(255, 60 - 28 * t + n))),
                                                UInt8(max(0, min(255, 74 - 34 * t + n))))
            }
        }
        fillRect(0, dashTop - 1, W, 1, packRGBA(8, 8, 12))        // seam shadow
        fillRect(0, dashTop, W, 2, packRGBA(128, 134, 148))       // machined lip
        fillRect(0, dashTop + 2, W, 1, packRGBA(58, 110, 138))    // status accent strip

        let by = dashBayY, bh = dashBayH
        let red = packRGBA(255, 90, 70), amber = packRGBA(255, 200, 90)

        // Bay 1 — flight-computer read-out, aligned label / value columns.
        dashScreen(bayInfoX, by, bayInfoW, bh)
        let lx = bayInfoX + 6, vx = bayInfoX + 48, ly = by + 4
        Font.draw("SCORE",  into: framebuffer, w: W, h: H, x: lx, y: ly,      color: dashDim)
        Font.draw("BASES",  into: framebuffer, w: W, h: H, x: lx, y: ly + 10, color: dashDim)
        Font.draw("ALIENS", into: framebuffer, w: W, h: H, x: lx, y: ly + 20, color: dashDim)
        Font.draw(String(format: "%06d", score), into: framebuffer, w: W, h: H, x: vx, y: ly, color: dashGreen)
        Font.draw("\(basesStanding)/\(basesTotal)", into: framebuffer, w: W, h: H, x: vx, y: ly + 10,
                  color: basesStanding == 0 ? red : dashGreen)
        Font.draw("\(aliens)", into: framebuffer, w: W, h: H, x: vx, y: ly + 20, color: dashGreen)
        Font.draw(planetName.uppercased(), into: framebuffer, w: W, h: H, x: lx, y: ly + 30, color: dashGreen)
        let lvlStr = "L\(level)"
        Font.draw(lvlStr, into: framebuffer, w: W, h: H,
                  x: bayInfoX + bayInfoW - 6 - Font.width(lvlStr), y: ly + 30, color: amber)

        // Bay 2 — segmented LED gauges on their own recessed screen.
        dashScreen(bayGaugeX, by, bayGaugeW, bh)
        let gx = bayGaugeX + 8
        ledBar(x: gx, y: by + 4,  label: "SHLD", frac: Float(shield) / Float(max(1, maxShield)), value: shield, danger: true)
        ledBar(x: gx, y: by + 19, label: "THR ", frac: Float(speed - 20) / 260, value: speed, danger: false)
        ledBar(x: gx, y: by + 34, label: "ALT ", frac: Float(altitude) / 460, value: altitude, danger: false)

        // Bay 3 — artificial-horizon dial.
        dashDial(cx: attCx, cy: roundCy, r: roundR)
        drawAttitude(cx: attCx, cy: roundCy, r: roundR - 3, bank: roll, pitch: pitch)

        // Bay 4 — chronometer screen (text drawn by drawChronometer afterwards).
        dashScreen(bayChronoX, by, bayChronoW, bh)

        // Bay 5 — radar dial (scope drawn by drawRadar afterwards).
        dashDial(cx: radarCx, cy: roundCy, r: roundR)
    }

    /// Artificial horizon: sky/ground split by a line that banks with roll and
    /// shifts with pitch, behind a fixed orange aircraft symbol.
    private func drawAttitude(cx: Int, cy: Int, r: Int, bank: Float, pitch: Float) {
        let bankA = -bank * 3.0          // horizon tilts opposite to roll, matching the real horizon
        let sb = sinf(bankA), cb = cosf(bankA)
        let off = (pitch / 80) * Float(r) * 0.7
        let sky = packRGBA(70, 130, 210), ground = packRGBA(120, 82, 52), line = packRGBA(235, 238, 248)
        let rf = Float(r)
        // Feather the disc rim (coverage AA) so the sky/ground edge blends into
        // the surrounding bezel instead of stair-stepping.
        for dy in -(r + 1)...(r + 1) {
            let py = cy + dy
            if py < 0 || py >= height { continue }
            for dx in -(r + 1)...(r + 1) {
                let px = cx + dx
                if px < 0 || px >= width { continue }
                let cov = max(0, min(1, rf + 0.5 - sqrtf(Float(dx * dx + dy * dy))))
                if cov <= 0 { continue }
                let ry = -Float(dx) * sb + Float(dy) * cb
                let d = ry - off
                let col = abs(d) < 1.3 ? line : (d < 0 ? sky : ground)
                blendPixel(px, py, col, cov)
            }
        }
        let amber = packRGBA(255, 170, 60)
        for dx in -6...6 { plot(cx + dx, cy, amber) }            // wings
        plot(cx, cy - 1, amber); plot(cx, cy + 1, amber)
    }

    /// Dashboard chronometer: live stardate/clock + mission-elapsed time. Text
    /// only — the recessed screen it sits in is drawn by drawCockpit (bay 4).
    func drawChronometer(date: String, clock: String, mission: String) {
        let x = bayChronoX + 5, y = dashBayY + 3
        Font.draw("STARDATE", into: framebuffer, w: width, h: height, x: x, y: y, color: dashDim)
        Font.draw(date,  into: framebuffer, w: width, h: height, x: x, y: y + 10, color: dashGreen)
        Font.draw(clock, into: framebuffer, w: width, h: height, x: x, y: y + 20, color: dashGreen)
        Font.draw("MET", into: framebuffer, w: width, h: height, x: x, y: y + 30, color: dashDim)
        Font.draw(mission, into: framebuffer, w: width, h: height, x: x + 24, y: y + 30, color: dashGreen)
    }

    /// A segmented LED bar: LABEL [▮▮▮▮▯▯▯▯] 080 + digital readout.
    /// `danger` gauges (shield) colour the LIT segments by level — green when
    /// high, red when low — so a depleting bar reads as danger. Other gauges
    /// (thrust/altitude) light a neutral cyan.
    private func ledBar(x: Int, y: Int, label: String, frac: Float, value: Int, danger: Bool) {
        let phos = packRGBA(150, 255, 175)
        Font.draw(label, into: framebuffer, w: width, h: height, x: x, y: y, color: phos)
        let bx = x + label.count * 6 + 4
        let segs = 12, segW = 5, gap = 1
        let f = max(0, min(1, frac))
        let lit = Int((Float(segs) * f).rounded())
        let litColor: UInt32 = danger
            ? (f > 0.5 ? packRGBA(60, 220, 90) : (f > 0.25 ? packRGBA(240, 200, 60) : packRGBA(255, 70, 55)))
            : packRGBA(90, 200, 255)
        for s in 0..<segs {
            let sx = bx + s * (segW + gap)
            fillRect(sx, y, segW, 6, s < lit ? litColor : packRGBA(24, 38, 30))
        }
        let rx = bx + segs * (segW + gap) + 5
        Font.draw(String(format: "%03d", min(999, max(0, value))), into: framebuffer, w: width, h: height,
                  x: rx, y: y, color: phos)
    }

    /// Perk: remaining radial-pulse charges, top-left corner.
    func drawPulseCharges(_ n: Int) {
        Font.draw("PULSE \(max(0, n))", into: framebuffer, w: width, h: height,
                  x: 4, y: 4, color: n > 0 ? packRGBA(255, 200, 90) : packRGBA(150, 120, 90))
    }

    /// Perk: cloak status, top-left below the pulse readout. Shows READY,
    /// the active countdown (bright cyan), or the recharge countdown (dim).
    func drawCloakStatus(active: Float, cooldown: Float) {
        let s: String, col: UInt32
        if active > 0 {
            s = "CLOAK \(Int(ceil(active)))"; col = packRGBA(120, 240, 255)
        } else if cooldown > 0 {
            s = "CLOAK \(Int(ceil(cooldown)))"; col = packRGBA(110, 120, 140)
        } else {
            s = "CLOAK READY"; col = packRGBA(120, 255, 200)
        }
        Font.draw(s, into: framebuffer, w: width, h: height, x: 4, y: 14, color: col)
    }

    /// Brief centred banner near the top for perk unlocks / bonuses. `t` is the
    /// seconds remaining; the text dims over its final second.
    func drawNotification(_ text: String, t: Float) {
        let scale = 2
        let x = (width - Font.width(text, scale: scale)) / 2
        let k = min(1, max(0, t))
        let col = packRGBA(UInt8(255 * k), UInt8(225 * k), UInt8(110 * k))
        Font.draw(text, into: framebuffer, w: width, h: height, x: x, y: height / 6, scale: scale, color: col)
    }

    func drawRadar(camera: Camera, enemies: EnemyField?, structures: StructureField?) {
        let a = camera.angle
        drawRadar(originX: camera.x, originY: camera.y,
                  fwdX: -sinf(a), fwdY: -cosf(a), rightX: cosf(a), rightY: -sinf(a),
                  enemies: enemies, structures: structures)
    }

    /// Radar scope from an explicit ground basis — the caller passes the
    /// quaternion camera's actual forward/right (deriving from a heading alone
    /// would mirror left/right). `fwd`/`right` need not be unit length (only
    /// direction matters). nil `enemies`/`structures` draw an empty scope (warp
    /// transit — contact lost).
    func drawRadar(originX: Float, originY: Float,
                   fwdX: Float, fwdY: Float, rightX rx: Float, rightY ry: Float,
                   enemies: EnemyField?, structures: StructureField?) {
        // Normalise the supplied basis so blip distances are in world units.
        let fl = max(1e-5, sqrtf(fwdX * fwdX + fwdY * fwdY))
        let rl = max(1e-5, sqrtf(rx * rx + ry * ry))
        let fwdX = fwdX / fl, fwdY = fwdY / fl, rightX = rx / rl, rightY = ry / rl
        let R = roundR - 3                          // scope interior (ring drawn by drawCockpit)
        let cxp = radarCx, cyp = roundCy
        let range: Float = 1600

        // Faint scope graticule — crosshair + a mid-range ring, clipped to the dial.
        let grid = packRGBA(28, 66, 44)
        let midRR = (R * R) / 4
        for dy in -R...R {
            let py = cyp + dy; if py < 0 || py >= height { continue }
            let row = py * width
            for dx in -R...R {
                let px = cxp + dx; if px < 0 || px >= width { continue }
                let d2 = dx * dx + dy * dy
                if d2 >= R * R { continue }
                if dx == 0 || dy == 0 || abs(d2 - midRR) <= R { framebuffer[row + px] = grid }
            }
        }

        // Player basis (passed in): forward points up on the scope, right to the right.
        let mapSize = self.mapSize           // world wrap size (set on terrain change)
        let inner = Float(R - 1)
        func wrap(_ d: Float) -> Float {
            var r = d.truncatingRemainder(dividingBy: mapSize)
            let h = mapSize * 0.5
            if r > h { r -= mapSize } else if r < -h { r += mapSize }
            return r
        }
        func blip(_ wx: Float, _ wy: Float, _ color: UInt32, _ s: Int) {
            let dx = wrap(wx - originX), dy = wrap(wy - originY)
            let fwd = dx * fwdX + dy * fwdY
            let rgt = dx * rightX + dy * rightY
            var ox = (rgt / range) * inner
            var oy = -(fwd / range) * inner                     // up = forward
            let m = sqrtf(ox * ox + oy * oy)
            if m > inner { ox *= inner / m; oy *= inner / m }   // clamp to the rim
            let ix = cxp + Int(ox), iy = cyp + Int(oy)
            for j in -s...s { for i in -s...s { plot(ix + i, iy + j, color) } }
        }

        for st in structures?.structures ?? [] where st.alive { blip(st.x, st.y, packRGBA(90, 220, 255), 1) }
        for e in enemies?.enemies ?? [] { blip(e.x, e.y, packRGBA(255, 90, 40), 0) }

        // Player marker — a small triangle pointing up at the centre.
        let p = packRGBA(120, 255, 140)
        plot(cxp, cyp - 2, p)
        plot(cxp - 1, cyp - 1, p); plot(cxp + 1, cyp - 1, p)
        plot(cxp - 2, cyp, p); plot(cxp, cyp, p); plot(cxp + 2, cyp, p)
    }

    /// Red damage vignette/tint when the player is hit (intensity 0…1).
    func drawDamageFlash(_ k: Float) {
        if k <= 0 { return }
        let kk = min(1, k)
        let add = kk * 0.55, mul = 1 - kk * 0.35
        let fb = framebuffer
        let n = width * height
        for i in 0..<n {
            let c = fb[i]
            let r = Float(c & 0xFF), g = Float((c >> 8) & 0xFF), b = Float((c >> 16) & 0xFF)
            fb[i] = packRGBA(UInt8(min(255, r + (255 - r) * add)), UInt8(g * mul), UInt8(b * mul))
        }
    }

    private func fillRect(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        let xe = min(width, x0 + w), ye = min(height, y0 + h)
        var yy = max(0, y0)
        while yy < ye {
            let row = yy * width
            var xx = max(0, x0)
            while xx < xe { framebuffer[row + xx] = color; xx += 1 }
            yy += 1
        }
    }

    @inline(__always) private func darken(_ c: UInt32, _ keep: Float) -> UInt32 {
        let r = Float(c & 0xFF) * keep
        let g = Float((c >> 8) & 0xFF) * keep
        let b = Float((c >> 16) & 0xFF) * keep
        return packRGBA(UInt8(r), UInt8(g), UInt8(b))
    }

    // MARK: Unicode text (Core Text) — for high-score names / emoji

    /// Alpha-composite a premultiplied RGBA bitmap (from TextImage) at (x, y).
    /// `alpha` < 1 ghosts the whole glyph (the premultiplied source scales
    /// uniformly, so coverage and colour both fade together).
    private func drawImageAlpha(_ bmp: TextImage.Bitmap, x: Int, y: Int, alpha: Float = 1) {
        let fb = framebuffer
        let k = max(0, min(1, alpha))
        for sy in 0..<bmp.h {
            let py = y + sy
            if py < 0 || py >= height { continue }
            let srow = sy * bmp.w, drow = py * width
            for sx in 0..<bmp.w {
                let px = x + sx
                if px < 0 || px >= width { continue }
                let s = bmp.pixels[srow + sx]
                let a = (s >> 24) & 0xFF
                if a == 0 { continue }
                if a == 255 && k >= 1 { fb[drow + px] = s; continue }
                let ia = 1.0 - Float(a) / 255.0 * k
                let d = fb[drow + px]
                let rr = Float(s & 0xFF) * k + Float(d & 0xFF) * ia
                let gg = Float((s >> 8) & 0xFF) * k + Float((d >> 8) & 0xFF) * ia
                let bb = Float((s >> 16) & 0xFF) * k + Float((d >> 16) & 0xFF) * ia
                fb[drow + px] = packRGBA(UInt8(min(255, rr)), UInt8(min(255, gg)), UInt8(min(255, bb)))
            }
        }
    }

    /// Rasterise and centre a Unicode string horizontally at row `y`.
    func drawUnicodeCentered(_ s: String, y: Int, fontSize: CGFloat,
                             _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: Float = 1) {
        guard let bmp = TextImage.rasterize(s, fontSize: fontSize, r: r, g: g, b: b) else { return }
        drawImageAlpha(bmp, x: (width - bmp.w) / 2, y: y, alpha: alpha)
    }

    /// Draw a Unicode string inside a column [x, x+maxWidth], clipped to that
    /// span. `rightAlign` pins it to the column's right edge (for numbers).
    private func drawUnicodeCol(_ s: String, x: Int, y: Int, maxWidth: Int, fontSize: CGFloat,
                                _ r: CGFloat, _ g: CGFloat, _ b: CGFloat,
                                rightAlign: Bool = false, center: Bool = false) {
        guard let bmp = TextImage.rasterize(s, fontSize: fontSize, r: r, g: g, b: b) else { return }
        let dx = center ? x + (maxWidth - bmp.w) / 2 : (rightAlign ? x + maxWidth - bmp.w : x)
        let fb = framebuffer
        let clipR = min(width, x + maxWidth)
        for sy in 0..<bmp.h {
            let py = y + sy
            if py < 0 || py >= height { continue }
            let srow = sy * bmp.w, drow = py * width
            for sx in 0..<bmp.w {
                let px = dx + sx
                if px < x || px >= clipR { continue }       // clip to column
                let s2 = bmp.pixels[srow + sx]
                let a = (s2 >> 24) & 0xFF
                if a == 0 { continue }
                if a == 255 { fb[drow + px] = s2; continue }
                let ia = Float(255 - a) / 255.0
                let d = fb[drow + px]
                let rr = Float(s2 & 0xFF) + Float(d & 0xFF) * ia
                let gg = Float((s2 >> 8) & 0xFF) + Float((d >> 8) & 0xFF) * ia
                let bb = Float((s2 >> 16) & 0xFF) + Float((d >> 16) & 0xFF) * ia
                fb[drow + px] = packRGBA(UInt8(min(255, rr)), UInt8(min(255, gg)), UInt8(min(255, bb)))
            }
        }
    }

    private func dimAll(_ keep: Float) {
        let n = width * height
        for i in 0..<n { framebuffer[i] = darken(framebuffer[i], keep) }
    }

    // MARK: Score / name-entry overlays

    func drawNameEntry(score: Int, name: String) {
        dimAll(0.30)
        drawUnicodeCentered("NEW HIGH SCORE", y: height / 2 - 54, fontSize: 22, 1.0, 0.88, 0.4)
        drawUnicodeCentered("SCORE \(score)", y: height / 2 - 24, fontSize: 12, 0.9, 0.92, 0.96)
        let shown = name.isEmpty ? "_" : name + "_"
        drawUnicodeCentered(shown, y: height / 2 + 2, fontSize: 18, 1.0, 1.0, 1.0)
        drawUnicodeCentered("TYPE YOUR NAME  —  RETURN TO CONFIRM", y: height / 2 + 36, fontSize: 9, 0.78, 0.82, 0.9)
    }

    func drawGameOver(loseReason: String, score: Int, scores: [HighScoreEntry], highlight: Int) {
        dimAll(0.32)
        drawUnicodeCentered("GAME OVER", y: 14, fontSize: 24, 1.0, 0.85, 0.4)
        drawUnicodeCentered("\(loseReason)   —   SCORE \(score)", y: 44, fontSize: 12, 1.0, 0.6, 0.5)

        // Column layout (W = 480): RANK | NAME | STARDATE | SCORE | LEVEL.
        let rankX = 20, rankW = 26
        let nameX = 50, nameW = 150
        let dateX = 206, dateW = 116
        let scoreX = 324, scoreW = 86
        let lvlX = 416, lvlW = 52
        let tableR = lvlX + lvlW

        // Header + rule.
        let hy = 66
        let (hr, hg, hb): (CGFloat, CGFloat, CGFloat) = (0.6, 0.74, 0.95)
        drawUnicodeCol("NAME",     x: nameX,  y: hy, maxWidth: nameW,  fontSize: 9, hr, hg, hb)
        drawUnicodeCol("STARDATE", x: dateX,  y: hy, maxWidth: dateW,  fontSize: 9, hr, hg, hb)
        drawUnicodeCol("SCORE",    x: scoreX, y: hy, maxWidth: scoreW, fontSize: 9, hr, hg, hb, rightAlign: true)
        drawUnicodeCol("LEVEL",    x: lvlX,   y: hy, maxWidth: lvlW,   fontSize: 9, hr, hg, hb, center: true)
        let ruleY = hy + 13
        if ruleY < height { for xx in rankX..<min(width, tableR) { framebuffer[ruleY * width + xx] = packRGBA(60, 80, 110) } }

        var yy = 84
        for (i, e) in scores.enumerated() {
            let hot = (i == highlight)
            if hot { fillRect(rankX - 4, yy - 2, tableR - rankX + 6, 15, packRGBA(74, 58, 14)) }
            let (r, g, b): (CGFloat, CGFloat, CGFloat) = hot ? (1.0, 0.9, 0.35) : (0.85, 0.88, 0.94)
            drawUnicodeCol(String(format: "%2d.", i + 1), x: rankX, y: yy, maxWidth: rankW, fontSize: 10, r, g, b, rightAlign: true)
            drawUnicodeCol(e.name, x: nameX, y: yy, maxWidth: nameW, fontSize: 10, r, g, b)
            drawUnicodeCol(e.stardate ?? "—", x: dateX, y: yy, maxWidth: dateW, fontSize: 10, r, g, b)
            drawUnicodeCol(String(format: "%06d", e.score), x: scoreX, y: yy, maxWidth: scoreW, fontSize: 10, r, g, b, rightAlign: true)
            drawUnicodeCol("\(e.level)", x: lvlX, y: yy, maxWidth: lvlW, fontSize: 10, r, g, b, center: true)
            yy += 15
        }
        drawUnicodeCentered("PRESS R TO RESTART      [ESC] TITLE SCREEN", y: height - 14, fontSize: 10, 0.85, 0.9, 1.0)
    }

    // MARK: Title overlay (drawn OVER the live attract-mode flyover)

    /// The logo + prompts, composited over whatever the flyover already drew.
    /// Dark gradient bands top and bottom keep the text legible against the
    /// moving terrain.
    /// `configHint`: a context-aware "configure controls" line (controller vs
    /// keyboard) built by the caller. `nebula`: per-planet-theme tint (0…1) for
    /// the title sky's nebula glow.
    func drawTitleScreen(time: Float, topName: String?, topScore: Int,
                         startHint: String, configHint: String, nebula: (CGFloat, CGFloat, CGFloat)) {
        let W = width, H = height
        let Hf = Float(H)

        // One even contrast scrim over the WHOLE display (not the old two bands):
        // enough to read the logo and text on bright worlds (e.g. the ice planet)
        // without the banding, and it makes the starfield read against it.
        dimAll(0.6)

        // Sky depth: a soft per-theme nebula and a parallax starfield in the
        // upper sky, over the scrim.
        drawTitleSky(time: time, nebula: nebula)

        // Title wordmark (bespoke ArcadeClassic-style logo). Dropped down so the
        // gaps credit→wordmark and wordmark→subtitle are even.
        let ty = Int(Hf * 0.115)
        drawTitleLogo("STRATARIS", centerX: W / 2, topY: ty, time: time)
        let logoBottom = ty + LogoFont.glyphHeight

        // Everything else uses the Core Text proportional font (the high-score
        // line's treatment) — softer and more refined than the 5×7 HUD bitmap.
        drawUnicodeCentered("Galactic Colony Defence", y: logoBottom + 12, fontSize: 17, 0.74, 0.85, 1.0)

        if sinf(time * 4) > -0.25 {
            drawUnicodeCentered(startHint, y: H - 80, fontSize: 17, 1.0, 1.0, 1.0)
        }
        drawUnicodeCentered("[B] Mission Briefing      [V] Enemy Intel", y: H - 58, fontSize: 11, 0.51, 0.78, 0.92)
        let hi = String(format: "High Score: %06d   ", topScore) + (topName ?? "---")
        drawUnicodeCentered(hi, y: H - 42, fontSize: 11, 1.0, 0.86, 0.4)
        drawUnicodeCentered(configHint, y: H - 24, fontSize: 11, 0.66, 0.70, 0.80)
        drawUnicodeCentered("Jorvik Software Proudly Presents", y: 5, fontSize: 10, 0.60, 0.64, 0.74)

        // CRT scanlines over the whole frame — scanlines only (no vignette/bloom).
        drawScanlines()
    }

    /// Title sky depth: a soft additive nebula glow (theme-tinted, slowly
    /// drifting) plus a parallax starfield in the upper half, twinkling and
    /// fading out toward the horizon. Drawn over the darkened sky band so the
    /// stars read against a near-space backdrop regardless of the daytime theme.
    private func drawTitleSky(time: Float, nebula: (CGFloat, CGFloat, CGFloat)) {
        let fb = framebuffer, W = width, H = height
        let skyH = Float(H) * 0.5

        // Nebula — a soft elliptical glow up in the sky.
        let nx = Float(W) * (0.64 + 0.04 * sinf(time * 0.03))
        let ny = Float(H) * 0.19
        let rx = Float(W) * 0.34, ry = Float(H) * 0.17
        let nr = Float(nebula.0), ng = Float(nebula.1), nb = Float(nebula.2)
        let x0 = max(0, Int(nx - rx)), x1 = min(W, Int(nx + rx))
        let y0 = max(0, Int(ny - ry)), y1 = min(H, Int(ny + ry))
        for y in y0..<y1 {
            let row = y * W
            for x in x0..<x1 {
                let ddx = (Float(x) - nx) / rx, ddy = (Float(y) - ny) / ry
                let d = ddx * ddx + ddy * ddy
                if d >= 1 { continue }
                let glow = (1 - d) * (1 - d) * 0.55
                let c = fb[row + x]
                let r = min(255, Float(c & 0xFF) + nr * 255 * glow)
                let g = min(255, Float((c >> 8) & 0xFF) + ng * 255 * glow)
                let b = min(255, Float((c >> 16) & 0xFF) + nb * 255 * glow)
                fb[row + x] = packRGBA(UInt8(r), UInt8(g), UInt8(b))
            }
        }

        // Starfield — deterministic positions, parallax drift, twinkle.
        for k in 0..<90 {
            var h = UInt32(k) &* 2_654_435_761
            h ^= h >> 15; h = h &* 668_265_263; h ^= h >> 13
            let bx = Float(h & 0xFFFF) / 65535 * Float(W)
            let by = Float((h >> 16) & 0x7FFF) / 32767 * skyH
            let layer = Float((h >> 4) & 0x3) / 3                 // 0…1 depth band
            var sx = bx + time * (2 + layer * 9)                  // parallax: far stars drift slower
            sx = sx.truncatingRemainder(dividingBy: Float(W)); if sx < 0 { sx += Float(W) }
            let px = Int(sx), py = Int(by)
            if px < 0 || px >= W || py < 0 || py >= H { continue }
            let horizonFade = max(0, 1 - by / skyH)               // fade into the horizon
            let twinkle = 0.65 + 0.35 * sinf(time * (1.5 + layer * 2.3) + Float(k))
            let bright = (0.35 + 0.65 * layer) * horizonFade * twinkle
            if bright <= 0.03 { continue }
            let i = py * W + px
            let c = fb[i]
            let add = bright * 255
            fb[i] = packRGBA(UInt8(min(255, Float(c & 0xFF) + add)),
                             UInt8(min(255, Float((c >> 8) & 0xFF) + add)),
                             UInt8(min(255, Float((c >> 16) & 0xFF) + add)))
        }
    }

    /// CRT scanlines: darken alternate rows a touch across the whole frame.
    private func drawScanlines(_ keep: Float = 0.8) {
        let fb = framebuffer, W = width
        var y = 1
        while y < height {
            let row = y * W
            for x in 0..<W { fb[row + x] = darken(fb[row + x], keep) }
            y += 2
        }
    }

    /// Bespoke wordmark alphabet in the spirit of Pizzadude's "ArcadeClassic" —
    /// every glyph is built from stacked horizontal bars of varying length, with
    /// thin gaps between them (the venetian-blind look of an 80s coin-op marquee).
    /// Each letter is 7 stripes tall on a unit grid; the value for a stripe is a
    /// bitmask of which unit columns are filled (high bit = leftmost). Only the
    /// letters STRATARIS uses are defined: S, T, R, A, I. Widths vary per glyph.
    enum LogoFont {
        static let stripes = 7
        static let unitW   = 6             // px per unit column
        static let stripeH = 6             // px per bar
        static let gapH    = 1             // px between bars
        static let tracking = 1            // blank unit columns between glyphs
        static var glyphHeight: Int { stripes * stripeH + (stripes - 1) * gapH }

        // (unit width, 7 stripe column-masks). Lifted from the actual font.
        static let glyphs: [Character: (w: Int, s: [UInt8])] = [
            " ": (3, [0, 0, 0, 0, 0, 0, 0]),
            "S": (7, [0b0111100, 0b1100110, 0b1100000, 0b0111110, 0b0000011, 0b1100011, 0b0111110]),
            "T": (6, [0b111111,  0b001100,  0b001100,  0b001100,  0b001100,  0b001100,  0b001100]),
            // R and A close their crossbar on stripe 3 — the same row as S's
            // middle bar — so all three align horizontally.
            "R": (7, [0b1111110, 0b1100011, 0b1100011, 0b1111110, 0b1101100, 0b1100110, 0b1100011]),
            "A": (7, [0b0011100, 0b0110110, 0b1100011, 0b1111111, 0b1100011, 0b1100011, 0b1100011]),
            "I": (6, [0b111111,  0b001100,  0b001100,  0b001100,  0b001100,  0b001100,  0b111111]),
        ]
    }

    /// Stylised "box art" wordmark for the title. The HUD font reads as plain big
    /// text; a game's name deserves better. We rasterise the word in the bespoke
    /// ArcadeClassic-style LogoFont above (stacked horizontal bars) into a local
    /// mask, then layer the treatment a 16-bit logo would get: a chunky 3D
    /// extrude, a dark keyline that lifts it off the busy terrain, a metallic
    /// chrome→gold vertical gradient face with a bevel (top rim-light, bottom
    /// shade), and a specular shine that sweeps across over time.
    func drawTitleLogo(_ text: String, centerX: Int, topY: Int, time: Float) {
        let upper = text.uppercased()
        let uw = LogoFont.unitW, sh = LogoFont.stripeH, gp = LogoFont.gapH
        let chars = Array(upper)
        let glyphsSeq = chars.map { LogoFont.glyphs[$0] ?? LogoFont.glyphs[" "]! }
        // Per-pair kerning (the tracking AFTER glyph i): tighten the "ST" and the
        // "A-T-A" clusters, where the T's narrow stem leaves a loose gap.
        func kern(_ i: Int) -> Int {
            guard i + 1 < chars.count else { return 0 }
            let c = chars[i], n = chars[i + 1]
            if (c == "S" && n == "T") || (c == "A" && n == "T") || (c == "T" && n == "A") { return 0 }
            return LogoFont.tracking
        }
        let totalUnits = (0..<glyphsSeq.count).reduce(0) { $0 + glyphsSeq[$1].w + kern($1) }
        let faceW = totalUnits * uw
        let faceH = LogoFont.glyphHeight
        let pad   = 2                                      // keyline room
        let bw = faceW + pad * 2
        let bh = faceH + pad * 2
        let ox = pad, oy = pad                             // face origin in bbox

        // Mask of the glyph faces — each stripe is a solid `sh`-tall bar, gaps
        // between stripes left clear (the venetian-blind look).
        var mask = [Bool](repeating: false, count: bw * bh)
        var penUnit = 0
        for gi in 0..<glyphsSeq.count {
            let gl = glyphsSeq[gi]
            for si in 0..<LogoFont.stripes {
                let bits = gl.s[si]
                let y0 = oy + si * (sh + gp)
                for col in 0..<gl.w where bits & (UInt8(1) << (gl.w - 1 - col)) != 0 {
                    let x0 = ox + (penUnit + col) * uw
                    for yy in 0..<sh {
                        let r = (y0 + yy) * bw
                        for xx in 0..<uw { mask[r + x0 + xx] = true }
                    }
                }
            }
            penUnit += gl.w + kern(gi)
        }
        let fb = framebuffer, W = width, H = height
        let bx = centerX - faceW / 2 - ox                  // bbox top-left in fb
        let by = topY - oy
        @inline(__always) func put(_ lx: Int, _ ly: Int, _ c: UInt32) {
            let px = bx + lx, py = by + ly
            if px >= 0 && px < W && py >= 0 && py < H { fb[py * W + px] = c }
        }

        // Flat cream fill — no gradient, bevel, grain, sheen or shadow.
        let cream = packRGBA(242, 234, 208)
        for ly in 0..<bh {
            for lx in 0..<bw where mask[ly * bw + lx] {
                put(lx, ly, cream)
            }
        }
    }

    /// Original mission lore for the briefing crawl. Uppercase only, and no
    /// apostrophes / commas / '>' (the 5×7 font doesn't carry those glyphs).
    static let briefingLines: [String] = [
        "GALACTIC COLONY DEFENCE",
        "",
        "AT THE FARTHEST REACH OF",
        "HUMAN EXPANSION LIES THE",
        "STRATARIS CLUSTER.",
        "",
        "SIX HARD-WON WORLDS AT",
        "THE EDGE OF THE DARK:",
        "",
        "*DEMETER   TANTALUS   BOREAS",
        "*PANDORA    VULCAN    VESPER",
        "",
        "HOME TO THE FAMILIES WHO",
        "DARED TO SETTLE THE FRONTIER.",
        "",
        "THEY DID NOT COME ALONE.",
        "",
        "FROM THE VOID BEYOND CAME",
        "THE MARAUDERS.",
        "",
        "WAVE UPON WAVE. WORLD AFTER",
        "WORLD. HUNTING THE COLONIES",
        "THAT CANNOT RUN.",
        "",
        "YOU ARE THE LAST INTERCEPTOR",
        "ON STATION.",
        "ONE SHIP. ONE PILOT.",
        "",
        "EVERY COMMAND POST YOU LOSE",
        "IS LOST FOR GOOD.",
        "",
        "HOLD THE LINE.",
        "MAKE THEM PAY FOR EVERY",
        "METRE OF SKY.",
        "",
        "*GOOD LUCK COMMANDER.",
        "",
        "",
        "",
    ]

    /// Mission-briefing screen: a slow "incoming transmission" crawl rendered on
    /// a cockpit comms display (matching the dashboard), over the attract flyover.
    func drawBriefing(time: Float) {
        let W = width, H = height
        let pX = 18, pY = 16, pW = W - 36, pH = H - 32
        dashScreen(pX, pY, pW, pH)

        let accent = packRGBA(58, 110, 138)
        let amber = packRGBA(255, 200, 90)

        // Header rule.
        Font.draw("PRIORITY TRANSMISSION", into: framebuffer, w: W, h: H, x: pX + 6, y: pY + 5, color: dashGreen)
        let rt = "STRATARIS COMMAND"
        Font.draw(rt, into: framebuffer, w: W, h: H, x: pX + pW - 6 - Font.width(rt), y: pY + 5, color: dashDim)
        fillRect(pX + 4, pY + 15, pW - 8, 1, accent)

        // Footer prompts.
        fillRect(pX + 4, pY + pH - 16, pW - 8, 1, accent)
        let foot = "[ENTER] ENGAGE    [ESC] STAND DOWN"
        Font.draw(foot, into: framebuffer, w: W, h: H, x: (W - Font.width(foot)) / 2, y: pY + pH - 11, color: dashGreen)

        // Scrolling body between the two divider lines.
        let bodyTop = pY + 19, bodyBot = pY + pH - 18, bodyH = bodyBot - bodyTop
        let lineH = 11
        let total = Canvas2D.briefingLines.count * lineH + bodyH
        let scroll = Int(time * 14) % total
        for (i, raw) in Canvas2D.briefingLines.enumerated() {
            if raw.isEmpty { continue }
            let y = bodyTop + bodyH - scroll + i * lineH
            if y < bodyTop || y > bodyBot - 7 { continue }          // strict clip; fades hide the edges
            let hot = raw.hasPrefix("*")
            let text = hot ? String(raw.dropFirst()) : raw
            Font.draw(text, into: framebuffer, w: W, h: H, x: (W - Font.width(text)) / 2, y: y,
                      color: hot ? amber : dashGreen)
        }

        // Soft fade top & bottom, so lines dissolve into the screen rather than
        // popping at the dividers.
        let fade = 13
        for f in 0..<fade {
            let a = 1 - Float(f) / Float(fade)                      // opaque at the edge → clear inner
            blendRow(bodyTop + f, pX + 4, pX + pW - 4, dashScreenBG, a)
            blendRow(bodyBot - 1 - f, pX + 4, pX + pW - 4, dashScreenBG, a)
        }
    }

    /// Blend a horizontal run of the framebuffer toward `target` by amount `a`.
    private func blendRow(_ y: Int, _ x0: Int, _ x1: Int, _ target: UInt32, _ a: Float) {
        if y < 0 || y >= height { return }
        let row = y * width
        let tr = Float(target & 0xFF), tg = Float((target >> 8) & 0xFF), tb = Float((target >> 16) & 0xFF)
        for x in max(0, x0)..<min(width, x1) {
            let d = framebuffer[row + x]
            let dr = Float(d & 0xFF), dg = Float((d >> 8) & 0xFF), db = Float((d >> 16) & 0xFF)
            framebuffer[row + x] = packRGBA(UInt8(dr + (tr - dr) * a),
                                            UInt8(dg + (tg - dg) * a),
                                            UInt8(db + (tb - db) * a))
        }
    }

    /// Enemy-craft codex: each of the four hostiles with a slowly-rotating 3D
    /// model, its role, and the points awarded — on a cockpit comms display.
    func drawCodex(time: Float) {
        let W = width, H = height
        let pX = 10, pY = 10, pW = W - 20, pH = H - 20
        dashScreen(pX, pY, pW, pH)

        let accent = packRGBA(58, 110, 138), amber = packRGBA(255, 200, 90)
        Font.draw("ENEMY VESSEL DATABASE", into: framebuffer, w: W, h: H, x: pX + 6, y: pY + 5, color: dashGreen)
        let rt = "THREAT ASSESSMENT"
        Font.draw(rt, into: framebuffer, w: W, h: H, x: pX + pW - 6 - Font.width(rt), y: pY + 5, color: dashDim)
        fillRect(pX + 4, pY + 15, pW - 8, 1, accent)
        fillRect(pX + 4, pY + pH - 16, pW - 8, 1, accent)
        let foot = "[ENTER] ENGAGE    [ESC] CLOSE"
        Font.draw(foot, into: framebuffer, w: W, h: H, x: (W - Font.width(foot)) / 2, y: pY + pH - 11, color: dashGreen)

        let meshes = [Mesh.drone(), Mesh.fighter(), Mesh.destroyer(), Mesh.mothership()]
        let names: [String] = ["DRONE", "FIGHTER", "DESTROYER", "MOTHERSHIP"]
        let pts = [10, 100, 250, 2500]
        let mscale: [Float] = [26, 19, 18, 16]
        let role1 = ["EXPENDABLE SWARM. MIMICS THE",
                     "HUNTS THE PLAYER WITH FAST",
                     "BOMBS GROUND INSTALLATIONS.",
                     "SLOW. HEAVILY ARMOURED."]
        let role2 = ["NEAREST FIGHTER OR DESTROYER.",
                     "STRAFING ATTACK RUNS.",
                     "TURNS ON YOU IF YOU CLOSE IN.",
                     "RARE - AND HIGH VALUE."]

        let top = pY + 22, rowH = (pH - 22 - 18) / 4
        for i in 0..<4 {
            let ry = top + i * rowH, mid = ry + rowH / 2
            if i > 0 { fillRect(pX + 8, ry, pW - 16, 1, packRGBA(24, 40, 30)) }   // row divider
            drawMeshSpin(meshes[i], cx: pX + 44, cy: mid, scale: mscale[i], yaw: time * 0.9 + Float(i) * 1.7)
            let tx = pX + 92
            Font.draw(names[i], into: framebuffer, w: W, h: H, x: tx, y: ry + 8, color: amber)
            Font.draw(role1[i], into: framebuffer, w: W, h: H, x: tx, y: ry + 22, color: dashGreen)
            Font.draw(role2[i], into: framebuffer, w: W, h: H, x: tx, y: ry + 32, color: dashDim)
            let ps = "\(pts[i]) PTS"
            Font.draw(ps, into: framebuffer, w: W, h: H, x: pX + pW - 10 - Font.width(ps), y: ry + 8, color: dashGreen)
        }
    }

    /// Centred end-of-game banner over a darkened band. `opacity` < 1 ghosts it
    /// (lighter band dim + translucent text) so the world stays visible behind —
    /// e.g. free-flying on the PLANET CLEARED screen.
    func drawBanner(title: String, subtitle: String, opacity: Float = 1) {
        let fb = framebuffer
        let tb = TextImage.rasterize(title, fontSize: 26, r: 1.0, g: 0.88, b: 0.43)
        let sb = subtitle.isEmpty ? nil : TextImage.rasterize(subtitle, fontSize: 11, r: 0.9, g: 0.93, b: 0.97)
        let gap = sb == nil ? 0 : 4
        // Lay the title+subtitle block around screen-centre, then wrap a dimmed
        // band around it with even vertical padding (the Core Text bitmaps carry
        // their own ascent/descent leading, so this stays balanced).
        let blockH = (tb?.h ?? 0) + gap + (sb?.h ?? 0)
        let blockTop = height / 2 - blockH / 2
        let pad = 12
        let bandY = blockTop - pad, bandH = blockH + pad * 2
        let keep = 1 - 0.68 * opacity                     // opacity 1 → the usual 0.32 dim
        for yy in max(0, bandY)..<min(height, bandY + bandH) {
            let row = yy * width
            for xx in 0..<width { fb[row + xx] = darken(fb[row + xx], keep) }
        }
        if let tb { drawImageAlpha(tb, x: (width - tb.w) / 2, y: blockTop, alpha: opacity) }
        if let sb { drawImageAlpha(sb, x: (width - sb.w) / 2, y: blockTop + (tb?.h ?? 0) + gap, alpha: opacity) }
    }
}

// MARK: - Headless smoke test (STRATARIS_SMOKE=1)

enum SmokeTest {
    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)        // unbuffered, so output survives a trap
        let w = RenderConfig.width, h = RenderConfig.height
        let t0 = CACurrentMediaTime()
        let terrain = Terrain(seed: 7)
        print("Strataris smoke test — generated terrain (\(terrain.size)×\(terrain.size))…")
        let genMs = (CACurrentMediaTime() - t0) * 1000
        print(String(format: "  terrain generated in %.1f ms", genMs))

        // Flight model (renderer-independent): fly the 6DOF camera in the
        // restricted envelope and confirm it advances along its facing and
        // never sinks into the terrain (the floor clamp in updateMeshFlight).
        let clearance: Float = 22
        var cam = Camera6DOF.start(position: SIMD3<Float>(512, 512, terrain.heightF(512, 512) + 90))
        cam.speed = 120
        let dt: Float = 1.0 / 60.0
        let startXY = SIMD2<Float>(cam.position.x, cam.position.y)
        var minClearance = Float.greatestFiniteMagnitude
        for f in 0..<240 {
            let turn: Float = f < 120 ? 1 : 0          // bank into a turn, then straighten
            cam.flyRestricted(turn: turn, pitchIn: 0, dt: dt)
            cam.position += cam.forward * cam.speed * dt
            let ground = terrain.heightF(cam.position.x, cam.position.y)
            cam.position.z = max(cam.position.z, ground + clearance)
            minClearance = min(minClearance, cam.position.z - ground)
        }
        let travelled = sqrtf((cam.position.x - startXY.x) * (cam.position.x - startXY.x) +
                              (cam.position.y - startXY.y) * (cam.position.y - startXY.y))
        print(String(format: "  flight: 6DOF camera travelled %.0f units over 4s; min clearance %.0f", travelled, minClearance))
        precondition(travelled > 50, "the flight camera barely moved")
        precondition(minClearance >= clearance - 0.5, "the flight camera sank into the terrain")

        // GPU world render — best-effort. On a real Mac this exercises the mesh
        // renderer end-to-end (encode → readback) and asserts terrain drew; over
        // SSH / headless CI with no Metal device it is SKIPPED, not failed.
        if let device = MTLCreateSystemDefaultDevice(),
           let mr = MeshTerrainRenderer(device: device, terrain: terrain, width: w, height: h) {
            mr.recenterIfNeeded(around: cam.position, sync: true)
            let rgb = mr.renderToRGB(camera: cam)
            var checksum: UInt64 = 0
            for i in stride(from: 0, to: rgb.count, by: 257) { checksum &+= UInt64(rgb[i]) }
            print("  gpu render: \(w)×\(h) frame, checksum \(checksum) (non-zero ⇒ terrain drew)")
            precondition(!rgb.isEmpty && checksum != 0, "mesh renderer produced a blank frame")
        } else {
            print("  gpu render: no Metal device — skipped (headless/CI)")
        }

        // 2D canvas overlays: must draw into the framebuffer without trapping
        // (incl. emoji via Core Text), and actually change the framebuffer.
        let field = EnemyField(terrain: terrain, around: 512, cy: 512)
        let hudStructs = StructureField(terrain: terrain, around: 512, cy: 512, count: 0)
        let canvas = Canvas2D(width: w, height: h, mapSize: Float(terrain.size))
        var beforeSum: UInt64 = 0
        for i in stride(from: 0, to: w * h, by: 53) { beforeSum &+= UInt64(canvas.framebuffer[i]) }
        canvas.drawCockpit(score: 123456, basesStanding: 3, basesTotal: 5,
                           aliens: field.enemies.count, planetName: "Tantalus", level: 2,
                           speed: 140, altitude: 220, shield: 70, maxShield: 100,
                           roll: 0.1, pitch: 8)
        canvas.drawRadar(originX: 512, originY: 512, fwdX: 0, fwdY: -1, rightX: -1, rightY: 0,
                         enemies: field, structures: hudStructs)
        canvas.drawBanner(title: "GAME OVER", subtitle: "SCORE 001200    PRESS R TO RESTART")
        canvas.drawNameEntry(score: 12300, name: "ACE 😀")
        canvas.drawGameOver(loseReason: "SHIELDS DOWN", score: 12300,
                            scores: [HighScoreEntry(name: "ACE 😀", score: 12300, level: 3,
                                                    stardate: "20260531::0140")], highlight: 0)
        var afterSum: UInt64 = 0
        for i in stride(from: 0, to: w * h, by: 53) { afterSum &+= UInt64(canvas.framebuffer[i]) }
        print("  canvas: cockpit/radar/banner/score-screens drew (incl. emoji via Core Text)")
        precondition(beforeSum != afterSum, "the 2D canvas drew nothing")

        // High-score persistence (temp file, so the real table is untouched).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("strataris_smoke_scores.json")
        try? FileManager.default.removeItem(at: tmp)
        let hs1 = HighScores(fileURL: tmp)
        _ = hs1.add(name: "ZIG🚀", score: 4200, level: 2)
        _ = hs1.add(name: "ACE", score: 9001, level: 5)
        let hs2 = HighScores(fileURL: tmp)        // reload from disk
        print("  highscores: persisted \(hs2.entries.count) entries; top = \(hs2.entries.first?.name ?? "?") \(hs2.entries.first?.score ?? -1)")
        precondition(hs2.entries.first?.name == "ACE" && hs2.entries.first?.score == 9001,
                     "high-score persistence/sort failed")
        try? FileManager.default.removeItem(at: tmp)

        // Combat: a 1-hit craft is destroyed and scores (target resolution is
        // the caller's projection job; here we verify the hit/score plumbing).
        let before = field.remaining
        let pts = field.hit(at: 0)
        precondition(field.remaining == before - 1 && pts != nil, "hit didn't destroy a 1-hit craft")
        print("  combat: kill OK (\(before) → \(field.remaining) craft, \(pts ?? 0) pts)")

        // AI path: craft wander and hug the terrain (never sink into it).
        // Player parked far away, no structures, so they purely wander.
        let noStructs = StructureField(terrain: terrain, around: 512, cy: 512, count: 0)
        let noProj = ProjectileField(), noBombs = ProjectileField()
        let aiField = EnemyField(terrain: terrain, around: 512, cy: 512)
        let p0 = aiField.enemies[0]
        for _ in 0..<180 { aiField.update(dt: 1.0 / 60, playerX: 1e6, playerY: 1e6, playerZ: 200, structures: noStructs, projectiles: noProj, bombs: noBombs) }
        let p1 = aiField.enemies[0]
        let moved = abs(p1.x - p0.x) + abs(p1.y - p0.y)
        var minClear = Float.greatestFiniteMagnitude
        for e in aiField.enemies { minClear = min(minClear, e.z - terrain.heightF(e.x, e.y)) }
        print(String(format: "  ai: enemy 0 moved %.1f units over 3s; min ground clearance %.1f",
                     moved, minClear))
        precondition(moved > 0.5, "enemies did not move")
        precondition(minClear > -1, "an enemy sank into the terrain")

        // Anti-collision: a flat-out 280 u/s pursuer must never breach the
        // craft's hard radius — you cannot crash into one.
        let chaseField = EnemyField(terrain: terrain, around: 512, cy: 512)
        var px = chaseField.enemies[0].x + 400, py = chaseField.enemies[0].y
        var closest = Float.greatestFiniteMagnitude
        for _ in 0..<360 {
            let e = chaseField.enemies[0]
            let ddx = e.x - px, ddy = e.y - py
            let dd = max(0.001, sqrtf(ddx * ddx + ddy * ddy))
            let step: Float = 280.0 / 60.0
            px += ddx / dd * step; py += ddy / dd * step
            chaseField.update(dt: 1.0 / 60, playerX: px, playerY: py, playerZ: e.z, structures: noStructs, projectiles: noProj, bombs: noBombs)
            let ne = chaseField.enemies[0]
            let sx = ne.x - px, sy = ne.y - py
            closest = min(closest, sqrtf(sx * sx + sy * sy))
        }
        print(String(format: "  ai avoidance: closest approach by a 280 u/s pursuer = %.0f units", closest))
        precondition(closest >= 50, "pursuer breached the anti-collision radius — a crash is possible")

        // Structures: stamped into the terrain, founded above the surroundings.
        let bastions = StructureField(terrain: terrain, around: 512, cy: 512, count: 5)
        print("  structures: \(bastions.standing) placed")
        precondition(bastions.standing > 0, "no structures placed")
        let st = bastions.structures[0]
        let roofH = terrain.heightF(st.x, st.y)
        let nearH = terrain.heightF(st.x + Float(st.half) + 14, st.y)
        print(String(format: "  structure 0: roof %.0f vs nearby ground %.0f (raised: %@)",
                     roofH, nearH, roofH > nearH ? "yes" : "no"))
        precondition(roofH > nearH, "structure not raised above its surroundings")
        bastions.destroy(0)
        print(String(format: "  structure 0 destroyed → ground restored to %.0f", terrain.heightF(st.x, st.y)))

        // Enemy intent: craft seek structures, and 3 hits level one.
        let atkTerrain = Terrain(seed: 11)
        let atkStructs = StructureField(terrain: atkTerrain, around: 0, cy: 0, count: 4)
        let atkEnemies = EnemyField(terrain: atkTerrain, around: 0, cy: 0)
        let atkProj = ProjectileField(), atkBombs = ProjectileField()
        precondition(atkStructs.standing > 0, "no structures for the intent test")
        func totalDistToStructures() -> Float {
            atkEnemies.enemies.reduce(Float(0)) { acc, e in
                var nearest = Float.greatestFiniteMagnitude
                for s in atkStructs.structures where s.alive {
                    let dx = s.x - e.x, dy = s.y - e.y
                    nearest = min(nearest, sqrtf(dx * dx + dy * dy))
                }
                return acc + nearest
            }
        }
        func totalHealth() -> Int { atkStructs.structures.reduce(0) { $0 + max(0, $1.health) } }

        // Seek: a short window (before anything is destroyed) — craft close in.
        let distBefore = totalDistToStructures()
        for _ in 0..<90 {   // 1.5 s, player far away
            atkEnemies.update(dt: 1.0 / 60, playerX: 1e6, playerY: 1e6, playerZ: 300, structures: atkStructs, projectiles: atkProj, bombs: atkBombs)
        }
        let distAfter = totalDistToStructures()
        print(String(format: "  intent: craft→structure distance %.0f → %.0f (closing in)", distBefore, distAfter))
        precondition(distAfter < distBefore, "craft did not move toward structures")

        // Attack: over time they reach the installations and chip their health.
        // (tick() mirrors the game loop's per-frame structure update.)
        let hp0 = totalHealth()
        for _ in 0..<60 * 30 {   // 30 s
            atkStructs.tick(dt: 1.0 / 60)
            atkEnemies.update(dt: 1.0 / 60, playerX: 1e6, playerY: 1e6, playerZ: 300, structures: atkStructs, projectiles: atkProj, bombs: atkBombs)
        }
        print("  intent: total structure health \(hp0) → \(totalHealth()); standing \(atkStructs.standing)/4")
        precondition(totalHealth() < hp0, "enemies never damaged a structure")
        print("  intent: \(atkBombs.shots.count) bombs in flight onto structures")
        // (bombs spawn on each attack tick; some will be mid-air at any moment)

        // Damage plumbing: hits past the cooldown level a structure (tick clears it).
        if let idx = atkStructs.structures.firstIndex(where: { $0.alive }) {
            let s0 = atkStructs.standing
            let hp = atkStructs.structures[idx].health
            for _ in 0..<hp {
                atkStructs.tick(dt: 2)            // clear the damage cooldown
                atkStructs.damage(at: idx)
            }
            print("  intent: levelled a structure → standing \(s0) → \(atkStructs.standing)")
            precondition(atkStructs.standing == s0 - 1, "killing a structure didn't reduce the count")
        }

        // Return fire: park the player right beside a craft so it's in range
        // and shoots back (also exercises the per-kind enemy update paths).
        let rfEnemies = EnemyField(terrain: terrain, around: 512, cy: 512, count: 9)
        let rfStructs = StructureField(terrain: terrain, around: 512, cy: 512, count: 0)
        let rfProj = ProjectileField(), rfBombs = ProjectileField()
        let anchor = rfEnemies.enemies[0]
        let rfPx = anchor.x, rfPy = anchor.y + 300
        let rfPz = terrain.heightF(rfPx, rfPy) + 110
        var totalHits = 0
        for _ in 0..<600 {   // 10 s
            rfEnemies.update(dt: 1.0 / 60, playerX: rfPx, playerY: rfPy, playerZ: rfPz,
                             structures: rfStructs, projectiles: rfProj, bombs: rfBombs)
            totalHits += rfProj.update(dt: 1.0 / 60, playerX: rfPx, playerY: rfPy, playerZ: rfPz, terrain: terrain)
        }
        print("  return fire: enemy bolts struck the player \(totalHits) time(s) over 10s")
        precondition(totalHits > 0, "enemies never landed a shot on a nearby player")

        print("  ✅ smoke test passed")
    }
}
