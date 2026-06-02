// Strataris — entry point.
//
// Two launch paths:
//   • STRATARIS_SMOKE=1 in the environment → run a headless CPU render of the
//     voxel engine for a fixed number of frames, print timing, and exit.
//     Lets us validate the hot path (terrain + raycaster) in CI / from a
//     shell without a window or GPU surface.
//   • otherwise → bring up the Cocoa app and the Metal-backed game window.

import Cocoa

if ProcessInfo.processInfo.environment["STRATARIS_SMOKE"] != nil {
    SmokeTest.run()
    exit(0)
}

// Experimental 6DOF renderer spike — headless orientation capture (exp/6dof).
if ProcessInfo.processInfo.environment["STRATARIS_6DOF_PNG"] != nil {
    Spike6DOF.runHeadlessCapture()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
