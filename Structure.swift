// Strataris — ground structures.
//
// The installations the player defends (the Defender core). Each is a 3-D
// entity model (`kind`) placed on a low flat concrete pad flattened into the
// terrain heightfield (Terrain.stampStructure, wallHeight 3), so it's founded
// in the ground — never floating. Damage is shown by render-time model tint
// driven by `health` (clean → charred → rubble model); the heightfield is not
// re-stamped on damage. This layer holds game state (position, health, alive)
// plus the pad's pristine heightfield snapshot, restored only by `destroy()`
// (cleanup / tests).
//
// Placement seeks flat-ish land, away from water and other structures.
// Destroyers bomb these (see EnemyField); the player defends them.

import Foundation

struct Structure {
    var x: Float
    var y: Float
    var half: Int            // footprint half-width in world cells (also the model scale)
    var roofHeight: Float    // world z of the model top (smoke/explosion origin)
    var kind: BuildingKind   // which 3D installation model
    var health: Int
    var alive: Bool
    var damageCooldown: Float = 0      // rate-limits incoming damage, so a swarm can't delete it
    var originalStamp: Terrain.Stamp   // pristine heightfield under the pad, restored on cleanup
}

final class StructureField {
    private(set) var structures: [Structure] = []
    private let terrain: Terrain
    let maxHealth = 8
    private let damageInterval: Float = 0.9   // min seconds between hits a base will register

    init(terrain: Terrain, around cx: Float, cy: Float, count: Int = 5, seed: UInt32 = 0x0B00_B1E5) {
        self.terrain = terrain
        var rngState = seed
        // Deterministic LCG (Numerical Recipes) → [0,1): same seed ⇒ same colony layout.
        func rnd() -> Float {
            rngState = rngState &* 1_664_525 &+ 1_013_904_223
            return Float((rngState >> 8) & 0xFFFF) / Float(0xFFFF)
        }

        let half = 26
        let kinds: [BuildingKind] = [.tower, .dome, .bunker, .hab, .spire]   // varied silhouettes
        let pad: (UInt8, UInt8, UInt8) = (120, 124, 132)                     // concrete apron
        let minSeparation: Float = 280
        var tries = 0
        while structures.count < count && tries < 500 {
            tries += 1
            let ang = rnd() * 6.2832
            let dist = 520 + rnd() * 1500
            let sx = cx + cosf(ang) * dist
            let sy = cy + sinf(ang) * dist

            if terrain.heightF(sx, sy) <= terrain.seaLevel + 8 { continue }   // keep on land
            var tooClose = false
            for s in structures {
                let dx = s.x - sx, dy = s.y - sy
                if dx * dx + dy * dy < minSeparation * minSeparation { tooClose = true; break }
            }
            if tooClose { continue }
            let (lo, hi) = terrain.heightRange(centerX: sx, centerY: sy, half: half)
            if hi - lo > 24 { continue }                                      // flat-ish

            // Flatten a low concrete pad (no tall walls — the building itself is a
            // 3D model placed on top), so it's founded and reads as built ground.
            // The pad is stamped wider than the placement footprint so the widest
            // models (hab annex ±1.35·s, bunker ±1.2·s) sit fully on concrete with a
            // margin — `half` still drives placement/flatness, so layout is unchanged.
            let kind = kinds[structures.count % kinds.count]
            let stamp = terrain.stampStructure(centerX: sx, centerY: sy, half: half + 12,
                                               wallHeight: 3, body: pad)
            let padTop = terrain.heightF(sx, sy)
            // World Z of the model's top = pad top + (model-space top × the
            // footprint scale, which is `half`). Used as the smoke/explosion origin.
            structures.append(Structure(x: sx, y: sy, half: half,
                                        roofHeight: padTop + Mesh.buildingTopZ(kind) * Float(half),
                                        kind: kind, health: maxHealth, alive: true, originalStamp: stamp))
        }
    }

    var standing: Int { structures.reduce(0) { $0 + ($1.alive ? 1 : 0) } }

    /// Tick down damage cooldowns (call once per frame while playing).
    func tick(dt: Float) {
        for i in structures.indices where structures[i].alive {
            structures[i].damageCooldown = max(0, structures[i].damageCooldown - dt)
        }
    }

    /// Apply damage: drop health (rate-limited by a cooldown so a swarm can't
    /// stack hits) and retire the structure at zero. The crumble/rubble look is
    /// the building model's tint/state at render time, not a heightfield edit.
    /// Returns true if this hit destroyed it.
    @discardableResult
    func damage(at index: Int, amount: Int = 1) -> Bool {
        guard structures.indices.contains(index), structures[index].alive else { return false }
        if structures[index].damageCooldown > 0 { return false }   // rate-limited — a swarm can't stack hits
        structures[index].damageCooldown = damageInterval
        structures[index].health -= amount
        // The damage look (charring → rubble) is the building model's tint/state,
        // applied at render time from `health`; no heightfield re-stamp.
        if structures[index].health <= 0 {
            structures[index].alive = false
            return true
        }
        return false
    }

    /// Hard flatten back to pristine ground (used by tests / cleanup).
    func destroy(_ index: Int) {
        guard structures.indices.contains(index), structures[index].alive else { return }
        terrain.restore(structures[index].originalStamp)
        structures[index].alive = false
    }
}
