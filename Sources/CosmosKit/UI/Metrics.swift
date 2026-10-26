import SwiftUI

/// The measurements the interface is built from. Spacing sits on a 4 pt grid, corner radii come in five sizes, and
/// nested shapes are concentric (an inner radius is its container's minus the padding between them), so nothing
/// reads as slightly off. Use these instead of a local number; add a token only when no existing one fits.
enum Metrics {
    enum Space {
        /// Between stacked sidebar rows.
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        /// Keycaps, tags and other small chips.
        static let chip: CGFloat = 6
        /// Buttons and small wells (toolbar buttons, the spaces bar).
        static let control: CGFloat = 8
        /// Sidebar rows, the address pill, rows in a list, drop zones. Inside a `tile` with 2 pt of padding.
        static let row: CGFloat = 10
        /// Favorites tiles, grouped rows (split view), small floating bars.
        static let tile: CGFloat = 12
        /// Web content and the windows that hold it: the page card, Peek, Probe.
        static let page: CGFloat = 14
        /// Floating panels: Command Bar, Site Controls, downloads, the welcome card.
        static let panel: CGFloat = 18
        /// A site icon's corners scale with its size so every icon has the same shape.
        static func icon(_ size: CGFloat) -> CGFloat { size * 0.25 }
    }

    enum Height {
        /// Tab, folder and "New Tab" rows.
        static let row: CGFloat = 32
        /// Section titles ("Today") and the space's name.
        static let header: CGFloat = 24
        /// The address pill and other text fields.
        static let field: CGFloat = 36
        static let tile: CGFloat = 48
        static let toolbar: CGFloat = 40
        static let bar: CGFloat = 44
        /// Square icon buttons.
        static let button: CGFloat = 28
    }

    /// One column system for the whole sidebar: every icon, title and section label starts at a shared x.
    enum Sidebar {
        /// Between the sidebar's edge and its content.
        static let gutter: CGFloat = Space.s
        /// Between a row's edge and what is inside it.
        static let inset: CGFloat = Space.s
        /// Between an icon and its title.
        static let gap: CGFloat = Space.s
        /// One level of folder nesting: a child's icon sits under its folder's icon.
        static let indent: CGFloat = chevron + gap
        static let chevron: CGFloat = 10
    }

    enum Icon {
        static let row: CGFloat = 18
        static let tile: CGFloat = 24
    }
}
