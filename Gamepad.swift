// Strataris — gamepad input (Xbox / DualShock / any extended controller).
//
// Polled once per frame; reads the connected controller's extended gamepad and
// writes the gamepad source of InputState (OR'd with the keyboard). Options
// (invert pitch, deadzone) are tweakable from the settings sheet.

import GameController

final class Gamepad {
    private(set) var connected = false
    private(set) var name = "—"
    var invertPitch = false
    var deadzone: Float = 0.25
    var fireConfirms = true        // fire button also starts / restarts on menus
    var leftWarp = true            // left trigger warps on the PLANET CLEARED screen
    var configuring = false        // true while the settings sheet is open (pauses the game)

    // Live state for the settings sheet's input preview.
    private(set) var stickX: Float = 0, stickY: Float = 0
    private(set) var firing = false, throttleUp = false, throttleDown = false, menu = false, warpHeld = false

    init() {
        // Wake up wireless pads that aren't already reporting.
        GCController.startWirelessControllerDiscovery(completionHandler: {})
    }

    private var pad: GCExtendedGamepad? {
        GCController.controllers().first?.extendedGamepad
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

        firing = gp.rightTrigger.value > 0.3 || gp.buttonA.isPressed
        throttleUp = gp.rightShoulder.isPressed
        throttleDown = gp.leftShoulder.isPressed
        menu = gp.buttonMenu.isPressed
        warpHeld = gp.leftTrigger.value > 0.3

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
        if menu { c.pause = true; c.restart = true }   // Menu pauses / confirms menus
        if fireConfirms && firing { c.restart = true } // fire starts / restarts (optional)
        if leftWarp && warpHeld { c.warp = true }      // left trigger warps (optional)
        input.gp = c
    }
}
