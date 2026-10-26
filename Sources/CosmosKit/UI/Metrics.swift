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

    /// A panel's width or height on a window that may be smaller than the panel wants: the preferred size, or the
    /// window's minus a margin on each side. 0 means the window has not been measured yet.
    static func panelSize(_ preferred: CGFloat, within available: CGFloat) -> CGFloat {
        available > 0 ? min(preferred, max(0, available - 2 * Space.l)) : preferred
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
        /// Favorites sit in a grid this many wide.
        static let favoriteColumns = 3
        /// The width of one Favorites tile in a sidebar of the given width (the grid's flexible columns share what the
        /// gutters and the gaps between tiles leave).
        static func tileWidth(sidebarWidth: CGFloat) -> CGFloat {
            (sidebarWidth - 2 * gutter - CGFloat(favoriteColumns - 1) * Space.s) / CGFloat(favoriteColumns)
        }
    }

    enum Icon {
        static let row: CGFloat = 18
        static let tile: CGFloat = 24
    }

    /// Where a bottom bar's first button goes so its glyph is centred on the icon column above it.
    static let footerInset: CGFloat = Sidebar.gutter + Sidebar.inset - (Height.button - Icon.row) / 2

    /// The controls Settings is built from.
    enum Control {
        /// Buttons, dropdowns, text fields and segmented choices share one height, so they line up in a row.
        static let height: CGFloat = 32
        static let switchWidth: CGFloat = 42
        static let switchHeight: CGFloat = 24
        static let knob: CGFloat = 18
        static let check: CGFloat = 20
        /// The window's navigation column and a question's width.
        static let navWidth: CGFloat = 212
        static let dialogWidth: CGFloat = 400
        /// A switch's knob sits this far in from the track's edge.
        static let knobInset: CGFloat = (switchHeight - knob) / 2
        /// The square behind a pane's symbol, the column a row's symbol sits in, and the line of text inside a field.
        static let paneIcon: CGFloat = 40
        static let rowSymbol: CGFloat = 22
        static let fieldText: CGFloat = 20
        /// How far a scrolling pane's ends fade, and how much of the top of the window the title bar takes.
        static let edgeFade: CGFloat = 28
        static let titleBarClearance: CGFloat = 52
        /// A choice of two or three sits in this much width.
        static let segmentedWidth: CGFloat = 270
    }
}
