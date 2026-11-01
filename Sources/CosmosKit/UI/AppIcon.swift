import AppKit
import SwiftUI

/// The app icon: four skies of the same mark (`cosmos icon/`), each cut to an icon tile by `scripts/make-app-icon.swift`.
/// `scripts/build-app.sh` makes the .icns from Nebula's tile; a 512 px copy of each ships inside the app, for the in-app
/// logo and for the Dock, which shows the one picked in Settings ▸ General while Cosmos is open.
enum AppIcon {
    /// The whole canvas, margin and shadow included: what the Dock expects.
    @MainActor static func image(_ style: Settings.AppIconStyle) -> NSImage {
        if let image = images[style] { return image }
        let image = Bundle.module.url(forResource: "AppIcon-\(style.rawValue)", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(size: NSSize(width: 512, height: 512))
        images[style] = image
        return image
    }
    @MainActor private static var images: [Settings.AppIconStyle: NSImage] = [:]

    /// The artwork is an 824 pt tile centred on a 1024 pt canvas.
    static let canvas: CGFloat = 1024
    static let tile: CGFloat = 824

    /// The one-colour crescent for the menu bar, as a template so the system inks it for light and dark menu bars. Each
    /// screen scale has its own drawing (`scripts/make-menubar-mark.swift`).
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

private struct AppIconStyleKey: EnvironmentKey { static let defaultValue = Settings.AppIconStyle.nebula }

extension EnvironmentValues {
    /// The icon picked in Settings, for the Cosmos logo drawn inside the app.
    var appIconStyle: Settings.AppIconStyle {
        get { self[AppIconStyleKey.self] }
        set { self[AppIconStyleKey.self] = newValue }
    }
}
