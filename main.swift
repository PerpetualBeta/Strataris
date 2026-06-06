// Strataris — entry point.
//
// Two launch paths:
//   • STRATARIS_SMOKE=1 in the environment → run the headless smoke test
//     (game-logic checks, the 2D canvas, the 6DOF flight model, and a
//     best-effort GPU mesh render) and exit. Runs from a shell / CI with no
//     window; the GPU check skips gracefully when there's no Metal device.
//   • otherwise → bring up the Cocoa app and the Metal-backed game window.

import Cocoa

if ProcessInfo.processInfo.environment["STRATARIS_SMOKE"] != nil {
    SmokeTest.run()
    exit(0)
}

// STRATARIS_SHOTS[=dir] → render the doc/marketing screenshots headlessly via
// the game's real draw path, then exit. World shots need a Metal device.
if let dir = ProcessInfo.processInfo.environment["STRATARIS_SHOTS"] {
    Captures.run(outDir: dir)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
