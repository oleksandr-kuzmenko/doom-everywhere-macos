import AppKit

@main
struct WindowSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let presentation = WindowPresentation()
        let image = NSImage(size: NSSize(width: 320, height: 240))
        presentation.update(enabled: true, image: image)
        let window = presentation.window!
        assert(window.isVisible && window.canBecomeKey)
        assert(window.styleMask.contains(.resizable))
        assert(window.contentAspectRatio == NSSize(width: 4, height: 3))
        assert((window.contentView as? DockFrameView)?.image === image)
        var closeRequested = false
        presentation.onClose = { closeRequested = true; presentation.update(enabled: false, image: nil) }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        assert(closeRequested && presentation.window == nil && !window.isVisible)
        presentation.update(enabled: true, image: image)
        assert(presentation.window !== window && presentation.window!.isVisible)
        closeRequested = false
        presentation.update(enabled: false, image: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        assert(!closeRequested && presentation.window == nil)
        print("PASS: resizable 4:3 window; shared frame; close callback; recreation; mode teardown without close callback.")
    }
}
