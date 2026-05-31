// Strataris — ground structures.
//
// The installations the player defends (the Defender core). Each is stamped
// into the terrain heightfield (see Terrain.stampStructure), so it's founded
// in the ground — never floating — and renders, occludes, and shades exactly
// like the landscape it's built on. This object layer holds game state
// (position, health, alive) and owns the heightfield snapshot needed to
// flatten the site when the structure is destroyed.
//
// Placement seeks flat-ish land, away from water and other structures.
// No enemy interaction yet — these stand to be defended.

import Foundation

struct Structure {
    var x: Float
    var y: Float
    var half: Int            // footprint half-width in world cells
    var roofHeight: Float
    var health: Int
    var alive: Bool
    var damageCooldown: Float = 0      // rate-limits incoming damage, so a swarm can't delete it
    var originalStamp: Terrain.Stamp   // pristine heightfield, restored before each re-stamp
}

final class StructureField {
    private(set) var structures: [Structure] = []
    private let terrain: Terrain
    let maxHealth = 8
    private let damageInterval: Float = 0.9   // min seconds between hits a base will register

    init(terrain: Terrain, around cx: Float, cy: Float, count: Int = 5, seed: UInt32 = 0x0B00_B1E5) {
        self.terrain = terrain
        var rngState = seed
        func rnd() -> Float {
            rngState = rngState &* 1_664_525 &+ 1_013_904_223
            return Float((rngState >> 8) & 0xFFFF) / Float(0xFFFF)
        }

        let half = 26
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

            let look = StructureField.stageLook(health: maxHealth, maxHealth: maxHealth)
            let stamp = terrain.stampStructure(centerX: sx, centerY: sy, half: half,
                                               wallHeight: look.wall, body: look.body)
            structures.append(Structure(x: sx, y: sy, half: half,
                                        roofHeight: terrain.heightF(sx, sy),
                                        health: maxHealth, alive: true, originalStamp: stamp))
        }
    }

    var standing: Int { structures.reduce(0) { $0 + ($1.alive ? 1 : 0) } }

    /// Restore the terrain under every structure to pristine (used on restart).
    func restoreAll() {
        for s in structures { terrain.restore(s.originalStamp) }
    }

    private static func clampU8(_ v: Float) -> UInt8 { UInt8(min(255, max(0, v))) }

    /// Footprint look by remaining health: clean bright concrete (pristine) →
    /// charred and shrinking → glowing red-hot when critical → low dark rubble
    /// at zero. A wide colour swing (not just a height nudge) so the damage
    /// state reads clearly from the air.
    static func stageLook(health: Int, maxHealth: Int) -> (wall: Float, body: (UInt8, UInt8, UInt8)) {
        if health <= 0 { return (8, (52, 44, 40)) }                 // rubble
        let f = max(0, min(1, Float(health) / Float(maxHealth)))    // 1 pristine … 0 dead
        let wall = 20 + f * 30                                       // ~50 → ~22 as it crumbles
        var r = 70 + (195 - 70) * f                                 // charred → clean grey
        var g = 56 + (200 - 56) * f
        var b = 50 + (210 - 50) * f
        if f < 0.4 {                                                // ember glow when badly hurt
            let e = (0.4 - f) / 0.4
            r += e * 95; g -= e * 12; b -= e * 16
        }
        return (wall, (clampU8(r), clampU8(g), clampU8(b)))
    }

    /// Apply damage: drop health, re-stamp the footprint to its new state
    /// (restoring pristine ground first so damage stages don't compound), and
    /// retire the structure at zero. Returns true if this hit destroyed it.
    /// Tick down damage cooldowns (call once per frame while playing).
    func tick(dt: Float) {
        for i in structures.indices where structures[i].alive {
            structures[i].damageCooldown = max(0, structures[i].damageCooldown - dt)
        }
    }

    @discardableResult
    func damage(at index: Int, amount: Int = 1) -> Bool {
        guard structures.indices.contains(index), structures[index].alive else { return false }
        if structures[index].damageCooldown > 0 { return false }   // rate-limited — a swarm can't stack hits
        structures[index].damageCooldown = damageInterval
        structures[index].health -= amount
        let h = max(0, structures[index].health)
        let s = structures[index]
        terrain.restore(s.originalStamp)
        let look = StructureField.stageLook(health: h, maxHealth: maxHealth)
        terrain.stampStructure(centerX: s.x, centerY: s.y, half: s.half,
                               wallHeight: look.wall, body: look.body)
        structures[index].roofHeight = terrain.heightF(s.x, s.y)
        if h <= 0 {
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
