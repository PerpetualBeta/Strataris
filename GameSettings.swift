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
        static let musicVolume   = "musicVolume"
        static let sfxVolume     = "sfxVolume"
        static let voiceVolume   = "voiceVolume"
        static let ambientVolume = "ambientVolume"
        static let invertPitch = "invertPitch"
        static let deadzone    = "deadzone"
        static let fireConfirms = "fireConfirms"
        static let leftWarp    = "leftWarp"
        static let padBindings = "padBindings"
        static let keyBindings = "keyBindings"
        static let trimAgility   = "trimAgility"
        static let trimYaw       = "trimYaw"
        static let trimAutoLevel = "trimAutoLevel"
    }

    private init() {
        d.register(defaults: [
            Key.musicVolume:   0.7,
            Key.sfxVolume:     0.9,
            Key.voiceVolume:   0.85,
            Key.ambientVolume: 0.8,
            Key.invertPitch: false,
            Key.deadzone:    0.25,
            Key.fireConfirms: true,
            Key.leftWarp:    true,
            Key.trimAgility:   1.0,
            Key.trimYaw:       1.0,
            Key.trimAutoLevel: 1.0,
        ])
    }

    // Audio — linear gains in 0...1.
    var musicVolume: Float   { get { d.float(forKey: Key.musicVolume) }   set { d.set(newValue, forKey: Key.musicVolume) } }
    var sfxVolume: Float     { get { d.float(forKey: Key.sfxVolume) }     set { d.set(newValue, forKey: Key.sfxVolume) } }
    var voiceVolume: Float   { get { d.float(forKey: Key.voiceVolume) }   set { d.set(newValue, forKey: Key.voiceVolume) } }
    var ambientVolume: Float { get { d.float(forKey: Key.ambientVolume) } set { d.set(newValue, forKey: Key.ambientVolume) } }

    // Controls.
    var invertPitch: Bool  { get { d.bool(forKey: Key.invertPitch) }  set { d.set(newValue, forKey: Key.invertPitch) } }
    var deadzone: Float    { get { d.float(forKey: Key.deadzone) }    set { d.set(newValue, forKey: Key.deadzone) } }
    var fireConfirms: Bool { get { d.bool(forKey: Key.fireConfirms) } set { d.set(newValue, forKey: Key.fireConfirms) } }
    var leftWarp: Bool     { get { d.bool(forKey: Key.leftWarp) }     set { d.set(newValue, forKey: Key.leftWarp) } }

    // Flight envelope trim — multipliers on the 6DOF handling rates (1 = the
    // tuned defaults). Agility scales pitch/roll, yaw scales the full-envelope
    // yaw axis, autoLevel scales the hands-off recovery (0 = hold attitude).
    var trimAgility: Float   { get { d.float(forKey: Key.trimAgility) }   set { d.set(newValue, forKey: Key.trimAgility) } }
    var trimYaw: Float       { get { d.float(forKey: Key.trimYaw) }       set { d.set(newValue, forKey: Key.trimYaw) } }
    var trimAutoLevel: Float { get { d.float(forKey: Key.trimAutoLevel) } set { d.set(newValue, forKey: Key.trimAutoLevel) } }

    // Controller button rebinds: [PadAction.rawValue: control name]. Empty until
    // the player changes something; Gamepad falls back to per-action defaults.
    var padBindings: [String: String] {
        get { d.dictionary(forKey: Key.padBindings) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: Key.padBindings) }
    }

    // Keyboard rebinds: [KeyAction.rawValue: virtual key code]. Empty until the
    // player changes something; KeyBindings falls back to per-action defaults.
    var keyBindings: [String: Int] {
        get { d.dictionary(forKey: Key.keyBindings) as? [String: Int] ?? [:] }
        set { d.set(newValue, forKey: Key.keyBindings) }
    }
}
