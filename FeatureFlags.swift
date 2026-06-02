// Strataris — hidden feature flags.
//
// Off by default; opt in per machine with `defaults write`, e.g.
//   defaults write cc.jorviksoftware.Strataris ShowFPS            -bool true
//   defaults write cc.jorviksoftware.Strataris ScreenshotOnSpace  -bool true   (F key)
// Read live each frame, so toggling takes effect on the next launch (or
// immediately, for flags re-read every frame).

import Foundation

enum FeatureFlags {
    private static var d: UserDefaults { .standard }

    /// Digital FPS readout, top-right of the HUD.
    static var showFPS: Bool { d.bool(forKey: "ShowFPS") }

    /// Enables the screen-capture control: the F key (keyboard) and a
    /// rebindable gamepad button. Space stays fire so keyboard-only players can
    /// still shoot. (Flag name is kept for back-compat with existing installs.)
    static var screenshotOnSpace: Bool { d.bool(forKey: "ScreenshotOnSpace") }

    // (The radial-pulse weapon is now a per-run level-12 perk, not a flag.)

    /// The GPU triangle-mesh terrain renderer (true 6DOF-capable) is the default.
    /// Opt back to the original Voxel-Space CPU raycaster for A/B comparison or
    /// as a fallback:
    ///   defaults write cc.jorviksoftware.Strataris UseVoxelRenderer -bool true
    static var useMeshRenderer: Bool { !d.bool(forKey: "UseVoxelRenderer") }

    /// Force the "May the fourth be with you" callout at every mission start,
    /// regardless of the date (for testing the date-gated Easter egg).
    ///   defaults write cc.jorviksoftware.Strataris ForceMayTheFourth -bool true
    static var forceMayTheFourth: Bool { d.bool(forKey: "ForceMayTheFourth") }
}
