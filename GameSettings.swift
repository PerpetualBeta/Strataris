// Strataris — persisted user settings.
//
// A thin, typed wrapper over UserDefaults: the single source of truth for the
// player's audio volumes and controller preferences. AudioEngine and Gamepad
// read these on launch; the options / controller sheets write them. Everything
// survives across sessions.

import Foundation

final class GameSettings {
    static let shared = GameSettings()

    private let d = UserDefaults.standard

    private enum Key {
        static let musicVolume = "musicVolume"
        static let sfxVolume   = "sfxVolume"
        static let voiceVolume = "voiceVolume"
        static let invertPitch = "invertPitch"
        static let deadzone    = "deadzone"
        static let fireConfirms = "fireConfirms"
        static let leftWarp    = "leftWarp"
    }

    private init() {
        d.register(defaults: [
            Key.musicVolume: 0.7,
            Key.sfxVolume:   0.9,
            Key.voiceVolume: 0.85,
            Key.invertPitch: false,
            Key.deadzone:    0.25,
            Key.fireConfirms: true,
            Key.leftWarp:    true,
        ])
    }

    // Audio — linear gains in 0...1.
    var musicVolume: Float { get { d.float(forKey: Key.musicVolume) } set { d.set(newValue, forKey: Key.musicVolume) } }
    var sfxVolume: Float   { get { d.float(forKey: Key.sfxVolume) }   set { d.set(newValue, forKey: Key.sfxVolume) } }
    var voiceVolume: Float { get { d.float(forKey: Key.voiceVolume) } set { d.set(newValue, forKey: Key.voiceVolume) } }

    // Controls.
    var invertPitch: Bool  { get { d.bool(forKey: Key.invertPitch) }  set { d.set(newValue, forKey: Key.invertPitch) } }
    var deadzone: Float    { get { d.float(forKey: Key.deadzone) }    set { d.set(newValue, forKey: Key.deadzone) } }
    var fireConfirms: Bool { get { d.bool(forKey: Key.fireConfirms) } set { d.set(newValue, forKey: Key.fireConfirms) } }
    var leftWarp: Bool     { get { d.bool(forKey: Key.leftWarp) }     set { d.set(newValue, forKey: Key.leftWarp) } }
}
