// Strataris — input state.
//
// Two independent sources — keyboard (`kb`, set by the view on key events) and
// gamepad (`gp`, refreshed each frame by Gamepad.poll). The game reads the
// effective flags, which are simply the OR of the two, so either device works
// and neither clobbers the other on release.

import Foundation

final class InputState {
    struct Controls {
        var bankLeft = false, bankRight = false
        var climb = false, dive = false
        var faster = false, slower = false
        var fire = false
        var pause = false, restart = false, mute = false
        var warp = false       // advance on the PLANET CLEARED screen (kept separate from fire)
        var briefing = false   // open/close the mission-briefing screen from the title
        var codex = false      // open/close the enemy-craft codex from the title
        var back = false       // Esc — close/return (backs out of briefing/codex to title)
        var screenshot = false // feature flag: spacebar grabs a screenshot
        var pulse = false      // feature flag: radial pulse weapon (X)
    }

    var kb = Controls()      // keyboard source (view writes)
    var gp = Controls()      // gamepad source (Gamepad.poll writes)

    // Effective inputs read by the game.
    var bankLeft: Bool  { kb.bankLeft  || gp.bankLeft }
    var bankRight: Bool { kb.bankRight || gp.bankRight }
    var climb: Bool     { kb.climb     || gp.climb }
    var dive: Bool      { kb.dive      || gp.dive }
    var faster: Bool    { kb.faster    || gp.faster }
    var slower: Bool    { kb.slower    || gp.slower }
    var fire: Bool      { kb.fire      || gp.fire }
    var pause: Bool     { kb.pause     || gp.pause }
    var restart: Bool   { kb.restart   || gp.restart }
    var mute: Bool      { kb.mute      || gp.mute }
    var warp: Bool      { kb.warp      || gp.warp }
    var briefing: Bool  { kb.briefing  || gp.briefing }
    var codex: Bool     { kb.codex     || gp.codex }
    var back: Bool      { kb.back      || gp.back }
    var screenshot: Bool { kb.screenshot }   // keyboard only
    var pulse: Bool     { kb.pulse }          // keyboard only

    // High-score name entry (keyboard only).
    var nameEntryActive = false
    var nameBuffer = ""
    var nameCommitted = false

    /// Clear held flight/fire flags so a fresh game never starts mid-turn or
    /// auto-firing because a key/stick was held through death/restart.
    func resetControls() {
        kb = Controls()
        gp = Controls()
    }
}
