// Strataris — CPU voxel terrain renderer.
//
// The Comanche-style "Voxel Space" technique (Kilauea / NovaLogic, 1992):
// for each screen COLUMN, march a ray forward across the heightmap from
// near to far; at each step project the sampled terrain height to a screen
// row and draw the vertical span from there up to the highest pixel already
// filled in that column (the y-buffer). Front-to-back + y-buffer means each
// pixel is written at most once and nearer ridges occlude farther ones for
// free — no depth sorting, no polygons.
//
// Output is a packed-RGBA framebuffer the Metal layer uploads as a texture
// and upscales nearest-neighbour. Deliberately low-res for the period look.
//
// This is the engine we'll later hang sprites + HUD off; keeping it a plain
// CPU pass (no GPU dependency) is also what lets the headless SmokeTest at
// the bottom exercise it without a window.

import Foundation
import QuartzCore

final class VoxelRenderer {
    let width: Int
    let height: Int
    let framebuffer: UnsafeMutablePointer<UInt32>

    private let terrain: Terrain
    private let ybuf: UnsafeMutablePointer<Float>
    private let depthBuf: UnsafeMutablePointer<Float>   // per-pixel terrain distance, for sprite occlusion
    private let sky: UnsafeMutablePointer<UInt32>   // precomputed gradient, one per row
    private let fog: UInt32                          // haze colour distant terrain fades into

    init(width: Int, height: Int, terrain: Terrain) {
        self.width = width
        self.height = height
        self.terrain = terrain
        self.framebuffer = .allocate(capacity: width * height)
        self.ybuf = .allocate(capacity: width)
        self.depthBuf = .allocate(capacity: width * height)
        self.sky = .allocate(capacity: height)

        // Sky gradient from this planet's theme: a deep top colour fading to a
        // pale horizon haze. The haze is also what distant terrain blends into,
        // so the far clip plane dissolves instead of popping.
        let st = terrain.theme.skyTop, sh = terrain.theme.skyHaze
        let topR = Float(st.0), topG = Float(st.1), topB = Float(st.2)
        let hazR = Float(sh.0), hazG = Float(sh.1), hazB = Float(sh.2)
        for y in 0..<height {
            let t = Float(y) / Float(height)
            let r: Float = topR + (hazR - topR) * t
            let g: Float = topG + (hazG - topG) * t
            let b: Float = topB + (hazB - topB) * t
            sky[y] = packRGBA(UInt8(r), UInt8(g), UInt8(b))
        }
        self.fog = packRGBA(UInt8(hazR), UInt8(hazG), UInt8(hazB))
    }

    deinit {
        framebuffer.deallocate()
        ybuf.deallocate()
        depthBuf.deallocate()
        sky.deallocate()
    }

    func render(camera: Camera) {
        let w = width, h = height
        let fb = framebuffer
        let db = depthBuf

        // Clear to the sky gradient; sky is "infinitely" far for depth tests.
        for y in 0..<h {
            let c = sky[y]
            let base = y &* w
            for x in 0..<w {
                fb[base &+ x] = c
                db[base &+ x] = .greatestFiniteMagnitude
            }
        }

        // Reset y-buffer to the bottom of the screen.
        let hF = Float(h)
        for i in 0..<w { ybuf[i] = hF }

        let sinA = sinf(camera.angle)
        let cosA = cosf(camera.angle)
        let camH = camera.height
        let scale = camera.scaleHeight
        let horizon = camera.horizon
        let maxDist = camera.maxDistance
        let invDist = 1.0 / maxDist
        let wF = Float(w)
        let halfW = wF * 0.5
        let roll = camera.roll          // horizon tilt (banking), pixels-per-column

        // March outward. dz grows with distance: fine detail near, coarse far
        // (level-of-detail), which also bounds the step count.
        var z: Float = 1.0
        var dz: Float = 1.0
        while z < maxDist {
            // The two ends of the scan line at this distance, rotated by yaw.
            // (A 90°-ish frustum — the classic Voxel Space framing.)
            var plx = (-cosA * z - sinA * z) + camera.x
            var ply = ( sinA * z - cosA * z) + camera.y
            let prx = ( cosA * z - sinA * z) + camera.x
            let pry = (-sinA * z - cosA * z) + camera.y
            let dx = (prx - plx) / wF
            let dy = (pry - ply) / wF

            let invZScale = (1.0 / z) * scale
            let fogT = z * invDist                    // 0 near … 1 far

            for i in 0..<w {
                let mapH = terrain.heightF(plx, ply)
                let horizonI = horizon + (Float(i) - halfW) * roll
                let projected = (camH - mapH) * invZScale + horizonI
                let top = Int(projected)
                let bottom = Int(ybuf[i])

                if top < bottom {
                    // `top` can go negative when terrain projects above the
                    // top of the screen (flying low beneath a tall peak).
                    // Clamp the fill to the visible range and store a
                    // non-negative y-buffer, or a later column forms the
                    // inverted Range `0 ..< negative` and Swift traps.
                    let from = max(0, top)
                    if from < bottom {
                        let col = fogBlend(terrain.colorAt(plx, ply), fog, fogT)
                        var idx = from &* w &+ i
                        for _ in from..<bottom {
                            fb[idx] = col
                            db[idx] = z          // nearest terrain claims the pixel first
                            idx &+= w
                        }
                    }
                    ybuf[i] = Float(from)
                }
                plx += dx
                ply += dy
            }

            z += dz
            dz += 0.005
        }
    }

    @inline(__always) private func fogBlend(_ c: UInt32, _ f: UInt32, _ t: Float) -> UInt32 {
        if t <= 0 { return c }
        let it = 1 - t
        let r = Float(c & 0xFF) * it + Float(f & 0xFF) * t
        let g = Float((c >> 8) & 0xFF) * it + Float((f >> 8) & 0xFF) * t
        let b = Float((c >> 16) & 0xFF) * it + Float((f >> 16) & 0xFF) * t
        return packRGBA(UInt8(r), UInt8(g), UInt8(b))
    }

    // MARK: Enemy rendering — flat-shaded 3D hulls (call AFTER render(camera:))

    /// Draw each craft as a small flat-shaded 3D model, rotated to face its
    /// heading, depth-tested per pixel against the terrain.
    func drawEnemies(_ field: EnemyField, camera: Camera) {
        let camX = camera.x, camY = camera.y, camZ = camera.height
        let lx: Float = -0.4, ly: Float = -0.5, lz: Float = 0.77

        // Far → near, so nearer ships resolve correctly even at equal depths.
        let order = field.enemies.indices.sorted {
            sq(field.enemies[$0].x - camX) + sq(field.enemies[$0].y - camY)
                > sq(field.enemies[$1].x - camX) + sq(field.enemies[$1].y - camY)
        }

        for ei in order {
            let e = field.enemies[ei]
            let mesh = field.mesh(for: e.kind)
            let scale = field.scale(for: e.kind)

            // Orthonormal basis from the facing vector (fwd, right, up).
            var fx = e.fwdX, fy = e.fwdY, fz = e.fwdZ
            let fl = max(0.0001, sqrtf(fx * fx + fy * fy + fz * fz)); fx /= fl; fy /= fl; fz /= fl
            var rx = fy, ry = -fx, rz: Float = 0                 // fwd × worldUp(0,0,1)
            var rl = sqrtf(rx * rx + ry * ry + rz * rz)
            if rl < 0.0001 { rx = 1; ry = 0; rz = 0; rl = 1 }
            rx /= rl; ry /= rl; rz /= rl
            let ux = ry * fz - rz * fy, uy = rz * fx - rx * fz, uz = rx * fy - ry * fx   // right × fwd

            let n = mesh.verts.count
            var wx = [Float](repeating: 0, count: n), wy = wx, wz = wx
            var sx = [Float](repeating: 0, count: n), sy = sx, sd = sx
            var ok = [Bool](repeating: false, count: n)
            for vi in 0..<n {
                let (mx, my, mz) = mesh.verts[vi]
                let px = e.x + scale * (mx * rx + my * fx + mz * ux)
                let py = e.y + scale * (mx * ry + my * fy + mz * uy)
                let pz = e.z + scale * (mx * rz + my * fz + mz * uz)
                wx[vi] = px; wy[vi] = py; wz[vi] = pz
                if let p = project(px, py, pz, camera: camera) { sx[vi] = p.x; sy[vi] = p.y; sd[vi] = p.depth; ok[vi] = true }
            }

            // Mesh centroid (world space) — used to orient each face normal
            // outward. The hulls are convex, so a normal that points away from
            // the centroid faces outward regardless of how the face was wound.
            // This makes backface culling winding-independent: the fighter /
            // destroyer wedge has mixed winding, which previously left some
            // front faces culled (holes in the hull).
            var mcx: Float = 0, mcy: Float = 0, mcz: Float = 0
            for vi in 0..<n { mcx += wx[vi]; mcy += wy[vi]; mcz += wz[vi] }
            mcx /= Float(n); mcy /= Float(n); mcz /= Float(n)

            // Draw the craft whole or not at all: if any vertex is behind or
            // hard up against the camera near-plane, the projection blows up
            // (stretched/torn triangles), so skip the entire ship. The 14-unit
            // floor sits well inside the in-game anti-collision distance, so this
            // only ever triggers on the attract camera flying through frozen craft.
            var nearest = Float.greatestFiniteMagnitude
            var clipped = false
            for vi in 0..<n {
                if ok[vi] { nearest = min(nearest, sd[vi]) } else { clipped = true; break }
            }
            if clipped || nearest < 14 { continue }

            for (ia, ib, ic) in mesh.faces {
                if !(ok[ia] && ok[ib] && ok[ic]) { continue }    // any vertex behind camera → skip
                let e1x = wx[ib] - wx[ia], e1y = wy[ib] - wy[ia], e1z = wz[ib] - wz[ia]
                let e2x = wx[ic] - wx[ia], e2y = wy[ic] - wy[ia], e2z = wz[ic] - wz[ia]
                var nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x
                let nl = sqrtf(nx * nx + ny * ny + nz * nz); if nl < 1e-5 { continue }
                nx /= nl; ny /= nl; nz /= nl
                let cxw = (wx[ia] + wx[ib] + wx[ic]) / 3, cyw = (wy[ia] + wy[ib] + wy[ic]) / 3, czw = (wz[ia] + wz[ib] + wz[ic]) / 3
                // Orient outward (away from the mesh centroid), then cull/shade.
                if nx * (cxw - mcx) + ny * (cyw - mcy) + nz * (czw - mcz) < 0 { nx = -nx; ny = -ny; nz = -nz }
                if nx * (camX - cxw) + ny * (camY - cyw) + nz * (camZ - czw) <= 0 { continue }   // backface
                var b = nx * lx + ny * ly + nz * lz
                b = 0.35 + 0.65 * max(0, b)
                let col = packRGBA(UInt8(min(255, mesh.color.0 * b)),
                                   UInt8(min(255, mesh.color.1 * b)),
                                   UInt8(min(255, mesh.color.2 * b)))
                fillTri(sx[ia], sy[ia], sd[ia], sx[ib], sy[ib], sd[ib], sx[ic], sy[ic], sd[ic], col)
            }
        }
    }

    @inline(__always) private func sq(_ x: Float) -> Float { x * x }

    /// Depth-tested flat triangle fill (barycentric).
    private func fillTri(_ ax: Float, _ ay: Float, _ ad: Float,
                         _ bx: Float, _ by: Float, _ bd: Float,
                         _ cx: Float, _ cy: Float, _ cd: Float, _ color: UInt32) {
        let minX = max(0, Int((min(ax, min(bx, cx))).rounded(.down)))
        let maxX = min(width - 1, Int((max(ax, max(bx, cx))).rounded(.up)))
        let minY = max(0, Int((min(ay, min(by, cy))).rounded(.down)))
        let maxY = min(height - 1, Int((max(ay, max(by, cy))).rounded(.up)))
        if minX > maxX || minY > maxY { return }
        let area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        if abs(area) < 1e-4 { return }
        let inv = 1 / area
        let fb = framebuffer, db = depthBuf
        for py in minY...maxY {
            let fy = Float(py) + 0.5
            let row = py * width
            for px in minX...maxX {
                let fx = Float(px) + 0.5
                let wa = ((bx - fx) * (cy - fy) - (by - fy) * (cx - fx)) * inv
                let wb = ((cx - fx) * (ay - fy) - (cy - fy) * (ax - fx)) * inv
                let wc = 1 - wa - wb
                if wa < 0 || wb < 0 || wc < 0 { continue }
                let depth = wa * ad + wb * bd + wc * cd
                let idx = row + px
                if depth < db[idx] { fb[idx] = color; db[idx] = depth }
            }
        }
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

    /// Shortest signed distance on a periodic (tiling) axis of length `size`.
    @inline(__always) private func wrapDelta(_ d: Float, _ size: Float) -> Float {
        var r = d.truncatingRemainder(dividingBy: size)
        let half = size * 0.5
        if r > half { r -= size } else if r < -half { r += size }
        return r
    }

    // MARK: Projection (shared by targeting + effects)

    /// World point → (depth, screen x, screen y), or nil if behind/too far.
    /// Uses the same basis and vertical projection as the terrain + sprites,
    /// so targeting and effects line up exactly with what's drawn.
    func project(_ wx: Float, _ wy: Float, _ wz: Float, camera: Camera) -> (depth: Float, x: Float, y: Float)? {
        let a = camera.angle
        let fwdX = -sinf(a), fwdY = -cosf(a)
        let rightX = cosf(a), rightY = -sinf(a)
        let mapSize = Float(terrain.size)
        let dx = wrapDelta(wx - camera.x, mapSize)
        let dy = wrapDelta(wy - camera.y, mapSize)
        let depth = dx * fwdX + dy * fwdY
        if depth <= 1 || depth >= camera.maxDistance { return nil }
        let lateral = dx * rightX + dy * rightY
        let halfW = Float(width) * 0.5
        let sx = halfW + (lateral / depth) * halfW
        let sy = (camera.height - wz) / depth * camera.scaleHeight + camera.horizon
        return (depth, sx, sy)
    }

    // MARK: Targeting

    /// Index of the nearest, non-occluded craft whose billboard the reticle
    /// is over. Call BEFORE drawEnemies so the depth buffer holds terrain only
    /// (otherwise a craft occludes itself). nil = nothing under the reticle.
    func targetedEnemy(in field: EnemyField, camera: Camera,
                       crosshairX: Float, crosshairY: Float) -> Int? {
        let w = width, h = height
        let scaleH = camera.scaleHeight
        var best: Int? = nil
        var bestDepth = Float.greatestFiniteMagnitude

        for (i, e) in field.enemies.enumerated() {
            guard let p = project(e.x, e.y, e.z, camera: camera) else { continue }
            // Reticle within the craft's projected radius (+ forgiving margin)?
            let r = min(field.scale(for: e.kind) * scaleH / p.depth, Float(h) * 4) + 4
            if abs(crosshairX - p.x) > r { continue }
            if abs(crosshairY - p.y) > r { continue }
            // Occlusion: is the craft's centre pixel in front of the terrain?
            var px = Int(p.x), py = Int(p.y)
            if px < 0 { px = 0 } else if px >= w { px = w - 1 }
            if py < 0 { py = 0 } else if py >= h { py = h - 1 }
            if p.depth >= depthBuf[py * w + px] { continue }
            if p.depth < bestDepth { bestDepth = p.depth; best = i }
        }
        return best
    }

    /// Targeting Computer: the nearest-to-reticle, non-occluded craft whose
    /// projected centre lies within `zoneRadius` px of the crosshair. Unlike
    /// `targetedEnemy` (which uses each craft's billboard radius and ranks by
    /// depth), this uses a fixed screen zone and ranks by 2D screen distance.
    /// Call BEFORE drawEnemies (depth buffer must hold terrain only).
    func lockableEnemy(in field: EnemyField, camera: Camera,
                       crosshairX: Float, crosshairY: Float, zoneRadius: Float) -> Int? {
        let w = width, h = height
        var best: Int? = nil
        var bestD2 = zoneRadius * zoneRadius
        for (i, e) in field.enemies.enumerated() {
            guard let p = project(e.x, e.y, e.z, camera: camera) else { continue }
            let dx = crosshairX - p.x, dy = crosshairY - p.y
            let d2 = dx * dx + dy * dy
            if d2 > bestD2 { continue }
            var px = Int(p.x), py = Int(p.y)
            if px < 0 { px = 0 } else if px >= w { px = w - 1 }
            if py < 0 { py = 0 } else if py >= h { py = h - 1 }
            if p.depth >= depthBuf[py * w + px] { continue }     // occluded by terrain
            bestD2 = d2; best = i
        }
        return best
    }

    /// Screen-space distance from the reticle to a craft's projected centre,
    /// or nil if it isn't in view. Used to test whether a lock is still in-zone.
    func screenDistanceToReticle(ofEnemyAt index: Int, in field: EnemyField, camera: Camera,
                                 crosshairX: Float, crosshairY: Float) -> Float? {
        guard let p = screenPosition(ofEnemyAt: index, in: field, camera: camera) else { return nil }
        let dx = crosshairX - p.x, dy = crosshairY - p.y
        return sqrtf(dx * dx + dy * dy)
    }

    /// Where a given craft projects on screen (for tests / future HUD/radar).
    func screenPosition(ofEnemyAt index: Int, in field: EnemyField, camera: Camera)
        -> (x: Float, y: Float, depth: Float)? {
        guard field.enemies.indices.contains(index) else { return nil }
        let e = field.enemies[index]
        guard let p = project(e.x, e.y, e.z, camera: camera) else { return nil }
        return (p.x, p.y, p.depth)
    }

    // MARK: Effects (call AFTER drawEnemies)

    func drawExplosions(_ explosions: [Explosion], duration: Float, camera: Camera) {
        let w = width, h = height
        let fb = framebuffer, db = depthBuf
        let worldSize: Float = 26
        for ex in explosions {
            guard let p = project(ex.x, ex.y, ex.z, camera: camera) else { continue }
            let lifeT = max(0, min(1, ex.age / duration))
            let radius = worldSize * (0.4 + lifeT * 1.7) * camera.scaleHeight / p.depth
            if radius < 0.5 { continue }
            let r2 = radius * radius
            let ri = Int(radius)
            let cxI = Int(p.x), cyI = Int(p.y)
            let x0 = max(0, cxI - ri), x1 = min(w - 1, cxI + ri)
            let y0 = max(0, cyI - ri), y1 = min(h - 1, cyI + ri)
            if x0 > x1 || y0 > y1 { continue }
            for py in y0...y1 {
                let dyf = Float(py) - p.y
                let row = py * w
                for px in x0...x1 {
                    let dxf = Float(px) - p.x
                    let d2 = dxf * dxf + dyf * dyf
                    if d2 > r2 { continue }
                    if p.depth >= db[row + px] { continue }       // behind terrain
                    // Dither-fade the burst as it ages out.
                    if lifeT > 0.55 {
                        let hsh = (px &* 73 &+ py &* 131) & 7
                        if Float(hsh) / 8 < (lifeT - 0.55) / 0.45 { continue }
                    }
                    let dn = sqrtf(d2) / radius                   // 0 centre … 1 edge
                    let col: UInt32
                    if dn < 0.4 { col = packRGBA(255, 240, 180) }
                    else if dn < 0.75 { col = packRGBA(255, 150, 50) }
                    else { col = packRGBA(190, 60, 20) }
                    fb[row + px] = col
                }
            }
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

    /// Targeting Computer: dashed box around the locked craft, sized to its
    /// projected radius (same math as `targetedEnemy`).
    func drawLockBox(forEnemyAt index: Int, in field: EnemyField, camera: Camera, color: UInt32) {
        guard field.enemies.indices.contains(index) else { return }
        let e = field.enemies[index]
        guard let p = project(e.x, e.y, e.z, camera: camera) else { return }
        let r = min(field.scale(for: e.kind) * camera.scaleHeight / p.depth, Float(height) * 4) + 5
        drawDottedBox(cx: p.x, cy: p.y, half: r, color: color)
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
        let ro2 = r * r, ri = r - 3, ri2 = ri * ri
        for dy in -r...r {
            let py = cy + dy; if py < 0 || py >= height { continue }
            let row = py * width
            for dx in -r...r {
                let px = cx + dx; if px < 0 || px >= width { continue }
                let d2 = dx * dx + dy * dy
                if d2 > ro2 { continue }
                framebuffer[row + px] = d2 >= ri2
                    ? ((dx + dy) < 0 ? dashRing : dashRingLo)    // bevelled ring (lit top-left)
                    : dashScreenBG
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
        let bankA = bank * 3.0
        let sb = sinf(bankA), cb = cosf(bankA)
        let off = (pitch / 80) * Float(r) * 0.7
        let sky = packRGBA(70, 130, 210), ground = packRGBA(120, 82, 52), line = packRGBA(235, 238, 248)
        for dy in -r...r {
            let py = cy + dy
            if py < 0 || py >= height { continue }
            let row = py * width
            for dx in -r...r {
                let px = cx + dx
                if px < 0 || px >= width { continue }
                if dx * dx + dy * dy > r * r { continue }
                let ry = -Float(dx) * sb + Float(dy) * cb
                let d = ry - off
                framebuffer[row + px] = abs(d) < 1.3 ? line : (d < 0 ? sky : ground)
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

    /// Feature flag: digital FPS readout, top-right corner.
    func drawFPS(_ fps: Int) {
        let s = "\(min(999, max(0, fps))) FPS"
        Font.draw(s, into: framebuffer, w: width, h: height,
                  x: width - Font.width(s) - 4, y: 4, color: packRGBA(120, 255, 160))
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

    func drawHUD(score: Int, basesStanding: Int, basesTotal: Int,
                 aliens: Int, speed: Int, altitude: Int, planetName: String, level: Int,
                 shield: Int, maxShield: Int) {
        let white = packRGBA(225, 232, 240)
        let amber = packRGBA(255, 200, 90)
        let red = packRGBA(255, 80, 60)
        let fb = framebuffer

        // Shield bar, bottom-left (green → amber → red as it drops).
        let frac = max(0, min(1, Float(shield) / Float(max(1, maxShield))))
        let bx = 10, by = height - 26, bw = 64, bh = 5
        fillRect(bx - 1, by - 1, bw + 2, bh + 2, packRGBA(18, 18, 22))
        let hc = frac > 0.5 ? packRGBA(80, 200, 255) : (frac > 0.25 ? amber : red)
        fillRect(bx, by, Int(Float(bw) * frac), bh, hc)
        Font.draw("SHIELD", into: fb, w: width, h: height, x: bx + bw + 4, y: by - 1, color: white)
        Font.draw(String(format: "SCORE %06d", score), into: fb, w: width, h: height, x: 10, y: 9, color: white)
        Font.draw("BASES \(basesStanding)/\(basesTotal)", into: fb, w: width, h: height, x: 10, y: 19,
                  color: basesStanding == 0 ? red : amber)
        Font.draw("ALIENS \(aliens)", into: fb, w: width, h: height, x: 10, y: 29, color: white)
        // Planet name + level, top-right.
        let planetText = "\(planetName.uppercased())  L\(level)"
        Font.draw(planetText, into: fb, w: width, h: height,
                  x: width - Font.width(planetText) - 12, y: 9, color: amber)
        Font.draw("SPD \(speed)  ALT \(altitude)", into: fb, w: width, h: height, x: 10, y: height - 12, color: white)
    }

    func drawRadar(camera: Camera, enemies: EnemyField, structures: StructureField) {
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

        // Player basis: rotate the world so forward points up on the scope.
        let a = camera.angle
        let fwdX = -sinf(a), fwdY = -cosf(a)
        let rightX = cosf(a), rightY = -sinf(a)
        let mapSize = Float(terrain.size)
        let inner = Float(R - 1)
        func wrap(_ d: Float) -> Float {
            var r = d.truncatingRemainder(dividingBy: mapSize)
            let h = mapSize * 0.5
            if r > h { r -= mapSize } else if r < -h { r += mapSize }
            return r
        }
        func blip(_ wx: Float, _ wy: Float, _ color: UInt32, _ s: Int) {
            let dx = wrap(wx - camera.x), dy = wrap(wy - camera.y)
            let fwd = dx * fwdX + dy * fwdY
            let rgt = dx * rightX + dy * rightY
            var ox = (rgt / range) * inner
            var oy = -(fwd / range) * inner                     // up = forward
            let m = sqrtf(ox * ox + oy * oy)
            if m > inner { ox *= inner / m; oy *= inner / m }   // clamp to the rim
            let ix = cxp + Int(ox), iy = cyp + Int(oy)
            for j in -s...s { for i in -s...s { plot(ix + i, iy + j, color) } }
        }

        for st in structures.structures where st.alive { blip(st.x, st.y, packRGBA(90, 220, 255), 1) }
        for e in enemies.enemies { blip(e.x, e.y, packRGBA(255, 90, 40), 0) }

        // Player marker — a small triangle pointing up at the centre.
        let p = packRGBA(120, 255, 140)
        plot(cxp, cyp - 2, p)
        plot(cxp - 1, cyp - 1, p); plot(cxp + 1, cyp - 1, p)
        plot(cxp - 2, cyp, p); plot(cxp, cyp, p); plot(cxp + 2, cyp, p)
    }

    /// Draw bolts as small glowing billboards, depth-tested against terrain.
    func drawProjectiles(_ field: ProjectileField, camera: Camera,
                         glow: UInt32 = packRGBA(255, 210, 80),
                         core: UInt32 = packRGBA(255, 255, 220)) {
        let db = depthBuf
        for p in field.shots {
            guard let pr = project(p.x, p.y, p.z, camera: camera) else { continue }
            let ix = Int(pr.x), iy = Int(pr.y)
            if ix < 0 || ix >= width || iy < 0 || iy >= height { continue }
            if pr.depth >= db[iy * width + ix] { continue }     // behind terrain
            for oy in -1...1 { for ox in -1...1 { plot(ix + ox, iy + oy, glow) } }
            plot(ix, iy, core)
        }
    }

    /// Draw smoke (grey, alpha-blended) and fire/embers (additive glow) as
    /// depth-tested soft billboards. Used for damaged-structure plumes and
    /// the debris bursts from destroyed craft.
    func drawSmoke(_ field: SmokeField, camera: Camera) {
        let fb = framebuffer, db = depthBuf
        let scaleH = camera.scaleHeight
        for p in field.particles {
            guard let pr = project(p.x, p.y, p.z, camera: camera) else { continue }
            let t = min(1, p.age / p.life)
            let worldR: Float = p.fire ? (3 + p.age * 8) : (5 + p.age * 18)
            var screenR = worldR * scaleH / pr.depth
            if screenR < 0.6 { continue }
            screenR = min(screenR, 42)
            let ri = Int(screenR)
            let cxI = Int(pr.x), cyI = Int(pr.y)
            let aBase: Float = p.fire ? (1 - t) * 0.95 : (1 - t) * 0.5
            if aBase <= 0.02 { continue }
            for dy in -ri...ri {
                let py = cyI + dy
                if py < 0 || py >= height { continue }
                let row = py * width
                for dx in -ri...ri {
                    let px = cxI + dx
                    if px < 0 || px >= width { continue }
                    let d2 = dx * dx + dy * dy
                    if d2 > ri * ri { continue }
                    let idx = row + px
                    if pr.depth >= db[idx] { continue }         // behind terrain
                    let a = aBase * (1 - sqrtf(Float(d2)) / Float(ri))
                    if a <= 0.02 { continue }
                    let dst = fb[idx]
                    let dr = Float(dst & 0xFF), dg = Float((dst >> 8) & 0xFF), dbb = Float((dst >> 16) & 0xFF)
                    if p.fire {
                        let fr = 255 * (1 - 0.35 * t), fg = 150 * (1 - 0.6 * t) + 50, fbl: Float = 40
                        fb[idx] = packRGBA(UInt8(min(255, dr + fr * a)),
                                           UInt8(min(255, dg + fg * a)),
                                           UInt8(min(255, dbb + fbl * a)))
                    } else {
                        let g = 70 + 80 * t
                        fb[idx] = packRGBA(UInt8(g * a + dr * (1 - a)),
                                           UInt8(g * a + dg * (1 - a)),
                                           UInt8((g + 8) * a + dbb * (1 - a)))
                    }
                }
            }
        }
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
    private func drawImageAlpha(_ bmp: TextImage.Bitmap, x: Int, y: Int) {
        let fb = framebuffer
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
                if a == 255 { fb[drow + px] = s; continue }
                let ia = Float(255 - a) / 255.0
                let d = fb[drow + px]
                let rr = Float(s & 0xFF) + Float(d & 0xFF) * ia
                let gg = Float((s >> 8) & 0xFF) + Float((d >> 8) & 0xFF) * ia
                let bb = Float((s >> 16) & 0xFF) + Float((d >> 16) & 0xFF) * ia
                fb[drow + px] = packRGBA(UInt8(min(255, rr)), UInt8(min(255, gg)), UInt8(min(255, bb)))
            }
        }
    }

    /// Rasterise and centre a Unicode string horizontally at row `y`.
    func drawUnicodeCentered(_ s: String, y: Int, fontSize: CGFloat,
                             _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        guard let bmp = TextImage.rasterize(s, fontSize: fontSize, r: r, g: g, b: b) else { return }
        drawImageAlpha(bmp, x: (width - bmp.w) / 2, y: y)
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
    func drawTitleScreen(time: Float, topName: String?, topScore: Int) {
        let fb = framebuffer
        let W = width, H = height
        let Hf = Float(H)

        // Legibility: darken a band at the top (behind the logo) and bottom
        // (behind the prompts), fading into the live scene.
        let topBand = Int(Hf * 0.46)
        for y in 0..<topBand {
            let keep = 0.28 + 0.72 * (Float(y) / Float(topBand))
            let row = y * W
            for x in 0..<W { fb[row + x] = darken(fb[row + x], keep) }
        }
        let botStart = Int(Hf * 0.72)
        for y in botStart..<H {
            let keep = 0.28 + 0.72 * (Float(H - 1 - y) / Float(max(1, H - botStart)))
            let row = y * W
            for x in 0..<W { fb[row + x] = darken(fb[row + x], keep) }
        }

        // Title wordmark (bespoke ArcadeClassic-style logo) + subtitle.
        let ty = Int(Hf * 0.07)
        drawTitleLogo("STRATARIS", centerX: W / 2, topY: ty, time: time)
        let logoBottom = ty + LogoFont.glyphHeight
        let sub = "GALACTIC COLONY DEFENCE"
        Font.draw(sub, into: fb, w: W, h: H, x: (W - Font.width(sub, scale: 2)) / 2,
                  y: logoBottom + 12, scale: 2, color: packRGBA(190, 218, 255))

        // Prompt (blink), hi-score, controls, credit.
        if sinf(time * 4) > -0.25 {
            let p = "PRESS ENTER TO START"
            Font.draw(p, into: fb, w: W, h: H, x: (W - Font.width(p, scale: 2)) / 2,
                      y: H - 76, scale: 2, color: packRGBA(255, 255, 255))
        }
        let menu = "[B] MISSION BRIEFING    [V] ENEMY INTEL"
        Font.draw(menu, into: fb, w: W, h: H, x: (W - Font.width(menu, scale: 1)) / 2,
                  y: H - 54, scale: 1, color: packRGBA(130, 200, 235))
        let hi = String(format: "High Score: %06d   ", topScore) + (topName ?? "---")
        drawUnicodeCentered(hi, y: H - 38, fontSize: 11, 1.0, 0.86, 0.4)
        let ctrl = "ARROWS STEER   SPACE FIRE   PLUS/MINUS THROTTLE   P PAUSE"
        Font.draw(ctrl, into: fb, w: W, h: H, x: (W - Font.width(ctrl, scale: 1)) / 2,
                  y: H - 14, scale: 1, color: packRGBA(165, 175, 200))
        let credit = "JORVIK SOFTWARE PRESENTS"
        Font.draw(credit, into: fb, w: W, h: H, x: (W - Font.width(credit, scale: 1)) / 2,
                  y: 6, scale: 1, color: packRGBA(150, 160, 185))
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
        static let gapH    = 2             // px between bars
        static let tracking = 1            // blank unit columns between glyphs
        static var glyphHeight: Int { stripes * stripeH + (stripes - 1) * gapH }

        // (unit width, 7 stripe column-masks). Lifted from the actual font.
        static let glyphs: [Character: (w: Int, s: [UInt8])] = [
            " ": (3, [0, 0, 0, 0, 0, 0, 0]),
            "S": (7, [0b0111100, 0b1100110, 0b1100000, 0b0111110, 0b0000011, 0b1100011, 0b0111110]),
            "T": (6, [0b111111,  0b001100,  0b001100,  0b001100,  0b001100,  0b001100,  0b001100]),
            "R": (7, [0b1111110, 0b1100011, 0b1100011, 0b1100111, 0b1111100, 0b1101110, 0b1100111]),
            "A": (7, [0b0011100, 0b0110110, 0b1100011, 0b1100011, 0b1111111, 0b1100011, 0b1100011]),
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
        let glyphsSeq = upper.map { LogoFont.glyphs[$0] ?? LogoFont.glyphs[" "]! }
        let totalUnits = glyphsSeq.reduce(0) { $0 + $1.w } + (glyphsSeq.count - 1) * LogoFont.tracking
        let faceW = totalUnits * uw
        let faceH = LogoFont.glyphHeight
        let pad   = 2                                      // keyline room
        let bw = faceW + pad * 2
        let bh = faceH + pad * 2
        let ox = pad, oy = pad                             // face origin in bbox

        // Mask of the glyph faces — each stripe is a `sh`-tall bar, gaps left clear.
        var mask = [Bool](repeating: false, count: bw * bh)
        var penUnit = 0
        for gl in glyphsSeq {
            for si in 0..<LogoFont.stripes {
                let bits = gl.s[si]
                let y0 = oy + si * (sh + gp)
                for col in 0..<gl.w where bits & (UInt8(1) << (gl.w - 1 - col)) != 0 {
                    let x0 = ox + (penUnit + col) * uw
                    for yy in 0..<sh { let r = (y0 + yy) * bw; for xx in 0..<uw { mask[r + x0 + xx] = true } }
                }
            }
            penUnit += gl.w + LogoFont.tracking
        }
        @inline(__always) func solid(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < bw && y >= 0 && y < bh && mask[y * bw + x]
        }

        let fb = framebuffer, W = width, H = height
        let bx = centerX - faceW / 2 - ox                  // bbox top-left in fb
        let by = topY - oy
        @inline(__always) func put(_ lx: Int, _ ly: Int, _ c: UInt32) {
            let px = bx + lx, py = by + ly
            if px >= 0 && px < W && py >= 0 && py < H { fb[py * W + px] = c }
        }

        // Brushed-aluminium ramp: cool blue-grey, light top edge → mid steel →
        // soft dark band → faint relight → dull base. Muted, low-chroma.
        let stops: [(Float, Float, Float, Float)] = [
            (0.00, 222, 227, 234), (0.18, 188, 194, 203), (0.45, 142, 149, 161),
            (0.50,  92,  98, 111), (0.57, 150, 157, 168), (0.80, 178, 184, 193),
            (1.00, 112, 118, 130),
        ]
        @inline(__always) func ramp(_ t: Float) -> (Float, Float, Float) {
            var i = 0; while i < stops.count - 1 && t > stops[i + 1].0 { i += 1 }
            let a = stops[i], b = stops[min(i + 1, stops.count - 1)]
            let span = max(0.0001, b.0 - a.0), k = min(1, max(0, (t - a.0) / span))
            return (a.1 + (b.1 - a.1) * k, a.2 + (b.2 - a.2) * k, a.3 + (b.3 - a.3) * k)
        }

        // Pass 1 — dark keyline around the face (1px, 8-neighbourhood). No 3D
        // extrude: with the glyphs split into separate stripes, a per-bar extrude
        // leaves stray dark nubs in the gaps; the keyline + bevel carry the depth.
        let keyline = packRGBA(14, 16, 22)
        for ly in 0..<bh {
            for lx in 0..<bw where !solid(lx, ly) {
                if solid(lx-1, ly) || solid(lx+1, ly) || solid(lx, ly-1) || solid(lx, ly+1) ||
                   solid(lx-1, ly-1) || solid(lx+1, ly-1) || solid(lx-1, ly+1) || solid(lx+1, ly+1) {
                    put(lx, ly, keyline)
                }
            }
        }

        // Pass 2 — gradient face + soft bevel + brushed grain + dull sheen.
        let sweep = (time * 0.32).truncatingRemainder(dividingBy: 2.2)  // slow, off-screen pause
        for ly in 0..<bh {
            let t = min(1, max(0, Float(ly - oy) / Float(faceH)))
            let (rr, gg, bb) = ramp(t)
            for lx in 0..<bw where mask[ly * bw + lx] {
                var r = rr, g = gg, b = bb
                if !solid(lx, ly - 1) { r = min(255, r*0.6 + 78); g = min(255, g*0.6 + 80); b = min(255, b*0.6 + 84) }   // soft top edge
                else if !solid(lx, ly + 1) { r *= 0.52; g *= 0.52; b *= 0.56 }                                          // bottom shade (cool)
                if !solid(lx - 1, ly) { r = min(255, r + 16); g = min(255, g + 16); b = min(255, b + 18) }              // faint left catch
                // brushed grain: faint vertical streaks (the metal's grain runs along the bars)
                let grain = Float((lx &* 2654435761) >> 27 & 0x7) - 3.5    // deterministic, ~[-3.5, 3.5]
                r += grain; g += grain; b += grain
                // dull anisotropic sheen — broad and low, drifting across the word
                let diag = (Float(lx) - Float(ly) * 0.5) / Float(faceW)
                let dist = abs(diag - (sweep - 0.5))
                if dist < 0.16 { let k = (1 - dist / 0.16) * 0.22; r += (236 - r)*k; g += (239 - g)*k; b += (244 - b)*k }
                put(lx, ly, packRGBA(UInt8(min(255, max(0, r))), UInt8(min(255, max(0, g))), UInt8(min(255, max(0, b)))))
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
        let total = VoxelRenderer.briefingLines.count * lineH + bodyH
        let scroll = Int(time * 14) % total
        for (i, raw) in VoxelRenderer.briefingLines.enumerated() {
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

    /// Centred end-of-game banner over a darkened band.
    func drawBanner(title: String, subtitle: String) {
        let fb = framebuffer
        let bandY = height / 2 - 24, bandH = 50
        for yy in max(0, bandY)..<min(height, bandY + bandH) {
            let row = yy * width
            for xx in 0..<width { fb[row + xx] = darken(fb[row + xx], 0.32) }
        }
        let tScale = 3
        let tw = Font.width(title, scale: tScale)
        Font.draw(title, into: fb, w: width, h: height, x: (width - tw) / 2, y: height / 2 - 16,
                  scale: tScale, color: packRGBA(255, 225, 110))
        let sw = Font.width(subtitle, scale: 1)
        Font.draw(subtitle, into: fb, w: width, h: height, x: (width - sw) / 2, y: height / 2 + 14,
                  scale: 1, color: packRGBA(230, 236, 246))
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

        let renderer = VoxelRenderer(width: w, height: h, terrain: terrain)
        var camera = Camera.start(over: terrain, renderHeight: h)
        let input = InputState()
        input.kb.faster = true         // accelerate while we fly the test

        let frames = 240
        let dt: Float = 1.0 / 60.0
        var total = 0.0
        var worst = 0.0
        var checksum: UInt64 = 0

        for f in 0..<frames {
            camera.update(dt: dt, input: input, terrain: terrain)
            let s = CACurrentMediaTime()
            renderer.render(camera: camera)
            let ms = (CACurrentMediaTime() - s) * 1000
            total += ms
            worst = max(worst, ms)
            if f == frames - 1 {
                for i in stride(from: 0, to: w * h, by: 257) {
                    checksum &+= UInt64(renderer.framebuffer[i])
                }
            }
        }

        let avg = total / Double(frames)
        print(String(format: "  %d frames @ %d×%d — avg %.2f ms (%.0f fps), worst %.2f ms",
                     frames, w, h, avg, 1000.0 / avg, worst))
        print("  final-frame checksum: \(checksum) (non-zero ⇒ terrain drew)")
        precondition(checksum != 0, "framebuffer was blank — render produced nothing")

        // Regression: render from an absurdly low altitude so terrain
        // projects above the screen top (negative `top`). This is the case
        // that trapped on an inverted fill Range; must now complete cleanly.
        var lowCam = Camera.start(over: terrain, renderHeight: h)
        lowCam.height = 25
        renderer.render(camera: lowCam)
        print("  low-altitude render: OK (no inverted-range trap)")

        // Sprite + occlusion path: render from the start pose and composite
        // the enemy field; confirm alien pixels actually reached the screen.
        let field = EnemyField(terrain: terrain, around: 512, cy: 512)
        let startCam = Camera.start(over: terrain, renderHeight: h)
        renderer.render(camera: startCam)
        var beforeSum: UInt64 = 0
        for i in stride(from: 0, to: w * h, by: 53) { beforeSum &+= UInt64(renderer.framebuffer[i]) }
        renderer.drawEnemies(field, camera: startCam)
        var afterSum: UInt64 = 0
        for i in stride(from: 0, to: w * h, by: 53) { afterSum &+= UInt64(renderer.framebuffer[i]) }
        print("  enemy field: \(field.enemies.count) craft; framebuffer changed: \(beforeSum != afterSum)")
        precondition(beforeSum != afterSum, "no craft drew — sprite/occlusion path is broken")

        // HUD + radar overlay: must draw without trapping.
        let hudStructs = StructureField(terrain: terrain, around: 512, cy: 512, count: 0)
        renderer.drawHUD(score: 123456, basesStanding: 3, basesTotal: 5,
                         aliens: field.enemies.count, speed: 140, altitude: 220,
                         planetName: "Tantalus", level: 2,
                         shield: 70, maxShield: 100)
        renderer.drawRadar(camera: startCam, enemies: field, structures: hudStructs)
        renderer.drawBanner(title: "GAME OVER", subtitle: "SCORE 001200    PRESS R TO RESTART")
        renderer.drawNameEntry(score: 12300, name: "ACE 😀")
        renderer.drawGameOver(loseReason: "SHIELDS DOWN", score: 12300,
                              scores: [HighScoreEntry(name: "ACE 😀", score: 12300, level: 3,
                                                      stardate: "20260531::0140")], highlight: 0)
        print("  hud/radar/banner/score-screens: drew without trapping (incl. emoji via Core Text)")

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

        // Combat path: re-render terrain-only (so depth isn't polluted by
        // sprites), then place the reticle on each craft in turn until one
        // targets, and confirm it can be removed.
        renderer.render(camera: startCam)
        var targeted: Int? = nil
        var aimAt = (x: Float(0), y: Float(0))
        for i in field.enemies.indices {
            guard let sp = renderer.screenPosition(ofEnemyAt: i, in: field, camera: startCam) else { continue }
            if let t = renderer.targetedEnemy(in: field, camera: startCam, crosshairX: sp.x, crosshairY: sp.y) {
                targeted = t; aimAt = (sp.x, sp.y); break
            }
        }
        print("  combat: reticle (\(Int(aimAt.x)),\(Int(aimAt.y))) targets enemy \(String(describing: targeted))")
        precondition(targeted != nil, "no craft targetable with the reticle placed on it")
        let before = field.remaining
        let pts = field.hit(at: targeted!)
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
