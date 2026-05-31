// Strataris — controller settings sheet.
//
// Opened with C (or Controller… in the app menu). Shows the detected controller
// (live), a live input preview, and a rebindable mapping: click an action's
// button, then press any controller button/trigger to bind it. The left stick
// always steers/pitches. While open, Gamepad.configuring pauses the game.

import Cocoa

final class SettingsSheet: NSObject {
    private static var current: SettingsSheet?

    private let sheet: SheetWindow
    private let gamepad: Gamepad
    private weak var parent: NSWindow?
    private var timer: Timer?

    private let statusLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")

    // One bind button per action (aligned with PadAction.allCases by tag).
    private var bindButtons: [NSButton] = []

    // Capture state: the action awaiting a press, and whether all controls have
    // been released since capture began (so a held control doesn't auto-bind).
    private var captureAction: PadAction?
    private var captureArmed = false

    static func present(over window: NSWindow, gamepad: Gamepad) {
        guard current == nil else { return }
        let s = SettingsSheet(gamepad: gamepad, parent: window)
        current = s
        gamepad.configuring = true
        window.beginSheet(s.sheet) { _ in
            gamepad.configuring = false
            s.timer?.invalidate()
            current = nil
            window.makeFirstResponder(window.contentView)   // hand control back to the game
        }
        s.timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak s] _ in s?.refresh() }
        s.refresh()
    }

    private init(gamepad: Gamepad, parent: NSWindow) {
        self.gamepad = gamepad
        self.parent = parent
        sheet = SheetWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        sheet.onCancel = { [weak self] in self?.cancelOrClose() }
        buildUI()
    }

    private func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "CONTROLLER")
        title.font = mono(20, .bold)

        statusLabel.font = mono(12, .semibold)
        previewLabel.font = mono(13, .medium)

        let fixed = NSTextField(wrappingLabelWithString: "LEFT STICK     steer · pitch (up = dive)")
        fixed.font = mono(11)
        fixed.textColor = .secondaryLabelColor

        let bindHdr = NSTextField(labelWithString: "REBIND — click an action, then press a button")
        bindHdr.font = mono(11, .bold)
        bindHdr.textColor = .secondaryLabelColor

        // One row per rebindable action.
        var rows: [NSView] = []
        for (i, action) in PadAction.allCases.enumerated() {
            let label = NSTextField(labelWithString: action.title)
            label.font = mono(12)
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true

            let btn = NSButton(title: Gamepad.friendlyName(gamepad.binding(for: action)), target: self, action: #selector(beginCapture(_:)))
            btn.bezelStyle = .rounded
            btn.font = mono(12, .semibold)
            btn.tag = i
            btn.widthAnchor.constraint(equalToConstant: 150).isActive = true
            bindButtons.append(btn)

            let row = NSStackView(views: [label, btn])
            row.orientation = .horizontal
            row.spacing = 12
            rows.append(row)
        }

        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetBindings))
        reset.bezelStyle = .rounded
        reset.font = mono(11)

        let fireStart = NSButton(checkboxWithTitle: "Fire button also starts / restarts",
                                 target: self, action: #selector(fireToggled(_:)))
        fireStart.font = mono(12)
        fireStart.state = gamepad.fireConfirms ? .on : .off

        let hint = NSTextField(labelWithString: "Pitch invert & deadzone are in Settings (⌘,).  Keyboard always works.")
        hint.font = mono(10)
        hint.textColor = .tertiaryLabelColor

        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded

        var views: [NSView] = [title, statusLabel, previewLabel, separator(), fixed, bindHdr]
        views.append(contentsOf: rows)
        views.append(contentsOf: [reset, separator(), fireStart, hint, separator(), done])

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

    private func refresh() {
        if gamepad.connected {
            statusLabel.stringValue = "Detected:  \(gamepad.name)"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "No controller detected — keyboard active"
            statusLabel.textColor = .systemOrange
        }

        // Capture loop: arm once everything is released, then bind the next press.
        if let action = captureAction {
            if !captureArmed {
                if gamepad.capturedControl() == nil { captureArmed = true }
            } else if let control = gamepad.capturedControl() {
                gamepad.setBinding(control, for: action)
                captureAction = nil
                refreshBindTitles()
            }
        }

        var parts: [String] = []
        if gamepad.stickX < -0.3 { parts.append("◀") } else if gamepad.stickX > 0.3 { parts.append("▶") }
        if gamepad.stickY > 0.3 { parts.append("▲") } else if gamepad.stickY < -0.3 { parts.append("▼") }
        if gamepad.firing { parts.append("FIRE") }
        if gamepad.throttleUp { parts.append("THR+") }
        if gamepad.throttleDown { parts.append("THR−") }
        if gamepad.menu { parts.append("START") }
        if gamepad.warpHeld { parts.append("WARP") }
        previewLabel.stringValue = "INPUT:  " + (parts.isEmpty ? "—" : parts.joined(separator: "  "))
        previewLabel.textColor = parts.isEmpty ? .tertiaryLabelColor : .labelColor
    }

    private func refreshBindTitles() {
        for (i, action) in PadAction.allCases.enumerated() {
            bindButtons[i].title = (captureAction == action) ? "PRESS…" : Gamepad.friendlyName(gamepad.binding(for: action))
        }
    }

    @objc private func beginCapture(_ sender: NSButton) {
        guard sender.tag >= 0 && sender.tag < PadAction.allCases.count else { return }
        captureAction = PadAction.allCases[sender.tag]
        captureArmed = false
        refreshBindTitles()
    }

    @objc private func resetBindings() {
        captureAction = nil
        gamepad.resetBindings()
        refreshBindTitles()
    }

    @objc private func fireToggled(_ s: NSButton) { gamepad.fireConfirms = (s.state == .on) }

    /// Esc cancels an in-progress capture; otherwise it closes the sheet.
    private func cancelOrClose() {
        if captureAction != nil { captureAction = nil; refreshBindTitles() }
        else { done() }
    }

    @objc private func done() { if let p = parent { p.endSheet(sheet) } }
}
