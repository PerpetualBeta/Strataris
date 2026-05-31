// Strataris — application delegate.
//
// Brings up a single window backed by a Metal GameView and wires the input
// → renderer chain, plus a minimal native menu bar (app + window menus) and
// the standard About panel.

import Cocoa
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var view: GameView!
    private var renderer: Renderer!
    private var gamepad: Gamepad!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Strataris: no Metal-capable GPU found")
        }

        // 2× the internal resolution, so a fresh window shows crisp 1:1-ish
        // pixels; the view scales freely if resized.
        let scale = 2
        let size = NSSize(width: RenderConfig.width * scale,
                          height: RenderConfig.height * scale)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Strataris: Galactic Colony Defence"
        window.collectionBehavior = [.fullScreenPrimary]
        // Open maximised: fill the screen's visible frame (below the menu bar,
        // clear of the Dock). The framebuffer is a fixed internal resolution
        // upscaled nearest-neighbour and letterboxed to the view, so a larger
        // window is just a bigger, aspect-correct upscale. Fall back to the
        // 2× contentRect (already set above) and centre if there's no screen.
        if let frame = (window.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrame(frame, display: true)
        } else {
            window.center()
        }

        let input = InputState()
        gamepad = Gamepad()
        view = GameView(frame: NSRect(origin: .zero, size: size), device: device, input: input, gamepad: gamepad)
        renderer = Renderer(device: device, view: view, input: input, gamepad: gamepad)
        view.delegate = renderer

        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu bar

    /// A minimal native menu, in the Jorvik order (About first, then Window
    /// actions, then Quit). Built in code — the app has no nib. Settings and
    /// "Check for Updates…" will slot into the app menu when those land.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // ── Application menu (bold, named after the app) ──
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        let about = NSMenuItem(title: "About Strataris", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)

        appMenu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openOptions), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let controller = NSMenuItem(title: "Controller…", action: #selector(openController), keyEquivalent: "")
        controller.target = self
        appMenu.addItem(controller)

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide Strataris",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Quit Strataris",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // ── Window menu (Minimize / Zoom / Full Screen) ──
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "Minimize",
                        action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom",
                        action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winMenu.addItem(.separator())
        let fullScreen = winMenu.addItem(withTitle: "Enter Full Screen",
                        action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = winMenu
    }

    /// Standard macOS About panel, populated with the app icon, version, and a
    /// Jorvik credit / tagline. Native and dependency-free (no SwiftUI), in
    /// keeping with the game's tiny, all-procedural footprint.
    @objc func openOptions() {
        guard let win = window else { return }
        OptionsSheet.present(over: win, audio: renderer.audio, gamepad: gamepad, highScores: renderer.highScores)
    }

    @objc func openController() {
        guard let win = window, !gamepad.configuring else { return }
        SettingsSheet.present(over: win, gamepad: gamepad)
    }

    @objc func showAbout() {
        let credits = NSMutableAttributedString()
        let centre = NSMutableParagraphStyle()
        centre.alignment = .center
        func line(_ s: String, size: CGFloat, color: NSColor, spacingAfter: CGFloat = 6) {
            credits.append(NSAttributedString(string: s + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
                .paragraphStyle: centre,
            ]))
            credits.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: spacingAfter),
                .paragraphStyle: centre,
            ]))
        }
        line("Galactic Colony Defence", size: 12, color: .labelColor)
        line("A first-person voxel-terrain shoot-’em-up.\nEvery pixel and sound generated in code — no asset files.",
             size: 10, color: .secondaryLabelColor)
        line("A Jorvik Software game.", size: 10, color: .secondaryLabelColor, spacingAfter: 2)

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Strataris",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
