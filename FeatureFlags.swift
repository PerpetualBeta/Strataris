// Strataris — hidden feature flags.
//
// Off by default; opt in per machine with `defaults write`, e.g.
//   defaults write cc.jorviksoftware.Strataris ScreenshotOnSpace  -bool true   (F key)
// Read live (computed on each access), so toggling via `defaults write` takes
// effect on the next frame that reads the flag — no relaunch needed.

import Foundation

enum FeatureFlags {
    private static var d: UserDefaults { .standard }

    /// Enables the screen-capture control: the F key (keyboard) and a
    /// rebindable gamepad button. Space stays fire so keyboard-only players can
    /// still shoot. (Flag name is kept for back-compat with existing installs.)
    static var screenshotOnSpace: Bool { d.bool(forKey: "ScreenshotOnSpace") }

    // Perk test flags — force-unlock a level-gated perk from level 1, for
    // testing (a.k.a. cheating). Undocumented by design; the curious can find
    // them in the source (or via `strings` on the binary). Read live.
    static var forceAxisUnlock: Bool        { d.bool(forKey: "ForceAxisUnlock") }        // full 6DOF (L3)
    static var forceTargetingComputer: Bool { d.bool(forKey: "ForceTargetingComputer") } // auto-lock (L6)
    static var forceCloak: Bool             { d.bool(forKey: "ForceCloak") }             // cloak (L9)
    static var forceRadialPulse: Bool       { d.bool(forKey: "ForceRadialPulse") }       // pulse weapon (L12)

    /// Force the "May the fourth be with you" callout at every mission start,
    /// regardless of the date (for testing the date-gated Easter egg).
    ///   defaults write cc.jorviksoftware.Strataris ForceMayTheFourth -bool true
    static var forceMayTheFourth: Bool { d.bool(forKey: "ForceMayTheFourth") }
}
