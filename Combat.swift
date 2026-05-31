// Strataris — combat.
//
// Hitscan firing against the reticle. Holding fire auto-repeats on a
// cooldown; each shot targets the nearest non-occluded craft sitting under
// the reticle (the projection + terrain depth test live in VoxelRenderer).
// A hit removes the craft and spawns an explosion; every shot leaves a brief
// tracer for feedback whether it connected or not.
//
// Projectiles are instantaneous for now — crisp and arcade-y. When enemies
// start moving fast we can swap in travelling bolts behind the same call.

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

    func update(dt: Float, input: InputState, camera: Camera,
                field: EnemyField, voxel: VoxelRenderer, smoke: SmokeField,
                crosshairX: Float, crosshairY: Float) {
        fireCooldown = max(0, fireCooldown - dt)
        tracerTimer = max(0, tracerTimer - dt)

        if input.fire && fireCooldown <= 0 {
            fireCooldown = fireInterval
            tracerTimer = 0.07
            if let idx = voxel.targetedEnemy(in: field, camera: camera,
                                             crosshairX: crosshairX, crosshairY: crosshairY) {
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

    /// Clear lingering effects (used when a planet is cleared).
    func clearTransient() {
        explosions.removeAll()
        tracerTimer = 0
    }
}
