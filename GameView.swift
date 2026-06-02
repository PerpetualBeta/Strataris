// Strataris — the game view.
//
// An MTKView that captures keyboard input into the keyboard source of the
// shared InputState. Held keys flip flags; we swallow the keys we handle so
// macOS doesn't play the "unhandled key" funk sound. Pressing C opens the
// controller settings sheet.

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
        if !set(keyCode: Int(event.keyCode), down: true) {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if input.nameEntryActive { return }
        if !set(keyCode: Int(event.keyCode), down: false) {
            super.keyUp(with: event)
        }
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
        switch keyCode {
        case kVK_LeftArrow:                 input.kb.bankLeft = down
        case kVK_RightArrow:                input.kb.bankRight = down
        // Pitch honours the Invert-pitch setting (shared with the gamepad). Default
        // (off) is flight-stick sense: ↑ = nose down / descend, ↓ = nose up / climb.
        // Inverted swaps them so ↑ = climb. Map at key time so the toggle applies
        // live without restarting.
        case kVK_UpArrow:   if gamepad.invertPitch { input.kb.dive = down }  else { input.kb.climb = down }
        case kVK_DownArrow: if gamepad.invertPitch { input.kb.climb = down } else { input.kb.dive = down }
        case kVK_Space:                     input.kb.fire = down    // Space is always fire
        case kVK_ANSI_A:                    input.kb.yawLeft = down  // yaw — full 6DOF (level-3 Axis Unlock)
        case kVK_ANSI_D:                    input.kb.yawRight = down
        case kVK_ANSI_F:
            // Feature flag: F grabs a screenshot. On its own key (not Space) so
            // keyboard-only players can still fire. Gamepad uses its own binding.
            guard FeatureFlags.screenshotOnSpace else { return false }
            input.kb.screenshot = down
        case kVK_ANSI_X:                    input.kb.pulse = down   // perk: radial pulse (level 12)
        case kVK_ANSI_Z:                    input.kb.cloak = down   // perk: cloak (level 9)
        case kVK_ANSI_R, kVK_Return, kVK_ANSI_KeypadEnter:
            input.kb.restart = down
            input.kb.warp = down            // keyboard advances both restart and warp screens
        case kVK_ANSI_P:                    input.kb.pause = down
        case kVK_ANSI_M:                    input.kb.mute = down
        case kVK_ANSI_B:                    input.kb.briefing = down
        case kVK_ANSI_V:                    input.kb.codex = down
        case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus:
            input.kb.faster = down
        case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus:
            input.kb.slower = down
        case kVK_ANSI_C:
            if down, !gamepad.configuring, let win = window {
                SettingsSheet.present(over: win, gamepad: gamepad)
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
}
