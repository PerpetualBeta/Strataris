// Strataris — keyboard settings sheet.
//
// Opened with K (or Keyboard… in the app menu). The keyboard mirror of the
// controller sheet: every flight/combat action maps to a key, edited by
// clicking an action's button then pressing the new key. Menu/system keys
// (pause, mute, briefing, codex, restart, Esc, the sheet openers) stay fixed
// and can't be bound over. While open, Gamepad.configuring pauses the game.

import Cocoa
import Carbon.HIToolbox   // kVK_* virtual key-code constants

/// A rebindable keyboard action. Raw values are the persistence keys.
enum KeyAction: String, CaseIterable {
    case bankLeft, bankRight, pitchForward, pitchBack, yawLeft, yawRight
    case fire, throttleUp, throttleDown, pulse, cloak, screenshot

    var title: String {
        switch self {
        case .bankLeft:     return "STEER LEFT"
        case .bankRight:    return "STEER RIGHT"
        case .pitchForward: return "PITCH (STICK FWD)"
        case .pitchBack:    return "PITCH (STICK BACK)"
        case .yawLeft:      return "YAW LEFT"
        case .yawRight:     return "YAW RIGHT"
        case .fire:         return "FIRE"
        case .throttleUp:   return "THROTTLE +"
        case .throttleDown: return "THROTTLE -"
        case .pulse:        return "RADIAL PULSE"
        case .cloak:        return "CLOAK"
        case .screenshot:   return "SCREENSHOT"
        }
    }

    /// Factory-default key for this action (the original hardcoded map).
    var defaultKey: Int {
        switch self {
        case .bankLeft:     return kVK_LeftArrow
        case .bankRight:    return kVK_RightArrow
        case .pitchForward: return kVK_UpArrow
        case .pitchBack:    return kVK_DownArrow
        case .yawLeft:      return kVK_ANSI_A
        case .yawRight:     return kVK_ANSI_D
        case .fire:         return kVK_Space
        case .throttleUp:   return kVK_ANSI_Equal
        case .throttleDown: return kVK_ANSI_Minus
        case .pulse:        return kVK_ANSI_X
        case .cloak:        return kVK_ANSI_Z
        case .screenshot:   return kVK_ANSI_F
        }
    }

    /// The actions shown in the sheet and routed each key event. Yaw only does
    /// anything in full 6DOF, pulse/cloak after their unlock levels — they're
    /// always bindable. Screenshot stays behind its feature flag.
    static var activeCases: [KeyAction] {
        var cases: [KeyAction] = [.bankLeft, .bankRight, .pitchForward, .pitchBack,
                                  .yawLeft, .yawRight, .fire, .throttleUp, .throttleDown,
                                  .pulse, .cloak]
        if FeatureFlags.screenshotOnSpace { cases.append(.screenshot) }
        return cases
    }
}

/// The live keyboard map: per-action overrides on top of the defaults,
/// persisted via GameSettings, with a reverse (keyCode → action) index that
/// GameView consults on every key event.
final class KeyBindings {
    static let shared = KeyBindings()

    private var overrides: [String: Int]
    private var reverse: [Int: KeyAction] = [:]

    private init() {
        overrides = GameSettings.shared.keyBindings
        rebuildReverse()
    }

    func binding(for action: KeyAction) -> Int { overrides[action.rawValue] ?? action.defaultKey }
    func action(for keyCode: Int) -> KeyAction? { reverse[keyCode] }

    /// Bind `keyCode` to `action`. If another action already owns that key the
    /// two SWAP, so every action always keeps a key (no silent unbinding).
    func setBinding(_ keyCode: Int, for action: KeyAction) {
        if let other = reverse[keyCode], other != action {
            overrides[other.rawValue] = binding(for: action)
        }
        overrides[action.rawValue] = keyCode
        persist()
    }

    func resetBindings() {
        overrides = [:]
        persist()
    }

    private func persist() {
        GameSettings.shared.keyBindings = overrides
        rebuildReverse()
    }

    private func rebuildReverse() {
        reverse = [:]
        for a in KeyAction.activeCases { reverse[binding(for: a)] = a }
    }

    /// Keys with fixed game/menu functions — refused during capture.
    static let reserved: Set<Int> = [kVK_ANSI_P, kVK_ANSI_M, kVK_ANSI_B, kVK_ANSI_V,
                                     kVK_ANSI_R, kVK_Return, kVK_ANSI_KeypadEnter,
                                     kVK_Escape, kVK_ANSI_C, kVK_ANSI_K]

    /// Display name for a virtual key code (the common bindable keys).
    static func friendlyName(_ keyCode: Int) -> String {
        switch keyCode {
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        case kVK_Space:      return "SPACE"
        case kVK_Tab:        return "TAB"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_KeypadPlus:  return "PAD +"
        case kVK_ANSI_KeypadMinus: return "PAD -"
        case kVK_ANSI_Comma:        return ","
        case kVK_ANSI_Period:       return "."
        case kVK_ANSI_Slash:        return "/"
        case kVK_ANSI_Semicolon:    return ";"
        case kVK_ANSI_Quote:        return "'"
        case kVK_ANSI_LeftBracket:  return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash:    return "\\"
        case kVK_ANSI_Grave:        return "`"
        default: break
        }
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        ]
        return letters[keyCode] ?? "KEY \(keyCode)"
    }
}

final class KeyboardSheet: NSObject {
    private static var current: KeyboardSheet?

    private let sheet: SheetWindow
    private let gamepad: Gamepad
    private weak var parent: NSWindow?
    private var keyMonitor: Any?

    // One bind button per action (aligned with KeyAction.activeCases by tag).
    private var bindButtons: [NSButton] = []
    private var captureAction: KeyAction?

    static func present(over window: NSWindow, gamepad: Gamepad) {
        guard current == nil else { return }
        let s = KeyboardSheet(gamepad: gamepad, parent: window)
        current = s
        gamepad.configuring = true             // reuse the pause-while-configuring path
        window.beginSheet(s.sheet) { _ in
            gamepad.configuring = false
            if let m = s.keyMonitor { NSEvent.removeMonitor(m) }
            current = nil
            window.makeFirstResponder(window.contentView)   // hand control back to the game
        }
        // Capture the next key press for the awaiting action; everything else
        // flows on to the sheet (Esc closes, Return = Done).
        s.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak s] ev in
            guard let s, let action = s.captureAction else { return ev }
            let code = Int(ev.keyCode)
            if code == kVK_Escape {
                s.captureAction = nil          // Esc cancels the capture
            } else if KeyBindings.reserved.contains(code) {
                NSSound.beep()                 // fixed-function key — keep waiting
                return nil
            } else {
                KeyBindings.shared.setBinding(code, for: action)
                s.captureAction = nil
            }
            s.refreshBindTitles()
            return nil
        }
    }

    private init(gamepad: Gamepad, parent: NSWindow) {
        self.gamepad = gamepad
        self.parent = parent
        sheet = SheetWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        sheet.onCancel = { [weak self] in self?.cancelOrClose() }
        buildUI()
    }

    private func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "KEYBOARD")
        title.font = mono(20, .bold)

        let bindHdr = NSTextField(labelWithString: "REBIND — click an action, then press a key")
        bindHdr.font = mono(11, .bold)
        bindHdr.textColor = .secondaryLabelColor

        var rows: [NSView] = []
        for (i, action) in KeyAction.activeCases.enumerated() {
            let label = NSTextField(labelWithString: action.title)
            label.font = mono(12)
            label.widthAnchor.constraint(equalToConstant: 170).isActive = true

            let btn = NSButton(title: KeyBindings.friendlyName(KeyBindings.shared.binding(for: action)),
                               target: self, action: #selector(beginCapture(_:)))
            btn.bezelStyle = .rounded
            btn.font = mono(12, .semibold)
            btn.tag = i
            btn.widthAnchor.constraint(equalToConstant: 130).isActive = true
            bindButtons.append(btn)

            let row = NSStackView(views: [label, btn])
            row.orientation = .horizontal
            row.spacing = 12
            rows.append(row)
        }

        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetBindings))
        reset.bezelStyle = .rounded
        reset.font = mono(11)

        let hint = NSTextField(wrappingLabelWithString:
            "Binding a key already in use swaps the two actions. Fixed keys: P pause · M mute · B briefing · V codex · R/Return restart & warp · Esc back · C controller · K keyboard. Pitch honours the Invert-pitch setting (⌘,).")
        hint.font = mono(10)
        hint.textColor = .tertiaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 412).isActive = true

        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded

        var views: [NSView] = [title, bindHdr]
        views.append(contentsOf: rows)
        views.append(contentsOf: [reset, separator(), hint, separator(), done])

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        sheet.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
        ])
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 412).isActive = true
        return b
    }

    private func refreshBindTitles() {
        for (i, action) in KeyAction.activeCases.enumerated() {
            bindButtons[i].title = (captureAction == action)
                ? "PRESS…"
                : KeyBindings.friendlyName(KeyBindings.shared.binding(for: action))
        }
    }

    @objc private func beginCapture(_ sender: NSButton) {
        let cases = KeyAction.activeCases
        guard sender.tag >= 0 && sender.tag < cases.count else { return }
        captureAction = cases[sender.tag]
        refreshBindTitles()
    }

    @objc private func resetBindings() {
        captureAction = nil
        KeyBindings.shared.resetBindings()
        refreshBindTitles()
    }

    /// Esc cancels an in-progress capture (handled by the monitor); otherwise
    /// it closes the sheet.
    private func cancelOrClose() {
        if captureAction != nil { captureAction = nil; refreshBindTitles() }
        else { done() }
    }

    @objc private func done() { if let p = parent { p.endSheet(sheet) } }
}
