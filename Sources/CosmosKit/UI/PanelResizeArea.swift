import SwiftUI
import AppKit
import CosmosCore

/// Over the menu-bar panel: its edges and corners take hold of the panel and resize it. The rest of the panel is not this
/// view's (it lets clicks through), so the page and the controls keep theirs.
struct PanelResizeArea: NSViewRepresentable {
    /// Called with the panel's size when the pointer is let go.
    let onResized: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ResizeView()
        view.onResized = onResized
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ResizeView)?.onResized = onResized }

    final class ResizeView: NSView {
        /// The strip along an edge that takes hold of it, and the square at a corner that takes hold of two. They lie in the
        /// strip of sky around the page, never over it.
        static let band: CGFloat = 6
        static let corner: CGFloat = 16

        var onResized: ((CGSize) -> Void)?
        private var edges: MenuBarPlacement.Edges = []
        private var startFrame = NSRect.zero
        private var startPointer = NSPoint.zero

        /// Which edges a point (in a view of `bounds`, y up) has hold of: none in the middle.
        static func edges(at p: NSPoint, in bounds: NSRect) -> MenuBarPlacement.Edges {
            guard bounds.contains(p) else { return [] }
            let nearLeft = p.x - bounds.minX, nearRight = bounds.maxX - p.x, nearBottom = p.y - bounds.minY, nearTop = bounds.maxY - p.y
            let inCornerBand = (nearLeft <= corner || nearRight <= corner) && (nearBottom <= corner || nearTop <= corner)
            var out: MenuBarPlacement.Edges = []
            if nearLeft <= band || (inCornerBand && nearLeft <= corner) { out.insert(.left) }
            if nearRight <= band || (inCornerBand && nearRight <= corner) { out.insert(.right) }
            if nearBottom <= band || (inCornerBand && nearBottom <= corner) { out.insert(.bottom) }
            if nearTop <= band || (inCornerBand && nearTop <= corner) { out.insert(.top) }
            return out
        }

        /// It sits over the whole panel: only the edges are its own.
        override func hitTest(_ point: NSPoint) -> NSView? {
            Self.edges(at: convert(point, from: superview), in: bounds).isEmpty ? nil : self
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            edges = Self.edges(at: convert(event.locationInWindow, from: nil), in: bounds)
            guard !edges.isEmpty, let window else { return }
            startFrame = window.frame
            startPointer = window.convertPoint(toScreen: event.locationInWindow)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !edges.isEmpty, let window else { return }
            // From where the pointer took hold, in screen coordinates: stays right however the panel moves meanwhile.
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? window.screen ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            let frame = MenuBarPlacement.resized(startFrame, edges: edges, delta: CGSize(width: pointer.x - startPointer.x, height: pointer.y - startPointer.y), visible: visible)
            window.setFrame(frame, display: true)
        }

        override func mouseUp(with event: NSEvent) {
            guard !edges.isEmpty, let window else { return }
            edges = []
            onResized?(window.frame.size)
        }

        override func resetCursorRects() {
            let b = bounds, band = Self.band, corner = Self.corner
            addCursorRect(NSRect(x: b.minX, y: b.minY + corner, width: band, height: b.height - 2 * corner), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: b.maxX - band, y: b.minY + corner, width: band, height: b.height - 2 * corner), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: b.minX + corner, y: b.minY, width: b.width - 2 * corner, height: band), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: b.minX + corner, y: b.maxY - band, width: b.width - 2 * corner, height: band), cursor: .resizeUpDown)
            for (x, y, position) in [(b.minX, b.minY, "bottomLeft"), (b.maxX - corner, b.minY, "bottomRight"), (b.minX, b.maxY - corner, "topLeft"), (b.maxX - corner, b.maxY - corner, "topRight")] {
                addCursorRect(NSRect(x: x, y: y, width: corner, height: corner), cursor: Self.cornerCursor(position))
            }
        }

        /// The diagonal resize cursors are only in the system's public API from macOS 15; before that a corner shows the
        /// cross, which still says "take hold here".
        private static func cornerCursor(_ position: String) -> NSCursor {
            if #available(macOS 15, *) {
                let p: NSCursor.FrameResizePosition = switch position {
                case "bottomLeft": .bottomLeft
                case "bottomRight": .bottomRight
                case "topLeft": .topLeft
                default: .topRight
                }
                return NSCursor.frameResize(position: p, directions: .all)
            }
            return .crosshair
        }
    }
}
