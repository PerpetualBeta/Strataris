// Strataris — options / settings sheet (⌘,).
//
// The single place for player preferences: audio volumes (Music / SFX / Voice /
// Ambient),
// flight controls (invert pitch, stick deadzone), and a Reset High Scores
// action. Changes apply live and persist via GameSettings. Native AppKit (no
// SwiftUI) to keep the game's tiny, all-procedural footprint. While open the
// game is paused (reusing Gamepad.configuring). Esc or Done closes it.

import Cocoa

/// An NSWindow that closes (cancels) on Esc — used for the modal sheets.
final class SheetWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class OptionsSheet: NSObject {
    private static var current: OptionsSheet?

    private let sheet: SheetWindow
    private let audio: AudioEngine
    private let gamepad: Gamepad
    private let highScores: HighScores
    private weak var parent: NSWindow?

    private let musicValue = NSTextField(labelWithString: "")
    private let sfxValue = NSTextField(labelWithString: "")
    private let voiceValue = NSTextField(labelWithString: "")
    private let ambientValue = NSTextField(labelWithString: "")

    static func present(over window: NSWindow, audio: AudioEngine, gamepad: Gamepad, highScores: HighScores) {
        guard current == nil else { return }
        let s = OptionsSheet(audio: audio, gamepad: gamepad, highScores: highScores, parent: window)
        current = s
        gamepad.configuring = true
        window.beginSheet(s.sheet) { _ in
            gamepad.configuring = false
            current = nil
            window.makeFirstResponder(window.contentView)   // hand control back to the game
        }
    }

    private init(audio: AudioEngine, gamepad: Gamepad, highScores: HighScores, parent: NSWindow) {
        self.audio = audio
        self.gamepad = gamepad
        self.highScores = highScores
        self.parent = parent
        sheet = SheetWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 614),
                            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        sheet.onCancel = { [weak self] in self?.done() }
        buildUI()
    }

    private func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "SETTINGS")
        title.font = mono(20, .bold)

        // ── Audio ──
        let audioHdr = header("AUDIO")
        let music = volumeRow("Music", value: audio.musicGain, label: musicValue, action: #selector(musicChanged(_:)))
        let sfx   = volumeRow("Sound", value: audio.sfxGain, label: sfxValue, action: #selector(sfxChanged(_:)))
        let voice = volumeRow("Voice", value: audio.voiceGain, label: voiceValue, action: #selector(voiceChanged(_:)))
        let ambient = volumeRow("Ambient", value: audio.ambientGain, label: ambientValue, action: #selector(ambientChanged(_:)))
        updateValueLabels()

        // ── Controls ──
        let controlsHdr = header("CONTROLS")
        let invert = NSButton(checkboxWithTitle: "Invert pitch (up = climb, keyboard + stick)",
                              target: self, action: #selector(invertToggled(_:)))
        invert.font = mono(12)
        invert.state = gamepad.invertPitch ? .on : .off

        let dzLabel = NSTextField(labelWithString: "Deadzone")
        dzLabel.font = mono(12)
        dzLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let dz = NSSlider(value: Double(gamepad.deadzone), minValue: 0.05, maxValue: 0.5,
                          target: self, action: #selector(deadzoneChanged(_:)))
        dz.controlSize = .small
        dz.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let dzRow = NSStackView(views: [dzLabel, dz])
        dzRow.orientation = .horizontal
        dzRow.spacing = 12

        let ctrlHint = NSTextField(labelWithString: "Controller mapping is under Controller… (or press C).")
        ctrlHint.font = mono(10)
        ctrlHint.textColor = .tertiaryLabelColor

        // ── Flight trim ──
        let trimHdr = header("FLIGHT TRIM")
        let t = GameSettings.shared
        let agility = trimRow("Agility", value: t.trimAgility, min: 0.25, max: 1.75,
                              action: #selector(agilityChanged(_:)))
        let yawT = trimRow("Yaw", value: t.trimYaw, min: 0.25, max: 1.75,
                           action: #selector(yawTrimChanged(_:)))
        let levelT = trimRow("Auto-level", value: t.trimAutoLevel, min: 0, max: 2, ticks: 9,
                             action: #selector(autoLevelChanged(_:)))
        let trimHint = NSTextField(labelWithString: "Handling response: pitch/roll · yaw (full 6DOF) · hands-off recovery. Centre = tuned defaults.")
        trimHint.font = mono(10)
        trimHint.textColor = .tertiaryLabelColor

        // ── Data ──
        let dataHdr = header("DATA")
        let reset = NSButton(title: "Reset High Scores…", target: self, action: #selector(resetScores))
        reset.bezelStyle = .rounded

        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded

        let stack = NSStackView(views: [title,
                                        audioHdr, music, sfx, voice, ambient,
                                        separator(), controlsHdr, invert, dzRow, ctrlHint,
                                        separator(), trimHdr, agility, yawT, levelT, trimHint,
                                        separator(), dataHdr, reset,
                                        separator(), done])
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

    /// A "LABEL  [slider]  NN%" row for a 0...1 volume.
    private func volumeRow(_ name: String, value: Float, label: NSTextField, action: Selector) -> NSStackView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = mono(12)
        nameLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 1, target: self, action: action)
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        label.font = mono(11)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let row = NSStackView(views: [nameLabel, slider, label])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    /// A "LABEL  [slider]" row for a flight-trim multiplier. Ranges are chosen
    /// so the CENTRE tick lands exactly on 1.0 — the tuned default.
    private func trimRow(_ name: String, value: Float, min: Double, max: Double,
                         ticks: Int = 7, action: Selector) -> NSStackView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = mono(12)
        nameLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let slider = NSSlider(value: Double(value), minValue: min, maxValue: max, target: self, action: action)
        slider.controlSize = .small
        slider.numberOfTickMarks = ticks
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let row = NSStackView(views: [nameLabel, slider])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    private func header(_ text: String) -> NSTextField {
        let h = NSTextField(labelWithString: text)
        h.font = mono(11, .bold)
        h.textColor = .secondaryLabelColor
        return h
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 372).isActive = true
        return b
    }

    private func updateValueLabels() {
        musicValue.stringValue = "\(Int(audio.musicGain * 100))%"
        sfxValue.stringValue = "\(Int(audio.sfxGain * 100))%"
        voiceValue.stringValue = "\(Int(audio.voiceGain * 100))%"
        ambientValue.stringValue = "\(Int(audio.ambientGain * 100))%"
    }

    // MARK: - Actions (apply live + persist)

    @objc private func musicChanged(_ s: NSSlider) {
        audio.musicGain = Float(s.doubleValue); GameSettings.shared.musicVolume = audio.musicGain; updateValueLabels()
    }
    @objc private func sfxChanged(_ s: NSSlider) {
        audio.sfxGain = Float(s.doubleValue); GameSettings.shared.sfxVolume = audio.sfxGain; updateValueLabels()
        audio.uiStart()   // audible tick so the slider has feedback even mid-menu
    }
    @objc private func voiceChanged(_ s: NSSlider) {
        audio.voiceGain = Float(s.doubleValue); GameSettings.shared.voiceVolume = audio.voiceGain; updateValueLabels()
    }
    @objc private func ambientChanged(_ s: NSSlider) {
        audio.ambientGain = Float(s.doubleValue); GameSettings.shared.ambientVolume = audio.ambientGain; updateValueLabels()
    }
    @objc private func invertToggled(_ s: NSButton) { gamepad.invertPitch = (s.state == .on) }
    @objc private func deadzoneChanged(_ s: NSSlider) { gamepad.deadzone = Float(s.doubleValue) }
    @objc private func agilityChanged(_ s: NSSlider) { GameSettings.shared.trimAgility = Float(s.doubleValue) }
    @objc private func yawTrimChanged(_ s: NSSlider) { GameSettings.shared.trimYaw = Float(s.doubleValue) }
    @objc private func autoLevelChanged(_ s: NSSlider) { GameSettings.shared.trimAutoLevel = Float(s.doubleValue) }

    @objc private func resetScores() {
        let alert = NSAlert()
        alert.messageText = "Reset High Scores?"
        alert.informativeText = "This permanently clears the high-score table. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sheet) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.highScores.clear() }
        }
    }

    @objc private func done() { if let p = parent { p.endSheet(sheet) } }
}
