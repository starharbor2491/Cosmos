import AppKit

/// The app icon, from `cosmos icon/cosmos-galaxy-icon.png` (scripts/build-app.sh makes the .icns from the original; this
/// is a 512 px copy of it that ships inside the app for the in-app logo and for the Dock when the app is not bundled).
enum AppIcon {
    /// The whole canvas, margin and shadow included: what the Dock expects.
    static let image: NSImage = {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"), let image = NSImage(contentsOf: url) else {
            return NSImage(size: NSSize(width: 512, height: 512))
        }
        return image
    }()

    /// The artwork is a 822 pt tile centred on a 1024 pt canvas.
    static let canvas: CGFloat = 1024
    static let tile: CGFloat = 822

    /// The tile alone (no margin or shadow) at a menu-bar size.
    static func menuBarImage(side: CGFloat = 18) -> NSImage {
        let source = image
        let margin = (canvas - tile) / 2 / canvas
        let inner = tile / canvas
        let crop = NSRect(x: source.size.width * margin, y: source.size.height * margin, width: source.size.width * inner, height: source.size.height * inner)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            source.draw(in: rect, from: crop, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}
