// Strataris — low-poly ship meshes (Elite-style flat-shaded solids).
//
// Model space: forward = +Y, up = +Z, right = +X (nose at +Y). Each craft is a
// handful of triangles with one base colour; the renderer flat-shades each face
// by its world normal and a fixed light, and the ship is rotated to point along
// its heading. Deliberately simple — readable little 3D hulls, not detail.

import Foundation

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
