// Strataris — enemy projectiles.
//
// Craft fire travelling bolts at the player (not hitscan), so they're
// telegraphed and dodgeable, and terrain stops them — ducking behind a ridge
// is real cover. Each frame the field advances its shots and reports how many
// struck the player, so the renderer can drain hull and flash the screen.

import Foundation

struct Projectile {
    var x: Float, y: Float, z: Float
    var vx: Float, vy: Float, vz: Float
    var ttl: Float
}

final class ProjectileField {
    private(set) var shots: [Projectile] = []
    private let speed: Float = 200

    func spawn(fromX: Float, fromY: Float, fromZ: Float,
               targetX: Float, targetY: Float, targetZ: Float, rng: inout UInt32) {
        let dx = targetX - fromX, dy = targetY - fromY, dz = targetZ - fromZ
        let d = max(1, sqrtf(dx * dx + dy * dy + dz * dz))
        let spread: Float = 0.06        // slight inaccuracy so a moving player can dodge
        let nx = dx / d + (pfRand(&rng) - 0.5) * spread
        let ny = dy / d + (pfRand(&rng) - 0.5) * spread
        let nz = dz / d + (pfRand(&rng) - 0.5) * spread
        shots.append(Projectile(x: fromX, y: fromY, z: fromZ,
                                vx: nx * speed, vy: ny * speed, vz: nz * speed, ttl: 3.5))
    }

    /// Fire along an explicit direction (forward guns, freefall bombs).
    func spawnDirected(fromX: Float, fromY: Float, fromZ: Float,
                       dirX: Float, dirY: Float, dirZ: Float, speedScale: Float = 1) {
        let d = max(0.0001, sqrtf(dirX * dirX + dirY * dirY + dirZ * dirZ))
        let s = speed * speedScale
        shots.append(Projectile(x: fromX, y: fromY, z: fromZ,
                                vx: dirX / d * s, vy: dirY / d * s, vz: dirZ / d * s, ttl: 3.5))
    }

    /// Advance shots; return how many struck the player this frame. Shots are
    /// consumed on hit, on hitting the ground, or when they expire.
    func update(dt: Float, playerX: Float, playerY: Float, playerZ: Float, terrain: Terrain) -> Int {
        guard !shots.isEmpty else { return 0 }
        var hits = 0
        let hitR2: Float = 30 * 30
        var kept: [Projectile] = []
        kept.reserveCapacity(shots.count)
        for var p in shots {
            p.x += p.vx * dt; p.y += p.vy * dt; p.z += p.vz * dt
            p.ttl -= dt
            let dx = p.x - playerX, dy = p.y - playerY, dz = p.z - playerZ
            if dx * dx + dy * dy + dz * dz < hitR2 { hits += 1; continue }
            if p.ttl <= 0 { continue }
            if p.z < terrain.heightF(p.x, p.y) { continue }    // hit the ground
            kept.append(p)
        }
        shots = kept
        return hits
    }
}

private func pfRand(_ s: inout UInt32) -> Float {
    s = s &* 1_664_525 &+ 1_013_904_223
    return Float((s >> 8) & 0xFFFF) / Float(0xFFFF)
}
