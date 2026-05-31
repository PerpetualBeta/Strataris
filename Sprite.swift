// Strataris — sprites.
//
// A sprite is a small packed-RGBA bitmap (alpha 0 = transparent) drawn as a
// screen-aligned billboard. No art pipeline yet, so the first alien is built
// in code from a pixel-art mask — the classic Space Invaders "crab", which
// is exactly on-theme for a first-person Invaders — with a 1px black outline
// baked in so it reads against any terrain or sky behind it.

import Foundation

struct Sprite {
    let width: Int
    let height: Int
    let pixels: [UInt32]      // row-major, packed RGBA

    /// The 11×8 invader, padded to 13×10 and given a dark outline.
    static func invader(body: UInt32) -> Sprite {
        let rows = [
            "00100000100",
            "00010001000",
            "00111111100",
            "01101110110",
            "11111111111",
            "10111111101",
            "10100000101",
            "00011011000",
        ]
        let w = rows[0].count, h = rows.count
        let pw = w + 2, ph = h + 2
        var body8 = [UInt32](repeating: 0, count: pw * ph)
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() where ch == "1" {
                body8[(r + 1) * pw + (c + 1)] = body
            }
        }

        // Outline: any transparent cell touching a body cell (8-neighbour)
        // becomes black. Done into a copy so the dilation doesn't feed itself.
        let outline = packRGBA(0, 0, 0, 255)
        var out = body8
        for y in 0..<ph {
            for x in 0..<pw where body8[y * pw + x] == 0 {
                var touches = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= pw || ny >= ph { continue }
                        if body8[ny * pw + nx] == body { touches = true }
                    }
                }
                if touches { out[y * pw + x] = outline }
            }
        }
        return Sprite(width: pw, height: ph, pixels: out)
    }

    // MARK: 3D-looking craft (procedurally shaded)

    private static func shade(_ c: Float, _ b: Float) -> UInt8 { UInt8(min(255, max(0, c * b))) }

    private static func norm(_ t: (Float, Float, Float)) -> (Float, Float, Float) {
        let l = sqrtf(t.0 * t.0 + t.1 * t.1 + t.2 * t.2)
        return (t.0 / l, t.1 / l, t.2 / l)
    }

    /// Add a dark outline ring around the solid pixels (readability).
    private static func outlined(_ src: [UInt32], _ w: Int, _ h: Int) -> Sprite {
        var out = src
        let ol = packRGBA(8, 8, 12, 255)
        for y in 0..<h {
            for x in 0..<w where src[y * w + x] == 0 {
                var adj = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                        if (src[ny * w + nx] >> 24) != 0 { adj = true }
                    }
                }
                if adj { out[y * w + x] = ol }
            }
        }
        return Sprite(width: w, height: h, pixels: out)
    }

    /// A lit ellipsoid hull (saucer / orb / gunship body), shaded for volume.
    static func spheroid(w: Int, h: Int, au: Float, av: Float, base: (Float, Float, Float)) -> Sprite {
        var px = [UInt32](repeating: 0, count: w * h)
        let l = norm((-0.5, -0.6, 0.65))
        for y in 0..<h {
            let v = 2 * Float(y) / Float(h - 1) - 1
            for x in 0..<w {
                let u = 2 * Float(x) / Float(w - 1) - 1
                let e = (u / au) * (u / au) + (v / av) * (v / av)
                if e > 1 { continue }
                let nz = sqrtf(max(0, 1 - e))
                var nx = u / au, ny = v / av, nzz = nz
                let nl = sqrtf(nx * nx + ny * ny + nzz * nzz)
                nx /= nl; ny /= nl; nzz /= nl
                var b = nx * l.0 + ny * l.1 + nzz * l.2
                b = 0.32 + 0.68 * max(0, b)
                if e > 0.80 { b *= 0.55 }                 // rim shading
                px[y * w + x] = packRGBA(shade(base.0, b), shade(base.1, b), shade(base.2, b), 255)
            }
        }
        return outlined(px, w, h)
    }

    @inline(__always) private static func pack(_ c: (Float, Float, Float)) -> UInt32 {
        packRGBA(shade(c.0, 1), shade(c.1, 1), shade(c.2, 1), 255)
    }

    /// Top-down interceptor: slim fuselage, swept delta wings, cockpit, twin
    /// engine glow. Nose points up.
    static func fighter(w: Int, h: Int, base: (Float, Float, Float),
                        cockpit: (Float, Float, Float), engine: (Float, Float, Float)) -> Sprite {
        var px = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h {
            let t = Float(y) / Float(h - 1)                 // 0 nose … 1 tail
            for x in 0..<w {
                let u = 2 * Float(x) / Float(w - 1) - 1
                let fuseHalf = 0.10 + 0.08 * sinf(t * .pi)
                let inFuse = abs(u) <= fuseHalf && t > 0.03 && t < 0.93
                let wingHalf = min(0.96, max(0, (t - 0.34) / 0.50) * 0.96)
                let inWing = t > 0.34 && t < 0.90 && abs(u) <= wingHalf
                if !(inFuse || inWing) { continue }
                var b = 0.5 + 0.5 * max(0, 1 - abs(u) / 0.6)   // central ridge
                b *= 0.88 + 0.12 * (-u)
                var c = (base.0 * b, base.1 * b, base.2 * b)
                if abs(u) < 0.09 && t > 0.10 && t < 0.26 { c = cockpit }
                if t > 0.85 && abs(abs(u) - 0.05) < 0.07 { c = engine }
                px[y * w + x] = pack(c)
            }
        }
        return outlined(px, w, h)
    }

    /// Top-down gunship: thick hull, stub wings, side weapon pods, bridge,
    /// engine bank — heavy and slab-sided.
    static func gunship(w: Int, h: Int, base: (Float, Float, Float),
                        cockpit: (Float, Float, Float), engine: (Float, Float, Float)) -> Sprite {
        var px = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h {
            let t = Float(y) / Float(h - 1)
            for x in 0..<w {
                let u = 2 * Float(x) / Float(w - 1) - 1
                let bodyHalf = 0.32 + 0.05 * sinf(t * .pi)
                let inBody = abs(u) <= bodyHalf && t > 0.05 && t < 0.95
                let inWing = t > 0.48 && t < 0.86 && abs(u) <= 0.66
                let inPod = abs(abs(u) - 0.58) < 0.13 && t > 0.44 && t < 0.92
                if !(inBody || inWing || inPod) { continue }
                var b = 0.45 + 0.5 * max(0, 1 - abs(u) / 0.8)
                b *= 0.88 + 0.12 * (-u)
                var c = (base.0 * b, base.1 * b, base.2 * b)
                if abs(u) < 0.18 && t > 0.12 && t < 0.30 { c = cockpit }
                if t > 0.90 && abs(u) < 0.24 { c = engine }
                px[y * w + x] = pack(c)
            }
        }
        return outlined(px, w, h)
    }

    /// Top-down flying saucer: domed disc, dark rim band, ring of lights.
    static func saucer(w: Int, h: Int, base: (Float, Float, Float), light: (Float, Float, Float)) -> Sprite {
        var px = [UInt32](repeating: 0, count: w * h)
        let l = norm((-0.5, -0.6, 0.65))
        for y in 0..<h {
            let v = 2 * Float(y) / Float(h - 1) - 1
            for x in 0..<w {
                let u = 2 * Float(x) / Float(w - 1) - 1
                let e = u * u + (v / 0.6) * (v / 0.6)
                if e > 1 { continue }
                let nz = sqrtf(max(0, 1 - e))
                var nx = u, ny = v / 0.6, nzz = nz
                let nl = sqrtf(nx * nx + ny * ny + nzz * nzz)
                nx /= nl; ny /= nl; nzz /= nl
                var b = 0.32 + 0.68 * max(0, nx * l.0 + ny * l.1 + nzz * l.2)
                let de = (u / 0.42) * (u / 0.42) + ((v + 0.10) / 0.34) * ((v + 0.10) / 0.34)
                if de < 1 { b += 0.45 }                       // raised dome
                var c = (base.0 * b, base.1 * b, base.2 * b)
                if e > 0.80 { c = (c.0 * 0.55, c.1 * 0.55, c.2 * 0.62) }   // rim band
                let a = atan2f(v, u) / .pi * 5                // ring of lights
                if e > 0.72 && e < 0.93 && abs(a - a.rounded()) < 0.13 { c = light }
                px[y * w + x] = pack(c)
            }
        }
        return outlined(px, w, h)
    }

    /// Small drone: central domed pod with two side panels (TIE-like).
    static func dronePod(w: Int, h: Int, base: (Float, Float, Float), accent: (Float, Float, Float)) -> Sprite {
        var px = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h {
            let v = 2 * Float(y) / Float(h - 1) - 1
            for x in 0..<w {
                let u = 2 * Float(x) / Float(w - 1) - 1
                let r2 = u * u + v * v
                let inPod = r2 <= 0.27
                let inWing = abs(abs(u) - 0.78) < 0.16 && abs(v) < 0.80
                let inStrut = abs(v) < 0.12 && abs(u) < 0.80
                if !(inPod || inWing || inStrut) { continue }
                var b: Float = 0.6
                if inPod { b = 0.4 + 0.6 * sqrtf(max(0, 1 - r2 / 0.27)) }   // dome
                var c = (base.0 * b, base.1 * b, base.2 * b)
                if r2 < 0.05 { c = accent }                   // central eye
                px[y * w + x] = pack(c)
            }
        }
        return outlined(px, w, h)
    }
}
