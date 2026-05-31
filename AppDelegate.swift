// Strataris — application delegate.
//
// Brings up a single window backed by a Metal GameView and wires the input
// → renderer chain. No menus, no settings yet — this is the flying prototype.

import Cocoa
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var view: GameView!
    private var renderer: Renderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let gamepad = Gamepad()
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
}
