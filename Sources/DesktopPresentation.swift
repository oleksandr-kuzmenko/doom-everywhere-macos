import AppKit

// A desktop layer never participates in keyboard focus or intercepts Finder clicks.
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DesktopPresentation {
    private(set) var window: DesktopWindow?
    private var view: DockFrameView?

    func update(enabled: Bool, image: NSImage?) {
        guard enabled, let screen = NSScreen.screens.first else {
            window?.close(); window = nil; view = nil
            return
        }
        if window == nil {
            let background = DesktopWindow(contentRect: screen.frame, styleMask: .borderless,
                                           backing: .buffered, defer: false)
            background.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            background.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            background.ignoresMouseEvents = true
            background.hidesOnDeactivate = false
            background.canHide = false
            background.isReleasedWhenClosed = false
            background.isExcludedFromWindowsMenu = true
            background.hasShadow = false
            background.backgroundColor = .black
            background.title = "DOOM Desktop"
            let frameView = DockFrameView(frame: NSRect(origin: .zero, size: screen.frame.size))
            frameView.autoresizingMask = [.width, .height]
            background.contentView = frameView
            window = background; view = frameView
        }
        window?.setFrame(screen.frame, display: true)
        setImage(image)
        window?.orderFrontRegardless()
    }

    func setImage(_ image: NSImage?) {
        view?.image = image
        view?.needsDisplay = true
    }
}
