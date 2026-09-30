import AppKit

final class WindowPresentation: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var view: DockFrameView?
    var onClose: (() -> Void)?
    var onVisibilityChange: (() -> Void)?

    func update(enabled: Bool, image: NSImage?) {
        guard enabled else {
            window?.delegate = nil
            window?.close(); window = nil; view = nil
            return
        }
        if window == nil {
            let game = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            game.title = "DOOM for macOS"
            game.contentMinSize = NSSize(width: 320, height: 240)
            game.contentAspectRatio = NSSize(width: 4, height: 3)
            game.collectionBehavior = [.fullScreenNone]
            game.isReleasedWhenClosed = false
            game.backgroundColor = .black
            game.delegate = self
            let frameView = DockFrameView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            frameView.autoresizingMask = [.width, .height]
            game.contentView = frameView
            game.center()
            window = game; view = frameView
        }
        setImage(image)
        show()
    }

    func show() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    func setImage(_ image: NSImage?) {
        view?.image = image
        view?.needsDisplay = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Let the app switch back to Dock after AppKit finishes handling the close.
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
        return false
    }
    func windowDidMiniaturize(_ notification: Notification) { onVisibilityChange?() }
    func windowDidDeminiaturize(_ notification: Notification) { onVisibilityChange?() }
}
