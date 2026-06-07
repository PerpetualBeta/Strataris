// Strataris — damage smoke & fire.
//
// A light particle system: each damaged installation continuously emits rising
// smoke (more as its health drops) and, once badly hurt, flame embers. Anchored
// to the structure roof, the particles drift up on a gentle wind and fade out.
// Rendered as depth-tested, alpha-blended billboards over the terrain.

import Foundation

struct Particle {
    var x: Float, y: Float, z: Float
    var vx: Float, vy: Float, vz: Float
    var age: Float
    var life: Float
    var fire: Bool
}

final class SmokeField {
    private(set) var particles: [Particle] = []
    private let terrain: Terrain
    private var rng: UInt32 = 0xC0FFEE
    private let maxParticles = 500

    init(terrain: Terrain) { self.terrain = terrain }

    /// A radial debris burst (flying embers + smoke puffs) for a destroyed craft.
    func burst(x: Float, y: Float, z: Float, big: Bool) {
        let embers = big ? 48 : 26
        for _ in 0..<embers {
            let ang = rnd() * 6.2832
            let sp = (big ? 55 : 36) * (0.4 + rnd() * 0.8)
            particles.append(Particle(x: x, y: y, z: z,
                                      vx: cosf(ang) * sp, vy: sinf(ang) * sp,
                                      vz: (rnd() - 0.25) * sp * 0.7 + sp * 0.3,
                                      age: 0, life: 0.35 + rnd() * 0.5, fire: rnd() < 0.72))
        }
        for _ in 0..<(big ? 14 : 7) {
            particles.append(Particle(x: x, y: y, z: z,
                                      vx: (rnd() - 0.5) * 12, vy: (rnd() - 0.5) * 12, vz: 8 + rnd() * 12,
                                      age: 0, life: 1.0 + rnd() * 0.9, fire: false))
        }
    }

    func update(dt: Float, structures: StructureField, maxHealth: Int) {
        // Emit from each damaged, standing structure.
        for s in structures.structures where s.alive {
            let d = 1 - Float(max(0, s.health)) / Float(maxHealth)   // 0 pristine … 1 near rubble
            if d <= 0.02 { continue }
            emit(rate: d * 16, dt: dt, s: s, fire: false)            // smoke
            if d > 0.5 { emit(rate: (d - 0.5) * 2 * 22, dt: dt, s: s, fire: true) }   // flame
        }
        // Advance + cull.
        for i in particles.indices {
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            particles[i].z += particles[i].vz * dt
            particles[i].age += dt
        }
        particles.removeAll { $0.age >= $0.life }
        if particles.count > maxParticles { particles.removeFirst(particles.count - maxParticles) }
    }

    private func emit(rate: Float, dt: Float, s: Structure, fire: Bool) {
        var n = rate * dt
        while n > 0 {
            if n < 1 && rnd() > n { break }
            n -= 1
            let jx = (rnd() - 0.5) * Float(s.half) * 0.8
            let jy = (rnd() - 0.5) * Float(s.half) * 0.8
            if fire {
                particles.append(Particle(x: s.x + jx, y: s.y + jy, z: s.roofHeight + 2,
                                          vx: (rnd() - 0.5) * 6 + 3, vy: (rnd() - 0.5) * 6,
                                          vz: 22 + rnd() * 16, age: 0, life: 0.4 + rnd() * 0.3, fire: true))
            } else {
                particles.append(Particle(x: s.x + jx, y: s.y + jy, z: s.roofHeight + 4,
                                          vx: (rnd() - 0.5) * 5 + 6, vy: (rnd() - 0.5) * 5,   // gentle wind +x
                                          vz: 9 + rnd() * 7, age: 0, life: 2.2 + rnd() * 1.2, fire: false))
            }
        }
    }

    // Cheap LCG (Numerical Recipes constants) → [0,1) for debris jitter.
    private func rnd() -> Float {
        rng = rng &* 1_664_525 &+ 1_013_904_223
        return Float((rng >> 8) & 0xFFFF) / Float(0xFFFF)
    }
}
