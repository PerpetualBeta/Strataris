// Strataris — low-poly ship meshes (Elite-style flat-shaded solids).
//
// Model space: forward = +Y, up = +Z, right = +X (nose at +Y). Each craft is a
// handful of triangles with one base colour; the renderer flat-shades each face
// by its world normal and a fixed light, and the ship is rotated to point along
// its heading. Deliberately simple — readable little 3D hulls, not detail.

import Foundation

/// The colony installation types — distinct silhouettes for variety.
enum BuildingKind: CaseIterable { case tower, spire, dome, bunker, hab, rubble }

struct Mesh {
    let verts: [(Float, Float, Float)]
    let faces: [(Int, Int, Int)]
    let color: (Float, Float, Float)

    /// Sleek interceptor wedge.
    static func fighter() -> Mesh {
        Mesh(verts: [(0, 1.1, 0), (-0.75, -0.7, 0), (0.75, -0.7, 0), (0, -0.45, 0.40), (0, -0.45, -0.30)],
             faces: [(0, 3, 1), (0, 2, 3), (0, 1, 4), (0, 4, 2), (3, 2, 1), (1, 4, 2)],
             color: (120, 152, 214))
    }

    /// Destroyer/bomber: the same interceptor hull, grey/silver (it's rendered
    /// at a larger scale, so it reads as a heavier version of the fighter).
    static func destroyer() -> Mesh {
        let f = fighter()
        return Mesh(verts: f.verts, faces: f.faces, color: (174, 180, 190))
    }

    /// Small octahedral drone.
    static func drone() -> Mesh {
        Mesh(verts: [(0.6, 0, 0), (-0.6, 0, 0), (0, 0.6, 0), (0, -0.6, 0), (0, 0, 0.5), (0, 0, -0.5)],
             faces: [(4, 0, 2), (4, 2, 1), (4, 1, 3), (4, 3, 0),
                     (5, 2, 0), (5, 1, 2), (5, 3, 1), (5, 0, 3)],
             color: (110, 208, 188))
    }

    // MARK: Colony installations (3D models, founded on the terrain)
    //
    // Distinct silhouettes so a colony reads as a built place, not five identical
    // boxes. Model space: footprint within ±1.2 in x/y, base at z=0, up = +Z;
    // the renderer scales by the footprint half-width and places them on the
    // ground. Flat-shaded by face normal, so roofs/walls/slopes self-shade.

    private static func addBox(_ v: inout [(Float, Float, Float)], _ f: inout [(Int, Int, Int)],
                               _ x0: Float, _ x1: Float, _ y0: Float, _ y1: Float, _ z0: Float, _ z1: Float,
                               top: Bool = true) {
        let i = v.count
        v += [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
              (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
        func q(_ a: Int, _ b: Int, _ c: Int, _ d: Int) { f += [(i+a, i+b, i+c), (i+a, i+c, i+d)] }
        q(0, 1, 5, 4); q(1, 2, 6, 5); q(2, 3, 7, 6); q(3, 0, 4, 7)   // 4 walls (outward normals)
        if top { q(4, 5, 6, 7) }                                      // roof
    }

    /// A faceted cone/dome: an `n`-gon ring at z0 (radius r) rising to an apex.
    private static func addCone(_ v: inout [(Float, Float, Float)], _ f: inout [(Int, Int, Int)],
                                r: Float, _ z0: Float, _ z1: Float, n: Int = 8) {
        let apex = v.count
        v.append((0, 0, z1))
        let ring = v.count
        for i in 0..<n {
            let a = Float(i) * 2 * .pi / Float(n)
            v.append((cosf(a) * r, sinf(a) * r, z0))
        }
        for i in 0..<n { f.append((apex, ring + i, ring + (i + 1) % n)) }
    }

    static func building(_ k: BuildingKind) -> Mesh {
        var v = [(Float, Float, Float)](); var f = [(Int, Int, Int)]()
        let col: (Float, Float, Float)
        switch k {
        case .tower:                                   // stepped command tower
            addBox(&v, &f, -1, 1, -1, 1, 0, 1.9)
            addBox(&v, &f, -0.62, 0.62, -0.62, 0.62, 1.9, 2.5)
            addBox(&v, &f, -0.22, 0.22, -0.22, 0.22, 2.5, 2.9)
            col = (150, 156, 170)
        case .spire:                                   // slender comms spire + mast
            addBox(&v, &f, -0.5, 0.5, -0.5, 0.5, 0, 1.7)
            addBox(&v, &f, -0.34, 0.34, -0.34, 0.34, 1.7, 2.3, top: false)
            addCone(&v, &f, r: 0.34, 2.3, 3.2, n: 4)
            col = (172, 178, 192)
        case .dome:                                    // reactor dome on a drum
            addBox(&v, &f, -0.95, 0.95, -0.95, 0.95, 0, 0.6)
            addCone(&v, &f, r: 0.95, 0.6, 1.7, n: 10)
            col = (184, 186, 192)
        case .bunker:                                  // wide low hangar + ridge
            addBox(&v, &f, -1.2, 1.2, -0.85, 0.85, 0, 0.5)
            addBox(&v, &f, -1.0, 1.0, -0.5, 0.5, 0.5, 0.78)
            col = (138, 146, 150)
        case .hab:                                     // modular habitat: block + module + annex
            addBox(&v, &f, -0.92, 0.92, -0.92, 0.92, 0, 1.1)
            addBox(&v, &f, -0.5, 0.5, -0.5, 0.5, 1.1, 1.7)
            addBox(&v, &f, 0.92, 1.35, -0.45, 0.45, 0, 0.62)
            col = (160, 162, 174)
        case .rubble:                                  // charred wreck (destroyed)
            addBox(&v, &f, -0.95, 0.2, -0.8, 0.5, 0, 0.32)
            addBox(&v, &f, 0.1, 0.9, -0.4, 0.85, 0, 0.46)
            addBox(&v, &f, -0.5, 0.4, 0.2, 0.95, 0, 0.22)
            col = (66, 56, 52)
        }
        return Mesh(verts: v, faces: f, color: col)
    }

    /// Model-space top (×footprint scale → world height) — for smoke/explosion origins.
    static func buildingTopZ(_ k: BuildingKind) -> Float {
        switch k {
        case .tower: return 2.9; case .spire: return 3.2; case .dome: return 1.7
        case .bunker: return 0.78; case .hab: return 1.7; case .rubble: return 0.46
        }
    }

    /// Wide faceted saucer (flat hexagonal bipyramid).
    static func mothership() -> Mesh {
        var v: [(Float, Float, Float)] = [(0, 0, 0.42), (0, 0, -0.42)]   // 0 top apex, 1 bottom apex
        for i in 0..<6 {
            let a = Float(i) * .pi / 3
            v.append((cosf(a) * 1.1, sinf(a) * 1.1, 0))                  // ring 2…7
        }
        var f: [(Int, Int, Int)] = []
        for i in 0..<6 {
            let r0 = 2 + i, r1 = 2 + (i + 1) % 6
            f.append((0, r0, r1))                                        // top fan
            f.append((1, r1, r0))                                        // bottom fan
        }
        return Mesh(verts: v, faces: f, color: (164, 152, 188))
    }
}
