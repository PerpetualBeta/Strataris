// Strataris — controller settings sheet.
//
// Opened with C. Shows the detected controller (live), a live input preview so
// you can confirm it's working, the control mapping, an invert-pitch toggle and
// a deadzone slider. While open, Gamepad.configuring pauses the game.

import Cocoa

final class SettingsSheet: NSObject {
    private static var current: SettingsSheet?

    private let sheet: NSWindow
    private let gamepad: Gamepad
    private weak var parent: NSWindow?
    private var timer: Timer?

    private let statusLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")

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
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
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

        let mapping = NSTextField(wrappingLabelWithString: """
        LEFT STICK     steer  ·  pitch (up = dive)
        A  /  RT       fire
        LB  /  RB      throttle −  /  +
        MENU           pause  ·  start / restart

        Keyboard always works too.
        """)
        mapping.font = mono(11)
        mapping.textColor = .secondaryLabelColor

        let invert = NSButton(checkboxWithTitle: "Invert pitch (up = climb)",
                              target: self, action: #selector(invertToggled(_:)))
        invert.font = mono(12)
        invert.state = gamepad.invertPitch ? .on : .off

        let fireStart = NSButton(checkboxWithTitle: "Fire button starts / restarts",
                                 target: self, action: #selector(fireToggled(_:)))
        fireStart.font = mono(12)
        fireStart.state = gamepad.fireConfirms ? .on : .off

        let leftWarp = NSButton(checkboxWithTitle: "Left trigger warps",
                                target: self, action: #selector(leftWarpToggled(_:)))
        leftWarp.font = mono(12)
        leftWarp.state = gamepad.leftWarp ? .on : .off

        let dzLabel = NSTextField(labelWithString: "Stick deadzone")
        dzLabel.font = mono(12)
        let dz = NSSlider(value: Double(gamepad.deadzone), minValue: 0.05, maxValue: 0.5,
                          target: self, action: #selector(deadzoneChanged(_:)))
        dz.controlSize = .small
        dz.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let dzRow = NSStackView(views: [dzLabel, dz])
        dzRow.orientation = .horizontal
        dzRow.spacing = 12

        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded

        let stack = NSStackView(views: [title, statusLabel, previewLabel,
                                        separator(), mapping, separator(),
                                        invert, fireStart, leftWarp, dzRow, separator(), done])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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
        b.widthAnchor.constraint(equalToConstant: 392).isActive = true
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
        var parts: [String] = []
        if gamepad.stickX < -0.3 { parts.append("◀") } else if gamepad.stickX > 0.3 { parts.append("▶") }
        if gamepad.stickY > 0.3 { parts.append("▲") } else if gamepad.stickY < -0.3 { parts.append("▼") }
        if gamepad.firing { parts.append("FIRE") }
        if gamepad.throttleUp { parts.append("THR+") }
        if gamepad.throttleDown { parts.append("THR−") }
        if gamepad.menu { parts.append("MENU") }
        previewLabel.stringValue = "INPUT:  " + (parts.isEmpty ? "—" : parts.joined(separator: "  "))
        previewLabel.textColor = parts.isEmpty ? .tertiaryLabelColor : .labelColor
    }

    @objc private func invertToggled(_ s: NSButton) { gamepad.invertPitch = (s.state == .on) }
    @objc private func fireToggled(_ s: NSButton) { gamepad.fireConfirms = (s.state == .on) }
    @objc private func leftWarpToggled(_ s: NSButton) { gamepad.leftWarp = (s.state == .on) }
    @objc private func deadzoneChanged(_ s: NSSlider) { gamepad.deadzone = Float(s.doubleValue) }
    @objc private func done() { if let p = parent { p.endSheet(sheet) } }
}
