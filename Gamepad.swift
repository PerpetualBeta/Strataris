// Strataris — gamepad input (Xbox / DualShock / any extended controller).
//
// Polled once per frame; reads the connected controller's extended gamepad and
// writes the gamepad source of InputState (OR'd with the keyboard). The left
// stick always steers/pitches; the discrete actions (fire, throttle, pause,
// warp) are rebindable to any button/trigger from the controller sheet and
// persisted via GameSettings. Invert pitch / deadzone live in the options sheet.

import GameController

/// A rebindable discrete control. Steering stays on the left stick (not bound).
enum PadAction: String, CaseIterable {
    case fire, throttleUp, throttleDown, pause, warp

    var title: String {
        switch self {
        case .fire:         return "FIRE"
        case .throttleUp:   return "THROTTLE +"
        case .throttleDown: return "THROTTLE -"
        case .pause:        return "PAUSE / START"
        case .warp:         return "WARP"
        }
    }

    /// Factory-default control for this action.
    var defaultControl: String {
        switch self {
        case .fire:         return "RT"
        case .throttleUp:   return "RB"
        case .throttleDown: return "LB"
        case .pause:        return "MENU"
        case .warp:         return "LT"
        }
    }
}

final class Gamepad {
    private(set) var connected = false
    private(set) var name = "—"
    // Player preferences — persisted via GameSettings so they survive launches.
    // invert/deadzone are edited in the options sheet. didSet doesn't fire for
    // the initial value, so reading from settings here doesn't write back.
    var invertPitch = GameSettings.shared.invertPitch  { didSet { GameSettings.shared.invertPitch = invertPitch } }
    var deadzone: Float = GameSettings.shared.deadzone  { didSet { GameSettings.shared.deadzone = deadzone } }
    var fireConfirms = GameSettings.shared.fireConfirms { didSet { GameSettings.shared.fireConfirms = fireConfirms } }
    var configuring = false        // true while a settings sheet is open (pauses the game)

    // Action → control-name bindings (loaded from GameSettings, defaulted).
    private(set) var bindings: [PadAction: String] = [:]

    // Live state for the settings sheet's input preview.
    private(set) var stickX: Float = 0, stickY: Float = 0
    private(set) var firing = false, throttleUp = false, throttleDown = false, menu = false, warpHeld = false

    // Bindable controls and how to read each one from a GCExtendedGamepad.
    // Order is the pick list shown when capturing a new binding.
    static let bindableControls = ["A", "B", "X", "Y", "LB", "RB", "LT", "RT",
                                   "MENU", "OPTIONS", "L3", "R3",
                                   "DPAD-UP", "DPAD-DOWN", "DPAD-LEFT", "DPAD-RIGHT"]

    static func controlValue(_ name: String, _ gp: GCExtendedGamepad) -> Float {
        switch name {
        case "A":          return gp.buttonA.value
        case "B":          return gp.buttonB.value
        case "X":          return gp.buttonX.value
        case "Y":          return gp.buttonY.value
        case "LB":         return gp.leftShoulder.value
        case "RB":         return gp.rightShoulder.value
        case "LT":         return gp.leftTrigger.value
        case "RT":         return gp.rightTrigger.value
        case "MENU":       return gp.buttonMenu.value
        case "OPTIONS":    return gp.buttonOptions?.value ?? 0
        case "L3":         return gp.leftThumbstickButton?.value ?? 0
        case "R3":         return gp.rightThumbstickButton?.value ?? 0
        case "DPAD-UP":    return gp.dpad.up.value
        case "DPAD-DOWN":  return gp.dpad.down.value
        case "DPAD-LEFT":  return gp.dpad.left.value
        case "DPAD-RIGHT": return gp.dpad.right.value
        default:           return 0
        }
    }

    init() {
        var b: [PadAction: String] = [:]
        let saved = GameSettings.shared.padBindings
        for a in PadAction.allCases { b[a] = saved[a.rawValue] ?? a.defaultControl }
        bindings = b
        // Wake up wireless pads that aren't already reporting.
        GCController.startWirelessControllerDiscovery(completionHandler: {})
    }

    // MARK: Bindings

    func binding(for a: PadAction) -> String { bindings[a] ?? a.defaultControl }

    func setBinding(_ control: String, for a: PadAction) {
        bindings[a] = control
        persistBindings()
    }

    func resetBindings() {
        for a in PadAction.allCases { bindings[a] = a.defaultControl }
        persistBindings()
    }

    private func persistBindings() {
        var d: [String: String] = [:]
        for (a, c) in bindings { d[a.rawValue] = c }
        GameSettings.shared.padBindings = d
    }

    /// The first bindable control currently pressed (for the sheet's capture
    /// mode). Returns nil if nothing is held.
    func capturedControl() -> String? {
        guard let gp = pad else { return nil }
        for c in Gamepad.bindableControls where Gamepad.controlValue(c, gp) > 0.6 { return c }
        return nil
    }

    private var pad: GCExtendedGamepad? {
        GCController.controllers().first?.extendedGamepad
    }

    private func down(_ a: PadAction, _ gp: GCExtendedGamepad) -> Bool {
        Gamepad.controlValue(binding(for: a), gp) > 0.4
    }

    /// Refresh `input.gp` from the controller (call once per frame).
    func poll(_ input: InputState) {
        guard let gc = GCController.controllers().first, let gp = gc.extendedGamepad else {
            connected = false
            name = "—"
            input.gp = .init()
            stickX = 0; stickY = 0; firing = false; throttleUp = false; throttleDown = false
            menu = false; warpHeld = false
            return
        }
        connected = true
        name = gc.vendorName ?? "Controller"

        let lx = gp.leftThumbstick.xAxis.value
        let ly = gp.leftThumbstick.yAxis.value
        stickX = lx; stickY = ly

        firing = down(.fire, gp)
        throttleUp = down(.throttleUp, gp)
        throttleDown = down(.throttleDown, gp)
        menu = down(.pause, gp)
        warpHeld = down(.warp, gp)

        var c = InputState.Controls()
        if lx < -deadzone { c.bankLeft = true }
        if lx >  deadzone { c.bankRight = true }
        // Up on the stick matches the Up-arrow (nose down) unless inverted.
        let py = invertPitch ? -ly : ly
        if py >  deadzone { c.climb = true }
        if py < -deadzone { c.dive = true }
        if firing { c.fire = true }
        if throttleUp { c.faster = true }
        if throttleDown { c.slower = true }
        if menu { c.pause = true; c.restart = true }   // pause / start / confirm menus
        if fireConfirms && firing { c.restart = true } // fire also starts / restarts (optional)
        if warpHeld { c.warp = true }
        input.gp = c
    }
}
