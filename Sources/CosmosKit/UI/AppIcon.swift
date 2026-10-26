import AppKit

/// The app icon: the galaxy artwork in `cosmos icon/`, cut to an icon tile by `scripts/make-app-icon.swift`
/// (`scripts/build-app.sh` makes the .icns from that tile; `AppIcon.png` is a 512 px copy that ships inside the app for
/// the in-app logo and for the Dock when the app is not bundled).
enum AppIcon {
    /// The whole canvas, margin and shadow included: what the Dock expects.
    static let image: NSImage = {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"), let image = NSImage(contentsOf: url) else {
            return NSImage(size: NSSize(width: 512, height: 512))
        }
        return image
    }()

    /// The artwork is an 824 pt tile centred on a 1024 pt canvas.
    static let canvas: CGFloat = 1024
    static let tile: CGFloat = 824

    /// The one-colour swirl for the menu bar, as a template so the system inks it for light and dark menu bars. Each screen
    /// scale has its own drawing (`cosmos icon/logos/single-color`).
    static func menuBarImage() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side))
        for pixels in [18, 36, 54] {
            guard let url = Bundle.module.url(forResource: "MenuBarMark-\(pixels)", withExtension: "png"),
                  let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(width: side, height: side)
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }
}
