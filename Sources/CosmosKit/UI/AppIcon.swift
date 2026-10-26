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
}
