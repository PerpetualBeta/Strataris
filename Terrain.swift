// Strataris — procedural terrain.
//
// A "planet" is two square, power-of-two maps the mesh renderer samples:
//   • heights  — UInt8 altitude, clamped up to sea level so water is flat
//   • colors   — packed RGBA, baked once with height-banding + slope shading
//
// The maps are generated from seamless (tiling) fractal value noise so the
// world wraps endlessly with no visible seam as you fly — sampling is just
// `index & mask`, which wraps power-of-two coordinates for free (including
// negatives, via two's-complement AND).
//
// We bake our OWN terrain rather than ship Comanche's reverse-engineered
// Voxel Space maps (those are outside that project's MIT licence and unfit
// for a commercial product) — and procedural generation is also how every
// warp becomes a fresh planet for ~free.

import Foundation

@inline(__always) func packRGBA(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> UInt32 {
    return UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24)
}

final class Terrain {
    let size: Int
    let mask: Int
    let theme: PlanetTheme              // sky + terrain palette for this planet
    private let baseCells: Int          // lowest-frequency feature count across the map
    private let heights: UnsafeMutablePointer<UInt8>
    private let colors: UnsafeMutablePointer<UInt32>

    let seaLevel: Float = 70

    init(size: Int = 4096, seed: UInt32 = 1, theme: PlanetTheme = PlanetTheme.all[0]) {
        precondition(size > 0 && (size & (size - 1)) == 0, "size must be a power of two")
        self.size = size
        self.mask = size - 1
        self.theme = theme
        // Keep feature size constant (~170 world units per base cell) as the
        // map grows, so a bigger map means MORE unique terrain before it
        // tiles — not just stretched-out hills.
        self.baseCells = max(4, size / 170)
        self.heights = .allocate(capacity: size * size)
        self.colors = .allocate(capacity: size * size)
        generate(seed: seed)
    }

    deinit {
        heights.deallocate()
        colors.deallocate()
    }

    // MARK: Sampling (hot path)

    @inline(__always) func heightF(_ x: Float, _ y: Float) -> Float {
        let xi = Int(x.rounded(.down)) & mask
        let yi = Int(y.rounded(.down)) & mask
        return Float(heights[yi &* size &+ xi])
    }

    @inline(__always) func colorAt(_ x: Float, _ y: Float) -> UInt32 {
        let xi = Int(x.rounded(.down)) & mask
        let yi = Int(y.rounded(.down)) & mask
        return colors[yi &* size &+ xi]
    }

    @inline(__always) private func rawHeight(_ x: Int, _ y: Int) -> Float {
        return Float(heights[(y & mask) &* size &+ (x & mask)])
    }

    // MARK: Generation

    private func generate(seed: UInt32) {
        let sizeF = Float(size)

        // --- Pass 1: heights from seamless fbm. --------------------------------
        for y in 0..<size {
            let v = Float(y) / sizeF
            for x in 0..<size {
                let u = Float(x) / sizeF
                var n = fbm(u, v, seed: seed)          // 0…1
                n = powf(n, 1.5)                        // flatten lowlands
                let raw = n * 255
                // Clamp up to sea level so oceans render as a flat plane.
                let clamped = max(raw, seaLevel)
                heights[y &* size &+ x] = UInt8(min(255, max(0, clamped)))
            }
        }

        // --- Pass 2: colours (height bands + slope shading). -------------------
        for y in 0..<size {
            for x in 0..<size {
                colorCell(x, y, base: nil)
            }
        }
    }

    /// (Re)compute the shaded colour for one cell from the CURRENT heights.
    /// Sun from the west: a west-facing slope catches light, the lee shades.
    /// `base` overrides the natural height-band colour (used by structures).
    private func colorCell(_ x: Int, _ y: Int, base: (UInt8, UInt8, UInt8)?) {
        let h = rawHeight(x, y)
        let hWest = rawHeight(x - 1, y)
        let hEast = rawHeight(x + 1, y)
        let hNorth = rawHeight(x, y - 1)
        let slope = (hWest - hEast) * 0.045 + (hNorth - h) * 0.02
        let light = min(1.32, max(0.55, 1.0 + slope))
        let (r, g, b) = base ?? baseColor(forHeight: h, x: x, y: y)
        colors[(y & mask) &* size &+ (x & mask)] = packRGBA(shade(r, light), shade(g, light), shade(b, light))
    }

    @inline(__always) private func shade(_ c: UInt8, _ light: Float) -> UInt8 {
        return UInt8(min(255, max(0, Float(c) * light)))
    }

    @inline(__always) private func clampU8(_ v: Float) -> UInt8 { UInt8(min(255, max(0, v))) }

    @inline(__always)
    private func lerp3(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8), _ t: Float) -> (UInt8, UInt8, UInt8) {
        let u = max(0, min(1, t))
        return (clampU8(Float(a.0) + (Float(b.0) - Float(a.0)) * u),
                clampU8(Float(a.1) + (Float(b.1) - Float(a.1)) * u),
                clampU8(Float(a.2) + (Float(b.2) - Float(a.2)) * u))
    }

    private func baseColor(forHeight h: Float, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        if h <= seaLevel {
            // Flat sea: no depth variation after clamping, so add a touch of
            // low-frequency noise so the surface isn't dead flat colour.
            let s = fbm(Float(x) / Float(size) * 3, Float(y) / Float(size) * 3, seed: 99)
            let t = 0.5 + 0.5 * s
            let w = theme.water
            return (clampU8(Float(w.0) + 28 * t), clampU8(Float(w.1) + 28 * t), clampU8(Float(w.2) + 34 * t))
        }
        // Land bands with SOFT transitions, so neither the shoreline nor the
        // band edges read as a hard stair-stepped contour. `smoothstep` windows
        // straddle each boundary; the chunky flat facets are kept, just the
        // colour contrast across the boundary is feathered.
        @inline(__always) func sstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
        }
        let beach = theme.beach, veg = theme.veg, rock = theme.rock, peak = theme.peak
        var col: (UInt8, UInt8, UInt8)
        switch h {
        case ..<86:   col = lerp3(beach, veg,  sstep(74, 90, h))
        case ..<148:  col = lerp3(veg,   rock, sstep(132, 152, h))
        case ..<208:  col = lerp3(rock,  peak, sstep(192, 212, h))
        default:      col = peak
        }
        // Wet-sand shore: feather the first few units of land back toward the
        // water tone so the waterline isn't a hard blue↔sand edge.
        if h < seaLevel + 7 {
            col = lerp3(theme.water, col, sstep(seaLevel, seaLevel + 7, h))
        }
        return col
    }

    // MARK: Structures (stamped into the heightfield, so they're truly founded)

    /// Saved heightfield region, for restoring on destruction.
    struct Stamp {
        let x0: Int, y0: Int, w: Int, h: Int
        let heights: [UInt8]
        let colors: [UInt32]
    }

    /// Min/max terrain height over a square footprint (to find flat sites).
    func heightRange(centerX: Float, centerY: Float, half: Int) -> (min: Float, max: Float) {
        let cx = Int(centerX.rounded()), cy = Int(centerY.rounded())
        var lo: Float = 255, hi: Float = 0
        for dy in -half...half {
            for dx in -half...half {
                let v = rawHeight(cx + dx, cy + dy)
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        return (lo, hi)
    }

    /// Raise a square footprint to a flat roof and recolour it (plus a 1-cell
    /// border whose slopes change). The structure becomes part of the
    /// heightfield, so the terrain renderer founds it for free — walls rise
    /// from the surface, ridges occlude it, fog and shading all match.
    /// Returns a snapshot for later restore/destruction.
    @discardableResult
    func stampStructure(centerX: Float, centerY: Float, half: Int,
                        wallHeight: Float, body: (UInt8, UInt8, UInt8)) -> Stamp {
        let cx = Int(centerX.rounded()), cy = Int(centerY.rounded())
        var maxg: Float = 0
        for dy in -half...half {
            for dx in -half...half { maxg = max(maxg, rawHeight(cx + dx, cy + dy)) }
        }
        let roof = UInt8(min(255, maxg + wallHeight))

        let bx0 = cx - half - 1, by0 = cy - half - 1
        let rw = 2 * half + 3, rh = 2 * half + 3

        var savedH = [UInt8](repeating: 0, count: rw * rh)
        var savedC = [UInt32](repeating: 0, count: rw * rh)
        for j in 0..<rh {
            for i in 0..<rw {
                let gx = (bx0 + i) & mask, gy = (by0 + j) & mask
                savedH[j * rw + i] = heights[gy &* size &+ gx]
                savedC[j * rw + i] = colors[gy &* size &+ gx]
            }
        }

        for dy in -half...half {
            for dx in -half...half {
                let gx = (cx + dx) & mask, gy = (cy + dy) & mask
                heights[gy &* size &+ gx] = roof
            }
        }

        // Recolour the footprint (roof = body) and the 1-cell wall ring (a darker
        // shade of body) so the walls read as the building's own sides instead of
        // dragging terrain greens/sands/blues up them. Beyond the ring is natural
        // terrain. The roof/wall tone split gives a clearer solid-3D read.
        let wall = (clampU8(Float(body.0) * 0.6), clampU8(Float(body.1) * 0.6), clampU8(Float(body.2) * 0.62))
        for j in 0..<rh {
            for i in 0..<rw {
                let x = bx0 + i, y = by0 + j
                let inFootprint = abs(x - cx) <= half && abs(y - cy) <= half
                let onRing = !inFootprint && abs(x - cx) <= half + 1 && abs(y - cy) <= half + 1
                colorCell(x, y, base: inFootprint ? body : (onRing ? wall : nil))
            }
        }
        return Stamp(x0: bx0, y0: by0, w: rw, h: rh, heights: savedH, colors: savedC)
    }

    /// Restore a previously stamped region (flatten a destroyed structure).
    func restore(_ s: Stamp) {
        for j in 0..<s.h {
            for i in 0..<s.w {
                let gx = (s.x0 + i) & mask, gy = (s.y0 + j) & mask
                heights[gy &* size &+ gx] = s.heights[j * s.w + i]
                colors[gy &* size &+ gx] = s.colors[j * s.w + i]
            }
        }
    }

    // MARK: Seamless fractal value noise

    private func fbm(_ u: Float, _ v: Float, seed: UInt32) -> Float {
        var amp: Float = 1
        var sum: Float = 0
        var norm: Float = 0
        var cells = baseCells               // base feature count across the map
        for _ in 0..<5 {
            sum += amp * periodicValue(u, v, cells: cells, seed: seed)
            norm += amp
            amp *= 0.5
            cells *= 2
        }
        return sum / norm                   // 0…1
    }

    private func periodicValue(_ u: Float, _ v: Float, cells: Int, seed: UInt32) -> Float {
        let lx = u * Float(cells)
        let ly = v * Float(cells)
        let x0 = Int(lx.rounded(.down))
        let y0 = Int(ly.rounded(.down))
        let fx = lx - Float(x0)
        let fy = ly - Float(y0)

        // Wrap lattice indices to `cells` so the field tiles with period 1
        // in (u, v) — i.e. period `size` in world space. Seamless wrap.
        let x0w = ((x0 % cells) + cells) % cells
        let y0w = ((y0 % cells) + cells) % cells
        let x1w = (x0w + 1) % cells
        let y1w = (y0w + 1) % cells

        let v00 = hash(x0w, y0w, seed)
        let v10 = hash(x1w, y0w, seed)
        let v01 = hash(x0w, y1w, seed)
        let v11 = hash(x1w, y1w, seed)

        let ux = fx * fx * (3 - 2 * fx)     // smoothstep
        let uy = fy * fy * (3 - 2 * fy)
        let a = v00 + (v10 - v00) * ux
        let b = v01 + (v11 - v01) * ux
        return a + (b - a) * uy
    }

    @inline(__always) private func hash(_ x: Int, _ y: Int, _ seed: UInt32) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 73856093
        h ^= UInt32(truncatingIfNeeded: y) &* 19349663
        h ^= seed &* 83492791
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Float(h & 0xFF_FFFF) / Float(0xFF_FFFF)   // 0…1
    }
}
