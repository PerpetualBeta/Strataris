// Strataris — enemies.
//
// Four craft types, each with its own look, flight and role:
//   • Destroyer — bombs the installations; breaks off to attack the player if
//     the player enters the defensive perimeter of the base it's hitting.
//   • Fighter — ignores structures; hunts and strafes the player.
//   • Drone — mimics the behaviour of the nearest Destroyer/Fighter.
//   • Mothership — rare, short-lived (60 s), 10 hits, slow and menacing.
// The opening swarm is split equally among Destroyer / Fighter / Drone.
//
// A hard anti-collision floor keeps the player from ever ramming a craft.

import Foundation

@inline(__always) private func nextRand(_ s: inout UInt32) -> Float {
    s = s &* 1_664_525 &+ 1_013_904_223
    return Float((s >> 8) & 0xFFFF) / Float(0xFFFF)
}

enum EnemyKind { case destroyer, fighter, drone, mothership }

struct Enemy {
    var kind: EnemyKind
    var x: Float
    var y: Float
    var z: Float
    var heading: Float
    var speed: Float
    var hoverOffset: Float
    var bobPhase: Float
    var bobRate: Float
    var wanderTimer: Float
    var rng: UInt32
    var jukeSign: Float
    var attackCooldown: Float
    var fireCooldown: Float
    var health: Int
    var points: Int
    var life: Float            // mothership countdown; <0 = never expires
    var fwdX: Float, fwdY: Float, fwdZ: Float   // unit facing (points where it travels / aims)
}

final class EnemyField {
    private(set) var enemies: [Enemy] = []
    let difficulty: Float
    let meshes: [EnemyKind: Mesh]

    private let terrain: Terrain
    private var fieldRng: UInt32
    private var motherTimer: Float

    // Tuning.
    private let fireRange: Float = 750
    private let attackRange: Float = 150        // destroyer starts bombing a structure inside this
    private let attackInterval: Float = 1.4
    private let defensivePerimeter: Float = 260 // player this close to a bombed base → destroyer defends
    private let strafeRange: Float = 170        // fighter circles the player inside this

    init(terrain: Terrain, around cx: Float, cy: Float, count: Int = 15,
         difficulty: Float = 1, seed: UInt32 = 0x5EED_1234) {
        self.terrain = terrain
        self.difficulty = difficulty
        self.fieldRng = seed ^ 0xA5A5_1234
        self.motherTimer = 40 + Float((seed >> 8) & 0xFF) / 255 * 30   // first mothership ~40–70 s

        var m = [EnemyKind: Mesh]()
        m[.destroyer]  = Mesh.destroyer()
        m[.fighter]    = Mesh.fighter()
        m[.drone]      = Mesh.drone()
        m[.mothership] = Mesh.mothership()
        meshes = m

        var seedState = seed
        func rnd() -> Float {
            seedState = seedState &* 1_664_525 &+ 1_013_904_223
            return Float((seedState >> 8) & 0xFFFF) / Float(0xFFFF)
        }
        let cycle: [EnemyKind] = [.destroyer, .fighter, .drone]
        for i in 0..<count {
            let kind = cycle[i % cycle.count]
            let ahead = 250 + rnd() * 1700
            let lateral = (rnd() - 0.5) * 760
            let ex = cx + lateral
            let ey = cy - ahead
            enemies.append(makeEnemy(kind: kind, x: ex, y: ey,
                                     heading: rnd() * 6.2832, rngSeed: seed ^ (UInt32(i) &* 2_654_435_761)))
        }
    }

    // MARK: Per-kind construction

    private func makeEnemy(kind: EnemyKind, x: Float, y: Float, heading: Float, rngSeed: UInt32) -> Enemy {
        let speed: Float, hover: Float, hp: Int, pts: Int
        switch kind {
        case .destroyer:  speed = 32; hover = 48;  hp = 1;  pts = 250
        case .fighter:    speed = 50; hover = 85;  hp = 1;  pts = 100
        case .drone:      speed = 44; hover = 62;  hp = 1;  pts = 10
        case .mothership: speed = 20; hover = 230; hp = 10; pts = 2500
        }
        var rng = rngSeed
        return Enemy(kind: kind, x: x, y: y, z: terrain.heightF(x, y) + hover,
                     heading: heading, speed: speed, hoverOffset: hover,
                     bobPhase: nextRand(&rng) * 6.2832, bobRate: 0.7 + nextRand(&rng) * 0.7,
                     wanderTimer: nextRand(&rng) * 2, rng: rng,
                     jukeSign: nextRand(&rng) < 0.5 ? -1 : 1,
                     attackCooldown: 2 + nextRand(&rng) * 2, fireCooldown: 1.5 + nextRand(&rng) * 2.5,
                     health: hp, points: pts, life: kind == .mothership ? 60 : -1,
                     fwdX: cosf(heading), fwdY: sinf(heading), fwdZ: 0)
    }

    /// World half-extent of the model (for billboard-free sizing / targeting).
    func scale(for kind: EnemyKind) -> Float {
        switch kind {
        case .destroyer:  return 22
        case .fighter:    return 16
        case .drone:      return 12
        case .mothership: return 62
        }
    }

    func mesh(for kind: EnemyKind) -> Mesh { meshes[kind]! }

    var remaining: Int { enemies.count }

    // MARK: Damage

    /// Apply one hit. Returns the point value if the craft was destroyed,
    /// nil if it merely took damage (the mothership soaks 10).
    func hit(at index: Int) -> Int? {
        guard enemies.indices.contains(index) else { return nil }
        enemies[index].health -= 1
        if enemies[index].health <= 0 {
            let pts = enemies[index].points
            enemies.remove(at: index)
            return pts
        }
        return nil
    }

    /// Radial pulse: remove every craft at once and return their positions for
    /// explosion FX. Awards NO points (the pulse is a panic button, not a kill).
    func obliterateAll() -> [(Float, Float, Float)] {
        let positions = enemies.map { ($0.x, $0.y, $0.z) }
        enemies.removeAll()
        return positions
    }

    // MARK: Update

    func update(dt: Float, playerX: Float, playerY: Float, playerZ: Float,
                structures: StructureField, projectiles: ProjectileField, bombs: ProjectileField) {
        let mapSize = Float(terrain.size)
        func wrap(_ d: Float) -> Float {
            var r = d.truncatingRemainder(dividingBy: mapSize)
            let h = mapSize * 0.5
            if r > h { r -= mapSize } else if r < -h { r += mapSize }
            return r
        }

        // Occasionally send in a mothership.
        motherTimer -= dt
        if motherTimer <= 0 && !enemies.contains(where: { $0.kind == .mothership }) {
            spawnMothership(playerX: playerX, playerY: playerY)
            motherTimer = 50 + nextRand(&fieldRng) * 45
        }

        for i in enemies.indices {
            var e = enemies[i]
            if e.kind == .mothership { e.life -= dt }

            let pdx = wrap(playerX - e.x), pdy = wrap(playerY - e.y)
            let pdist = sqrtf(pdx * pdx + pdy * pdy)

            // Drones adopt the nearest Destroyer/Fighter's role.
            let role = (e.kind == .drone) ? nearestRole(to: e, wrap: wrap) : e.kind

            var v = e.speed * difficulty
            var fireAtPlayer = false
            var handled = false

            func huntPlayer() {
                let ang = atan2f(pdy, pdx)
                if pdist > strafeRange { e.heading = ang; v = e.speed * difficulty * 1.3 }
                else { e.heading = ang + e.jukeSign * 1.2 }
                fireAtPlayer = true
                handled = true
            }

            switch role {
            case .fighter:
                huntPlayer()

            case .destroyer:
                if let tgt = nearestLivingStructure(to: e, in: structures, wrap: wrap) {
                    let s = structures.structures[tgt.index]
                    let psx = wrap(playerX - s.x), psy = wrap(playerY - s.y)
                    if sqrtf(psx * psx + psy * psy) < defensivePerimeter {
                        huntPlayer()                       // defend the base from the intruder
                    } else {
                        let ang = atan2f(tgt.dy, tgt.dx)
                        if tgt.dist > attackRange {
                            e.heading = ang; v = e.speed * difficulty * 1.4
                        } else {
                            e.heading = ang + e.jukeSign * 1.4
                            e.attackCooldown -= dt
                            if e.attackCooldown <= 0 {
                                structures.damage(at: tgt.index)
                                e.attackCooldown = attackInterval
                                bombs.spawnDirected(fromX: e.x, fromY: e.y, fromZ: e.z - 2,
                                                    dirX: 0, dirY: 0, dirZ: -1, speedScale: 0.7)  // freefall
                            }
                        }
                        handled = true
                    }
                } else {
                    huntPlayer()                           // nothing left to bomb → go after the player
                }

            case .mothership:
                // Slow, menacing drift that gradually tracks the player; fires
                // the occasional bolt.
                let ang = atan2f(pdy, pdx)
                var d = ang - e.heading
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                e.heading += d * min(1, dt * 0.3)
                fireAtPlayer = pdist < fireRange * 1.6
                handled = true

            case .drone:
                break   // resolved into a role above
            }

            if !handled {                                  // wander fallback
                e.wanderTimer -= dt
                if e.wanderTimer <= 0 {
                    e.heading += (nextRand(&e.rng) - 0.5) * 1.6
                    e.wanderTimer = 1.5 + nextRand(&e.rng) * 2.5
                }
            }

            e.x += cosf(e.heading) * v * dt
            e.y += sinf(e.heading) * v * dt

            // Facing: point at the player when attacking (so forward guns hit),
            // otherwise along the direction of travel.
            if fireAtPlayer {
                let dz = playerZ - e.z
                let fl = max(0.001, sqrtf(pdx * pdx + pdy * pdy + dz * dz))
                e.fwdX = pdx / fl; e.fwdY = pdy / fl; e.fwdZ = dz / fl
            } else {
                e.fwdX = cosf(e.heading); e.fwdY = sinf(e.heading); e.fwdZ = 0
            }

            // Forward-firing guns (along the nose).
            if fireAtPlayer {
                e.fireCooldown -= dt
                if pdist < fireRange && e.fireCooldown <= 0 {
                    let nose: Float = 8
                    // Aim spread tightens as difficulty rises — early planets miss a lot.
                    let spread = 0.20 / max(0.6, difficulty)
                    let jx = e.fwdX + (nextRand(&e.rng) - 0.5) * spread
                    let jy = e.fwdY + (nextRand(&e.rng) - 0.5) * spread
                    let jz = e.fwdZ + (nextRand(&e.rng) - 0.5) * spread
                    projectiles.spawnDirected(fromX: e.x + e.fwdX * nose, fromY: e.y + e.fwdY * nose,
                                              fromZ: e.z + e.fwdZ * nose, dirX: jx, dirY: jy, dirZ: jz)
                    // Slower cadence early; ramps up with difficulty.
                    e.fireCooldown = e.kind == .mothership ? 1.4 : (2.8 + nextRand(&e.rng) * 1.8) / difficulty
                }
            }

            // Hard anti-collision (bigger bubble for the mothership).
            let minR: Float = e.kind == .mothership ? 95 : 52
            let ndx = wrap(e.x - playerX), ndy = wrap(e.y - playerY)
            let nd2 = ndx * ndx + ndy * ndy
            if nd2 < minR * minR {
                let nd = max(0.001, sqrtf(nd2))
                e.x = e.x - ndx + (ndx / nd) * minR
                e.y = e.y - ndy + (ndy / nd) * minR
            }

            // Terrain-follow + bob.
            e.bobPhase += e.bobRate * dt
            let ground = terrain.heightF(e.x, e.y)
            let targetZ = ground + e.hoverOffset + sinf(e.bobPhase) * 12
            e.z += (targetZ - e.z) * min(1, dt * 3)
            e.z = max(e.z, ground + 8)

            enemies[i] = e
        }

        // Retire a mothership that's overstayed its welcome (fled — no points).
        enemies.removeAll { $0.kind == .mothership && $0.life <= 0 }
    }

    private func spawnMothership(playerX: Float, playerY: Float) {
        let ang = nextRand(&fieldRng) * 6.2832
        let mx = playerX + cosf(ang) * 1200
        let my = playerY + sinf(ang) * 1200
        enemies.append(makeEnemy(kind: .mothership, x: mx, y: my,
                                 heading: ang + .pi, rngSeed: fieldRng ^ 0xBEEF))
    }

    private func nearestRole(to e: Enemy, wrap: (Float) -> Float) -> EnemyKind {
        var best = Float.greatestFiniteMagnitude
        var role: EnemyKind = .fighter      // default if it's alone
        for o in enemies where o.kind == .destroyer || o.kind == .fighter {
            let dx = wrap(o.x - e.x), dy = wrap(o.y - e.y)
            let d2 = dx * dx + dy * dy
            if d2 < best { best = d2; role = o.kind }
        }
        return role
    }

    private func nearestLivingStructure(to e: Enemy, in structures: StructureField,
                                        wrap: (Float) -> Float)
        -> (index: Int, dist: Float, dx: Float, dy: Float)? {
        var best: (index: Int, dist: Float, dx: Float, dy: Float)?
        var bestD2 = Float.greatestFiniteMagnitude
        for (si, s) in structures.structures.enumerated() where s.alive {
            let sdx = wrap(s.x - e.x), sdy = wrap(s.y - e.y)
            let d2 = sdx * sdx + sdy * sdy
            if d2 < bestD2 { bestD2 = d2; best = (si, sqrtf(d2), sdx, sdy) }
        }
        return best
    }
}
