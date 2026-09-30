import AppKit

final class DockFrameView: NSView {
    var image: NSImage?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image = image else {
            ("DOOM" as NSString).draw(at: NSPoint(x: 10, y: bounds.midY - 12), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.systemOrange])
            return
        }
        // Correct DOOM's 320x200 non-square pixels to the original 4:3 display ratio.
        let width = min(bounds.width, bounds.height * 4 / 3)
        let height = width * 3 / 4
        let rect = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
}
