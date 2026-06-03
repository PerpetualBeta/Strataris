// Strataris — legacy camera / ship scalars.
//
// A scalar bridge the HUD, radar, enemy AI and engine audio still read. The
// authoritative flight camera is the quaternion `Camera6DOF`; each frame
// `Renderer.updateMeshFlight` writes the derived scalars here (position, yaw
// `angle`, eased `roll`/`pitch` for the attitude dial, `speed`). It is also
// the path-math carrier for the title flyover (`titleCam`) and the warp
// cinematic (`warpCam`).

import Foundation

struct Camera {
    var x: Float
    var y: Float
    var height: Float
    var angle: Float           // yaw heading (radians)
    var roll: Float = 0        // eased bank angle (drives the attitude dial)
    var pitch: Float = 0       // eased nose tip (drives the attitude dial)

    var speed: Float = 90      // forward units/sec
    let minSpeed: Float = 20
    let maxSpeed: Float = 280

    static func start(over terrain: Terrain) -> Camera {
        Camera(x: 512, y: 512, height: terrain.heightF(512, 512) + 140, angle: 0)
    }
}
