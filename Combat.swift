// Strataris — combat.
//
// Hitscan firing against the reticle. Holding fire auto-repeats on a cooldown.
// The caller resolves the target craft through the quaternion camera's
// projection and passes it in `lockedTargetIndex` (a targeting-computer lock,
// or whatever sits under the reticle); a nil target means "fire but miss"
// (tracer only). A hit removes the craft and spawns an explosion; every shot
// leaves a brief tracer for feedback whether it connected or not.
//
// The player's shot is hitscan (instantaneous) — crisp and arcade-y. Enemy
// fire, by contrast, uses travelling, dodgeable bolts (see ProjectileField).

import Foundation

struct Explosion {
    var x: Float
    var y: Float
    var z: Float
    var age: Float
}

final class Combat {
    private(set) var explosions: [Explosion] = []
    private(set) var kills = 0
    private(set) var score = 0

    let fireInterval: Float = 0.16
    let explosionDuration: Float = 0.5

    private var fireCooldown: Float = 0
    private var tracerTimer: Float = 0

    var tracerActive: Bool { tracerTimer > 0 }

    /// `lockedTargetIndex`: the craft fire is directed at (a targeting-computer
    /// lock, or whatever the reticle is over, resolved by the caller through the
    /// quaternion projection). nil ⇒ fire but miss (tracer only).
    func update(dt: Float, input: InputState,
                field: EnemyField, smoke: SmokeField,
                lockedTargetIndex: Int? = nil) {
        fireCooldown = max(0, fireCooldown - dt)
        tracerTimer = max(0, tracerTimer - dt)

        if input.fire && fireCooldown <= 0 {
            fireCooldown = fireInterval
            tracerTimer = 0.07
            if let idx = lockedTargetIndex {
                let e = field.enemies[idx]
                explosions.append(Explosion(x: e.x, y: e.y, z: e.z, age: 0))
                if let pts = field.hit(at: idx) {   // nil = damaged but not destroyed (mothership)
                    score += pts
                    kills += 1
                    smoke.burst(x: e.x, y: e.y, z: e.z, big: e.kind == .mothership)   // debris
                }
            }
        }

        for i in explosions.indices { explosions[i].age += dt }
        explosions.removeAll { $0.age >= explosionDuration }
    }

    /// Award points not tied to a kill (level-milestone bonuses).
    func awardBonus(_ pts: Int) { score += pts }

    /// Clear lingering effects (used when a planet is cleared).
    func clearTransient() {
        explosions.removeAll()
        tracerTimer = 0
    }

    /// Spawn explosions + debris at the given points without scoring (used by
    /// the radial pulse weapon, which destroys craft but awards no points).
    func detonate(at positions: [(Float, Float, Float)], smoke: SmokeField) {
        for p in positions {
            explosions.append(Explosion(x: p.0, y: p.1, z: p.2, age: 0))
            smoke.burst(x: p.0, y: p.1, z: p.2, big: true)
        }
    }
}
