// Strataris — the game view.
//
// An MTKView that captures keyboard input into the keyboard source of the
// shared InputState. Held keys flip flags; we swallow the keys we handle so
// macOS doesn't play the "unhandled key" funk sound. Flight/combat keys are
// player-rebindable (KeyBindings); menu/system keys are fixed. Pressing C
// opens the controller settings sheet, K the keyboard one.

import MetalKit
import Carbon.HIToolbox   // kVK_* virtual key-code constants

final class GameView: MTKView {
    let input: InputState
    let gamepad: Gamepad

    init(frame: CGRect, device: MTLDevice, input: InputState, gamepad: Gamepad) {
        self.input = input
        self.gamepad = gamepad
        super.init(frame: frame, device: device)
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColorMake(0, 0, 0, 1)   // letterbox bars
        self.preferredFramesPerSecond = 60
        self.isPaused = false
        self.enableSetNeedsDisplay = false   // continuous animation, driven by the internal timer
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // While entering a high-score name, route everything through the text
        // input system so accents, IME, and the emoji viewer all work.
        if input.nameEntryActive {
            interpretKeyEvents([event])
            return
        }
        // Swallow even unhandled keys: passing them to super plays the system
        // "funk" alert over the title music. Menu key-equivalents (⌘Q etc.)
        // are dispatched before keyDown, so nothing real is lost.
        _ = set(keyCode: Int(event.keyCode), down: true)
    }

    override func keyUp(with event: NSEvent) {
        if input.nameEntryActive { return }
        _ = set(keyCode: Int(event.keyCode), down: false)
    }

    // MARK: Text input (high-score name entry)

    override func insertText(_ insertString: Any) {
        guard input.nameEntryActive else { return }
        let s = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        var buf = input.nameBuffer + s
        if buf.count > 32 { buf = String(buf.prefix(32)) }   // 32 grapheme clusters (emoji = 1)
        input.nameBuffer = buf
    }

    override func deleteBackward(_ sender: Any?) {
        guard input.nameEntryActive else { return }
        if !input.nameBuffer.isEmpty { input.nameBuffer.removeLast() }
    }

    override func insertNewline(_ sender: Any?) {
        guard input.nameEntryActive else { return }
        input.nameCommitted = true
    }

    /// Returns true if we consumed the key. Writes the KEYBOARD source.
    private func set(keyCode: Int, down: Bool) -> Bool {
        // Rebindable flight/combat actions first — the player-configured map
        // (Keyboard… sheet, K). Bound keys always win over the fixed fallbacks.
        if let action = KeyBindings.shared.action(for: keyCode) {
            apply(action, down: down)
            return true
        }
        switch keyCode {
        case kVK_ANSI_R, kVK_Return, kVK_ANSI_KeypadEnter:
            input.kb.restart = down
            input.kb.warp = down            // keyboard advances both restart and warp screens
        case kVK_ANSI_P:                    input.kb.pause = down
        case kVK_ANSI_M:                    input.kb.mute = down
        case kVK_ANSI_B:                    input.kb.briefing = down
        case kVK_ANSI_V:                    input.kb.codex = down
        // Keypad aliases for throttle stay live unless the player binds the
        // keypad keys to something else (bound keys are consumed above).
        case kVK_ANSI_KeypadPlus:           input.kb.faster = down
        case kVK_ANSI_KeypadMinus:          input.kb.slower = down
        case kVK_ANSI_C:
            if down, !gamepad.configuring, let win = window {
                SettingsSheet.present(over: win, gamepad: gamepad)
            }
        case kVK_ANSI_K:
            if down, !gamepad.configuring, let win = window {
                KeyboardSheet.present(over: win, gamepad: gamepad)
            }
        case kVK_Escape:
            // Esc backs out (closes the briefing/codex screens → title). It no
            // longer quits — that's ⌘Q, the macOS standard, via the menu.
            input.kb.back = down
        default:
            return false
        }
        return true
    }

    /// Apply a rebindable action to the keyboard input source.
    private func apply(_ action: KeyAction, down: Bool) {
        switch action {
        case .bankLeft:  input.kb.bankLeft = down
        case .bankRight: input.kb.bankRight = down
        // Pitch honours the Invert-pitch setting (shared with the gamepad).
        // Default (off) is flight-stick sense: stick-forward = nose down /
        // descend, stick-back = nose up / climb. Inverted swaps them. Applied
        // at key time so the toggle takes effect live.
        case .pitchForward: if gamepad.invertPitch { input.kb.dive = down }  else { input.kb.climb = down }
        case .pitchBack:    if gamepad.invertPitch { input.kb.climb = down } else { input.kb.dive = down }
        case .yawLeft:   input.kb.yawLeft = down    // yaw — full 6DOF (level-3 Axis Unlock)
        case .yawRight:  input.kb.yawRight = down
        case .fire:      input.kb.fire = down
        case .throttleUp:   input.kb.faster = down
        case .throttleDown: input.kb.slower = down
        case .pulse:     input.kb.pulse = down      // perk: radial pulse (level 12)
        case .cloak:     input.kb.cloak = down      // perk: cloak (level 9)
        case .screenshot: input.kb.screenshot = down   // flag-gated (not active otherwise)
        }
    }
}
