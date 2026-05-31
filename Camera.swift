// Strataris — camera / ship state.
//
// The observer for the voxel raycaster. Position (x, y) lives on the
// heightmap plane; `height` is altitude in the same units as the map's
// 0…255 height values. `angle` is yaw in radians. `horizon` is the
// screen-space row the horizon projects to (shifting it = pitch). The ship
// auto-flies forward along `angle`; the player only steers, climbs/dives,
// and adjusts throttle.

import Foundation

struct Camera {
    var x: Float
    var y: Float
    var height: Float
    var angle: Float           // fixed heading — the ship always faces forward
    var horizon: Float         // effective horizon row (= horizonBase + pitch)
    let horizonBase: Float     // level-flight horizon
    var roll: Float = 0        // eased bank angle; tilts the horizon for feel
    var pitch: Float = 0       // eased nose tip; shifts the horizon up/down

    // Flight tuning. All eyeballed for "feels like flying"; easy to tweak
    // once the thing is on screen — that's the whole point of the prototype.
    var speed: Float = 90          // forward units/sec (auto-fly)
    let minSpeed: Float = 20
    let maxSpeed: Float = 280

    let scaleHeight: Float = 220   // vertical projection scale
    let maxDistance: Float = 800   // far clip (z)
    let clearance: Float = 110     // min altitude kept above the terrain

    static func start(over terrain: Terrain, renderHeight: Int) -> Camera {
        let h = terrain.heightF(512, 512)
        let h0 = Float(renderHeight) * 0.40
        return Camera(
            x: 512, y: 512,
            height: h + 140,
            angle: 0,
            horizon: h0,
            horizonBase: h0
        )
    }

    mutating func update(dt: Float, input: InputState, terrain: Terrain) {
        // Throttle.
        let accel: Float = 140
        if input.faster { speed = min(maxSpeed, speed + accel * dt) }
        if input.slower { speed = max(minSpeed, speed - accel * dt) }

        // Banking turn: left/right roll AND rotate the heading, so the ship
        // genuinely changes direction of travel (a real turn, not a sideways
        // slide) while always facing where it's going. Forward is (-sin,-cos);
        // increasing the angle curves travel toward screen-left.
        var turn: Float = 0
        if input.bankLeft  { turn += 1 }      // ← turn left
        if input.bankRight { turn -= 1 }      // → turn right
        let turnRate: Float = 1.5             // rad/sec at full bank — sharp enough to track attackers
        angle += turn * turnRate * dt

        // Ease the visual roll (horizon tilt) toward the bank — steeper angle.
        let maxRoll: Float = 0.15
        roll += (turn * maxRoll - roll) * min(1, dt * 8)

        // Auto-fly forward along the heading.
        x += -sinf(angle) * speed * dt
        y += -cosf(angle) * speed * dt

        // Climb / dive — flight-stick sense: ↑ pushes the nose DOWN to dive
        // (drop the horizon, lose altitude); ↓ pulls it UP to climb. Tips the
        // nose AND changes altitude, easing back to level on release.
        let climbRate: Float = 150
        var pitchInput: Float = 0
        if input.climb { pitchInput -= 1 }   // ↑ = nose down / descend
        if input.dive  { pitchInput += 1 }   // ↓ = nose up / climb
        height += pitchInput * climbRate * dt
        let maxPitch: Float = 80          // point the nose much further up / down
        pitch += (pitchInput * maxPitch - pitch) * min(1, dt * 6)
        horizon = horizonBase + pitch

        // Never sink into the ground; keep a little clearance. Also a soft
        // ceiling so you can't fly off into orbit.
        let ground = terrain.heightF(x, y)
        height = max(height, ground + clearance)
        height = min(height, 460)
    }
}
